"""Pure session visibility and acknowledgement decisions.

Two questions live here, and nowhere else:

* which sessions the panel's list may hold at all (``session_visibility``,
  ``filter_visible_sessions``) -- everything else belongs to
  ``list_history``;
* which finished sessions still count as news the user has not seen
  (``select_unseen_completions``) and which may be acknowledged
  (``select_clearable_completions``, ``clearable_presentation_key``).

Nothing here reads a clock or a controller: every window is passed in, so a
test clock can move twenty minutes without waiting twenty minutes.
"""

from __future__ import annotations

import math
from collections.abc import Collection, Iterable, Mapping
from datetime import datetime, timezone
from typing import Any, Final

from .clear_agents import (
    CompletionPresentationKey,
    clearable_presentation_key,
    completion_presentation_key,
)
from .freshness import is_recent
from .models import AgentMode, AgentStatus
from .provider_facts import WorkKey

#: How long a finished session (``completed`` or ``ended``) stays in
#: ``state.sessions`` while nobody acknowledges it. After this it is only in
#: ``list_history``. The collector uses the same number to decide when a
#: completion stops being a fresh row.
COMPLETED_VISIBLE_SECONDS: Final = 20 * 60.0

#: How long a live-shaped session (working, tool running, waiting, blocked,
#: idle-ready) that has stopped delivering stays listed. Ten quiet minutes
#: and it is over as far as the panel is concerned -- the owner's 49-minute
#: "Done · stale" rows are exactly what this window exists to stop.
LIVE_VISIBLE_SECONDS: Final = 10 * 60.0

#: The events that prove a provider really ended a run. Anything else that
#: arrives as ``AgentMode.COMPLETED`` (a notification the collector read as
#: finished, an explicit status message) is an inference, and an inference
#: never earns the green check -- it reads ``ended``.
END_EVENT_NAMES: Final = frozenset({"Stop", "SessionEnd", "SubagentStop"})

#: The ``lifecycle`` words that mean "this run is over".
FINISHED_LIFECYCLES: Final = frozenset({"completed", "ended"})

#: Acknowledgement epochs and row clocks come from the same datetime, but
#: they travel through JSON; compare them with a millisecond of slack.
ACKNOWLEDGED_EPSILON: Final = 0.001

#: What ``session_visibility`` answers.
VISIBLE_LIVE: Final = "live"
VISIBLE_COMPLETION: Final = "completion"
HIDDEN: Final = "hidden"


def _as_utc(value: datetime) -> datetime:
    if value.tzinfo is None:
        return value.replace(tzinfo=timezone.utc)
    return value.astimezone(timezone.utc)


def acknowledged_epoch_by_session(
    acknowledged_keys: Iterable[CompletionPresentationKey],
) -> dict[str, float]:
    """The newest acknowledgement epoch per session id.

    A receipt acknowledges one *event* of one session, not the session for
    ever: the row it hid stays hidden, but the moment that session speaks
    again its clock moves past the receipt and it is listed once more.
    """

    newest: dict[str, float] = {}
    for key in acknowledged_keys:
        agent_id = getattr(key, "agent_id", None)
        at = getattr(key, "completed_at_epoch", None)
        if not isinstance(agent_id, str) or not isinstance(at, (int, float)):
            continue
        at = float(at)
        if not math.isfinite(at):
            continue
        if at > newest.get(agent_id, float("-inf")):
            newest[agent_id] = at
    return newest


def _row_is_acknowledged(
    row: Mapping[str, Any], acknowledged_at_by_id: Mapping[str, float]
) -> bool:
    acknowledged_at = acknowledged_at_by_id.get(str(row.get("id") or ""))
    if acknowledged_at is None:
        return False
    updated_at = row.get("updated_at")
    if not isinstance(updated_at, (int, float)):
        return True
    return float(acknowledged_at) >= float(updated_at) - ACKNOWLEDGED_EPSILON


