"""Grok credential isolation and sign-in pickup with synthetic sources."""

import json
from dataclasses import replace
from types import SimpleNamespace

import pytest

from jrbar import provider_reconnect
from jrbar import provider_usage_collectors as collectors
from jrbar.provider_instances import ProviderInstanceKey
from jrbar.provider_reconnect import FailureGate, credential_fingerprint
from jrbar.provider_usage_platform import ProviderSourceState, failure_snapshot
from jrbar.provider_usage_runtime import ProviderUsageService, ProviderUsageState, _InstanceCredentialView
from jrbar.provider_usage_settings import default_provider_usage_settings


class Store:
    def __init__(self):
        self.values = {("grok", "default", "token"): "synthetic-stored", ("grok", "second", "token"): "synthetic-second"}

    def get(self, provider, account):
        return self.get_for_instance(ProviderInstanceKey(provider, "default"), account)

    def get_for_instance(self, key, account):
        value = self.values.get((*key.value, account))
        return SimpleNamespace(available=value is not None, secret=value)


def write_auth(home, token="synthetic-cli", expiry=5000):
    path = home / ".grok" / "auth.json"
    path.parent.mkdir(exist_ok=True)
    path.write_text(json.dumps({"https://auth.x.ai::fixture": {"key": token, "expires_at": expiry}}))


def collect(home, store, http, *, instance="default"):
    credentials = _InstanceCredentialView(store, ProviderInstanceKey("grok", instance))
    return collectors.collect_grok(SimpleNamespace(source_instance_id=instance), home=home,
                                   observed_at=1000, credentials=credentials, http_json=http)


def test_named_grok_profile_never_reads_or_sends_default_cli_credentials(tmp_path, monkeypatch):
    write_auth(tmp_path)
    monkeypatch.setattr(collectors, "_read_grok_auth", lambda *_a: pytest.fail("default CLI source read"))
    asked = []

    def http(*_a, headers, **_k):
        asked.append(headers["Authorization"])
        return {"config": {"creditUsagePercent": 40}}

    result = collect(tmp_path, Store(), http, instance="second")
    assert result.state is ProviderSourceState.READY
    assert asked == ["Bearer synthetic-second"]


@pytest.mark.parametrize("body", ["expired", "malformed"])
def test_existing_invalid_cli_auth_never_falls_back_to_an_old_stored_copy(tmp_path, body):
    write_auth(tmp_path, expiry=900)
    if body == "malformed":
        (tmp_path / ".grok" / "auth.json").write_text("not json")
    result = collect(tmp_path, Store(), lambda *_a, **_k: pytest.fail("invalid sign-in reached HTTP"))
    assert result.state is ProviderSourceState.NEEDS_SIGN_IN
    assert result.action_label == "Run grok login"


@pytest.mark.parametrize("expiry", [
    "1970-01-01T00:15:00Z", "1970-01-01T01:15:00+01:00",
    "1970-01-01T00:16:40Z", "not-a-date", "1970-01-01T00:20:00",
    True, float("nan"), float("inf"), 10 ** 400,
])
def test_declared_expired_or_invalid_expiry_never_reaches_http(tmp_path, expiry):
    write_auth(tmp_path, expiry=expiry)
    result = collect(tmp_path, Store(), lambda *_a, **_k: pytest.fail("expired/invalid CLI token reached HTTP"))
    assert result.state is ProviderSourceState.NEEDS_SIGN_IN
    assert provider_reconnect.grok_auth_status(tmp_path, 1000)[0] == "expired"


@pytest.mark.parametrize("expiry", ["1970-01-01T00:20:00Z", "1970-01-01T01:20:00+01:00", 1200, None])
def test_live_expiry_formats_and_legacy_no_expiry_remain_usable(tmp_path, expiry):
    write_auth(tmp_path, expiry=expiry)
    asked = []

    def http(*_a, headers, **_k):
        asked.append(headers["Authorization"])
        return {"config": {"creditUsagePercent": 40}}

    assert collect(tmp_path, Store(), http).state is ProviderSourceState.READY
    assert asked == ["Bearer synthetic-cli"]


