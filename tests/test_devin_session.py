"""Devin imports use fake profiles, a fake credential store, and no network."""

import json
import sqlite3
from dataclasses import replace
from pathlib import Path

import pytest

from jrbar import devin_session, provider_browser_access
from jrbar.browser_session_import import FIREFOX_FAMILY_PROFILE_ROOTS, BrowserSessionReadError
from jrbar.core_server import CommandError
from jrbar.provider_browser_consent import load_browser_consents, save_browser_consents
from jrbar.provider_usage_settings import load_provider_usage_settings, save_provider_usage_settings

TOKEN = "auth1_synthetic_browser_session_value"


class Store:
    def __init__(self):
        self.values = {}

    def set(self, provider, account, value):
        self.values[(provider, "default", account)] = value

    def set_for_instance(self, key, account, value):
        self.values[(*key.value, account)] = value


@pytest.fixture
def context(tmp_path, monkeypatch):
    monkeypatch.setattr(Path, "home", lambda: tmp_path)
    monkeypatch.setenv("XDG_CONFIG_HOME", str(tmp_path / ".config"))
    return tmp_path, Store()


def profile(home, relative, *, corrupt=False):
    root = home / "Library/Application Support" / relative / "synthetic.default"
    storage = root / "storage/default/https+++app.devin.ai/ls"
    storage.mkdir(parents=True)
    database = storage / "data.sqlite"
    if corrupt:
        database.write_bytes(b"synthetic damaged database")
        return
    with sqlite3.connect(database) as connection:
        connection.execute("CREATE TABLE data (key TEXT, value BLOB, compression_type INTEGER)")
        connection.executemany("INSERT INTO data VALUES (?, ?, 0)", [
            ("auth1_session", json.dumps({"token": TOKEN})),
            ("last-internal-org-for-external-org-v1-example", "org_synthetic"),
        ])


def args(browser="zen", **changes):
    return {"browser": browser, "profile": "synthetic.default", "confirm": True, **changes}


@pytest.mark.parametrize("browser,relative", [(label.lower(), relative) for label, relative in FIREFOX_FAMILY_PROFILE_ROOTS])
def test_selected_firefox_family_profile_imports_without_enabling_requests(context, browser, relative):
    home, store = context
    profile(home, relative)
    before = load_provider_usage_settings().settings.preference("devin").usage_consented
    result = devin_session.import_session(args(browser), store)
    assert result["instance"] == "default" and "imported" in result["message"]
    assert store.values[("devin", "default", "token")] == TOKEN
    pref = load_provider_usage_settings().settings.preference("devin")
    assert pref.usage_consented == before and pref.browser_sources
    assert pref.option("organization") == "org/example"
    assert len(load_browser_consents().store.consents) == 1


@pytest.mark.parametrize("changes", [{"confirm": False}, {"confirm": 1}, {"profile": "../other"}, {"browser": "unknown"}, {"background_repair": "yes"}])
def test_no_browser_read_or_credential_write_without_confirmation(context, monkeypatch, changes):
    _, store = context
    monkeypatch.setattr(provider_browser_access, "_load_consented_devin_session", lambda **_: pytest.fail("read without consent"))
    with pytest.raises(CommandError) as caught:
        devin_session.import_session(args(**changes), store)
    assert caught.value.code == "invalid_args"
    assert store.values == {} and not load_browser_consents().store.consents


def test_missing_consent_never_falls_into_clipboard_or_network(context, monkeypatch):
    _, store = context
    monkeypatch.setattr("jrbar.browser_session_import.import_devin_session_from_profile", lambda **_: pytest.fail("read without consent"))
    message = provider_browser_access.handle_provider_usage_action(
        "devin", "Import Devin browser session", credential_store=store,
        clipboard_reader=lambda: pytest.fail("unexpected clipboard"), url_opener=lambda _: pytest.fail("unexpected URL"),
    )
    assert "choose" in message.lower() and "profile" in message
    assert store.values == {}


@pytest.mark.parametrize("category,fix", [("storage_invalid", "database"), ("storage_unreadable", "access"),
                                         ("storage_changed", "finish saving"), ("reader_unavailable", "Update JR-Bar"),
                                         ("profile_not_found", "Reload profiles")])
def test_reader_failures_name_the_fix_without_secret_values(context, monkeypatch, category, fix):
    _, store = context
    def fail(**_):
        raise BrowserSessionReadError(category)
    monkeypatch.setattr("jrbar.browser_session_import.import_devin_session_from_profile", fail)
    with pytest.raises(CommandError) as caught:
        devin_session.import_session(args(), store)
    assert caught.value.code == "browser_import_failed"
    assert fix in str(caught.value)
    assert TOKEN not in str(caught.value)
    assert store.values == {}


def test_corrupt_database_is_reported_instead_of_a_silent_missing_session(context):
    home, store = context
    profile(home, "zen/Profiles", corrupt=True)
    with pytest.raises(CommandError) as caught:
        devin_session.import_session(args(), store)
    assert "database" in str(caught.value)
    assert store.values == {}


def test_keychain_failure_is_not_reported_as_a_successful_reconnect(context, monkeypatch):
    from jrbar.provider_browser_access import BrowserImportError
    from jrbar.provider_reconnect import reconnect_provider

    _, store = context
    def fail(_provider):
        raise BrowserImportError("Check the login keychain, then Import again.")
    result = reconnect_provider("devin", credential_store=store, session_importer=fail)
    assert not result.changed
    assert "keychain" in result.message


def test_unexpected_reader_failure_never_echoes_values(context, monkeypatch):
    _, store = context
    def fail(**_):
        raise RuntimeError(TOKEN)
    monkeypatch.setattr("jrbar.browser_session_import.import_devin_session_from_profile", fail)
    with pytest.raises(CommandError) as caught:
        devin_session.import_session(args(), store)
    assert TOKEN not in str(caught.value) and "profile" in str(caught.value)


def test_selected_profile_replaces_only_the_selected_account_grant(context):
    home, store = context
    profile(home, "zen/Profiles")
    loaded = load_provider_usage_settings()
    named = replace(loaded.settings.preference("devin"), source_instance_id="work", label="Test account")
    save_provider_usage_settings(loaded.settings.with_instance(named), loaded=loaded)
    grants = load_browser_consents()
    prior = grants.store
    for instance in ("default", "work"):
        prior = prior.grant(provider_id="devin", browser="chrome", profile="Default",
                            domains=("app.devin.ai",), fields=("auth1_session", "organization"),
                            background_repair=False, granted_at=10, source_instance_id=instance)
    save_browser_consents(prior, loaded=grants)
    store.values[("devin", "default", "token")] = "synthetic-existing-session"
    result = devin_session.import_session(args(instance="work"), store)
    assert result["instance"] == "work"
    assert store.values[("devin", "work", "token")] == TOKEN
    assert store.values[("devin", "default", "token")] == "synthetic-existing-session"
    selected = load_browser_consents().store.consents
    assert {(row.source_instance_id, row.browser, row.profile) for row in selected} == {
        ("default", "chrome", "Default"), ("work", "zen", "synthetic.default"),
    }
