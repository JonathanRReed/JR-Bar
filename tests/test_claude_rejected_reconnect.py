"""A server-rejected access token is not healthy just because it is unexpired."""

import json
from types import SimpleNamespace

import pytest

from jrbar.provider_reconnect import RepairOutcome, reconnect_provider
from jrbar.provider_sign_in import ProviderSignIn, SignInResult


class Store:
    def __init__(self):
        self.values = {("claude", "oauth-token"): "rejected-token"}

    def get(self, provider, account):
        secret = self.values.get((provider, account))
        return SimpleNamespace(available=secret is not None, secret=secret)

    def set(self, provider, account, secret):
        self.values[(provider, account)] = secret


def reconnect(store, reason, token="rejected-token"):
    return reconnect_provider(
        "claude",
        credential_store=store,
        reason_code=reason,
        now=1000.0,
        keychain_payload_reader=lambda: json.dumps({
            "claudeAiOauth": {"accessToken": token, "expiresAt": 2000000},
        }),
    )


def test_unchanged_rejected_token_requires_provider_refresh():
    result = reconnect(Store(), "authentication_required")
    assert result.outcome is RepairOutcome.NEEDS_PROVIDER_REFRESH
    assert not result.changed


@pytest.mark.parametrize("reason", [None, "usage_permission_missing", "rate_limited"])
def test_other_reasons_do_not_request_renewal(reason):
    assert reconnect(Store(), reason).outcome is RepairOutcome.ALREADY_HEALTHY


def test_changed_token_can_repair_a_rejected_sign_in():
    store = Store()
    result = reconnect(store, "authentication_required", token="fresh-token")
    assert result.outcome is RepairOutcome.REPAIRED
    assert result.changed
    assert store.values[("claude", "oauth-token")] == "fresh-token"


def test_fix_sign_in_attempts_provider_renewal_for_unchanged_rejected_token():
    class Fixer(ProviderSignIn):
        def _renew_claude(self, reread, *, reason_code=None):
            assert reread.outcome is RepairOutcome.NEEDS_PROVIDER_REFRESH
            assert reason_code == "authentication_required"
            return SignInResult("renewed", "Synthetic renewal attempted.")

    store = Store()
    def reread(provider, instance, reason_code=None):
        return reconnect(store, reason_code)

    fixer = Fixer(reconnect=reread)
    assert fixer.sign_in("claude", reason_code="authentication_required").outcome == "renewed"
