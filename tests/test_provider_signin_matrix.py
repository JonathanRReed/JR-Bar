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
    elif provider in {"devin", "factory", "kilo", "kimi"} or state is ProviderSourceState.NEEDS_CONSENT or reason == "usage_consent_required":
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
