"""Explicit Factory browser imports and instance-scoped session storage."""

from __future__ import annotations

import base64
import hashlib
import itertools
import json
import os
import re
import sqlite3
import stat
import tempfile
import threading
import time
from pathlib import Path

from .browser_session_import import (
    FIREFOX_FAMILY_PROFILE_ROOTS,
    _copy_storage_file,
    _decoded,
    _storage_stamp,
    firefox_profile_directory,
)
from .core_server import CommandError
from .provider_browser_consent import BrowserConsentStore, load_browser_consents, save_browser_consents
from .provider_browser_import import (
    _CHROMIUM_PROFILE_ROOT_BY_BROWSER,
    chromium_profile_directory,
    read_chromium_local_storage,
)
from .provider_instances import ProviderInstanceKey
from .provider_usage_settings import load_provider_usage_settings

ORIGINS = ("app.factory.ai", "auth.factory.ai")
FIELDS = ("workos:refresh-token", "workos:access-token")
WORKOS_CLIENT_IDS = ("client_01HXRMBQ9BJ3E7QSTQ9X2PHVB7", "client_01HNM792M5G5G1A2THWPXKFMXB")
SESSION_LOCK = threading.RLock()
_IMPORT_GENERATIONS = {}
_LOGIN = "Sign in at https://app.factory.ai in the selected browser profile, then import again."
_ROOTS = {
    label.lower(): relative for label, relative in FIREFOX_FAMILY_PROFILE_ROOTS
} | _CHROMIUM_PROFILE_ROOT_BY_BROWSER


def _text(value, maximum=16384):
    return (
        isinstance(value, str)
        and 0 < len(value) <= maximum
        and value == value.strip()
        and all(ord(char) >= 33 and ord(char) != 127 for char in value)
    )


def decode_session(raw):
    if not isinstance(raw, str) or len(raw.encode("utf-8")) > 65536:
        raise ValueError("invalid Factory session")
    try:
        value = json.loads(raw)
    except (ValueError, TypeError):
        raise ValueError("invalid Factory session") from None
    if (
        not isinstance(value, dict)
        or set(value)
        - {
            "refresh_token",
            "access_token",
            "organization_id",
            "browser",
            "profile",
            "consent_version",
            "identity",
            "client_id",
        }
        or ("client_id" in value and value["client_id"] not in WORKOS_CLIENT_IDS)
        or type(value.get("consent_version")) is not int
        or value["consent_version"] != 1
        or not _text(value.get("refresh_token"))
        or not isinstance(value.get("browser"), str)
        or value["browser"] not in _ROOTS
        or not isinstance(value.get("profile"), str)
        or not _valid_profile(value["profile"])
        or any(
            key in value and not _text(value[key], 256 if key in {"organization_id", "identity"} else 16384)
            for key in ("access_token", "organization_id", "identity")
        )
    ):
        raise ValueError("invalid Factory session")
    return value


def _valid_profile(profile):
    return (
        isinstance(profile, str)
        and 0 < len(profile) <= 256
        and profile not in {".", ".."}
        and Path(profile).name == profile
        and all(ord(char) >= 32 and ord(char) != 127 for char in profile)
    )


def fingerprint(raw):
    return hashlib.sha256(raw.encode()).digest() if isinstance(raw, str) else None


def save_if_current(credentials, expected, value):
    encoded = json.dumps(value, separators=(",", ":"), sort_keys=True)
    decode_session(encoded)
    with SESSION_LOCK:
        current = credentials.get("factory", "web-session")
        if not current.available or fingerprint(current.secret) != expected:
            return False
        if current.secret != encoded:
            credentials.set("factory", "web-session", encoded)
        return True


def profiles(args, *, home=None):
    if args:
        raise CommandError("invalid_args", "factory_session_profiles takes no arguments")
    support = (Path.home() if home is None else Path(home)) / "Library/Application Support"
    rows = []
    for browser, relative in _ROOTS.items():
        root = support / relative
        try:
            _owned_path(support.parent.parent, ("Library", "Application Support", *Path(relative).parts))
            with os.scandir(root) as entries:
                candidates = list(itertools.islice(entries, 257))
            if len(candidates) > 256:
                continue
            for entry in sorted(candidates, key=lambda entry: entry.name):
                if len(rows) >= 256:
                    break
                if (
                    entry.stat(follow_symlinks=False).st_uid != os.getuid()
                    or not _valid_profile(entry.name)
                    or entry.is_symlink()
                    or not entry.is_dir(follow_symlinks=False)
                ):
                    continue
                if browser in _CHROMIUM_PROFILE_ROOT_BY_BROWSER and not re.fullmatch(
                    r"Default|Profile [0-9]+", entry.name
                ):
                    continue
                label = next(
                    (label for label, _ in FIREFOX_FAMILY_PROFILE_ROOTS if label.lower() == browser), browser.title()
                )
                rows.append({"browser": browser, "profile": entry.name, "label": f"{label} · {entry.name}"})
        except OSError:
            continue
    return {"profiles": rows}


