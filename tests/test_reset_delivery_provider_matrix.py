"""Confirmed measured windows use the same durable delivery path for every provider."""

from dataclasses import replace
from types import SimpleNamespace

import pytest

from jrbar.provider_reset_events import (
    ResetDeliverySettings,
    ResetDeliveryState,
    apply_app_receipt,
    begin_reset_delivery,
    decode_reset_delivery_state,
    encode_reset_delivery_state,
)
from jrbar.provider_reset_settings_action import reset_replay_documents
from jrbar.provider_usage_parsers import _snapshot
from jrbar.provider_usage_platform import UsageLane, provider_descriptors
from jrbar.provider_usage_qol import confirm_reset_events, detect_reset_events
from jrbar.provider_usage_status_bar import _publish_reset_wire_events


@pytest.mark.parametrize("provider", [row.provider_id for row in provider_descriptors()])
@pytest.mark.parametrize("lane_id,period", [
    ("five-hour", 5 * 3600), ("daily", 86400), ("weekly", 7 * 86400),
    ("monthly", 30 * 86400), ("synthetic-model-weekly", 7 * 86400),
])
def test_measured_refill_reaches_live_and_durable_app_delivery(provider, lane_id, period):
    at = 1_790_000_000.0
    boundary = at + 100
    lane = UsageLane(provider, lane_id, "Synthetic allowance", 10, boundary,
                     "account", None, None, True, "synthetic-source")
    before = _snapshot(provider, observed_at=at, lanes=(lane,),
                       account_discriminator="synthetic-account")
    after = replace(before, observed_at=at + 200,
                    lanes=(replace(lane, remaining_percent=98, reset_at=boundary + period),))
    detected = detect_reset_events((before,), (after,), seen_event_ids=frozenset())
    confirmed = confirm_reset_events(detected, (after,))
    assert len(confirmed.events) == 1
    event = confirmed.events[0]
    assert (event.provider_id, event.lane_id, event.account_discriminator) == (
        provider, lane_id, "synthetic-account")

    wire = []
    controller = SimpleNamespace(_core_publish_event=lambda kind, **fields: wire.append((kind, fields)))
    _publish_reset_wire_events(controller, confirmed.events)
    assert len(wire) == 1
    assert wire[0][0] == "quota_reset"
    assert wire[0][1]["event_id"] == event.event_id
    assert wire[0][1]["lane"] == lane_id

    state = begin_reset_delivery(ResetDeliveryState(), event, ResetDeliverySettings(), now=after.observed_at)
    state = decode_reset_delivery_state(encode_reset_delivery_state(state))
    controller._jrbar_reset_delivery_state = state
    replay = reset_replay_documents(controller, now=after.observed_at + 1)
    assert len(replay) == 1
    assert replay[0] == {"kind": "quota_reset", "provider": provider, "instance": "default",
                         "lane": lane_id, "event_id": event.event_id, "id": event.event_id,
                         "at": after.observed_at, "notify": False}
    controller._jrbar_reset_delivery_state = apply_app_receipt(
        state, event.event_id, "held", "call", now=after.observed_at + 2)
    assert reset_replay_documents(controller, now=after.observed_at + 3) == replay
    controller._jrbar_reset_delivery_state = apply_app_receipt(
        controller._jrbar_reset_delivery_state, event.event_id, "delivered", "after_hold",
        now=after.observed_at + 4)
    assert reset_replay_documents(controller, now=after.observed_at + 5) == []
