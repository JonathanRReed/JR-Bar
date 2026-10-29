"""Explicit provider imports and reconnects with visible, secret-free results.

Browser reads require an exact persisted provider, instance and profile grant.
"""

from __future__ import annotations

import time

from .product_identity import PRODUCT_DISPLAY_NAME
from .provider_usage_settings import (
    load_provider_usage_settings,
    save_provider_usage_settings,
)

#: Where each provider keeps the token/session the collector needs.
PROVIDER_TOKEN_PAGES: dict[str, str] = {
    "devin": "https://app.devin.ai/settings/api-keys",
    "cursor": "https://cursor.com/settings",
}

MIN_TOKEN_LENGTH = 16
MAX_TOKEN_LENGTH = 4096


def _clipboard_text() -> str:
    import os

    if os.environ.get("JRBAR_TESTING") == "1" or "PYTEST_CURRENT_TEST" in os.environ:
        return ""
    try:
        import subprocess

        result = subprocess.run(["/usr/bin/pbpaste"], capture_output=True, text=True, timeout=2, check=False)
        return result.stdout if result.returncode == 0 else ""
    except Exception:
        return ""


def plausible_token(text: str) -> bool:
    """A pasted credential, not prose: bounded, single-line, no spaces."""
    cleaned = text.strip()
    return (
        MIN_TOKEN_LENGTH <= len(cleaned) <= MAX_TOKEN_LENGTH
        and "\n" not in cleaned
        and " " not in cleaned
    )