def session_visibility(
    row: Mapping[str, Any],
    *,
    now: float,
    acknowledged_at_by_id: Mapping[str, float] | None = None,
    live_visible_seconds: float = LIVE_VISIBLE_SECONDS,
    completed_visible_seconds: float = COMPLETED_VISIBLE_SECONDS,
) -> str:
    """``live``, ``completion`` or ``hidden`` for one ``state.sessions`` row.

    * live -- working, tool running, waiting, blocked, or idle-ready, and
      either still delivering or quiet for less than ``live_visible_seconds``;
    * completion -- finished (``completed`` or ``ended``), not acknowledged,
      and younger than ``completed_visible_seconds``;
    * hidden -- everything else. ``list_history`` has it.
    """

    acknowledged_at_by_id = acknowledged_at_by_id or {}
    updated_at = row.get("updated_at")
    age = (
        float(now) - float(updated_at)
        if isinstance(updated_at, (int, float))
        else float("inf")
    )
    age = max(0.0, age)
    lifecycle = str(row.get("lifecycle") or "active")
    acknowledged = _row_is_acknowledged(row, acknowledged_at_by_id)
    if lifecycle in FINISHED_LIFECYCLES:
        if acknowledged or age > float(completed_visible_seconds):
            return HIDDEN
        return VISIBLE_COMPLETION
    if acknowledged:
        # A widened clear acknowledges stale rows too; they do not come
        # back until their session speaks again.
        return HIDDEN
    if lifecycle == "stale" or bool(row.get("stale")):
        return HIDDEN if age > float(live_visible_seconds) else VISIBLE_LIVE
    return VISIBLE_LIVE


def filter_visible_sessions(
    sessions: Iterable[Mapping[str, Any]],
    *,
    now: float,
    acknowledged_at_by_id: Mapping[str, float] | None = None,
    live_visible_seconds: float = LIVE_VISIBLE_SECONDS,
    completed_visible_seconds: float = COMPLETED_VISIBLE_SECONDS,
) -> tuple[list[Mapping[str, Any]], int, tuple[str, ...]]:
    """``(visible rows, hidden main count, visible completion ids)``.

    Order is preserved. A worker follows its parent: when the parent is not
    listed the worker is not either, so the panel never shows an orphan.
    ``hidden main count`` is what the app renders as "n earlier in History";
    workers dropped with their parent are not counted twice.
    """

    rows = list(sessions)
    verdicts = {
        str(row.get("id") or ""): session_visibility(
            row,
            now=now,
            acknowledged_at_by_id=acknowledged_at_by_id,
            live_visible_seconds=live_visible_seconds,
            completed_visible_seconds=completed_visible_seconds,
        )
        for row in rows
    }
    listed: list[Mapping[str, Any]] = []
    hidden_mains = 0
    completions: list[str] = []
    for row in rows:
        agent_id = str(row.get("id") or "")
        verdict = verdicts.get(agent_id, HIDDEN)
        parent = row.get("parent")
        if (
            verdict != HIDDEN
            and str(row.get("kind") or "") == "worker"
            and parent
            and verdicts.get(str(parent), HIDDEN) == HIDDEN
        ):
            verdict = HIDDEN
        if verdict == HIDDEN:
            if str(row.get("kind") or "main") == "main":
                hidden_mains += 1
            continue
        listed.append(row)
        if verdict == VISIBLE_COMPLETION and str(row.get("kind") or "") == "main":
            completions.append(agent_id)
    return listed, hidden_mains, tuple(completions)


