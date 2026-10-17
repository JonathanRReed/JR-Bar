"""Synthetic provider auth recovery, without Keychain or network access."""

import io
import json
import threading
from pathlib import Path
from types import SimpleNamespace
from urllib.error import HTTPError

import pytest

from jrbar import claude_quota, provider_reconnect
from jrbar import provider_usage_codex_claude as claude
from jrbar import provider_usage_collectors as collectors
from jrbar.claude_statusline_source import StatusLineReading, StatusLineWindow


class Store:
    def __init__(self):
        self.values = {("claude", "oauth-token"): "synthetic-old", ("claude", "oauth-expires-at"): "9000"}

    def get(self, provider, account):
        return SimpleNamespace(available=(provider, account) in self.values, secret=self.values.get((provider, account)))

    def set(self, provider, account, value):
        self.values[provider, account] = value


@pytest.fixture(autouse=True)
def isolated(monkeypatch):
    claude._oauth_rest_until.clear()
    monkeypatch.setattr(provider_reconnect, "sync_claude_credential_in_background", lambda *_a, **_k: False)
    monkeypatch.setattr(claude_quota, "account_facts_from_claude_config", lambda *_a: (None, None))
    yield
    claude._oauth_rest_until.clear()


def collect(store, fetcher, *, now=1000, reading=False, instance="default"):
    return claude.collect_claude(
        SimpleNamespace(source_instance_id=instance), home=Path("/synthetic"), observed_at=now,
        credentials=store, quota_fetcher=fetcher, local_scanner=lambda *_a: None,
        statusline_reader=lambda stamp: StatusLineReading(None, None, (
            ("five_hour", StatusLineWindow(25, 5000)),
        ), stamp) if reading else None,
    )


def good_windows():
    return [{"id": "five-hour", "label": "5-hour", "remaining_percent": 60, "resets_at": 5000}]


@pytest.mark.parametrize("replacement", ["synthetic-new", None, "synthetic-old"])
def test_claude_401_rereads_once_and_retries_only_a_changed_token(monkeypatch, replacement):
    store = Store()
    asked, synced = [], []

    def sync(*_a, **_k):
        synced.append(True)
        store.values["claude", "oauth-token"] = replacement

    def fetch(token):
        asked.append(token)
        if token == "synthetic-old":
            raise RuntimeError("claude_remote_quota_unauthorized")
        return good_windows()

    monkeypatch.setattr(provider_reconnect, "sync_claude_credential_in_background", sync)
    result = collect(store, fetch)
    assert len(synced) == 1
    assert len(asked) == (2 if replacement == "synthetic-new" else 1)
    assert result.state.value == ("ready" if replacement == "synthetic-new" else "needs_sign_in")


def test_claude_reloaded_token_rejection_does_not_loop(monkeypatch):
    store = Store()
    asked, synced = [], []

    def sync(*_a, **_k):
        synced.append(True)
        store.values["claude", "oauth-token"] = "synthetic-new"

    def fetch(token):
        asked.append(token)
        raise RuntimeError("claude_remote_quota_unauthorized")

    monkeypatch.setattr(provider_reconnect, "sync_claude_credential_in_background", sync)
    assert collect(store, fetch).state.value == "needs_sign_in"
    assert len(asked) == 2 and len(synced) == 1


@pytest.mark.parametrize("failure", ["unauthorized", "rate_limited"])
def test_claude_new_token_clears_auth_rest_but_preserves_429_rest(failure):
    store = Store()
    asked = []

    def fetch(token):
        asked.append(token)
        if token == "synthetic-old":
            raise RuntimeError("claude_remote_quota_" + failure)
        return good_windows()

    collect(store, fetch, reading=True)
    store.values["claude", "oauth-token"] = "synthetic-new"
    result = collect(store, fetch, now=1001, reading=True)
    assert len(asked) == (2 if failure == "unauthorized" else 1)
    assert result.state.value == "ready"
    assert result.lanes[0].source_id == ("claude-oauth" if failure == "unauthorized" else "claude-statusline")


def test_claude_same_token_updates_missing_expiry():
    store = Store()
    store.values.pop(("claude", "oauth-expires-at"))
    result = provider_reconnect.repair_claude_credential(store, now=1000, keychain_payload_reader=lambda: json.dumps({
        "claudeAiOauth": {"accessToken": "synthetic-old", "expiresAt": 9000},
    }))
    assert result.outcome.value == "already_healthy"
    assert store.values["claude", "oauth-expires-at"] == "9000"
    assert not provider_reconnect.claude_token_is_stale(store, now=1000)


@pytest.mark.parametrize("body,reason,state,code", [
    (b'{"error":{"type":"permission_error","message":"private fixture"}}', "permission_denied", "unavailable", "usage_permission_missing"),
    (b'{"error":{"type":"unsupported_endpoint"}}', "unsupported_usage", "unsupported", "usage_source_unsupported"),
    (b"<html>Denied</html>", "access_denied", "unavailable", "usage_access_denied"),
    (b'{"error":{"type":"unknown"}}', "access_denied", "unavailable", "usage_access_denied"),
])
def test_grok_403_preserves_safe_categories_and_never_requests_login(monkeypatch, body, reason, state, code):
    monkeypatch.setattr(collectors, "_read_grok_auth", lambda *_a: collectors._GrokAuthRead(("synthetic-grok", None)))
    classified = collectors._http_error_reason(403, body)
    assert classified == reason

    def failed(*_a, **_k):
        raise collectors.ProviderHttpError(403, classified)

    result = collectors.collect_grok(SimpleNamespace(), home=Path("/synthetic"), observed_at=1000, credentials=None, http_json=failed)
    assert result.state.value == state and result.reason_code == code
    assert "login" not in result.action_label.lower()
    assert "private fixture" not in repr(result)


