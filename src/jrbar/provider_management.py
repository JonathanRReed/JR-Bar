"""Provider connection management shared by the CLI and the core socket.

Inspect/enable/consent/action live here so the native app exercises the
exact same stores, optimistic-concurrency saves, and consent allowlists
as ``jrbar providers`` -- never a second, divergent control path.
"""

from __future__ import annotations

import hashlib
import json
import time
from pathlib import Path
from typing import Any

from .provider_browser_consent import (
    default_browser_consent_path,
    load_browser_consents,
    save_browser_consents,
)
from .provider_usage_platform import provider_descriptor
from .provider_usage_settings import (
    ProviderUsageSettingsWriteRefusedError,
    default_provider_usage_settings_path,
    load_provider_usage_settings,
    save_provider_usage_settings,
)
from .provider_usage_store import load_provider_usage_state

#: Provider -> the exact browser/profile scope a consent binds. Mirrors the
#: CLI's allowlist: a consent never covers more domains or fields than this.
BROWSER_CONSENT_SCOPES: dict[str, dict[str, tuple[str, ...]]] = {
    "devin": {
        "domains": ("app.devin.ai",),
        "fields": ("auth1_session", "organization"),
    },
    "cursor": {
        "domains": ("cursor.com",),
        "fields": ("session",),
    },
}

#: Provider -> credential accounts a caller may inspect (never read back).
CREDENTIAL_ACCOUNTS: dict[str, tuple[str, ...]] = {
    "claude": ("oauth-token",),
    "devin": ("token",),
    "grok": ("token",),
    "openai-api": ("admin-key",),
    # The CLIProxyAPI hub's management key (cliproxy_hub). Not a provider:
    # it lets the hub read the accounts the proxy signs in to.
    "cliproxy": ("management",),
}


def supports_provider_instances(provider_id: str) -> bool:
    """Whether a second configured account can read a *different* account.

    Only true where a source is per-instance -- a stored credential
    (``CREDENTIAL_ACCOUNTS``) or a consented browser session
    (``BROWSER_CONSENT_SCOPES``). A provider whose sources are all this
    Mac's own CLI/app sign-in (Codex, Gemini, OpenCode, Antigravity)
    would report the same account twice, so the UI must not offer the
    "+" for it.
    """
    return provider_id in CREDENTIAL_ACCOUNTS or provider_id in BROWSER_CONSENT_SCOPES

_IMPORT_LEDGER_NAME = "browser-imports.json"
_IMPORT_ACCOUNT = "token"

#: Preference-option keys safe to publish to the app. Display identifiers
#: only -- ``csrf_token`` and anything a future provider adds stay inside
#: the settings store. ``endpoint`` is loopback-validated at write time.
_PUBLISHABLE_OPTION_KEYS = frozenset(
    {"organization", "organization_id", "project_id", "endpoint"}
)


class ProviderManagementError(ValueError):
    """A refused provider-management operation; ``code`` goes on the wire."""

    def __init__(self, code: str, message: str) -> None:
        super().__init__(message)
        self.code = code


def _import_ledger_path(home: Path | None = None) -> Path:
    return default_browser_consent_path(home).parent / _IMPORT_LEDGER_NAME


def _load_import_ledger(home: Path | None = None) -> dict[str, dict[str, Any]]:
    path = _import_ledger_path(home)
    try:
        document = json.loads(path.read_text(encoding="utf-8"))
    except (OSError, UnicodeError, ValueError):
        return {}
    rows = document.get("imports")
    if not isinstance(rows, list):
        return {}
    out: dict[str, dict[str, Any]] = {}
    for row in rows[:256]:
        if not isinstance(row, dict):
            continue
        provider_id = row.get("provider_id")
        instance = row.get("source_instance_id")
        digest = row.get("secret_sha256")
        if (
            isinstance(provider_id, str)
            and isinstance(instance, str)
            and isinstance(digest, str)
        ):
            out[f"{provider_id}:{instance}"] = row
    return out


def _save_import_ledger(
    ledger: dict[str, dict[str, Any]],
    home: Path | None = None,
) -> None:
    path = _import_ledger_path(home)
    from .private_io import atomic_private_write

    atomic_private_write(
        path,
        json.dumps(
            {"imports": [ledger[key] for key in sorted(ledger)]},
            ensure_ascii=False,
            sort_keys=True,
            separators=(",", ":"),
        ),
    )


