"""Read optional macOS Focus mode names and identifiers.

The public Focus observation in ``focus_status`` reports whether Focus is
active. This module reads the private files maintained by ``focusd`` for
named per-Focus rules. Those files require Full Disk Access for the exact
Python interpreter reading them, and their schema can change with macOS.

Unreadable files or active assertions without a usable identifier raise
FocusSyncUnavailableError. An empty active assertion list means no named
Focus is active. Synthetic tests cover these reads; they do not prove the
private schema against a live Focus session.
"""

from __future__ import annotations

import json
from pathlib import Path

ASSERTIONS_PATH = Path("~/Library/DoNotDisturb/DB/Assertions.json").expanduser()
MODE_CONFIGURATIONS_PATH = Path("~/Library/DoNotDisturb/DB/ModeConfigurations.json").expanduser()

MAX_ACTIVE_IDENTIFIERS = 64
MAX_IDENTIFIER_UTF8_BYTES = 256
MAX_FOCUS_JSON_BYTES = 8 * 1024 * 1024


class FocusSyncUnavailableError(RuntimeError):
    pass


def _load_focus_json(path: Path) -> object:
    try:
        with path.open("rb") as stream:
            raw_bytes = stream.read(MAX_FOCUS_JSON_BYTES + 1)
        if len(raw_bytes) > MAX_FOCUS_JSON_BYTES:
            raise FocusSyncUnavailableError("Focus data exceeds the read limit")
        raw = raw_bytes.decode("utf-8")
        if not raw.strip():
            return {}
        return json.loads(raw)
    except (OSError, UnicodeError, json.JSONDecodeError, RecursionError) as exc:
        raise FocusSyncUnavailableError(str(exc)) from exc


def _collect_string_values(node: object, key: str, found: set[str]) -> None:
    """Depth-first search for string values stored under ``key``."""
    if isinstance(node, dict):
        value = node.get(key)
        if isinstance(value, str) and value.strip():
            try:
                encoded = value.encode("utf-8")
            except UnicodeError as exc:
                raise FocusSyncUnavailableError("Active Focus mode names unavailable") from exc
            if len(encoded) > MAX_IDENTIFIER_UTF8_BYTES:
                raise FocusSyncUnavailableError("Active Focus mode names unavailable")
            found.add(value)
        for child in node.values():
            _collect_string_values(child, key, found)
    elif isinstance(node, list):
        for item in node:
            _collect_string_values(item, key, found)


def _collect_active_assertion_identifiers(node: object, found: set[str]) -> None:
    """Collect identifiers only from live ``storeAssertionRecords`` rows.

    Assertions.json also carries configured-mode metadata. Searching the
    whole document after finding one active assertion therefore reported
    every configured Focus as active at once. Keep the schema-tolerant tree
    walk, but restrict identifier extraction to the records focusd marks as
    currently asserted.
    """
    if isinstance(node, dict):
        records = node.get("storeAssertionRecords")
        if "storeAssertionRecords" in node and not isinstance(records, list):
            raise FocusSyncUnavailableError("Active Focus mode names unavailable")
        if isinstance(records, list):
            for record in records:
                identifiers: set[str] = set()
                _collect_string_values(
                    record,
                    "assertionDetailsModeIdentifier",
                    identifiers,
                )
                if not identifiers:
                    raise FocusSyncUnavailableError("Active Focus mode names unavailable")
                found.update(identifiers)
                if len(found) > MAX_ACTIVE_IDENTIFIERS:
                    raise FocusSyncUnavailableError("Active Focus mode names unavailable")
        for child in node.values():
            _collect_active_assertion_identifiers(child, found)
    elif isinstance(node, list):
        for item in node:
            _collect_active_assertion_identifiers(item, found)


def active_focus_mode_identifiers() -> list[str]:
    """Mode identifiers (e.g. "com.apple.donotdisturb.mode.default") for
    every currently-active Focus assertion, sorted. Empty when no Focus is
    on. Raises FocusSyncUnavailableError when it can't be determined (no
    Full Disk Access, missing file, unparseable JSON)."""
    data = _load_focus_json(ASSERTIONS_PATH)
    identifiers: set[str] = set()
    try:
        _collect_active_assertion_identifiers(data, identifiers)
    except RecursionError as exc:
        raise FocusSyncUnavailableError("Active Focus mode names unavailable") from exc
    return sorted(identifiers)


def configured_focus_modes() -> list[tuple[str, str]]:
    """(identifier, display name) for every Focus the user has configured,
    sorted by name -- the roster the per-Focus dim rules UI offers. Raises
    FocusSyncUnavailableError when unreadable."""
    data = _load_focus_json(MODE_CONFIGURATIONS_PATH)
    modes: dict[str, str] = {}

    def walk(node: object) -> None:
        if isinstance(node, dict):
            identifier = node.get("modeIdentifier")
            name = node.get("name")
            if isinstance(identifier, str) and identifier and isinstance(name, str) and name:
                modes.setdefault(identifier, name)
            for child in node.values():
                walk(child)
        elif isinstance(node, list):
            for item in node:
                walk(item)

    try:
        walk(data)
    except RecursionError as exc:
        raise FocusSyncUnavailableError("Configured Focus mode names unavailable") from exc
    return sorted(modes.items(), key=lambda item: item[1].lower())


def _has_active_assertion(node: object) -> bool:
    if isinstance(node, dict):
        records = node.get("storeAssertionRecords")
        if isinstance(records, list) and records:
            return True
        return any(_has_active_assertion(value) for value in node.values())
    if isinstance(node, list):
        return any(_has_active_assertion(item) for item in node)
    return False


def is_focus_active() -> bool:
    """True if at least one macOS Focus is currently active.

    Raises FocusSyncUnavailableError if this can't be determined right now
    (no Full Disk Access, file missing, or unparseable) -- callers must
    treat that the same as "assume not active" rather than let it
    propagate into the LED sync loop.
    """
    data = _load_focus_json(ASSERTIONS_PATH)
    try:
        return _has_active_assertion(data)
    except RecursionError as exc:
        raise FocusSyncUnavailableError("Active Focus unavailable") from exc
