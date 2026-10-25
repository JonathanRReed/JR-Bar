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
    """Every confirmed quota window retains its lane and stable delivery ID."""
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
                "event_id": "claude:acct:weekly:boundary",
            },
        ),
        (
            "quota_reset",
            {
                "provider": "claude",
                "instance": "acct",
                "label": "Weekly reset",
                "lane": "five-hour",
                "event_id": "claude:acct:five-hour:boundary",
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


def test_app_receipts_close_the_replay_offer__and_2_more() -> None:
    from jrbar.provider_reset_events import (
        RESET_APP_FRESHNESS_SECONDS,
        apply_app_receipt,
        reset_events_pending_app,
    )

    # --- scenario: a fresh unacknowledged reset is re-offered to the app
    state = begin_reset_delivery(
        ResetDeliveryState(), _event(), ResetDeliverySettings(), now=1_000.0
    )
    assert [
        event.event_id for event in reset_events_pending_app(state, now=2_000.0)
    ] == [_event().event_id]

    # --- scenario: held, expired and suppressed stay re-offerable; delivered and dropped close it
    for outcome in ("held", "expired", "suppressed"):
        updated = apply_app_receipt(
            state, _event().event_id, outcome, "room", now=2_100.0
        )
        pending = reset_events_pending_app(updated, now=2_200.0)
        assert pending and pending[0].app_receipts[-1].outcome == outcome
    for outcome in ("delivered", "dropped"):
        closed = apply_app_receipt(
            state, _event().event_id, outcome, "done", now=2_100.0
        )
        assert reset_events_pending_app(closed, now=2_200.0) == ()

    # --- scenario: the freshness window bounds what is still newsworthy
    edge = 1_000.0 + RESET_APP_FRESHNESS_SECONDS
    assert reset_events_pending_app(state, now=edge - 1.0)
    assert reset_events_pending_app(state, now=edge) == ()


@pytest.mark.parametrize("outcome", ["delivered", "dropped"])
def test_terminal_app_receipt_survives_late_receipts_and_persistence(outcome) -> None:
    from jrbar.provider_reset_events import (
        MAX_APP_RECEIPTS,
        apply_app_receipt,
        reset_events_pending_app,
    )

    state = begin_reset_delivery(
        ResetDeliveryState(), _event(), ResetDeliverySettings(), now=1_000.0
    )
    state = apply_app_receipt(state, _event().event_id, outcome, "finished", now=1_001.0)
    for index in range(MAX_APP_RECEIPTS + 1):
        state = apply_app_receipt(
            state, _event().event_id, "held", "late receipt", now=1_002.0 + index
        )
    restored = decode_reset_delivery_state(encode_reset_delivery_state(state))
    assert reset_events_pending_app(restored, now=1_100.0) == ()
    assert [receipt.outcome for receipt in restored.events[0].app_receipts] == [outcome]


def test_app_receipt_validates_and_survives_persistence__and_1_more() -> None:
    import json

    from jrbar.provider_reset_events import apply_app_receipt

    state = begin_reset_delivery(
        ResetDeliveryState(), _event(), ResetDeliverySettings(), now=1_000.0
    )
    with pytest.raises(KeyError):
        apply_app_receipt(state, "nope", "delivered", "ok", now=1_100.0)
    with pytest.raises(ValueError):
        apply_app_receipt(state, _event().event_id, "shrug", "ok", now=1_100.0)
    with pytest.raises(ValueError):
        apply_app_receipt(state, _event().event_id, "held", "", now=1_100.0)

    state = apply_app_receipt(
        state, _event().event_id, "held", "call", now=1_100.0
    )
    restored = decode_reset_delivery_state(encode_reset_delivery_state(state))
    assert restored == state

    # --- scenario: a file from before app receipts decodes with none
    document = json.loads(encode_reset_delivery_state(state))
    for item in document["events"]:
        item.pop("app_receipts", None)
    older = decode_reset_delivery_state(json.dumps(document))
    assert older.events[0].app_receipts == ()


def test_replay_documents_and_app_receipt_round_trip() -> None:
    from types import SimpleNamespace

    from jrbar.provider_reset_settings_action import (
        apply_app_reset_receipt,
        reset_replay_documents,
    )

    state = begin_reset_delivery(
        ResetDeliveryState(), _event(), ResetDeliverySettings(), now=1_000.0
    )
    saved = []
    controller = SimpleNamespace(
        _jrbar_reset_delivery_state=state,
        _persist_reset_delivery_state=lambda: saved.append(
            controller._jrbar_reset_delivery_state
        ),
    )
    assert reset_replay_documents(controller, now=2_000.0) == [
        {
            "kind": "quota_reset",
            "provider": "claude",
            "instance": "acct",
            "lane": "weekly",
            "event_id": _event().event_id,
            "id": _event().event_id,
            "at": 1_000.0,
            "notify": False,
        }
    ]

    assert apply_app_reset_receipt(
        controller, _event().event_id, "delivered", "presented"
    ) == {"recorded": True, "persistence": None}
    assert saved[-1].events[0].app_receipts[-1].outcome == "delivered"
    assert reset_replay_documents(controller, now=2_000.0) == []


def test_reset_receipt_command_records_the_verdict__and_1_more() -> None:
    from types import SimpleNamespace

    from jrbar import core_runtime
    from jrbar.core_server import CommandError

    state = begin_reset_delivery(
        ResetDeliveryState(), _event(), ResetDeliverySettings(), now=1_000.0
    )
    controller = SimpleNamespace(
        _jrbar_reset_delivery_state=state,
        _persist_reset_delivery_state=lambda: None,
        _core_log=lambda message: None,
    )
    assert core_runtime._cmd_reset_receipt(
        controller,
        {"event_id": _event().event_id, "outcome": "held", "reason": "call"},
    ) == {"recorded": True, "persistence": None}
    receipts = controller._jrbar_reset_delivery_state.events[0].app_receipts
    assert (receipts[-1].outcome, receipts[-1].reason) == ("held", "call")

    # --- scenario: bad args and unknown events are honest refusals
    with pytest.raises(CommandError) as missing_id:
        core_runtime._cmd_reset_receipt(controller, {"outcome": "delivered"})
    assert missing_id.value.code == "invalid_args"
    with pytest.raises(CommandError) as unknown:
        core_runtime._cmd_reset_receipt(
            controller, {"event_id": "nope", "outcome": "delivered"}
        )
    assert unknown.value.code == "not_found"
    with pytest.raises(CommandError) as bad_outcome:
        core_runtime._cmd_reset_receipt(
            controller, {"event_id": _event().event_id, "outcome": "shrug"}
        )
    assert bad_outcome.value.code == "invalid_args"



def test_a_channel_receipt_keeps_what_the_app_reported() -> None:
    from jrbar.provider_reset_events import (
        ResetChannel,
        ResetChannelOutcome,
        apply_app_receipt,
        apply_reset_channel_receipt,
    )

    state = begin_reset_delivery(
        ResetDeliveryState(), _event(), ResetDeliverySettings(), now=1_000.0
    )
    state = apply_app_receipt(state, _event().event_id, "held", "call", now=1_010.0)
    state = apply_reset_channel_receipt(
        state,
        _event().event_id,
        ResetChannel.OVERLAY,
        ResetChannelOutcome.DELIVERED,
        reason="effect_scheduled",
        now=1_020.0,
    )
    receipts = state.events[0].app_receipts
    assert [(r.outcome, r.reason) for r in receipts] == [("held", "call")]


def test_same_window_boundary_keeps_distinct_proven_accounts_after_reload():
    from jrbar.provider_reset_events import apply_app_receipt, reset_events_pending_app
    from jrbar.provider_usage_qol import _event_id

    def account_event(account):
        return replace(_event(), event_id=_event_id("claude", "acct", "weekly", 900.0, account),
                       account_discriminator=account)

    first = account_event("synthetic-account-a")
    second = account_event("synthetic-account-b")
    state = begin_reset_delivery(ResetDeliveryState(), first, ResetDeliverySettings(), now=1_000.0)
    state = apply_reset_channel_receipt(state, first.event_id, ResetChannel.OVERLAY,
                                      ResetChannelOutcome.DELIVERED, reason="shown", now=1_001.0)
    state = apply_app_receipt(state, first.event_id, "delivered", "presented", now=1_001.0)
    state = decode_reset_delivery_state(encode_reset_delivery_state(state))
    state = begin_reset_delivery(state, second, ResetDeliverySettings(), now=1_002.0)
    assert [event.event_id for event in state.events] == [first.event_id, second.event_id]
    restored = decode_reset_delivery_state(encode_reset_delivery_state(state))
    assert [event.account_discriminator for event in restored.events] == [
        "synthetic-account-a", "synthetic-account-b"]
    assert [event.event_id for event in reset_events_pending_app(restored, now=1_003.0)] == [second.event_id]
    assert begin_reset_delivery(restored, second, ResetDeliverySettings(), now=1_004.0) == restored
    assert begin_reset_delivery(restored, replace(second, event_id="different-untrusted-id"),
                                ResetDeliverySettings(), now=1_004.0) == restored
    settled = apply_app_receipt(restored, second.event_id, "delivered", "presented", now=1_005.0)
    assert reset_events_pending_app(settled, now=1_006.0) == ()


def test_legacy_delivery_without_account_scope_keeps_fact_and_stable_id_dedup():
    import json

    from jrbar.provider_reset_events import apply_app_receipt, reset_events_pending_app

    first = replace(_event(), account_discriminator="synthetic-account-a")
    state = begin_reset_delivery(ResetDeliveryState(), first, ResetDeliverySettings(), now=1_000.0)
    state = apply_app_receipt(state, first.event_id, "delivered", "presented", now=1_001.0)
    document = json.loads(encode_reset_delivery_state(state))
    document["events"][0].pop("account_discriminator", None)
    legacy = decode_reset_delivery_state(json.dumps(document))
    assert len(legacy.events) == 1
    assert legacy.events[0].event_id == first.event_id
    assert legacy.events[0].app_receipts == state.events[0].app_receipts
    assert begin_reset_delivery(legacy, first, ResetDeliverySettings(), now=1_002.0) == legacy
    second = replace(first, event_id="claude:acct:weekly:second-account", account_discriminator="synthetic-account-b")
    grown = begin_reset_delivery(legacy, second, ResetDeliverySettings(), now=1_003.0)
    assert len(grown.events) == 2
    assert [event.event_id for event in reset_events_pending_app(grown, now=1_004.0)] == [second.event_id]


@pytest.mark.parametrize("outcomes", [("dropped", "delivered"), ("delivered", "dropped")])
def test_delivered_wins_a_racing_reconciliation_receipt(outcomes):
    from jrbar.provider_reset_events import apply_app_receipt, reset_events_pending_app

    state = begin_reset_delivery(ResetDeliveryState(), _event(), ResetDeliverySettings(), now=1_000.0)
    for index, outcome in enumerate(outcomes):
        state = apply_app_receipt(state, _event().event_id, outcome, "fixture", now=1_001.0 + index)
    restored = decode_reset_delivery_state(encode_reset_delivery_state(state))
    assert restored.events[0].app_receipts[-1].outcome == "delivered"
    assert reset_events_pending_app(restored, now=1_100.0) == ()