def record_browser_import(
    provider_id: str,
    source_instance_id: str,
    browser: str,
    profile: str,
    secret: str,
    *,
    home: Path | None = None,
    imported_at: float | None = None,
) -> None:
    """Mark that a stored credential came from a consented browser import.

    Only the secret's digest is recorded, so a later revoke can tell
    JR-Bar-owned imported data from a token the user set themselves (T26).
    """
    ledger = _load_import_ledger(home)
    ledger[f"{provider_id}:{source_instance_id}"] = {
        "provider_id": provider_id,
        "source_instance_id": source_instance_id,
        "browser": browser,
        "profile": profile,
        "account": _IMPORT_ACCOUNT,
        "imported_at": float(time.time() if imported_at is None else imported_at),
        "secret_sha256": hashlib.sha256(secret.encode("utf-8")).hexdigest(),
    }
    _save_import_ledger(ledger, home)


def forget_browser_import(
    provider_id: str,
    source_instance_id: str = "default",
    *,
    home: Path | None = None,
) -> None:
    """Drop import provenance -- a manually stored credential is the user's
    own data again, so a later revoke must not delete it."""
    ledger = _load_import_ledger(home)
    if ledger.pop(f"{provider_id}:{source_instance_id}", None) is not None:
        _save_import_ledger(ledger, home)


def purge_imported_browser_data(
    provider_id: str,
    source_instance_id: str,
    credentials,
    *,
    home: Path | None = None,
) -> str:
    """Remove the imported credential iff it is still the imported one.

    Returns ``removed``/``retained``/``replaced``/``none`` so the reply can
    say exactly what happened to JR-Bar-owned data (T26).
    """
    ledger = _load_import_ledger(home)
    record = ledger.pop(f"{provider_id}:{source_instance_id}", None)
    if record is None:
        return "none"
    _save_import_ledger(ledger, home)
    try:
        if source_instance_id == "default":
            stored = credentials.get(provider_id, record.get("account") or _IMPORT_ACCOUNT)
        else:
            from .provider_instances import ProviderInstanceKey

            stored = credentials.get_for_instance(
                ProviderInstanceKey(provider_id, source_instance_id),
                record.get("account") or _IMPORT_ACCOUNT,
            )
    except Exception:
        return "retained"
    secret = getattr(stored, "secret", None)
    available = bool(getattr(stored, "available", False))
    if not available or not isinstance(secret, str):
        return "none"
    if hashlib.sha256(secret.encode("utf-8")).hexdigest() != record["secret_sha256"]:
        # The user replaced the imported value; nothing here is ours.
        return "replaced"
    try:
        if source_instance_id == "default":
            credentials.delete(provider_id, record.get("account") or _IMPORT_ACCOUNT)
        else:
            from .provider_instances import ProviderInstanceKey

            credentials.delete_for_instance(
                ProviderInstanceKey(provider_id, source_instance_id),
                record.get("account") or _IMPORT_ACCOUNT,
            )
    except Exception:
        return "retained"
    return "removed"


def _consent_row(consent) -> dict[str, Any]:
    return {
        "browser": consent.browser,
        "profile": consent.profile,
        "domains": list(consent.domains),
        "fields": list(consent.fields),
        "background_repair": consent.background_repair,
        "granted_at": consent.granted_at,
        "source_instance_id": consent.source_instance_id,
    }


