"""A terminal Claude gate cannot spawn security on the main request path."""

import subprocess
import threading

from jrbar import provider_reconnect
from jrbar.provider_reconnect import FailureGate
from jrbar.provider_usage_runtime import ProviderUsageService, ProviderUsageState
from jrbar.provider_usage_settings import default_provider_usage_settings


def test_request_reads_cached_keychain_stamp_only(tmp_path, monkeypatch):
    settings = default_provider_usage_settings().with_usage_consent("claude", True, source="settings")
    service = ProviderUsageService(settings_loader=lambda: settings, collectors={"claude": lambda *a: None},
        credentials=object(), home=tmp_path, clock=lambda: 1000)
    service._settings_snapshot = settings
    service._failure_gates[("claude", "default")] = FailureGate(terminal=True, terminal_fingerprint=None)
    service._state = ProviderUsageState((), 1000, 5000, False)
    monkeypatch.setattr(provider_reconnect, "_KEYCHAIN_FINGERPRINT_CACHE", {})
    monkeypatch.setattr(subprocess, "run", lambda *a, **kw: (_ for _ in ()).throw(AssertionError("spawn on request path")))
    service.request(callback=lambda _: None)
    service.close()


def test_auth_timer_fingerprints_off_main_without_holding_service_lock(tmp_path, monkeypatch):
    from jrbar import provider_usage_runtime as runtime

    timers = []
    settings = default_provider_usage_settings().with_usage_consent("claude", True, source="settings")

    class Timer:
        def __init__(self, delay, callback):
            self.callback = callback
            timers.append(self)
        def start(self):
            pass
        def cancel(self):
            pass

    clock = [1000]
    service = ProviderUsageService(settings_loader=lambda: settings, collectors={"claude": lambda *a: None},
        credentials=object(), home=tmp_path, clock=lambda: clock[0], timer_factory=Timer)
    service._settings_snapshot = settings
    service._failure_gates[("claude", "default")] = FailureGate(terminal=True, terminal_fingerprint=None)
    service._state = ProviderUsageState((), 1000, 5000, False)
    calls = []

    def fingerprint(home, provider, *, cached_only=False):
        if not cached_only:
            assert threading.current_thread() is not threading.main_thread()
            assert not service._lock._is_owned()
        calls.append(cached_only)
        return None

    monkeypatch.setattr(runtime, "credential_fingerprint", fingerprint)
    service.request(callback=lambda _: None)
    clock[0] = 1060
    worker = threading.Thread(target=timers[-1].callback)
    worker.start()
    worker.join(timeout=2)
    assert not worker.is_alive()
    assert False in calls
    service.close()
