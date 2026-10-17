"""Connection cues belong to the profile that lost its source."""

from types import SimpleNamespace

import pytest

from jrbar.provider_reconnect import connection_loss_transitions
from jrbar.provider_usage_feedback import alert_connection_loss


def snapshot(instance="default", state="ready", reason=None):
    return SimpleNamespace(
        provider_id="claude",
        source_instance_id=instance,
        state=SimpleNamespace(value=state),
        reason_code=reason,
    )


def lost(instance="default"):
    return snapshot(instance, "stale", "authentication_required")


@pytest.mark.parametrize("reverse", [False, True])
def test_unchanged_mixed_profiles_never_form_a_new_loss_edge(reverse):
    rows = (lost(), snapshot("work"))
    if reverse:
        rows = rows[::-1]
    assert connection_loss_transitions(rows, rows) == ()


def test_new_profile_does_not_inherit_another_profiles_healthy_history():
    assert connection_loss_transitions((snapshot(),), (snapshot(), lost("work"))) == ()


def test_each_profile_has_its_own_loss_key_including_colon_ids():
    before = (snapshot(), snapshot("team:west"))
    after = (lost(), lost("team:west"))
    events = connection_loss_transitions(before, after)
    assert events == (
        ("claude:authentication_required", "claude", "authentication_required"),
        ("claude:team%3Awest:authentication_required", "claude", "authentication_required"),
    )
    assert connection_loss_transitions(before, after, seen_keys=frozenset({events[0][0]})) == (events[1],)


class Controller:
    connection_notice_until = 0.0

    def __init__(self):
        self.refreshes = 0

    def schedule_event_refresh(self):
        self.refreshes += 1


def apply(controller, before, after):
    alert_connection_loss(
        controller,
        SimpleNamespace(snapshots=before),
        SimpleNamespace(snapshots=after),
        log=lambda _: None,
        signal_kind=None,
    )


def test_healthy_neighbor_does_not_extend_a_broken_profiles_notice(monkeypatch):
    clock = [100.0]
    monkeypatch.setattr("jrbar.provider_usage_feedback.time.monotonic", lambda: clock[0])
    controller = Controller()
    before = (snapshot(), snapshot("work"))
    after = (lost(), snapshot("work"))
    apply(controller, before, after)
    assert controller.connection_notice_until == 104.0
    assert controller.refreshes == 1
    clock[0] = 200.0
    apply(controller, after, after)
    assert controller.connection_notice_until == 104.0
    assert controller.refreshes == 1
    assert controller._jrbar_seen_connection_losses == ("claude:authentication_required",)


@pytest.mark.parametrize("recovering", ["default", "team:west"])
def test_recovery_rearms_only_its_own_profile(monkeypatch, recovering):
    monkeypatch.setattr("jrbar.provider_usage_feedback.time.monotonic", lambda: 100.0)
    controller = Controller()
    before = (snapshot(), snapshot("team:west"))
    broken = (lost(), lost("team:west"))
    apply(controller, before, broken)
    assert len(controller._jrbar_seen_connection_losses) == 2
    recovered = tuple(
        snapshot(row.source_instance_id) if row.source_instance_id == recovering else row for row in broken
    )
    apply(controller, broken, recovered)
    remaining = (
        "claude:team%3Awest:authentication_required" if recovering == "default" else "claude:authentication_required"
    )
    assert controller._jrbar_seen_connection_losses == (remaining,)
    assert controller.refreshes == 1
    apply(controller, recovered, broken)
    assert len(controller._jrbar_seen_connection_losses) == 2
    assert controller.refreshes == 2


@pytest.mark.parametrize("gate", ["quiet", "interrupt"])
def test_suppressed_loss_is_consumed_without_a_later_repeat(monkeypatch, gate):
    monkeypatch.setattr("jrbar.provider_usage_feedback.time.monotonic", lambda: 100.0)
    controller = Controller()
    controller.quiet_active = lambda: gate == "quiet"
    controller.may_interrupt = lambda _: gate != "interrupt"
    before = (snapshot(), snapshot("work"))
    after = (lost(), snapshot("work"))
    alert_connection_loss(
        controller,
        SimpleNamespace(snapshots=before),
        SimpleNamespace(snapshots=after),
        log=lambda _: None,
        signal_kind="synthetic",
    )
    assert controller.connection_notice_until == 0.0
    assert controller.refreshes == 0
    controller.quiet_active = lambda: False
    controller.may_interrupt = lambda _: True
    apply(controller, after, after)
    assert controller.connection_notice_until == 0.0
    assert controller.refreshes == 0


def test_missing_broken_profile_does_not_count_as_recovery():
    controller = Controller()
    broken = (lost(), snapshot("work"))
    apply(controller, (snapshot(), snapshot("work")), broken)
    apply(controller, broken, (snapshot("work"),))
    apply(controller, (snapshot("work"),), broken)
    assert controller._jrbar_seen_connection_losses == ("claude:authentication_required",)
    assert controller.refreshes == 1