def test_expired_date_does_not_shadow_a_second_live_auth_entry(tmp_path):
    write_auth(tmp_path, expiry="1970-01-01T00:15:00Z")
    path = tmp_path / ".grok" / "auth.json"
    document = json.loads(path.read_text())
    document["https://auth.x.ai::second"] = {"key": "synthetic-live", "expires_at": "1970-01-01T00:20:00Z"}
    path.write_text(json.dumps(document))
    assert collectors._read_grok_auth(tmp_path, 1000).credential == ("synthetic-live", None)


@pytest.mark.parametrize("scope", [
    "https://company.example/oidc::fixture", "https://auth.x.ai.evil.example::fixture",
    "https://accounts.x.ai.evil.example/sign-in", "xai::api_key",
])
def test_unrelated_cli_auth_never_reaches_public_quota_transport(tmp_path, scope):
    write_auth(tmp_path)
    path = tmp_path / ".grok" / "auth.json"
    path.write_text(json.dumps({scope: {"key": "synthetic-other-scope", "expires_at": 1200}}))
    asked = []

    def http(*args, **kwargs):
        asked.append((args, kwargs))
        return {"config": {"creditUsagePercent": 40}}

    result = collect(tmp_path, Store(), http)
    assert asked == []
    assert result.state is ProviderSourceState.UNSUPPORTED
    assert result.reason_code == "unsupported_cli_auth_scope"
    assert provider_reconnect.grok_auth_status(tmp_path, 1000) == ("unsupported", None)


def test_unrelated_scope_does_not_shadow_legacy_quota_credentials(tmp_path):
    write_auth(tmp_path)
    path = tmp_path / ".grok" / "auth.json"
    path.write_text(json.dumps({
        "https://company.example/oidc::fixture": {"key": "synthetic-company", "expires_at": 1200},
        "https://accounts.x.ai/sign-in": {"key": "synthetic-legacy", "expires_at": 1200},
    }))
    asked = []

    def http(*_a, headers, **_k):
        asked.append(headers["Authorization"])
        return {"config": {"creditUsagePercent": 40}}

    assert collect(tmp_path, Store(), http).state is ProviderSourceState.READY
    assert asked == ["Bearer synthetic-legacy"]


def test_reconnect_does_not_delete_stored_credentials_for_an_unrelated_cli_scope(tmp_path):
    write_auth(tmp_path)
    path = tmp_path / ".grok" / "auth.json"
    path.write_text(json.dumps({"https://company.example/oidc::fixture": {"key": "synthetic-company"}}))
    store = Store()
    deletes = []
    store.delete = lambda *key: deletes.append(key) or True
    result = provider_reconnect.repair_grok_credential(store, home=tmp_path, now=1000)
    assert deletes == []
    assert result.outcome.value == "unavailable"
    assert "quota profile" in result.message
    assert "grok login" not in result.message


def test_401_scope_change_reports_unsupported_without_retry_or_signin(tmp_path):
    write_auth(tmp_path)
    path = tmp_path / ".grok" / "auth.json"
    asked = []
    store = Store()

    def http(*_a, headers, **_k):
        asked.append(headers["Authorization"])
        path.write_text(json.dumps({"https://company.example/oidc::fixture": {"key": "synthetic-company"}}))
        raise collectors.ProviderHttpError(401, "http_error")

    result = collect(tmp_path, store, http)
    assert asked == ["Bearer synthetic-cli"]
    assert result.state is ProviderSourceState.UNSUPPORTED
    assert result.action_label == "Add a Grok quota profile"
    assert store.values["grok", "default", "token"] == "synthetic-stored"


def test_absent_cli_source_keeps_explicit_stored_credential_support(tmp_path):
    asked = []

    def http(*_a, headers, **_k):
        asked.append(headers["Authorization"])
        return {"config": {"creditUsagePercent": 40}}

    assert collect(tmp_path, Store(), http).state is ProviderSourceState.READY
    assert asked == ["Bearer synthetic-stored"]


@pytest.mark.parametrize("replacement", ["synthetic-new", "synthetic-cli"])
def test_401_rereads_cli_source_and_retries_only_a_changed_token(tmp_path, replacement):
    write_auth(tmp_path)
    asked = []

    def http(*_a, headers, **_k):
        asked.append(headers["Authorization"])
        if len(asked) == 1:
            write_auth(tmp_path, token=replacement)
            raise collectors.ProviderHttpError(401, "http_error")
        return {"config": {"creditUsagePercent": 40}}

    result = collect(tmp_path, Store(), http)
    assert len(asked) == (2 if replacement == "synthetic-new" else 1)
    assert result.state.value == ("ready" if replacement == "synthetic-new" else "needs_sign_in")