def _firefox_values(profile_root, origin):
    try:
        database = _owned_path(
            profile_root, ("storage", "default", "https+++" + origin, "ls", "data.sqlite"), file=True
        )
    except OSError:
        return {}
    wal = database.with_name(database.name + "-wal")
    try:
        stamp, wal_stamp = _storage_stamp(database), _storage_stamp(wal)
        if wal_stamp is not None and wal.lstat().st_uid != os.getuid():
            return {}
        if stamp is None:
            return {}
        with tempfile.TemporaryDirectory(prefix="jrbar-factory-import-") as directory:
            snapshot = Path(directory) / "data.sqlite"
            _copy_storage_file(database, snapshot, stamp)
            if wal_stamp is not None:
                _copy_storage_file(wal, snapshot.with_name("data.sqlite-wal"), wal_stamp)
            if _storage_stamp(database) != stamp or _storage_stamp(wal) != wal_stamp:
                return {}
            connection = sqlite3.connect(f"{snapshot.as_uri()}?mode=ro", uri=True, timeout=1)
            try:
                rows = connection.execute(
                    "SELECT key, value, compression_type FROM data WHERE key IN (?, ?) LIMIT 3", FIELDS
                ).fetchall()
            finally:
                connection.close()
        if len(rows) > 2:
            return {}
        return {key: _decoded(value) for key, value, compression in rows if compression == 0}
    except (OSError, sqlite3.Error):
        return {}


def _owned_path(root, parts, *, file=False):
    current = root
    for index, part in enumerate(parts):
        current = current / part
        info = current.lstat()
        expected = stat.S_ISREG if file and index == len(parts) - 1 else stat.S_ISDIR
        if info.st_uid != os.getuid() or not expected(info.st_mode):
            raise OSError("unsafe browser storage")
    return current


def _jwt_claim(access, name):
    try:
        if not isinstance(access, str) or len(access) > 16384:
            return None
        parts = access.split(".")
        if len(parts) != 3:
            return None
        claims = json.loads(base64.b64decode(parts[1] + "=" * (-len(parts[1]) % 4), altchars=b"-_", validate=True))
        value = claims.get(name) if isinstance(claims, dict) else None
        return value if _text(value, 200) else None
    except (ValueError, TypeError):
        return None


def _jwt_organization(access):
    # This is a routing hint only. auth/me must prove this organization before saving usage.
    return _jwt_claim(access, "org_id")


def read_browser_session(browser, profile, *, home=None):
    home = Path.home() if home is None else Path(home)
    chromium = browser in _CHROMIUM_PROFILE_ROOT_BY_BROWSER
    resolve = chromium_profile_directory if chromium else firefox_profile_directory
    root = resolve(home, browser=browser, profile=profile)
    if root is None:
        return None
    try:
        _owned_path(home, ("Library", "Application Support", *Path(_ROOTS[browser]).parts, profile))
    except OSError:
        return None
    found = []
    for origin in ORIGINS:
        if chromium:
            _owned_path(root, ("Local Storage", "leveldb"))
            values = read_chromium_local_storage(root, origin="https://" + origin, allowed_keys=FIELDS)
        else:
            values = _firefox_values(root, origin)
        refresh, access = values.get(FIELDS[0]), values.get(FIELDS[1])
        if not _text(refresh):
            continue
        row = {"refresh_token": refresh, "browser": browser, "profile": profile, "consent_version": 1}
        if access is not None:
            if not _text(access):
                continue
            row["access_token"] = access
            organization = _jwt_organization(access)
            if organization is not None:
                row["organization_id"] = organization
        found.append(row)
    if not found or len({row["refresh_token"] for row in found}) != 1:
        return None
    return found[0]


