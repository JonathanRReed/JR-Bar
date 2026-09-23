"""Claude Code's StopFailure and SubagentStart are subscribed and mean what
they say: a turn that died on an API error fails with the real error, and a
worker is counted from the moment it starts."""

from __future__ import annotations

import json
from pathlib import Path

from jrbar._collector_legacy import mode_for_event
from jrbar.hook import _normalized_hook_record, routed_hook_payload
from jrbar.models import AgentMode
from jrbar.provider_adapters import NormalizedProviderRecord, ProviderEventName
from jrbar.providers import CLAUDE_EVENTS, parse_log_line


def _record(payload: dict):
    text = json.dumps(payload)
    actual, _, line = routed_hook_payload("claude", Path("/tmp/claude.jsonl"), text)
    return _normalized_hook_record(actual, line), parse_log_line(actual, json.dumps(line))


def test_claude_subscribes_to_stop_failure_and_subagent_start__and_2_more() -> None:
    # --- scenario: the installer and the detector know both events
    assert "StopFailure" in CLAUDE_EVENTS and "SubagentStart" in CLAUDE_EVENTS
    assert CLAUDE_EVENTS.index("SubagentStart") < CLAUDE_EVENTS.index("SubagentStop")

    # --- scenario: a rate-limited turn fails with the API's own words
    normalized, event = _record(
        {
            "hook_event_name": "StopFailure",
            "session_id": "s-1",
            "cwd": "/Users/me/repo",
            "error": "rate_limit",
            "error_details": "429 Too Many Requests",
            "last_assistant_message": "API Error: Rate limit reached",
        }
    )
    assert type(normalized) is NormalizedProviderRecord
    assert normalized.event_name is ProviderEventName.STOP_FAILURE
    assert mode_for_event(event) is AgentMode.BLOCKED_ERROR
    assert event.message == "API Error: Rate limit reached"

    # --- scenario: a worker exists from its start, under its session
    normalized, event = _record(
        {
            "hook_event_name": "SubagentStart",
            "session_id": "s-1",
            "cwd": "/Users/me/repo",
            "agent_id": "agent-abc123",
            "agent_type": "Explore",
        }
    )
    assert type(normalized) is NormalizedProviderRecord
    assert normalized.event_name is ProviderEventName.SUBAGENT_START
    assert normalized.provider_work_id.value == "agent-abc123"
    assert normalized.parent_work_id.value == "s-1"
    assert mode_for_event(event) is AgentMode.WORKING
