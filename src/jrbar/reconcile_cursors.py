"""Per-source read cursors for the event-log reconcile path.

Every hook event used to make the collector re-read and re-parse a
bounded TAIL of the provider's events log -- thousands of JSON lines per
event, several events per second under a busy agent, one full core spent
re-deriving state it already had (observed live 2026-08-21, the day the
claude ingest outage was fixed and the hidden cost surfaced). Ingestion
is idempotent, so nothing was wrong -- just wildly wasteful.

This module remembers where each source's last read ended (device,
inode, offset) so a reconcile parses only the bytes appended since.
Rotation, trimming, or first sight fall back to the same bounded tail as
before. Cursors live on the monitor object itself; this module owns the
locking and the fallback rules.
"""

from __future__ import annotations

import threading
from pathlib import Path

from .private_io import read_private_log_slice

#: Fresh-start bound, matching the collector's historical tail replay.
FRESH_START_MAX_LINES = 5_000

_CURSORS_ATTR = "_reconcile_log_cursors"
_LOCK_ATTR = "_reconcile_log_cursors_lock"


def take_new_lines(
    monitor: object,
    source_key: object,
    log_path: Path,
    *,
    max_bytes: int,
) -> list[str] | None:
    """Lines appended to ``log_path`` since this source's last reconcile.

    Returns None when the log cannot be read (caller returns, exactly as
    the old OSError branch did). On a fresh start (no cursor, rotated or
    trimmed file) returns the newest ``max_bytes`` worth of lines bounded
    to FRESH_START_MAX_LINES. The cursor only advances on a successful
    read, and only to a newline boundary.
    """
    lock = getattr(monitor, _LOCK_ATTR, None)
    if lock is None:
        lock = threading.Lock()
        setattr(monitor, _LOCK_ATTR, lock)
    with lock:
        cursors = getattr(monitor, _CURSORS_ATTR, None)
        if cursors is None:
            cursors = {}
            setattr(monitor, _CURSORS_ATTR, cursors)
        cursor = cursors.get(source_key)
        try:
            text, next_cursor = read_private_log_slice(
                Path(log_path),
                cursor=cursor,
                max_bytes=max_bytes,
            )
        except OSError:
            return None
        cursors[source_key] = next_cursor
    fresh_start = cursor is None or (cursor[0], cursor[1]) != (
        next_cursor[0],
        next_cursor[1],
    )
    lines = text.splitlines()
    if fresh_start and len(lines) > FRESH_START_MAX_LINES:
        return lines[-FRESH_START_MAX_LINES:]
    return lines


def take_own_append(
    monitor: object,
    source_key: object,
    at: tuple[int, int, int, int],
) -> bool:
    """Move this source's cursor past a line the monitor's own process just
    appended at ``(device, inode, start, end)``, when the cursor stands
    exactly at ``start``: nothing else was appended in between, so the
    line is all a reread would find. False leaves the cursor alone and the
    caller rereads the log."""
    lock = getattr(monitor, _LOCK_ATTR, None)
    if lock is None:
        return False
    device, inode, start, end = at
    with lock:
        cursors = getattr(monitor, _CURSORS_ATTR, None)
        if not cursors or cursors.get(source_key) != (device, inode, start):
            return False
        cursors[source_key] = (device, inode, end)
    return True


__all__ = ["FRESH_START_MAX_LINES", "take_new_lines", "take_own_append"]
