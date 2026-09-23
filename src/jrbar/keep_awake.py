from __future__ import annotations

import json
import math
import os
import subprocess
import threading
import time
from collections.abc import Callable, Iterable, Mapping, Sequence
from dataclasses import dataclass
from pathlib import Path

from .device_writer import KNOWN_LED_FILE_NAMES
from .models import AgentMode
from .power_policy import configure_caffeinate_display_assertion

AWAKE_GRACE_SECONDS = 300.0
SD_STATUS_READ_SECONDS = 60.0
KEEPALIVE_FILE_NAME = "keepalive"
STATUS_FILE_NAME = KEEPALIVE_FILE_NAME
# -t bounds the assertion by TIME as well as by process life, matching
# the closed-lid hold in lid_sleep.py: the sync tick re-spawns the hold
# while work continues, and a hold whose renewals stopped (App Nap with
# the display asleep, a wedge, a bootout) must die on its own instead of
# burning a closed laptop all night.
CAFFEINATE_SELF_EXPIRE_SECONDS = 1800
# -i idle sleep, -m disk sleep, -s system sleep (AC): the machine stays
# up for the AGENTS. No -d and no -u -- the display may sleep and the
# hold must never count as user activity; -dimsu kept the SCREEN awake
# all night for a background monitor.
CAFFEINATE_COMMAND = (
    "/usr/bin/caffeinate",
    "-ims",
    "-t",
    str(CAFFEINATE_SELF_EXPIRE_SECONDS),
)

#: The modes that hold the machine awake in their own right.
WORK_MODES = frozenset(
    {AgentMode.WORKING, AgentMode.TOOL_RUNNING, AgentMode.LONG_TASK_PROGRESS}
)


def battery_yields_hold(snapshot, settings) -> bool:
    """True when the battery is low enough that the hold must yield --
    judged DIRECTLY from the snapshot and threshold, never through
    low_power_active, which is gated on the charge-reminder DISPLAY
    toggle (regression review: disabling that cosmetic reminder used to
    disable the safety yield with it)."""
    if snapshot is None or not getattr(snapshot, "battery_present", False):
        return False
    if getattr(snapshot, "is_plugged", True):
        return False
    threshold = float(getattr(settings, "low_battery_threshold_percent", 5.0))
    return float(getattr(snapshot, "percent", 100.0)) <= threshold


# --- The manual lease ---------------------------------------------------
#
# The agent hold above answers "is anyone working"; a lease answers "the
# person asked". It is the one daemon-owned hold every surface shares --
# the notch chip, a deck key, a CLI verb -- so there is exactly one
# assertion and one release rule, and state.power can say why the Mac is
# awake. Three shapes:
#
#   duration    -- until an epoch (for an hour, until 8 AM)
#   agents      -- until the named sessions finish, which no keep-awake app
#                  can offer because none of them knows what an agent is
#   indefinite  -- until the person turns it off
#
# A lease never outlives its own bound, and it YIELDS (not ends) to heat and
# to a dying battery: the countdown keeps running while it is suspended,
# and it picks up again when the Mac cools or is plugged in.

LEASE_DURATION = "duration"
LEASE_AGENTS = "agents"
LEASE_INDEFINITE = "indefinite"
LEASE_KINDS = (LEASE_DURATION, LEASE_AGENTS, LEASE_INDEFINITE)
#: The longest duration a lease may ask for. "Until 8 AM" from late
#: evening fits; a week-long hold is a forgotten one.
MAX_LEASE_SECONDS = 24 * 60 * 60.0
#: "Until these agents finish" is bounded too. An agent that wedges in a
#: tool call never finishes, and a closed laptop must not stay up all of
#: the next day waiting for it.
AGENT_LEASE_BACKSTOP_SECONDS = 12 * 60 * 60.0
MAX_LEASE_SESSIONS = 32
MAX_LEASE_SESSION_ID_LENGTH = 256
MAX_LEASE_SOURCE_LENGTH = 32
LEASE_FILE_NAME = "keep-awake-lease.json"

#: A session the "agents" lease still waits on: working, or blocked on the
#: person. An ask is not a finish -- the run is not over, and the answer the
#: person gives in the morning must find the agent still there.
LEASE_PENDING_MODES = WORK_MODES | {AgentMode.WAITING_FOR_INPUT}

LEASE_END_EXPIRED = "expired"
LEASE_END_FINISHED = "finished"
LEASE_END_CANCELLED = "cancelled"
LEASE_END_REPLACED = "replaced"

HOLD_STATE_OFF = "off"
HOLD_STATE_AGENTS = "agents"
HOLD_STATE_MANUAL = "manual"

