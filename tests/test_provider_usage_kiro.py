"""Synthetic Kiro databases and transports never read the user's CLI state."""
import copy
import hashlib
import json
import sqlite3
from types import SimpleNamespace

import pytest

from jrbar.provider_usage_collectors import ProviderHttpError
from jrbar.provider_usage_kiro import collect_kiro, kiro_database_path, parse_kiro_usage
from jrbar.provider_usage_platform import ProviderSourceState as State
from jrbar.provider_usage_settings import default_provider_usage_settings


@pytest.fixture
def preference():
    settings = default_provider_usage_settings().with_usage_consent("kiro", True, source="settings", at=1)
    return settings.preference("kiro")


@pytest.fixture
def database(tmp_path):
    path = tmp_path / "data.sqlite3"
    with sqlite3.connect(path) as db:
        db.execute("CREATE TABLE auth_kv (key TEXT PRIMARY KEY, value TEXT)")
        db.execute("CREATE TABLE state (key TEXT PRIMARY KEY, value TEXT)")
        db.execute("INSERT INTO auth_kv VALUES (?, ?)", ("kirocli:odic:token", json.dumps({"access_token": "synthetic-token"})))
        db.execute("INSERT INTO state VALUES (?, ?)", ("api.codewhisperer.profile", json.dumps({"arn": "arn:aws:codewhisperer:us-east-1:000000000000:profile/synthetic"})))
    return path


def payload():
    return {"nextDateReset": 1_800_000_000, "overageConfiguration": {"overageStatus": "ENABLED"},
            "usageBreakdownList": [{"resourceType": "CREDIT", "usageLimitWithPrecision": 100,
                "currentUsageWithPrecision": 52.5, "currentOveragesWithPrecision": 2.5,
                "overageCapWithPrecision": 25, "overageCharges": 0.1, "overageRate": 0.04}]}


def test_plan_and_overage_use_separate_credit_denominators():
    result = parse_kiro_usage(payload(), observed_at=100)
    assert [(lane.lane_id, lane.remaining_percent, lane.reset_at) for lane in result.lanes] == [
        ("monthly", 50, 1_800_000_000), ("overage", 90, 1_800_000_000)]
    assert result.estimated_cost_usd == 0.1
    assert result.account_label is None
    assert result.account_plan is None


@pytest.mark.parametrize("field,value", [("currentUsageWithPrecision", True),
    ("currentUsageWithPrecision", -1), ("usageLimitWithPrecision", float("inf")),
    ("currentOveragesWithPrecision", 60), ("nextDateReset", 1_800_000_000_000),
    ("bonuses", {})])
def test_bad_metrics_never_invent_a_quota(field, value):
    data = payload()
    data["usageBreakdownList"][0][field] = value
    with pytest.raises((ValueError, TypeError)):
        parse_kiro_usage(data, observed_at=100)


def test_duplicate_credit_rows_are_ambiguous():
    data = payload()
    data["usageBreakdownList"].append(copy.deepcopy(data["usageBreakdownList"][0]))
    with pytest.raises(ValueError):
        parse_kiro_usage(data, observed_at=100)


def test_bonus_spend_is_not_misreported_as_plan_or_trial_usage():
    data = payload()
    data["usageBreakdownList"][0]["bonuses"] = [{"synthetic": True}]
    result = parse_kiro_usage(data, observed_at=100)
    assert [lane.lane_id for lane in result.lanes] == ["overage"]
    data["overageConfiguration"]["overageStatus"] = "DISABLED"
    assert parse_kiro_usage(data, observed_at=100).lanes == ()


def test_foreign_currency_does_not_enter_usd_cost():
    data = payload()
    data["usageBreakdownList"][0]["currency"] = "EUR"
    assert parse_kiro_usage(data, observed_at=100).estimated_cost_usd is None


@pytest.mark.parametrize("enabled,consented,instance,state", [
    (False, True, "default", State.DISABLED), (True, False, "default", State.NEEDS_CONSENT),
    (True, True, "work", State.UNSUPPORTED)])
def test_gates_before_any_auth_read_or_request(preference, monkeypatch, enabled, consented, instance, state):
    def forbidden(*args, **kw):
        pytest.fail("auth or network touched before consent")
    monkeypatch.setattr("jrbar.provider_usage_kiro._identity", forbidden)
    pref = SimpleNamespace(enabled=enabled, usage_consented=consented, source_instance_id=instance)
    assert collect_kiro(pref, observed_at=100, http_json=forbidden).state is state


@pytest.mark.parametrize("region,endpoint", [("us-east-1", "https://codewhisperer.us-east-1.amazonaws.com/"),
    ("eu-central-1", "https://q.eu-central-1.amazonaws.com/")])
