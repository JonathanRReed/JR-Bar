"""Owner-private deduplication store for finite provider reset cues."""

from __future__ import annotations

import json
import re
import time
from pathlib import Path

from .provider_reset_events import (
    ResetDeliveryState,
    decode_reset_delivery_state,
    encode_reset_delivery_state,
    prune_reset_delivery_state,
)

RESET_EVENT_STORE_SCHEMA_VERSION = 1
MAX_SEEN_RESET_EVENTS = 512
#: The delivery file is trimmed to stay under ``RESET_STATE_SOFT_BYTES`` on
#: every write. The read ceiling sits far above it, so a file that grew
#: past the old cap (from an older build that never trimmed) is read,
#: trimmed and rewritten smaller instead of being thrown away.
RESET_STATE_SOFT_BYTES = 96 * 1024
RESET_STATE_READ_CEILING_BYTES = 4 * 1024 * 1024
_EVENT_ID = re.compile(r"[a-z][a-z0-9-]{0,31}:[a-z0-9][a-z0-9._:-]{0,127}:[0-9a-f]{24}\Z")


def default_reset_event_store_path(home: Path | None = None) -> Path:
    base = Path.home() if home is None else Path(home)
    return base / ".local" / "state" / "jrbar" / "provider-reset-events.json"


def load_seen_reset_events(path: Path | None = None) -> tuple[str, ...]:
    target = default_reset_event_store_path() if path is None else Path(path)
    try:
        from .private_io import read_private_text

        document = json.loads(read_private_text(target, max_bytes=128 * 1024))
    except (FileNotFoundError, OSError, UnicodeError, ValueError, RecursionError):
        return ()
    if (
        not isinstance(document, dict)
        or document.get("schema_version") != RESET_EVENT_STORE_SCHEMA_VERSION
        or not isinstance(document.get("seen"), list)
    ):
        return ()
    rows = []
    for value in document["seen"][-MAX_SEEN_RESET_EVENTS:]:
        if isinstance(value, str) and _EVENT_ID.fullmatch(value) and value not in rows:
            rows.append(value)
    return tuple(rows)


def save_seen_reset_events(
    event_ids: tuple[str, ...] | list[str],
    path: Path | None = None,
) -> Path:
    rows = []
    for value in tuple(event_ids)[-MAX_SEEN_RESET_EVENTS:]:
        if isinstance(value, str) and _EVENT_ID.fullmatch(value) and value not in rows:
            rows.append(value)
    document = {
        "schema_version": RESET_EVENT_STORE_SCHEMA_VERSION,
        "seen": rows[-MAX_SEEN_RESET_EVENTS:],
    }
    target = default_reset_event_store_path() if path is None else Path(path)
    from .private_io import atomic_private_write

    atomic_private_write(
        target,
        json.dumps(document, separators=(",", ":"), sort_keys=True),
    )
    return target


def load_reset_delivery_state(
    path: Path | None = None,
    *,
    now: float | None = None,
) -> ResetDeliveryState:
    """The saved deliveries and waiting jumps, trimmed to the retention
    bound. A file that outgrew the old size cap still loads (its oldest
    finished deliveries are dropped); only an unreadable one is empty."""
    target = default_reset_event_store_path() if path is None else Path(path)
    try:
        from .private_io import read_private_text

        state = decode_reset_delivery_state(
            read_private_text(target, max_bytes=RESET_STATE_READ_CEILING_BYTES)
        )
    # A file of the wrong shape (a missing key, a wrong type) is as unreadable
    # as a torn one: the store starts empty and the daemon starts.
    except (
        FileNotFoundError,
        OSError,
        UnicodeError,
        ValueError,
        KeyError,
        TypeError,
        AttributeError,
        OverflowError,
        RecursionError,
    ):
        return ResetDeliveryState()
    return prune_reset_delivery_state(state, now=time.time() if now is None else now)


def save_reset_delivery_state(
    state: ResetDeliveryState,
    path: Path | None = None,
    *,
    now: float | None = None,
) -> Path:
    if type(state) is not ResetDeliveryState:
        raise ValueError("invalid reset delivery state")
    target = default_reset_event_store_path() if path is None else Path(path)
    from .private_io import atomic_private_write

    current = time.time() if now is None else now
    state = prune_reset_delivery_state(state, now=current)
    payload = encode_reset_delivery_state(state)
    keep = len(state.events)
    # Retention by count normally keeps the file small; this is the
    # backstop for unusually large receipts. Only finished deliveries
    # are ever shed, so open ones and waiting jumps always survive.
    while len(payload.encode("utf-8")) > RESET_STATE_SOFT_BYTES and keep > 0:
        keep //= 2
        state = prune_reset_delivery_state(state, now=current, keep_settled=keep)
        payload = encode_reset_delivery_state(state)
    atomic_private_write(target, payload)
    return target


__all__ = [
    "MAX_SEEN_RESET_EVENTS",
    "RESET_EVENT_STORE_SCHEMA_VERSION",
    "RESET_STATE_READ_CEILING_BYTES",
    "RESET_STATE_SOFT_BYTES",
    "default_reset_event_store_path",
    "load_reset_delivery_state",
    "load_seen_reset_events",
    "save_reset_delivery_state",
    "save_seen_reset_events",
]
