"""How long an unanswered ask stays on every surface.

An ask is the one thing JR-Bar shows that a person has to act on. It stays
visible until it is answered, until the agent settles it itself, or until its
session is over. Time alone never hides it. This module is the one place the
two clocks that govern an ask that nobody has touched are named:

* ``ASK_MAY_BE_STALE_SECONDS`` -- once the ask is this old and its session has
  been silent for as long, every surface keeps showing it and says it may be
  stale, with its age in words, and offers one Dismiss. The strip keeps the
  Ask colour but pulses more calmly.
* ``ASK_EXPIRES_UNANSWERED_SECONDS`` -- once it is this old and silent, with no
  agent process to vouch for it, it is closed and recorded in History as
  "expired unanswered". An ask whose process is still running is never closed
  by age.

Before this module an unanswered ask read "Ask" at 59 minutes and idle at 61,
because four places (the reducer's live grace, the presence horizon, the
collector's stale window and the mailbox section) each carried their own hour.
Those are the clocks for work that has gone quiet; an ask is exempt from all
of them, and these two are its only clocks.

The completed glow (20 s on the strip), the rows' completed memory (120 s) and
the glance light (900 s) are not asks and keep their own rules.

Nothing here reads a clock: every function takes the time it should judge, so
a test moves a day without waiting a day.
"""

from __future__ import annotations

import math
import re
from enum import Enum
from typing import Final

#: An ask older than this, from a session silent for as long, "may be stale".
ASK_MAY_BE_STALE_SECONDS: Final = 6 * 3600.0
#: An unanswered stale ask this old, with no live process, is archived into
#: History as "expired unanswered".
ASK_EXPIRES_UNANSWERED_SECONDS: Final = 7 * 86_400.0

#: The settings' bounds. The mark cannot be set so low that a normal pause
#: reads as stale, and the expiry cannot come before the mark.
MIN_ASK_MAY_BE_STALE_SECONDS: Final = 900.0
MAX_ASK_MAY_BE_STALE_SECONDS: Final = 7 * 86_400.0
MIN_ASK_EXPIRES_UNANSWERED_SECONDS: Final = 86_400.0
MAX_ASK_EXPIRES_UNANSWERED_SECONDS: Final = 90 * 86_400.0

#: The ``reason`` on the SessionEnd JR-Bar writes when it closes an ask by age.
ASK_EXPIRED_REASON: Final = "jrbar_ask_expired"

#: How much slower a stale ask pulses on the strip than a current one. The
#: colour and the shape are the same; only the tempo changes.
STALE_ASK_PULSE_STRETCH: Final = 2.5


_DURATION: Final = re.compile(r"(?<![0-9A-Za-z.])(\d+(?:\.\d+)?)(ms|s)\b")


class AskStanding(str, Enum):
    """Where one unanswered ask stands against the two clocks."""

    #: Shown as an ask, with no caveat.
    CURRENT = "current"
    #: Shown as an ask, marked "may be stale", and dismissible.
    MAY_BE_STALE = "may_be_stale"
    #: Past the bound with no live process: close it and say so in History.
    EXPIRED = "expired"


def _finite(value: object) -> float | None:
    if isinstance(value, bool) or not isinstance(value, (int, float)):
        return None
    number = float(value)
    return number if math.isfinite(number) else None


def stale_after_seconds_from(hours: object) -> float:
    """The mark in seconds from the ``ask_stale_after_hours`` setting."""
    number = _finite(hours)
    if number is None:
        return ASK_MAY_BE_STALE_SECONDS
    return max(
        MIN_ASK_MAY_BE_STALE_SECONDS,
        min(MAX_ASK_MAY_BE_STALE_SECONDS, number * 3600.0),
    )


def stale_after_seconds_for(settings: object) -> float:
    """The mark for a settings object (anything without the field gets the default)."""
    return stale_after_seconds_from(getattr(settings, "ask_stale_after_hours", None))


def expire_after_seconds_for(settings: object) -> float:
    """The expiry for a settings object, never before its stale mark."""
    return expire_after_seconds_from(
        getattr(settings, "ask_expire_after_days", None),
        stale_after_seconds=stale_after_seconds_for(settings),
    )


