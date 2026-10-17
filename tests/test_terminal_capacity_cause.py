"""Typed capacity outcomes survive replay without gaining transition authority."""

import json
from dataclasses import replace
from datetime import UTC, datetime

import pytest

from jrbar.capacity_types import SourceKey
from jrbar.collector import (
    AgentMonitor,
    SourceSpec,
    _batch_for_hook_record,
    _operator_state_from_document,
    _state_to_document,
    _work_from_payload,
    _work_to_payload,
    agent_status_from_canonical_work,
)
from jrbar.models import _CODEX_TRANSCRIPT_USAGE_LIMIT_PROVENANCE, AgentMode, HookEvent
from jrbar.operator_state import BootIdentifier, ClockSample, empty_operator_state, reduce_operator_state
from jrbar.provider_adapters import (
    NormalizedProviderRecord,
    minimize_hook_event,
    normalized_provider_record_from_payload,
    normalized_provider_record_to_payload,
    provider_facts_for_record,
)
from jrbar.provider_contracts import negotiate_provider_contract
from jrbar.provider_facts import ObservationAuthority, ProviderTerminalCause, WorkLifecycle
from jrbar.providers import parse_log_line

EPOCH = 1_800_000_000.0


def contract_for(provider):
    return negotiate_provider_contract({
        "schema_version": {"major": 1, "minor": 0}, "provider_id": provider,
        "adapter_id": "hooks", "source_instance_id": "global",
        "capabilities": [
            {"id": "live_agent_events", "versions": [{"major": 1, "minor": 0}]},
            {"id": "actionable_requests", "versions": [{"major": 1, "minor": 0}]},
        ],
    })


def record(provider="claude", error="rate_limit", *, event="StopFailure", epoch=EPOCH, provenance=None, session="fixture"):
    source = SourceKey(provider, "hooks", "global", "live_agent_events")
    hook = HookEvent(provider, datetime.fromtimestamp(epoch, UTC), event,
                     {"hook_event_name": event, "session_id": session, "error": error,
                      **({"request_id": "fixture-ask"} if event == "PermissionRequest" else {})},
                     session_id=session, _terminal_provenance=provenance)
    result = minimize_hook_event(hook, source_key=source, contract=contract_for(provider),
                                 observation_authority=ObservationAuthority.DIRECT_PROVIDER_OBSERVATION)
    assert isinstance(result, NormalizedProviderRecord)
    return result


def batch(normalized, *, authority=ObservationAuthority.DIRECT_PROVIDER_OBSERVATION):
    return provider_facts_for_record(normalized, contract=contract_for(normalized.source_key.provider_id),
                                     observation_authority=authority, observed_at_epoch=normalized.occurred_at_epoch)


def reduce(normalized, *, previous=None, authority=ObservationAuthority.DIRECT_PROVIDER_OBSERVATION):
    return reduce_operator_state(previous or empty_operator_state(), batch(normalized, authority=authority),
                                  clock=ClockSample(normalized.occurred_at_epoch,
                                                    100 + normalized.occurred_at_epoch - EPOCH,
                                                    BootIdentifier("boot:fixture"))).state


@pytest.mark.parametrize("provider,cause,provenance", [
    ("claude", ProviderTerminalCause.CLAUDE_RATE_LIMIT, None),
    ("codex", ProviderTerminalCause.CODEX_USAGE_LIMIT, _CODEX_TRANSCRIPT_USAGE_LIMIT_PROVENANCE),
])
def test_capacity_cause_survives_normalized_replay_and_saved_canonical_facade(provider, cause, provenance):
    original = record(provider, provenance=provenance)
    assert original.terminal_cause is cause
    payload = normalized_provider_record_to_payload(original)
    assert payload["terminal_cause"] == cause.value
    assert "error" not in payload and "_terminal_provenance" not in payload
    replayed = normalized_provider_record_from_payload(payload)
    assert replayed.terminal_cause is cause
    state = reduce(replayed)
    work = state.works[0]
    assert work.lifecycle is WorkLifecycle.FAILED and work.terminal_cause is cause
    saved = _work_to_payload(work)
    restored = _work_from_payload(saved)
    assert restored.terminal_cause is cause
    restored_state, _ = _operator_state_from_document(
        _state_to_document(state), restore_work_keys=(),
    )
    status = agent_status_from_canonical_work(restored_state.works[0])
    assert status.mode is AgentMode.BLOCKED_ERROR
    assert status.terminal_cause is cause and status.is_capacity_limited


