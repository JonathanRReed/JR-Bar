"""Kilo reads use synthetic auth files and an injected transport."""
import json
from types import SimpleNamespace

import pytest

from jrbar.provider_usage_collectors import ProviderHttpError
from jrbar.provider_usage_kilo import collect_kilo, parse_kilo_usage
from jrbar.provider_usage_platform import ProviderSourceState


def batch(credits=None, subscription=None):
    return [{"result": {"data": {"json": value}}} for value in [
        credits if credits is not None else {"creditBlocks": [{"amount_mUsd": 10000000, "balance_mUsd": 6000000}]},
        {"subscription": subscription}, None]]


class Store:
    def __init__(self):
        self.calls = []

    def get(self, provider, account):
        self.calls.append((provider, account))
        return SimpleNamespace(available=True, secret="synthetic-key")


def pref(**changes):
    return SimpleNamespace(**dict(enabled=True, usage_consented=True, source_instance_id="synthetic", **changes))


def test_credit_blocks_and_pass_keep_separate_allowances():
    result = parse_kilo_usage(batch(subscription={"currentPeriodUsageUsd": 4,
        "currentPeriodBaseCreditsUsd": 10, "currentPeriodBonusCreditsUsd": 6,
        "nextBillingAt": "2030-01-01T00:00:00Z", "tier": "tier_49"}), observed_at=100)
    assert result.credits_remaining == 6
    assert [lane.remaining_percent for lane in result.lanes] == [60, 75]
    assert result.lanes[0].reset_at is None
    assert result.lanes[1].reset_at == 1893456000
    assert result.estimated_cost_usd is None
    assert result.input_tokens == result.output_tokens == 0


def test_balance_only_has_no_invented_allowance():
    result = parse_kilo_usage(batch({"totalBalance_mUsd": 5000000}), observed_at=100)
    assert result.credits_remaining == 5
    assert result.lanes == ()


def test_cli_auth_precedes_key_and_uses_fixed_host(tmp_path):
    path = tmp_path / ".local/share/kilo/auth.json"
    path.parent.mkdir(parents=True)
    path.write_text(json.dumps({"kilo": {"access": "synthetic-cli"}}))
    calls = []
    store = Store()
    def transport(method, url, **kwargs):
        calls.append((method, url, kwargs))
        return batch()
    preference = SimpleNamespace(enabled=True, usage_consented=True, source_instance_id="default")
    result = collect_kilo(preference, observed_at=100, credentials=store, home=tmp_path, http_json=transport)
    assert result.state == ProviderSourceState.READY
    assert result.source_instance_id == "default"
    assert store.calls == []
    assert calls[0][0] == "GET"
    assert calls[0][1].startswith("https://app.kilo.ai/api/trpc/user.getCreditBlocks,kiloPass.getState,user.getAutoTopUpPaymentMethod?")
    assert calls[0][2]["headers"]["Authorization"] == "Bearer synthetic-cli"


@pytest.mark.parametrize("status,state", [(401, ProviderSourceState.NEEDS_SIGN_IN),
    (403, ProviderSourceState.NEEDS_SIGN_IN), (429, ProviderSourceState.RATE_LIMITED),
    (500, ProviderSourceState.UNAVAILABLE)])
def test_failure_is_scoped_and_contains_no_credentials(tmp_path, status, state):
    def transport(*args, **kwargs):
        raise ProviderHttpError(status, "synthetic-secret")
    result = collect_kilo(pref(), observed_at=100, credentials=Store(), home=tmp_path, http_json=transport)
    assert result.state == state
    assert result.source_instance_id == "synthetic"
    assert result.lanes == ()
    assert "synthetic-secret" not in repr(result)


def test_consent_blocks_auth_and_transport(tmp_path):
    store = Store()
    preference = SimpleNamespace(enabled=True, usage_consented=False, source_instance_id="synthetic")
    result = collect_kilo(preference, observed_at=100, credentials=store, home=tmp_path,
        http_json=lambda *a, **k: pytest.fail("transport called"))
    assert result.state == ProviderSourceState.NEEDS_CONSENT
    assert store.calls == []


