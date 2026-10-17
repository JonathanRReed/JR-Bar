"""Factory integration checks use synthetic responses and temporary settings."""

from copy import deepcopy
from types import SimpleNamespace

import pytest

from jrbar.core_projection import usage_document
from jrbar.provider_usage_consent import consent_gated_collectors, usage_disclosure
from jrbar.provider_usage_factory import collect_factory, parse_factory_usage
from jrbar.provider_usage_platform import ProviderSourceState, most_constrained_lane
from jrbar.provider_usage_runtime import ProviderUsageService, ProviderUsageState
from jrbar.provider_usage_settings import default_provider_usage_settings, load_provider_usage_settings


def payload(core=False):
    standard = {name: {"usedPercent": value, "windowEnd": 3000} for name, value in
                [("fiveHour", 12), ("weekly", 34), ("monthly", 56)]}
    pools = {"standard": standard}
    if core:
        pools["core"] = {name: {"usedPercent": 99, "windowEnd": 3000} for name in standard}
    return {"usesTokenRateLimitsBilling": True, "limits": pools}


def test_core_pool_cannot_exhaust_the_standard_subscription_meter():
    reading = parse_factory_usage(payload(core=True), observed_at=1000)
    assert len(reading.lanes) == 6
    selected = most_constrained_lane(reading, now=1000)
    assert selected.lane_id == "standard-30d"
    projected = usage_document(ProviderUsageState((reading,), None, None, False), now=1000)
    row = projected["providers"][0]
    assert len(row["windows"]) == 6
    assert sum(window["detail"] for window in row["windows"]) == 3
    assert row["constrained"]["id"] == "standard-30d"


def test_factory_defaults_and_old_documents_keep_usage_off(tmp_path):
    settings = default_provider_usage_settings()
    assert not settings.preference("factory").enabled
    assert not settings.preference("factory").usage_consented
    loaded = load_provider_usage_settings(tmp_path / "missing.json").settings.preference("factory")
    assert not loaded.enabled and not loaded.usage_consented
    assert usage_disclosure("factory").hosts == ("api.factory.ai", "api.workos.com")


def test_registered_collector_does_not_touch_keychain_or_http_without_consent(tmp_path):
    class NoAccess:
        def get(self, *_args):
            pytest.fail("unconsented credentials read")
    def forbidden(*_args, **_kwargs):
        pytest.fail("unconsented HTTP")
    collector = consent_gated_collectors(http_json=forbidden)["factory"]
    reading = collector(default_provider_usage_settings().preference("factory"), tmp_path, 1000, NoAccess())
    assert reading.lanes == ()
    assert reading.state in {ProviderSourceState.DISABLED, ProviderSourceState.NEEDS_CONSENT}


@pytest.mark.parametrize("proved", [False, True])
def test_factory_retains_only_proved_same_account_history(tmp_path, proved):
    class Store:
        def get(self, provider, account):
            return SimpleNamespace(available=account == "api-key", secret="synthetic-key" if account == "api-key" else None)
    response = {"payload": payload(), "auth": {"userProfile": {"id": "synthetic-user"},
                                                "organization": {"id": "synthetic-org"}} if proved else {}}
    def http(_method, url, **_kwargs):
        if url.endswith("/auth/me"):
            return response["auth"]
        if response["payload"] is None:
            raise ValueError("synthetic failed read")
        return deepcopy(response["payload"])
    def collector(preference, _home, observed, credentials):
        return collect_factory(preference, observed_at=observed, credentials=credentials, http_json=http)
    settings = default_provider_usage_settings().with_usage_consent("factory", True, source="settings", at=1000)
    service = ProviderUsageService(settings_loader=lambda: settings, collectors={"factory": collector},
                                   credentials=Store(), home=tmp_path, clock=lambda: 1000)
    try:
        assert service.refresh_now(providers=("factory",), force=True).by_provider("factory").lanes
        response["payload"] = None
        failed = service.refresh_now(providers=("factory",), force=True).by_provider("factory")
        assert bool(failed.lanes) is proved
        assert (failed.state is ProviderSourceState.STALE) is proved
    finally:
        service.close()


def test_factory_refresh_action_is_explicit_and_account_scoped(monkeypatch):
    from jrbar import core_runtime
    calls = []
    monkeypatch.setattr(core_runtime, "_require_usage_on", lambda *_args: None)
    controller = SimpleNamespace(_request_provider_usage=lambda **kwargs: calls.append(kwargs))
    handler = core_runtime._MAIN_THREAD_COMMANDS["provider_action"].handler
    result = handler(controller, {"provider": "factory", "instance": "work"})
    assert calls == [{"force": True, "providers": (("factory", "work"),)}]
    assert result["message"] == "Factory usage refresh requested."
    calls.clear()
    def denied(*_args):
        from jrbar.core_server import CommandError
        raise CommandError("usage_off", "Factory usage is off")
    monkeypatch.setattr(core_runtime, "_require_usage_on", denied)
    from jrbar.core_server import CommandError
    with pytest.raises(CommandError):
        handler(controller, {"provider": "factory"})
    assert calls == []


