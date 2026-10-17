"""Factory browser connections use synthetic browser data and a fake Keychain."""

import json
import sqlite3
import tempfile
from pathlib import Path
from types import SimpleNamespace

import pytest

from jrbar.core_server import CommandError
from jrbar.provider_credential_store import ProviderCredentialStore
from jrbar.provider_usage_factory import collect_factory
from jrbar.provider_usage_platform import ProviderSourceState


class Backend:
    def __init__(self):
        self.values = {}

    def get_password(self, service, account):
        return self.values.get((service, account))

    def set_password(self, service, account, secret):
        self.values[service, account] = secret

    def delete_password(self, service, account):
        self.values.pop((service, account), None)


@pytest.fixture
def context(tmp_path, monkeypatch):
    monkeypatch.setattr(Path, "home", lambda: tmp_path)
    return tmp_path, ProviderCredentialStore(backend=Backend())


def session(**changes):
    return dict(
        refresh_token="synthetic-refresh-token",
        access_token="synthetic-access-token",
        browser="zen",
        profile="synthetic.default",
        consent_version=1,
    ) | changes


def preference(**changes):
    return SimpleNamespace(**(dict(enabled=True, usage_consented=True, source_instance_id="default") | changes))


def billing():
    return {
        "usesTokenRateLimitsBilling": True,
        "limits": {
            "standard": {
                key: {"usedPercent": value} for key, value in [("fiveHour", 12), ("weekly", 34), ("monthly", 56)]
            }
        },
    }


def auth(user="synthetic-user", org="synthetic-org"):
    return {"userProfile": {"id": user}, "organization": {"id": org}}


def browser_database(home, origin="app.factory.ai", refresh="synthetic-refresh-token"):
    profile = home / "Library/Application Support/zen/Profiles/synthetic.default"
    path = profile / "storage/default" / f"https+++{origin}" / "ls/data.sqlite"
    path.parent.mkdir(parents=True, exist_ok=True)
    db = sqlite3.connect(path)
    db.execute("CREATE TABLE data (key TEXT, value BLOB, compression_type INTEGER)")
    db.executemany(
        "INSERT INTO data VALUES (?, ?, 0)",
        [
            ("workos:refresh-token", refresh),
            ("workos:access-token", "synthetic-access-token"),
            ("unrelated-secret", "must-never-import"),
        ],
    )
    db.commit()
    db.close()
    return profile


def test_commands_require_confirmation_before_browser_read(context, monkeypatch):
    from jrbar import factory_session as module

    home, store = context
    monkeypatch.setattr(module, "read_browser_session", lambda *_a, **_k: pytest.fail("read before confirmation"))
    with pytest.raises(CommandError) as caught:
        module.import_session({"browser": "zen", "profile": "synthetic.default"}, store)
    assert caught.value.code == "invalid_args"
    assert store._backend.values == {}


def test_import_disconnect_and_metadata_profiles_keep_usage_off(context):
    from jrbar import factory_session as module
    from jrbar.provider_browser_consent import load_browser_consents
    from jrbar.provider_usage_settings import load_provider_usage_settings

    home, store = context
    browser_database(home)
    before = load_provider_usage_settings().settings
    assert module.profiles({}) == {
        "profiles": [{"browser": "zen", "profile": "synthetic.default", "label": "Zen · synthetic.default"}]
    }
    result = module.import_session({"browser": "zen", "profile": "synthetic.default", "confirm": True}, store)
    assert result["provider"] == "factory"
    saved = json.loads(store.get("factory", "web-session").secret)
    assert saved == session()
    consent = load_browser_consents().store.consents[0]
    assert consent.domains == ("app.factory.ai", "auth.factory.ai")
    assert consent.fields == ("workos:refresh-token", "workos:access-token")
    assert not consent.background_repair
    store.set("factory", "api-key", "synthetic-api-key")
    module.disconnect({}, store)
    assert not store.get("factory", "web-session").available
    assert store.get("factory", "api-key").secret == "synthetic-api-key"
    assert load_browser_consents().store.consents == ()
    assert load_provider_usage_settings().settings == before


@pytest.mark.parametrize("name", ["factory_session_profiles", "factory_session_import", "factory_session_disconnect"])
def test_factory_commands_accept_valid_arguments_over_the_socket(context, name):
    from jrbar import core_runtime, factory_session
    from tests.test_core_server import _connect
    from tests.test_core_server_hardening import _command, _read_strict, _serve

    home, store = context
    browser_database(home)
    arguments = {"browser": "zen", "profile": "synthetic.default", "confirm": True}
    if name == "factory_session_disconnect":
        factory_session.import_session(arguments, store)
    args = arguments if name == "factory_session_import" else {}
    controller = SimpleNamespace(_jrbar_provider_credential_store=store)

    def dispatch(command, command_args):
        return core_runtime._MAIN_THREAD_COMMANDS[command].handler(controller, command_args)

    with tempfile.TemporaryDirectory(prefix="jrbar-factory-", dir="/tmp") as directory:
        server = _serve(Path(directory), dispatch)
        try:
            with _connect(server) as client:
                _read_strict(client, 1)
                client.sendall(_command("valid", name, args))
                reply = _read_strict(client, 1)[0]
                assert reply["ok"], reply.get("error")
                if name == "factory_session_profiles":
                    assert reply["result"]["profiles"] == [{
                        "browser": "zen", "profile": "synthetic.default", "label": "Zen · synthetic.default",
                    }]
                else:
                    assert reply["result"]["provider"] == "factory"
                    assert reply["result"]["instance"] == "default"
                    assert store.get("factory", "web-session").available == (name == "factory_session_import")

                client.sendall(_command("invalid", name, {**args, "unexpected": True}))
                refused = _read_strict(client, 1)[0]
                assert not refused["ok"]
                assert refused["error"]["code"] == "invalid_args"
        finally:
            server.stop()


