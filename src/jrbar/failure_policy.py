"""Failure history stays visible; only a fresh top-level failure interrupts."""
from __future__ import annotations

from datetime import datetime

from .models import AgentMode, AgentStatus

FAILURE_SIGNAL_SECONDS = 5.0
INTERRUPTED_EVENTS = frozenset({
    "Interrupt", "StopInterrupted", "StopCancelled", "SessionCancelled",
    "Cancelled", "Canceled", "Interrupted", "stop:aborted", "on_session_end:interrupted",
})


def ended_without_failure(status: AgentStatus) -> bool:
    return getattr(status, "event_name", "") in INTERRUPTED_EVENTS or getattr(status, "is_capacity_limited", False)


def failure_signal_until(status: AgentStatus) -> float | None:
    if (getattr(status, "is_subagent", False) or getattr(status, "stale", False) or ended_without_failure(status)
            or getattr(status, "mode", None) is not AgentMode.BLOCKED_ERROR):
        return None
    updated = getattr(status, "updated_at", None)
    return updated.timestamp() + FAILURE_SIGNAL_SECONDS if isinstance(updated, datetime) else None


def signals_failure(status: AgentStatus, *, now: datetime) -> bool:
    deadline = failure_signal_until(status)
    return deadline is not None and status.updated_at.timestamp() <= now.timestamp() < deadline