def test_readonly_regional_request_and_opaque_identity(preference, database, region, endpoint):
    arn = f"arn:aws:codewhisperer:{region}:000000000000:profile/synthetic"
    with sqlite3.connect(database) as db:
        db.execute("UPDATE state SET value = ?", (json.dumps({"arn": arn}),))
    before = hashlib.sha256(database.read_bytes()).hexdigest()
    calls = []
    def transport(method, url, **kw):
        calls.append((method, url, kw))
        return payload()
    result = collect_kiro(preference, observed_at=100, database_path=database, http_json=transport)
    assert result.state is State.READY
    assert calls == [("POST", endpoint, {"headers": {
        "Content-Type": "application/x-amz-json-1.0", "X-Amz-Target": "AmazonCodeWhispererService.GetUsageLimits",
        "Authorization": "Bearer synthetic-token"}, "body": {"profileArn": arn}, "timeout": 10})]
    assert hashlib.sha256(database.read_bytes()).hexdigest() == before
    assert sorted(path.name for path in database.parent.iterdir()) == ["data.sqlite3"]
    assert result.account_discriminator.startswith("kiro-profile-credential:")
    assert "synthetic-token" not in result.account_discriminator
    assert arn not in result.account_discriminator


def test_credential_change_inflight_discards_response(preference, database):
    def transport(*args, **kw):
        with sqlite3.connect(database) as db:
            db.execute("UPDATE auth_kv SET value = ?", (json.dumps({"access_token": "synthetic-new"}),))
        return payload()
    result = collect_kiro(preference, observed_at=100, database_path=database, http_json=transport)
    assert result.state is State.NEEDS_SIGN_IN
    assert result.reason_code == "cli_session_changed"
    assert result.lanes == ()


def test_profile_change_inflight_discards_response(preference, database):
    def transport(*args, **kw):
        with sqlite3.connect(database) as db:
            db.execute("UPDATE state SET value = ?", (json.dumps({"arn": "arn:aws:codewhisperer:eu-central-1:000000000000:profile/other"}),))
        return payload()
    assert collect_kiro(preference, observed_at=100, database_path=database, http_json=transport).lanes == ()


@pytest.mark.parametrize("status,state", [(401, State.NEEDS_SIGN_IN), (403, State.NEEDS_SIGN_IN),
    (429, State.RATE_LIMITED), (500, State.UNAVAILABLE)])
def test_transport_failures_are_scoped_and_redacted(preference, database, status, state):
    def transport(*args, **kw):
        raise ProviderHttpError(status, "synthetic-private-detail")
    result = collect_kiro(preference, observed_at=100, database_path=database, http_json=transport)
    assert result.state is state
    assert result.lanes == ()
    assert "synthetic-private-detail" not in repr(result)


def test_no_separable_bonus_plan_is_explicitly_unsupported(preference, database):
    data = payload()
    data["usageBreakdownList"][0]["bonuses"] = [{}]
    data["overageConfiguration"]["overageStatus"] = "DISABLED"
    result = collect_kiro(preference, observed_at=100, database_path=database, http_json=lambda *a, **k: data)
    assert result.state is State.UNSUPPORTED
    assert result.reason_code == "no_separable_quota"


def test_bad_region_and_symlink_fail_before_request(preference, database):
    def forbidden(*args, **kw):
        pytest.fail("unsafe identity reached network")
    with sqlite3.connect(database) as db:
        db.execute("UPDATE state SET value = ?", (json.dumps({"arn": "arn:aws:codewhisperer:other:000000000000:profile/synthetic"}),))
    assert collect_kiro(preference, observed_at=100, database_path=database, http_json=forbidden).state is State.NEEDS_SIGN_IN
    link = database.parent / "linked.sqlite3"
    link.symlink_to(database)
    assert collect_kiro(preference, observed_at=100, database_path=link, http_json=forbidden).state is State.NEEDS_SIGN_IN


def test_default_paths_and_override_are_explicit(tmp_path):
    assert kiro_database_path(home=tmp_path, environment={}) == tmp_path / "Library/Application Support/kiro-cli/data.sqlite3"
    assert kiro_database_path(home=tmp_path, environment={"KIRO_DATA_DIR": str(tmp_path)}) == tmp_path / "data.sqlite3"
    with pytest.raises(ValueError):
        kiro_database_path(home=tmp_path, environment={"KIRO_DATA_DIR": "relative"})


def test_optional_nulls_use_reported_top_level_reset_and_no_invented_overage():
    data = payload()
    data["usageBreakdownList"][0].update(nextDateReset=None, bonuses=None,
        currentOveragesWithPrecision=None, currency=None)
    data["overageConfiguration"] = None
    result = parse_kiro_usage(data, observed_at=100)
    assert len(result.lanes) == 1
    assert result.lanes[0].reset_at == 1_800_000_000
    assert result.lanes[0].remaining_percent == 47.5


def test_tests_cannot_default_to_real_cli_auth(preference):
    def forbidden(*args, **kw):
        pytest.fail("real CLI identity was requested")
    assert collect_kiro(preference, observed_at=100, http_json=forbidden).state is State.NEEDS_SIGN_IN


