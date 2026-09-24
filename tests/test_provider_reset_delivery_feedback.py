from types import SimpleNamespace

from jrbar.provider_reset_events import ResetChannel, ResetChannelOutcome
from jrbar.provider_usage_feedback import deliver_reset_channels
from jrbar.provider_usage_qol import ResetEvent


def test_quiet_visuals_do_not_block_notification_fallback__and_1_more() -> None:
    # --- scenario: quiet_visuals_do_not_block_notification_fallback
    delivered = []
    controller = SimpleNamespace(
        quiet_active=lambda: True,
        settings=SimpleNamespace(virtual_status_device_enabled=True),
        has_connected_physical_device=lambda: True,
        # MacOSNotificationClient.deliver says whether it posted.
        _notification_client_for_use=lambda: SimpleNamespace(
            deliver=lambda *args: delivered.append(args) or True
        ),
    )
    event = ResetEvent("codex:weekly:event", "codex", "weekly", "Weekly reset", 1000, "acct", 900)

    receipts = deliver_reset_channels(
        controller,
        event,
        tuple(ResetChannel),
        now=1001,
        monotonic_now=50,
        log=lambda _message: None,
        sound_player=lambda: True,
    )

    by_channel = {receipt.channel: receipt for receipt in receipts}
    assert by_channel[ResetChannel.OVERLAY].outcome is ResetChannelOutcome.SUPPRESSED
    assert by_channel[ResetChannel.HARDWARE].outcome is ResetChannelOutcome.SUPPRESSED
    assert by_channel[ResetChannel.SOUND].outcome is ResetChannelOutcome.SUPPRESSED
    assert by_channel[ResetChannel.NOTIFICATION].outcome is ResetChannelOutcome.DELIVERED
    assert len(delivered) == 1

    # --- scenario: common_effect_only_receipts_surfaces_that_exist
    controller = SimpleNamespace(
        quiet_active=lambda: False,
        settings=SimpleNamespace(virtual_status_device_enabled=False),
        has_connected_physical_device=lambda: True,
        schedule_event_refresh=lambda: None,
    )
    event = ResetEvent("codex:weekly:event", "codex", "weekly", "Weekly reset", 1000, "acct", 900)

    receipts = deliver_reset_channels(
        controller,
        event,
        (ResetChannel.OVERLAY, ResetChannel.HARDWARE),
        now=1001,
        monotonic_now=50,
        log=lambda _message: None,
    )

    assert [(item.channel, item.outcome, item.reason) for item in receipts] == [
        (ResetChannel.OVERLAY, ResetChannelOutcome.SUPPRESSED, "surface_unavailable"),
        (ResetChannel.HARDWARE, ResetChannelOutcome.DELIVERED, "effect_scheduled"),
    ]



def test_a_client_that_posts_nothing_is_not_recorded_as_posted() -> None:
    """The daemon's HeadlessNotificationClient returns False: the app
    banners the quota_reset wire event itself, and the receipt must not
    claim a banner the daemon never showed."""
    controller = SimpleNamespace(
        quiet_active=lambda: False,
        settings=SimpleNamespace(virtual_status_device_enabled=False),
        has_connected_physical_device=lambda: False,
        _notification_client_for_use=lambda: SimpleNamespace(deliver=lambda *_args: False),
    )
    event = ResetEvent("codex:weekly:event", "codex", "weekly", "Weekly reset", 1000, "acct", 900)

    receipts = deliver_reset_channels(
        controller,
        event,
        (ResetChannel.NOTIFICATION,),
        now=1001,
        monotonic_now=50,
        log=lambda _message: None,
    )

    assert [(item.outcome, item.reason) for item in receipts] == [(ResetChannelOutcome.FAILED, "not_delivered")]


def test_a_lane_turning_critical_reaches_the_app_as_a_quota_pace_event__and_2_more() -> None:
    from jrbar.provider_usage_feedback import alert_new_critical_pace
    from jrbar.provider_usage_platform import ProviderSourceState, ProviderUsageSnapshot, UsageLane
    from jrbar.provider_usage_runtime import ProviderUsageState

    hour = 3600.0
    base = 1_000_000.0

    def state(remaining: float) -> ProviderUsageState:
        # Halfway through a five-hour window; heavy use turns it critical.
        snapshot = ProviderUsageSnapshot(
            provider_id="codex",
            account_label=None,
            observed_at=base,
            state=ProviderSourceState.READY,
            reason_code=None,
            action_label=None,
            lanes=(
                UsageLane(
                    provider_id="codex",
                    lane_id="five-hour",
                    label="5-hour",
                    remaining_percent=remaining,
                    reset_at=base + 2.5 * hour,
                    scope="all",
                    model=None,
                    feature=None,
                    bindable=True,
                    source_id="fixture",
                ),
            ),
            input_tokens=0, cached_input_tokens=0, output_tokens=0,
            model_count=0, estimated_cost_usd=None, cache_savings_usd=None,
            credits_remaining=None, incident=None,
        )
        return ProviderUsageState((snapshot,), base, base, False)

    def controller(**settings):
        published: list[tuple[str, dict]] = []
        delivered: list[tuple] = []
        return published, delivered, SimpleNamespace(
            settings=SimpleNamespace(**settings),
            quiet_active=lambda: False,
            _notification_client_for_use=lambda: SimpleNamespace(
                deliver=lambda *args: delivered.append(args) or False
            ),
            _core_publish_event=lambda kind, **fields: published.append((kind, fields)),
        )

    # --- scenario: the event names the lane, what is left, the run-out and the reset
    published, delivered, target = controller(quota_alerts_enabled=True)
    alert_new_critical_pace(target, state(55.0), state(30.0), log=lambda _m: None, signal_kind=None, now=base)
    assert len(delivered) == 1
    assert [kind for kind, _fields in published] == ["quota_pace"]
    fields = published[0][1]
    assert fields["provider"] == "codex"
    assert fields["lane"] == "five-hour"
    assert fields["label"] == "5-hour"
    assert fields["remaining_percent"] == 30.0
    assert fields["resets_at"] == base + 2.5 * hour
    assert base < fields["runs_out_at"] < fields["resets_at"]
    assert fields["detail"].startswith("30% left · runs out around ")
    assert " · resets " in fields["detail"]

    # --- scenario: the same window is not news twice
    alert_new_critical_pace(target, state(55.0), state(30.0), log=lambda _m: None, signal_kind=None, now=base)
    assert len(published) == 1

    # --- scenario: with quota alerts off nothing is published
    published, delivered, target = controller(quota_alerts_enabled=False)
    alert_new_critical_pace(target, state(55.0), state(30.0), log=lambda _m: None, signal_kind=None, now=base)
    assert published == [] and delivered == []
