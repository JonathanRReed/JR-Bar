"""One presence fact: is the person on a call, in a meeting, or away.

Luxafor and Kuando go quiet on calls with no setup, because they read the
call itself. JR-Bar's app already senses a live microphone and camera (the
notch's privacy dots); the daemon never heard about it, so a call without a
Focus quieted nothing and an ask chime could land in the person's AirPods
mid-sentence. The app now reports what it senses through the ``presence``
command, and this module turns that report into one fact every surface
reads the same way:

* the quiet policy gains a ``call`` source (and ``calendar`` for a meeting)
  -- by default "sounds": every light and banner stays, the sounds go;
* the escalation ladder holds at the light stage while the person is on a
  call, and skips the menu-bar pulse nobody can see while the screen is
  locked;
* celebrations hold their burst (the Screen Bar sits beside the webcam);
* the Dot may take an "On a call" role.

The fact is only as good as its reporter, so it EXPIRES: the app re-sends
while anything is live, and a report older than ``PRESENCE_TTL_SECONDS``
reads as "not on a call" -- a crashed app must not leave the Mac quiet for
good.

Pure: no clock, no I/O. Callers hand in ``now``.
"""

from __future__ import annotations

import math
from collections.abc import Mapping
from dataclasses import dataclass
from typing import Final

from .dnd_policy import DndMode

#: How long one report stands. The app re-sends at least every minute
#: while a sensor is live, so three missed reports end the call.
PRESENCE_TTL_SECONDS: Final = 180.0
#: An idle stretch this long counts as away, like a locked screen.
AWAY_IDLE_SECONDS: Final = 300.0
#: The furthest ahead a reported meeting end may lie.
MAX_MEETING_SECONDS: Final = 12 * 60 * 60.0

QUIET_OFF: Final = "off"
#: Lights and banners stay; only the sounds go. The busylight default.
QUIET_SOUNDS: Final = "sounds"
PRESENCE_QUIET_CHOICES: Final = (QUIET_OFF, QUIET_SOUNDS, *(mode.value for mode in DndMode))
DEFAULT_CALL_QUIET_MODE: Final = QUIET_SOUNDS
DEFAULT_MEETING_QUIET_MODE: Final = QUIET_OFF

#: The escalation stage a call holds at: the light ramp, never the
#: menu-bar pulse or the chime.
CALL_ESCALATION_CEILING: Final = 1


def normalize_presence_quiet_mode(value: object, default: str = DEFAULT_CALL_QUIET_MODE) -> str:
    text = str(value or "").strip().lower()
    return text if text in PRESENCE_QUIET_CHOICES else default


def _finite(value: object) -> float | None:
    if isinstance(value, bool) or not isinstance(value, (int, float)):
        return None
    number = float(value)
    return number if math.isfinite(number) else None


@dataclass(frozen=True, slots=True)
class PresenceFacts:
    """One report from the app. Every field is what the app sensed; the
    derived questions (``on_call``, ``away``) are asked with a clock."""

    received_at: float
    mic: bool = False
    camera: bool = False
    screen_shared: bool = False
    locked: bool = False
    idle_seconds: float | None = None
    #: INFocusStatusCenter's ``isFocused``, from the app's own grant -- a
    #: hint the daemon uses when it cannot read Focus itself.
    focus: bool | None = None
    #: When a calendar meeting in progress ends, or None.
    meeting_until: float | None = None
    #: When the current call began, carried across reports.
    call_since: float | None = None

    def fresh(self, now: float) -> bool:
        return 0.0 <= now - self.received_at < PRESENCE_TTL_SECONDS

    def expires_at(self) -> float:
        return self.received_at + PRESENCE_TTL_SECONDS

    @property
    def sensing_call(self) -> bool:
        return self.mic or self.camera or self.screen_shared

    def on_call(self, now: float) -> bool:
        return self.fresh(now) and self.sensing_call

    def in_meeting(self, now: float) -> bool:
        # The meeting carries its own end; it does not need the app alive.
        return self.meeting_until is not None and self.received_at <= now < self.meeting_until

    def away(self, now: float) -> bool:
        if not self.fresh(now):
            return False
        return self.locked or (
            self.idle_seconds is not None and self.idle_seconds >= AWAY_IDLE_SECONDS
        )

    def focus_hint(self, now: float) -> bool | None:
        return self.focus if self.fresh(now) else None


