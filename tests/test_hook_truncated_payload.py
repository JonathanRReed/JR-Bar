"""The daemon reads the shim's record for an oversize payload as the event it names.

The compiled shim (hook/jrbar-hook.c) cannot forward a payload past 1 MiB. It
hands the daemon the event, the session, the tool and ``"payload_truncated":
true`` instead (tests/test_hook_shim_oversize.py covers that side). Here the
daemon's half: that record is a PostToolUse that resolves the request its ask
opened, a PermissionRequest that is shown as an ask, and an ask that is never
parked for a verdict, because its input cannot be shown to the person deciding.
"""

from __future__ import annotations

import json
from pathlib import Path

from jrbar.answer_decisions import DecisionBroker, permission_facts
from jrbar.hook import HookProcessingOutcome, process_hook_payload
from jrbar.hook_ingress import HookIngressService
from jrbar.hook_ingress_protocol import HookIngressRequest
from jrbar.models import HookEvent
from jrbar.operator_state import (
    BootIdentifier,
    ClockSample,
    RequestPhase,
    empty_operator_state,
    reduce_operator_state,
)
from jrbar.provider_facts import ProviderRequestState, WorkLifecycle
from jrbar.providers import parse_log_line
from jrbar.hook import routed_hook_payload
from tests.test_provider_adapters import _batch

BOOT = BootIdentifier("boot:01")
LARGE_INPUT = {"file_path": "/Users/me/demo/big.txt", "content": "x" * 64}
SMALL_INPUT = {"url": "https://example.test/", "full_page": True}


def _payload(event: str, **fields: object) -> dict[str, object]:
    document: dict[str, object] = {
        "hook_event_name": event,
        "session_id": "session-1",
        "tool_name": "mcp__shots__capture",
        "tool_input": SMALL_INPUT,
    }
    document.update(fields)
    return {key: value for key, value in document.items() if value is not None}


def _truncated(event: str, **fields: object) -> dict[str, object]:
    return _payload(event, payload_truncated=True, **fields)


def _event(provider: str, payload: dict[str, object]) -> HookEvent:
    actual, _, line = routed_hook_payload(provider, Path("/tmp/jrbar-test.jsonl"), json.dumps(payload))
    event = parse_log_line(actual, json.dumps(line))
    assert event is not None
    return event


def _facts(provider: str, payload: dict[str, object]):
    normalized, batch = _batch(_event(provider, payload))
    return normalized, batch


def test_a_truncated_post_tool_use_resolves_the_request_its_ask_opened() -> None:
    """The ask was small; the PostToolUse carried a megabyte of screenshot. The
    record keeps the call's own input, so it names the same request."""
    ask_record, ask = _facts("claude", _payload("PermissionRequest"))
    done_record, done = _facts("claude", _truncated("PostToolUse", tool_response=None))
    assert len(ask.request_facts) == 1 and len(done.request_facts) == 1
    assert ask.request_facts[0].state is ProviderRequestState.LIVE
    assert done.request_facts[0].state is ProviderRequestState.RESOLVED
    assert done.request_facts[0].key == ask.request_facts[0].key
    assert done.work_facts[0].lifecycle is WorkLifecycle.ACTIVE

    # Through the reducer: the ask is live, then the record closes it.
    opened = reduce_operator_state(
        empty_operator_state(), ask, clock=ClockSample(ask.observed_at_epoch, 100.0, BOOT)
    )
    assert [request.phase for request in opened.state.requests] == [RequestPhase.LIVE_UNACKNOWLEDGED]
    closed = reduce_operator_state(
        opened.state, done, clock=ClockSample(done.observed_at_epoch + 1.0, 101.0, BOOT)
    )
    assert [request.phase for request in closed.state.requests] == [RequestPhase.RESOLVED]
    assert ask_record.provider_request_id == done_record.provider_request_id


