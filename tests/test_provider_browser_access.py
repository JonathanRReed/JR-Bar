"""The staged browser-access flow: three honest clicks, never a dead one."""

from __future__ import annotations

from types import SimpleNamespace

import pytest

from jrbar import provider_browser_access
from jrbar.browser_session_import import BrowserSession
from jrbar.provider_browser_access import (
    handle_provider_usage_action,
    plausible_token,
)


class FakeStore:
    def __init__(self):
        self.saved = {}

    def set(self, provider_id, account, secret):
        self.saved[(provider_id, account)] = secret


def test_failed_keychain_write_does_not_claim_browser_sign_in(monkeypatch) -> None:
    class FailingStore:
        def set(self, *_args):
            raise OSError("synthetic Keychain failure")

    class Settings:
        def with_option(self, *_args, **_kwargs):
            return self

    saves: list[object] = []
    monkeypatch.setattr(
        provider_browser_access,
        "_load_consented_devin_session",
        lambda **_kwargs: BrowserSession("auth1_fixture_value_long", "org_fixture", None, "Zen Default"),
    )
    monkeypatch.setattr("jrbar.provider_credential_store.ProviderCredentialStore", FailingStore)
    monkeypatch.setattr(
        provider_browser_access,
        "load_provider_usage_settings",
        lambda: SimpleNamespace(settings=Settings()),
    )
    monkeypatch.setattr(provider_browser_access, "save_provider_usage_settings", lambda *_args, **_kwargs: saves.append(True))

    with pytest.raises(provider_browser_access.BrowserImportError) as caught:
        provider_browser_access._import_browser_session("devin")
    message = str(caught.value)

    assert message is not None and "Keychain" in message and "Signed in" not in message
    assert saves == []


def test_import_with_token_on_clipboard_stores_it__and_2_more() -> None:
    # --- scenario: import_with_token_on_clipboard_stores_it
    store = FakeStore()
    message = handle_provider_usage_action(
        "devin",
        "Import Devin browser session",
        credential_store=store,
        clipboard_reader=lambda: "  devin_api_key_abcdef1234567890  ",
        session_importer=lambda _provider: None,
        url_opener=lambda _url: None,
    )
    assert store.saved[("devin", "token")] == "devin_api_key_abcdef1234567890"
    assert "imported" in message

    # --- scenario: import_without_token_opens_the_page_and_explains
    opened = []
    store = FakeStore()
    message = handle_provider_usage_action(
        "devin",
        "Import Devin browser session",
        credential_store=store,
        clipboard_reader=lambda: "some prose that is not a token",
        url_opener=opened.append,
        session_importer=lambda provider: None,
    )
    assert store.saved == {}
    assert opened and opened[0].startswith("https://app.devin.ai")
    assert "clipboard" in message and "click" in message
    # The page opens in the DEFAULT browser, which may not hold the Devin
    # session (reported live: opened in Zen, signed in only in Chrome).
    # The message must name the literal address so it can be pasted into
    # the browser that does.
    assert "app.devin.ai/settings/api-keys" in message
    assert "browser you normally use" in message

    # --- scenario: unrelated_actions_fall_through
    assert (
        handle_provider_usage_action(
            "grok", "Retry", credential_store=FakeStore(),
            clipboard_reader=lambda: "", url_opener=lambda _u: None,
        )
        is None
    )



def test_plausible_token_rejects_prose_and_fragments__and_2_more() -> None:
    # --- scenario: plausible_token_rejects_prose_and_fragments
    assert plausible_token("sk-abc123def456ghi789")
    assert not plausible_token("short")
    assert not plausible_token("two words here padding padding")
    assert not plausible_token("line\nbreak" + "x" * 30)

    # --- scenario: grok_reconnect_names_the_real_fix
    message = handle_provider_usage_action(
        "grok", "Run grok login", credential_store=FakeStore(),
        clipboard_reader=lambda: "", url_opener=lambda _u: None,
    )
    assert "grok login" in message

    # --- scenario: reconnect_preserves_the_token_until_a_replacement_is_found
    """A failed re-import keeps the existing credential and explains the next step."""
    opened = []

    class DeletingStore(FakeStore):
        def __init__(self):
            super().__init__()
            self.deleted = []

        def delete(self, provider_id, account):
            self.deleted.append((provider_id, account))

    store = DeletingStore()
    message = handle_provider_usage_action(
        "devin", "Reconnect Devin", credential_store=store,
        clipboard_reader=lambda: "", url_opener=opened.append,
        session_importer=lambda provider: None,
    )
    assert store.deleted == []
    assert opened and "devin" in opened[0]
    assert "not replaced" in message and "Import Devin" in message