def test_http_transport_preserves_403_category_without_retaining_body(monkeypatch):
    body = b'{"error":{"type":"permission_error","message":"private fixture"}}'

    class Opener:
        def open(self, request, timeout):
            raise HTTPError(request.full_url, 403, "Forbidden", {}, io.BytesIO(body))

    monkeypatch.setattr(collectors, "build_opener", lambda *_a: Opener())
    with pytest.raises(collectors.ProviderHttpError) as caught:
        collectors._default_http_json("GET", "https://fixture.invalid/usage")
    assert caught.value.status == 403
    assert caught.value.reason == "permission_denied"
    assert "private fixture" not in str(caught.value)


def test_grok_401_remains_authentication_required(monkeypatch):
    monkeypatch.setattr(collectors, "_read_grok_auth", lambda *_a: collectors._GrokAuthRead(("synthetic-grok", None)))

    def failed(*_a, **_k):
        raise collectors.ProviderHttpError(401, "http_error")

    result = collectors.collect_grok(SimpleNamespace(), home=Path("/synthetic"), observed_at=1000, credentials=None, http_json=failed)
    assert result.state.value == "needs_sign_in"
    assert result.action_label == "Run grok login"


@pytest.mark.parametrize("failure", ["unauthorized", "rate_limited"])
def test_same_token_reconnect_clears_auth_rest_but_preserves_rate_limit(failure):
    store = Store()
    asked = []

    def fetch(token):
        asked.append(token)
        raise RuntimeError("claude_remote_quota_" + failure)

    collect(store, fetch, reading=True)
    provider_reconnect.repair_claude_credential(store, now=1001, keychain_payload_reader=lambda: json.dumps({
        "claudeAiOauth": {"accessToken": "synthetic-old", "expiresAt": 9000},
    }))
    collect(store, fetch, now=1002, reading=True)
    assert len(asked) == (2 if failure == "unauthorized" else 1)


def test_auth_rest_invalidation_is_instance_scoped():
    claude._oauth_rest_until.update({
        ("/synthetic", "default"): (2800, "digest-a", "authentication_required"),
        ("/synthetic", "second"): (2800, "digest-b", "authentication_required"),
        ("/other-synthetic", "default"): (1600, "digest-c", "rate_limited"),
    })
    claude.clear_claude_auth_rest()
    assert ("/synthetic", "default") not in claude._oauth_rest_until
    assert ("/synthetic", "second") in claude._oauth_rest_until
    assert ("/other-synthetic", "default") in claude._oauth_rest_until


@pytest.mark.parametrize("expiry", ["9000", "900"])
def test_named_claude_instance_never_rereads_default_keychain(monkeypatch, expiry):
    from jrbar.provider_instances import ProviderInstanceKey
    from jrbar.provider_usage_runtime import _InstanceCredentialView

    class ScopedStore(Store):
        def get_for_instance(self, key, account):
            assert key == ProviderInstanceKey("claude", "second")
            return super().get("claude", account)

    store = ScopedStore()
    store.values["claude", "oauth-expires-at"] = expiry
    scoped = _InstanceCredentialView(store, ProviderInstanceKey("claude", "second"))
    asked = []

    def forbidden_reread(*_a, **_k):
        pytest.fail("Named profile tried to copy default Claude Code credentials")

    def fetch(token):
        asked.append(token)
        raise RuntimeError("claude_remote_quota_unauthorized")

    monkeypatch.setattr(provider_reconnect, "sync_claude_credential_in_background", forbidden_reread)
    result = collect(scoped, fetch, instance="second")
    assert result.state.value == "needs_sign_in"
    assert asked == ["synthetic-old"]
    assert store.values["claude", "oauth-token"] == "synthetic-old"


def test_background_sync_refuses_named_profile_before_any_keychain_read(monkeypatch):
    from jrbar import credentials

    monkeypatch.setattr(credentials, "read_keychain_secret", lambda *_a, **_k: pytest.fail("Default grant used"))
    assert not provider_reconnect.sync_claude_credential_in_background(
        Store(), home=Path("/synthetic"), now=1000, source_instance_id="second",
    )


def test_reconnect_cannot_remove_a_concurrently_recorded_rate_limit(monkeypatch):
    entered, proceed, writing = threading.Event(), threading.Event(), threading.Event()
    key = ("/synthetic", "default")
    rate_limit = (1600, "digest-new", "rate_limited")

    class PausedRest(dict):
        def items(self):
            entries = tuple(super().items())
            entered.set()
            assert proceed.wait(2)
            return entries

    rest = PausedRest({key: (2800, "digest-old", "authentication_required")})
    monkeypatch.setattr(claude, "_oauth_rest_until", rest)

    def record_rate_limit():
        writing.set()
        with claude._oauth_rest_lock:
            rest[key] = rate_limit

    reconnect = threading.Thread(target=claude.clear_claude_auth_rest)
    writer = threading.Thread(target=record_rate_limit)
    reconnect.start()
    try:
        assert entered.wait(2)
        writer.start()
        assert writing.wait(2)
    finally:
        proceed.set()
        reconnect.join(2)
        if writer.ident is not None:
            writer.join(2)
    assert not reconnect.is_alive() and not writer.is_alive()
    assert rest[key] == rate_limit