@pytest.mark.parametrize("status", [401, 429])
def test_changed_token_retry_is_bounded_and_never_retries_a_429(tmp_path, status):
    write_auth(tmp_path)
    asked = []

    def http(*_a, **_k):
        asked.append(True)
        write_auth(tmp_path, token="synthetic-new")
        raise collectors.ProviderHttpError(status, "http_error")

    result = collect(tmp_path, Store(), http)
    assert len(asked) == (2 if status == 401 else 1)
    assert result.state.value == ("needs_sign_in" if status == 401 else "rate_limited")


def test_named_reconnect_never_inspects_or_deletes_default_cli_source(tmp_path, monkeypatch):
    store = Store()
    monkeypatch.setattr(provider_reconnect, "grok_auth_status", lambda *_a: pytest.fail("default CLI source read"))
    result = provider_reconnect.repair_grok_credential(store, home=tmp_path, now=1000, source_instance_id="second")
    assert result.outcome.value == "already_healthy"
    assert store.values["grok", "default", "token"] == "synthetic-stored"
    rejected = provider_reconnect.repair_grok_credential(store, home=tmp_path, now=1000,
                                                        source_instance_id="second", server_rejected=True)
    assert rejected.outcome.value == "needs_sign_in"
    assert "grok login" not in rejected.message


class Timer:
    def __init__(self, interval, callback):
        self.interval, self.callback = interval, callback
        self.cancelled = False

    def start(self):
        pass

    def cancel(self):
        self.cancelled = True


def service_fixture(home, *, consent=True, terminal=True):
    clock = [1000.0]
    timers = []
    settings = default_provider_usage_settings().with_usage_consent("grok", consent, source="settings", at=1000)
    state = ProviderUsageState((failure_snapshot("grok", observed_at=1000,
                              state=ProviderSourceState.NEEDS_SIGN_IN, reason="authentication_required", action="Run grok login"),),
                              1000, 2800, False)

    def timer_factory(interval, callback):
        timer = Timer(interval, callback)
        timers.append(timer)
        return timer

    service = ProviderUsageService(settings_loader=lambda: settings, collectors={"grok": lambda *_a: None},
                                   credentials=Store(), home=home, clock=lambda: clock[0], timer_factory=timer_factory)
    service._state = state
    service._settings_snapshot = settings
    service._failure_gates[("grok", "default")] = FailureGate(
        terminal=terminal, terminal_fingerprint=credential_fingerprint(home, "grok"), retry_at=1500,
    )
    service._scheduled_callback = lambda *_a: None
    return service, clock, timers


def test_terminal_auth_watch_preserves_usage_cadence_and_does_not_move_its_deadline(tmp_path, monkeypatch):
    write_auth(tmp_path, expiry=900)
    service, clock, timers = service_fixture(tmp_path)
    monkeypatch.setattr(service, "request", lambda **_k: pytest.fail("unchanged auth triggered a collection"))
    try:
        service._schedule_due_locked()
        assert timers[-1].interval == 60
        assert service.snapshot().next_refresh_at == 2800
        clock[0] = 1020
        service._schedule_due_locked()
        assert timers[-1].interval == 40, "normal ticks must not postpone credential pickup"
        clock[0] = 1060
        timers[-1].callback()
        assert timers[-1].interval == 60
        assert service.snapshot().next_refresh_at == 2800
    finally:
        service.close()


def test_changed_cli_signin_bypasses_cadence_only_for_default_grok(tmp_path, monkeypatch):
    write_auth(tmp_path, expiry=900)
    service, clock, timers = service_fixture(tmp_path)
    started = []
    monkeypatch.setattr(service, "_start_worker_locked", lambda **kwargs: started.append(kwargs))
    try:
        service._schedule_due_locked()
        write_auth(tmp_path, token="synthetic-new-longer", expiry=5000)
        clock[0] = 1060
        timers[-1].callback()
        assert len(started) == 1
        assert started[0]["providers"] == (("grok", "default"),)
        assert started[0]["force"] is False
    finally:
        service.close()