SUSPENDED_THERMAL = "thermal"
SUSPENDED_BATTERY = "battery"


class LeaseRefusedError(ValueError):
    """A well-formed request the daemon will not honour right now."""


def _finite(value: object) -> float | None:
    if isinstance(value, bool) or not isinstance(value, (int, float)):
        return None
    number = float(value)
    return number if math.isfinite(number) else None


def _bounded_word(value: object, limit: int) -> str | None:
    if type(value) is not str:
        return None
    text = value.strip()
    if not text or len(text) > limit or not text.isprintable():
        return None
    return text


@dataclass(frozen=True, slots=True)
class AwakeLease:
    """One explicit request to keep the Mac awake."""

    kind: str
    started_at: float
    until: float | None
    sessions: tuple[str, ...] = ()
    display: bool = False
    source: str = "app"

    def __post_init__(self) -> None:
        if self.kind not in LEASE_KINDS:
            raise ValueError("unknown keep-awake lease kind")
        started = _finite(self.started_at)
        if started is None or started < 0.0:
            raise ValueError("lease start must be a finite epoch")
        object.__setattr__(self, "started_at", started)
        if self.kind == LEASE_INDEFINITE:
            if self.until is not None:
                raise ValueError("an indefinite lease has no end")
        else:
            until = _finite(self.until)
            if until is None or until <= started:
                raise ValueError("lease end must follow its start")
            bound = (
                AGENT_LEASE_BACKSTOP_SECONDS
                if self.kind == LEASE_AGENTS
                else MAX_LEASE_SECONDS
            )
            if until - started > bound + 1.0:
                raise ValueError("lease exceeds its bounded duration")
            object.__setattr__(self, "until", until)
        if type(self.sessions) is not tuple or not all(
            _bounded_word(item, MAX_LEASE_SESSION_ID_LENGTH) == item
            for item in self.sessions
        ):
            raise ValueError("lease sessions must be bounded ids")
        if len(self.sessions) > MAX_LEASE_SESSIONS:
            raise ValueError("lease names too many sessions")
        if self.kind == LEASE_AGENTS and not self.sessions:
            raise ValueError("an agents lease must name the sessions it waits on")
        if self.kind != LEASE_AGENTS and self.sessions:
            raise ValueError("only an agents lease names sessions")
        if type(self.display) is not bool:
            raise ValueError("lease display flag must be a boolean")
        if _bounded_word(self.source, MAX_LEASE_SOURCE_LENGTH) != self.source:
            raise ValueError("lease source must be a short word")

    def to_dict(self) -> dict[str, object]:
        return {
            "kind": self.kind,
            "started_at": self.started_at,
            "until": self.until,
            "sessions": list(self.sessions),
            "display": self.display,
            "source": self.source,
        }

    @classmethod
    def from_dict(cls, raw: object) -> AwakeLease | None:
        """A stored lease, or None for anything this build cannot trust."""
        if not isinstance(raw, Mapping):
            return None
        sessions = raw.get("sessions") or ()
        if isinstance(sessions, (str, bytes)) or not isinstance(sessions, Iterable):
            return None
        try:
            return cls(
                kind=raw.get("kind"),  # type: ignore[arg-type]
                started_at=raw.get("started_at"),  # type: ignore[arg-type]
                until=raw.get("until"),  # type: ignore[arg-type]
                sessions=tuple(sessions),
                display=raw.get("display", False),  # type: ignore[arg-type]
                source=raw.get("source", "app"),  # type: ignore[arg-type]
            )
        except (TypeError, ValueError):
            return None


def lease_verdict(
    lease: AwakeLease,
    *,
    now: float,
    pending_ids: frozenset[str] | None,
) -> str | None:
    """None while ``lease`` still holds, else the reason it is over.

    ``pending_ids`` None means nobody has observed the sessions yet -- an
    agents lease never ends on a missing observation, only on a real one
    that shows none of its sessions still pending.
    """
    if lease.until is not None and now >= lease.until:
        return LEASE_END_EXPIRED
    if (
        lease.kind == LEASE_AGENTS
        and pending_ids is not None
        and not pending_ids.intersection(lease.sessions)
    ):
        return LEASE_END_FINISHED
    return None