@pytest.mark.parametrize("error", ["authentication_failed", "permission_error", "overloaded", "Rate_limit", "rate_limit exceeded", {"type": "rate_limit"}, None])
def test_claude_capacity_classification_accepts_only_the_exact_typed_hook_error(error):
    normalized = record(error=error)
    assert normalized.terminal_cause is ProviderTerminalCause.NONE
    assert not agent_status_from_canonical_work(reduce(normalized).works[0]).is_capacity_limited


def test_old_normalized_and_saved_work_shapes_remain_valid():
    normalized = record(error="authentication_failed")
    payload = normalized_provider_record_to_payload(normalized)
    assert "terminal_cause" not in payload
    assert normalized_provider_record_from_payload(payload).terminal_cause is ProviderTerminalCause.NONE
    work = reduce(normalized).works[0]
    saved = _work_to_payload(work)
    assert "terminal_cause" not in saved
    assert _work_from_payload(saved).terminal_cause is ProviderTerminalCause.NONE


@pytest.mark.parametrize("value", ["unknown", None, 1, "codex_usage_limit"])
def test_unknown_or_wrong_provider_causes_are_rejected(value):
    payload = normalized_provider_record_to_payload(record())
    payload["terminal_cause"] = value
    assert normalized_provider_record_from_payload(payload) is None
    saved = _work_to_payload(reduce(record()).works[0])
    saved["terminal_cause"] = value
    with pytest.raises(ValueError):
        _work_from_payload(saved)


def test_serialized_codex_cause_cannot_gain_private_transcript_authority():
    active = record("codex", event="UserPromptSubmit", epoch=EPOCH)
    previous = reduce(active)
    terminal = record("codex", epoch=EPOCH + 1, provenance=_CODEX_TRANSCRIPT_USAGE_LIMIT_PROVENANCE)
    assert batch(terminal).work_facts[0].has_codex_usage_limit_provenance
    trusted = reduce(terminal, previous=previous, authority=ObservationAuthority.FALLBACK_OBSERVATION)
    assert trusted.works[0].lifecycle is WorkLifecycle.FAILED
    decoded = normalized_provider_record_from_payload(normalized_provider_record_to_payload(terminal))
    assert decoded.terminal_cause is ProviderTerminalCause.CODEX_USAGE_LIMIT
    assert not batch(decoded).work_facts[0].has_codex_usage_limit_provenance
    untrusted = reduce(decoded, previous=previous, authority=ObservationAuthority.FALLBACK_OBSERVATION)
    assert untrusted.works[0].lifecycle is WorkLifecycle.ACTIVE


def test_raw_codex_hook_cannot_claim_private_usage_limit_provenance():
    normalized = record("codex", error="usage_limit_exceeded")
    assert normalized.terminal_cause is ProviderTerminalCause.NONE


def test_a_later_active_turn_clears_the_terminal_capacity_cause():
    failed = reduce(record())
    active = reduce(record(event="UserPromptSubmit", epoch=EPOCH + 1), previous=failed)
    assert active.works[0].terminal_cause is ProviderTerminalCause.NONE
    assert not agent_status_from_canonical_work(active.works[0]).is_capacity_limited


def test_unknown_fields_and_nonfailure_capacity_outcomes_are_rejected():
    payload = normalized_provider_record_to_payload(record())
    payload["private_provenance"] = True
    assert normalized_provider_record_from_payload(payload) is None
    saved = _work_to_payload(reduce(record()).works[0])
    saved["private_provenance"] = True
    with pytest.raises(ValueError):
        _work_from_payload(saved)
    with pytest.raises(ValueError):
        replace(reduce(record()).works[0], lifecycle=WorkLifecycle.ACTIVE)



def test_claude_capacity_failure_does_not_clear_another_sessions_real_ask():
    waiting = reduce(record(event="PermissionRequest", error=None, session="asking-fixture"))
    assert waiting.requests
    after = reduce(record(epoch=EPOCH + 1), previous=waiting)
    def semantic(request):
        return request.key, request.phase, request.next_actor, request.watermark
    assert tuple(map(semantic, after.requests)) == tuple(map(semantic, waiting.requests))
    failed = next(work for work in after.works if work.key.work_id.value == "fixture")
    assert failed.lifecycle is WorkLifecycle.FAILED
    assert failed.terminal_cause is ProviderTerminalCause.CLAUDE_RATE_LIMIT



