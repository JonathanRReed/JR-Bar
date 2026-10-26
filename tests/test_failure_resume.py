from dataclasses import replace
from datetime import datetime, timedelta, timezone

import pytest

from jrbar.collector import LiveAgentMonitor
from jrbar.failure_policy import signals_failure
from jrbar.models import AgentMode, AgentStatus, HookEvent, ParentLink
from jrbar.operator_state import BootIdentifier, ClockSample
from jrbar.provider_adapters import _PROVIDER_EVENT_RULES

NOW = datetime(2026, 10, 7, 12, tzinfo=timezone.utc)


@pytest.mark.parametrize("provider", [*list(_PROVIDER_EVENT_RULES), "factory"])
@pytest.mark.parametrize("event,mode", [("UserPromptSubmit", AgentMode.WORKING), ("PreToolUse", AgentMode.TOOL_RUNNING), ("SessionEnd", AgentMode.COMPLETED)])
def test_newer_activity_replaces_failure_across_integrations(provider, event, mode):
    failure = AgentStatus(provider, f"{provider}:session:fixture", "Fixture", AgentMode.BLOCKED_ERROR, NOW, "StopFailure")
    activity = replace(failure, mode=mode, updated_at=NOW + timedelta(seconds=1), event_name=event)
    for direct, external in ((failure, activity), (activity, failure)):
        monitor = LiveAgentMonitor(clock_sampler=lambda: ClockSample(NOW.timestamp() + 2, 102, BootIdentifier("boot:fixture")))
        monitor._compatibility_statuses_by_agent_id[direct.agent_id] = direct
        monitor.replace_external_statuses("t3code", (external,))
        result = monitor.snapshot().statuses[0]
        assert result.mode is mode
        assert not signals_failure(result, now=NOW + timedelta(seconds=2))


@pytest.mark.parametrize("provider,event", [(key, event) for key, rules in _PROVIDER_EVENT_RULES.items() if "StopFailure" in rules
                                         for event in ("UserPromptSubmit", "PreToolUse", "PostToolUse") if event in rules])
def test_hook_or_transcript_resume_clears_canonical_failed_lifecycle(provider, event):
    monitor = LiveAgentMonitor(clock_sampler=lambda: ClockSample(NOW.timestamp() + 2, 102, BootIdentifier("boot:fixture")))
    for delta, name in ((0, "StopFailure"), (1, event)):
        monitor.ingest_record(HookEvent(provider, NOW + timedelta(seconds=delta), name,
                                       {"session_id": "fixture", "tool_name": "Read", "antigravity": {"conversationId": "fixture"}}, session_id="fixture", tool_name="Read"))
    snapshot = monitor.snapshot()
    assert snapshot.statuses[0].mode in {AgentMode.WORKING, AgentMode.TOOL_RUNNING}
    assert snapshot.operator_state.works[0].lifecycle.value == "active"


def test_t3_claude_child_failure_never_signals_and_newer_tool_clears_it():
    child = AgentStatus("claudeAgent", "claude:session:child", "Worker", AgentMode.BLOCKED_ERROR, NOW,
                        "StopFailure", parent_links=(ParentLink("claude:session:child", "codex:session:root", "t3code", NOW.timestamp()),))
    assert not signals_failure(child, now=NOW)
    monitor = LiveAgentMonitor(clock_sampler=lambda: ClockSample(NOW.timestamp() + 2, 102, BootIdentifier("boot:fixture")))
    monitor.replace_external_statuses("t3code", (child,))
    monitor._compatibility_statuses_by_agent_id[child.agent_id] = replace(child, mode=AgentMode.TOOL_RUNNING,
                                                                         event_name="PreToolUse", updated_at=NOW + timedelta(seconds=1))
    assert monitor.snapshot().statuses[0].mode is AgentMode.TOOL_RUNNING


@pytest.mark.parametrize("provider", ["claude", "codex"])
@pytest.mark.parametrize("event", ["UserPromptSubmit", "PreToolUse", "PostToolUse"])
def test_newer_transcript_activity_resumes_a_failed_direct_hook(provider, event):
    monitor = LiveAgentMonitor(clock_sampler=lambda: ClockSample(NOW.timestamp() + 2, 102, BootIdentifier("boot:fixture")))
    for delta, name in ((0, "StopFailure"), (1, event)):
        raw = {"session_id": "fixture", "tool_name": "Read", "request_id": "fixture-tool"}
        if delta:
            raw["source"] = provider + "-transcripts"
        monitor.ingest_record(HookEvent(provider, NOW + timedelta(seconds=delta), name, raw,
                                       session_id="fixture", tool_name="Read"))
    snapshot = monitor.snapshot()
    assert snapshot.statuses[0].mode in {AgentMode.WORKING, AgentMode.TOOL_RUNNING}
    assert snapshot.operator_state.works[0].lifecycle.value == "active"