@pytest.mark.parametrize("number", [True, -1, float("inf"), float("nan")])
def test_invalid_credit_numbers_rejected(number):
    with pytest.raises(ValueError):
        parse_kilo_usage(batch({"creditBlocks": [{"amount_mUsd": number, "balance_mUsd": 0}]}), observed_at=100)


def test_required_trpc_auth_error_is_not_ready():
    payload = batch()
    payload[0] = {"error": {"json": {"data": {"code": "UNAUTHORIZED"}}}}
    with pytest.raises(ProviderHttpError):
        parse_kilo_usage(payload, observed_at=100)


def test_named_instance_uses_own_key_and_explicit_org(tmp_path):
    path = tmp_path / ".local/share/kilo/auth.json"
    path.parent.mkdir(parents=True)
    path.write_text(json.dumps({"kilo": {"access": "other-account-cli"}}))
    store = Store()
    def transport(method, url, **kwargs):
        assert kwargs["headers"]["Authorization"] == "Bearer synthetic-key"
        assert kwargs["headers"]["X-KILOCODE-ORGANIZATIONID"] == "synthetic-org"
        return batch()
    result = collect_kilo(pref(options=(("organization_id", "synthetic-org"),)), observed_at=100,
        credentials=store, home=tmp_path, http_json=transport)
    assert store.calls == [("kilo", "api-key"), ("kilo", "api-key")]
    assert result.source_instance_id == "synthetic"
    assert all(lane.scope == "organization" for lane in result.lanes)


def test_changed_cli_session_discards_response(tmp_path):
    path = tmp_path / ".local/share/kilo/auth.json"
    path.parent.mkdir(parents=True)
    path.write_text(json.dumps({"kilo": {"access": "synthetic-cli"}}))
    def transport(*args, **kwargs):
        path.unlink()
        return batch()
    result = collect_kilo(SimpleNamespace(enabled=True, usage_consented=True, source_instance_id="default"),
        observed_at=100, credentials=Store(), home=tmp_path, http_json=transport)
    assert result.state == ProviderSourceState.NEEDS_SIGN_IN
    assert result.reason_code == "cli_session_changed"
    assert result.lanes == ()


@pytest.mark.parametrize("credits", [{"usedCredits": "4", "remainingCredits": 6},
    {"blocks": [{"consumed": 4, "limit": 10, "remaining": 6}]}])
def test_generic_credit_aliases(credits):
    result = parse_kilo_usage(batch(credits), observed_at=100)
    assert result.credits_remaining == 6
    assert result.lanes[0].remaining_percent == 60


@pytest.mark.parametrize("fields", [{"amountCents": 1000, "spentCents": 400},
    {"total_mUsd": 10000000, "used_mUsd": 4000000},
    {"included": 10, "available": 6}])
def test_generic_pass_money_aliases(fields):
    payload = batch()
    payload[1]["result"]["data"]["json"] = {"pass": {**fields, "resetAt": 2000, "planName": "Synthetic Pass"}}
    result = parse_kilo_usage(payload, observed_at=100)
    assert result.lanes[1].remaining_percent == 60
    assert result.lanes[1].reset_at == 2000
    assert result.account_plan == "Synthetic Pass"


def test_credential_provenance_and_mutation(tmp_path):
    store = Store()
    preference = pref(options=(("organization_id", "first-org"),))
    def transport(*args, **kwargs):
        preference.options = (("organization_id", "second-org"),)
        return batch()
    result = collect_kilo(preference, observed_at=100, credentials=store, home=tmp_path, http_json=transport)
    assert result.reason_code == "source_changed"
    assert result.lanes == ()


