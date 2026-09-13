from __future__ import annotations

from dataclasses import replace

import pytest

from jrbar.provider_reset_events import (
    RESET_DELIVERY_PRIORITY,
    ResetChannel,
    ResetChannelOutcome,
    ResetDeliverySettings,
    ResetDeliveryState,
    apply_reset_channel_receipt,
    begin_reset_delivery,
    decode_reset_delivery_state,
    encode_reset_delivery_state,
    next_reset_retry_delay,
    pending_reset_channels,
    reset_event_is_terminal,
)
from jrbar.provider_usage_qol import ResetEvent


def _event(event_id: str = "claude:acct:weekly:boundary") -> ResetEvent:
    return ResetEvent(
        event_id=event_id,
        provider_id="claude",
        lane_id="weekly",
        label="Weekly reset",
        occurred_at=1_000.0,
        source_instance_id="acct",
        reset_boundary=900.0,
    )


def test_each_channel_is_independently_enabled_and_receipted__and_2_more() -> None:
    # --- scenario: each_channel_is_independently_enabled_and_receipted
    state = begin_reset_delivery(
        ResetDeliveryState(),
        _event(),
        ResetDeliverySettings(
            overlay=True,
            hardware=False,
            notification=True,
            sound=False,
        ),
        now=1_000.0,
    )

    assert pending_reset_channels(state, _event().event_id, now=1_000.0) == (
        ResetChannel.OVERLAY,
        ResetChannel.NOTIFICATION,
    )
    receipts = state.events[0].receipts
    assert [(item.channel, item.outcome, item.reason) for item in receipts] == [
        (ResetChannel.HARDWARE, ResetChannelOutcome.SUPPRESSED, "disabled"),
        (ResetChannel.SOUND, ResetChannelOutcome.SUPPRESSED, "disabled"),
    ]

    # --- scenario: suppressed_and_failed_enabled_channels_retry_through_299_seconds
    state = begin_reset_delivery(
        ResetDeliveryState(), _event(), ResetDeliverySettings(), now=1_000.0
    )
    state = apply_reset_channel_receipt(
        state,
        _event().event_id,
        ResetChannel.OVERLAY,
        ResetChannelOutcome.SUPPRESSED,
        reason="display_suppressed",
        now=1_001.0,
    )
    state = apply_reset_channel_receipt(
        state,
        _event().event_id,
        ResetChannel.HARDWARE,
        ResetChannelOutcome.FAILED,
        reason="device_busy",
        now=1_001.0,
    )

    assert ResetChannel.OVERLAY in pending_reset_channels(
        state, _event().event_id, now=1_299.0
    )
    assert ResetChannel.HARDWARE in pending_reset_channels(
        state, _event().event_id, now=1_299.0
    )
    assert not reset_event_is_terminal(state, _event().event_id)

    # --- scenario: pending_channels_are_discarded_at_exactly_300_seconds
    state = begin_reset_delivery(
        ResetDeliveryState(), _event(), ResetDeliverySettings(), now=1_000.0
    )

    state, pending = pending_reset_channels(
        state, _event().event_id, now=1_300.0, record_discards=True
    )

    assert pending == ()
    assert reset_event_is_terminal(state, _event().event_id)
    assert all(
        receipt.outcome is ResetChannelOutcome.DISCARDED
        and receipt.reason == "delivery_window_expired"
        for receipt in state.events[0].receipts
    )



def test_duplicate_provider_account_window_boundary_is_not_reopened__and_2_more() -> None:
    # --- scenario: duplicate_provider_account_window_boundary_is_not_reopened
    state = begin_reset_delivery(
        ResetDeliveryState(), _event(), ResetDeliverySettings(), now=1_000.0
    )
    duplicate = replace(_event("different-untrusted-id"))
    state2 = begin_reset_delivery(
        state, duplicate, ResetDeliverySettings(), now=1_001.0
    )

    assert state2 == state

    # --- scenario: pending_delivery_survives_a_persistence_round_trip
    state = begin_reset_delivery(
        ResetDeliveryState(), _event(), ResetDeliverySettings(), now=1_000.0
    )
    restored = decode_reset_delivery_state(encode_reset_delivery_state(state))

    assert restored == state
    assert pending_reset_channels(restored, _event().event_id, now=1_299.0)

    # --- scenario: visual_suppression_leaves_nonvisual_fallback_pending
    state = begin_reset_delivery(
        ResetDeliveryState(), _event(), ResetDeliverySettings(), now=1_000.0
    )
    state = apply_reset_channel_receipt(
        state,
        _event().event_id,
        ResetChannel.OVERLAY,
        ResetChannelOutcome.SUPPRESSED,
        reason="display_suppressed",
        now=1_001.0,
    )

    pending = pending_reset_channels(state, _event().event_id, now=1_001.0)
    assert any(
        channel in pending
        for channel in (
            ResetChannel.HARDWARE,
            ResetChannel.NOTIFICATION,
            ResetChannel.SOUND,
        )
    )



