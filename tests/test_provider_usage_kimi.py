"""Synthetic Kimi Code responses and temporary CLI credentials only."""
import json
from types import SimpleNamespace

import pytest

from jrbar.provider_usage_collectors import ProviderHttpError
from jrbar.provider_usage_kimi import collect_kimi, parse_kimi_usage
from jrbar.provider_usage_platform import ProviderSourceState

RESET = "2030-01-02T03:04:05Z"


def counts():
    return {"usage": {"limit": "1000", "used": "250", "resetTime": RESET},
            "limits": [{"window": {"duration": 300, "timeUnit": "TIME_UNIT_MINUTE"},
                        "detail": {"limit": "200", "remaining": "40", "resetTime": RESET}}]}


def preference(**options):
    return SimpleNamespace(enabled=True, usage_consented=True, source_instance_id="default",
                           option=lambda name: options.get(name))


class Store:
    def __init__(self, **secrets):
        self.secrets, self.calls = secrets, []

    def get(self, provider, account):
        self.calls.append((provider, account))
        return SimpleNamespace(available=account in self.secrets, secret=self.secrets.get(account))


def test_legacy_code_windows_use_observed_reset_and_no_money():
    result = parse_kimi_usage(counts(), observed_at=1000)
    assert [(x.lane_id, x.remaining_percent) for x in result.lanes] == [("five-hour", 20), ("weekly", 75)]
    assert {x.reset_at for x in result.lanes} == {1893553445}
    assert result.credits_remaining is None
    assert all(x.source_id == "kimi-code-api" for x in result.lanes)
    assert result.account_discriminator is None


def test_ratios_partial_windows_and_matching_exhausted_counts():
    payload = counts()
    payload["usages"] = {"limit_5h": {"used_ratio": .2, "reset_time": RESET},
                         "limit_7d": {"used_ratio": .5, "reset_time": RESET},
                         "limit_month_total": {"used_ratio": 1.1}}
    result = parse_kimi_usage(payload, observed_at=1000)
    assert [(x.lane_id, x.remaining_percent) for x in result.lanes] == [("five-hour", 20), ("weekly", 50), ("monthly", 0)]
    assert result.lanes[-1].reset_at is None
    partial = parse_kimi_usage({"usages": {"limit_7d": {"used_ratio": 0}}}, observed_at=1000)
    assert len(partial.lanes) == 1 and partial.lanes[0].lane_id == "weekly"
    assert partial.lanes[0].reset_at is None


@pytest.mark.parametrize("value", [None, True, -1, "0.5", float("nan"), float("inf")])
def test_bad_ratios_do_not_invent_lanes(value):
    with pytest.raises(ValueError):
        parse_kimi_usage({"usages": {"limit_5h": {"used_ratio": value}}}, observed_at=1000)


@pytest.mark.parametrize("payload", [{}, {"balance": 100}, {"usage": {"limit": 10}},
    {"usage": {"limit": "0", "used": "0"}}, {"usage": {"limit": 100, "used": -1}},
    {"usage": {"limit": 100, "remaining": 101}}])
def test_no_counts_or_balance_cannot_fabricate_quota(payload):
    with pytest.raises(ValueError):
        parse_kimi_usage(payload, observed_at=1000)


def test_malformed_reset_stays_unknown_and_counts_require_integer_values():
    result = parse_kimi_usage({"usage": {"limit": 10, "used": 3, "reset_at": "bad"}}, observed_at=1000)
    assert result.lanes[0].remaining_percent == 70 and result.lanes[0].reset_at is None
    with pytest.raises(ValueError):
        parse_kimi_usage({"usage": {"limit": 10, "used": 1.5}}, observed_at=1000)


@pytest.mark.parametrize("enabled,consent,state", [(False, True, ProviderSourceState.DISABLED),
    (True, False, ProviderSourceState.NEEDS_CONSENT)])
def test_off_reads_neither_credentials_nor_network(enabled, consent, state):
    pref = preference()
    pref.enabled, pref.usage_consented = enabled, consent
    store = Store(**{"api-key": "synthetic-key"})
    result = collect_kimi(pref, observed_at=1000, credentials=store,
                          http_json=lambda *a, **k: pytest.fail("network forbidden"))
    assert result.state is state and store.calls == []


def test_missing_secret_never_requests(tmp_path):
    result = collect_kimi(preference(), observed_at=1000, credentials=Store(), home=tmp_path,
                         http_json=lambda *a, **k: pytest.fail("network forbidden"))
    assert result.state is ProviderSourceState.NEEDS_SIGN_IN


def test_explicit_api_key_region_instance_and_opaque_identity(tmp_path):
    calls = []
    pref = preference(region="international")
    pref.source_instance_id = "second"
    result = collect_kimi(pref, observed_at=1000, credentials=Store(**{"api-key": "synthetic-key"}),
                         home=tmp_path, http_json=lambda *a, **k: calls.append((a, k)) or counts())
    assert calls[0][0] == ("GET", "https://api.kimi.ai/coding/v1/usages")
    assert calls[0][1]["headers"]["Authorization"] == "Bearer synthetic-key"
    assert result.source_instance_id == "second"
    assert result.account_discriminator.startswith("kimi:credential:")
    assert "synthetic" not in result.account_discriminator