def parse_presence(
    args: Mapping[str, object],
    *,
    now: float,
    previous: PresenceFacts | None = None,
) -> PresenceFacts:
    """The ``presence`` command's arguments as facts. Unknown keys are
    ignored; a key that is present with the wrong type is a ``ValueError``
    (a reporter bug should be loud, not read as "not on a call")."""

    def flag(name: str) -> bool:
        value = args.get(name, False)
        if value is None:
            return False
        if type(value) is not bool:
            raise ValueError(f"{name} must be a boolean")
        return value

    mic = flag("mic")
    camera = flag("camera")
    screen_shared = flag("screen_shared")
    locked = flag("locked")
    idle = args.get("idle_seconds")
    idle_seconds = None
    if idle is not None:
        idle_seconds = _finite(idle)
        if idle_seconds is None or idle_seconds < 0.0:
            raise ValueError("idle_seconds must be a non-negative number")
    focus = args.get("focus")
    if focus is not None and type(focus) is not bool:
        raise ValueError("focus must be a boolean")
    meeting = args.get("meeting_until")
    meeting_until = None
    if meeting is not None:
        meeting_until = _finite(meeting)
        if meeting_until is None:
            raise ValueError("meeting_until must be an epoch")
        if meeting_until <= now:
            meeting_until = None
        elif meeting_until - now > MAX_MEETING_SECONDS:
            raise ValueError("meeting_until lies too far ahead")
    sensing = mic or camera or screen_shared
    call_since = None
    if sensing:
        carried = previous.call_since if previous is not None and previous.on_call(now) else None
        call_since = carried if carried is not None else now
    return PresenceFacts(
        received_at=now,
        mic=mic,
        camera=camera,
        screen_shared=screen_shared,
        locked=locked,
        idle_seconds=idle_seconds,
        focus=focus,
        meeting_until=meeting_until,
        call_since=call_since,
    )


def call_quiet_active(facts: PresenceFacts | None, *, now: float, call_quiet_mode: str) -> bool:
    return (
        facts is not None
        and facts.on_call(now)
        and normalize_presence_quiet_mode(call_quiet_mode) != QUIET_OFF
    )


def presence_escalation_ceiling(
    facts: PresenceFacts | None,
    *,
    now: float,
    call_quiet_mode: str,
) -> int | None:
    """The stage a live call caps escalation at, or None for no cap."""
    if call_quiet_active(facts, now=now, call_quiet_mode=call_quiet_mode):
        return CALL_ESCALATION_CEILING
    return None


def presence_document(
    facts: PresenceFacts | None,
    *,
    now: float,
    call_quiet_mode: str,
    meeting_quiet_mode: str,
) -> dict[str, object]:
    """``state.presence``: the fact every surface reads the same way."""
    on_call = bool(facts is not None and facts.on_call(now))
    in_meeting = bool(facts is not None and facts.in_meeting(now))
    call_mode = normalize_presence_quiet_mode(call_quiet_mode, DEFAULT_CALL_QUIET_MODE)
    meeting_mode = normalize_presence_quiet_mode(meeting_quiet_mode, DEFAULT_MEETING_QUIET_MODE)
    quiet = (
        call_mode
        if on_call and call_mode != QUIET_OFF
        else meeting_mode
        if in_meeting and meeting_mode != QUIET_OFF
        else QUIET_OFF
    )
    fresh = bool(facts is not None and facts.fresh(now))
    return {
        "on_call": on_call,
        "mic": bool(fresh and facts is not None and facts.mic),
        "camera": bool(fresh and facts is not None and facts.camera),
        "screen_shared": bool(fresh and facts is not None and facts.screen_shared),
        "since": facts.call_since if on_call and facts is not None else None,
        "in_meeting": in_meeting,
        "meeting_until": facts.meeting_until if in_meeting and facts is not None else None,
        "away": bool(facts is not None and facts.away(now)),
        # No report time: the app renews while a sensor is live, and a
        # stamp that moved every minute would rebroadcast an unchanged
        # state that often. ``fresh`` is the fact a reader needs.
        "fresh": fresh,
        "quiet": quiet,
        "escalation_ceiling": (
            CALL_ESCALATION_CEILING
            if call_quiet_active(facts, now=now, call_quiet_mode=call_mode)
            else None
        ),
        # Confetti and every other celebration hold their burst on a call:
        # a party on the edge of the frame is the last thing a call needs.
        "celebrations_held": on_call,
    }


__all__ = [
    "AWAY_IDLE_SECONDS",
    "CALL_ESCALATION_CEILING",
    "DEFAULT_CALL_QUIET_MODE",
    "DEFAULT_MEETING_QUIET_MODE",
    "PRESENCE_QUIET_CHOICES",
    "PRESENCE_TTL_SECONDS",
    "QUIET_OFF",
    "QUIET_SOUNDS",
    "PresenceFacts",
    "call_quiet_active",
    "normalize_presence_quiet_mode",
    "parse_presence",
    "presence_document",
    "presence_escalation_ceiling",
]