def test_an_oversize_ask_and_its_oversize_post_tool_use_name_the_same_request() -> None:
    """A very large Write: the shim could not keep the input for either, so both
    records say only that it was cut down. The ask is still shown, as an ask."""
    _, ask = _facts("claude", _truncated("PermissionRequest", tool_name="Write", tool_input=None))
    assert len(ask.request_facts) == 1, "an oversize ask is not shown"
    assert ask.request_facts[0].state is ProviderRequestState.LIVE
    assert ask.work_facts[0].lifecycle is WorkLifecycle.WAITING
    assert [item.identifier.value for item in ask.diagnostics] == []

    _, done = _facts("claude", _truncated("PostToolUse", tool_name="Write", tool_input=None))
    assert done.request_facts[0].state is ProviderRequestState.RESOLVED
    assert done.request_facts[0].key == ask.request_facts[0].key

    # Another tool, or another turn, is another question.
    _, other_tool = _facts("claude", _truncated("PermissionRequest", tool_name="Edit", tool_input=None))
    assert other_tool.request_facts[0].key != ask.request_facts[0].key
    _, turn_a = _facts("codex", _truncated("PermissionRequest", tool_name="apply_patch", tool_input=None, turn_id="turn-1"))
    _, turn_b = _facts("codex", _truncated("PermissionRequest", tool_name="apply_patch", tool_input=None, turn_id="turn-2"))
    assert turn_a.request_facts[0].key != turn_b.request_facts[0].key


def test_a_cut_down_ask_is_not_the_same_request_as_one_that_kept_its_input() -> None:
    _, kept = _facts("claude", _truncated("PermissionRequest", tool_name="Write", tool_input=LARGE_INPUT))
    _, cut = _facts("claude", _truncated("PermissionRequest", tool_name="Write", tool_input=None))
    assert kept.request_facts[0].key != cut.request_facts[0].key
    # And a payload that was never cut down needs no marker to stay itself.
    _, plain = _facts("claude", _payload("PermissionRequest", tool_name="Write", tool_input=LARGE_INPUT))
    assert plain.request_facts[0].key == kept.request_facts[0].key


def test_a_truncated_ask_is_never_parked_for_a_verdict() -> None:
    assert permission_facts("claude", json.dumps(_payload("PermissionRequest"))) is not None
    assert permission_facts("claude", json.dumps(_truncated("PermissionRequest"))) is None
    assert permission_facts("claude", json.dumps(_truncated("PermissionRequest", tool_input=None))) is None
    assert permission_facts("codex", json.dumps(_truncated("PermissionRequest", turn_id="t"))) is None


def test_the_ingress_does_not_park_a_truncated_ask_even_when_it_asks_to_be_held(tmp_path: Path) -> None:
    broker = DecisionBroker(watching=lambda _facts, _pid: False)
    service = HookIngressService(
        process=lambda _request: None,
        socket_path=tmp_path / "hook-ingress.sock",
        rejection_path=tmp_path / "rejections.jsonl",
        decision_broker=broker,
    )

    def request(document: dict[str, object]) -> HookIngressRequest:
        return HookIngressRequest(
            "claude",
            str(tmp_path / "claude.jsonl"),
            json.dumps(document),
            ppid=4242,
            decide_ms=50_000,
        )

    held = service._park_decision(request(_payload("PermissionRequest")))
    assert held is not None, "the control request was not parked"
    assert service._park_decision(request(_truncated("PermissionRequest"))) is None
    assert service._park_decision(request(_truncated("PermissionRequest", tool_input=None))) is None
    assert len(broker._slots) == 1  # only the control


def test_a_truncated_post_tool_use_lets_go_of_the_hold_on_its_request() -> None:
    broker = DecisionBroker(watching=lambda _facts, _pid: False)
    facts = permission_facts("claude", json.dumps(_payload("PermissionRequest")))
    assert facts is not None
    slot = broker.park(facts, wait_limit_seconds=50.0)
    assert slot is not None
    assert broker.observe("claude", json.dumps(_truncated("PostToolUse"))) == 1


def test_the_record_is_written_to_the_log_as_the_event_it_names(tmp_path: Path) -> None:
    log = tmp_path / "claude.jsonl"
    for document in (
        _payload("PermissionRequest", tool_name="Write", tool_input=None, payload_truncated=True),
        _payload("PostToolUse", tool_name="Write", tool_input=None, payload_truncated=True),
    ):
        outcome = process_hook_payload("claude", log, json.dumps(document), refresh=False)
        assert outcome is HookProcessingOutcome.WRITTEN
    rows = [json.loads(line) for line in log.read_text().splitlines()]
    assert [row["event_name"] for row in rows] == ["permission_request", "post_tool_use"]
    assert rows[0]["provider_request_id"].startswith("derived:")
    assert rows[0]["provider_request_id"] == rows[1]["provider_request_id"]
    assert all(row["provider_work_id"] == "session-1" for row in rows)
    assert "payload_truncated" not in log.read_text(), "the marker is not content to keep"
