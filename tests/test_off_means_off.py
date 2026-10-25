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