def project_clearable_sessions(
    statuses: Iterable[AgentStatus],
    *,
    listed_ids: Collection[str],
    state: object,
    now_epoch: float,
    session_ids: Collection[str] | None = None,
):
    """The Clear Agents preview for ``clear_completed``.

    Targets are the main sessions the panel is *currently listing* as over:
    completed, ended-unconfirmed, or stale. Everything else it lists --
    live sessions and every worker row -- is fenced as protected, exactly as
    the popover's own preview does, so the same commit/undo machinery
    applies. ``session_ids`` narrows the batch to those sessions; ``None``
    means every clearable row.
    """

    from .clear_agents import project_clear_agents_preview

    wanted = None if session_ids is None else {str(value) for value in session_ids}
    listed = {str(value) for value in listed_ids}
    candidates: list[AgentStatus] = []
    protected: list[AgentStatus] = []
    seen: set[str] = set()
    for status in statuses:
        agent_id = getattr(status, "agent_id", None)
        if not isinstance(agent_id, str) or agent_id in seen or agent_id not in listed:
            continue
        seen.add(agent_id)
        clearable = (
            not getattr(status, "is_subagent", False)
            and clearable_presentation_key(status) is not None
            and (wanted is None or agent_id in wanted)
        )
        (candidates if clearable else protected).append(status)
    return project_clear_agents_preview(
        tuple(candidates),
        state=state,
        now_epoch=now_epoch,
        protected_statuses=tuple(protected),
        widened=True,
    )


def _current_rows_by_id(
    statuses: Iterable[AgentStatus],
) -> tuple[dict[str, AgentStatus], tuple[str, ...]]:
    selected: dict[str, AgentStatus] = {}
    ordered_ids: list[str] = []
    for status in statuses:
        existing = selected.get(status.agent_id)
        if existing is None:
            ordered_ids.append(status.agent_id)
        if existing is None or (
            _as_utc(status.updated_at),
            status.mode != AgentMode.COMPLETED,
        ) > (
            _as_utc(existing.updated_at),
            existing.mode != AgentMode.COMPLETED,
        ):
            selected[status.agent_id] = status
    return selected, tuple(ordered_ids)


def _source_bound_identity(status: AgentStatus) -> tuple[object | None, str]:
    """Keep source instances distinct while retaining a safe unkeyed fallback."""

    work_key = status.work_key
    source_key = (
        work_key.source_key
        if type(work_key) is WorkKey
        and work_key.source_key.provider_id == status.provider
        else None
    )
    return source_key, status.agent_id


def _current_rows_by_source_identity(
    statuses: Iterable[AgentStatus],
) -> tuple[dict[tuple[object | None, str], AgentStatus], tuple[tuple[object | None, str], ...]]:
    selected: dict[tuple[object | None, str], AgentStatus] = {}
    ordered_keys: list[tuple[object | None, str]] = []
    for status in statuses:
        identity = _source_bound_identity(status)
        existing = selected.get(identity)
        if existing is None:
            ordered_keys.append(identity)
        if existing is None or (
            _as_utc(status.updated_at),
            status.mode != AgentMode.COMPLETED,
        ) > (
            _as_utc(existing.updated_at),
            existing.mode != AgentMode.COMPLETED,
        ):
            selected[identity] = status
    return selected, tuple(ordered_keys)


def _completion_is_eligible(
    status: AgentStatus,
    *,
    collected_at: datetime,
    within_seconds: float,
    include_subagents: bool,
) -> bool:
    return (
        (include_subagents or not status.is_subagent)
        and status.mode == AgentMode.COMPLETED
        and status.event_name != "SessionEnd"
        and is_recent(collected_at, status.updated_at, within_seconds)
    )


