"""Redacted widget snapshot: the file a WidgetKit extension reads.

The daemon already publishes a full ``state`` frame over the socket, but a
widget extension cannot hold that connection and must never see raw
transcript text anyway.  This module projects the state document down to
counts, provider names and a timestamp — the glance a desktop widget
shows — and writes it atomically beside the daemon's other state files so
a crash never leaves a half-written JSON.

Consent boundary: nothing here carries a session title, a message body or
a path.  ``entries`` are reduced to ``{provider, mode, waiting}`` — enough
for the widget's tile strip, never enough to reconstruct a conversation.
"""

from __future__ import annotations

import json
import os
from collections.abc import Mapping
from pathlib import Path
from typing import Any

SNAPSHOT_FILENAME = "widget-snapshot.json"

# A state document with more rows than this is already beyond what a
# widget glance can show; the cap also bounds the file's size on disk.
_MAX_ENTRIES = 24

_LIVE_MODES: frozenset[str] = frozenset(
    {"working", "tool_running", "long_task_progress", "thinking", "waiting_for_input"}
)


def _entry(session: Mapping[str, Any]) -> dict[str, Any] | None:
    provider = session.get("provider")
    if not isinstance(provider, str) or not provider:
        return None
    axes = session.get("axes")
    axes_map = axes if isinstance(axes, Mapping) else {}
    return {
        "provider": provider,
        "mode": session.get("mode") if isinstance(session.get("mode"), str) else "unknown",
        "waiting": axes_map.get("attention") == "waiting",
        "stale": bool(session.get("stale")),
    }


def widget_snapshot(state: Mapping[str, Any], *, now: float) -> dict[str, Any]:
    """Project a ``state`` document into the widget's redacted shape.

    ``sessions`` rows carry the transcript-era fields; only the three the
    widget needs survive.  Counts come from the same rows the panel lists,
    so a widget and the menu bar can never disagree about "3 working".
    """
    sessions = state.get("sessions")
    rows = [s for s in sessions if isinstance(s, Mapping)] if isinstance(sessions, list) else []
    entries: list[dict[str, Any]] = []
    working = waiting = stale = 0
    for row in rows:
        mode = row.get("mode")
        axes = row.get("axes")
        is_waiting = isinstance(axes, Mapping) and axes.get("attention") == "waiting"
        if isinstance(mode, str) and mode in _LIVE_MODES and not is_waiting:
            working += 1
        if is_waiting:
            waiting += 1
        if row.get("stale"):
            stale += 1
        if len(entries) < _MAX_ENTRIES:
            entry = _entry(row)
            if entry is not None:
                entries.append(entry)
    return {
        "schema": 1,
        "generated_at": round(now, 3),
        "counts": {
            "sessions": len(rows),
            "working": working,
            "waiting": waiting,
            "stale": stale,
            "shown": len(entries),
        },
        "entries": entries,
    }


def write_widget_snapshot(state: Mapping[str, Any], state_dir: Path, *, now: float) -> Path:
    """Atomically replace the snapshot file: tmp + rename, never partial."""
    return write_widget_snapshot_payload(
        json.dumps(widget_snapshot(state, now=now), separators=(",", ":")), state_dir
    )


def write_widget_snapshot_payload(payload: str, state_dir: Path) -> Path:
    """Write an already-projected snapshot: the daemon projects on its run
    loop and writes from its persistence thread."""
    target = state_dir / SNAPSHOT_FILENAME
    tmp = state_dir / f".{SNAPSHOT_FILENAME}.{os.getpid()}.tmp"
    tmp.write_text(payload, encoding="utf-8")
    os.replace(tmp, target)
    return target