def test_import_takes_the_browser_session_and_never_mentions_a_key__and_2_more() -> None:
    # --- scenario: import_takes_the_browser_session_and_never_mentions_a_key
    """The reported defect: "Why do I need an API key? The
    implementation inside of CodexBar doesn't require an API key." When
    the browser holds a session, no key, no page and no clipboard are
    involved."""
    opened: list[str] = []
    store = FakeStore()
    message = handle_provider_usage_action(
        "devin",
        "Import Devin browser session",
        credential_store=store,
        clipboard_reader=lambda: "should never be read",
        url_opener=opened.append,
        session_importer=lambda provider: "Signed in as your Zen session — no API key needed.",
    )
    assert opened == []
    assert "no API key needed" in message
    assert "clipboard" not in message.lower()
    assert store.saved == {}

    # --- scenario: import_falls_back_to_the_manual_route_when_no_session_exists
    opened: list[str] = []
    message = handle_provider_usage_action(
        "devin",
        "Import Devin browser session",
        credential_store=FakeStore(),
        clipboard_reader=lambda: "prose, not a token",
        url_opener=opened.append,
        session_importer=lambda provider: None,
    )
    assert opened and opened[0].startswith("https://app.devin.ai")
    assert "clipboard" in message

    # --- scenario: reconnect_reimports_a_rotated_session_before_asking_for_anything
    """Devin reissues its web token routinely, so the common cause of a
    rejected session is rotation, not a wrong credential."""
    opened: list[str] = []
    store = FakeStore()
    message = handle_provider_usage_action(
        "devin",
        "Reconnect Devin",
        credential_store=store,
        clipboard_reader=lambda: "",
        url_opener=opened.append,
        session_importer=lambda provider: "Signed in as your Zen session — no API key needed.",
    )
    assert opened == []
    assert "Zen" in message


@pytest.mark.parametrize("label", ["Run grok login", "Reconnect Grok"])
def test_grok_action_preserves_the_selected_profile(monkeypatch, label):
    calls = []

    def repair(store, **kwargs):
        calls.append((store, kwargs))
        return SimpleNamespace(message="Synthetic named profile repair")

    monkeypatch.setattr("jrbar.provider_reconnect.repair_grok_credential", repair)
    store = FakeStore()
    message = handle_provider_usage_action(
        "grok", label, credential_store=store, source_instance_id="second",
        reason_code="authentication_required",
        clipboard_reader=lambda: pytest.fail("unexpected clipboard access"),
        url_opener=lambda _url: pytest.fail("unexpected browser launch"),
    )
    assert message == "Synthetic named profile repair"
    assert len(calls) == 1 and calls[0][0] is store
    assert calls[0][1].get("source_instance_id") == "second"
    assert calls[0][1]["server_rejected"] is True


def test_a_grok_action_label_cannot_repair_another_provider(monkeypatch):
    monkeypatch.setattr("jrbar.provider_reconnect.repair_grok_credential",
                        lambda *_a, **_k: pytest.fail("unrelated Grok repair"))
    assert handle_provider_usage_action("claude", "Reconnect Grok", credential_store=FakeStore()) is None


def test_failed_named_grok_repair_does_not_direct_a_default_cli_login(monkeypatch):
    def repair(*_a, **_k):
        raise OSError("synthetic credential failure")

    monkeypatch.setattr("jrbar.provider_reconnect.repair_grok_credential", repair)
    message = handle_provider_usage_action(
        "grok", "Reconnect Grok", credential_store=FakeStore(), source_instance_id="second",
    )
    assert "profile" in message
    assert "grok login" not in message