def test_provenance_changes_with_token_org_and_source(tmp_path):
    def collect(preference, store):
        return collect_kilo(preference, observed_at=100, credentials=store, home=tmp_path,
            http_json=lambda *a, **k: batch())
    first = collect(pref(), Store())
    org = collect(pref(options=(("organization_id", "synthetic-org"),)), Store())
    other = SimpleNamespace(enabled=True, usage_consented=True, source_instance_id="other")
    source = collect(other, Store())
    class OtherStore(Store):
        def get(self, *args):
            return SimpleNamespace(available=True, secret="other-key")
    key = collect(pref(), OtherStore())
    values = [result.account_discriminator for result in [first, org, source, key]]
    assert all(value and value.startswith("kilo-provenance:") for value in values)
    assert len(set(values)) == 4
    assert "synthetic-key" not in str(values)


@pytest.mark.parametrize("value", [True, -1, "unknown", float("inf"), float("nan"), {}])
def test_invalid_generic_alias_does_not_become_quota(value):
    payload = batch()
    payload[1]["result"]["data"]["json"] = {"pass": {"amountCents": value, "usedCents": 0}}
    with pytest.raises((ValueError, TypeError)):
        parse_kilo_usage(payload, observed_at=100)


def test_unknown_nested_numbers_do_not_create_lanes():
    payload = batch({"totalBalance_mUsd": 5000000, "unrelated": {"total": 10, "used": 4}})
    payload[1]["result"]["data"]["json"] = {"unrelated": {"total": 10, "used": 4}}
    result = parse_kilo_usage(payload, observed_at=100)
    assert result.lanes == ()


def test_inflight_key_mutation_discards_response(tmp_path):
    class MutableStore(Store):
        secret = "synthetic-first"
        def get(self, *args):
            return SimpleNamespace(available=True, secret=self.secret)
    store = MutableStore()
    def transport(*args, **kwargs):
        store.secret = "synthetic-second"
        return batch()
    result = collect_kilo(pref(), observed_at=100, credentials=store, home=tmp_path, http_json=transport)
    assert result.reason_code == "credential_changed"
    assert result.lanes == ()


def test_multiple_generic_credit_blocks_aggregate_allowances():
    result = parse_kilo_usage(batch({"blocks": [{"total": 10, "used": 5},
        {"total": 90, "used": 0}]}), observed_at=100)
    assert result.credits_remaining == 95
    assert result.lanes[0].remaining_percent == 95


@pytest.mark.parametrize("blocks", [
    [{"total": 10, "used": 5}, {"total_mUsd": 90000000, "used_mUsd": 0}],
    [{"total": 10, "used": 5}, {"unrelatedBalance": 90}],
    [{"total": 10, "used": 5}, {"total": 90}],
])
def test_incompatible_generic_credit_blocks_reject_partial_quota(blocks):
    with pytest.raises(ValueError):
        parse_kilo_usage(batch({"blocks": blocks}), observed_at=100)


