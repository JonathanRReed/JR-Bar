"""Claude Code's MCP elicitation and its dialog notifications are asks.

An MCP server asking the owner for input (the ``Elicitation`` hook) opens a
live DIALOG request keyed by its ``elicitation_id`` -- a real ask for the
light, escalation and the panel, never answered in place -- and the matching
``ElicitationResult`` resolves it. The ``elicitation_dialog``,
``elicitation_url_dialog`` and ``agent_needs_input`` notifications wait on
the owner by name, whatever their words, and no longer read as the source
going quiet.
"""

from __future__ import annotations

import json
from datetime import datetime, timedelta, timezone
from pathlib import Path

import pytest

from jrbar._collector_legacy import (
    _registered_hook_source,
    mode_for_event,
    notification_requests_input,
    should_ignore_status_transition,
    status_from_event,
)
from jrbar.answer_in_place import answer_capability_for_request
from jrbar.collector import LiveAgentMonitor
from jrbar.hook import _normalized_hook_record, routed_hook_payload
from jrbar.models import AgentMode
from jrbar.operator_state import BootIdentifier, ClockSample, RequestPhase
from jrbar.provider_adapters import (
    NormalizedProviderRecord,
    NotificationKind,
    ProviderEventName,
    provider_facts_for_record,
)
from jrbar.provider_facts import (
    NextActor,
    ProviderRequestState,
    RequestKind,
    SourceFreshness,
    WorkLifecycle,
)
from jrbar.providers import CLAUDE_EVENTS, parse_log_line

NOW = datetime.now(timezone.utc).replace(microsecond=0)
BASE = {"session_id": "s-1", "cwd": "/Users/me/repo", "transcript_path": "/tmp/t.jsonl"}
ELICIT = {
    **BASE,
    "hook_event_name": "Elicitation",
    "mcp_server_name": "github",
    "message": "Which repository?",
    "mode": "form",
    "elicitation_id": "el-7",
    "requested_schema": {"type": "object", "properties": {"repo": {"type": "string"}}},
}
RESULT = {
    **BASE,
    "hook_event_name": "ElicitationResult",
    "mcp_server_name": "github",
    "elicitation_id": "el-7",
    "mode": "form",
    "action": "accept",
    "content": {"repo": "jr-bar"},
}


def _records(payload: dict):
    actual, _, line = routed_hook_payload("claude", Path("/tmp/claude.jsonl"), json.dumps(payload))
    return _normalized_hook_record(actual, line), parse_log_line(actual, json.dumps(line))


def _batch(normalized):
    source = _registered_hook_source("claude")
    return provider_facts_for_record(
        normalized,
        contract=source.contract,
        observation_authority=source.registration.observation_authority,
        observed_at_epoch=NOW.timestamp(),
    )


def test_claude_subscribes_to_the_elicitation_pair() -> None:
    assert "Elicitation" in CLAUDE_EVENTS and "ElicitationResult" in CLAUDE_EVENTS


def test_an_elicitation_opens_a_dialog_request_its_result_resolves() -> None:
    normalized, event = _records(ELICIT)
    assert type(normalized) is NormalizedProviderRecord
    assert normalized.event_name is ProviderEventName.ELICITATION
    assert normalized.provider_request_id.value == "el-7"
    batch = _batch(normalized)
    assert batch.diagnostics == () and batch.source_freshness is SourceFreshness.FRESH
    (work,) = batch.work_facts
    assert work.lifecycle is WorkLifecycle.WAITING and work.next_actor is NextActor.USER
    (request,) = batch.request_facts
    assert request.state is ProviderRequestState.LIVE and request.next_actor is NextActor.USER
    assert request.request_kind is RequestKind.DIALOG
    assert mode_for_event(event) is AgentMode.WAITING_FOR_INPUT
    status = status_from_event(event)
    assert status.is_hard_ask and status.message == "Which repository?"

    normalized, event = _records(RESULT)
    assert normalized.event_name is ProviderEventName.ELICITATION_RESULT
    (resolved,) = _batch(normalized).request_facts
    assert resolved.key == request.key and resolved.state is ProviderRequestState.RESOLVED
    assert mode_for_event(event) is AgentMode.WORKING


