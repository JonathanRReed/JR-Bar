"""Grok quota continuity uses synthetic accounts and an injected transport."""

import json
from types import SimpleNamespace

import pytest

from jrbar import provider_usage_collectors as collectors
from jrbar.provider_account_identity import grok_account_metadata
from jrbar.provider_usage_platform import ProviderSourceState
from jrbar.provider_usage_runtime import ProviderUsageService
from jrbar.provider_usage_settings import default_provider_usage_settings


class Store:
    def get_for_instance(self, _key, _account):
        return SimpleNamespace(available=False, secret=None)


def write_auth(home, token, email):
    path = home / ".grok" / "auth.json"
    path.parent.mkdir(exist_ok=True)
    path.write_text(json.dumps({"https://auth.x.ai::fixture": {
        "key": token, "email": email, "expires_at": 5000,
    }}))


@pytest.mark.parametrize("failure", [401, 0, "invalid_response"])
@pytest.mark.parametrize("second_email", ["b@example.invalid", None, "not-an-email"])
def test_changed_or_unknown_account_never_borrows_old_grok_quota(tmp_path, failure, second_email):
    write_auth(tmp_path, "synthetic-a", "a@example.invalid")
    result = [{"config": {"creditUsagePercent": 40, "planName": "Synthetic A"}}]

    def http(*_args, **_kwargs):
        if isinstance(result[0], int):
            raise collectors.ProviderHttpError(result[0], "http_error")
        return result[0]

    def collector(preference, home, observed, credentials):
        return collectors.collect_grok(preference, home=home, observed_at=observed,
                                       credentials=credentials, http_json=http)

    settings = default_provider_usage_settings().with_usage_consent("grok", True, source="settings", at=1000)
    service = ProviderUsageService(settings_loader=lambda: settings, collectors={"grok": collector},
                                   credentials=Store(), home=tmp_path, clock=lambda: 1000)
    try:
        first = service.refresh_now(providers=("grok",), force=True).by_provider("grok")
        assert first.state is ProviderSourceState.READY
        assert first.account_discriminator is not None
        assert first.lanes[0].remaining_percent == 60
        write_auth(tmp_path, "synthetic-b", second_email)
        result[0] = [] if failure == "invalid_response" else failure
        failed = service.refresh_now(providers=("grok",), force=True).by_provider("grok")
        assert failed.state is not ProviderSourceState.STALE
        assert failed.account_label != first.account_label
        assert failed.account_plan is None
        assert failed.lanes == ()
        if second_email == "b@example.invalid":
            assert failed.account_discriminator != first.account_discriminator
            assert not service._last_known_good
        else:
            assert failed.account_discriminator is None
    finally:
        service.close()


@pytest.mark.parametrize("failure", [401, 0, "invalid_response"])
def test_same_account_token_rotation_retains_its_stale_quota(tmp_path, failure):
    write_auth(tmp_path, "synthetic-a", "a@example.invalid")
    result = [{"config": {"creditUsagePercent": 40, "planName": "Synthetic A"}}]

    def http(*_args, **_kwargs):
        if isinstance(result[0], int):
            raise collectors.ProviderHttpError(result[0], "http_error")
        return result[0]

    def collector(preference, home, observed, credentials):
        return collectors.collect_grok(preference, home=home, observed_at=observed,
                                       credentials=credentials, http_json=http)

    settings = default_provider_usage_settings().with_usage_consent("grok", True, source="settings", at=1000)
    service = ProviderUsageService(settings_loader=lambda: settings, collectors={"grok": collector},
                                   credentials=Store(), home=tmp_path, clock=lambda: 1000)
    try:
        first = service.refresh_now(providers=("grok",), force=True).by_provider("grok")
        write_auth(tmp_path, "synthetic-rotated", "  A@EXAMPLE.INVALID  ")
        result[0] = [] if failure == "invalid_response" else failure
        failed = service.refresh_now(providers=("grok",), force=True).by_provider("grok")
        assert failed.state is ProviderSourceState.STALE
        assert failed.account_discriminator == first.account_discriminator
        assert failed.account_label == first.account_label
        assert failed.account_plan == first.account_plan
        assert failed.lanes == first.lanes
    finally:
        service.close()