def next_local_time(clock: str, *, now: float, zone=None) -> float:
    """The next occurrence of a local ``HH:MM`` after ``now``, as an epoch --
    "until 8 AM" said the way a person says it, resolved in the Mac's own
    zone (a daylight-saving night is not a fixed 24 hours)."""
    from datetime import datetime, timedelta
    from datetime import time as wall_time

    from .local_time_boundary import resolve_local_epoch, system_local_timezone

    text = str(clock).strip()
    parts = text.split(":")
    if len(parts) != 2 or not all(part.isdigit() and len(part) == 2 for part in parts):
        raise ValueError("until_time must be HH:MM")
    hour, minute = int(parts[0]), int(parts[1])
    if hour > 23 or minute > 59:
        raise ValueError("until_time must be HH:MM")
    local_zone = zone or system_local_timezone(now)
    today = datetime.fromtimestamp(now, local_zone).date()
    for offset in (0, 1, 2):
        epoch = resolve_local_epoch(
            today + timedelta(days=offset), wall_time(hour, minute), local_zone
        )
        if epoch is not None and epoch > now:
            return epoch
    raise ValueError("until_time could not be resolved")


def lease_from_args(
    args: Mapping[str, object],
    *,
    now: float,
    pending_ids: frozenset[str],
    zone=None,
) -> AwakeLease:
    """The ``hold_awake`` command's arguments as a lease.

    Exactly one of ``seconds``, ``until``, ``until_time`` (a local ``HH:MM``,
    the next one), ``until_agents_idle`` or ``indefinite`` says how long.
    ``sessions`` narrows "until the agents finish" to named sessions; without
    it the lease waits on every session working right now. ``ValueError`` is
    a malformed request; ``LeaseRefusedError`` is a well-formed one that
    cannot be honoured (there is nothing working to wait for).
    """
    display = args.get("display", False)
    if type(display) is not bool:
        raise ValueError("display must be a boolean")
    source = args.get("source", "app")
    if _bounded_word(source, MAX_LEASE_SOURCE_LENGTH) is None:
        raise ValueError("source must be a short word")
    source = str(source).strip()
    chosen = [
        name
        for name in ("seconds", "until", "until_time", "until_agents_idle", "indefinite")
        if args.get(name) not in (None, False)
    ]
    if len(chosen) != 1:
        raise ValueError(
            "give exactly one of seconds, until, until_time, until_agents_idle or indefinite"
        )
    shape = chosen[0]
    if shape in ("seconds", "until", "until_time"):
        if shape == "until_time":
            if type(args.get("until_time")) is not str:
                raise ValueError("until_time must be HH:MM")
            until = next_local_time(str(args.get("until_time")), now=now, zone=zone)
        else:
            raw = _finite(args.get(shape))
            if raw is None:
                raise ValueError(f"{shape} must be a number")
            until = now + raw if shape == "seconds" else raw
        if until <= now:
            raise ValueError(f"{shape} must lie in the future")
        if until - now > MAX_LEASE_SECONDS:
            raise ValueError("a keep-awake lease lasts at most 24 hours")
        return AwakeLease(LEASE_DURATION, now, until, display=display, source=source)
    if shape == "indefinite":
        if args.get("indefinite") is not True:
            raise ValueError("indefinite must be true")
        return AwakeLease(LEASE_INDEFINITE, now, None, display=display, source=source)
    if args.get("until_agents_idle") is not True:
        raise ValueError("until_agents_idle must be true")
    named = args.get("sessions")
    if named is None:
        sessions = tuple(sorted(pending_ids))
    else:
        if isinstance(named, (str, bytes)) or not isinstance(named, Iterable):
            raise ValueError("sessions must be a list of session ids")
        wanted = []
        for item in named:
            word = _bounded_word(item, MAX_LEASE_SESSION_ID_LENGTH)
            if word is None:
                raise ValueError("sessions must be a list of session ids")
            wanted.append(word)
        sessions = tuple(sorted(set(wanted) & pending_ids))
    if not sessions:
        raise LeaseRefusedError("No agent is working right now.")
    if len(sessions) > MAX_LEASE_SESSIONS:
        sessions = sessions[:MAX_LEASE_SESSIONS]
    return AwakeLease(
        LEASE_AGENTS,
        now,
        now + AGENT_LEASE_BACKSTOP_SECONDS,
        sessions,
        display=display,
        source=source,
    )


# --- The thermal governor ----------------------------------------------
#
# ProcessInfo.thermalState: 0 nominal, 1 fair, 2 serious, 3 critical. A
# hold is released at "serious" while the lid is closed -- a laptop in a bag
# has nowhere to shed that heat -- and only at "critical" with the lid open,
# where the person is at the desk and the fans are doing their job. It comes
# back after the Mac has sat at fair or better for a while, so a hold does
# not flap on a borderline reading.

THERMAL_NOMINAL = 0
THERMAL_FAIR = 1
THERMAL_SERIOUS = 2
THERMAL_CRITICAL = 3
THERMAL_WORDS = ("nominal", "fair", "serious", "critical")
THERMAL_RESUME_SECONDS = 300.0


