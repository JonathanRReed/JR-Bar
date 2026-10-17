"""Initial journal failures stay history while later input stays live."""

import json

from test_terminal_capacity_cause import EPOCH, record

from jrbar.collector import AgentMonitor, SourceSpec
from jrbar.models import AgentMode
from jrbar.operator_state import BootIdentifier, ClockSample
from jrbar.provider_adapters import normalized_provider_record_to_payload
from jrbar.provider_facts import ProviderTerminalCause, WorkLifecycle


def test_initial_failure_fence_survives_rescan_and_allows_new_failure(tmp_path):
    log = tmp_path / "claude.jsonl"
    now = [EPOCH]

    def append(event, session, epoch):
        payload = normalized_provider_record_to_payload(
            record(error="authentication_failed", event=event, session=session, epoch=epoch)
        )
        payload.pop("terminal_cause", None)
        with log.open("a") as stream:
            stream.write(json.dumps(payload) + "\n")

    append("StopFailure", "old-failure", EPOCH - 1)
    append("PermissionRequest", "old-ask", EPOCH - 1)
    append("UserPromptSubmit", "working", EPOCH - 1)
    monitor = AgentMonitor(sources=(SourceSpec("claude", log),), clock_sampler=lambda:
                           ClockSample(now[0], 100, BootIdentifier("boot:fixture")))
    monitor.session_is_live = lambda *_args: False
    first = monitor.snapshot()
    assert any(row.mode is AgentMode.BLOCKED_ERROR for row in first.stale_statuses)
    assert not any(row.mode is AgentMode.BLOCKED_ERROR for row in first.statuses)
    assert any(row.mode is AgentMode.WAITING_FOR_INPUT for row in first.statuses)
    assert any(row.mode is AgentMode.WORKING for row in first.statuses)
    old = next(work for work in first.operator_state.works if work.key.work_id.value == "old-failure")
    assert old.lifecycle is WorkLifecycle.FAILED
    assert old.terminal_cause is ProviderTerminalCause.NONE
    assert all(event.kind.value != "failed" for event in first.operator_events)
    assert monitor.snapshot().operator_events == ()

    now[0] += 1
    append("StopFailure", "new-failure", now[0])
    second = monitor.snapshot()
    assert any(row.mode is AgentMode.BLOCKED_ERROR for row in second.statuses)
    assert any(row.mode is AgentMode.BLOCKED_ERROR for row in second.stale_statuses)
    assert any(event.kind.value == "failed" for event in second.operator_events)

    now[0] += 1
    append("StopFailure", "old-failure", now[0])
    third = monitor.snapshot()
    assert any(row.session_id == "old-failure" and not row.stale for row in third.statuses)


def test_empty_initial_journal_does_not_fence_later_failure(tmp_path):
    log = tmp_path / "claude.jsonl"
    log.touch()
    monitor = AgentMonitor(sources=(SourceSpec("claude", log),), clock_sampler=lambda:
                           ClockSample(EPOCH, 100, BootIdentifier("boot:fixture")))
    monitor.snapshot()
    log.write_text(json.dumps(normalized_provider_record_to_payload(record(error="authentication_failed"))) + "\n")
    assert any(row.mode is AgentMode.BLOCKED_ERROR for row in monitor.snapshot().statuses)


def test_initial_failure_then_reopened_same_session_ask_stays_fresh_on_rescan(tmp_path):
    from jrbar.attention import project_attention
    from jrbar.settings import AgentMonitorSettings

    log = tmp_path / "claude.jsonl"
    payloads = [normalized_provider_record_to_payload(record(
        error="authentication_failed", event=event, session="same-session", epoch=epoch
    )) for event, epoch in [("PermissionRequest", EPOCH - 2), ("StopFailure", EPOCH - 1)]]
    log.write_text("".join(json.dumps(payload) + "\n" for payload in payloads))
    monitor = AgentMonitor(sources=(SourceSpec("claude", log),), clock_sampler=lambda:
                           ClockSample(EPOCH, 100, BootIdentifier("boot:fixture")))
    monitor.session_is_live = lambda *_args: False

    def assert_ask(snapshot):
        work = next(work for work in snapshot.operator_state.works if work.key.work_id.value == "same-session")
        assert work.lifecycle is WorkLifecycle.WAITING
        assert work.terminal_cause is ProviderTerminalCause.NONE
        row = next(row for row in snapshot.statuses if row.session_id == "same-session")
        assert row.mode is AgentMode.WAITING_FOR_INPUT
        assert not row.stale
        assert project_attention(snapshot, AgentMonitorSettings()).actionable_attention
        assert not any(event.kind.value == "failed" for event in snapshot.operator_events)

    initial = monitor.snapshot()
    assert initial.operator_state.works[0].lifecycle is WorkLifecycle.FAILED
    assert initial.stale_statuses[0].mode is AgentMode.BLOCKED_ERROR
    assert not initial.statuses
    assert not any(event.kind.value == "failed" for event in initial.operator_events)
    with log.open("a") as stream:
        stream.write(json.dumps(normalized_provider_record_to_payload(record(
            event="PermissionRequest", session="same-session", epoch=EPOCH
        ))) + "\n")
    assert_ask(monitor.snapshot())
    assert_ask(monitor.snapshot())
    with log.open("a") as stream:
        stream.write(json.dumps(normalized_provider_record_to_payload(record(
            event="UserPromptSubmit", session="other-session", epoch=EPOCH
        ))) + "\n")
    assert_ask(monitor.snapshot())