def test_seen_requires_terminal_delivery_or_expiry_not_an_attempt__and_2_more() -> None:
    # --- scenario: seen_requires_terminal_delivery_or_expiry_not_an_attempt
    state = begin_reset_delivery(
        ResetDeliveryState(), _event(), ResetDeliverySettings(), now=1_000.0
    )
    state = apply_reset_channel_receipt(
        state,
        _event().event_id,
        ResetChannel.NOTIFICATION,
        ResetChannelOutcome.DELIVERED,
        reason="posted",
        now=1_001.0,
    )

    assert not reset_event_is_terminal(state, _event().event_id)

    # --- scenario: reset_delivery_priority_has_the_required_ordering
    assert RESET_DELIVERY_PRIORITY["input"] > RESET_DELIVERY_PRIORITY["reset"]
    assert RESET_DELIVERY_PRIORITY["failure"] > RESET_DELIVERY_PRIORITY["reset"]
    assert RESET_DELIVERY_PRIORITY["quota_exhaustion"] > RESET_DELIVERY_PRIORITY["reset"]
    assert RESET_DELIVERY_PRIORITY["reset"] > RESET_DELIVERY_PRIORITY["completion"]
    assert RESET_DELIVERY_PRIORITY["reset"] > RESET_DELIVERY_PRIORITY["quota_warning"]
    assert RESET_DELIVERY_PRIORITY["reset"] > RESET_DELIVERY_PRIORITY["idle"]

    # --- scenario: retry_delay_runs_independently_and_reaches_exact_expiry
    state = begin_reset_delivery(
        ResetDeliveryState(), _event(), ResetDeliverySettings(), now=1_000.0
    )
    assert next_reset_retry_delay(state, now=1_001.0) == 15.0
    assert next_reset_retry_delay(state, now=1_299.9) == pytest.approx(0.1)
    assert next_reset_retry_delay(state, now=1_300.0) is None



def test_quota_reset_wire_event_carries_the_lane__and_1_more() -> None:
    # --- scenario: quota_reset_wire_event_carries_the_lane
    """The app's confetti fires on the weekly lane only -- dropping
    ``lane`` from the publish would silence it, and conflating lanes
    would fire it on the five-hour window."""
    from types import SimpleNamespace

    from jrbar.provider_usage_status_bar import _publish_reset_wire_events

    sent = []
    controller = SimpleNamespace(
        _core_publish_event=lambda kind, **fields: sent.append((kind, fields))
    )
    events = (
        _event(),
        replace(_event("claude:acct:five-hour:boundary"), lane_id="five-hour"),
    )
    _publish_reset_wire_events(controller, events)

    assert sent == [
        (
            "quota_reset",
            {
                "provider": "claude",
                "instance": "acct",
                "label": "Weekly reset",
                "lane": "weekly",
            },
        ),
        (
            "quota_reset",
            {
                "provider": "claude",
                "instance": "acct",
                "label": "Weekly reset",
                "lane": "five-hour",
            },
        ),
    ]

    # --- scenario: reset_wire_events_skip_a_host_without_core_publish
    """The legacy menu host has no ``_core_publish_event`` -- nothing to send."""
    from types import SimpleNamespace

    from jrbar.provider_usage_status_bar import _publish_reset_wire_events

    _publish_reset_wire_events(SimpleNamespace(), (_event(),))

    # And one bad event must not block the rest.
    sent = []
    controller = SimpleNamespace(
        _core_publish_event=lambda kind, **fields: sent.append((kind, fields))
    )
    class _Broken:
        provider_id = "claude"
        source_instance_id = "acct"
        label = "Weekly reset"

        @property
        def lane_id(self):
            raise RuntimeError("boom")

    broken = _Broken()
    _publish_reset_wire_events(controller, (broken, _event()))
    assert [kind for kind, _fields in sent] == ["quota_reset"]

