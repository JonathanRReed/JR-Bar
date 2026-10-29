"""Explicit, profile-scoped Devin imports. No request leaves the Mac."""

from __future__ import annotations

import threading
import time

from .core_server import CommandError
from .provider_browser_access import BrowserImportError, _import_browser_session
from .provider_browser_consent import BrowserConsentStore, load_browser_consents, save_browser_consents
from .provider_instances import ProviderInstanceKey
from .provider_usage_settings import load_provider_usage_settings

_IMPORT_LOCK = threading.Lock()


def profiles(args):
    from .factory_session import profiles as browser_profiles

    if args:
        raise CommandError("invalid_args", "devin_session_profiles takes no arguments")
    return browser_profiles({})


def import_session(args, credentials):
    from .factory_session import _ROOTS, _valid_profile

    if (
        set(args) - {"browser", "profile", "instance", "confirm", "background_repair"}
        or args.get("confirm") is not True
        or type(args.get("background_repair", False)) is not bool
        or not isinstance(args.get("browser"), str)
        or args["browser"] not in _ROOTS
        or not _valid_profile(args.get("profile"))
    ):
        raise CommandError("invalid_args", "Choose a browser profile and confirm access to its Devin sign-in")
    try:
        key = ProviderInstanceKey("devin", args.get("instance", "default"))
        settings = load_provider_usage_settings().settings
        if not any(row.provider_id == "devin" and row.source_instance_id == key.value[1]
                   for row in settings.providers):
            raise ValueError("unknown instance")
    except (TypeError, ValueError):
        raise CommandError("unknown_instance", "This Devin account is not configured. Reload providers.") from None
    with _IMPORT_LOCK:
        try:
            loaded = load_browser_consents()
            # One selected profile per instance. Other providers and accounts retain their grants.
            remaining = tuple(row for row in loaded.store.consents
                              if (row.provider_id, row.source_instance_id) != key.value)
            updated = BrowserConsentStore(remaining).grant(
                provider_id="devin", browser=args["browser"], profile=args["profile"],
                domains=("app.devin.ai",), fields=("auth1_session", "organization"),
                background_repair=args.get("background_repair", False), granted_at=time.time(),
                source_instance_id=key.value[1],
            )
            save_browser_consents(updated, loaded=loaded)
        except Exception:
            raise CommandError("unavailable", "Devin browser permission could not be saved. Reload Settings > Providers, then Import again.") from None
        try:
            message = _import_browser_session("devin", key.value[1], credential_store=credentials)
        except BrowserImportError as error:
            code = "browser_token_unavailable" if error.reason == "browser_token_unavailable" else "browser_import_failed"
            raise CommandError(code, str(error)) from None
        except Exception:
            raise CommandError("browser_import_failed", "Devin browser import failed. Choose the profile again, then Import again.") from None
    return {"provider": "devin", "instance": key.value[1], "message": message}
