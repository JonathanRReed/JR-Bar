"""Synthetic credential writes through the registered local commands."""

import json
from pathlib import Path
from types import SimpleNamespace
from unittest.mock import Mock

import pytest

from jrbar import core_runtime
from jrbar.core_auth import CoreAuthority, privilege_of
from jrbar.core_server import CommandError, CoreServer
from jrbar.provider_credential_store import ProviderCredentialStore
from jrbar.provider_usage_settings import (
    ProviderPreference,
    default_provider_usage_settings_path,
    load_provider_usage_settings,
    save_provider_usage_settings,
)


class Backend:
    def __init__(self):
        self.values = {}
        self.failure = False

    def set_password(self, service, account, secret):
        if self.failure:
            raise RuntimeError(secret)
        self.values[service, account] = secret

    def get_password(self, service, account):
        if self.failure:
            raise RuntimeError("synthetic-secret")
        return self.values.get((service, account))

    def delete_password(self, service, account):
        if self.failure:
            raise RuntimeError("synthetic-secret")
        self.values.pop((service, account), None)


@pytest.fixture
def context(tmp_path, monkeypatch):
    monkeypatch.setattr(Path, "home", lambda: tmp_path)
    backend = Backend()
    controller = SimpleNamespace(
        _jrbar_provider_credential_store=ProviderCredentialStore(backend=backend),
        _request_provider_usage=Mock(side_effect=AssertionError("unexpected refresh")),
    )
    return tmp_path, backend, controller


def call(controller, name="set_provider_credential", **args):
    return core_runtime._MAIN_THREAD_COMMANDS[name].handler(controller, args)


def test_default_named_isolation_and_idempotent_delete(context):
    home, backend, controller = context
    loaded = load_provider_usage_settings()
    save_provider_usage_settings(
        loaded.settings.with_instance(ProviderPreference("factory", enabled=False, browser_sources=False, source_instance_id="work")),
        default_provider_usage_settings_path(),
        loaded=loaded,
    )
    before = {p: p.read_bytes() for p in home.rglob("*") if p.is_file()}
    for instance, secret in (("default", "synthetic-default"), ("work", "synthetic-work")):
        result = call(controller, provider="factory", account="api-key", instance=instance, secret=secret)
        assert result == dict(provider="factory", account="api-key", instance=instance, available=True)
    assert len(backend.values) == 2
    result = call(controller, "delete_provider_credential", provider="factory", account="api-key", instance="work")
    assert result["removed"] and result["available"] is False
    assert len(backend.values) == 1
    assert not call(controller, "delete_provider_credential", provider="factory", account="api-key", instance="work")[
        "removed"
    ]
    assert before == {p: p.read_bytes() for p in home.rglob("*") if p.is_file()}
    assert not hasattr(controller, "_jrbar_command_journal")
    controller._request_provider_usage.assert_not_called()


@pytest.mark.parametrize(
    "secret",
    [
        None,
        "",
        " ",
        " key",
        "key ",
        "a\nb",
        "a\rb",
        "a\tb",
        "a\x00b",
        "a\x7fb",
        "a\u0085b",
        "a\u2028b",
        "a\u200bb",
        "x" * 65537,
        "é" * 32769,
        "\ud800",
    ],
)
def test_invalid_secrets_do_not_write(context, secret):
    _, backend, controller = context
    with pytest.raises(CommandError) as error:
        call(controller, provider="factory", account="api-key", secret=secret)
    assert error.value.code == "invalid_args"
    assert backend.values == {}


@pytest.mark.parametrize(
    "changes,code",
    [
        ({"provider": "unknown"}, "unknown_provider"),
        ({"account": "token"}, "invalid_args"),
        ({"instance": "missing"}, "unknown_instance"),
        ({"instance": ""}, "invalid_args"),
    ],
)
def test_unknown_identity(context, changes, code):
    _, backend, controller = context
    args = dict(provider="factory", account="api-key", secret="synthetic-secret")
    args.update(changes)
    with pytest.raises(CommandError) as error:
        call(controller, **args)
    assert error.value.code == code
    assert not backend.values


@pytest.mark.parametrize("name", ["set_provider_credential", "delete_provider_credential"])
def test_backend_exception_stays_out_of_replies_logs_and_journals(context, name):
    home, backend, controller = context
    backend.failure = True
    logs = []
    server = CoreServer(
        dispatch=lambda name, args: call(controller, name, **args),
        initial_documents=lambda: [],
        socket_path=home / "unused.sock",
        log=logs.append,
    )
    reply = server.run_command("test", name, dict(provider="factory", account="api-key", secret="synthetic-secret"))
    assert reply["ok"] is False
    assert "synthetic-secret" not in json.dumps([reply, logs, list(server._journal)])
    assert not hasattr(controller, "_jrbar_command_journal")
    assert not [p for p in home.rglob("*") if p.is_file()]