def test_missing_or_ambiguous_session_leaves_no_grant(context):
    from jrbar import factory_session as module
    from jrbar.provider_browser_consent import load_browser_consents

    home, store = context
    for setup in (False, True):
        if setup:
            browser_database(home)
            browser_database(home, "auth.factory.ai", "synthetic-other-refresh")
        with pytest.raises(CommandError) as caught:
            module.import_session({"browser": "zen", "profile": "synthetic.default", "confirm": True}, store)
        assert caught.value.code == "browser_session_not_found"
        assert "https://app.factory.ai" in str(caught.value)
        assert not load_browser_consents().store.consents
        assert not store._backend.values


def test_invalid_web_session_cannot_fall_back_to_api_key(context):
    _, store = context
    store.set("factory", "web-session", "invalid-json")
    store.set("factory", "api-key", "synthetic-api-key")
    result = collect_factory(
        preference(),
        observed_at=1000,
        credentials=store,
        http_json=lambda *_a, **_k: pytest.fail("invalid session network"),
    )
    assert result.state is ProviderSourceState.NEEDS_SIGN_IN
    assert result.action_label == "Reconnect Factory browser session"


def test_refresh_rotates_and_verifies_auth_before_usage(context):
    _, store = context
    original = session()
    original.pop("access_token")
    store.set("factory", "web-session", json.dumps(original))
    store.set("factory", "api-key", "synthetic-api-key")
    calls = []

    def http(method, url, **kwargs):
        calls.append((method, url, kwargs))
        if "workos.com" in url:
            assert kwargs["body"]["refresh_token"] == original["refresh_token"]
            return {"access_token": "synthetic-new-access", "refresh_token": "synthetic-new-refresh"}
        assert kwargs["headers"]["Authorization"] == "Bearer synthetic-new-access"
        return auth() if url.endswith("/auth/me") else billing()

    result = collect_factory(preference(), observed_at=1000, credentials=store, http_json=http)
    assert result.state is ProviderSourceState.READY
    saved = json.loads(store.get("factory", "web-session").secret)
    assert saved["refresh_token"] == "synthetic-new-refresh"
    assert saved["identity"] == result.account_discriminator
    assert saved["organization_id"] == "synthetic-org"
    assert calls[0][0:2] == ("POST", "https://api.workos.com/user_management/authenticate")
    assert len(calls) == 3


def test_disconnect_during_refresh_cannot_resurrect_session(context):
    from jrbar import factory_session as module

    _, store = context
    original = session()
    original.pop("access_token")
    store.set("factory", "web-session", json.dumps(original))

    def http(_method, url, **_kwargs):
        if "workos.com" in url:
            module.disconnect({}, store)
            return {"access_token": "synthetic-new-access"}
        return auth() if url.endswith("/auth/me") else billing()

    result = collect_factory(preference(), observed_at=1000, credentials=store, http_json=http)
    assert result.state is ProviderSourceState.NEEDS_SIGN_IN
    assert not store.get("factory", "web-session").available


@pytest.mark.parametrize("enabled,consented", [(False, True), (True, False)])
def test_disabled_does_not_read_sessions(enabled, consented):
    class Forbidden:
        def get(self, *_args):
            pytest.fail("disabled credential read")

    result = collect_factory(
        preference(enabled=enabled, usage_consented=consented),
        observed_at=1000,
        credentials=Forbidden(),
        http_json=lambda *_a, **_k: pytest.fail("disabled HTTP"),
    )
    assert result.lanes == ()


def test_workos_rejection_never_tries_api_key(context):
    from jrbar.provider_usage_collectors import ProviderHttpError

    _, store = context
    original = session()
    original.pop("access_token")
    store.set("factory", "web-session", json.dumps(original))
    store.set("factory", "api-key", "synthetic-api-key")
    calls = []

    def http(method, url, **_kwargs):
        calls.append((method, url))
        raise ProviderHttpError(400, "invalid_grant")

    result = collect_factory(preference(), observed_at=1000, credentials=store, http_json=http)
    assert result.state is ProviderSourceState.NEEDS_SIGN_IN
    assert len(calls) == 2 and all("workos.com" in url for _, url in calls)
    assert json.loads(store.get("factory", "web-session").secret) == original


