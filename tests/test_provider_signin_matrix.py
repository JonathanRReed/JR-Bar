"""The same recovery contract applies to every provider, including stale readings."""

from dataclasses import replace
from types import SimpleNamespace

import pytest

from jrbar import core_runtime
from jrbar.provider_availability import _NEEDS_PERSON_REASONS, availability_document
from jrbar.provider_usage_platform import (
    ProviderSourceState,
    UsageLane,
    account_display_label,
    failure_snapshot,
    provider_descriptors,
)

PROVIDERS = [row.provider_id for row in provider_descriptors()]


@pytest.mark.parametrize("provider", PROVIDERS)
@pytest.mark.parametrize("state", [ProviderSourceState.NEEDS_SIGN_IN, ProviderSourceState.NEEDS_CONSENT, ProviderSourceState.STALE])
@pytest.mark.parametrize("reason", sorted(_NEEDS_PERSON_REASONS))
def test_person_actions_never_refresh_or_disappear(provider, state, reason, monkeypatch):
    snapshot = failure_snapshot(provider, observed_at=10, state=ProviderSourceState.NEEDS_SIGN_IN, reason=reason, action="Retry")
    if state is ProviderSourceState.STALE:
        lane = UsageLane(provider, "daily", "Daily", 25, 5, "account", None, None, True, "fixture")
        snapshot = replace(snapshot, state=state, lanes=(lane,))
    else:
        snapshot = replace(snapshot, state=state)
    row = availability_document(snapshot, now=10, installed=False)
    assert row["panel_visible"] and row["availability"] == "available"
    assert row["action"] and row["action"] not in {"Retry", "Retry later"}
    kind = row["action_kind"]
    if provider == "claude" and reason == "claude_keychain_access_lost":
        assert kind == "resign_in"
    elif provider == "cursor" and reason in {"browser_consent_required", "browser_session_not_imported", "browser_token_unavailable"}:
        assert kind == "sign_in"
    elif reason.startswith("cliproxy_") or provider in {"devin", "factory", "kilo", "kimi"} or state is ProviderSourceState.NEEDS_CONSENT or reason == "usage_consent_required":
        assert kind == "manage"
    else:
        assert kind == "sign_in"


@pytest.mark.parametrize("provider", PROVIDERS)
def test_sign_in_commands_do_not_fall_through_to_refresh(provider, monkeypatch):
    snapshot = failure_snapshot(provider, observed_at=10, state=ProviderSourceState.NEEDS_SIGN_IN,
                                reason="authentication_required", action="Retry")
    controller = SimpleNamespace(provider_usage_state=SimpleNamespace(snapshots=(snapshot,)),
                                 _request_provider_usage=lambda **_: pytest.fail("sign-in became a refresh"))
    calls = []
    monkeypatch.setattr(core_runtime, "_cmd_provider_sign_in",
                        lambda _controller, args: calls.append(args) or {"message": "Sign-in flow started."})
    result = core_runtime._cmd_provider_action(controller, {"provider": provider})
    assert result["message"]
    expected_manage = provider in {"devin", "factory", "kilo", "kimi"}
    assert bool(calls) is not expected_manage


@pytest.mark.parametrize("label", ["your-organization-1234abcd", "your-workspace", "org-1234abcd", "org_1234abcd",
                                 "organizations/org-1234abcd", "org/example-1234abcd", "example-1234abcd",
                                 "12345678-abcd-1234-abcd-123456789abc"])
def test_routing_ids_never_become_account_names(label):
    assert account_display_label(label) is None
    snapshot = failure_snapshot("devin", observed_at=10, state=ProviderSourceState.NEEDS_SIGN_IN, reason="authentication_required", action="Retry")
    assert replace(snapshot, account_label=label).account_label is None


@pytest.mark.parametrize("label", ["Example team", "Example Studio", "person@example.test"])
def test_real_names_remain_available(label):
    assert account_display_label(label) == label


@pytest.mark.parametrize("provider", ["factory", "kilo", "kimi", "kiro"])
@pytest.mark.parametrize("state,reason,action,expected", [
    (ProviderSourceState.RATE_LIMITED, "rate_limited", "Retry later", "Retry later"),
    (ProviderSourceState.ERROR, "network_unavailable", "Retry", "Retry"),
    (ProviderSourceState.DISABLED, "disabled", "Enable usage", None),
    (ProviderSourceState.UNSUPPORTED, "source_unavailable", "Check source", None),
])
def test_non_signin_actions_keep_the_release_behavior(provider, state, reason, action, expected):
    snapshot = failure_snapshot(provider, observed_at=10, state=state, reason=reason, action=action)
    row = availability_document(snapshot, now=10, installed=True)
    assert row.get("action", snapshot.action_label) == expected


@pytest.mark.parametrize("provider", PROVIDERS)
@pytest.mark.parametrize("reason", ["cliproxy_account_signed_out", "cliproxy_key_missing", "cliproxy_key_rejected"])
def test_proxy_sign_in_preserves_the_authentication_owner(provider, reason, monkeypatch):
    snapshot = failure_snapshot(provider, observed_at=10, state=ProviderSourceState.NEEDS_SIGN_IN,
                                reason=reason, action="Retry")
    controller = SimpleNamespace(provider_usage_state=SimpleNamespace(snapshots=(snapshot,)),
                                 _request_provider_usage=lambda **_: pytest.fail("sign-in became a refresh"))
    monkeypatch.setattr(core_runtime, "_cmd_provider_sign_in", lambda *_: pytest.fail("the provider CLI does not own proxy sign-in"))
    row = availability_document(snapshot, now=10, installed=True)
    assert row["action"] == "Reconnect CLIProxyAPI account" and row["action_kind"] == "manage"
    reply = core_runtime._cmd_provider_action(controller, {"provider": provider})
    assert "CLIProxy" in reply["message"]


@pytest.mark.parametrize("reason,action", [
    ("browser_consent_required", "Enable Cursor browser access"),
    ("browser_session_not_imported", "Import Cursor browser session"),
])
def test_cursor_browser_actions_keep_the_existing_staged_flow(reason, action, monkeypatch):
    snapshot = failure_snapshot("cursor", observed_at=10, state=ProviderSourceState.NEEDS_CONSENT,
                                reason=reason, action=action)
    row = availability_document(snapshot, now=10, installed=True)
    assert row["action"] == action and row["action_kind"] == "sign_in"
    calls = []
    controller = SimpleNamespace(provider_usage_state=SimpleNamespace(snapshots=(snapshot,)),
                                 _request_provider_usage=lambda **_: pytest.fail("staged import became a refresh"))
    monkeypatch.setattr(core_runtime, "_cmd_provider_sign_in",
                        lambda _controller, args: calls.append(args) or {"message": "Staged flow started."})
    reply = core_runtime._cmd_provider_action(controller, {"provider": "cursor"})
    assert calls == [{"provider": "cursor", "instance": "default"}]
    assert reply["message"] == "Staged flow started."


@pytest.mark.parametrize("provider,action,kind", [
    ("factory", "Add Factory API key", "manage"),
    ("devin", "Add Devin API key", "manage"),
    ("cursor", "Import Cursor browser session", "sign_in"),
])
def test_incomplete_browser_token_has_a_working_alternative(provider, action, kind):
    snapshot = failure_snapshot(provider, observed_at=10, state=ProviderSourceState.NEEDS_SIGN_IN,
                                reason="browser_token_unavailable", action="Retry")
    row = availability_document(snapshot, now=10, installed=False)
    assert row["action"] == action and row["action_kind"] == kind
    assert "expired" not in row["status_text"].lower()
    assert row["panel_visible"]