@pytest.mark.parametrize("status,state", [(401, ProviderSourceState.NEEDS_SIGN_IN),
    (403, ProviderSourceState.NEEDS_SIGN_IN), (429, ProviderSourceState.RATE_LIMITED),
    (500, ProviderSourceState.UNAVAILABLE)])
def test_http_failures_are_credential_safe(status, state):
    def request(*args, **kwargs):
        raise ProviderHttpError(status, "synthetic-secret")
    result = collect_kimi(preference(), observed_at=1000, credentials=Store(**{"api-key": "synthetic-key"}), http_json=request)
    assert result.state is state
    assert "synthetic" not in (result.reason_code or "")


def test_web_session_uses_only_coding_scope():
    calls = []
    def request(*args, **kwargs):
        calls.append((args, kwargs))
        return {"usages": [{"scope": "OTHER", "detail": {"limit": 1, "used": 1}},
                            {"scope": "FEATURE_CODING", "detail": counts()["usage"], "limits": counts()["limits"]}]}
    result = collect_kimi(preference(source="web"), observed_at=1000,
        credentials=Store(**{"web-session": "synthetic-web-token"}), http_json=request)
    assert result.state is ProviderSourceState.READY
    assert calls[0][0] == ("POST", "https://www.kimi.com/apiv2/kimi.gateway.billing.v1.BillingService/GetUsages")
    assert calls[0][1]["body"] == {"scope": ["FEATURE_CODING"]}
    assert {x.source_id for x in result.lanes} == {"kimi-code-web"}


def test_cli_reuses_only_fresh_china_default_source_and_existing_device(tmp_path):
    root = tmp_path / ".kimi-code"
    (root / "credentials").mkdir(parents=True)
    file = root / "credentials" / "kimi-code.json"
    file.write_text(json.dumps({"access_token": "synthetic-cli", "refresh_token": "never-use", "expires_at": 3000}))
    (root / "device_id").write_text("synthetic-device")
    original = file.read_bytes()
    calls = []
    def request(*a, **k):
        calls.append((a, k))
        return counts()
    result = collect_kimi(preference(source="cli"), observed_at=1000, credentials=Store(), home=tmp_path, http_json=request)
    assert result.state is ProviderSourceState.READY
    assert calls[0][1]["headers"]["X-Msh-Device-Id"] == "synthetic-device"
    assert file.read_bytes() == original
    for pref in (preference(source="cli", region="international"), preference(source="cli")):
        if pref.option("region") is None:
            pref.source_instance_id = "second"
        blocked = collect_kimi(pref, observed_at=1000, credentials=Store(), home=tmp_path,
                              http_json=lambda *a, **k: pytest.fail("forbidden credential reuse"))
        assert blocked.state is ProviderSourceState.NEEDS_SIGN_IN
    stale = collect_kimi(preference(source="cli"), observed_at=2940, credentials=Store(), home=tmp_path,
                         http_json=lambda *a, **k: pytest.fail("stale token"))
    assert stale.state is ProviderSourceState.NEEDS_SIGN_IN


def test_auto_can_reuse_default_cli_but_api_key_remains_authoritative(tmp_path):
    root = tmp_path / ".kimi-code"
    (root / "credentials").mkdir(parents=True)
    (root / "credentials" / "kimi-code.json").write_text(json.dumps(
        {"access_token": "synthetic-cli", "expires_at": 5000}))
    (root / "device_id").write_text("synthetic-device")
    calls = []
    def request(*a, **k):
        calls.append(k["headers"]["Authorization"])
        return counts()
    collect_kimi(preference(), observed_at=1000, credentials=Store(), home=tmp_path, http_json=request)
    collect_kimi(preference(), observed_at=1000, credentials=Store(**{"api-key": "explicit-key"}),
                 home=tmp_path, http_json=request)
    assert calls == ["Bearer synthetic-cli", "Bearer explicit-key"]


def test_cli_does_not_create_device_identity_or_follow_credentials_symlink(tmp_path):
    root = tmp_path / ".kimi-code"
    (root / "credentials").mkdir(parents=True)
    path = root / "credentials" / "kimi-code.json"
    path.write_text(json.dumps({"access_token": "synthetic-cli", "expires_at": 5000}))
    def no_request(*a, **k):
        pytest.fail("no existing device identity")
    result = collect_kimi(preference(source="cli"), observed_at=1000, credentials=Store(), home=tmp_path, http_json=no_request)
    assert result.state is ProviderSourceState.NEEDS_SIGN_IN
    assert not (root / "device_id").exists()
    (root / "device_id").write_text("synthetic-device")
    path.rename(root / "elsewhere.json")
    path.symlink_to(root / "elsewhere.json")
    result = collect_kimi(preference(source="cli"), observed_at=1000, credentials=Store(), home=tmp_path, http_json=no_request)
    assert result.state is ProviderSourceState.NEEDS_SIGN_IN


