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
from collections.abc import Callable, Iterable
from dataclasses import dataclass
from pathlib import Path

from .hook import process_hook_payload
from .models import AgentMode, AgentStatus
from .process_registry import DeadAgentProcess, ProcessSweeper
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


def _subagent_worker_id(status: AgentStatus) -> str | None:
    marker = ":agent:"
    if marker not in status.agent_id:
        return None
    return status.agent_id.split(marker, 1)[1] or None


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


def reap_dead_agents(
    statuses: Iterable[AgentStatus],
    *,
    sweeper: ProcessSweeper,
    refresh_hint_handler: Callable[[object], object] | None,
    process_payload: Callable[..., object] = process_hook_payload,
    log_path_for: Callable[[str], Path] = detect_log_path,
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
    return SweepResult(tuple(dead), synthesized, frozenset(live), failed)


__all__ = ["LIVE_MODES", "SweepResult", "reap_dead_agents", "synthetic_end_payloads"]