def test_refresh_preserves_refresh_token_and_checks_identity(context):
    from jrbar.provider_usage_collectors import ProviderHttpError
    from jrbar.provider_usage_factory import _identity

    _, store = context
    initial = session(identity=_identity(auth())[0], organization_id="synthetic-org")
    for user in ("synthetic-other-user", "synthetic-user"):
        store.set("factory", "web-session", json.dumps(initial))
        calls = []

        def http(method, url, **kwargs):
            calls.append(url)
            if "workos.com" in url:
                assert kwargs["body"]["organization_id"] == "synthetic-org"
                return {"access_token": "synthetic-new-access"}
            if len(calls) == 1:
                raise ProviderHttpError(401, "http_error")
            return auth(user) if url.endswith("/auth/me") else billing()

        result = collect_factory(preference(), observed_at=1000, credentials=store, http_json=http)
        saved = json.loads(store.get("factory", "web-session").secret)
        assert saved["refresh_token"] == initial["refresh_token"]
        if user == "synthetic-other-user":
            assert result.state is ProviderSourceState.NEEDS_SIGN_IN
            assert saved["identity"] == initial["identity"]
            assert saved["organization_id"] == initial["organization_id"]
            assert saved["access_token"] == "synthetic-new-access"
            assert not any(url.endswith("/billing/limits") for url in calls)
        else:
            assert result.state is ProviderSourceState.READY
            assert saved["access_token"] == "synthetic-new-access"


def test_reconnect_during_refresh_keeps_new_session(context):
    _, store = context
    initial = session()
    initial.pop("access_token")
    store.set("factory", "web-session", json.dumps(initial))
    new = session()
    new["refresh_token"] = "synthetic-reconnected-refresh"

    def http(_method, url, **_kwargs):
        if "workos.com" in url:
            store.set("factory", "web-session", json.dumps(new))
            return {"access_token": "synthetic-new-access"}
        return auth() if url.endswith("/auth/me") else billing()

    result = collect_factory(preference(), observed_at=1000, credentials=store, http_json=http)
    assert result.state is ProviderSourceState.NEEDS_SIGN_IN
    assert json.loads(store.get("factory", "web-session").secret) == new


def test_named_import_disconnect_isolates_default_and_other_grants(context):
    from jrbar import factory_session as module
    from jrbar.provider_instances import ProviderInstanceKey
    from jrbar.provider_usage_runtime import _InstanceCredentialView
    from jrbar.provider_usage_settings import (
        ProviderPreference,
        load_provider_usage_settings,
        save_provider_usage_settings,
    )

    home, store = context
    browser_database(home)
    loaded = load_provider_usage_settings()
    save_provider_usage_settings(
        loaded.settings.with_instance(
            ProviderPreference("factory", enabled=False, browser_sources=False, source_instance_id="work")
        ),
        loaded=loaded,
    )
    for instance in ("default", "work"):
        module.import_session(
            {"browser": "zen", "profile": "synthetic.default", "confirm": True, "instance": instance}, store
        )
    view = _InstanceCredentialView(store, ProviderInstanceKey("factory", "work"))
    result = collect_factory(
        preference(source_instance_id="work"),
        observed_at=1000,
        credentials=view,
        http_json=lambda _method, url, **_kwargs: auth() if url.endswith("/auth/me") else billing(),
    )
    assert result.state is ProviderSourceState.READY
    assert result.source_instance_id == "work"
    module.disconnect({"instance": "work"}, store)
    assert store.get("factory", "web-session").available
    assert not store.get_for_instance(ProviderInstanceKey("factory", "work"), "web-session").available


def test_registered_commands_are_privileged_workers_and_generic_session_writes_refuse(context):
    from jrbar import core_runtime
    from jrbar.core_auth import privilege_of
    from jrbar.provider_credential_commands import change_credential

    _, store = context
    for name in ("factory_session_profiles", "factory_session_import", "factory_session_disconnect"):
        assert name in core_runtime._MAIN_THREAD_COMMANDS
        assert not core_runtime._MAIN_THREAD_COMMANDS[name].main_thread
        assert privilege_of(name) == "privileged"
    for delete in (False, True):
        with pytest.raises(CommandError) as caught:
            change_credential(
                {"provider": "factory", "account": "web-session", "secret": "synthetic"}, store, delete=delete
            )
        assert caught.value.code == "invalid_args"


def test_chromium_reader_keeps_origin_and_key_allowlists(context, monkeypatch):
    from jrbar import factory_session as module

    home, _ = context
    root = home / "Library/Application Support/Google/Chrome/Default"
    (root / "Local Storage/leveldb").mkdir(parents=True)
    calls = []

    def read(path, **kwargs):
        assert path == root
        assert kwargs["allowed_keys"] == ("workos:refresh-token", "workos:access-token")
        calls.append(kwargs["origin"])
        return {"workos:refresh-token": "synthetic-refresh-token", "workos:access-token": "synthetic-access-token"}

    monkeypatch.setattr(module, "read_chromium_local_storage", read)
    saved = module.read_browser_session("chrome", "Default")
    assert saved["refresh_token"] == "synthetic-refresh-token"
    assert calls == ["https://app.factory.ai", "https://auth.factory.ai"]