def read_thermal_state() -> int | None:
    """``NSProcessInfo.thermalState`` as 0-3, or None when unreadable."""
    try:
        from Foundation import NSProcessInfo

        value = int(NSProcessInfo.processInfo().thermalState())
    except Exception:
        return None
    return value if THERMAL_NOMINAL <= value <= THERMAL_CRITICAL else None


def thermal_word(state: int | None) -> str | None:
    if state is None or not THERMAL_NOMINAL <= state <= THERMAL_CRITICAL:
        return None
    return THERMAL_WORDS[state]


class ThermalGovernor:
    """Whether heat says every hold must let go right now."""

    def __init__(self, *, resume_after_seconds: float = THERMAL_RESUME_SECONDS) -> None:
        self.resume_after_seconds = max(0.0, float(resume_after_seconds))
        self.suspended = False
        self.cool_since: float | None = None

    def observe(self, state: int | None, *, lid_closed: bool | None, now: float) -> bool:
        if state is None:
            # An unreadable sensor changes nothing: it neither starts nor
            # ends a release.
            return self.suspended
        limit = THERMAL_SERIOUS if lid_closed is True else THERMAL_CRITICAL
        if state >= limit:
            self.suspended = True
            self.cool_since = None
        elif self.suspended:
            if state <= THERMAL_FAIR:
                if self.cool_since is None:
                    self.cool_since = now
                if now - self.cool_since >= self.resume_after_seconds:
                    self.suspended = False
                    self.cool_since = None
            else:
                self.cool_since = None
        return self.suspended


# --- The power log --------------------------------------------------------
#
# Why the Mac stopped being held awake, in a form History can list: "let go:
# Mac too hot", "ran 2 h 40 m with the lid closed", "put the Mac to sleep".
# Kept apart from the activity ledger on purpose -- that ledger is about
# sessions, and an older build that met a power row there would refuse the
# whole file. Bounded and content-free like the ledger.

POWER_LOG_FILE_NAME = "power-log.json"
MAX_POWER_EVENTS = 64
MAX_POWER_LOG_BYTES = 32 * 1024

POWER_LEASE_STARTED = "lease_started"
POWER_LEASE_ENDED = "lease_ended"
POWER_SUSPENDED = "suspended"
POWER_RESUMED = "resumed"
POWER_LID_HOLD_ENDED = "lid_hold_ended"
POWER_SLEPT = "slept"
POWER_EVENT_KINDS = (
    POWER_LEASE_STARTED,
    POWER_LEASE_ENDED,
    POWER_SUSPENDED,
    POWER_RESUMED,
    POWER_LID_HOLD_ENDED,
    POWER_SLEPT,
)
MAX_POWER_REASON_LENGTH = 32

#: What History says for each kind worth reading later. Starting a lease
#: and resuming after a release are the person's own doing or a return to
#: normal -- the log keeps them for state, History leaves them out.
_POWER_HISTORY_LABELS = {
    POWER_LEASE_ENDED: "Keep awake ended",
    POWER_SUSPENDED: "Keep awake let go",
    POWER_LID_HOLD_ENDED: "Held awake with the lid closed",
    POWER_SLEPT: "Put the Mac to sleep",
}
_POWER_REASON_WORDS = {
    SUSPENDED_THERMAL: "Mac too hot",
    SUSPENDED_BATTERY: "battery low",
    LEASE_END_EXPIRED: "time up",
    LEASE_END_FINISHED: "agents finished",
    "agents_idle": "agents finished",
    "policy": "setting changed",
}


@dataclass(frozen=True, slots=True)
class PowerEvent:
    at: float
    kind: str
    reason: str | None = None
    duration: float | None = None

    def __post_init__(self) -> None:
        at = _finite(self.at)
        if at is None or at < 0.0:
            raise ValueError("power event time must be a finite epoch")
        object.__setattr__(self, "at", at)
        if self.kind not in POWER_EVENT_KINDS:
            raise ValueError("unknown power event kind")
        if self.reason is not None and (
            _bounded_word(self.reason, MAX_POWER_REASON_LENGTH) != self.reason
        ):
            raise ValueError("power event reason must be a short word")
        if self.duration is not None:
            duration = _finite(self.duration)
            if duration is None or duration < 0.0:
                raise ValueError("power event duration must be non-negative")
            object.__setattr__(self, "duration", duration)

    def to_dict(self) -> dict[str, object]:
        return {
            "at": self.at,
            "kind": self.kind,
            "reason": self.reason,
            "duration": self.duration,
        }