@pytest.mark.parametrize("new_user", [None, "synthetic-other-user"])
def test_changed_or_unknown_account_does_not_borrow_factory_quota(tmp_path, new_user):
    class Store:
        def get(self, provider, account):
            return SimpleNamespace(available=account == "api-key", secret="synthetic-key" if account == "api-key" else None)
    state = {"user": "synthetic-first-user", "fail": False}
    def http(_method, url, **_kwargs):
        if url.endswith("/auth/me"):
            return {"userProfile": {"id": state["user"]}, "organization": {"id": "synthetic-org"}}
        if state["fail"]:
            raise ValueError("synthetic failure")
        return payload()
    def collector(preference, _home, observed, credentials):
        return collect_factory(preference, observed_at=observed, credentials=credentials, http_json=http)
    settings = default_provider_usage_settings().with_usage_consent("factory", True, source="settings", at=1000)
    service = ProviderUsageService(settings_loader=lambda: settings, collectors={"factory": collector},
                                   credentials=Store(), home=tmp_path, clock=lambda: 1000)
    try:
        first = service.refresh_now(providers=("factory",), force=True).by_provider("factory")
        assert first.lanes and first.account_discriminator
        state.update(user=new_user, fail=True)
        failed = service.refresh_now(providers=("factory",), force=True).by_provider("factory")
        assert failed.lanes == ()
        assert failed.state is not ProviderSourceState.STALE
        if new_user:
            assert failed.account_discriminator != first.account_discriminator
            assert not service._last_known_good
        else:
            assert failed.account_discriminator is None
    finally:
        service.close()


def test_disabled_factory_action_does_not_schedule_a_request(monkeypatch):
    from jrbar import core_runtime
    from jrbar.core_server import CommandError
    from jrbar.provider_usage_platform import failure_snapshot
    calls = []
    disabled = failure_snapshot("factory", observed_at=1000, state=ProviderSourceState.DISABLED,
                                reason="disabled", action="Enable Factory usage")
    controller = SimpleNamespace(provider_usage_state=ProviderUsageState((disabled,), None, None, False),
                                 _request_provider_usage=lambda **kwargs: calls.append(kwargs))
    monkeypatch.setattr(core_runtime, "_require_usage_on", lambda *_args: None)
    with pytest.raises(CommandError) as error:
        core_runtime._MAIN_THREAD_COMMANDS["provider_action"].handler(controller, {"provider": "factory"})
    assert error.value.code == "usage_off"
    assert calls == []


@pytest.mark.parametrize("provider,label", [("factory", "Factory"), ("kimi", "Kimi Code"),
                                          ("kilo", "Kilo"), ("kiro", "Kiro")])
@pytest.mark.parametrize("instance", ["default", "work"])
def test_key_managed_refresh_targets_one_instance(monkeypatch, provider, label, instance):
    from jrbar import core_runtime

    calls = []
    controller = SimpleNamespace(_request_provider_usage=lambda **kwargs: calls.append(kwargs))
    monkeypatch.setattr(core_runtime, "_require_usage_on", lambda *_args: None)
    reply = core_runtime._MAIN_THREAD_COMMANDS["provider_action"].handler(
        controller, {"provider": provider, "instance": instance})
    assert calls == [{"force": True, "providers": ((provider, instance),)}]
    assert reply == {"provider": provider, "instance": instance, "message": f"{label} usage refresh requested."}


@pytest.mark.parametrize("provider", ["kimi", "kilo", "kiro"])
def test_disabled_key_managed_refresh_never_schedules(monkeypatch, provider):
    from jrbar import core_runtime
    from jrbar.core_server import CommandError
    from jrbar.provider_usage_platform import failure_snapshot

    disabled = failure_snapshot(provider, observed_at=1000, state=ProviderSourceState.DISABLED,
                                reason="disabled", action="Enable usage")
    calls = []
    controller = SimpleNamespace(provider_usage_state=ProviderUsageState((disabled,), None, None, False),
                                 _request_provider_usage=lambda **kwargs: calls.append(kwargs))
    monkeypatch.setattr(core_runtime, "_require_usage_on", lambda *_args: None)
    with pytest.raises(CommandError) as error:
        core_runtime._MAIN_THREAD_COMMANDS["provider_action"].handler(controller, {"provider": provider})
    assert error.value.code == "usage_off"
    assert calls == []
