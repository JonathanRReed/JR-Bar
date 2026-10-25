import threading
from dataclasses import replace
from types import SimpleNamespace
from unittest.mock import Mock

import pytest

from jrbar import ambient_effect_runtime as ambient
from jrbar import device_writer
from jrbar.ntfy_alert import KIND_NEEDS_YOU, PhoneAlerts, Reason
from jrbar.provider_usage_consent import ConsentGatedCollector, usage_off_snapshot
from jrbar.provider_usage_runtime import ProviderUsageService
from jrbar.provider_usage_settings import default_provider_usage_settings
from jrbar.runtime_scheduler import AppKitTimerRegistry, RuntimeFeature
from jrbar.settings import AgentMonitorSettings, DeviceDisplaySetting
from jrbar.usage_event_hooks import UsageHookJobs
from tests.test_core_runtime import REAL_THREAD, headless  # noqa: F401
from tests.test_presentation_scheduler import _FakeAppKitFactory, _inputs
from tests.test_status_bar_lifecycle_contract import controller  # noqa: F401


def test_consent_off_never_schedules_a_collector_or_reads_local_sources(tmp_path, monkeypatch):
    calls = []
    collector = ConsentGatedCollector(
        "codex", lambda *_: calls.append("remote"), lambda *_: calls.append("local"),
    )
    settings = default_provider_usage_settings()
    service = ProviderUsageService(
        settings_loader=lambda: settings, collectors={"codex": collector},
        credentials=object(), home=tmp_path, clock=lambda: 1000,
    )
    monkeypatch.setattr("jrbar.provider_usage_runtime._CollectionRound._collect", lambda *_: calls.append("job"))
    state = service.refresh_now(force=True)
    assert state.by_provider("codex").reason_code == "usage_not_turned_on"
    assert state.next_refresh_at is None
    collector.off(settings.preference("codex"), tmp_path, 1000)
    assert calls == []
    service.close()


def test_provider_on_then_off_stops_collecting_and_disarms_the_refresh(tmp_path):
    calls = []
    current = default_provider_usage_settings().with_usage_consent("codex", True, source="settings")
    current = replace(current, providers=tuple(replace(p, enabled=p.provider_id == "codex") for p in current.providers))
    collector = ConsentGatedCollector("codex", lambda *_: (calls.append(1), usage_off_snapshot("codex", observed_at=1000))[1])
    service = ProviderUsageService(settings_loader=lambda: current, collectors={"codex": collector},
                                  credentials=object(), home=tmp_path, clock=lambda: 1000)
    service.refresh_now(force=True)
    assert calls == [1]
    current = current.with_enabled("codex", False)
    service.note_settings_updated(current)
    assert service.refresh_now(force=True).next_refresh_at is None
    assert calls == [1]
    service.close()


def test_disabled_device_is_not_inspected_even_while_another_device_is_on(tmp_path, monkeypatch):
    off = tmp_path / "SidePulse"
    on = tmp_path / "PulseDot"
    off.mkdir()
    on.mkdir()
    touched = []
    monkeypatch.setattr(device_writer, "path_exists", lambda path: touched.append(path) or False)
    device_writer.discover_devices(mount_root=tmp_path, excluded_roots=(str(off),))
    assert touched
    assert all(off not in path.parents for path in touched)


@pytest.mark.parametrize("profile_rules", [{}, {"work": "fixture"}])
def test_disabled_daemon_consumers_only_schedule_standalone_profile_rules(controller, profile_rules):  # noqa: F811
    target, _ = controller
    off_device = DeviceDisplaySetting("fixture", "Fixture", "/tmp/jrbar-device-fixture", enabled=False)
    target.settings = replace(AgentMonitorSettings(), devices=(off_device,), focus_dim_rules={"work": 0.5},
                              focus_profile_rules=profile_rules)
    target._runtime_started = True
    target.leds_enabled = True
    inputs = _inputs(screen_bar_enabled=False, visible=False)
    assert not target._device_inventory_should_run(inputs)
    assert not target._hardware_write_should_run(inputs)
    assert not target._lid_observation_should_run(inputs)
    assert target._display_environment_should_run(inputs) == bool(profile_rules)
    assert not target._calendar_observation_should_run(inputs)
    assert not target._reminders_observation_should_run(inputs)
    factory = _FakeAppKitFactory()
    target._runtime_timer_registry = AppKitTimerRegistry({feature: (lambda: None) for feature in RuntimeFeature}, timer_factory=factory, monotonic=lambda: 100)
    target.reconcile_presentation_timers(inputs)
    live = target._runtime_timer_registry.snapshot().active_features
    assert RuntimeFeature.DEVICE_INVENTORY not in live
    assert RuntimeFeature.LID_OBSERVATION not in live
    assert (RuntimeFeature.DISPLAY_ENVIRONMENT in live) == bool(profile_rules)
    submissions = []
    target._display_environment_active = True
    target._os_poll_worker = SimpleNamespace(submit=submissions.append)
    target._display_environment_timer_fired()
    assert submissions[0].payload.read_focus == bool(profile_rules)