class PowerLog:
    """The newest ``limit`` power events, optionally persisted."""

    def __init__(
        self,
        path: Path | None = None,
        *,
        limit: int = MAX_POWER_EVENTS,
        clock: Callable[[], float] = time.time,
    ) -> None:
        self.path = path
        self.limit = max(1, int(limit))
        self.clock = clock
        self.events: tuple[PowerEvent, ...] = ()
        self.last_error: str | None = None

    def load(self) -> None:
        if self.path is None:
            return
        from .private_io import read_private_text

        try:
            raw = json.loads(read_private_text(self.path, max_bytes=MAX_POWER_LOG_BYTES))
        except FileNotFoundError:
            return
        except (OSError, ValueError) as exc:
            self.last_error = f"power log unreadable: {exc.__class__.__name__}"
            return
        rows = raw.get("events") if isinstance(raw, dict) else None
        events: list[PowerEvent] = []
        for row in rows if isinstance(rows, list) else ():
            if not isinstance(row, dict):
                continue
            try:
                events.append(
                    PowerEvent(
                        row.get("at"),  # type: ignore[arg-type]
                        row.get("kind"),  # type: ignore[arg-type]
                        row.get("reason"),  # type: ignore[arg-type]
                        row.get("duration"),  # type: ignore[arg-type]
                    )
                )
            except (TypeError, ValueError):
                continue
        events.sort(key=lambda event: event.at)
        self.events = tuple(events[-self.limit :])

    def save(self) -> None:
        if self.path is None:
            return
        from .private_io import atomic_private_write

        payload = json.dumps(
            {"version": 1, "events": [event.to_dict() for event in self.events]},
            allow_nan=False,
            separators=(",", ":"),
        )
        try:
            atomic_private_write(self.path, payload)
            self.last_error = None
        except (OSError, ValueError) as exc:
            self.last_error = f"power log not saved: {exc.__class__.__name__}"

    def record(
        self,
        kind: str,
        *,
        reason: str | None = None,
        duration: float | None = None,
        at: float | None = None,
    ) -> PowerEvent:
        event = PowerEvent(self.clock() if at is None else at, kind, reason, duration)
        self.events = (*self.events, event)[-self.limit :]
        self.save()
        return event

    def last(self, *kinds: str) -> PowerEvent | None:
        for event in reversed(self.events):
            if not kinds or event.kind in kinds:
                return event
        return None

    def history_rows(
        self,
        *,
        since: float | None = None,
        last_seen: float = 0.0,
    ) -> list[dict[str, object]]:
        """``list_history`` rows (kind ``power``) for the events worth a
        line in History, newest first."""
        rows: list[dict[str, object]] = []
        for event in reversed(self.events):
            label = _POWER_HISTORY_LABELS.get(event.kind)
            if label is None or (since is not None and event.at < since):
                continue
            if event.kind == POWER_LEASE_ENDED and event.reason in (
                LEASE_END_CANCELLED,
                LEASE_END_REPLACED,
            ):
                continue
            rows.append(
                {
                    "at": event.at,
                    "kind": "power",
                    "provider": None,
                    "session": None,
                    "label": label,
                    "detail": _POWER_REASON_WORDS.get(event.reason or "", event.reason),
                    "duration": event.duration,
                    "unseen": event.at > float(last_seen or 0.0),
                }
            )
        return rows


def merge_history_rows(
    rows: list[dict[str, object]],
    power_rows: list[dict[str, object]],
    *,
    limit: int,
) -> list[dict[str, object]]:
    """Session rows and power rows as one newest-first list, within limit."""
    merged = [*rows, *power_rows]
    merged.sort(key=lambda row: float(row.get("at") or 0.0), reverse=True)  # type: ignore[arg-type]
    return merged[: max(0, int(limit))]


