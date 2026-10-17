"""End sessions whose agent process is gone -- and name the ones still running.

The sweep runs inside the app on every refresh tick. For each session that
still looks alive (working, tool running, waiting, idle) it asks the
process registry whether the backing process exists. When it does not, a
``SessionEnd`` (or ``SubagentStop`` for a worker) is written through the
ordinary hook pipeline, so the record is persisted, deduplicated, and
reduced exactly like one the agent would have sent itself. The synthetic
record carries ``reason`` so the menu can say "process exited" rather than
"completed".

The same pass answers the opposite question for free, and
``SweepResult.live_sessions`` carries it: which sessions the process table
just proved alive. The collector needs that, because otherwise a silence
timer is the only evidence it has, and a long tool run that legitimately
says nothing for twenty minutes gets called dead while its process is
sitting right there in the table.
"""

from __future__ import annotations

import json
import time
from collections.abc import Callable, Iterable, Mapping
from dataclasses import dataclass
from pathlib import Path

from .ask_lifetime import (
    ASK_EXPIRED_REASON,
    ASK_EXPIRES_UNANSWERED_SECONDS,
    ASK_MAY_BE_STALE_SECONDS,
    AskStanding,
    ask_standing,
)
from .hook import process_hook_payload
from .models import AgentMode, AgentStatus, worker_id
from .process_registry import (
    ClaudeSessionActivity,
    DeadAgentProcess,
    ProcessSweeper,
    claude_session_activity,
)
from .providers import detect_log_path

LIVE_MODES = frozenset(
    {
        AgentMode.WORKING,
        AgentMode.TOOL_RUNNING,
        AgentMode.WAITING_FOR_INPUT,
        AgentMode.LONG_TASK_PROGRESS,
        AgentMode.IDLE_READY,
        AgentMode.BLOCKED_ERROR,
        AgentMode.ENDED_UNCONFIRMED,
    }
)
SYNTHETIC_REASON_PREFIX = "jrbar_process_"
IDLE_REASON = "jrbar_claude_session_idle"
#: A session file that turns idle within this long of the last hook is the
#: normal end of a turn whose Stop is still in flight, not a missed one.
IDLE_GRACE_SECONDS = 3.0
_WORKING_SHAPED = frozenset(
    {AgentMode.WORKING, AgentMode.TOOL_RUNNING, AgentMode.LONG_TASK_PROGRESS}
)


@dataclass(frozen=True, slots=True)
class SweepResult:
    ended_sessions: tuple[DeadAgentProcess, ...]
    synthesized_events: int
    # The other half of the sweep, and the half the silence timer needs:
    # the ``(provider, session_id)`` pairs whose process the table just
    # proved alive. Affirmative only -- a session absent from this set is
    # one nobody could vouch for, not one known dead.
    live_sessions: frozenset[tuple[str, str]] = frozenset()
    # Payloads the pipeline refused. The registry marks a death before the
    # event lands, so a failed write used to be a silent permanent loss --
    # the session kept its light and the corpse kept its ask. ``classify``
    # re-reports any session still claimed live past its recorded end, so
    # a failure is now a delay instead of a loss; the count exists so the
    # caller can log that delay instead of swallowing it.
    failed_sends: int = 0
    # Claude turns the person stopped with Esc, which fire no hook: the pid
    # file says the session went idle after the last hook, and the turn was
    # ended here.
    idled_sessions: int = 0
    # Asks closed by age: unanswered past ``ask_lifetime``'s outer bound with
    # no running process behind them. Each one was ended through the ordinary
    # hook pipeline and is recorded in History as "expired unanswered".
    expired_asks: tuple[AgentStatus, ...] = ()


def _subagent_worker_id(status: AgentStatus) -> str | None:
    return worker_id(status.provider, status.agent_id) or None


def synthetic_end_payloads(
    dead: DeadAgentProcess,
    statuses: Iterable[AgentStatus],
    *,
    now: float | None = None,
) -> list[str]:
    """Hook-shaped payloads that end every row of one dead session."""
    stamp = time.time() if now is None else now
    record = dead.record
    reason = f"{SYNTHETIC_REASON_PREFIX}{dead.reason}"
    payloads: list[str] = []
    for status in statuses:
        if status.provider != record.provider or status.session_id != record.session_id:
            continue
        worker = _subagent_worker_id(status)
        if worker is None:
            continue
        payloads.append(
            json.dumps(
                {
                    "hook_event_name": "SubagentStop",
                    "session_id": record.session_id,
                    "agent_id": worker,
                    "reason": reason,
                    "jrbar_synthetic": True,
                    "occurred_at_epoch": stamp,
                },
                separators=(",", ":"),
            )
        )
    payloads.append(
        json.dumps(
            {
                "hook_event_name": "SessionEnd",
                "session_id": record.session_id,
                "cwd": record.cwd,
                "reason": reason,
                "jrbar_synthetic": True,
                "occurred_at_epoch": stamp,
            },
            separators=(",", ":"),
        )
    )
    return payloads


