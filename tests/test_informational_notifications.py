"""A routine notification from one session never disturbs another session's ask.

Claude sends ``idle_prompt`` about a minute after every idle turn, and Grok
sends its own. The adapter names only the types that wait on the owner, so
these stay inert with their diagnostic. An inert batch used to read as the
whole provider source going quiet: the reducer opened a timing quarantine,
moved every live ask of every session to a stale hold, and dropped the next
hook event. These tests run the real reducer over synthetic sessions with
fixed stamps and no sleeps.
"""

from __future__ import annotations

from dataclasses import replace

from jrbar.operator_state import (
    BootIdentifier,
    CanonicalOperatorState,
    ClockSample,
    ReductionResult,
    RequestPhase,
    TransitionKind,
    empty_operator_state,
    reduce_operator_state,
)
from jrbar.provider_adapters import (
    InertProviderRecord,
    NormalizedProviderRecord,
    minimize_hook_event,
    normalized_provider_record_from_payload,
    normalized_provider_record_to_payload,
    provider_facts_for_record,
)
from jrbar.provider_contracts import DiagnosticIdentifier
from jrbar.provider_facts import (
    ObservationAuthority,
    ProviderFactBatch,
    ProviderFactDiagnostic,
    SourceFreshness,
    SourceHealth,
    WorkLifecycle,
)
from tests.test_provider_adapters import _EPOCH, _batch, _contract, _event, _source

_BASH = {"tool_input": {"command": "echo synthetic"}}


def _ingest(
    state: CanonicalOperatorState,
    provider: str,
    event_name: str,
    *,
    at: float,
    session: str,
    raw: dict[str, object] | None = None,
    tool_name: str | None = None,
) -> tuple[CanonicalOperatorState, ReductionResult]:
    event = _event(
        provider,
        event_name,
        epoch=_EPOCH + at,
        session_id=session,
        turn_id=f"turn:{session}",
        raw=raw,
        tool_name=tool_name,
    )
    _record, batch = _batch(event)
    clock = ClockSample(_EPOCH + at + 0.5, 100.0 + at, BootIdentifier("boot:01"))
    result = reduce_operator_state(state, batch, clock=clock)
    return result.state, result


def _kinds(result: ReductionResult) -> set[TransitionKind]:
    return {event.kind for event in result.events}


def _phases(state: CanonicalOperatorState) -> dict[str, RequestPhase]:
    return {item.key.work_key.work_id.value: item.phase for item in state.requests}


def _session_b_holds_a_live_permission_request() -> CanonicalOperatorState:
    """Session A works and session B waits on a Bash approval, at fixed stamps."""
    state = empty_operator_state()
    state, _ = _ingest(state, "claude", "UserPromptSubmit", at=0.0, session="session-a")
    state, _ = _ingest(state, "claude", "UserPromptSubmit", at=1.0, session="session-b")
    state, opened = _ingest(
        state,
        "claude",
        "PermissionRequest",
        at=2.0,
        session="session-b",
        raw=_BASH,
        tool_name="Bash",
    )
    assert TransitionKind.REQUEST_OPENED in _kinds(opened)
    assert set(_phases(state).values()) == {RequestPhase.LIVE_UNACKNOWLEDGED}
    return state


def test_an_idle_prompt_leaves_another_sessions_live_ask_alone() -> None:
    # --- scenario: an_idle_prompt_leaves_another_sessions_live_ask_alone
    """Session B waits on a Bash approval; session A's idle nudge arrives."""
    state = _session_b_holds_a_live_permission_request()

    state, idle = _ingest(
        state,
        "claude",
        "Notification",
        at=3.0,
        session="session-a",
        raw={"notification_type": "idle_prompt"},
    )

    assert set(_phases(state).values()) == {RequestPhase.LIVE_UNACKNOWLEDGED}
    assert state.timing_uncertain_sources == ()
    assert TransitionKind.SOURCE_DEGRADED not in _kinds(idle)

    # Answering in the terminal reaches the reducer on the very next hook.
    state, answered = _ingest(
        state,
        "claude",
        "PostToolUse",
        at=4.0,
        session="session-b",
        raw=_BASH,
        tool_name="Bash",
    )

    assert TransitionKind.REQUEST_RESOLVED in _kinds(answered)
    assert TransitionKind.BECAME_ACTIVE in _kinds(answered)
    assert set(_phases(state).values()) == {RequestPhase.RESOLVED}


def test_the_first_hook_after_an_idle_prompt_is_applied() -> None:
    # --- scenario: the_first_hook_after_an_idle_prompt_is_applied
    """A session that starts after an idle nudge shows Working on its first event."""
    state = empty_operator_state()
    state, _ = _ingest(state, "claude", "UserPromptSubmit", at=0.0, session="session-a")
    state, _ = _ingest(state, "claude", "Stop", at=1.0, session="session-a")
    state, _ = _ingest(
        state,
        "claude",
        "Notification",
        at=2.0,
        session="session-a",
        raw={"notification_type": "idle_prompt"},
    )

    state, started = _ingest(state, "claude", "UserPromptSubmit", at=3.0, session="session-c")

    assert TransitionKind.BECAME_ACTIVE in _kinds(started)
    assert {work.key.work_id.value for work in state.works} == {"session-a", "session-c"}


