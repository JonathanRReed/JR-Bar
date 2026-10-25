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


def test_metadata_worker_requires_tool_consent_and_unlocked_keychain(tmp_path, monkeypatch):
    from jrbar import credentials, providers
    from jrbar.credentials import CLAUDE_CODE_KEYCHAIN, KeychainConsentLedger

    monkeypatch.setattr(providers, "default_state_dir", lambda: tmp_path)
    monkeypatch.setattr(provider_reconnect, "_KEYCHAIN_FINGERPRINT_CACHE", {})
    checks, reads = [], []
    unlocked = [False]
    monkeypatch.setattr(credentials, "_keychain_is_unlocked", lambda: checks.append(True) or unlocked[0])

    def run(arguments, **kwargs):
        reads.append(arguments)
        assert "-w" not in arguments
        return subprocess.CompletedProcess(arguments, 0, stdout='"mdat"="synthetic-stamp"', stderr="")

    monkeypatch.setattr(subprocess, "run", run)
    service = CLAUDE_CODE_KEYCHAIN.service
    assert provider_reconnect.keychain_fingerprint(service, now=1000, fresh=True) == ()
    assert checks == []
    assert reads == []
    ledger = KeychainConsentLedger(tmp_path / "keychain-consent.json")
    ledger.record_success(service, 1000, security=True)
    assert provider_reconnect.keychain_fingerprint(service, now=1001, fresh=True) == ()
    assert checks == [True]
    assert reads == []
    unlocked[0] = True
    assert provider_reconnect.keychain_fingerprint(service, now=1002, fresh=True)
    assert len(reads) == 1
    unlocked[0] = False
    assert provider_reconnect.keychain_fingerprint(service, now=1003, cached_only=True)
    assert len(checks) == 2
    assert len(reads) == 1