def test_failed_event_retains_capacity_cause_after_a_prompt_clears_current_work():
    from jrbar.operator_state import TransitionKind, semantic_event_key_from_payload, semantic_event_key_to_payload

    terminal = record()
    first = reduce_operator_state(empty_operator_state(), batch(terminal),
                                  clock=ClockSample(EPOCH, 100, BootIdentifier("boot:fixture")))
    failure = next(event for event in first.events if event.kind is TransitionKind.FAILED)
    prompt = record(event="UserPromptSubmit", epoch=EPOCH + 1)
    later = reduce_operator_state(first.state, batch(prompt),
                                  clock=ClockSample(EPOCH + 1, 101, BootIdentifier("boot:fixture")))
    assert later.state.works[0].terminal_cause is ProviderTerminalCause.NONE
    combined_events = (*first.events, *later.events)
    retained = next(event for event in combined_events if event.kind is TransitionKind.FAILED)
    assert retained.terminal_cause is ProviderTerminalCause.CLAUDE_RATE_LIMIT
    assert retained.key == failure.key
    assert semantic_event_key_from_payload(semantic_event_key_to_payload(retained.key)) == retained.key
    assert all(event.terminal_cause is ProviderTerminalCause.NONE for event in later.events)


def test_authentication_failure_event_has_no_capacity_cause():
    from jrbar.operator_state import TransitionKind

    auth = record(error="authentication_failed")
    result = reduce_operator_state(empty_operator_state(), batch(auth),
                                   clock=ClockSample(EPOCH, 100, BootIdentifier("boot:fixture")))
    failure = next(event for event in result.events if event.kind is TransitionKind.FAILED)
    assert failure.terminal_cause is ProviderTerminalCause.NONE
    with pytest.raises(ValueError):
        replace(failure, terminal_cause="unknown")
    with pytest.raises(ValueError):
        replace(failure, terminal_cause=ProviderTerminalCause.CODEX_USAGE_LIMIT)



@pytest.mark.parametrize("provider,cause,provenance", [
    ("claude", ProviderTerminalCause.CLAUDE_RATE_LIMIT, None),
    ("codex", ProviderTerminalCause.CODEX_USAGE_LIMIT, _CODEX_TRANSCRIPT_USAGE_LIMIT_PROVENANCE),
])
def test_actual_log_parser_and_batch_keep_encoded_cause_without_private_authority(provider, cause, provenance):
    payload = normalized_provider_record_to_payload(record(provider, provenance=provenance))
    parsed = parse_log_line(provider, json.dumps(payload))
    assert parsed is not None and "error" not in parsed.raw
    replay_batch = _batch_for_hook_record(parsed, clock=ClockSample(EPOCH, 100, BootIdentifier("boot:fixture")))
    assert replay_batch is not None
    assert replay_batch.work_facts[0].terminal_cause is cause
    assert not replay_batch.work_facts[0].has_codex_usage_limit_provenance


def test_cold_agent_monitor_preserves_capacity_classification_from_normalized_file(tmp_path):
    log = tmp_path / "claude.jsonl"
    log.write_text(json.dumps(normalized_provider_record_to_payload(record())) + "\n")
    monitor = AgentMonitor(sources=(SourceSpec("claude", log),),
                           clock_sampler=lambda: ClockSample(EPOCH, 100, BootIdentifier("boot:fixture")))
    monitor.session_is_live = lambda *_a, **_k: False
    first = monitor.snapshot()
    assert first.operator_state.works[0].terminal_cause is ProviderTerminalCause.CLAUDE_RATE_LIMIT
    assert first.statuses[0].is_capacity_limited
    assert first.statuses[0].terminal_cause is ProviderTerminalCause.CLAUDE_RATE_LIMIT
    assert monitor.snapshot().operator_events == ()


@pytest.mark.parametrize("mutation", [
    {"terminal_cause": "unknown"},
    {"terminal_cause": "codex_usage_limit"},
    {"unexpected_field": True},
    {"source_instance_id": "other-profile"},
    {"adapter_id": "other-adapter"},
    {"provider_id": "codex"},
    {"hook_event_name": "PermissionRequest"},
    {"logged_at": "2027-01-15T08:00:00Z"},
])
def test_invalid_encoded_records_never_fall_back_to_generic_failed_statuses(tmp_path, mutation):
    payload = normalized_provider_record_to_payload(record()) | mutation
    line = json.dumps(payload)
    parsed = parse_log_line("claude", line)
    if parsed is not None:
        assert _batch_for_hook_record(parsed, clock=ClockSample(EPOCH, 100, BootIdentifier("boot:fixture"))) is None
    log = tmp_path / "claude.jsonl"
    log.write_text(line + "\n")
    monitor = AgentMonitor(sources=(SourceSpec("claude", log),),
                           clock_sampler=lambda: ClockSample(EPOCH, 100, BootIdentifier("boot:fixture")))
    monitor.session_is_live = lambda *_a, **_k: False
    result = monitor.snapshot()
    assert result.statuses == () and result.stale_statuses == ()
    assert result.operator_events == ()