def _instance(args):
    instance = args.get("instance", "default")
    try:
        key = ProviderInstanceKey("factory", instance)
    except (ValueError, TypeError):
        raise CommandError("invalid_args", "instance must be a configured provider instance") from None
    try:
        exists = any(
            row.provider_id == "factory" and row.source_instance_id == instance
            for row in load_provider_usage_settings().settings.providers
        )
    except Exception:
        raise CommandError("unavailable", "provider settings could not be read") from None
    if not exists:
        raise CommandError("unknown_instance", "provider instance is not configured")
    return key


def _read(store, key):
    return store.get_for_instance(key, "web-session")


def import_session(args, credentials):
    if (
        set(args) - {"browser", "profile", "instance", "confirm"}
        or args.get("confirm") is not True
        or not isinstance(args.get("browser"), str)
        or args["browser"] not in _ROOTS
        or not _valid_profile(args.get("profile"))
    ):
        raise CommandError(
            "invalid_args",
            "Choose a supported browser profile and explicitly confirm Factory storage and WorkOS renewal access",
        )
    key = _instance(args)
    browser, profile = args["browser"], args["profile"]
    try:
        with SESSION_LOCK:
            before = _read(credentials, key)
            if not before.available and before.reason != "credential_not_found":
                raise RuntimeError
            expected = fingerprint(before.secret)
            generation = _IMPORT_GENERATIONS.get(key.value, 0) + 1
            _IMPORT_GENERATIONS[key.value] = generation
        value = read_browser_session(browser, profile)
    except Exception:
        raise CommandError("unavailable", "Factory browser storage could not be read. " + _LOGIN) from None
    if value is None:
        raise CommandError("browser_session_not_found", _LOGIN)
    encoded = json.dumps(value, separators=(",", ":"), sort_keys=True)
    decode_session(encoded)
    try:
        with SESSION_LOCK:
            current = _read(credentials, key)
            if (
                _IMPORT_GENERATIONS.get(key.value) != generation
                or fingerprint(current.secret) != expected
                or current.available != before.available
            ):
                raise RuntimeError
            loaded = load_browser_consents()
            updated = loaded.store.grant(
                provider_id="factory",
                browser=browser,
                profile=profile,
                domains=ORIGINS,
                fields=FIELDS,
                background_repair=False,
                granted_at=time.time(),
                source_instance_id=key.value[1],
            )
            save_browser_consents(updated, loaded=loaded)
            try:
                credentials.set_for_instance(key, "web-session", encoded)
            except Exception:
                rollback = load_browser_consents()
                identity = ("factory", key.value[1], browser, profile)
                written = next(row for row in updated.consents if row.identity == identity)
                current_grant = next((row for row in rollback.store.consents if row.identity == identity), None)
                if current_grant == written:
                    prior = tuple(row for row in loaded.store.consents if row.identity == identity)
                    preserved = tuple(row for row in rollback.store.consents if row.identity != identity)
                    save_browser_consents(BrowserConsentStore(preserved + prior), loaded=rollback)
                raise
    except Exception:
        raise CommandError(
            "credential_unavailable", "Factory session could not be saved. Check Keychain and try again."
        ) from None
    return {
        "provider": "factory",
        "instance": key.value[1],
        "message": "Factory browser sign-in saved. Refresh usage to verify it. Your usage switch is unchanged.",
    }


def disconnect(args, credentials):
    if set(args) - {"instance"}:
        raise CommandError("invalid_args", "factory_session_disconnect accepts only instance")
    key = _instance(args)
    try:
        with SESSION_LOCK:
            _IMPORT_GENERATIONS[key.value] = _IMPORT_GENERATIONS.get(key.value, 0) + 1
            loaded = load_browser_consents()
            updated = BrowserConsentStore(
                tuple(
                    consent
                    for consent in loaded.store.consents
                    if (consent.provider_id, consent.source_instance_id) != key.value
                )
            )
            credentials.delete_for_instance(key, "web-session")
            after = _read(credentials, key)
            if after.available or after.reason != "credential_not_found":
                raise RuntimeError
            save_browser_consents(updated, loaded=loaded)
    except Exception:
        raise CommandError(
            "credential_unavailable", "Factory browser session could not be disconnected. Check Keychain and try again."
        ) from None
    return {"provider": "factory", "instance": key.value[1], "message": "Factory browser session disconnected."}
