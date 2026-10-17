"""The reset delivery file stays bounded and never loses what is still owed."""

from __future__ import annotations

from pathlib import Path

from jrbar.provider_reset_events import (
    MAX_SETTLED_RESET_EVENTS,
    RESET_APP_FRESHNESS_SECONDS,
    ResetChannel,
    ResetChannelOutcome,
    ResetDeliverySettings,
    ResetDeliveryState,
    apply_app_receipt,
    apply_reset_channel_receipt,
    begin_reset_delivery,
    encode_reset_delivery_state,
    pending_reset_channels,
    prune_reset_delivery_state,
    reset_events_pending_app,
)
from jrbar.provider_usage_event_store import (
    RESET_STATE_SOFT_BYTES,
    load_reset_delivery_state,
    save_reset_delivery_state,
)
from jrbar.provider_usage_qol import ResetEvent

ALL_OFF = ResetDeliverySettings(False, False, False, False)


def _event(index: int) -> ResetEvent:
    return ResetEvent(
        event_id=f"codex:acct:weekly:{index:024x}",
        provider_id="codex",
        lane_id="weekly",
        label="Weekly reset",
        occurred_at=float(index),
        source_instance_id="acct",
        reset_boundary=float(index),
    )


def _finished(state: ResetDeliveryState, index: int, at: float) -> ResetDeliveryState:
    """A delivery the app has closed, with every channel off."""
    state = begin_reset_delivery(state, _event(index), ALL_OFF, now=at)
    return apply_app_receipt(state, _event(index).event_id, "delivered", "shown", now=at)


def test_finished_deliveries_are_trimmed_to_the_retention_bound() -> None:
    state = ResetDeliveryState()
    total = MAX_SETTLED_RESET_EVENTS + 40
    for index in range(total):
        state = _finished(state, index, 1_000.0 + index)
    assert len(state.events) == MAX_SETTLED_RESET_EVENTS
    # The newest survive; the oldest were dropped.
    assert state.events[-1].event_id == _event(total - 1).event_id
    assert state.events[0].event_id == _event(total - MAX_SETTLED_RESET_EVENTS).event_id


def test_an_open_delivery_is_never_trimmed() -> None:
    now = 1_000.0
    state = begin_reset_delivery(
        ResetDeliveryState(), _event(9999), ResetDeliverySettings(), now=now
    )
    # Many finished ones arrive after it, within the same delivery window.
    for index in range(MAX_SETTLED_RESET_EVENTS + 20):
        state = _finished(state, index, now + 1 + index * 0.001)
    ids = [event.event_id for event in state.events]
    assert _event(9999).event_id in ids
    assert pending_reset_channels(state, _event(9999).event_id, now=now + 2) != ()
    # An undelivered-to-the-app reset is open for the freshness window too.
    old = begin_reset_delivery(ResetDeliveryState(), _event(7), ALL_OFF, now=0.0)
    kept = prune_reset_delivery_state(
        old, now=RESET_APP_FRESHNESS_SECONDS - 1, keep_settled=0
    )
    assert reset_events_pending_app(kept, now=RESET_APP_FRESHNESS_SECONDS - 1)
    assert prune_reset_delivery_state(
        old, now=RESET_APP_FRESHNESS_SECONDS + 1, keep_settled=0
    ).events == ()


def test_waiting_candidates_survive_pruning() -> None:
    from jrbar.provider_usage_qol import ResetCandidate

    candidate = ResetCandidate(
        event_id="codex:acct:weekly:" + "a" * 24,
        provider_id="codex",
        source_instance_id="acct",
        lane_id="weekly",
        label="Weekly",
        reset_boundary=5.0,
        after_reset_at=10.0,
        after_remaining=99.0,
        before_remaining=5.0,
        observed_at=10.0,
    )
    state = ResetDeliveryState(candidates=(candidate,))
    for index in range(MAX_SETTLED_RESET_EVENTS + 5):
        state = _finished(state, index, 1_000.0 + index)
    assert state.candidates == (candidate,)


def test_an_oversized_old_file_loads_trimmed_and_not_empty(tmp_path: Path) -> None:
    target = tmp_path / "events.json"
    state = ResetDeliveryState()
    # Build a state far past the old 128 KB cap by bypassing retention.
    from dataclasses import replace

    events = []
    for index in range(1_200):
        built = _finished(ResetDeliveryState(), index, 1_000.0 + index)
        events.append(built.events[0])
    state = replace(state, events=tuple(events))
    payload = encode_reset_delivery_state(state)
    assert len(payload.encode()) > 128 * 1024
    target.write_text(payload)
    target.chmod(0o600)

    loaded = load_reset_delivery_state(target, now=50_000.0)

    assert loaded.events != ()
    assert len(loaded.events) == MAX_SETTLED_RESET_EVENTS
    assert loaded.events[-1].event_id == _event(1_199).event_id


def test_saving_keeps_the_file_under_the_soft_size(tmp_path: Path) -> None:
    target = tmp_path / "events.json"
    state = ResetDeliveryState()
    for index in range(MAX_SETTLED_RESET_EVENTS * 3):
        state = _finished(state, index, 1_000.0 + index)
        state = apply_reset_channel_receipt(
            state,
            _event(index).event_id,
            ResetChannel.OVERLAY,
            ResetChannelOutcome.DISCARDED,
            reason="x" * 100,
            now=1_000.0 + index,
        )
        save_reset_delivery_state(state, target, now=1_000.0 + index)
        assert target.stat().st_size <= RESET_STATE_SOFT_BYTES
    assert load_reset_delivery_state(target, now=5_000.0).events != ()