def test_grok_and_gemini_notifications_leave_a_live_ask_alone_too() -> None:
    # --- scenario: grok_and_gemini_notifications_leave_a_live_ask_alone_too
    """The fix lives in the batch, so every provider with an unmapped type gets it."""
    # Grok opens an ask with a typed Notification; Gemini has a PermissionRequest.
    cases = (
        ("grok", "Notification", {"notification_type": "permission_prompt"}, "idle_prompt"),
        ("gemini", "PermissionRequest", {}, "Other"),
    )
    for provider, open_event, open_raw, notification_type in cases:
        state = empty_operator_state()
        state, _ = _ingest(state, provider, "UserPromptSubmit", at=0.0, session="session-a")
        state, opened = _ingest(
            state,
            provider,
            open_event,
            at=1.0,
            session="session-a",
            raw={"request_id": "request:synthetic-01", **open_raw},
        )
        assert TransitionKind.REQUEST_OPENED in _kinds(opened), provider
        assert set(_phases(state).values()) == {RequestPhase.LIVE_UNACKNOWLEDGED}, provider

        state, idle = _ingest(
            state,
            provider,
            "Notification",
            at=2.0,
            session="session-b",
            raw={"notification_type": notification_type},
        )

        assert set(_phases(state).values()) == {RequestPhase.LIVE_UNACKNOWLEDGED}, provider
        assert state.timing_uncertain_sources == (), provider
        assert TransitionKind.SOURCE_DEGRADED not in _kinds(idle), provider


def test_a_real_loss_of_the_source_still_holds_the_ask() -> None:
    # --- scenario: a_real_loss_of_the_source_still_holds_the_ask
    """The fence is intact: other inert records and an unavailable source still quarantine."""
    source = _source("claude")
    contract = _contract("claude")
    for kind in ("malformed", "unavailable"):
        state = _session_b_holds_a_live_permission_request()
        if kind == "malformed":
            # A record that names no valid session identity is a real loss.
            event = _event(
                "claude",
                "Notification",
                epoch=_EPOCH + 3.0,
                session_id="session-a",
                raw={"notification_type": "idle_prompt"},
            )
            record = minimize_hook_event(
                event,
                source_key=source,
                contract=contract,
                observation_authority=ObservationAuthority.DIRECT_PROVIDER_OBSERVATION,
            )
            assert type(record) is InertProviderRecord
            record = InertProviderRecord(
                record.source_key,
                record.occurred_at_epoch,
                _diagnostic("invalid_provider_identity"),
            )
            batch = provider_facts_for_record(
                record,
                contract=contract,
                observation_authority=ObservationAuthority.DIRECT_PROVIDER_OBSERVATION,
                observed_at_epoch=_EPOCH + 3.25,
            )
        else:
            _record, healthy = _batch(
                _event(
                    "claude",
                    "Notification",
                    epoch=_EPOCH + 3.0,
                    session_id="session-a",
                    raw={"notification_type": "idle_prompt"},
                )
            )
            batch = _with_health(healthy, SourceHealth.UNAVAILABLE, SourceFreshness.PARTIAL)

        clock = ClockSample(_EPOCH + 3.5, 103.0, BootIdentifier("boot:01"))
        result = reduce_operator_state(state, batch, clock=clock)

        assert set(_phases(result.state).values()) == {RequestPhase.STALE_HOLD}, kind
        assert TransitionKind.SOURCE_DEGRADED in _kinds(result), kind


def test_a_replayed_unknown_notification_record_is_healthy() -> None:
    # --- scenario: a_replayed_unknown_notification_record_is_healthy
    """A ledger line written before this fix decodes and reduces without a quarantine."""
    event = _event(
        "claude",
        "Notification",
        epoch=_EPOCH,
        raw={"notification_type": "idle_prompt"},
    )
    record = minimize_hook_event(
        event,
        source_key=_source("claude"),
        contract=_contract("claude"),
        observation_authority=ObservationAuthority.DIRECT_PROVIDER_OBSERVATION,
    )
    assert type(record) is InertProviderRecord

    replayed = normalized_provider_record_from_payload(
        normalized_provider_record_to_payload(record)
    )

    assert type(replayed) is InertProviderRecord
    assert type(replayed) is not NormalizedProviderRecord
    batch = provider_facts_for_record(
        replayed,
        contract=_contract("claude"),
        observation_authority=ObservationAuthority.DIRECT_PROVIDER_OBSERVATION,
        observed_at_epoch=_EPOCH + 0.25,
    )
    assert batch.source_health is SourceHealth.HEALTHY
    assert batch.source_freshness is SourceFreshness.FRESH
    assert batch.work_facts == () and batch.request_facts == ()
    assert tuple(item.identifier.value for item in batch.diagnostics) == (
        "unknown_notification_kind",
    )


def test_a_notification_alone_does_not_end_a_sessions_work() -> None:
    # --- scenario: a_notification_alone_does_not_end_a_sessions_work
    """An informational notification names no lifecycle, so the work stays as it was."""
    state = empty_operator_state()
    state, _ = _ingest(state, "claude", "UserPromptSubmit", at=0.0, session="session-a")
    state, idle = _ingest(
        state,
        "claude",
        "Notification",
        at=1.0,
        session="session-a",
        raw={"notification_type": "idle_prompt"},
    )

    (work,) = state.works
    assert work.lifecycle is WorkLifecycle.ACTIVE
    assert work.source_health is SourceHealth.HEALTHY
    assert work.timing_uncertain is False
    assert _kinds(idle) == set()


def _diagnostic(identifier: str) -> ProviderFactDiagnostic:
    return ProviderFactDiagnostic(DiagnosticIdentifier(identifier), 1)


def _with_health(
    batch: ProviderFactBatch,
    health: SourceHealth,
    freshness: SourceFreshness,
) -> ProviderFactBatch:
    return replace(batch, source_health=health, source_freshness=freshness)
