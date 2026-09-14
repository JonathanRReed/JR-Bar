"""OpenCode control bridge: probe the live ``serve`` API, honestly.

W26's contract: control is enabled only against an *authenticated,
reachable* OpenCode instance, and only for the operations its actual
OpenAPI surface reports — never a guess at a route that might 404.
A missing server or a missing endpoint is a declared limitation, not a
worked-around failure.

The bridge is read-heavy by design: ``capabilities`` asks ``/doc`` what
the server truly serves and reports the supported surface as a closed
set of operation ids. The two control calls the runtime needs —
``interrupt`` and ``permission reply`` — exist only if the probe says
the routes are present.
"""

from __future__ import annotations

import json
import urllib.error
import urllib.request
from collections.abc import Mapping
from dataclasses import dataclass
from typing import Any

# Endpoints this bridge knows how to drive, keyed by the OpenAPI path the
# live server must actually publish for the capability to light up.
_CONTROL_PATHS: dict[str, str] = {
    "interrupt": "/api/session/{sessionID}/interrupt",
    "permission_reply": "/api/permission/{requestID}/reply",
    "question_reply": "/api/session/{sessionID}/question/{requestID}/reply",
    "session_list": "/session",
    "session_events": "/api/session/{sessionID}/event",
    "prompt": "/api/session/{sessionID}/prompt",
}

_REQUEST_TIMEOUT_SECONDS = 5.0


@dataclass(frozen=True, slots=True)
class OpenCodeCapabilities:
    """What a probed instance actually serves — the closed set the UI
    shows, with every missing operation named, not hidden."""

    reachable: bool
    version: str | None
    supported: frozenset[str]
    missing: frozenset[str]
    reason: str | None = None


def probe_capabilities(base_url: str, *, opener=None) -> OpenCodeCapabilities:
    """GET ``/doc`` and report which known routes the instance serves.

    ``opener`` is injectable so tests never touch a socket — production
    passes ``urllib.request.urlopen``.
    """
    open_ = opener or urllib.request.urlopen
    try:
        with open_(f"{base_url.rstrip('/')}/doc",
                   timeout=_REQUEST_TIMEOUT_SECONDS) as response:
            doc = json.loads(response.read().decode("utf-8"))
    except (urllib.error.URLError, OSError, ValueError):
        return OpenCodeCapabilities(
            reachable=False, version=None,
            supported=frozenset(), missing=frozenset(_CONTROL_PATHS),
            reason="opencode serve is not reachable",
        )
    paths = doc.get("paths") if isinstance(doc, Mapping) else None
    if not isinstance(paths, Mapping):
        return OpenCodeCapabilities(
            reachable=True, version=None,
            supported=frozenset(), missing=frozenset(_CONTROL_PATHS),
            reason="/doc answered without an OpenAPI paths map",
        )
    version = None
    info = doc.get("info")
    if isinstance(info, Mapping) and isinstance(info.get("version"), str):
        version = info["version"]
    served = set(paths)
    supported = frozenset(k for k, p in _CONTROL_PATHS.items() if p in served)
    return OpenCodeCapabilities(
        reachable=True, version=version,
        supported=supported,
        missing=frozenset(k for k, p in _CONTROL_PATHS.items() if p not in served),
    )


def list_sessions(base_url: str, *, opener=None) -> list[dict[str, Any]]:
    """The read half: the server's own session list, projected to the
    facts a glance needs — id, title, directory, updated stamp."""
    open_ = opener or urllib.request.urlopen
    try:
        with open_(f"{base_url.rstrip('/')}/session",
                   timeout=_REQUEST_TIMEOUT_SECONDS) as response:
            rows = json.loads(response.read().decode("utf-8"))
    except (urllib.error.URLError, OSError, ValueError):
        return []
    if not isinstance(rows, list):
        return []
    sessions: list[dict[str, Any]] = []
    for row in rows[:50]:
        if not isinstance(row, Mapping):
            continue
        entry: dict[str, Any] = {}
        if isinstance(row.get("id"), str):
            entry["id"] = row["id"]
        if isinstance(row.get("title"), str):
            entry["title"] = row["title"][:200]
        if isinstance(row.get("directory"), str):
            entry["directory"] = row["directory"]
        time_block = row.get("time")
        if isinstance(time_block, Mapping) and isinstance(
                time_block.get("updated"), (int, float)):
            entry["updated"] = time_block["updated"]
        if isinstance(row.get("version"), str):
            entry["version"] = row["version"]
        if entry.get("id"):
            sessions.append(entry)
    return sessions