def test_missing_workos_refresh_permission_fails_without_network(context):
    _, store = context
    original = session()
    original["consent_version"] = 0
    store.set("factory", "web-session", json.dumps(original))
    result = collect_factory(
        preference(),
        observed_at=1000,
        credentials=store,
        http_json=lambda *_a, **_k: pytest.fail("missing WorkOS consent"),
    )
    assert result.state is ProviderSourceState.NEEDS_SIGN_IN


def test_symlink_and_path_profiles_do_not_read_browser_storage(context):
    from jrbar import factory_session as module

    home, _ = context
    root = home / "Library/Application Support/zen/Profiles"
    root.mkdir(parents=True)
    (root / "synthetic.default").symlink_to(home, target_is_directory=True)
    assert module.profiles({}) == {"profiles": []}
    assert module.read_browser_session("zen", "synthetic.default") is None
    for profile in ("..", "../other", "", "has\x00nul"):
        with pytest.raises(CommandError):
            module.import_session({"browser": "zen", "profile": profile, "confirm": True}, context[1])


def test_disconnect_during_billing_discards_old_account_reading(context):
    from jrbar import factory_session as module

    _, store = context
    store.set("factory", "web-session", json.dumps(session()))

    def http(_method, url, **_kwargs):
        if url.endswith("/auth/me"):
            return auth()
        module.disconnect({}, store)
        return billing()

    result = collect_factory(preference(), observed_at=1000, credentials=store, http_json=http)
    assert result.state is ProviderSourceState.NEEDS_SIGN_IN
    assert result.account_discriminator is None and not result.lanes


def test_jwt_org_routing_hint_is_imported_and_verified(context):
    import base64

    from jrbar import factory_session as module
    from jrbar.provider_usage_collectors import ProviderHttpError

    home, store = context
    profile = browser_database(home)
    claims = base64.urlsafe_b64encode(json.dumps({"org_id": "synthetic-org"}).encode()).decode().rstrip("=")
    access = "synthetic-header." + claims + ".synthetic-signature"
    database = profile / "storage/default/https+++app.factory.ai/ls/data.sqlite"
    db = sqlite3.connect(database)
    db.execute("UPDATE data SET value=? WHERE key=?", (access, "workos:access-token"))
    db.commit()
    db.close()
    module.import_session({"browser": "zen", "profile": "synthetic.default", "confirm": True}, store)
    assert json.loads(store.get("factory", "web-session").secret)["organization_id"] == "synthetic-org"
    calls = []

    def http(_method, url, **kwargs):
        calls.append(url)
        if len(calls) == 1:
            raise ProviderHttpError(401, "http_error")
        if "workos.com" in url:
            assert kwargs["body"]["organization_id"] == "synthetic-org"
            return {"access_token": "synthetic-new-access"}
        return auth(org="synthetic-other-org")

    result = collect_factory(preference(), observed_at=1000, credentials=store, http_json=http)
    assert result.state is ProviderSourceState.NEEDS_SIGN_IN
    assert len(calls) == 3
    assert "identity" not in json.loads(store.get("factory", "web-session").secret)


def test_identical_poll_does_not_rewrite_keychain(context, monkeypatch):
    from jrbar.provider_usage_factory import _identity

    _, store = context
    original = session(identity=_identity(auth())[0], organization_id="synthetic-org")
    store.set("factory", "web-session", json.dumps(original, separators=(",", ":"), sort_keys=True))
    monkeypatch.setattr(store._backend, "set_password", lambda *_a: pytest.fail("unchanged session rewritten"))
    result = collect_factory(
        preference(),
        observed_at=1000,
        credentials=store,
        http_json=lambda _method, url, **_kwargs: auth() if url.endswith("/auth/me") else billing(),
    )
    assert result.state is ProviderSourceState.READY


def test_disconnect_during_import_does_not_reconnect(context, monkeypatch):
    from jrbar import factory_session as module

    home, store = context
    browser_database(home)
    original_reader = module.read_browser_session

    def read(*args, **kwargs):
        value = original_reader(*args, **kwargs)
        module.disconnect({}, store)
        return value

    monkeypatch.setattr(module, "read_browser_session", read)
    with pytest.raises(CommandError) as caught:
        module.import_session({"browser": "zen", "profile": "synthetic.default", "confirm": True}, store)
    assert caught.value.code == "credential_unavailable"
    assert not store.get("factory", "web-session").available


def test_symlinked_firefox_ancestor_is_not_followed(context):
    from jrbar import factory_session as module

    home, _ = context
    profile = browser_database(home)
    library = home / "Library"
    library.rename(home / "moved-library")
    library.symlink_to(home / "moved-library", target_is_directory=True)
    assert module.profiles({}) == {"profiles": []}
    assert module.read_browser_session("zen", profile.name) is None


