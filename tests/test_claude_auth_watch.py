"""Credential pickup uses fake attribute fingerprints, never a Keychain read."""
from dataclasses import replace

import pytest

from jrbar.provider_reconnect import FailureGate
from jrbar.provider_usage_platform import ProviderSourceState, failure_snapshot
from jrbar.provider_usage_runtime import ProviderUsageService, ProviderUsageState
from jrbar.provider_usage_settings import default_provider_usage_settings
from tests.test_grok_auth_freshness import Timer


def fixture(home, monkeypatch, *, consent=True, terminal=True, instance="default"):
    clock, timers, starts = [1000.0], [], []
    fingerprints = {"claude": ("old",), "grok": ("old",)}
    monkeypatch.setattr("jrbar.provider_usage_runtime.credential_fingerprint",
                        lambda _home, provider: fingerprints[provider])
    settings = default_provider_usage_settings().with_usage_consent("claude", consent, source="settings", at=1000)

    def timer_factory(delay, callback):
        timer = Timer(delay, callback)
        timers.append(timer)
        return timer

    service = ProviderUsageService(settings_loader=lambda: settings, collectors={"claude": lambda *_a: None},
                                   credentials=object(), home=home, clock=lambda: clock[0], timer_factory=timer_factory)
    reading = failure_snapshot("claude", observed_at=1000, state=ProviderSourceState.NEEDS_SIGN_IN,
                               reason="authentication_required", action="Fix sign-in")
    service._state = ProviderUsageState((replace(reading, source_instance_id=instance),), 1000, 2800, False)
    service._settings_snapshot = settings
    service._failure_gates[("claude", instance)] = FailureGate(terminal=terminal, terminal_fingerprint=("old",))
    service._scheduled_callback = lambda *_a: None
    monkeypatch.setattr(service, "_start_worker_locked", lambda **kwargs: starts.append(kwargs))
    return service, clock, timers, starts, fingerprints


def test_unchanged_auth_does_not_collect_or_postpone_pickup(tmp_path, monkeypatch):
    service, clock, timers, starts, _ = fixture(tmp_path, monkeypatch)
    try:
        service._schedule_due_locked()
        assert timers[-1].interval == 60
        clock[0] = 1020
        service._schedule_due_locked()
        assert timers[-1].interval == 40
        clock[0] = 1060
        timers[-1].callback()
        assert starts == []
        assert timers[-1].interval == 60
        assert service.snapshot().next_refresh_at == 2800
    finally:
        service.close()


def test_rotated_auth_targets_only_claude_before_normal_deadline(tmp_path, monkeypatch):
    service, clock, timers, starts, fingerprints = fixture(tmp_path, monkeypatch)
    other = FailureGate(strikes=2, retry_at=2000)
    service._failure_gates[("grok", "default")] = other
    try:
        service._schedule_due_locked()
        fingerprints["claude"] = ("renewed",)
        clock[0] = 1060
        timers[-1].callback()
        assert len(starts) == 1
        assert starts[0]["providers"] == (("claude", "default"),)
        assert starts[0]["force"] is False
        assert service._failure_gates[("grok", "default")] == other
    finally:
        service.close()


@pytest.mark.parametrize("consent,terminal,instance", [(False, True, "default"), (True, False, "default"), (True, True, "work")])
def test_no_probe_without_consent_during_backoff_or_for_named_profile(tmp_path, monkeypatch, consent, terminal, instance):
    service, _, timers, _, _ = fixture(tmp_path, monkeypatch, consent=consent, terminal=terminal, instance=instance)
    monkeypatch.setattr("jrbar.provider_usage_runtime.credential_fingerprint",
                        lambda *_a: pytest.fail("unexpected credential probe"))
    try:
        service._schedule_due_locked()
        assert timers[-1].interval == 1800
        assert service._changed_auth_providers_locked() == ()
    finally:
        service.close()


def test_explicit_scope_does_not_refresh_another_changed_credential(tmp_path, monkeypatch):
    service, _, _, starts, fingerprints = fixture(tmp_path, monkeypatch)
    try:
        fingerprints["claude"] = ("renewed",)
        service.request(callback=lambda *_a: None, providers=("grok",))
        assert starts == []
        service.request(callback=lambda *_a: None, providers=("claude",))
        assert starts[0]["providers"] == (("claude", "default"),)
    finally:
        service.close()


def test_renewed_source_publishes_fresh_usage_without_touching_another_gate(tmp_path, monkeypatch):
    from tests.test_provider_usage_runtime import snapshot

    service, clock, timers, _, fingerprints = fixture(tmp_path, monkeypatch)
    reads, results = [], []

    def collect(_preference, _home, observed_at, _credentials):
        reads.append(observed_at)
        return snapshot("claude", observed=observed_at)

    service._collectors["claude"] = collect
    other_gate = FailureGate(strikes=2, retry_at=2000)
    other_reading = failure_snapshot("grok", observed_at=1000, state=ProviderSourceState.RATE_LIMITED,
                                    reason="rate_limited", action="Retry later")
    service._state = replace(service._state, snapshots=(*service._state.snapshots, other_reading))
    service._failure_gates[("grok", "default")] = other_gate
    monkeypatch.setattr(service, "_start_worker_locked", lambda **kwargs: results.append(
        service.refresh_now(providers=kwargs["providers"], force=kwargs["force"])))
    try:
        service._schedule_due_locked()
        fingerprints["claude"] = ("renewed",)
        clock[0] = 1060
        timers[-1].callback()
        assert reads == [1060]
        assert results[0].by_provider("claude").state is ProviderSourceState.READY
        assert results[0].by_provider("claude").effective_read_at == 1060
        assert results[0].by_provider("grok") == other_reading
        assert service._failure_gates[("grok", "default")] == other_gate
        assert service._watched_auth_providers_locked() == ()
    finally:
        service.close()