def test_off_remote_peers_invalidates_its_timer_and_does_not_rearm(controller):  # noqa: F811
    target, _ = controller
    invalidated = []
    target.remote_peers_timer = SimpleNamespace(invalidate=lambda: invalidated.append(True))
    target.start_remote_peer_timer()
    assert invalidated == [True]
    assert target.remote_peers_timer is None
    target.refreshRemotePeers_(None)
    assert target.remote_peers_timer is None


@pytest.mark.parametrize("family", list(ambient._CUE_RESOURCES))
def test_disabled_cue_releases_its_observer_state(family):
    settings = replace(AgentMonitorSettings(), ambient_cues_disabled=(family.value,))
    target = SimpleNamespace(settings=settings)
    for attribute in ambient._CUE_RESOURCES[family]:
        setattr(target, attribute, object())
    ambient.stop_disabled_cues(target)
    assert all(not hasattr(target, name) for name in ambient._CUE_RESOURCES[family])


def test_disabled_cue_returns_before_its_planner(monkeypatch):
    target = SimpleNamespace(settings=replace(AgentMonitorSettings(), ambient_cues_disabled=("ask_heartbeat",)))
    calls = []
    monkeypatch.setattr(ambient, "plan_ask_heartbeat_sync", lambda *_args, **_kwargs: calls.append(True))
    ambient._observe_ask_heartbeat(target, object(), object(), frozenset())
    assert calls == []


def test_phone_off_cancels_queued_delivery_and_its_active_connection(headless):  # noqa: F811
    queued = []
    wire = []
    service = PhoneAlerts(transport=lambda *_: wire.append(True), spawn=queued.append, away_probe=lambda: True)
    headless._jrbar_phone_alerts = service
    headless.settings = replace(headless.settings, ntfy_enabled=True, ntfy_topic="fixture")
    assert service.alert(headless.settings, KIND_NEEDS_YOU, "codex").sent
    assert service.active_deliveries == 1
    delivery = next(iter(service._deliveries))
    closed = []
    delivery._connection = SimpleNamespace(sock=None, close=lambda: closed.append(True))
    headless.settings = replace(headless.settings, ntfy_enabled=False)
    queued[0]()
    assert closed == [True]
    assert service.active_deliveries == 0 and wire == []
    assert service.alert(headless.settings, KIND_NEEDS_YOU, "codex").reason == Reason.OFF


def test_hooks_off_retires_active_processes_and_rejects_late_launches(monkeypatch):
    jobs = UsageHookJobs()
    generation = jobs.generation
    killed = []
    monkeypatch.setattr("jrbar.usage_event_hooks._signal_kill", killed.append)
    first = object()
    assert jobs.register(first, generation)
    jobs.cancel()
    assert jobs.active_count == 0 and killed == [first]
    late = Mock()
    assert not jobs.register(late, generation)
    assert killed == [first, late]
    late.wait.assert_called_once_with(timeout=2.0)


def test_presence_off_releases_the_daemons_expiry_timer(headless):  # noqa: F811
    from jrbar.presence import PresenceFacts

    invalidated = []
    headless.apply_escalation = lambda **_kwargs: None
    headless._core_presence = PresenceFacts(received_at=1000, mic=True)
    headless._core_presence_timer = SimpleNamespace(invalidate=lambda: invalidated.append(True))
    headless.settings = replace(headless.settings, presence_enabled=False)
    assert headless._core_presence is None
    assert headless._core_presence_timer is None
    assert invalidated == [True]


def test_phone_off_cancels_an_active_test_send(headless, monkeypatch):  # noqa: F811
    entered = threading.Event()
    outcomes = []
    service = PhoneAlerts()
    headless._jrbar_phone_alerts = service
    headless.settings = replace(headless.settings, ntfy_enabled=True, ntfy_topic="fixture")

    def post(delivery, _target, _body):
        entered.set()
        assert delivery.cancelled.wait(timeout=5)
        return None

    monkeypatch.setattr("jrbar.ntfy_alert._Delivery.post", post)
    worker = REAL_THREAD(target=lambda: outcomes.append(service.send_test(headless.settings)))
    worker.start()
    try:
        assert entered.wait(timeout=5)
        assert service.active_deliveries == 1
        headless.settings = replace(headless.settings, ntfy_enabled=False)
    finally:
        service.cancel()
        worker.join(timeout=5)
    assert not worker.is_alive()
    assert service.active_deliveries == 0
    assert outcomes[0].reason == Reason.OFF
