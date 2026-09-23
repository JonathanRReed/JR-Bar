"""``confetti``: a burst asked for from outside JR-Bar.

Raycast's confetti deeplink made any script able to celebrate; this is the
daemon's half of the same idea with agent awareness on top. ``jrbar
confetti`` (a Stop hook, ``make test && …``, CI) sends the ``confetti``
command; the daemon names the session the caller means -- by its own id or
by the agent's -- and journals one ``confetti`` event carrying that
session's provider, so the burst wears its colours. The daemon only states
the fact: the app's Confetti toy decides whether it fires (the toy on, the
room clear, its own cooldown), exactly as it judges a weekly reset.

Nothing here answers anything, reads a transcript or leaves the Mac. The
one thing the daemon guards itself is its journal: a loop in someone's
hook coalesces into one event per ``CONFETTI_COALESCE_SECONDS`` instead of
evicting the real events a reconnecting app replays.
"""

from __future__ import annotations

import re
from collections.abc import Iterable, Mapping
from dataclasses import dataclass
from typing import Any, Final

CONFETTI_EVENT_KIND: Final = "confetti"
#: The app's own ``ConfettiRoom.requestCooldown``: a second ask inside it
#: would be dropped there anyway, so it never reaches the journal.
CONFETTI_COALESCE_SECONDS: Final = 3.0
#: "tests passed", "deployed" -- a line for History, not a message.
MAX_CONFETTI_REASON: Final = 80
MAX_SESSION_ARGUMENT: Final = 512

_PROVIDER = re.compile(r"[a-z][a-z0-9._-]{0,31}")


@dataclass(frozen=True, slots=True)
class ConfettiRequest:
    """One validated ask: the session it names (the daemon's agent id, when
    one is watched), the provider whose colours it wears, and why."""

    session: str | None
    provider: str | None
    reason: str | None
    label: str | None
    #: A session was named but nothing watched matches it: the burst still
    #: goes out, in the Toys colour, and the caller is told.
    unmatched: str | None = None

    def event_fields(self) -> dict[str, Any]:
        """The ``confetti`` event's fields, absent rather than null."""
        fields = {
            "session": self.session,
            "provider": self.provider,
            "label": self.label,
            "detail": self.reason,
        }
        return {key: value for key, value in fields.items() if value is not None}


def _provider(value: object) -> str | None:
    if value is None:
        return None
    if type(value) is not str:
        raise ValueError("provider must be a provider id such as claude or codex")
    text = value.strip().lower()
    if not text:
        return None
    if _PROVIDER.fullmatch(text) is None:
        raise ValueError(f"not a provider id: {value[:40]!r}")
    return text


def _reason(value: object) -> str | None:
    if value is None:
        return None
    if type(value) is not str:
        raise ValueError("reason must be text")
    text = " ".join(value.split())[:MAX_CONFETTI_REASON].strip()
    if not text:
        return None
    if not text.isprintable():
        raise ValueError("reason must be printable text")
    return text


def _session_argument(value: object) -> str | None:
    if value is None:
        return None
    if type(value) is not str:
        raise ValueError("session must be a session id")
    text = value.strip()
    if not text:
        return None
    if len(text) > MAX_SESSION_ARGUMENT or not text.isprintable():
        raise ValueError("session must be a printable session id")
    return text


def match_session(session: str, statuses: Iterable[object]) -> object | None:
    """The watched status a caller means by ``session``.

    The daemon's own id (``claude:session:…``, what the app and ``jrbar
    status`` show) wins; otherwise the agent's id as its hook payload
    carries it -- a Claude or Codex ``session_id`` -- names that session's
    main row before any of its workers, so a Stop hook colours the burst
    by the run that stopped.
    """
    rows = tuple(statuses)
    for status in rows:
        if getattr(status, "agent_id", None) == session:
            return status
    family = [status for status in rows if getattr(status, "session_id", None) == session]
    for status in family:
        agent_id = str(getattr(status, "agent_id", "") or "")
        if agent_id.endswith(f":session:{session}"):
            return status
    return family[0] if family else None


def resolve_confetti_request(
    args: Mapping[str, Any],
    statuses: Iterable[object],
) -> ConfettiRequest:
    """Validate ``confetti`` args against the watched sessions.

    Raises ``ValueError`` with the sentence to refuse on. An explicit
    ``provider`` wins over the session's own; a session nobody watches
    still celebrates, in the Toys colour.
    """
    provider = _provider(args.get("provider"))
    reason = _reason(args.get("reason"))
    session = _session_argument(args.get("session"))
    if session is None:
        return ConfettiRequest(None, provider, reason, None)
    status = match_session(session, statuses)
    if status is None:
        return ConfettiRequest(None, provider, reason, None, unmatched=session)
    own_provider = getattr(status, "provider", None)
    label = getattr(status, "display_name", None)
    return ConfettiRequest(
        session=str(getattr(status, "agent_id", "") or "") or None,
        provider=provider or (own_provider if type(own_provider) is str and own_provider else None),
        reason=reason,
        label=label if type(label) is str and label else None,
    )


class ConfettiGate:
    """At most one journaled burst per ``CONFETTI_COALESCE_SECONDS``, on the
    caller's monotonic clock."""

    __slots__ = ("_last",)

    def __init__(self) -> None:
        self._last: float | None = None

    def admit(self, now: float) -> bool:
        if self._last is not None and 0.0 <= now - self._last < CONFETTI_COALESCE_SECONDS:
            return False
        self._last = now
        return True


__all__ = [
    "CONFETTI_COALESCE_SECONDS",
    "CONFETTI_EVENT_KIND",
    "MAX_CONFETTI_REASON",
    "ConfettiGate",
    "ConfettiRequest",
    "match_session",
    "resolve_confetti_request",
]
