from dataclasses import replace
from types import SimpleNamespace

from jrbar.provider_usage_feedback import _pace_event_fields, alert_new_critical_pace
from jrbar.provider_usage_platform import ProviderSourceState, ProviderUsageSnapshot, UsageLane
from jrbar.usage_pace import critical_pace_transitions, pace_window_key

NOW = 1_000_000.0
RESET = NOW + 2.5 * 3600


def snapshot(instance="default", account=None, remaining=55.0):
    lane = UsageLane(
        provider_id="codex", lane_id="five-hour", label="5-hour",
        remaining_percent=remaining, reset_at=RESET, scope="all", model=None,
        feature=None, bindable=True, source_id="fixture",
    )
    return ProviderUsageSnapshot(
        provider_id="codex", account_label=None, observed_at=NOW,
        state=ProviderSourceState.READY, reason_code=None, action_label=None,
        lanes=(lane,), input_tokens=0, cached_input_tokens=0, output_tokens=0,
        model_count=0, estimated_cost_usd=None, cache_savings_usd=None,
        credits_remaining=None, incident=None, source_instance_id=instance,
        account_discriminator=account,
    )


def test_instances_with_the_same_reset_alert_independently():
    home = snapshot("home", "account-home")
    work = snapshot("work", "account-work")
    home_low = replace(home, lanes=(replace(home.lanes[0], remaining_percent=25),))
    work_low = replace(work, lanes=(replace(work.lanes[0], remaining_percent=10),))
    first = critical_pace_transitions((home, work), (home_low, work), now=NOW, seen_keys=frozenset())
    assert len(first) == 1
    second = critical_pace_transitions(
        (home_low, work), (home_low, work_low), now=NOW, seen_keys=frozenset({first[0][0]}),
    )
    assert len(second) == 1
    assert first[0][0] != second[0][0]
    fields = _pace_event_fields(SimpleNamespace(snapshots=(home_low, work_low)), *second[0], now=NOW)
    assert fields["remaining_percent"] == 10
    assert fields["instance"] == "work"
    assert fields["detail"].startswith("10% left")


def test_changing_the_account_does_not_borrow_the_previous_alert():
    old = snapshot(account="account-old", remaining=25)
    new = snapshot(account="account-new", remaining=10)
    old_key = pace_window_key(old, old.lanes[0])
    alerts = critical_pace_transitions((old,), (new,), now=NOW, seen_keys=frozenset({old_key}))
    assert len(alerts) == 1
    assert "account-new" not in alerts[0][0]
    assert "account-old" not in old_key
    unchanged = replace(new, observed_at=NOW + 30)
    assert pace_window_key(unchanged, unchanged.lanes[0]) == alerts[0][0]
    assert critical_pace_transitions(
        (new,), (unchanged,), now=NOW + 30, seen_keys=frozenset({alerts[0][0]}),
    ) == ()


def test_unknown_default_identity_keeps_its_legacy_window_key():
    item = snapshot()
    assert pace_window_key(item, item.lanes[0]) == f"codex:five-hour:{int(RESET)}"


def test_notification_and_event_refer_to_the_account_that_changed():
    home = snapshot("home", "account-home", 25)
    work = snapshot("work", "account-work", 55)
    work_low = replace(work, lanes=(replace(work.lanes[0], remaining_percent=10),))
    home_key = pace_window_key(home, home.lanes[0])
    delivered, published, errors = [], [], []
    target = SimpleNamespace(
        settings=SimpleNamespace(quota_alerts_enabled=True), quiet_active=lambda: False,
        _jrbar_seen_pace_alerts=(home_key,),
        _notification_client_for_use=lambda: SimpleNamespace(deliver=lambda *args: delivered.append(args)),
        _core_publish_event=lambda kind, **fields: published.append((kind, fields)),
    )
    alert_new_critical_pace(
        target, SimpleNamespace(snapshots=(home, work)), SimpleNamespace(snapshots=(home, work_low)),
        log=errors.append, signal_kind=None, now=NOW,
    )
    assert errors == []
    assert len(delivered) == len(published) == 1
    kind, fields = published[0]
    assert kind == "quota_pace"
    assert fields["instance"] == "work"
    assert fields["remaining_percent"] == 10
    assert "account-work" not in str(delivered)
    assert "account-work" not in str(published)