def expired_ask_payloads(status: AgentStatus, *, now: float) -> list[str]:
    """The hook-shaped end of a session whose ask expired unanswered.

    A worker's ask ends that worker (``SubagentStop``); a main session's ends
    the session. ``reason`` names the cause so the panel never says the agent
    finished, and ``jrbar_synthetic`` marks it as the Mac's own record.
    """
    worker = _subagent_worker_id(status)
    event = "SubagentStop" if worker is not None else "SessionEnd"
    payload: dict[str, object] = {
        "hook_event_name": event,
        "session_id": status.session_id,
        "reason": ASK_EXPIRED_REASON,
        "jrbar_synthetic": True,
        "occurred_at_epoch": now,
    }
    if worker is not None:
        payload["agent_id"] = worker
    else:
        payload["cwd"] = status.cwd
    return [json.dumps(payload, separators=(",", ":"))]


def reap_dead_agents(
    statuses: Iterable[AgentStatus],
    *,
    sweeper: ProcessSweeper,
    refresh_hint_handler: Callable[[object], object] | None,
    process_payload: Callable[..., object] = process_hook_payload,
    log_path_for: Callable[[str], Path] = detect_log_path,
    claude_activity_loader: Callable[[], Mapping[str, ClaudeSessionActivity]] = claude_session_activity,
    now: float | None = None,
    ask_stale_after_seconds: float = ASK_MAY_BE_STALE_SECONDS,
    ask_expire_after_seconds: float = ASK_EXPIRES_UNANSWERED_SECONDS,
) -> SweepResult:
    rows = [status for status in statuses if status.mode in LIVE_MODES and status.session_id]
    sessions = [(status.provider, status.session_id) for status in rows if status.session_id]
    classify = getattr(sweeper, "classify", None)
    if callable(classify):
        dead, live = classify(sessions)
    else:  # a sweeper double that only knows the old question
        dead, live = sweeper.sweep(sessions), frozenset()
    synthesized = 0
    failed = 0
    for item in dead:
        for payload in synthetic_end_payloads(item, rows):
            try:
                process_payload(
                    item.record.provider,
                    log_path_for(item.record.provider),
                    payload,
                    refresh_hint_handler=refresh_hint_handler,
                )
                synthesized += 1
            except Exception:
                failed += 1
    idled = 0
    for status, changed_at in _idle_claude_turns(rows, live, claude_activity_loader):
        payload = json.dumps(
            {
                "hook_event_name": "Interrupt",
                "session_id": status.session_id,
                "cwd": status.cwd,
                "reason": IDLE_REASON,
                "jrbar_synthetic": True,
                "occurred_at_epoch": changed_at,
            },
            separators=(",", ":"),
        )
        try:
            process_payload(
                status.provider,
                log_path_for(status.provider),
                payload,
                refresh_hint_handler=refresh_hint_handler,
            )
            idled += 1
        except Exception:
            failed += 1
    expired: list[AgentStatus] = []
    stamp = time.time() if now is None else float(now)
    dead_sessions = {(item.record.provider, item.record.session_id) for item in dead}
    for status in rows:
        session = (status.provider, status.session_id)
        if (
            status.stale
            or not status.is_hard_ask
            or session in dead_sessions
            or ask_standing(
                opened_at_epoch=status.updated_at.timestamp(),
                last_activity_epoch=status.updated_at.timestamp(),
                now_epoch=stamp,
                process_alive=session in live,
                stale_after_seconds=ask_stale_after_seconds,
                expire_after_seconds=ask_expire_after_seconds,
            )
            is not AskStanding.EXPIRED
        ):
            continue
        sent = False
        for payload in expired_ask_payloads(status, now=stamp):
            try:
                process_payload(
                    status.provider,
                    log_path_for(status.provider),
                    payload,
                    refresh_hint_handler=refresh_hint_handler,
                )
                sent = True
            except Exception:
                failed += 1
        if sent:
            expired.append(status)
    return SweepResult(tuple(dead), synthesized, frozenset(live), failed, idled, tuple(expired))


def _idle_claude_turns(
    rows: Iterable[AgentStatus],
    live: Iterable[tuple[str, str]],
    loader: Callable[[], Mapping[str, ClaudeSessionActivity]],
) -> list[tuple[AgentStatus, float]]:
    """Working Claude sessions whose own pid file went idle after the last hook."""
    candidates = [
        status
        for status in rows
        if status.provider == "claude"
        and status.mode in _WORKING_SHAPED
        and status.session_id
        and _subagent_worker_id(status) is None
    ]
    live = frozenset(live)
    candidates = [status for status in candidates if ("claude", status.session_id) in live]
    if not candidates:
        return []
    try:
        activity = loader()
    except Exception:
        return []
    ended: list[tuple[AgentStatus, float]] = []
    for status in candidates:
        seen = activity.get(status.session_id or "")
        if (
            seen is not None
            and seen.status == "idle"
            and seen.changed_at > status.updated_at.timestamp() + IDLE_GRACE_SECONDS
        ):
            ended.append((status, seen.changed_at))
    return ended


__all__ = [
    "LIVE_MODES",
    "SweepResult",
    "expired_ask_payloads",
    "reap_dead_agents",
    "synthetic_end_payloads",
]
