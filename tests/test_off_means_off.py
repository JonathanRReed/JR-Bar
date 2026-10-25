from dataclasses import replace
from types import SimpleNamespace

import pytest

from jrbar import ambient_effect_runtime as ambient
from jrbar import device_writer
from jrbar.ntfy_alert import KIND_NEEDS_YOU, PhoneAlerts, Reason
from jrbar.provider_usage_consent import ConsentGatedCollector, usage_off_snapshot
from jrbar.provider_usage_runtime import ProviderUsageService
from jrbar.provider_usage_settings import default_provider_usage_settings
from jrbar.runtime_scheduler import AppKitTimerRegistry, RuntimeFeature
from jrbar.settings import AgentMonitorSettings, DeviceDisplaySetting
from tests.test_core_runtime import headless  # noqa: F401
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