def test_missing_database_is_not_created(preference, tmp_path):
    missing = tmp_path / "missing.sqlite3"
    result = collect_kiro(preference, observed_at=100, database_path=missing,
                          http_json=lambda *a, **k: pytest.fail("missing auth reached network"))
    assert result.state is State.NEEDS_SIGN_IN
    assert not missing.exists()


def test_identical_credentials_in_separate_source_paths_do_not_merge(preference, database):
    other = database.parent / "other.sqlite3"
    other.write_bytes(database.read_bytes())
    def transport(*args, **kwargs):
        return payload()
    first = collect_kiro(preference, observed_at=100, database_path=database, http_json=transport)
    second = collect_kiro(preference, observed_at=100, database_path=other, http_json=transport)
    assert first.account_discriminator != second.account_discriminator


def test_header_injection_in_cli_token_is_refused_before_request(preference, database):
    with sqlite3.connect(database) as db:
        db.execute("UPDATE auth_kv SET value = ?", (json.dumps({"access_token": "synthetic\nheader"}),))
    result = collect_kiro(preference, observed_at=100, database_path=database,
                          http_json=lambda *a, **k: pytest.fail("invalid token reached network"))
    assert result.state is State.NEEDS_SIGN_IN


def test_data_directory_change_inflight_discards_response(preference, database):
    environment = {"KIRO_DATA_DIR": str(database.parent)}
    def transport(*args, **kw):
        environment["KIRO_DATA_DIR"] = str(database.parent / "other")
        return payload()
    result = collect_kiro(preference, observed_at=100, home=database.parent,
                          environment=environment, http_json=transport)
    assert result.state is State.ERROR
    assert result.reason_code == "source_changed"


def test_registry_defaults_and_disclosure_keep_cli_auth_distinct_from_local_history():
    from jrbar.provider_management import CREDENTIAL_ACCOUNTS, supports_provider_instances
    from jrbar.provider_usage_consent import usage_disclosure
    from jrbar.provider_usage_platform import provider_descriptor

    descriptor = provider_descriptor("kiro")
    pref = default_provider_usage_settings().preference("kiro")
    assert not pref.enabled
    assert not pref.usage_consented
    assert not descriptor.supports_local_tokens
    assert not supports_provider_instances("kiro")
    assert "kiro" not in CREDENTIAL_ACCOUNTS
    disclosure = usage_disclosure("kiro")
    assert disclosure.hosts == ("codewhisperer.us-east-1.amazonaws.com", "q.eu-central-1.amazonaws.com")
    assert "profile ARN" in disclosure.detail
    assert "never refreshes" in disclosure.detail


def test_registered_collector_keeps_off_provider_inert(tmp_path, monkeypatch):
    from jrbar.provider_usage_consent import consent_gated_collectors

    def forbidden(*args, **kw):
        pytest.fail("off provider read CLI credentials or reached the network")
    monkeypatch.setattr("jrbar.provider_usage_kiro._identity", forbidden)
    collector = consent_gated_collectors(http_json=forbidden)["kiro"]
    pref = default_provider_usage_settings().preference("kiro")
    result = collector(pref, tmp_path, 100, object())
    assert result.state is State.NEEDS_CONSENT
    assert result.lanes == ()
    assert result.reason_code == "usage_not_turned_on"


def test_registered_collector_reads_only_injected_home_database(preference, database, tmp_path, monkeypatch):
    from jrbar.provider_usage_consent import consent_gated_collectors

    monkeypatch.delenv("KIRO_DATA_DIR", raising=False)
    home = tmp_path / "synthetic-home"
    target = home / "Library/Application Support/kiro-cli/data.sqlite3"
    target.parent.mkdir(parents=True)
    target.write_bytes(database.read_bytes())
    collector = consent_gated_collectors(http_json=lambda *a, **k: payload())["kiro"]
    result = collector(preference, home, 100, object())
    assert result.state is State.READY
    assert [lane.lane_id for lane in result.lanes] == ["monthly", "overage"]


def test_stable_cli_identity_survives_transient_failure_for_stale_retention(preference, database):
    ready = collect_kiro(preference, observed_at=100, database_path=database,
                         http_json=lambda *a, **k: payload())
    def unavailable(*args, **kwargs):
        raise ProviderHttpError(500, "synthetic-private")
    failed = collect_kiro(preference, observed_at=200, database_path=database, http_json=unavailable)
    assert failed.state is State.UNAVAILABLE
    assert failed.account_discriminator == ready.account_discriminator


def test_failed_request_after_cli_rotation_does_not_retain_old_identity(preference, database):
    def unavailable(*args, **kwargs):
        with sqlite3.connect(database) as db:
            db.execute("UPDATE auth_kv SET value = ?", (json.dumps({"access_token": "synthetic-new"}),))
        raise ProviderHttpError(500, "synthetic-private")
    failed = collect_kiro(preference, observed_at=200, database_path=database, http_json=unavailable)
    assert failed.state is State.NEEDS_SIGN_IN
    assert failed.account_discriminator is None