def test_reset_period_mismatch_does_not_borrow_legacy_usage():
    payload = counts()
    payload["usages"] = {"limit_5h": {"used_ratio": .2, "reset_time": "2030-02-01T00:00:00Z"}}
    result = parse_kimi_usage(payload, observed_at=1000)
    assert result.lanes[0].remaining_percent == 80


def test_transport_malformed_json_and_header_injection_fail_safely():
    def broken(*args, **kwargs):
        raise ProviderHttpError(200, "invalid_json")
    result = collect_kimi(preference(source="api"), observed_at=1000,
                         credentials=Store(**{"api-key": "synthetic-key"}), http_json=broken)
    assert result.state is ProviderSourceState.ERROR
    result = collect_kimi(preference(source="api"), observed_at=1000,
        credentials=Store(**{"api-key": "key\r\nInjected: yes"}),
        http_json=lambda *a, **k: pytest.fail("unsafe header"))
    assert result.state is ProviderSourceState.NEEDS_SIGN_IN


@pytest.mark.parametrize("change", ["credential", "source", "consent"])
@pytest.mark.parametrize("fails", [False, True])
def test_inflight_source_change_discards_the_old_reading(tmp_path, change, fails):
    pref = preference()
    store = Store(**{"api-key": "synthetic-first"})
    def response(*args, **kwargs):
        if change == "credential":
            store.secrets["api-key"] = "synthetic-second"
        elif change == "source":
            pref.option = lambda key: "international" if key == "region" else None
        else:
            pref.usage_consented = False
        if fails:
            raise ProviderHttpError(500, "synthetic-private")
        return counts()
    result = collect_kimi(pref, observed_at=1000, credentials=store, home=tmp_path, http_json=response)
    assert result.state is not ProviderSourceState.READY
    assert result.lanes == ()


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
    settings = [default_provider_usage_settings().with_usage_consent("kimi", True, source="settings", at=1)]
    settings[0] = settings[0].with_option("kimi", "source", auth_source)
    auth_path = tmp_path / ".kimi-code/credentials/kimi-code.json"
    def write_cli_key(secret):
        auth_path.parent.mkdir(parents=True, exist_ok=True)
        auth_path.write_text(json.dumps({"access_token": secret, "expires_at": 2000}))
        (auth_path.parent.parent / "device_id").write_text("synthetic-device")
    if auth_source == "cli":
        write_cli_key("synthetic-first")
    def transport(*args, **kwargs):
        if now[0] == 1000:
            return counts()
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
        home=tmp_path, collectors={"kimi": consent_gated_collectors(http_json=transport)["kimi"]},
        clock=lambda: now[0], timer_factory=Timer, incident_lookup=lambda *_: None)
    try:
        first = service.refresh_now(providers=("kimi",), force=True).by_provider("kimi")
        assert first.state is ProviderSourceState.READY
        assert first.lanes
        assert first.account_discriminator is not None
        if change == "source":
            settings[0] = settings[0].with_option("kimi", "region", "international")
        now[0] = 1100
        second = service.refresh_now(providers=("kimi",), force=True).by_provider("kimi")
        if change in {"stable", "rate_limited", "malformed"}:
            assert second.state is ProviderSourceState.STALE
            assert second.lanes == first.lanes
            assert second.account_discriminator == first.account_discriminator
            assert second.read_at == first.observed_at
        else:
            assert second.state is (ProviderSourceState.UNAVAILABLE if change == "source" and auth_source == "api"
                                    else ProviderSourceState.NEEDS_SIGN_IN)
            assert second.lanes == ()
            assert second.account_discriminator != first.account_discriminator
        if change == "rejected":
            assert second.reason_code == "authentication_required"
            assert second.account_discriminator is None
        assert "synthetic-private" not in repr(second)
    finally:
        service.close()



def test_rejected_old_request_does_not_mark_rotated_key_rejected(tmp_path):
    store = Store(**{"api-key": "synthetic-first"})
    def transport(*args, **kwargs):
        store.secrets["api-key"] = "synthetic-second"
        raise ProviderHttpError(401, "synthetic-private")
    result = collect_kimi(preference(source="api"), observed_at=1000, home=tmp_path,
                          credentials=store, http_json=transport)
    assert result.reason_code == "credential_changed"
    assert result.account_discriminator is None


@pytest.mark.parametrize("fails", [False, True])
def test_new_auto_priority_key_changes_the_selected_source(tmp_path, fails):
    store = Store(**{"web-session": "synthetic-web"})
    def transport(*args, **kwargs):
        store.secrets["api-key"] = "synthetic-new-account"
        if fails:
            raise ProviderHttpError(500, "synthetic-private")
        return {"usages": [{"scope": "FEATURE_CODING", "detail": counts()["usage"], "limits": []}]}
    result = collect_kimi(preference(), observed_at=1000, credentials=store, home=tmp_path, http_json=transport)
    assert result.reason_code == "source_changed"
    assert result.account_discriminator is None
    assert result.lanes == ()
