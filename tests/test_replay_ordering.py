"""Event ordering survives replay, while activity ages from arrival."""
import json
from dataclasses import replace

import pytest

from jrbar.capacity_types import SourceKey
from jrbar.collector import LiveAgentMonitor, _operator_state_from_document, _state_to_document
from jrbar.hook_ingress import AppOwnedHookIngressProcessor
from jrbar.hook_ingress_protocol import HookIngressRequest
from jrbar.ipc import _hint_from_wire, _hint_to_payload, _replay_admission, _ReplayAdmission
from jrbar.operator_state import (
    BootIdentifier,
    ClockSample,
    active_work_went_silent,
    empty_operator_state,
    reduce_operator_state,
)
from jrbar.provider_facts import (
    EventToken,
    NextActor,
    ObservationAuthority,
    ProviderFactBatch,
    ProviderRequestFact,
    ProviderRequestState,
    ProviderWatermark,
    ProviderWorkFact,
    RequestIdentifier,
    RequestKey,
    RequestKind,
    SourceFreshness,
    SourceHealth,
    WatermarkBasis,
    WorkIdentifier,
    WorkKey,
    WorkLifecycle,
)

NOW = 1_800_000_000.0
SOURCE = SourceKey("codex", "hooks", "global", "live_agent_events")


def clock(wall=NOW, monotonic=10):
    return ClockSample(wall, monotonic, BootIdentifier("boot:replay"))


def batch(epoch, identity="session:one", lifecycle=WorkLifecycle.ACTIVE, request=None,
          authority=ObservationAuthority.DIRECT_PROVIDER_OBSERVATION):
    watermark = ProviderWatermark(SOURCE, WatermarkBasis.PROVIDER_EVENT_ID,
                                  epoch, EventToken(f"event:{identity}:{epoch}:{request}"), None, 10)
    key = WorkKey(SOURCE, WorkIdentifier(identity))
    requests = () if request is None else (ProviderRequestFact(
        RequestKey(key, RequestIdentifier("request:one")), request,
        RequestKind.PERMISSION, NextActor.USER if request is ProviderRequestState.LIVE else NextActor.NONE,
        watermark),)
    return ProviderFactBatch(SOURCE, authority, SourceHealth.HEALTHY, SourceFreshness.FRESH,
                            NOW, watermark,
                            (ProviderWorkFact(key, lifecycle, watermark, f"Codex {identity}", None,
                                              NextActor.PROVIDER),), requests, ())


def replay(state, incoming, admission=None, sampled=None):
    return reduce_operator_state(state, incoming, clock=sampled or clock(),
                                 _replay=admission or _replay_admission(incoming.watermark, NOW)).state


def seed(incoming):
    return reduce_operator_state(empty_operator_state(), incoming, clock=clock()).state


def test_recent_ingress_orders_same_session_and_preserves_second_session_arrival(tmp_path, monkeypatch):
    monkeypatch.setattr("time.time", lambda: NOW)
    monitor = LiveAgentMonitor(clock_sampler=clock)
    log = tmp_path / "codex.jsonl"
    processor = AppOwnedHookIngressProcessor(
        refresh_hint_handler=lambda hint: monitor.reconcile_refresh_hint(hint, log_path=log),
        appended_handler=lambda hint, appended: monitor.reconcile_appended_line(hint, appended, log_path=log),
        confine_to=tmp_path,
    )

    def deliver(name, identity, queued, token):
        processor(HookIngressRequest("codex", str(log), json.dumps({
            "hook_event_name": name, "session_id": identity, "event_id": token,
        }), queued_at_epoch=queued))

    deliver("Stop", "session:one", NOW - 20, "stop:one")
    deliver("UserPromptSubmit", "session:one", NOW - 600, "old:one")
    assert monitor.operator_state.works[0].lifecycle is WorkLifecycle.COMPLETED
    deliver("UserPromptSubmit", "session:two", NOW - 600, "old:two")
    second = next(work for work in monitor.operator_state.works if work.key.work_id.value == "session:two")
    assert second.lifecycle is WorkLifecycle.ACTIVE
    assert second.watermark.occurred_at_epoch == NOW - 600
    assert second.observed_at_epoch == NOW
    assert not active_work_went_silent(second, NOW)
    deliver("UserPromptSubmit", "session:one", NOW - 10, "new:one")
    assert next(work for work in monitor.operator_state.works if work.key.work_id.value == "session:one").lifecycle is WorkLifecycle.ACTIVE
    deliver("UserPromptSubmit", "session:history", NOW - 1801, "history")
    assert not any(work.key.work_id.value == "session:history" for work in monitor.operator_state.works)