def test_a_dialog_is_never_answered_in_place() -> None:
    # Neither a yes/no key nor a line of text fills an MCP form.
    contract = _registered_hook_source("claude").contract
    assert not answer_capability_for_request(contract, RequestKind.DIALOG).supported
    assert answer_capability_for_request(contract, RequestKind.INPUT).supported


@pytest.mark.parametrize(
    ("kind", "message"),
    [
        ("elicitation_dialog", "Claude Code needs your input"),
        ("elicitation_url_dialog", "An MCP server wants you to open a link"),
        ("agent_needs_input", "File sync is offline — your message is waiting"),
    ],
)
def test_dialog_notifications_wait_on_the_owner_by_name(kind: str, message: str) -> None:
    payload = {**BASE, "hook_event_name": "Notification", "notification_type": kind, "message": message}
    normalized, event = _records(payload)
    assert normalized.notification_kind is NotificationKind.INPUT_REQUIRED
    batch = _batch(normalized)
    # No request id to key on: a record's limit, never the source going quiet.
    assert batch.source_freshness is SourceFreshness.FRESH
    assert batch.work_facts[0].lifecycle is WorkLifecycle.WAITING
    assert batch.work_facts[0].next_actor is NextActor.USER
    assert notification_requests_input(event)
    assert mode_for_event(event) is AgentMode.WAITING_FOR_INPUT


def test_the_idle_nudge_is_still_not_an_input_notification() -> None:
    _normalized, event = _records(
        {**BASE, "hook_event_name": "Notification", "notification_type": "idle_prompt", "message": "Turn complete"}
    )
    assert not notification_requests_input(event)
    assert mode_for_event(event) is AgentMode.COMPLETED


def test_a_blocked_background_agent_asks_after_the_turn_ended() -> None:
    finished = status_from_event(_records({**BASE, "hook_event_name": "Stop"})[1])
    assert finished.mode is AgentMode.COMPLETED
    _normalized, blocked = _records(
        {**BASE, "hook_event_name": "Notification", "notification_type": "agent_needs_input",
         "message": "Explore needs your input: choose a branch"}
    )
    after = status_from_event(blocked)
    assert not should_ignore_status_transition(
        finished, after, set(), requests_input=notification_requests_input(blocked)
    )
    _normalized, nudge = _records(
        {**BASE, "hook_event_name": "Notification", "notification_type": "idle_prompt",
         "message": "Claude is waiting for your input"}
    )
    assert should_ignore_status_transition(
        finished, status_from_event(nudge), set(), requests_input=notification_requests_input(nudge)
    ), "the idle nudge after a Stop stays ignored"


def test_the_monitor_holds_the_dialog_as_a_live_ask_until_its_result() -> None:
    clock_offset = [0.0]

    def clock() -> ClockSample:
        return ClockSample(NOW.timestamp() + clock_offset[0], 100.0 + clock_offset[0], BootIdentifier("boot:elicit"))

    monitor = LiveAgentMonitor(clock_sampler=clock)
    for index, payload in enumerate(({**BASE, "hook_event_name": "UserPromptSubmit", "prompt": "go"}, ELICIT)):
        line = json.dumps({**payload, "logged_at": (NOW + timedelta(seconds=index)).isoformat()})
        clock_offset[0] = float(index) + 0.5
        monitor.ingest_record(parse_log_line("claude", line))
    snapshot = monitor.snapshot()
    (request,) = snapshot.operator_state.requests
    assert request.request_kind is RequestKind.DIALOG
    assert request.phase is RequestPhase.LIVE_UNACKNOWLEDGED and request.next_actor is NextActor.USER
    (status,) = snapshot.statuses
    assert status.is_hard_ask and status.request_key == request.key

    clock_offset[0] = 3.0
    monitor.ingest_record(
        parse_log_line("claude", json.dumps({**RESULT, "logged_at": (NOW + timedelta(seconds=2)).isoformat()}))
    )
    snapshot = monitor.snapshot()
    assert snapshot.operator_state.requests[0].phase is RequestPhase.RESOLVED
    (status,) = snapshot.statuses
    assert not status.is_hard_ask and status.mode is AgentMode.WORKING
