"""A status-line fallback must not mask a renewed, consented Claude token."""

import json
from types import SimpleNamespace

import pytest

from jrbar.provider_usage_codex_claude import (
    _claude_credential_identity,
    _oauth_rest_until,
    collect_claude,
)
from jrbar.provider_usage_settings import default_provider_usage_settings
from tests.test_claude_rejected_reconnect import Store
from tests.test_claude_statusline_source import LIMITS, NOW, minimize, statusline_payload


@pytest.fixture
def recovery(tmp_path, monkeypatch):
    _oauth_rest_until.clear()
    store = Store()
    store.set("claude", "oauth-expires-at", str(NOW + 3600))
    key = (str(tmp_path), "default")
    _oauth_rest_until[key] = (NOW + 1800, _claude_credential_identity(store), "authentication_required")
    reading = minimize(statusline_payload(**LIMITS), now=NOW)
    reads, fetches = [], []
    payload = {"token": "renewed-token", "allowed": True}

    def read_keychain(_service, *, allow_prompt, ledger):
        assert not allow_prompt
        reads.append(True)
        if "during_read" in payload:
            payload["during_read"]()
        secret = json.dumps({"claudeAiOauth": {
            "accessToken": payload["token"], "expiresAt": (NOW + 5000) * 1000,
        }})
        return SimpleNamespace(ok=payload["allowed"], secret=secret if payload["allowed"] else None)

    monkeypatch.setattr("jrbar.credentials.read_keychain_secret", read_keychain)
    monkeypatch.setattr("jrbar.providers.default_state_dir", lambda: tmp_path / "state")

    def collect():
        def fetch(token):
            fetches.append(token)
            return [{"label": "5-hour", "used_percent": 15, "resets_at": NOW + 3600}]
        return collect_claude(
            default_provider_usage_settings().preference("claude"),
            home=tmp_path, observed_at=NOW, credentials=store, quota_fetcher=fetch,
            local_scanner=lambda *_args: None, statusline_reader=lambda _now: reading,
        )

    yield store, key, payload, reads, fetches, collect
    _oauth_rest_until.clear()


def test_renewed_token_resumes_oauth_without_waiting_for_auth_rest(recovery):
    store, key, _, reads, fetches, collect = recovery
    result = collect()
    assert reads == [True]
    assert fetches == ["renewed-token"]
    assert store.get("claude", "oauth-token").secret == "renewed-token"
    assert {lane.source_id for lane in result.lanes} == {"claude-oauth"}
    assert key not in _oauth_rest_until


def test_unchanged_rejected_token_keeps_auth_rest(recovery):
    _, key, payload, reads, fetches, collect = recovery
    payload["token"] = "rejected-token"
    before = _oauth_rest_until[key]
    result = collect()
    assert reads == [True]
    assert fetches == []
    assert _oauth_rest_until[key] == before
    assert {lane.source_id for lane in result.lanes} == {"claude-statusline"}


def test_refused_background_read_keeps_fallback_and_rest(recovery):
    _, key, payload, reads, fetches, collect = recovery
    payload["allowed"] = False
    before = _oauth_rest_until[key]
    result = collect()
    assert reads == [True]
    assert fetches == []
    assert _oauth_rest_until[key] == before
    assert {lane.source_id for lane in result.lanes} == {"claude-statusline"}


@pytest.mark.parametrize("reason", [
    "rate_limited", "usage_permission_missing", "network_unavailable", "usage_connection_required",
])
def test_other_rests_do_not_probe_or_retry(recovery, reason):
    _, key, _, reads, fetches, collect = recovery
    until, identity, _ = _oauth_rest_until[key]
    _oauth_rest_until[key] = (until, identity, reason)
    before = _oauth_rest_until[key]
    result = collect()
    assert reads == []
    assert fetches == []
    assert _oauth_rest_until[key] == before
    assert {lane.source_id for lane in result.lanes} == {"claude-statusline"}


def test_new_rate_limit_during_token_pickup_still_blocks_oauth(recovery):
    store, key, payload, _, fetches, collect = recovery

    def rate_limit():
        until, identity, _ = _oauth_rest_until[key]
        _oauth_rest_until[key] = (until, identity, "rate_limited")

    payload["during_read"] = rate_limit
    result = collect()
    assert store.get("claude", "oauth-token").secret == "renewed-token"
    assert _oauth_rest_until[key][2] == "rate_limited"
    assert fetches == []
    assert {lane.source_id for lane in result.lanes} == {"claude-statusline"}


def test_failed_token_copy_does_not_clear_auth_rest(recovery, monkeypatch):
    store, key, _, _, fetches, collect = recovery
    before = _oauth_rest_until[key]

    def refuse_write(*_args):
        raise OSError("Synthetic store refusal")

    monkeypatch.setattr(store, "set", refuse_write)
    result = collect()
    assert store.get("claude", "oauth-token").secret == "rejected-token"
    assert _oauth_rest_until[key] == before
    assert fetches == []
    assert {lane.source_id for lane in result.lanes} == {"claude-statusline"}