def test_keychain_write_failure_rolls_back_new_browser_consent(context, monkeypatch):
    from jrbar import factory_session as module
    from jrbar.provider_browser_consent import load_browser_consents

    home, store = context
    browser_database(home)

    def refuse(*_args):
        raise RuntimeError("synthetic secret must not escape")

    monkeypatch.setattr(store, "set_for_instance", refuse)
    with pytest.raises(CommandError) as caught:
        module.import_session({"browser": "zen", "profile": "synthetic.default", "confirm": True}, store)
    assert caught.value.code == "credential_unavailable"
    assert "synthetic secret" not in str(caught.value)
    assert not load_browser_consents().store.consents


@pytest.mark.parametrize("raw", ["[]", '{"browser":{}}', '{"browser":"zen","consent_version":true}'])
def test_malformed_web_session_is_a_safe_auth_failure(context, raw):
    _, store = context
    store.set("factory", "web-session", raw)
    result = collect_factory(
        preference(),
        observed_at=1000,
        credentials=store,
        http_json=lambda *_a, **_k: pytest.fail("malformed session HTTP"),
    )
    assert result.state is ProviderSourceState.NEEDS_SIGN_IN


def test_import_rollback_preserves_concurrent_other_provider_grant(context, monkeypatch):
    from jrbar import factory_session as module
    from jrbar.provider_browser_consent import load_browser_consents, save_browser_consents

    home, store = context
    browser_database(home)

    def refuse_after_other_grant(*_args):
        current = load_browser_consents()
        updated = current.store.grant(
            provider_id="devin",
            browser="zen",
            profile="other.default",
            domains=("app.devin.ai",),
            fields=("auth1_session",),
            background_repair=False,
            granted_at=1000,
            source_instance_id="default",
        )
        save_browser_consents(updated, loaded=current)
        raise RuntimeError("synthetic Keychain failure")

    monkeypatch.setattr(store, "set_for_instance", refuse_after_other_grant)
    with pytest.raises(CommandError):
        module.import_session({"browser": "zen", "profile": "synthetic.default", "confirm": True}, store)
    grants = load_browser_consents().store.consents
    assert len(grants) == 1 and grants[0].provider_id == "devin"


def test_invalid_nonempty_web_credential_does_not_fall_back(context):
    _, store = context
    # A raw backend can contain malformed data even though public setters forbid it.
    store._backend.set_password("com.jonathanreed.jrbar.provider.factory", "web-session", "invalid\x00json")
    store.set("factory", "api-key", "synthetic-api-key")
    result = collect_factory(
        preference(),
        observed_at=1000,
        credentials=store,
        http_json=lambda *_a, **_k: pytest.fail("invalid web credential fell back"),
    )
    assert result.state is ProviderSourceState.NEEDS_SIGN_IN


def test_chromium_snapshot_decodes_only_live_selected_factory_fields(context, monkeypatch):
    from jrbar import factory_session as module
    from jrbar import provider_browser_import as chromium

    home, _ = context
    source = home / "Library/Application Support/Google/Chrome/Default/Local Storage/leveldb"
    source.mkdir(parents=True)
    (source / "000001.log").write_bytes(b"synthetic snapshot bytes")
    live, deleted = object(), object()

    def record(origin, key, value, sequence, state=live):
        return SimpleNamespace(
            user_key=b"_" + origin.encode() + b"\x00\x01" + key.encode(),
            value=b"\x01" + value.encode(),
            seq=sequence,
            state=state,
        )

    records = [
        record("https://app.factory.ai", "workos:refresh-token", "synthetic-old-refresh", 1),
        record("https://app.factory.ai", "workos:refresh-token", "synthetic-new-refresh", 2),
        record("https://app.factory.ai", "workos:access-token", "synthetic-old-access", 3),
        record("https://app.factory.ai", "workos:access-token", "", 4, deleted),
        record("https://unrelated.example", "workos:refresh-token", "synthetic-wrong-origin", 5),
        record("https://app.factory.ai", "unrelated-secret", "synthetic-wrong-key", 6),
    ]

    class RawDB:
        def __init__(self, path):
            assert Path(path) != source
            assert (Path(path) / "000001.log").read_bytes() == b"synthetic snapshot bytes"

        def __enter__(self):
            return self

        def __exit__(self, *_args):
            return False

        def iterate_records_raw(self):
            return records

    monkeypatch.setattr(chromium, "_default_leveldb_runtime", lambda: (RawDB, live, deleted))
    saved = module.read_browser_session("chrome", "Default")
    assert saved == {
        "browser": "chrome",
        "profile": "Default",
        "consent_version": 1,
        "refresh_token": "synthetic-new-refresh",
    }