def test_unopened_resolution_retains_order_without_materializing_request():
    resolved = batch(NOW - 10, request=ProviderRequestState.RESOLVED)
    state = seed(resolved)
    assert state.requests == ()
    assert len(state.request_order_marks) == 1
    state = replay(state, batch(NOW - 20, request=ProviderRequestState.LIVE))
    assert state.requests == ()


def test_replayed_request_age_starts_at_arrival():
    incoming = batch(NOW - 600, request=ProviderRequestState.LIVE)
    state = replay(empty_operator_state(), incoming)
    assert state.requests[0].opened_at_epoch == NOW
    assert state.requests[0].eligible_elapsed_seconds == 0
    assert state.requests[0].observed_at_epoch == NOW


def test_evicted_work_and_authority_remain_covered(monkeypatch):
    monkeypatch.setattr("jrbar.operator_state.MAX_CANONICAL_WORKS", 1)
    state = seed(batch(NOW - 100, lifecycle=WorkLifecycle.COMPLETED,
                       authority=ObservationAuthority.AUTHORITATIVE_PROVIDER))
    state = reduce_operator_state(state, batch(NOW - 10, "session:two",
                                  authority=ObservationAuthority.AUTHORITATIVE_PROVIDER), clock=clock()).state
    assert state.works[0].key.work_id.value == "session:two"
    assert state.source_order_floors
    state = replay(state, batch(NOW - 101))
    assert all(work.key.work_id.value != "session:one" for work in state.works)


def test_snapshot_round_trip_preserves_event_arrival_and_resolution_order():
    state = replay(empty_operator_state(), batch(NOW - 600, request=ProviderRequestState.RESOLVED))
    document = _state_to_document(state)
    assert document["version"] == 3
    restored, _ = _operator_state_from_document(document, restore_work_keys=())
    assert restored.works[0].observed_at_epoch == NOW
    assert restored.request_order_marks == state.request_order_marks
    restored = replay(restored, batch(NOW - 601, request=ProviderRequestState.LIVE))
    assert restored.requests == ()


def test_legacy_snapshot_unknown_older_identity_is_refused():
    document = _state_to_document(seed(batch(NOW - 10)))
    document["version"] = 2
    for field in ("work_order_marks", "request_order_marks", "source_order_floors"):
        document.pop(field)
    restored, _ = _operator_state_from_document(document, restore_work_keys=())
    restored = replay(restored, batch(NOW - 20, "session:unknown"))
    assert all(work.key.work_id.value != "session:unknown" for work in restored.works)


@pytest.mark.parametrize("kind", ["forged", "different_event", "expired", "lower_authority", "clock_jump"])
def test_replay_admission_does_not_bypass_other_guards(kind):
    state = seed(batch(NOW - 10))
    incoming = batch(NOW - 20, "session:two")
    admission = _replay_admission(incoming.watermark, NOW)
    sampled = clock()
    if kind == "forged":
        admission = _ReplayAdmission(incoming.watermark, NOW, object())
    elif kind == "different_event":
        admission = _replay_admission(batch(NOW - 21, "session:two").watermark, NOW)
    elif kind == "expired":
        admission = _replay_admission(incoming.watermark, NOW + 1801)
    elif kind == "lower_authority":
        incoming = replace(incoming, observation_authority=ObservationAuthority.FALLBACK_OBSERVATION)
    else:
        sampled = clock(NOW - 1, 11)
    state = replay(state, incoming, admission, sampled)
    assert all(work.key.work_id.value != "session:two" for work in state.works)