@pytest.mark.parametrize("change", ["stable", "rate_limited", "malformed", "rotated", "removed", "source", "rejected"])
@pytest.mark.parametrize("auth_source", ["api", "cli"])
def test_service_retains_only_verified_credential_source_after_failure(tmp_path, monkeypatch, change, auth_source):
    from jrbar import provider_usage_runtime as runtime
    from jrbar.provider_usage_consent import consent_gated_collectors
    from jrbar.provider_usage_settings import default_provider_usage_settings

    monkeypatch.setattr(runtime, "credential_fingerprint", lambda *_: None)
    monkeypatch.setattr(runtime, "_machine_is_constrained", lambda: False)
    class Keys:
        secret = "synthetic-first"
        def get(self, *_):
            return SimpleNamespace(available=self.secret is not None, secret=self.secret)
        def get_for_instance(self, *_):
            return self.get()
    class Timer:
        def __init__(self, *args, **kwargs):
            pass
        def start(self):
            pass
        def cancel(self):
            pass
    store = Keys()
    now = [1000.0]
    settings = [default_provider_usage_settings().with_usage_consent("kilo", True, source="settings", at=1)]
    auth_path = tmp_path / ".local/share/kilo/auth.json"
    def write_cli_key(secret):
        auth_path.parent.mkdir(parents=True, exist_ok=True)
        auth_path.write_text(json.dumps({"kilo": {"access": secret}}))
    if auth_source == "cli":
        write_cli_key("synthetic-first")

    def transport(*args, **kwargs):
        if now[0] == 1000:
            return batch()
        if change in {"rotated", "removed"}:
            if auth_source == "cli":
                if change == "removed":
                    auth_path.unlink()
                else:
                    write_cli_key("synthetic-second")
            else:
                store.secret = "synthetic-second" if change == "rotated" else None
        raise ProviderHttpError(401 if change == "rejected" else 429 if change == "rate_limited" else 200 if change == "malformed" else 500,
                                "invalid_json" if change == "malformed" else "synthetic-private")
    service = runtime.ProviderUsageService(settings_loader=lambda: settings[0], credentials=store,
        home=tmp_path, collectors={"kilo": consent_gated_collectors(http_json=transport)["kilo"]},
        clock=lambda: now[0], timer_factory=Timer, incident_lookup=lambda *_: None)
    try:
        first = service.refresh_now(providers=("kilo",), force=True).by_provider("kilo")
        assert first.state is ProviderSourceState.READY
        assert first.lanes
        assert first.account_discriminator is not None
        if change == "source":
            settings[0] = settings[0].with_option("kilo", "organization_id", "synthetic-other")
        now[0] = 1100
        second = service.refresh_now(providers=("kilo",), force=True).by_provider("kilo")
        if change in {"stable", "rate_limited", "malformed"}:
            assert second.state is ProviderSourceState.STALE
            assert second.lanes == first.lanes
            assert second.account_discriminator == first.account_discriminator
            assert second.read_at == first.observed_at
        else:
            assert second.state is (ProviderSourceState.UNAVAILABLE if change == "source" else ProviderSourceState.NEEDS_SIGN_IN)
            assert second.lanes == ()
            assert second.account_discriminator != first.account_discriminator
        if change == "rejected":
            assert second.reason_code == "authentication_required"
            assert second.account_discriminator is None
        assert "synthetic-private" not in repr(second)
    finally:
        service.close()



def test_rejected_old_request_does_not_mark_rotated_key_rejected(tmp_path):
    class MutableStore(Store):
        secret = "synthetic-first"
        def get(self, *args):
            return SimpleNamespace(available=True, secret=self.secret)
    store = MutableStore()
    def transport(*args, **kwargs):
        store.secret = "synthetic-second"
        raise ProviderHttpError(401, "synthetic-private")
    result = collect_kilo(pref(), observed_at=1000, home=tmp_path,
                          credentials=store, http_json=transport)
    assert result.reason_code == "credential_changed"
    assert result.account_discriminator is None


@pytest.mark.parametrize("fails", [False, True])
def test_new_cli_session_replaces_selected_api_source(tmp_path, fails):
    preference = pref()
    preference.source_instance_id = "default"
    def transport(*args, **kwargs):
        auth = tmp_path / ".local/share/kilo/auth.json"
        auth.parent.mkdir(parents=True)
        auth.write_text(json.dumps({"kilo": {"access": "synthetic-other-account"}}))
        if fails:
            raise ProviderHttpError(500, "synthetic-private")
        return batch()
    result = collect_kilo(preference, observed_at=1000, credentials=Store(), home=tmp_path, http_json=transport)
    assert result.reason_code == "source_changed"
    assert result.account_discriminator is None
    assert result.lanes == ()


@pytest.mark.parametrize("change", ["source", "consent"])
@pytest.mark.parametrize("fails", [False, True])
def test_changed_request_context_never_binds_old_kilo_identity(tmp_path, change, fails):
    preference = pref(options=())
    def transport(*args, **kwargs):
        if change == "source":
            preference.options = (("organization_id", "synthetic-other"),)
        else:
            preference.usage_consented = False
        if fails:
            raise ProviderHttpError(500, "synthetic-private")
        return batch()
    result = collect_kilo(preference, observed_at=1000, credentials=Store(), home=tmp_path, http_json=transport)
    assert result.reason_code == ("source_changed" if change == "source" else "usage_consent_required")
    assert result.account_discriminator is None
    assert result.lanes == ()