class KeepAwakeController:
    def __init__(
        self,
        *,
        enabled: bool = True,
        grace_seconds: float = AWAKE_GRACE_SECONDS,
        status_read_seconds: float = SD_STATUS_READ_SECONDS,
        command: Sequence[str] = CAFFEINATE_COMMAND,
        process_factory: Callable[..., object] | None = None,
        status_reader: Callable[[Path], None] | None = None,
        status_read_async: bool = True,
        watch_current_process: bool = True,
        keep_display_awake: bool = False,
    ) -> None:
        self.enabled = enabled
        self.grace_seconds = grace_seconds
        self.status_read_seconds = status_read_seconds
        self.command = tuple(command)
        self.process_factory = process_factory or subprocess.Popen
        self.status_reader = status_reader or touch_keepalive_file
        self.status_read_async = status_read_async
        self.watch_current_process = watch_current_process
        self.keep_display_awake = bool(keep_display_awake)
        self.process = None
        self.last_mode: AgentMode | None = None
        self.holding_requested = False
        self.grace_until_monotonic: float | None = None
        self.last_error: str | None = None
        self.last_status_read_monotonic_by_path: dict[Path, float] = {}
        self.last_status_error: str | None = None
        self.status_read_in_flight_by_path: set[Path] = set()
        # The daemon-owned lease and the environment it yields to. Nothing
        # below changes behaviour until someone starts a lease or reports
        # the environment (observe_environment): the menu-bar app that
        # never does keeps the agent hold exactly as it was.
        self.wall_clock: Callable[[], float] = time.time
        self.lease: AwakeLease | None = None
        self.lease_path: Path | None = None
        self.power_log: PowerLog | None = None
        self.thermal = ThermalGovernor()
        self.thermal_state: int | None = None
        self.lid_closed: bool | None = None
        self.battery_floor = False
        self.pending_ids: frozenset[str] | None = None
        self.working_count = 0
        #: The agents alone want the Mac awake (working, or in the grace).
        self.agent_demand = False
        #: Why a demanded hold is yielding right now, or None.
        self.suspension: str | None = None
        self._process_display: bool | None = None
        self._grace_epoch: tuple[float, float] | None = None

    def set_enabled(self, enabled: bool) -> None:
        if self.enabled == enabled:
            return
        self.enabled = enabled
        if not enabled:
            self.release()
            self.holding_requested = False
            self.grace_until_monotonic = None
            self.last_status_error = None
            self.last_status_read_monotonic_by_path.clear()
            self.status_read_in_flight_by_path.clear()

    def set_grace_seconds(self, seconds: float) -> None:
        """Live-adjustable -- called every poll with the current setting
        value (see StatusBarController.sync_keep_awake) rather than fixed
        once at construction, so changing it in Settings takes effect on
        the very next tick instead of needing a restart."""
        self.grace_seconds = max(0.0, float(seconds))

    def set_keep_display_awake(self, enabled: bool) -> None:
        enabled = bool(enabled)
        if self.keep_display_awake == enabled:
            return
        self.keep_display_awake = enabled
        was_running = self.process_running()
        if was_running:
            self._terminate_process()
            if self.holding_requested and (self.enabled or self.lease is not None):
                self.ensure_awake()

    def update(
        self,
        mode: AgentMode,
        *,
        now: float | None = None,
        on_battery: bool | None = None,
        hold_on_battery: bool = True,
    ) -> bool:
        current = time.monotonic() if now is None else now
        should_hold = self.should_hold_for_mode(mode, current)
        self.agent_demand = should_hold
        self.last_mode = mode
        lease_holds = self._lease_holds()
        suspension = self._observe_suspension(current)
        # "Somebody wants the Mac awake": the agents or the person, unless
        # heat or a dying battery says every hold must let go. The closed-lid
        # hold reads this, so a yield here reaches a shut laptop too.
        self.holding_requested = (should_hold or lease_holds) and suspension is None

        # Only a POSITIVE battery reading may suppress the hold: an
        # unknown power state must never silently release keep-awake and
        # let a lid-closed agent sleep mid-task. The person's own lease is
        # not the agents' hold -- "keep awake on battery" is about agents,
        # and only the low-battery floor (a suspension) overrides a lease.
        battery_blocked = on_battery is True and not hold_on_battery
        agent_hold = self.enabled and should_hold and not battery_blocked

        if not (agent_hold or lease_holds) or suspension is not None:
            self.release()
            return False

        if self.process_running() and self._process_display != self.effective_display():
            self._terminate_process()
        self.ensure_awake()
        return self.process_running()

    # -- the lease -------------------------------------------------------

    def attach_store(self, state_dir: Path, *, power_log: PowerLog | None = None) -> None:
        """Persist the lease under ``state_dir`` and restore one that is
        still in force, so a daemon restart does not drop the person's
        "until 8 AM"."""
        self.lease_path = Path(state_dir) / LEASE_FILE_NAME
        if power_log is not None:
            self.power_log = power_log
        if self.lease is not None:
            return
        from .private_io import read_private_text

        try:
            raw = json.loads(read_private_text(self.lease_path, max_bytes=4096))
        except (OSError, ValueError):
            return
        lease = AwakeLease.from_dict(raw)
        if lease is None or lease_verdict(
            lease, now=self.wall_clock(), pending_ids=None
        ) is not None:
            self._save_lease(None)
            return
        self.lease = lease

    def start_lease(self, lease: AwakeLease) -> AwakeLease:
        if type(lease) is not AwakeLease:
            raise ValueError("a keep-awake lease must be an AwakeLease")
        if self.lease is not None:
            self._log(POWER_LEASE_ENDED, reason=LEASE_END_REPLACED)
        self.lease = lease
        self._save_lease(lease)
        self._log(POWER_LEASE_STARTED, reason=lease.kind)
        return lease

    def end_lease(self, reason: str = LEASE_END_CANCELLED) -> bool:
        lease = self.lease
        if lease is None:
            return False
        self.lease = None
        self._save_lease(None)
        self._log(
            POWER_LEASE_ENDED,
            reason=reason,
            duration=max(0.0, self.wall_clock() - lease.started_at),
        )
        return True

    def observe_environment(
        self,
        *,
        pending_ids: Iterable[str] | None = None,
        working_count: int = 0,
        battery_floor: bool = False,
        thermal_state: int | None = None,
        lid_closed: bool | None = None,
    ) -> None:
        """What the hold yields to, read by the daemon before each sync:
        which sessions are still running (for "until these agents finish"),
        whether the battery is at its floor, how hot the Mac is, and
        whether the lid is shut (heat is judged more strictly then)."""
        self.pending_ids = None if pending_ids is None else frozenset(pending_ids)
        self.working_count = max(0, int(working_count))
        self.battery_floor = bool(battery_floor)
        self.thermal_state = thermal_state
        self.lid_closed = lid_closed

    def effective_display(self) -> bool:
        lease = self.lease
        return self.keep_display_awake or bool(lease is not None and lease.display)

    def _lease_holds(self) -> bool:
        lease = self.lease
        if lease is None:
            return False
        verdict = lease_verdict(lease, now=self.wall_clock(), pending_ids=self.pending_ids)
        if verdict is None:
            return True
        self.end_lease(verdict)
        return False

    def _observe_suspension(self, now: float) -> str | None:
        hot = self.thermal.observe(self.thermal_state, lid_closed=self.lid_closed, now=now)
        suspension = (
            SUSPENDED_THERMAL
            if hot
            else SUSPENDED_BATTERY
            if self.battery_floor
            else None
        )
        if suspension != self.suspension:
            # Only a yield that actually took a hold away is news; heat on
            # an idle Mac with nothing held is not.
            if suspension is not None and (self.agent_demand or self.lease is not None):
                self._log(POWER_SUSPENDED, reason=suspension)
            elif suspension is None and self.suspension is not None:
                self._log(POWER_RESUMED, reason=self.suspension)
            self.suspension = suspension
        return suspension

    def _log(self, kind: str, *, reason: str | None = None, duration: float | None = None) -> None:
        log = self.power_log
        if log is None:
            return
        try:
            log.record(kind, reason=reason, duration=duration)
        except ValueError:
            pass

    def _save_lease(self, lease: AwakeLease | None) -> None:
        path = self.lease_path
        if path is None:
            return
        from .private_io import atomic_private_write

        try:
            if lease is None:
                path.unlink(missing_ok=True)
            else:
                atomic_private_write(path, json.dumps(lease.to_dict(), allow_nan=False))
        except (OSError, ValueError) as exc:
            self.last_error = f"lease not saved: {exc.__class__.__name__}"

    def hold_state(self) -> str:
        """The three words the chip draws: ``manual`` while a lease is in
        force, ``agents`` while the agents hold the Mac, else ``off``."""
        if self.lease is not None:
            return HOLD_STATE_MANUAL
        if self.enabled and self.agent_demand:
            return HOLD_STATE_AGENTS
        return HOLD_STATE_OFF

    def hold_document(self, *, now_monotonic: float | None = None) -> dict[str, object]:
        """``state.power.hold``: why the Mac is (or is not) held awake."""
        state = self.hold_state()
        grace_until = None
        deadline = self.grace_until_monotonic
        if state == HOLD_STATE_AGENTS and deadline is not None:
            current = time.monotonic() if now_monotonic is None else now_monotonic
            if current < deadline:
                # Converted once per grace window: re-deriving the epoch on
                # every build jitters it by microseconds, and a state
                # document that never compares equal is broadcast on every
                # refresh for nothing.
                cached = self._grace_epoch
                if cached is None or cached[0] != deadline:
                    cached = (deadline, round(self.wall_clock() + (deadline - current), 3))
                    self._grace_epoch = cached
                grace_until = cached[1]
        return {
            "state": state,
            "agents": self.working_count if state == HOLD_STATE_AGENTS else 0,
            "active": self.process_running(),
            "display": self.effective_display(),
            "grace_until": grace_until,
            "lease": None if self.lease is None else self.lease.to_dict(),
            "suspended": self.suspension,
            "thermal": thermal_word(self.thermal_state),
        }

    def should_hold_for_mode(self, mode: AgentMode, now: float) -> bool:
        if mode in WORK_MODES:
            self.grace_until_monotonic = None
            return True

        # One grace window per stretch of work, started the moment work
        # STOPS -- so a momentary idle blip between tool calls (or a
        # bare IDLE_READY fallback where an explicit Completed never
        # arrives) still gets the full window. The window is NOT
        # refreshed by transitions among rest modes: overnight the
        # display flapped idle-completed-idle as sessions aged out, each
        # flap re-armed a five-minute hold, and the machine never slept
        # again. Rest-to-rest changes now ride out the original window.
        if self.grace_until_monotonic is None:
            if self.last_mode is None or self.last_mode in WORK_MODES:
                self.grace_until_monotonic = now + self.grace_seconds
            else:
                return False
        return now < self.grace_until_monotonic

    def ensure_awake(self) -> None:
        if self.process_running():
            return

        try:
            self.process = self.process_factory(
                self.caffeinate_command(),
                stdout=subprocess.DEVNULL,
                stderr=subprocess.DEVNULL,
            )
            self._process_display = self.effective_display()
            self.last_error = None
        except Exception as exc:
            self.process = None
            self.last_error = str(exc)

    def release(self) -> None:
        self._terminate_process()

    def _terminate_process(self) -> None:
        process = self.process
        self.process = None
        if process is None:
            return

        try:
            if process.poll() is None:
                process.terminate()
                process.wait(timeout=1)
        except Exception:
            try:
                process.kill()
            except Exception:
                pass

    def process_running(self) -> bool:
        return self.process is not None and self.process.poll() is None

    def poke_status_file(self, target: Path | None, *, now: float | None = None) -> Path | None:
        if not self.enabled or target is None:
            return None

        current = time.monotonic() if now is None else now
        status_path = keepalive_file_for_target(target)
        last_read = self.last_status_read_monotonic_by_path.get(status_path)
        if last_read is not None and current - last_read < self.status_read_seconds:
            return None

        self.last_status_read_monotonic_by_path[status_path] = current
        if self.status_read_async:
            if status_path in self.status_read_in_flight_by_path:
                return None
            self.status_read_in_flight_by_path.add(status_path)
            thread = threading.Thread(
                target=self._run_status_reader,
                args=(status_path,),
                daemon=True,
            )
            thread.start()
            return status_path

        return self._run_status_reader(status_path)

    def caffeinate_command(self) -> list[str]:
        command = list(
            configure_caffeinate_display_assertion(
                self.command,
                keep_display_awake=self.effective_display(),
            )
        )
        if self.watch_current_process:
            command.extend(["-w", str(os.getpid())])
        return command

    def _run_status_reader(self, status_path: Path) -> Path | None:
        try:
            self.status_reader(status_path)
            self.last_status_error = None
            return status_path
        except Exception as exc:
            self.last_status_error = str(exc)
            return None
        finally:
            self.status_read_in_flight_by_path.discard(status_path)

    def detail(self, *, now: float | None = None) -> str:
        if self.suspension == SUSPENDED_THERMAL:
            return "Keep awake let go: the Mac is too hot"
        if self.suspension == SUSPENDED_BATTERY:
            return "Keep awake let go: battery low"
        if self.lease is not None:
            return f"Keep awake held by you ({self.lease.kind})"
        if not self.enabled:
            return "Keep awake disabled"
        if self.last_error:
            return f"Keep awake error: {self.last_error}"
        current = time.monotonic() if now is None else now
        if self.grace_until_monotonic is not None and current < self.grace_until_monotonic:
            remaining = int(self.grace_until_monotonic - current)
            return f"Keep awake grace: {format_duration(remaining)}"
        if self.process_running():
            return (
                "Keep awake active, display held awake"
                if self.keep_display_awake
                else "Keep awake active, display may sleep"
            )
        return "Keep awake standby"


def keepalive_file_for_target(target: Path) -> Path:
    known_file_names = KNOWN_LED_FILE_NAMES | {KEEPALIVE_FILE_NAME.upper(), "STATUS.TXT"}
    if target.name.upper() in known_file_names:
        return target.parent / KEEPALIVE_FILE_NAME
    return target / KEEPALIVE_FILE_NAME


def touch_keepalive_file(path: Path) -> None:
    subprocess.run(
        ["/usr/bin/touch", str(path)],
        stdout=subprocess.DEVNULL,
        stderr=subprocess.DEVNULL,
        timeout=2,
        check=True,
    )


def format_duration(seconds: int) -> str:
    seconds = max(0, int(seconds))
    minutes, rest = divmod(seconds, 60)
    if minutes:
        return f"{minutes}m{rest:02d}s"
    return f"{rest}s"
