"""Factory tests use synthetic accounts, keys and an injected transport."""

from copy import deepcopy
from types import SimpleNamespace

import pytest

from jrbar.provider_usage_collectors import ProviderHttpError
from jrbar.provider_usage_factory import collect_factory, parse_factory_usage
from jrbar.provider_usage_platform import ProviderSourceState


def billing(core=False):
    pool = {"fiveHour": {"usedPercent": 12, "secondsRemaining": 300},
            "weekly": {"usedPercent": 34, "windowEnd": 2000},
            "monthly": {"usedPercent": 56}}
    limits = {"standard": pool}
    if core:
        limits["core"] = deepcopy(pool)
    return {"usesTokenRateLimitsBilling": True, "limits": limits,
            "extraUsageBalanceCents": 2500}


def auth(user="synthetic-user", org="synthetic-org"):
    return {"userProfile": {"id": user}, "organization": {
        "id": org, "subscription": {"factoryTier": "synthetic-plan"}}}


def preference(**kwargs):
    return SimpleNamespace(enabled=True, usage_consented=True, source_instance_id="default", **kwargs)


class Store:
    def __init__(self, key="synthetic-key"):
        self.key = key
        self.calls = []

    def get(self, provider, account):
        self.calls.append((provider, account))
        return SimpleNamespace(available=account == "api-key" and self.key is not None, secret=self.key if account == "api-key" else None, reason="credential_not_found" if account != "api-key" else None)


def test_independent_standard_and_core_lanes_and_no_money_invention():
    result = parse_factory_usage(billing(True), observed_at=1000, auth=auth())
    assert [lane.lane_id for lane in result.lanes] == [
        "standard-5h", "standard-7d", "standard-30d", "core-5h", "core-7d", "core-30d"]
    assert [lane.remaining_percent for lane in result.lanes] == [88, 66, 44, 88, 66, 44]
    assert [lane.reset_at for lane in result.lanes[:3]] == [1300, 2000, None]
    assert {lane.scope for lane in result.lanes} == {"standard", "core"}
    assert all(lane.source_id == "factory-billing-limits" for lane in result.lanes)
    assert result.credits_remaining is None
    assert result.estimated_cost_usd is None
    assert result.input_tokens == result.output_tokens == 0
    assert result.account_plan == "synthetic-plan"


@pytest.mark.parametrize("value", [None, True, -1, float("nan"), float("inf"), "12"])
def test_invalid_percent_rejects_the_reading(value):
    payload = billing()
    payload["limits"]["standard"]["fiveHour"]["usedPercent"] = value
    with pytest.raises(ValueError):
        parse_factory_usage(payload, observed_at=1000)


@pytest.mark.parametrize("change", ["missing-window", "missing-standard", "bad-core", "missing-mode"])
def test_malformed_schema_rejects_instead_of_fabricating_lanes(change):
    payload = billing()
    if change == "missing-window":
        del payload["limits"]["standard"]["weekly"]
    elif change == "missing-standard":
        del payload["limits"]["standard"]
    elif change == "bad-core":
        payload["limits"]["core"] = {}
    else:
        del payload["usesTokenRateLimitsBilling"]
    with pytest.raises(ValueError):
        parse_factory_usage(payload, observed_at=1000)


@pytest.mark.parametrize("reset,expected", [(500, 500), (1790000000000, 1790000000),
                                          ("1970-01-01T00:08:20Z", 500)])
def test_past_reset_keeps_observed_usage(reset, expected):
    payload = billing()
    payload["limits"]["standard"]["fiveHour"] = {"usedPercent": 120, "windowEnd": reset}
    lane = parse_factory_usage(payload, observed_at=2000000000).lanes[0]
    assert lane.remaining_percent == 0
    assert lane.reset_at == expected


def test_identity_changes_only_with_proved_user_and_org():
    first = parse_factory_usage(billing(), observed_at=1000, auth=auth())
    rotated = parse_factory_usage(billing(), observed_at=1001, auth=auth())
    changed = parse_factory_usage(billing(), observed_at=1001, auth=auth("other-user"))
    assert first.account_discriminator == rotated.account_discriminator
    assert first.account_discriminator != changed.account_discriminator
    assert "synthetic-user" not in first.account_discriminator
    for missing in (None, {}, auth(None), auth(org=None)):
        assert parse_factory_usage(billing(), observed_at=1000, auth=missing).account_discriminator is None


@pytest.mark.parametrize("enabled,consented,state", [
    (False, True, ProviderSourceState.DISABLED), (True, False, ProviderSourceState.NEEDS_CONSENT)])
def test_off_or_unconsented_never_reads_credentials_or_http(enabled, consented, state):
    pref = SimpleNamespace(enabled=enabled, usage_consented=consented)
    store = Store()
    def forbidden(*_args, **_kwargs):
        pytest.fail("HTTP must remain off")
    result = collect_factory(pref, observed_at=1000, credentials=store, http_json=forbidden)
    assert result.state is state
    assert store.calls == []


def test_missing_key_is_actionable_without_http():
    result = collect_factory(preference(), observed_at=1000, credentials=Store(None),
                             http_json=lambda *_a, **_k: pytest.fail("no key"))
    assert result.action_label == "Add Factory API key"
    assert result.lanes == ()


def test_collection_uses_fixed_endpoints_and_only_connected_key():
    calls = []
    def http(method, url, *, headers):
        assert method == "GET"
        calls.append((url, headers))
        return auth() if url.endswith("/auth/me") else billing()
    store = Store()
    result = collect_factory(preference(), observed_at=1000, credentials=store, http_json=http)
    assert result.state is ProviderSourceState.READY
    assert store.calls == [("factory", "api-key")]
    assert [url for url, _ in calls] == ["https://api.factory.ai/api/app/auth/me",
                                        "https://api.factory.ai/api/billing/limits"]
    assert all(headers["Authorization"] == "Bearer synthetic-key" for _, headers in calls)
    assert "synthetic-key" not in repr(result)