def test_successful_response_email_proves_identity_when_cli_has_none(tmp_path):
    write_auth(tmp_path, "synthetic-a", None)
    result = collectors.collect_grok(SimpleNamespace(source_instance_id="default"), home=tmp_path,
                                    observed_at=1000, credentials=Store(), http_json=lambda *_a, **_k: {
                                        "email": " A@EXAMPLE.INVALID ", "config": {"creditUsagePercent": 40},
                                    })
    assert (result.account_label, result.account_discriminator) == grok_account_metadata(tmp_path, "a@example.invalid")
    assert "a@example.invalid" not in result.account_discriminator


def test_parse_failure_keeps_selected_cli_identity(tmp_path, monkeypatch):
    write_auth(tmp_path, "synthetic-a", "a@example.invalid")

    def invalid(*_args, **_kwargs):
        raise ValueError("synthetic parse failure")

    monkeypatch.setattr(collectors, "parse_grok_usage", invalid)
    result = collectors.collect_grok(SimpleNamespace(source_instance_id="default"), home=tmp_path,
                                    observed_at=1000, credentials=Store(), http_json=lambda *_a, **_k: {})
    assert result.state is ProviderSourceState.ERROR
    assert (result.account_label, result.account_discriminator) == grok_account_metadata(tmp_path, "a@example.invalid")


@pytest.mark.parametrize("current", ["different", "unknown", "missing", "expired", "named", "same"])
def test_restored_grok_quota_is_checked_before_any_collection(tmp_path, current):
    from dataclasses import replace

    from jrbar.provider_usage_runtime import ProviderUsageState

    write_auth(tmp_path, "synthetic-a", "a@example.invalid")
    saved = collectors.collect_grok(SimpleNamespace(source_instance_id="default"), home=tmp_path,
                                   observed_at=900, credentials=Store(), http_json=lambda *_a, **_k: {
                                       "config": {"creditUsagePercent": 40, "planName": "Synthetic A"},
                                   })
    if current == "named":
        saved = replace(saved, source_instance_id="second")
    elif current == "missing":
        (tmp_path / ".grok" / "auth.json").unlink()
    elif current == "expired":
        path = tmp_path / ".grok" / "auth.json"
        payload = json.loads(path.read_text())
        payload["https://auth.x.ai::fixture"]["expires_at"] = 950
        path.write_text(json.dumps(payload))
    else:
        email = {"different": "b@example.invalid", "unknown": None, "same": " A@EXAMPLE.INVALID "}[current]
        write_auth(tmp_path, "synthetic-rotated", email)

    def forbidden(*_args):
        pytest.fail("restore ran a collector")

    service = ProviderUsageService(settings_loader=default_provider_usage_settings,
                                   collectors={"grok": forbidden}, credentials=Store(), home=tmp_path,
                                   clock=lambda: 1000,
                                   state_loader=lambda: ProviderUsageState((saved,), 900, 2000, False))
    try:
        if current == "same":
            assert service.snapshot().snapshots == (saved,)
            assert service._last_known_good
        else:
            assert service.snapshot().snapshots == ()
            assert service.snapshot().next_refresh_at is None
            assert not service._last_known_good
    finally:
        service.close()


def test_empty_and_usage_off_restore_do_not_read_grok_auth(tmp_path, monkeypatch):
    from jrbar.provider_usage_runtime import ProviderUsageState

    write_auth(tmp_path, "synthetic-a", "a@example.invalid")
    saved = collectors.collect_grok(SimpleNamespace(source_instance_id="default"), home=tmp_path,
                                   observed_at=900, credentials=Store(), http_json=lambda *_a, **_k: {
                                       "config": {"creditUsagePercent": 40},
                                   })

    def forbidden(*_args):
        pytest.fail("empty or usage-off restore inspected Grok auth")

    monkeypatch.setattr(collectors, "_read_grok_auth", forbidden)
    forbidden.requires_usage_consent = True
    settings = default_provider_usage_settings().with_usage_consent("grok", False, source="settings", at=1000)
    for snapshots in [(), (saved,)]:
        service = ProviderUsageService(settings_loader=lambda: settings, collectors={"grok": forbidden},
                                       credentials=Store(), home=tmp_path, clock=lambda: 1000,
                                       state_loader=lambda: ProviderUsageState(snapshots, 900, 2000, False))
        try:
            assert not service._last_known_good
            if snapshots:
                restored = service.snapshot().by_provider("grok")
                assert restored.reason_code == "usage_not_turned_on"
                assert not restored.lanes
        finally:
            service.close()