def _open_url(url: str) -> None:
    try:
        import subprocess

        subprocess.Popen(["/usr/bin/open", url], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    except Exception:
        pass


def _consented_devin_session(
    *,
    home,
    consents,
    session_reader,
    source_instance_id: str = "default",
    require_background_repair: bool = False,
):
    """Read only when one exact persisted Devin grant selects a profile."""
    matches = []
    for consent in consents.consents:
        if consent.provider_id != "devin":
            continue
        if consent.source_instance_id != source_instance_id:
            continue
        if require_background_repair and not consent.background_repair:
            continue
        if not (
            consents.allows(
                provider_id="devin",
                browser=consent.browser,
                profile=consent.profile,
                domain="app.devin.ai",
                field="auth1_session",
                source_instance_id=source_instance_id,
            )
            and consents.allows(
                provider_id="devin",
                browser=consent.browser,
                profile=consent.profile,
                domain="app.devin.ai",
                field="organization",
                source_instance_id=source_instance_id,
            )
        ):
            continue
        matches.append(consent)
    if len(matches) != 1:
        return None
    selected = matches[0]
    return session_reader(
        home=home,
        browser=selected.browser,
        profile=selected.profile,
    )


class BrowserImportError(Exception):
    """A fixed, safe explanation for a failed explicit import."""


def _load_consented_devin_session(
    *,
    source_instance_id: str = "default",
    require_background_repair: bool = False,
    strict: bool = False,
):
    """Read one exact grant. Explicit clicks report why a read was refused."""
    from pathlib import Path

    from .browser_session_import import BrowserSessionReadError, import_devin_session_from_profile
    from .provider_browser_consent import load_browser_consents

    try:
        loaded = load_browser_consents()
        if loaded.read_only:
            raise BrowserImportError("Browser permissions could not be read. Reopen Settings > Providers and choose the Devin browser profile again.")

        def read(**kwargs):
            browser = str(kwargs["browser"]).title()
            try:
                session = import_devin_session_from_profile(**kwargs, strict=strict)
            except BrowserSessionReadError as error:
                fixes = {
                    "profile_not_found": "The selected browser profile was not found. Reload profiles in Settings > Providers and choose it again.",
                    "reader_unavailable": "This build cannot read Chromium storage. Update JR-Bar or choose Firefox or Zen, then Import again.",
                    "storage_changed": "Browser storage changed during import. Wait for the browser to finish saving, then Import again.",
                    "storage_invalid": "The browser session database could not be read. Open app.devin.ai in the selected profile, then Import again.",
                }
                raise BrowserImportError(fixes.get(str(error), "Browser storage could not be opened. Check JR-Bar's browser access, then Import again.")) from None
            if session is None and strict:
                raise BrowserImportError(f"Sign in at app.devin.ai in {browser} using the selected profile, then Import again.")
            return session

        session = _consented_devin_session(
            home=Path.home(), consents=loaded.store, session_reader=read,
            source_instance_id=source_instance_id,
            require_background_repair=require_background_repair,
        )
        if session is None and strict:
            raise BrowserImportError("Choose one Devin browser profile in Settings > Providers and allow access, then Import again.")
        return session
    except BrowserImportError:
        if strict:
            raise
        return None
    except Exception:
        if strict:
            raise BrowserImportError("Devin browser access could not be checked. Reopen Settings > Providers and choose the profile again.") from None
        return None


def _import_browser_session(
    provider_id: str,
    source_instance_id: str = "default",
    *,
    credential_store=None,
) -> str | None:
    """Import an exact consented profile, or report a safe, actionable failure."""
    if provider_id != "devin":
        return None
    from .provider_credential_store import ProviderCredentialStore

    session = _load_consented_devin_session(source_instance_id=source_instance_id, strict=True)
    if session is None:
        raise BrowserImportError("No Devin browser session was found. Sign in at app.devin.ai in the selected profile, then Import again.")
    store = credential_store if credential_store is not None else ProviderCredentialStore()
    try:
        if source_instance_id == "default":
            store.set(provider_id, "token", session.token)
        else:
            from .provider_instances import ProviderInstanceKey

            store.set_for_instance(ProviderInstanceKey(provider_id, source_instance_id), "token", session.token)
    except Exception:
        raise BrowserImportError("JR-Bar couldn't save this browser session to Keychain. Check the login keychain and try Import again.") from None
    try:
        loaded = load_provider_usage_settings()
        settings = loaded.settings.with_browser_sources(provider_id, True, source_instance_id=source_instance_id)
        for option, value in (("organization", session.organization), ("organization_id", session.internal_organization_id)):
            if value:
                settings = settings.with_option(provider_id, option, value, source_instance_id=source_instance_id)
        save_provider_usage_settings(settings, loaded=loaded)
        from .provider_browser_consent import load_browser_consents
        from .provider_management import record_browser_import

        grants = [row for row in load_browser_consents().store.consents
                  if row.provider_id == provider_id and row.source_instance_id == source_instance_id]
        if len(grants) == 1:
            row = grants[0]
            record_browser_import(provider_id, source_instance_id, row.browser, row.profile, session.token)
    except Exception:
        raise BrowserImportError("Devin's session was saved, but its organization settings could not be saved. Reload Settings > Providers, then Import again.") from None
    return "Devin browser session imported. Refresh usage to verify the sign-in."


def _run_session_import(provider_id, source_instance_id, credential_store, session_importer):
    if session_importer is None:
        return _import_browser_session(provider_id, source_instance_id, credential_store=credential_store)
    if source_instance_id == "default":
        return session_importer(provider_id)
    return session_importer(provider_id, source_instance_id)


def _signed_out_hint(title: str, url: str) -> str:
    """The token page opens in the DEFAULT browser, which is not
    necessarily where the user is signed in to the provider (reported
    live: page opened in Zen, Devin lives in Chrome, flow dead-ended at
    a login wall). Name the literal address so it can be pasted into
    whichever browser actually holds the session."""
    bare = url.removeprefix("https://").removeprefix("http://")
    return (
        f" If that page isn't signed in, open {bare} in the browser "
        f"you normally use for {title}."
    )


def handle_provider_usage_action(
    provider_id: str,
    action_label: str,
    *,
    credential_store,
    clipboard_reader=_clipboard_text,
    url_opener=_open_url,
    session_importer=None,
    reason_code: str | None = None,
    source_instance_id: str = "default",
) -> str | None:
    """Perform one staged action. Returns the user-facing message, or
    None when this action is not part of the browser-access flow (the
    caller falls through to its previous behavior)."""
    label = str(action_label or "")
    title = provider_id.title()
    if label.startswith("Enable ") and label.endswith("browser access"):
        try:
            loaded = load_provider_usage_settings()
            updated = loaded.settings.with_browser_sources(
                provider_id,
                True,
                source_instance_id=source_instance_id,
            )
            save_provider_usage_settings(updated, loaded=loaded)
        except Exception:
            return (
                f"{title} does not support browser sources in this build."
            )
        return (
            f"{title} browser access enabled. Browser data is still off-limits "
            f"until an exact browser/profile grant exists. Then click "
            f"'Import {title} browser session' on the same card."
        )
    if label.startswith("Import ") and "browser session" in label:
        try:
            imported = _run_session_import(provider_id, source_instance_id, credential_store, session_importer)
        except BrowserImportError as error:
            return str(error)
        except Exception:
            return "Browser import failed. Choose the profile again in Settings > Providers, then Import again."
        if imported is not None:
            return imported
        clipboard = clipboard_reader()
        if plausible_token(clipboard):
            try:
                if source_instance_id == "default":
                    credential_store.set(provider_id, "token", clipboard.strip())
                else:
                    from .provider_instances import ProviderInstanceKey

                    credential_store.set_for_instance(
                        ProviderInstanceKey(provider_id, source_instance_id),
                        "token",
                        clipboard.strip(),
                    )
            except Exception:
                return f"Could not save the {title} session. Check the login keychain, then Import again."
            return f"{title} session imported — refreshing usage now."
        url = PROVIDER_TOKEN_PAGES.get(provider_id)
        if url is not None:
            url_opener(url)
        return (
            f"Grant one exact browser/profile with `jrbar providers "
            f"browser-consent grant {provider_id} --browser <browser> "
            "--profile <profile>` to use browser import. Or copy your "
            f"{title} API key"
            + (" (page opened)" if url is not None else "")
            + f", then click 'Import {title} browser session' again — "
            f"{PRODUCT_DISPLAY_NAME} reads it from the clipboard only when you click."
            + (_signed_out_hint(title, url) if url is not None else "")
        )
    if label == f"Reconnect {title}" and provider_id in PROVIDER_TOKEN_PAGES:
        try:
            reimported = _run_session_import(provider_id, source_instance_id, credential_store, session_importer)
        except BrowserImportError as error:
            return str(error)
        except Exception:
            return "Browser import failed. Choose the profile again in Settings > Providers, then Import again."
        if reimported is not None:
            return reimported
        url = PROVIDER_TOKEN_PAGES.get(provider_id)
        if url is not None:
            url_opener(url)
        return (
            f"The stored {title} session was rejected and was "
            f"not replaced. Copy a fresh API key (page opened), then click "
            f"'Import {title} browser session'."
            + (_signed_out_hint(title, url) if url is not None else "")
        )
    if provider_id == "grok" and label in ("Run grok login", "Reconnect Grok"):
        # Grok's sign-in belongs to the grok CLI, but "run grok login"
        # was being said to users whose CLI was ALREADY signed in --
        # the collector was wedged on a stale stored token instead.
        # Actually probe the auth file and repair the wedge, then say
        # what was found.
        import time as _time
        from pathlib import Path as _Path

        from .provider_reconnect import repair_grok_credential

        try:
            result = repair_grok_credential(
                credential_store,
                home=_Path.home(),
                now=_time.time(),
                # The collector's last verdict rides along: a 401 means
                # the file token the repair is about to bless is the
                # very token the server just rejected.
                server_rejected=reason_code == "authentication_required",
                source_instance_id=source_instance_id,
            )
            return result.message
        except Exception:
            if source_instance_id != "default":
                return "Couldn't read this Grok profile's sign-in. Check its credential in Settings, then refresh."
            return (
                f"Run `grok login` in a terminal — {PRODUCT_DISPLAY_NAME} reads the "
                "CLI's sign-in automatically on the next refresh."
            )
    if provider_id == "codex" and (
        label.startswith("Last read")
        or "run Codex" in label
        or label.startswith("Use Codex once")
        or label == "Reconnect Codex"
    ):
        # Codex usage comes from the CLI's own transcripts; the honest
        # action is "look again and say what the evidence shows" --
        # including the case where the user DID just run Codex but the
        # run never completed a turn, so nothing was written.
        import time as _time
        from pathlib import Path as _Path

        from .provider_reconnect import codex_activity_report

        try:
            return codex_activity_report(_Path.home(), _time.time())
        except Exception:
            return "Rescanning Codex CLI activity now."
    if provider_id == "gemini":
        # Gemini's OAuth credentials live in ~/.gemini/oauth_creds.json
        # and belong to the gemini CLI: JR-Bar refreshes and reads them
        # but cannot sign the user in, onboard the account, or create a
        # Code Assist project. Every action here points at the owner.
        if "sign in" in label.lower():
            return (
                "Gemini's sign-in belongs to the gemini CLI. Run `gemini` "
                "once in a terminal and complete its sign-in — JR-Bar reads "
                "~/.gemini/oauth_creds.json on the next refresh."
            )
        if label == "Set a Code Assist project id":
            return (
                "This account has no Code Assist project. Run `gemini` once "
                "so the CLI can provision one, or set an existing GCP "
                "project id with `jrbar providers configure gemini "
                "--option project_id=<id>`."
            )
        if label == "Check the Code Assist license":
            return (
                "Google denied the quota read: the account has no Code "
                "Assist license for that project. This is a Gemini-side "
                "entitlement — enable it in the Google Admin console or "
                "AI Studio; JR-Bar only reads the result."
            )
        if label == "Check Gemini Code Assist eligibility":
            return (
                "Google reports this account/client ineligible for the "
                "Code Assist free tier — the free tier now routes through "
                "Antigravity. Use the Antigravity provider or a paid "
                "Code Assist project."
            )
        return None
    if provider_id == "antigravity" and (
        "Antigravity" in label or "agy" in label
    ):
        if label == "Run agy in a terminal":
            return "Run `agy` in a terminal. JR-Bar reads its quota service on the next refresh."
        # Antigravity's quota comes from its own loopback service; the
        # only "reconnect" is making sure that service is up. This
        # label used to match nothing -- a dead button (audit).
        return (
            "Antigravity's usage comes from its local service. Open the "
            "Antigravity app (or run `agy` in a terminal) so its "
            f"endpoint is running — {PRODUCT_DISPLAY_NAME} reads it on the next "
            "refresh."
        )
    if provider_id == "openai-api" and (
        "Admin key" in label or label.lower().startswith("reconnect openai")
    ):
        # Clipboard flow, same contract as the Import stage: the key is
        # read only when clicked. This label also used to match nothing.
        clipboard = clipboard_reader()
        if plausible_token(clipboard):
            try:
                credential_store.set("openai-api", "admin-key", clipboard.strip())
            except Exception as exc:
                return f"Could not store the OpenAI Admin key: {exc}"
            return "OpenAI Admin key stored — refreshing usage now."
        return (
            "Copy an OpenAI ADMIN key (platform.openai.com → Settings → "
            f"Admin keys), then click this again — {PRODUCT_DISPLAY_NAME} reads it "
            "from the clipboard only when you click."
        )
    if label.startswith("Choose ") and "organization" in label:
        clipboard = clipboard_reader().strip()
        if clipboard and "\n" not in clipboard and len(clipboard) <= 120:
            try:
                loaded = load_provider_usage_settings()
                updated = loaded.settings.with_option(
                    provider_id,
                    "organization",
                    clipboard,
                    source_instance_id=source_instance_id,
                )
                save_provider_usage_settings(updated, loaded=loaded)
            except Exception:
                return "Could not save the organization. Reload Settings > Providers and try again."
            return f"{title} organization set to {clipboard!r} — refreshing."
        return (
            f"Copy your {title} organization name, then click "
            f"'Choose {title} organization' again."
        )
    return None


def perform_provider_usage_action(
    controller,
    provider_id: str,
    source_instance_id: str = "default",
) -> str | None:
    """Resolve the provider's CURRENT action label, run the staged flow,
    surface the message, force a refresh. Returns the surfaced message --
    None when the label is not part of this flow (caller falls back)."""
    state = getattr(controller, "provider_usage_state", None)
    snapshot = next(
        (
            item
            for item in getattr(state, "snapshots", ())
            if item.identity == (provider_id, source_instance_id)
        ),
        None,
    )
    label = getattr(snapshot, "action_label", None)
    if not label:
        return None
    from .provider_credential_store import ProviderCredentialStore

    message = handle_provider_usage_action(
        provider_id,
        label,
        credential_store=ProviderCredentialStore(),
        reason_code=getattr(snapshot, "reason_code", None),
        source_instance_id=source_instance_id,
    )
    if message is None:
        return None
    def after_click():
        # The message MUST land somewhere a person can find it. A controller
        # that has a feedback sink uses it (the daemon logs the provider
        # action); the plain settings message is only the fallback, which is
        # how "Reconnect Grok" once spent months answering into the void.
        feedback = getattr(controller, "_show_provider_usage_feedback", None)
        if callable(feedback):
            try:
                feedback(message)
            except Exception:
                pass
        else:
            try:
                controller.set_settings_message(message)
            except Exception:
                pass
        # Arm the outcome watcher before starting the asynchronous refresh so a
        # fast collector cannot publish before the click has an identity.
        try:
            controller._jrbar_reconnect_watch = (
                provider_id,
                source_instance_id,
                time.time(),
            )
        except Exception:
            pass
        try:
            scope = (
                (provider_id,)
                if source_instance_id == "default"
                else ((provider_id, source_instance_id),)
            )
            controller._request_provider_usage(force=True, providers=scope)
        except Exception:
            pass

    on_main = getattr(controller, "_core_on_main", None) or (lambda fn: fn())
    on_main(after_click)
    # The click's REAL outcome arrives with the refresh it just forced;
    # arm the one-shot reporter so the banner tells the truth about what
    # actually happened instead of only what was attempted.
    return message


__all__ = [
    "PROVIDER_TOKEN_PAGES",
    "handle_provider_usage_action",
    "plausible_token",
]