@pytest.mark.parametrize("status,state,reason", [
    (401, ProviderSourceState.NEEDS_SIGN_IN, "authentication_required"),
    (403, ProviderSourceState.UNAVAILABLE, "usage_access_denied"),
    (429, ProviderSourceState.RATE_LIMITED, "rate_limited"),
    (0, ProviderSourceState.UNAVAILABLE, "network_unavailable")])
def test_errors_do_not_fall_back_or_expose_messages(status, state, reason):
    calls = []
    def http(method, url, **_kwargs):
        assert method == "GET"
        calls.append(url)
        if url.endswith("/auth/me"):
            return auth()
        raise ProviderHttpError(status, "private-secret-body")
    result = collect_factory(preference(), observed_at=1000, credentials=Store(), http_json=http)
    assert result.state is state
    assert result.reason_code == reason
    assert result.account_discriminator is not None
    assert len(calls) == 2
    assert "private-secret" not in repr(result)


def test_explicit_legacy_fallback_preserves_organization_scope():
    calls = []
    def http(method, url, **kwargs):
        assert method == "GET"
        assert kwargs["headers"]["Authorization"] == "Bearer synthetic-key"
        calls.append(url)
        if url.endswith("/auth/me"):
            return auth()
        if url.endswith("/billing/limits"):
            return {"usesTokenRateLimitsBilling": False}
        return {"usage": {"endDate": 2000, "standard": {
            "userTokens": 1, "orgTotalTokensUsed": 40, "totalAllowance": 100}}}
    result = collect_factory(preference(), observed_at=1000, credentials=Store(), http_json=http)
    assert calls == ["https://api.factory.ai/api/app/auth/me",
                     "https://api.factory.ai/api/billing/limits",
                     "https://api.factory.ai/api/organization/subscription/usage?useCache=true&userId=synthetic-user"]
    assert result.lanes[0].remaining_percent == 60
    assert result.lanes[0].scope == "organization-standard"
    assert result.lanes[0].reset_at == 2000


def test_invalid_payload_does_not_fall_back():
    calls = []
    def http(method, url, **_kwargs):
        assert method == "GET"
        calls.append(url)
        return auth() if url.endswith("/auth/me") else {"usesTokenRateLimitsBilling": True}
    result = collect_factory(preference(), observed_at=1000, credentials=Store(), http_json=http)
    assert result.reason_code == "invalid_response"
    assert len(calls) == 2


def test_named_profile_uses_instance_credential_view():
    from jrbar.provider_instances import ProviderInstanceKey
    from jrbar.provider_usage_runtime import _InstanceCredentialView
    class ScopedStore:
        def get_for_instance(self, key, account):
            assert key == ProviderInstanceKey("factory", "secondary")
            if account == "web-session":
                return SimpleNamespace(available=False, secret=None, reason="credential_not_found")
            assert account == "api-key"
            return SimpleNamespace(available=True, secret="named-key")
        def get(self, *_args):
            pytest.fail("must not borrow default key")
    pref = preference()
    pref.source_instance_id = "secondary"
    def http(method, url, *, headers):
        assert method == "GET"
        assert headers["Authorization"] == "Bearer named-key"
        return auth("named-user") if url.endswith("/auth/me") else billing()
    result = collect_factory(pref, observed_at=1000,
                             credentials=_InstanceCredentialView(ScopedStore(), ProviderInstanceKey("factory", "secondary")),
                             http_json=http)
    assert result.source_instance_id == "secondary"
    assert result.state is ProviderSourceState.READY


def test_legacy_ratio_is_explicit_and_missing_counts_do_not_become_zero():
    result = parse_factory_usage({"usesTokenRateLimitsBilling": False, "usage": {
        "premium": {"usedRatio": 0.25}}}, observed_at=1000)
    assert result.lanes[0].remaining_percent == 75
    assert result.lanes[0].lane_id == "premium-billing"
    with pytest.raises(ValueError):
        parse_factory_usage({"usesTokenRateLimitsBilling": False, "usage": {
            "standard": {"userTokens": 1, "totalAllowance": 100}}}, observed_at=1000)


@pytest.mark.parametrize("reason", ["invalid_json", "response_too_large"])
def test_transport_payload_errors_are_invalid_response(reason):
    def http(*_args, **_kwargs):
        raise ProviderHttpError(200, reason)
    result = collect_factory(preference(), observed_at=1000, credentials=Store(), http_json=http)
    assert result.state is ProviderSourceState.ERROR
    assert result.reason_code == "invalid_response"


@pytest.mark.parametrize("key", ["synthetic\r\nInjected: value", "synthetic\tkey", "synthetic\x7fkey"])
def test_header_control_characters_never_reach_transport(key):
    result = collect_factory(preference(), observed_at=1000, credentials=Store(key),
                             http_json=lambda *_a, **_k: pytest.fail("unsafe header"))
    assert result.state is ProviderSourceState.NEEDS_SIGN_IN


def test_failed_read_after_account_rollover_carries_only_new_identity():
    selected = [auth()]
    def http(_method, url, **_kwargs):
        if url.endswith("/auth/me"):
            return selected[0]
        if selected[0] != auth():
            raise ProviderHttpError(429, "private-body")
        return billing()
    first = collect_factory(preference(), observed_at=1000, credentials=Store(), http_json=http)
    selected[0] = auth("other-user")
    second = collect_factory(preference(), observed_at=1001, credentials=Store(), http_json=http)
    assert second.account_discriminator != first.account_discriminator
    assert second.account_plan is None
    assert second.lanes == ()