@pytest.mark.parametrize("consent,terminal", [(False, True), (True, False)])
def test_no_credential_watch_without_consent_or_during_429_backoff(tmp_path, monkeypatch, consent, terminal):
    service, _clock, timers = service_fixture(tmp_path, consent=consent, terminal=terminal)
    monkeypatch.setattr("jrbar.provider_usage_runtime.credential_fingerprint", lambda *_a: pytest.fail("unexpected source inspection"))
    try:
        service._schedule_due_locked()
        assert timers[-1].interval == 1800
        assert not service._changed_auth_providers_locked()
    finally:
        service.close()


def test_a_named_profile_does_not_arm_default_cli_watch(tmp_path):
    service, _clock, timers = service_fixture(tmp_path)
    service._failure_gates[("grok", "second")] = service._failure_gates.pop(("grok", "default"))
    service._state = replace(service._state, snapshots=(replace(service._state.snapshots[0], source_instance_id="second"),))
    try:
        service._schedule_due_locked()
        assert timers[-1].interval == 1800
    finally:
        service.close()


def test_new_cli_signin_produces_fresh_usage_without_disturbing_another_429(tmp_path, monkeypatch):
    write_auth(tmp_path, expiry=900)
    service, clock, timers = service_fixture(tmp_path)
    asked = []

    def http(*_a, headers, **_k):
        asked.append(headers["Authorization"])
        return {"config": {"creditUsagePercent": 40}}

    def collector(preference, home, observed, credentials):
        return collectors.collect_grok(preference, home=home, observed_at=observed,
                                       credentials=credentials, http_json=http)

    service._collectors["grok"] = collector
    limited = failure_snapshot("codex", observed_at=1000, state=ProviderSourceState.RATE_LIMITED,
                               reason="rate_limited", action="Retry later")
    service._state = replace(service._state, snapshots=(*service._state.snapshots, limited))
    other_gate = FailureGate(strikes=2, retry_at=1800)
    service._failure_gates[("codex", "default")] = other_gate
    results = []
    monkeypatch.setattr(service, "_start_worker_locked", lambda **kwargs: results.append(
        service.refresh_now(providers=kwargs["providers"], force=kwargs["force"])))
    try:
        service._schedule_due_locked()
        write_auth(tmp_path, token="synthetic-new-longer", expiry=5000)
        clock[0] = 1060
        timers[-1].callback()
        reading = results[0].by_provider("grok")
        assert asked == ["Bearer synthetic-new-longer"]
        assert reading.state is ProviderSourceState.READY
        assert reading.effective_read_at == 1060
        assert reading.lanes[0].remaining_percent == 60
        assert results[0].by_provider("codex") == limited
        assert service._failure_gates[("codex", "default")] == other_gate
        assert not service._watched_auth_providers_locked()
    finally:
        service.close()


@pytest.mark.parametrize("provider", ["grok", "claude", "codex", "gemini"])
def test_default_cli_rotation_does_not_lift_named_profile_auth_gate(tmp_path, monkeypatch, provider):
    settings = default_provider_usage_settings()
    settings = settings.with_instance(replace(settings.preference(provider), source_instance_id="second"))
    fingerprint = ["synthetic-old"]
    probes = []

    def default_fingerprint(*_args):
        probes.append(True)
        return tuple(fingerprint)

    monkeypatch.setattr("jrbar.provider_usage_runtime.credential_fingerprint", default_fingerprint)
    calls = []
    clock = [1000.0]

    def collector(preference, _home, observed, _credentials):
        calls.append(preference.source_instance_id)
        return replace(failure_snapshot(provider, observed_at=observed, state=ProviderSourceState.NEEDS_SIGN_IN,
                                        reason="authentication_required", action="Reconnect this profile"),
                       source_instance_id=preference.source_instance_id)

    service = ProviderUsageService(settings_loader=lambda: settings, collectors={provider: collector},
                                   credentials=Store(), home=tmp_path, clock=lambda: clock[0])
    try:
        service.refresh_now(providers=((provider, "second"),))
        assert calls == ["second"]
        assert service.snapshot().by_instance(provider, "second").state is ProviderSourceState.NEEDS_SIGN_IN
        fingerprint[0] = "synthetic-rotated"
        clock[0] = 3000.0
        service.refresh_now(providers=((provider, "second"),))
        assert calls == ["second"], "default CLI rotation retried an unrelated named credential"
        service.refresh_now(providers=((provider, "second"),), force=True)
        assert calls == ["second", "second"]
        assert not probes, "named profile inspected the default CLI sign-in"
    finally:
        service.close()