@pytest.mark.parametrize("name", ["set_provider_credential", "delete_provider_credential", "connect_factory_api_key"])
def test_unauthenticated_connection_cannot_write(context, name, monkeypatch):
    home, backend, controller = context
    assert privilege_of(name) == "privileged"
    replies = []
    server = CoreServer(
        dispatch=lambda name, args: call(controller, name, **args),
        initial_documents=lambda: [],
        socket_path=home / "unused.sock",
        authority=CoreAuthority(bytes(range(32))),
    )
    monkeypatch.setattr(server, "_send_reply", lambda client, reply, *args: replies.append(reply))
    server._handle_line(
        SimpleNamespace(authenticated=False, who="synthetic"),
        json.dumps(
            dict(
                t="command",
                id="test",
                name=name,
                args=dict(provider="factory", account="api-key", secret="synthetic-secret"),
            )
        ).encode(),
    )
    assert replies[0]["error"]["code"] == "unauthenticated"
    assert backend.values == {}


def test_settings_exception_is_safe(context, monkeypatch):
    from jrbar import provider_credential_commands

    _, _, controller = context

    def fail():
        raise RuntimeError("synthetic-secret")

    monkeypatch.setattr(provider_credential_commands, "load_provider_usage_settings", fail)
    with pytest.raises(CommandError) as error:
        call(controller, provider="factory", account="api-key", secret="synthetic-secret")
    assert error.value.code == "unavailable"
    assert "synthetic-secret" not in str(error.value)


def test_delete_failure_keeps_key_and_returns_safe_error(context, monkeypatch):
    _, backend, controller = context
    call(controller, provider="factory", account="api-key", secret="synthetic-secret")

    def fail(*args):
        raise RuntimeError("synthetic-secret")

    monkeypatch.setattr(backend, "delete_password", fail)
    with pytest.raises(CommandError) as error:
        call(controller, "delete_provider_credential", provider="factory", account="api-key")
    assert error.value.code == "credential_unavailable"
    assert "synthetic-secret" not in str(error.value)
    assert list(backend.values.values()) == ["synthetic-secret"]


def test_largest_allowed_secret(context):
    _, backend, controller = context
    result = call(controller, provider="factory", account="api-key", secret="x" * 65536)
    assert result["available"] is True
    assert list(backend.values.values()) == ["x" * 65536]


@pytest.fixture
def factory_transport(context, monkeypatch):
    from jrbar import provider_usage_factory

    calls = []
    account = {"userProfile": {"id": "synthetic-user"}, "organization": {"id": "synthetic-org"}}
    window = {"usedPercent": 20}
    billing = {"usesTokenRateLimitsBilling": True, "limits": {"standard": {
        "fiveHour": window, "weekly": window, "monthly": window}}}

    def request(method, url, *, headers):
        calls.append((method, url, headers))
        return account if url.endswith("/auth/me") else billing

    monkeypatch.setattr(provider_usage_factory, "_default_http_json", request)
    return calls, account, billing


def test_factory_save_is_the_only_validation_opt_in(context, factory_transport):
    home, backend, controller = context
    calls, _, _ = factory_transport
    before = {p: p.read_bytes() for p in home.rglob("*") if p.is_file()}
    assert calls == []
    call(controller, provider="factory", account="api-key", secret="synthetic-old")
    assert calls == []  # The existing local-only credential command stays local.
    result = call(controller, "connect_factory_api_key", secret="synthetic-new")
    assert result == dict(provider="factory", instance="default", account="api-key", available=True)
    assert list(backend.values.values()) == ["synthetic-new"]
    assert [(method, url) for method, url, _ in calls] == [
        ("GET", "https://api.factory.ai/api/app/auth/me"),
        ("GET", "https://api.factory.ai/api/billing/limits"),
    ]
    assert all(headers["Authorization"] == "Bearer synthetic-new" for _, _, headers in calls)
    assert all("Cookie" not in headers for _, _, headers in calls)
    assert before == {p: p.read_bytes() for p in home.rglob("*") if p.is_file()}
    controller._request_provider_usage.assert_not_called()