def provider_rows(
    *,
    credentials,
    home: Path | None = None,
    settings_path: Path | None = None,
    consent_path: Path | None = None,
    state_path: Path | None = None,
    state=None,
    only: str | None = None,
    instance: str | None = None,
) -> list[dict[str, Any]]:
    """One inspection row per configured provider instance: identity,
    enabled flag, the live source state, its source ladder, granted
    consents, and which credential accounts exist. Secrets never appear.

    Rows come from the settings' preference entries, so a provider with
    two configured accounts produces two rows keyed by
    ``(provider_id, source_instance_id)`` -- the same identity the
    usage state and consents are scoped by."""
    from .provider_instances import ProviderInstanceKey

    loaded = load_provider_usage_settings(settings_path)
    consents = load_browser_consents(consent_path).store
    if state is None:
        try:
            state = load_provider_usage_state(state_path)
        except Exception:
            state = None
    snapshots = {
        item.identity: item for item in getattr(state, "snapshots", ())
    }
    ledger = _load_import_ledger(home)
    rows: list[dict[str, Any]] = []
    for preference in loaded.settings.providers:
        provider_id = preference.provider_id
        instance_id = preference.source_instance_id
        if only is not None and provider_id != only:
            continue
        if instance is not None and instance_id != instance:
            continue
        descriptor = provider_descriptor(provider_id)
        snapshot = snapshots.get((provider_id, instance_id))
        accounts = []
        for account in CREDENTIAL_ACCOUNTS.get(provider_id, ()):
            try:
                if instance_id == "default":
                    read = credentials.get(provider_id, account)
                else:
                    read = credentials.get_for_instance(
                        ProviderInstanceKey(provider_id, instance_id), account
                    )
                available = bool(getattr(read, "available", False))
            except Exception:
                available = False
            accounts.append({"account": account, "available": available})
        imported = ledger.get(f"{provider_id}:{instance_id}")
        rows.append(
            {
                "id": provider_id,
                "instance": instance_id,
                "label": preference.label,
                "enabled": preference.enabled,
                "menu_visible": preference.menu_visible,
                "browser_sources_enabled": preference.browser_sources,
                "supports_browser_sources": provider_id in BROWSER_CONSENT_SCOPES,
                "supports_local_tokens": descriptor.supports_local_tokens,
                "supports_quota": descriptor.supports_quota,
                "supports_instances": supports_provider_instances(provider_id),
                "source_order": list(descriptor.source_order),
                # Whitelist, not substring filter: an option named
                # ``api_password`` or ``session_cookie`` would sail
                # through the old key/token/secret check. Only known
                # display-safe fields are published.
                "options": {
                    key: value
                    for key, value in preference.options
                    if key in _PUBLISHABLE_OPTION_KEYS
                },
                "consents": [
                    _consent_row(consent)
                    for consent in consents.consents
                    if consent.provider_id == provider_id
                    and consent.source_instance_id == instance_id
                ],
                "credentials": accounts,
                "imported_credential": imported is not None,
                "state": getattr(snapshot.state, "value", None) if snapshot else None,
                "reason": getattr(snapshot, "reason_code", None) if snapshot else None,
                "action": getattr(snapshot, "action_label", None) if snapshot else None,
                "account_label": getattr(snapshot, "account_label", None) if snapshot else None,
                "observed_at": getattr(snapshot, "observed_at", None) if snapshot else None,
            }
        )
    return rows


def set_provider_enabled(
    provider_id: str,
    enabled: bool,
    *,
    source_instance_id: str = "default",
    settings_path: Path | None = None,
    credentials=None,
    home: Path | None = None,
) -> dict[str, Any]:
    """Persist the enabled flag through the settings document's optimistic
    concurrency -- a concurrent edit is refused, never silently merged
    (T25). Returns the row as actually persisted."""
    try:
        provider_descriptor(provider_id)
    except ValueError as exc:
        raise ProviderManagementError("unknown_provider", f"unknown provider {provider_id!r}") from exc
    loaded = load_provider_usage_settings(settings_path)
    try:
        updated = loaded.settings.with_enabled(
            provider_id, enabled, source_instance_id=source_instance_id
        )
    except StopIteration as exc:
        raise ProviderManagementError(
            "unknown_instance",
            f"{provider_id} has no configured instance {source_instance_id!r}",
        ) from exc
    try:
        save_provider_usage_settings(
            updated,
            settings_path or default_provider_usage_settings_path(),
            loaded=loaded,
        )
    except ProviderUsageSettingsWriteRefusedError as exc:
        raise ProviderManagementError("settings_changed", str(exc)) from exc
    rows = provider_rows(
        credentials=credentials,
        home=home,
        settings_path=settings_path,
        only=provider_id,
        instance=source_instance_id,
    )
    row = rows[0] if rows else {
        "id": provider_id,
        "instance": source_instance_id,
        "enabled": enabled,
    }
    return row


