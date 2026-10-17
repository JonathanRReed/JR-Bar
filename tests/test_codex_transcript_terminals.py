"""Codex's rollout fallback reads how a turn ended, not only that it ended.

Fixtures are synthetic; the event names and error classes are the ones
Codex's protocol defines (``turn_aborted`` with a reason, and
``task_complete`` carrying a typed ``codex_error_info``).
"""

from __future__ import annotations

from datetime import datetime, timezone
from pathlib import Path

import pytest

from jrbar import collector as collector_module
from jrbar.models import AgentMode

SESSION = "019f179b-7fdc-7eb0-a3af-1ca3eb128eee"
PATH = Path(f"/tmp/rollout-{SESSION}.jsonl")


def _event(payload: dict):
    return collector_module.codex_transcript_event(
        payload,
        session_id=SESSION,
        turn_id="turn-1",
        cwd="/tmp/project",
        timestamp=datetime.now(timezone.utc),
        path=PATH,
    )


@pytest.mark.parametrize("reason", ("interrupted", "replaced", "review_ended", "budget_limited"))
def test_an_aborted_turn_ends_as_an_interrupt_not_a_silent_stall(reason: str) -> None:
    event = _event({"type": "turn_aborted", "reason": reason})

    assert event is not None
    assert event.event_name == "Interrupt"
    assert collector_module.mode_for_event(event) is AgentMode.IDLE_READY
    assert event.session_id == SESSION


@pytest.mark.parametrize(
    "info",
    (
        "context_window_exceeded",
        "rate_limit_exceeded",
        "server_overloaded",
        "unauthorized",
        "session_budget_exceeded",
        {"response_stream_disconnected": {"http_status_code": 502}},
        {"http_connection_failed": {"http_status_code": None}},
    ),
)
def test_a_turn_that_ended_in_a_typed_failure_is_a_failed_terminal(info) -> None:
    event = _event({"type": "task_complete", "error": {"message": "x", "codex_error_info": info}})

    assert event is not None
    assert event.event_name == "StopFailure"
    assert collector_module.mode_for_event(event) is AgentMode.BLOCKED_ERROR
    # Never the raw error text, and never the usage-limit provenance.
    assert "error" not in event.raw
    assert event.message is None
    assert event._terminal_provenance is None


@pytest.mark.parametrize(
    "error",
    (
        {"message": "You hit a rate limit exceeded wall"},
        {"message": "x", "codex_error_info": "other"},
        {"message": "x", "codex_error_info": {"active_turn_not_steerable": {"turn_kind": "review"}}},
        {"message": "x", "codex_error_info": "something_new"},
        {"message": "x", "codex_error_info": None},
    ),
)
def test_free_form_text_and_non_failure_classes_still_read_as_a_normal_stop(error: dict) -> None:
    event = _event({"type": "task_complete", "error": error})

    assert event is not None
    assert event.event_name == "Stop"


def test_a_turn_with_no_error_is_still_a_normal_stop() -> None:
    event = _event({"type": "task_complete", "last_agent_message": "done"})

    assert event is not None and event.event_name == "Stop"


def test_the_usage_limit_class_keeps_its_own_provenance() -> None:
    event = _event({"type": "task_complete", "error": {"codex_error_info": "usage_limit_exceeded"}})

    assert event is not None
    assert event.event_name == "StopFailure"
    assert event._terminal_provenance is not None


@pytest.mark.parametrize("metadata", ({"phase": "commentary"}, {"phase": "analysis"}, {"channel": "commentary"}, {"channel": "analysis"}))
def test_assistant_progress_is_not_a_terminal_or_new_prompt(metadata) -> None:
    event = _event({"type": "message", "role": "assistant", "content": [{"text": "private progress"}], **metadata})
    assert event is not None and event.event_name == "ActivityProgress"
    assert collector_module.mode_for_event(event) is AgentMode.WORKING
    assert event.message is None
    assert "private progress" not in repr(event.raw)


@pytest.mark.parametrize("metadata", ({}, {"phase": "final_answer"}, {"phase": "final"}, {"channel": "final"}))
def test_final_and_legacy_assistant_messages_still_stop(metadata) -> None:
    event = _event({"type": "message", "role": "assistant", "content": [], **metadata})
    assert event is not None and event.event_name == "Stop"


def test_unknown_explicit_assistant_phase_is_not_assumed_final() -> None:
    assert _event({"type": "message", "role": "assistant", "phase": "future_phase"}) is None


@pytest.mark.parametrize("payload,event_name,mode", (
    ({"type": "custom_tool_call", "name": "exec", "call_id": "call-1", "input": "private input"}, "PreToolUse", AgentMode.TOOL_RUNNING),
    ({"type": "custom_tool_call_output", "call_id": "call-1", "output": "private output"}, "PostToolUse", AgentMode.WORKING),
    ({"type": "reasoning", "summary": [{"text": "private reasoning"}]}, "ActivityProgress", AgentMode.WORKING),
))
def test_current_codex_progress_records_are_admitted(payload, event_name, mode) -> None:
    event = _event(payload)
    assert event is not None and event.event_name == event_name
    assert collector_module.mode_for_event(event) is mode


def test_resumed_old_directory_tail_revives_session_without_prompt(tmp_path) -> None:
    import json

    from jrbar.collector import AgentMonitor, SourceSpec

    path = tmp_path / "2026" / "10" / "02" / f"rollout-2026-10-02T17-06-16-{SESSION}_019f179b-7fdc-7eb0-a3af-1ca3eb128eef.jsonl"
    path.parent.mkdir(parents=True)
    now = datetime.now(timezone.utc).isoformat()
    rows = [{"timestamp": now, "type": "event_msg", "payload": {"type": "task_complete"}}]
    rows.extend({"timestamp": now, "type": "event_msg", "payload": {"type": "token_count"}} for _ in range(collector_module.CODEX_TRANSCRIPT_MAX_LINES))
    rows.extend({"timestamp": now, "type": "response_item", "payload": payload} for payload in (
        {"type": "custom_tool_call", "name": "exec", "call_id": "call-1", "input": "{}"},
        {"type": "custom_tool_call_output", "call_id": "call-1", "output": "synthetic"},
        {"type": "message", "role": "assistant", "phase": "commentary", "content": []},
        {"type": "reasoning", "summary": []},
    ))
    path.write_text("\n".join(json.dumps(row) for row in rows) + "\n")
    snapshot = AgentMonitor(sources=(SourceSpec("codex-transcripts", tmp_path),), stale_after_seconds=3600).snapshot()
    assert len(snapshot.statuses) == 1
    assert snapshot.statuses[0].session_id == SESSION
    assert snapshot.statuses[0].mode is AgentMode.WORKING
    assert snapshot.aggregate.mode is AgentMode.WORKING