def select_clearable_completions(
    current_statuses: Iterable[AgentStatus],
    stale_statuses: Iterable[AgentStatus],
    *,
    collected_at: datetime,
    within_seconds: float,
    include_subagents: bool = False,
) -> tuple[AgentStatus, ...]:
    """Select one recent clearable completion per identity.

    Any current row shadows every stale row with the same identity, even when
    the current row is not itself eligible. This prevents an old completion
    from reappearing after that session has resumed.
    """

    current_by_identity, _ = _current_rows_by_source_identity(current_statuses)
    eligible_by_identity = {
        identity: status
        for identity, status in current_by_identity.items()
        if _completion_is_eligible(
            status,
            collected_at=collected_at,
            within_seconds=within_seconds,
            include_subagents=include_subagents,
        )
    }
    stale_by_identity, _ = _current_rows_by_source_identity(stale_statuses)
    for identity, status in stale_by_identity.items():
        if identity in current_by_identity:
            continue
        if _completion_is_eligible(
            status,
            collected_at=collected_at,
            within_seconds=within_seconds,
            include_subagents=include_subagents,
        ):
            eligible_by_identity[identity] = status
    return tuple(
        sorted(
            eligible_by_identity.values(),
            key=lambda status: (
                -_as_utc(status.updated_at).timestamp(),
                status.agent_id,
            ),
        )
    )


def select_unseen_completions(
    current_statuses: Iterable[AgentStatus],
    stale_statuses: Iterable[AgentStatus],
    *,
    collected_at: datetime,
    within_seconds: float,
    menu_last_opened_at: datetime | None,
    acknowledged_keys: Collection[CompletionPresentationKey],
    attended_prompt_monotonic: Mapping[str, float],
    now_monotonic: float,
    attended_quiet_seconds: float,
) -> tuple[AgentStatus, ...]:
    """Select main-session completions not acknowledged by any surface."""

    current_by_identity, current_order = _current_rows_by_source_identity(
        current_statuses
    )
    stale_by_identity, stale_order = _current_rows_by_source_identity(stale_statuses)
    candidates = (
        *(current_by_identity[identity] for identity in current_order),
        *(
            stale_by_identity[identity]
            for identity in stale_order
            if identity not in current_by_identity
        ),
    )
    opened_at = (
        _as_utc(menu_last_opened_at)
        if menu_last_opened_at is not None
        else None
    )
    unseen: list[AgentStatus] = []
    for status in candidates:
        if not _completion_is_eligible(
            status,
            collected_at=collected_at,
            within_seconds=within_seconds,
            include_subagents=False,
        ):
            continue
        key = completion_presentation_key(status)
        if key is not None and key in acknowledged_keys:
            continue
        if opened_at is not None and _as_utc(status.updated_at) <= opened_at:
            continue
        prompted_at = attended_prompt_monotonic.get(status.agent_id)
        if (
            prompted_at is not None
            and float(now_monotonic) - float(prompted_at)
            <= float(attended_quiet_seconds)
        ):
            continue
        unseen.append(status)
    return tuple(unseen)


def plan_seen_completion_ids(
    visible_statuses: Iterable[AgentStatus],
    previously_seen_ids: Collection[str],
    *,
    limit: int = 100,
) -> tuple[str, ...]:
    """Plan bounded completion acknowledgement for one menu visit."""

    selected_by_id, _ = _current_rows_by_id(visible_statuses)
    visible_ids = [
        status.agent_id
        for status in sorted(
            (
                status
                for status in selected_by_id.values()
                if status.mode == AgentMode.COMPLETED
                and status.event_name != "SessionEnd"
            ),
            key=lambda status: (
                -_as_utc(status.updated_at).timestamp(),
                status.agent_id,
            ),
        )
    ]
    retained_ids = sorted(set(previously_seen_ids).difference(visible_ids))
    return tuple((*visible_ids, *retained_ids)[: max(0, int(limit))])
__all__ = [
    "ACKNOWLEDGED_EPSILON",
    "COMPLETED_VISIBLE_SECONDS",
    "END_EVENT_NAMES",
    "FINISHED_LIFECYCLES",
    "HIDDEN",
    "LIVE_VISIBLE_SECONDS",
    "VISIBLE_COMPLETION",
    "VISIBLE_LIVE",
    "acknowledged_epoch_by_session",
    "filter_visible_sessions",
    "plan_seen_completion_ids",
    "project_clearable_sessions",
    "select_clearable_completions",
    "select_unseen_completions",
    "session_visibility",
]
