"""The asks a person dismissed on this Mac, remembered across restarts.

Dismissing a stale ask is a local choice: it takes that one ask off JR-Bar's
surfaces and sends nothing to the agent. Nothing answers an agent on its own,
so a dismissal never approves, denies or replies; the agent's own prompt is
exactly where it was. The record is content-free -- a session id and the
millisecond the ask opened -- and bounded, so it cannot grow without end.

A later ask on the same session opens at a different time, so a dismissal
never covers it. When the agent settles the ask, or the session ends, the
record is simply never matched again and ages out.

The same file remembers the sessions whose ask JR-Bar closed by age
(``ask_lifetime.ASK_EXPIRES_UNANSWERED_SECONDS``, no process behind it). Their
end is the Mac's own record, not the agent's, so a row for one reads "ended",
never the green "done" a real finish earns.
"""

from __future__ import annotations

import json
import math
import threading
from pathlib import Path
from typing import Final

from .ask_lifetime import ask_dismissal_key
from .private_io import (
    atomic_private_write,
    private_file_identity,
    quarantine_private_file,
    read_private_text,
)

STORE_NAME: Final = "dismissed-asks.json"
STORE_VERSION: Final = 1
MAX_DISMISSED_ASKS: Final = 256
#: A dismissal older than this is forgotten. The ask it covered is long over:
#: nothing waits on a person for thirty days without being closed by then.
DISMISSAL_RETENTION_SECONDS: Final = 30 * 86_400.0
_MAX_STORE_BYTES: Final = 256 * 1024


class AskDismissals:
    """A thread-safe, bounded set of dismissed ask identities."""

    def __init__(
        self,
        entries: dict[tuple[str, int], float] | None = None,
        expired: dict[tuple[str, str], float] | None = None,
    ) -> None:
        self._lock = threading.Lock()
        self._entries: dict[tuple[str, int], float] = dict(entries or {})
        self._expired: dict[tuple[str, str], float] = dict(expired or {})

    def absorb(self, other: AskDismissals) -> None:
        """Take on what ``other`` (a freshly loaded file) remembers, keeping
        anything already recorded here."""
        with other._lock:
            entries, expired = dict(other._entries), dict(other._expired)
        with self._lock:
            for key, at in entries.items():
                self._entries.setdefault(key, at)
            for key, at in expired.items():
                self._expired.setdefault(key, at)

    def mark_expired(self, provider: str, session_id: str, *, at: float) -> bool:
        """Remember that this session's ask was closed by age."""
        if not (type(provider) is str and provider and type(session_id) is str and session_id):
            return False
        if not math.isfinite(at):
            return False
        with self._lock:
            self._expired[(provider, session_id)] = float(at)
            excess = len(self._expired) - MAX_DISMISSED_ASKS
            if excess > 0:
                for old in sorted(self._expired, key=self._expired.__getitem__)[:excess]:
                    del self._expired[old]
        return True

    def was_expired(self, provider: object, session_id: object) -> bool:
        with self._lock:
            return (provider, session_id) in self._expired

    def keys(self) -> frozenset[tuple[str, int]]:
        with self._lock:
            return frozenset(self._entries)

    def __len__(self) -> int:
        with self._lock:
            return len(self._entries)

    def add(self, agent_id: str, opened_at_epoch: float, *, at: float) -> bool:
        """Remember one dismissal. ``False`` for an identity that cannot be keyed."""
        key = ask_dismissal_key(agent_id, opened_at_epoch)
        if key is None or not math.isfinite(at):
            return False
        with self._lock:
            self._entries[key] = float(at)
            excess = len(self._entries) - MAX_DISMISSED_ASKS
            if excess > 0:
                for old in sorted(self._entries, key=self._entries.__getitem__)[:excess]:
                    del self._entries[old]
        return True

    def forget(self, agent_id: str, opened_at_epoch: float) -> bool:
        key = ask_dismissal_key(agent_id, opened_at_epoch)
        with self._lock:
            return key is not None and self._entries.pop(key, None) is not None

    def prune(self, *, now: float) -> bool:
        """Drop dismissals past the retention. ``True`` when any went."""
        with self._lock:
            old = [
                key
                for key, at in self._entries.items()
                if now - at > DISMISSAL_RETENTION_SECONDS
            ]
            for key in old:
                del self._entries[key]
            old_expired = [
                key
                for key, at in self._expired.items()
                if now - at > DISMISSAL_RETENTION_SECONDS
            ]
            for key in old_expired:
                del self._expired[key]
            return bool(old or old_expired)

    def document(self) -> dict[str, object]:
        with self._lock:
            rows = [
                {"session": agent_id, "opened_ms": opened_ms, "dismissed_at": at}
                for (agent_id, opened_ms), at in sorted(self._entries.items())
            ]
            expired = [
                {"provider": provider, "session": session_id, "at": at}
                for (provider, session_id), at in sorted(self._expired.items())
            ]
        return {"version": STORE_VERSION, "dismissed": rows, "expired": expired}


def default_ask_dismissals_path(state_dir: Path) -> Path:
    return Path(state_dir) / STORE_NAME


def load_ask_dismissals(path: Path) -> AskDismissals:
    """Read the store. A file that does not read is set aside, never trusted."""
    target = Path(path)
    seen = private_file_identity(target)
    try:
        raw = read_private_text(target, max_bytes=_MAX_STORE_BYTES)
    except FileNotFoundError:
        return AskDismissals()
    except OSError:
        return AskDismissals()
    try:
        document = json.loads(raw)
        if (
            not isinstance(document, dict)
            or document.get("version") != STORE_VERSION
            or not isinstance(document.get("dismissed"), list)
        ):
            raise ValueError("unsupported dismissed-asks document")
        entries: dict[tuple[str, int], float] = {}
        for row in document["dismissed"][:MAX_DISMISSED_ASKS]:
            session = row.get("session") if isinstance(row, dict) else None
            opened_ms = row.get("opened_ms") if isinstance(row, dict) else None
            at = row.get("dismissed_at") if isinstance(row, dict) else None
            if (
                type(session) is str
                and session
                and type(opened_ms) is int
                and type(at) in (int, float)
                and math.isfinite(at)
            ):
                entries[(session, opened_ms)] = float(at)
        expired: dict[tuple[str, str], float] = {}
        for row in (document.get("expired") or [])[:MAX_DISMISSED_ASKS]:
            provider = row.get("provider") if isinstance(row, dict) else None
            session = row.get("session") if isinstance(row, dict) else None
            at = row.get("at") if isinstance(row, dict) else None
            if (
                type(provider) is str
                and provider
                and type(session) is str
                and session
                and type(at) in (int, float)
                and math.isfinite(at)
            ):
                expired[(provider, session)] = float(at)
    except (TypeError, ValueError, RecursionError):
        quarantine_private_file(target, reason="it did not decode", expected_identity=seen)
        return AskDismissals()
    return AskDismissals(entries, expired)


def save_ask_dismissals(path: Path, dismissals: AskDismissals) -> None:
    serialized = json.dumps(
        dismissals.document(), allow_nan=False, separators=(",", ":"), sort_keys=True
    )
    atomic_private_write(Path(path), f"{serialized}\n")


__all__ = [
    "DISMISSAL_RETENTION_SECONDS",
    "MAX_DISMISSED_ASKS",
    "STORE_NAME",
    "AskDismissals",
    "default_ask_dismissals_path",
    "load_ask_dismissals",
    "save_ask_dismissals",
]