def test_ipc_round_trip_cannot_carry_replay_capability():
    from jrbar.ipc import ProviderRefreshHint
    incoming = batch(NOW - 20)
    hint = ProviderRefreshHint(SOURCE, incoming.watermark.event_token,
                               _replay_admission(incoming.watermark, NOW))
    payload = _hint_to_payload(hint)
    assert "_replay" not in payload
    decoded = _hint_from_wire(json.dumps(payload).encode())
    assert decoded is not None and decoded._replay is None
    payload["_replay"] = {"observed_at_epoch": NOW}
    assert _hint_from_wire(json.dumps(payload).encode()) is None


@pytest.mark.parametrize("restore", [False, True])
def test_resolution_order_survives_request_eviction_in_the_same_batch(monkeypatch, restore):
    monkeypatch.setattr("jrbar.operator_state.MAX_CANONICAL_REQUESTS", 1)
    state = seed(batch(NOW - 100, request=ProviderRequestState.LIVE))
    stop = batch(NOW - 10, lifecycle=WorkLifecycle.COMPLETED)
    other = batch(NOW - 10, "session:two", request=ProviderRequestState.LIVE)
    incoming = replace(stop, work_facts=stop.work_facts + other.work_facts,
                       request_facts=other.request_facts)
    state = reduce_operator_state(state, incoming, clock=clock()).state
    assert all(request.key.work_key.work_id.value != "session:one" for request in state.requests)
    assert state.source_order_floors or any(
        mark.watermark == stop.watermark
        for key, mark in state.request_order_marks if key.work_key.work_id.value == "session:one"
    )
    if restore:
        state, _ = _operator_state_from_document(_state_to_document(state), restore_work_keys=())
    state = replay(state, batch(NOW - 50, request=ProviderRequestState.LIVE))
    assert all(request.key.work_key.work_id.value != "session:one" for request in state.requests)


def test_first_seen_work_evicted_in_its_first_batch_remains_covered(monkeypatch):
    monkeypatch.setattr("jrbar.operator_state.MAX_CANONICAL_WORKS", 1)
    first = batch(NOW - 10, lifecycle=WorkLifecycle.COMPLETED)
    other = batch(NOW - 5, "session:two")
    incoming = replace(other, work_facts=first.work_facts + other.work_facts)
    state = seed(incoming)
    assert state.works[0].key.work_id.value == "session:two"
    state, _ = _operator_state_from_document(_state_to_document(state), restore_work_keys=())
    state = replay(state, batch(NOW - 20))
    assert all(work.key.work_id.value != "session:one" for work in state.works)


@pytest.mark.parametrize("wall,monotonic", [(NOW + 1801, 1811), (NOW - 1, 10)])
def test_replay_admission_expires_at_consumption_and_rejects_future_arrival(wall, monotonic):
    incoming = batch(NOW - 20, "session:unknown", request=ProviderRequestState.LIVE)
    admission = _replay_admission(incoming.watermark, NOW)
    state = reduce_operator_state(empty_operator_state(), incoming,
                                  clock=clock(wall, monotonic), _replay=admission).state
    assert state.requests == ()
    assert state.works == ()


def test_replay_consumption_checks_the_total_original_queue_horizon():
    incoming = batch(NOW - 1799, "session:unknown", request=ProviderRequestState.LIVE)
    admission = _replay_admission(incoming.watermark, NOW)
    state = reduce_operator_state(empty_operator_state(), incoming,
                                  clock=clock(NOW + 2, 12), _replay=admission).state
    assert state.requests == ()
    assert state.works == ()
    restored, _ = _operator_state_from_document(_state_to_document(state), restore_work_keys=())
    assert restored.requests == ()
    assert restored.works == ()