def test_sqlite_snapshot_rejects_oversized_and_compressed_tokens(context, monkeypatch):
    from jrbar import browser_session_import as sqlite_reader
    from jrbar import factory_session as module

    home, _ = context
    profile = browser_database(home)
    database = profile / "storage/default/https+++app.factory.ai/ls/data.sqlite"
    original_bytes = database.read_bytes()
    monkeypatch.setattr(sqlite_reader, "MAX_LOCAL_STORAGE_BYTES", len(original_bytes) - 1)
    assert module.read_browser_session("zen", profile.name) is None
    monkeypatch.setattr(sqlite_reader, "MAX_LOCAL_STORAGE_BYTES", 64 * 1024 * 1024)
    db = sqlite3.connect(database)
    db.execute("UPDATE data SET compression_type=1 WHERE key='workos:refresh-token'")
    db.commit()
    db.close()
    assert module.read_browser_session("zen", profile.name) is None


def test_factory_commands_use_socket_action_worker_lane():
    from jrbar.core_server import ACTION_LANE_COMMANDS

    assert {"factory_session_profiles", "factory_session_import", "factory_session_disconnect"} <= ACTION_LANE_COMMANDS


def test_rotated_tokens_survive_transient_auth_validation_failure(context):
    from jrbar.provider_usage_collectors import ProviderHttpError
    from jrbar.provider_usage_factory import _identity

    _, store = context
    original = session(identity=_identity(auth())[0], organization_id="synthetic-org")
    original.pop("access_token")
    store.set("factory", "web-session", json.dumps(original))
    calls = []

    def http(_method, url, **_kwargs):
        calls.append(url)
        if "workos.com" in url:
            return {"access_token": "synthetic-rotated-access", "refresh_token": "synthetic-rotated-refresh"}
        assert url.endswith("/auth/me")
        raise ProviderHttpError(503, "http_error")

    result = collect_factory(preference(), observed_at=1000, credentials=store, http_json=http)
    saved = json.loads(store.get("factory", "web-session").secret)
    assert result.state is ProviderSourceState.UNAVAILABLE
    assert not result.lanes
    assert saved["refresh_token"] == "synthetic-rotated-refresh"
    assert saved["access_token"] == "synthetic-rotated-access"
    assert saved["identity"] == original["identity"]
    assert saved["organization_id"] == original["organization_id"]
    assert len(calls) == 2


@pytest.mark.parametrize("change", ["disconnect", "reimport"])
def test_renewal_cannot_overwrite_concurrent_disconnect_or_reimport(context, change):
    from jrbar import factory_session as module

    home, store = context
    original = session()
    original.pop("access_token")
    store.set("factory", "web-session", json.dumps(original))
    browser_database(home, refresh="synthetic-reimported-refresh")
    calls = []
    expected = []

    def http(_method, url, **_kwargs):
        calls.append(url)
        assert "workos.com" in url
        if change == "disconnect":
            module.disconnect({}, store)
        else:
            module.import_session({"browser": "zen", "profile": "synthetic.default", "confirm": True}, store)
        expected.append(store.get("factory", "web-session").secret)
        return {"access_token": "synthetic-rotated-access", "refresh_token": "synthetic-rotated-refresh"}

    result = collect_factory(preference(), observed_at=1000, credentials=store, http_json=http)
    assert result.state is ProviderSourceState.NEEDS_SIGN_IN
    assert not result.lanes
    assert len(calls) == 1
    assert store.get("factory", "web-session").secret == expected[0]
    if change == "reimport":
        assert json.loads(expected[0])["refresh_token"] == "synthetic-reimported-refresh"


def test_second_known_workos_client_is_saved_and_used_first_next_time(context):
    from jrbar.provider_usage_collectors import ProviderHttpError

    _, store = context
    original = session()
    original.pop("access_token")
    store.set("factory", "web-session", json.dumps(original))
    clients = []

    def http(_method, url, **kwargs):
        if "workos.com" in url:
            client = kwargs["body"]["client_id"]
            clients.append(client)
            if client == "client_01HXRMBQ9BJ3E7QSTQ9X2PHVB7":
                raise ProviderHttpError(400, "http_error")
            return {"access_token": "synthetic-rotated-access", "refresh_token": "synthetic-rotated-refresh"}
        return auth() if url.endswith("/auth/me") else billing()

    first = collect_factory(preference(), observed_at=1000, credentials=store, http_json=http)
    assert first.state is ProviderSourceState.READY
    assert clients == ["client_01HXRMBQ9BJ3E7QSTQ9X2PHVB7", "client_01HNM792M5G5G1A2THWPXKFMXB"]
    saved = json.loads(store.get("factory", "web-session").secret)
    assert saved["client_id"] == clients[-1]
    saved.pop("access_token")
    store.set("factory", "web-session", json.dumps(saved))
    clients.clear()
    second = collect_factory(preference(), observed_at=1001, credentials=store, http_json=http)
    assert second.state is ProviderSourceState.READY
    assert clients == ["client_01HNM792M5G5G1A2THWPXKFMXB"]