@pytest.mark.parametrize("instance", ["default", "work"])
def test_factory_validated_key_stays_in_its_configured_instance(context, factory_transport, instance):
    _, backend, controller = context
    loaded = load_provider_usage_settings()
    save_provider_usage_settings(
        loaded.settings.with_instance(ProviderPreference("factory", enabled=False, browser_sources=False,
                                                       source_instance_id="work")),
        default_provider_usage_settings_path(), loaded=loaded,
    )
    before = load_provider_usage_settings().settings
    call(controller, provider="factory", account="api-key", secret="synthetic-default")
    call(controller, "connect_factory_api_key", instance=instance, secret="synthetic-new")
    store = controller._jrbar_provider_credential_store
    assert store.get("factory", "api-key").secret == ("synthetic-new" if instance == "default" else "synthetic-default")
    assert len(backend.values) == (1 if instance == "default" else 2)
    assert load_provider_usage_settings().settings == before


@pytest.mark.parametrize("args,code", [
    ({"secret": "a\nb"}, "invalid_args"),
    ({"secret": "synthetic-key", "instance": "missing"}, "unknown_instance"),
])
def test_factory_invalid_save_never_requests(context, factory_transport, args, code):
    _, backend, controller = context
    with pytest.raises(CommandError) as error:
        call(controller, "connect_factory_api_key", **args)
    assert error.value.code == code
    assert factory_transport[0] == []
    assert backend.values == {}


@pytest.mark.parametrize("status,code", [(401, "authentication_required"), (403, "usage_access_denied"),
    (429, "rate_limited"), (0, "network_unavailable"), (500, "network_unavailable")])
@pytest.mark.parametrize("stage", ["account", "billing"])
def test_factory_validation_failure_preserves_key_and_redacts(context, factory_transport, monkeypatch, status, code, stage):
    from jrbar import provider_usage_factory
    from jrbar.provider_usage_collectors import ProviderHttpError

    _, backend, controller = context
    _, account, _ = factory_transport
    call(controller, provider="factory", account="api-key", secret="synthetic-old")

    def fail(method, url, **kwargs):
        if stage == "billing" and url.endswith("/auth/me"):
            return account
        raise ProviderHttpError(status, "synthetic-secret")

    monkeypatch.setattr(provider_usage_factory, "_default_http_json", fail)
    logs = []
    server = CoreServer(dispatch=lambda name, args: call(controller, name, **args),
                        initial_documents=lambda: [], log=logs.append)
    reply = server.run_command("test", "connect_factory_api_key", {"secret": "synthetic-secret"})
    assert reply["ok"] is False
    assert reply["error"]["code"] == code
    assert "synthetic-secret" not in json.dumps([reply, logs, list(server._journal)])
    assert list(backend.values.values()) == ["synthetic-old"]


@pytest.mark.parametrize("stage", ["account", "billing"])
def test_factory_bad_response_never_saves(context, factory_transport, stage):
    _, backend, controller = context
    _, account, billing = factory_transport
    (account if stage == "account" else billing).clear()
    with pytest.raises(CommandError) as error:
        call(controller, "connect_factory_api_key", secret="synthetic-key")
    assert error.value.code == "invalid_response"
    assert backend.values == {}


def test_factory_legacy_validation_uses_the_same_usage_reader(context, factory_transport, monkeypatch):
    from jrbar import provider_usage_factory

    _, _, controller = context
    calls, account, billing = factory_transport
    billing.clear()
    billing["usesTokenRateLimitsBilling"] = False

    def legacy(method, url, *, headers):
        calls.append((method, url, headers))
        if url.endswith("/auth/me"):
            return account
        if url.endswith("/billing/limits"):
            return billing
        return {"usage": {"standard": {"usedRatio": 0.25}, "endDate": 2000}}

    monkeypatch.setattr(provider_usage_factory, "_default_http_json", legacy)
    assert call(controller, "connect_factory_api_key", secret="synthetic-key")["available"]
    assert calls[-1][1] == "https://api.factory.ai/api/organization/subscription/usage?useCache=true&userId=synthetic-user"


def test_factory_storage_failure_after_validation_is_redacted(context, factory_transport):
    _, backend, controller = context
    call(controller, provider="factory", account="api-key", secret="synthetic-old")
    backend.failure = True
    with pytest.raises(CommandError) as error:
        call(controller, "connect_factory_api_key", secret="synthetic-secret")
    assert error.value.code == "credential_unavailable"
    assert "synthetic-secret" not in str(error.value)
    assert list(backend.values.values()) == ["synthetic-old"]