def expire_after_seconds_from(days: object, *, stale_after_seconds: float) -> float:
    """The expiry in seconds from the ``ask_expire_after_days`` setting.

    Never before the stale mark: an ask is marked before it is closed.
    """
    number = _finite(days)
    seconds = ASK_EXPIRES_UNANSWERED_SECONDS if number is None else number * 86_400.0
    seconds = max(
        MIN_ASK_EXPIRES_UNANSWERED_SECONDS,
        min(MAX_ASK_EXPIRES_UNANSWERED_SECONDS, seconds),
    )
    return max(seconds, stale_after_seconds)


def ask_standing(
    *,
    opened_at_epoch: object,
    last_activity_epoch: object,
    now_epoch: float,
    process_alive: bool,
    stale_after_seconds: float = ASK_MAY_BE_STALE_SECONDS,
    expire_after_seconds: float = ASK_EXPIRES_UNANSWERED_SECONDS,
) -> AskStanding:
    """Judge one ask that is still unanswered.

    ``opened_at_epoch`` is when the request opened and ``last_activity_epoch``
    is the newest thing heard from its session. An ask is only ever called
    stale when BOTH are old: a session that is still talking is not abandoned,
    however long one question has stood. Unknown times read as current, so a
    missing clock never hides or marks anything.

    ``process_alive`` is the liveness sweep's affirmative answer. Only a
    session nobody can vouch for is closed by age.
    """
    opened = _finite(opened_at_epoch)
    heard = _finite(last_activity_epoch)
    now = _finite(now_epoch)
    if now is None or (opened is None and heard is None):
        return AskStanding.CURRENT
    newest = max(value for value in (opened, heard) if value is not None)
    quiet_for = now - newest
    if quiet_for < stale_after_seconds:
        return AskStanding.CURRENT
    if quiet_for >= expire_after_seconds and not process_alive:
        return AskStanding.EXPIRED
    return AskStanding.MAY_BE_STALE


def ask_dismissal_key(agent_id: object, opened_at_epoch: object) -> tuple[str, int] | None:
    """The identity a local dismissal remembers: the session row and the
    millisecond its ask opened. A later ask on the same session opens at a
    different time, so a dismissal never covers it."""
    opened = _finite(opened_at_epoch)
    if type(agent_id) is not str or not agent_id or opened is None:
        return None
    return (agent_id, int(round(opened * 1000.0)))


def ask_age_words(seconds: object) -> str:
    """An age in the words a person says: "12 minutes", "9 hours", "3 days"."""
    number = _finite(seconds)
    if number is None or number < 0.0:
        return "a while"
    if number < 60.0:
        return "under a minute"
    minutes = int(number // 60)
    if minutes < 60:
        return "1 minute" if minutes == 1 else f"{minutes} minutes"
    hours = int(number // 3600)
    if hours < 48:
        return "1 hour" if hours == 1 else f"{hours} hours"
    days = int(number // 86_400)
    return f"{days} days"


def stretch_program_durations(program: str, factor: float = STALE_ASK_PULSE_STRETCH) -> str:
    """The same light program at a slower tempo.

    Every ``<n>ms`` and ``<n>s`` duration in a program is multiplied by
    ``factor``; colours, shapes and the order of lines are untouched. A calmer
    pulse for an ask that may be stale is the same Ask light, slowed.
    """
    if not (isinstance(program, str) and factor > 0.0 and math.isfinite(factor)):
        return program

    def scaled(match: re.Match[str]) -> str:
        value = float(match.group(1)) * factor
        unit = match.group(2)
        if unit == "ms":
            return f"{int(round(value))}ms"
        text = f"{value:.3f}".rstrip("0").rstrip(".")
        return f"{text}s"

    return _DURATION.sub(scaled, program)


__all__ = [
    "ASK_EXPIRED_REASON",
    "ASK_EXPIRES_UNANSWERED_SECONDS",
    "ASK_MAY_BE_STALE_SECONDS",
    "MAX_ASK_EXPIRES_UNANSWERED_SECONDS",
    "MAX_ASK_MAY_BE_STALE_SECONDS",
    "MIN_ASK_EXPIRES_UNANSWERED_SECONDS",
    "MIN_ASK_MAY_BE_STALE_SECONDS",
    "STALE_ASK_PULSE_STRETCH",
    "AskStanding",
    "ask_age_words",
    "ask_dismissal_key",
    "ask_standing",
    "expire_after_seconds_for",
    "expire_after_seconds_from",
    "stale_after_seconds_for",
    "stale_after_seconds_from",
    "stretch_program_durations",
]