@pytest.mark.parametrize("status", [0, 429, 500, 503])
def test_workos_client_does_not_fall_back_after_transient_error(context, status):
    from jrbar.provider_usage_collectors import ProviderHttpError

    _, store = context
    original = session()
    original.pop("access_token")
    store.set("factory", "web-session", json.dumps(original))
    calls = []

    def http(_method, url, **_kwargs):
        calls.append(url)
        raise ProviderHttpError(status, "network_error")

    result = collect_factory(preference(), observed_at=1000, credentials=store, http_json=http)
    assert result.state in {ProviderSourceState.UNAVAILABLE, ProviderSourceState.RATE_LIMITED}
    assert len(calls) == 1
    assert json.loads(store.get("factory", "web-session").secret) == original


def test_both_workos_clients_rejected_never_falls_back_to_api(context):
    from jrbar.provider_usage_collectors import ProviderHttpError

    _, store = context
    original = session()
    original.pop("access_token")
    store.set("factory", "web-session", json.dumps(original))
    store.set("factory", "api-key", "synthetic-api-key")
    calls = []

    def http(_method, url, **kwargs):
        assert "workos.com" in url
        calls.append(kwargs["body"]["client_id"])
        raise ProviderHttpError(401, "http_error")

    result = collect_factory(preference(), observed_at=1000, credentials=store, http_json=http)
    assert result.state is ProviderSourceState.NEEDS_SIGN_IN
    assert len(calls) == 2 and len(set(calls)) == 2
    assert json.loads(store.get("factory", "web-session").secret) == original


@pytest.mark.parametrize("response", [None, {}, {"access_token": "bad\ntoken"}])
def test_workos_client_does_not_retry_malformed_success(context, response):
    _, store = context
    original = session()
    original.pop("access_token")
    store.set("factory", "web-session", json.dumps(original))
    calls = []

    def http(_method, url, **_kwargs):
        calls.append(url)
        return response

    result = collect_factory(preference(), observed_at=1000, credentials=store, http_json=http)
    assert result.state is ProviderSourceState.ERROR
    assert len(calls) == 1
    assert json.loads(store.get("factory", "web-session").secret) == original


def test_saved_unknown_workos_client_is_rejected_before_network(context):
    _, store = context
    original = session(client_id="synthetic-unknown-client")
    store.set("factory", "web-session", json.dumps(original))
    result = collect_factory(
        preference(),
        observed_at=1000,
        credentials=store,
        http_json=lambda *_a, **_k: pytest.fail("unknown client request"),
    )
    assert result.state is ProviderSourceState.NEEDS_SIGN_IN


def identity_jwt(claims):
    import base64

    payload = base64.urlsafe_b64encode(json.dumps(claims).encode()).decode().rstrip("=")
    return "synthetic-header." + payload + ".synthetic-signature"


def test_valid_bearer_subject_cannot_bypass_auth_rejection(context):
    from jrbar.provider_usage_collectors import ProviderHttpError

    _, store = context
    token = identity_jwt({"sub": "synthetic-user"})
    store.set("factory", "web-session", json.dumps(session(access_token=token)))
    calls = []

    def http(_method, url, **_kwargs):
        calls.append(url)
        if "workos.com" in url:
            return {"access_token": token}
        raise ProviderHttpError(401, "http_error")

    result = collect_factory(preference(), observed_at=1000, credentials=store, http_json=http)
    assert result.state is ProviderSourceState.NEEDS_SIGN_IN
    assert result.reason_code == "authentication_required"
    assert result.account_discriminator is None and not result.lanes
    assert calls == ["https://api.factory.ai/api/app/auth/me",
                     "https://api.workos.com/user_management/authenticate",
                     "https://api.factory.ai/api/app/auth/me"]
    assert "identity" not in json.loads(store.get("factory", "web-session").secret)


def test_missing_profile_id_uses_bearer_subject_without_mutating_auth(context):
    from jrbar.provider_usage_factory import _identity

    _, store = context
    response = auth()
    del response["userProfile"]["id"]
    original = json.loads(json.dumps(response))
    store.set("factory", "web-session", json.dumps(session(access_token=identity_jwt({"sub": "synthetic-user"}))))
    results = [collect_factory(
        preference(), observed_at=1000 + index, credentials=store,
        http_json=lambda _method, url, **_kwargs: response if url.endswith("/auth/me") else billing(),
    ) for index in range(2)]
    assert all(result.state is ProviderSourceState.READY for result in results)
    assert all(result.account_discriminator == _identity(auth())[0] for result in results)
    assert response == original
    assert json.loads(store.get("factory", "web-session").secret)["identity"] == results[0].account_discriminator


@pytest.mark.parametrize("token,response", [
    (identity_jwt({}), auth(None)),
    (identity_jwt({"sub": ""}), auth(None)),
    (identity_jwt({"sub": "   "}), auth(None)),
    (identity_jwt({"sub": 123}), auth(None)),
    (identity_jwt({"sub": "x" * 201}), auth(None)),
    ("synthetic-malformed-token", auth(None)),
    ("header.!.signature", auth(None)),
    (identity_jwt({"sub": "synthetic-user"}), auth(None, org=None)),
    (identity_jwt({"sub": "synthetic-user"}), {"organization": {"id": "synthetic-org"}}),
    (identity_jwt({"sub": "synthetic-user"}), {"userProfile": None, "organization": {"id": "synthetic-org"}}),
], ids=["absent", "empty", "blank", "non-string", "oversized", "malformed", "invalid-base64", "missing-org",
        "missing-profile", "null-profile"])
