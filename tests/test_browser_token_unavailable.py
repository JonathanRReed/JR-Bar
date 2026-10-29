"""Incomplete sign-ins use synthetic storage and never spend refresh tokens."""

import json
import sqlite3
from pathlib import Path
from types import SimpleNamespace

import pytest

from jrbar import devin_session, provider_browser_import
from jrbar.browser_session_import import FIREFOX_FAMILY_PROFILE_ROOTS
from jrbar.core_server import CommandError
from jrbar.provider_usage_collectors import collect_cursor
from jrbar.provider_usage_settings import default_provider_usage_settings


@pytest.mark.parametrize("browser,relative", [(name.lower(), root) for name, root in FIREFOX_FAMILY_PROFILE_ROOTS]
                         + [("chrome", "Google/Chrome"), ("brave", "BraveSoftware/Brave-Browser"),
                            ("edge", "Microsoft Edge"), ("chromium", "Chromium")])
@pytest.mark.parametrize("shape", ["refresh-only", "renamed-key"])
def test_devin_import_names_incomplete_signin(tmp_path, monkeypatch, browser, relative, shape):
    monkeypatch.setattr(Path, "home", lambda: tmp_path)
    monkeypatch.setenv("XDG_CONFIG_HOME", str(tmp_path / ".config"))
    name = "Default" if browser in {"chrome", "brave", "edge", "chromium"} else "synthetic.default"
    root = tmp_path / "Library/Application Support" / relative / name
    root.mkdir(parents=True)
    entries = {"last-internal-org-for-external-org-v1-example": "org_synthetic"}
    if shape == "refresh-only":
        entries["auth1_session"] = json.dumps({"refresh_token": "synthetic-refresh"})
    else:
        entries["renamed_session"] = json.dumps({"token": "auth1_synthetic_renamed_value"})
    if name == "Default":
        monkeypatch.setattr(provider_browser_import, "read_chromium_local_storage", lambda *_a, **_k: entries)
    else:
        storage = root / "storage/default/https+++app.devin.ai/ls"
        storage.mkdir(parents=True)
        with sqlite3.connect(storage / "data.sqlite") as connection:
            connection.execute("CREATE TABLE data (key TEXT, value BLOB, compression_type INTEGER)")
            connection.executemany("INSERT INTO data VALUES (?, ?, 0)", entries.items())
    class Store:
        def set(self, *_):
            pytest.fail("incomplete sign-in saved")
    with pytest.raises(CommandError) as caught:
        devin_session.import_session({"browser": browser, "profile": name, "confirm": True}, Store())
    assert caught.value.code == "browser_token_unavailable"
    assert "API key" in str(caught.value)
    assert "synthetic-refresh" not in str(caught.value)
    assert "auth1_synthetic" not in str(caught.value)


@pytest.mark.parametrize("shape", ["refresh-only", "renamed-key", "renamed-field"])
@pytest.mark.parametrize("saved", [False, True])
def test_cursor_incomplete_local_signin_offers_manual_import(tmp_path, shape, saved):
    database = tmp_path / "Library/Application Support/Cursor/User/globalStorage/state.vscdb"
    database.parent.mkdir(parents=True)
    key = "cursorAuth/refreshToken" if shape == "refresh-only" else "cursorAuth/accessTokenV2"
    value = "synthetic-token"
    if shape == "renamed-field":
        key, value = "cursorAuth/accessToken", json.dumps({"renamedAccessToken": value})
    with sqlite3.connect(database) as connection:
        connection.execute("CREATE TABLE ItemTable (key TEXT, value TEXT)")
        connection.execute("INSERT INTO ItemTable VALUES (?, ?)", (key, value))
    class Store:
        def get(self, *_):
            return SimpleNamespace(available=saved, secret="synthetic-pasted-token" if saved else None)
    calls = []
    def http(_method, url, **kwargs):
        calls.append(url)
        assert kwargs["headers"]["Authorization"] == "Bearer synthetic-pasted-token"
        return {"email": "person@example.invalid"} if url.endswith("/auth/me") else {"planUsage": {"usedPercent": 30}}
    result = collect_cursor(default_provider_usage_settings().preference("cursor"), home=tmp_path,
                            observed_at=1000, credentials=Store(), http_json=http)
    if saved:
        assert calls and result.reason_code != "browser_token_unavailable"
    else:
        assert calls == []
        assert result.reason_code == "browser_token_unavailable"
        assert result.action_label == "Import Cursor browser session"


@pytest.mark.parametrize("shape", ["refresh-only", "renamed-key"])
def test_chromium_devin_command_line_import_names_incomplete_signin(tmp_path, monkeypatch, shape):
    from jrbar.provider_browser_consent import BrowserConsentStore

    root = tmp_path / "Library/Application Support/Google/Chrome/Default"
    root.mkdir(parents=True)
    entries = {"last-internal-org-for-external-org-v1-example": "org_synthetic"}
    entries["auth1_session" if shape == "refresh-only" else "renamed-session"] = json.dumps(
        {"refresh_token": "synthetic-refresh"})
    monkeypatch.setattr(provider_browser_import, "read_chromium_local_storage", lambda *_a, **_k: entries)
    consent = BrowserConsentStore.empty().grant(provider_id="devin", browser="chrome", profile="Default",
        domains=("app.devin.ai",), fields=("auth1_session", "organization"), background_repair=False, granted_at=1000)
    result = provider_browser_import.import_devin_browser_session(browser="chrome", profile="Default",
        profile_root=root, home=tmp_path, consents=consent, credentials=object())
    assert result.reason == "browser_token_unavailable"
    assert result.state is provider_browser_import.BrowserImportState.UNAVAILABLE


def test_devin_background_read_preserves_incomplete_reason_and_key_bypasses_it(monkeypatch):
    from jrbar.provider_browser_access import BrowserImportError
    from jrbar.provider_usage_collectors import collect_devin

    def incomplete(**_):
        raise BrowserImportError("Sign-in part unavailable", reason="browser_token_unavailable")
    monkeypatch.setattr("jrbar.provider_browser_access._load_consented_devin_session", incomplete)
    settings = default_provider_usage_settings().with_browser_sources("devin", True)
    pref = settings.preference("devin").with_option("organization_id", "org_synthetic")
    class Store:
        def __init__(self, saved):
            self.saved = saved
        def get(self, *_):
            return SimpleNamespace(available=self.saved, secret="synthetic-key" if self.saved else None)
    result = collect_devin(pref, observed_at=1000, credentials=Store(False),
                           http_json=lambda *_a, **_k: pytest.fail("incomplete sign-in request"))
    assert result.reason_code == "browser_token_unavailable"
    calls = []
    def http(*_args, **kwargs):
        calls.append(kwargs)
        return {"daily_usage": {"used": 1, "limit": 10}}
    collect_devin(pref, observed_at=1000, credentials=Store(True), http_json=http)
    assert len(calls) == 1