def add_provider_instance(
    provider_id: str,
    source_instance_id: str,
    *,
    label: str | None = None,
    settings_path: Path | None = None,
    credentials=None,
    home: Path | None = None,
) -> dict[str, Any]:
    """Persist one more configured account for a provider.

    The new preference lands through the settings document's optimistic
    concurrency (T25), exactly like ``set_provider_enabled``. It starts
    enabled and metered; the instance's own credential/consent is what
    separates it from the default account, so providers without a
    per-instance source are refused ``unsupported`` rather than silently
    mirroring the first account.
    """
    from .provider_instances import (
        DEFAULT_PROVIDER_INSTANCE_SOURCE_ID,
        ProviderInstanceError,
        ProviderInstanceKey,
    )
    from .provider_usage_settings import ProviderPreference

    try:
        descriptor = provider_descriptor(provider_id)
    except ValueError as exc:
        raise ProviderManagementError("unknown_provider", f"unknown provider {provider_id!r}") from exc
    if not supports_provider_instances(provider_id):
        raise ProviderManagementError(
            "unsupported",
            f"{descriptor.label} reads this Mac's own sign-in; a second "
            "configured account would report the same account twice",
        )
    try:
        key = ProviderInstanceKey(provider_id, source_instance_id)
    except ProviderInstanceError as exc:
        raise ProviderManagementError("invalid_args", str(exc)) from exc
    instance_id = key.source_instance_id.value
    if instance_id == DEFAULT_PROVIDER_INSTANCE_SOURCE_ID:
        raise ProviderManagementError(
            "invalid_args", "every provider already has the default instance"
        )
    if label is not None and (
        not isinstance(label, str)
        or not label.strip()
        or len(label) > 128
        or any(ord(char) < 32 for char in label)
    ):
        raise ProviderManagementError("invalid_args", "invalid instance label")
    loaded = load_provider_usage_settings(settings_path)
    try:
        loaded.settings.preference(provider_id, instance_id)
    except StopIteration:
        pass
    else:
        raise ProviderManagementError(
            "already_exists",
            f"{provider_id} already has instance {instance_id!r}",
        )
    preference = ProviderPreference(
        provider_id,
        enabled=True,
        browser_sources=False,
        source_instance_id=instance_id,
        # None lets ProviderPreference name it "<Label> · <instance>".
        label=label.strip() if label else None,
    )
    try:
        save_provider_usage_settings(
            loaded.settings.with_instance(preference),
            settings_path or default_provider_usage_settings_path(),
            loaded=loaded,
        )
    except ProviderUsageSettingsWriteRefusedError as exc:
        raise ProviderManagementError("settings_changed", str(exc)) from exc
    rows = provider_rows(
        credentials=credentials,
        home=home,
        settings_path=settings_path,
        only=provider_id,
        instance=instance_id,
    )
    return rows[0] if rows else {
        "id": provider_id,
        "instance": instance_id,
        "enabled": True,
    }


def grant_browser_consent(
    provider_id: str,
    browser: str,
    profile: str,
    *,
    background_repair: bool = False,
    source_instance_id: str = "default",
    consent_path: Path | None = None,
    home: Path | None = None,
) -> dict[str, Any]:
    """Consent binds one provider + browser + profile + declared fields and
    imports nothing; the import remains a separate explicit action (T26)."""
    scope = BROWSER_CONSENT_SCOPES.get(provider_id)
    if scope is None:
        raise ProviderManagementError(
            "unsupported",
            f"{provider_id} has no consented browser source",
        )
    loaded = load_browser_consents(consent_path)
    try:
        updated = loaded.store.grant(
            provider_id=provider_id,
            browser=browser,
            profile=profile,
            domains=scope["domains"],
            fields=scope["fields"],
            background_repair=background_repair,
            granted_at=time.time(),
            source_instance_id=source_instance_id,
        )
        save_browser_consents(updated, consent_path, loaded=loaded)
    except Exception as exc:
        raise ProviderManagementError("invalid_args", str(exc)[:300]) from exc
    return {
        "provider_id": provider_id,
        "source_instance_id": source_instance_id,
        "browser": browser,
        "profile": profile,
        "domains": list(scope["domains"]),
        "fields": list(scope["fields"]),
        "background_repair": background_repair,
        "imported": False,
    }


def revoke_browser_consent(
    provider_id: str,
    browser: str,
    profile: str,
    *,
    source_instance_id: str = "default",
    consent_path: Path | None = None,
    credentials=None,
    home: Path | None = None,
) -> dict[str, Any]:
    """Revoking stops every future read (``consents.allows`` gates them
    all) and removes the imported credential only while it is still the
    imported one (T26)."""
    loaded = load_browser_consents(consent_path)
    had = any(
        consent.provider_id == provider_id
        and consent.source_instance_id == source_instance_id
        and consent.browser == browser
        and consent.profile == profile
        for consent in loaded.store.consents
    )
    updated = loaded.store.revoke(
        provider_id,
        browser,
        profile,
        source_instance_id=source_instance_id,
    )
    save_browser_consents(updated, consent_path, loaded=loaded)
    imported_data = "none"
    if credentials is not None:
        imported_data = purge_imported_browser_data(
            provider_id,
            source_instance_id,
            credentials,
            home=home,
        )
    return {
        "provider_id": provider_id,
        "source_instance_id": source_instance_id,
        "browser": browser,
        "profile": profile,
        "was_granted": had,
        "imported_data": imported_data,
    }


__all__ = [
    "BROWSER_CONSENT_SCOPES",
    "CREDENTIAL_ACCOUNTS",
    "ProviderManagementError",
    "add_provider_instance",
    "forget_browser_import",
    "grant_browser_consent",
    "provider_rows",
    "purge_imported_browser_data",
    "record_browser_import",
    "revoke_browser_consent",
    "set_provider_enabled",
    "supports_provider_instances",
]