def test_unavailable_account_identity_fails_honestly_before_billing(context, token, response):
    _, store = context
    store.set("factory", "web-session", json.dumps(session(access_token=token)))
    calls = []

    def http(_method, url, **_kwargs):
        calls.append(url)
        assert url.endswith("/auth/me"), "unproved identity reached billing"
        return response

    result = collect_factory(preference(), observed_at=1000, credentials=store, http_json=http)
    assert result.state is ProviderSourceState.ERROR
    assert result.reason_code == "account_identity_unavailable"
    assert result.account_discriminator is None and not result.lanes
    assert len(calls) == 1
    assert "identity" not in json.loads(store.get("factory", "web-session").secret)


def test_explicit_profile_id_wins_over_bearer_subject(context):
    from jrbar.provider_usage_factory import _identity

    _, store = context
    store.set("factory", "web-session", json.dumps(session(
        access_token=identity_jwt({"sub": "synthetic-other-user"}),
        identity=_identity(auth())[0], organization_id="synthetic-org",
    )))
    result = collect_factory(
        preference(), observed_at=1000, credentials=store,
        http_json=lambda _method, url, **_kwargs: auth() if url.endswith("/auth/me") else billing(),
    )
    assert result.state is ProviderSourceState.READY
    assert result.account_discriminator == _identity(auth())[0]


@pytest.mark.parametrize("subject,org", [
    ("synthetic-other-user", "synthetic-org"),
    ("synthetic-user", "synthetic-other-org"),
], ids=["changed-subject", "changed-org"])
def test_fallback_identity_change_rejects_protected_session(context, subject, org):
    from jrbar.provider_usage_factory import _identity

    _, store = context
    original = session(access_token=identity_jwt({"sub": subject}),
                       identity=_identity(auth())[0], organization_id="synthetic-org")
    store.set("factory", "web-session", json.dumps(original))
    calls = []

    def http(_method, url, **_kwargs):
        calls.append(url)
        assert url.endswith("/auth/me"), "changed account reached billing"
        return auth(None, org=org)

    result = collect_factory(preference(), observed_at=1000, credentials=store, http_json=http)
    assert result.state is ProviderSourceState.NEEDS_SIGN_IN
    assert result.reason_code == "web_session_account_changed"
    assert result.account_discriminator is None and not result.lanes
    assert len(calls) == 1
    assert json.loads(store.get("factory", "web-session").secret) == original


def test_missing_profile_id_after_refresh_uses_renewed_bearer_subject(context):
    from jrbar.provider_usage_collectors import ProviderHttpError
    from jrbar.provider_usage_factory import _identity

    _, store = context
    expired = identity_jwt({"sub": "synthetic-expired-user"})
    renewed = identity_jwt({"sub": "synthetic-user"})
    store.set("factory", "web-session", json.dumps(session(
        access_token=expired, identity=_identity(auth())[0], organization_id="synthetic-org",
    )))
    calls = []

    def http(_method, url, **kwargs):
        calls.append(url)
        if len(calls) == 1:
            raise ProviderHttpError(401, "http_error")
        if "workos.com" in url:
            return {"access_token": renewed}
        assert kwargs["headers"]["Authorization"] == "Bearer " + renewed
        return auth(None) if url.endswith("/auth/me") else billing()

    result = collect_factory(preference(), observed_at=1000, credentials=store, http_json=http)
    assert result.state is ProviderSourceState.READY
    assert result.account_discriminator == _identity(auth())[0]
    assert len(calls) == 4


@pytest.mark.parametrize("browser_session", [True, False], ids=["browser", "api-key"])
def test_legacy_usage_query_contains_authenticated_user_id(context, browser_session):
    from urllib.parse import parse_qs, urlencode, urlsplit

    _, store = context
    user = "synthetic-user+/&?"
    if browser_session:
        store.set("factory", "web-session", json.dumps(session(access_token=identity_jwt({"sub": user}))))
    else:
        store.set("factory", "api-key", "synthetic-api-key")
    calls = []

    def http(method, url, **_kwargs):
        calls.append(url)
        assert method == "GET"
        if url.endswith("/auth/me"):
            return auth(None if browser_session else user)
        if url.endswith("/billing/limits"):
            return {"usesTokenRateLimitsBilling": False}
        return {"usage": {"standard": {"usedRatio": 0.25}}}

    result = collect_factory(preference(), observed_at=1000, credentials=store, http_json=http)
    assert len(calls) == 3
    parsed = urlsplit(calls[-1])
    assert parsed.path == "/api/organization/subscription/usage"
    assert parse_qs(parsed.query) == {"useCache": ["true"], "userId": [user]}
    assert urlencode({"userId": user}) in parsed.query
    assert result.state is ProviderSourceState.READY
    assert result.lanes[0].remaining_percent == 75
