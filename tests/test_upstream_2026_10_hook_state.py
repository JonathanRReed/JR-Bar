"""Hook-state fixes JR-Bar took from the October 2026 SidePulse review.

Both are fork-native regressions for behaviours the upstream issue threads
reported (inteliwear/sidepulse #44 and #48); the data here is synthetic.
"""

from __future__ import annotations

import json
from datetime import UTC, datetime, timedelta

from jrbar.collector import LiveAgentMonitor, claude_tool_result_failed, parse_log_line
from jrbar.models import AgentMode
from jrbar.operator_state import BootIdentifier, ClockSample

_NOW = datetime(2026, 10, 7, 12, 0, 0, tzinfo=UTC)


def _clock() -> ClockSample:
    """A fixed minute after the last synthetic event, so nothing here ages out
    with the real date."""
    return ClockSample(_NOW.timestamp() + 60.0, 100.0, BootIdentifier("boot:hook-state"))


def _ingest(monitor, event_name: str, agent_id: str, seconds: int, **event: object) -> None:
    record = parse_log_line(
        "codex",
        json.dumps(
            {
                "logged_at": (_NOW + timedelta(seconds=seconds)).isoformat(),
                "event": {
                    "hook_event_name": event_name,
                    "session_id": "parent-session",
                    "agent_id": agent_id,
                    "cwd": "/tmp/project",
                    **event,
                },
            }
        ),
    )
    assert record is not None
    monitor.ingest_record(record)


def _modes(monitor) -> dict[str, AgentMode]:
    snapshot = monitor.snapshot()
    return {
        status.agent_id: status.mode
        for status in (*snapshot.statuses, *snapshot.stale_statuses)
    }


def test_a_subagent_that_stops_clears_its_own_unanswered_permissions() -> None:
    monitor = LiveAgentMonitor(stale_after_seconds=10**9, clock_sampler=_clock)
    bash = {"tool_name": "Bash"}
    _ingest(monitor, "PermissionRequest", "child-a", 0, **bash, tool_input={"command": "one"})
    _ingest(monitor, "PermissionRequest", "child-a", 1, **bash, tool_input={"command": "two"})
    _ingest(monitor, "PermissionRequest", "child-b", 2, **bash, tool_input={"command": "three"})
    _ingest(monitor, "SubagentStop", "child-a", 3)
    _ingest(monitor, "SubagentStop", "child-b", 4)
    modes = _modes(monitor)
    assert not any(
        mode is AgentMode.WAITING_FOR_INPUT for mode in modes.values()
    ), modes


def test_a_subagent_stop_leaves_a_sibling_waiting_on_its_own_permission() -> None:
    monitor = LiveAgentMonitor(stale_after_seconds=10**9, clock_sampler=_clock)
    bash = {"tool_name": "Bash"}
    _ingest(monitor, "PermissionRequest", "child-a", 0, **bash, tool_input={"command": "one"})
    _ingest(monitor, "PermissionRequest", "child-b", 1, **bash, tool_input={"command": "two"})
    _ingest(monitor, "SubagentStop", "child-a", 2)
    modes = _modes(monitor)
    assert modes["codex:agent:child-b"] is AgentMode.WAITING_FOR_INPUT
    assert modes["codex:agent:child-a"] is not AgentMode.WAITING_FOR_INPUT


def test_output_text_that_mentions_a_traceback_is_not_a_tool_failure() -> None:
    noisy = "ran the suite\nTraceback (most recent call last): shown by a passing test\nexit code: 1 printed by a script\n"
    # A plain string carries the command's output, not a verdict on it.
    assert claude_tool_result_failed([{"type": "tool_result", "content": noisy}], noisy) is False
    assert claude_tool_result_failed(None, noisy) is False


def test_structured_failure_markers_still_count_as_failures() -> None:
    assert claude_tool_result_failed([{"type": "tool_result", "is_error": True, "content": "x"}], None)
    assert claude_tool_result_failed(None, {"success": False})
    assert claude_tool_result_failed(None, {"exit_code": 2})
    assert claude_tool_result_failed(None, {"interrupted": True})
    assert not claude_tool_result_failed(None, {"exit_code": 0})
