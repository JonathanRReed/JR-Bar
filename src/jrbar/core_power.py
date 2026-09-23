"""The headless daemon's power and presence glue: the keep-awake lease
commands, the environment the holds yield to, what ``state.power`` says
about them, and the app's presence report (``presence``) that quiets a
call, holds escalation at the light and gives ``state.presence``.

``core_runtime`` registers the commands and calls in here from its
controller seams; everything below takes the controller as an argument and
reads it defensively, so a controller built without a piece (a test
harness, an older composition) degrades to "no extra facts" rather than an
error on the socket.
"""

from __future__ import annotations

import math
import threading
import time
from typing import Any

from . import keep_awake as keep_awake_module
from . import lid_sleep as lid_sleep_module
from .battery_runtime import battery_state_document
from .battery_runtime import low_battery_by_time_left as battery_time_left_rule
from .keep_awake import (
    LEASE_END_CANCELLED,
    LEASE_PENDING_MODES,
    POWER_LEASE_ENDED,
    POWER_LID_HOLD_ENDED,
    POWER_LOG_FILE_NAME,
    POWER_SLEPT,
    POWER_SUSPENDED,
    WORK_MODES,
    LeaseRefusedError,
    PowerLog,
    battery_yields_hold,
    lease_from_args,
    merge_history_rows,
)
from .models import AgentMode
from .presence import (
    DEFAULT_AWAY_QUIET_MODE,
    DEFAULT_CALL_QUIET_MODE,
    DEFAULT_MEETING_QUIET_MODE,
    PresenceFacts,
    normalize_presence_quiet_mode,
    parse_presence,
    presence_document,
    presence_escalation_ceiling,
)
from .signals import presence_escalation_stage, provider_escalation_stage

#: The power events a client hears as an ``event`` frame (kind ``power``),
#: in History's words. Starting a lease and resuming are visible in
#: ``state.power`` the moment they happen; these are the ones worth a line.
_EVENT_LABELS = {
    POWER_LEASE_ENDED: "Keep awake ended",
    POWER_SUSPENDED: "Keep awake let go",
    POWER_LID_HOLD_ENDED: "Held awake with the lid closed",
    POWER_SLEPT: "Put the Mac to sleep",
}


def _command_error(code: str, message: str):
    from .core_server import CommandError

    return CommandError(code, message)


def session_facts(snapshot: object) -> tuple[frozenset[str], int]:
    """(ids of main sessions still running or waiting on the person, how
    many main sessions are working right now). Sub-agents never count: a
    lease waits on the run the person started, and one main agent fans out
    to a hundred workers."""
    pending: set[str] = set()
    working = 0
    for status in tuple(getattr(snapshot, "statuses", ()) or ()):
        if getattr(status, "is_subagent", False) or getattr(status, "stale", False):
            continue
        mode = getattr(status, "mode", None)
        if not isinstance(mode, AgentMode):
            continue
        agent_id = str(getattr(status, "agent_id", "") or "")
        if agent_id and mode in LEASE_PENDING_MODES:
            pending.add(agent_id)
        if mode in WORK_MODES:
            working += 1
    return frozenset(pending), working


def attach(controller: Any) -> PowerLog | None:
    """Give the holds their store, their shared log and the closed-lid
    sleep wiring, once. Returns the log (None when the controller has no
    keep-awake hold to attach to)."""
    log = getattr(controller, "_core_power_log", None)
    if log is not None:
        return log
    keep = getattr(controller, "keep_awake", None)
    if keep is None or not callable(getattr(keep, "attach_store", None)):
        return None
    # core_runtime.default_state_dir, not state_paths': the test harness
    # patches the runtime's name to keep every store in a temporary folder.
    from . import core_runtime

    state_dir = core_runtime.default_state_dir()
    log = PowerLog(state_dir / POWER_LOG_FILE_NAME)
    log.load()
    controller._core_power_log = log
    controller._core_power_published = log.events[-1] if log.events else None
    keep.attach_store(state_dir, power_log=log)
    lid = getattr(controller, "closed_lid_awake", None)
    if lid is not None and callable(getattr(lid, "configure_sleep_on_release", None)):
        lid.power_log = log
        lid.governor = lambda: getattr(getattr(controller, "keep_awake", None), "suspension", None)
        lid.configure_sleep_on_release(
            lid_closed_reader=lid_sleep_module.read_lid_closed,
            clamshell_sleep_reader=lid_sleep_module.read_clamshell_causes_sleep,
            sleeper=lid_sleep_module.run_pmset_sleepnow,
        )
    return log


def lid_closed(controller: Any) -> bool | None:
    """The lid reading, or None when nothing is watching the lid.

    The lid is polled only while something needs it (a closed-lid policy, a
    keep-awake hold, a lid animation), and the poll's last answer outlives
    it. A lid shut while agents ran and opened after they finished would
    otherwise read shut until the next hold: the Dot stuck as the asks
    beacon, ``closed_lid.lid_closed`` still true."""
    if getattr(controller, "_lid_observation_active", None) is False:
        return None
    reading = getattr(controller, "last_lid_closed", None)
    return reading if isinstance(reading, bool) else None


def observe_environment(controller: Any) -> None:
    """Tell the keep-awake hold what it yields to, before each sync."""
    keep = getattr(controller, "keep_awake", None)
    observe = getattr(keep, "observe_environment", None)
    if not callable(observe):
        return
    snapshot = getattr(controller, "last_snapshot", None)
    pending, working = session_facts(snapshot)
    battery = getattr(getattr(controller, "_production_battery_observation", None), "snapshot", None)
    # The raw reading: the hold consults the lid only while it holds, and
    # a hold keeps the lid poll running.
    lid = getattr(controller, "last_lid_closed", None)
    observe(
        # No snapshot yet (a restarted daemon whose first refresh failed) is
        # no observation at all: a restored agents lease must not read the
        # empty set as "every session finished".
        pending_ids=None if snapshot is None else pending,
        working_count=working,
        battery_floor=battery_yields_hold(battery, getattr(controller, "settings", None)),
        thermal_state=keep_awake_module.read_thermal_state(),
        lid_closed=lid if isinstance(lid, bool) else None,
    )


def before_keep_awake_sync(controller: Any) -> None:
    attach(controller)
    observe_environment(controller)


def finished_during(controller: Any, start: float, end: float) -> int | None:
    """How many runs finished between ``start`` and ``end`` -- the "3
    finished" in "ran 2 h 40 m closed, 3 finished, slept at 02:14" -- read
    from the activity ledger. None when the ledger cannot say."""
    ledger = getattr(controller, "activity_ledger", None)
    entries = getattr(ledger, "entries", None)
    if entries is None:
        return None
    count = 0
    for entry in entries:
        kind = getattr(getattr(entry, "kind", None), "value", None)
        at = getattr(entry, "occurred_at_epoch", None)
        if kind == "completed" and isinstance(at, (int, float)) and start <= at <= end:
            count += 1
    return count


def _release_document(controller: Any, log: PowerLog, last: Any) -> dict[str, Any]:
    """``state.power.last_release``. A closed-lid stretch and the sleep that
    ended it are one story -- "ran 2 h 40 m closed, 3 finished, slept at
    02:14" -- so a sleep carries the stretch it closed."""
    stretch = last
    slept_at = None
    if last.kind == POWER_SLEPT:
        slept_at = last.at
        before = [event for event in log.events if event.kind == POWER_LID_HOLD_ENDED]
        if before and 0.0 <= last.at - before[-1].at <= 5.0:
            stretch = before[-1]
    return {
        "kind": last.kind,
        "reason": last.reason,
        "at": last.at,
        "duration": stretch.duration,
        "finished": _held_stretch_finished(controller, stretch),
        "slept_at": slept_at,
    }


def _held_stretch_finished(controller: Any, event: Any) -> int | None:
    if event.kind != POWER_LID_HOLD_ENDED or event.duration is None:
        return None
    return finished_during(controller, event.at - event.duration, event.at)


def after_keep_awake_sync(controller: Any) -> None:
    """Publish the power events this sync recorded, once each."""
    log = getattr(controller, "_core_power_log", None)
    publish = getattr(controller, "_core_publish_event", None)
    if log is None or not callable(publish):
        return
    events = log.events
    last = getattr(controller, "_core_power_published", None)
    start = 0
    if last is not None:
        for index in range(len(events) - 1, -1, -1):
            if events[index] is last:
                start = index + 1
                break
    fresh = events[start:]
    if fresh:
        controller._core_power_published = fresh[-1]
    for event in fresh:
        label = _EVENT_LABELS.get(event.kind)
        if label is None:
            continue
        publish(
            "power",
            label=label,
            detail=event.reason,
            power=event.kind,
            duration=event.duration,
            finished=_held_stretch_finished(controller, event),
            at=event.at,
        )


def _resync(controller: Any) -> None:
    """Apply a lease change now, not at the next refresh: the hold takes
    (or drops) its assertion, and the state document says so."""
    keep = getattr(controller, "keep_awake", None)
    mode = getattr(keep, "last_mode", None) or AgentMode.IDLE_READY
    sync = getattr(controller, "sync_keep_awake", None)
    if callable(sync):
        sync(mode)
    publish = getattr(controller, "_core_publish_state", None)
    if callable(publish):
        publish()


def hold_awake(controller: Any, args: dict[str, Any]) -> dict[str, Any]:
    """The ``hold_awake`` command: start (or replace) the person's lease."""
    keep = getattr(controller, "keep_awake", None)
    if keep is None or not callable(getattr(keep, "start_lease", None)):
        raise _command_error("unsupported", "this daemon has no keep-awake hold")
    seconds = args.get("seconds")
    if (
        not isinstance(seconds, bool)
        and isinstance(seconds, (int, float))
        and math.isfinite(float(seconds))
        and float(seconds) == 0.0
    ):
        return release_awake(controller, {})
    pending, _working = session_facts(getattr(controller, "last_snapshot", None))
    try:
        lease = lease_from_args(args, now=time.time(), pending_ids=pending)
    except LeaseRefusedError as error:
        raise _command_error("refused", str(error)) from error
    except ValueError as error:
        raise _command_error("invalid_args", str(error)) from error
    attach(controller)
    keep.start_lease(lease)
    _resync(controller)
    return {"lease": lease.to_dict(), "hold": keep.hold_document()}


def release_awake(controller: Any, _args: dict[str, Any]) -> dict[str, Any]:
    """The ``release_awake`` command: end the person's lease. The agent hold
    is not the person's to end here -- it has its own switch."""
    keep = getattr(controller, "keep_awake", None)
    if keep is None or not callable(getattr(keep, "end_lease", None)):
        raise _command_error("unsupported", "this daemon has no keep-awake hold")
    attach(controller)
    ended = bool(keep.end_lease(LEASE_END_CANCELLED))
    if ended:
        _resync(controller)
    return {"ended": ended, "hold": keep.hold_document()}


def augment_power_document(controller: Any, document: dict[str, Any]) -> None:
    """Add the lease, the yield and the closed-lid facts to ``state.power``."""
    power = document.get("power")
    if not isinstance(power, dict):
        return
    keep = getattr(controller, "keep_awake", None)
    hold_document = getattr(keep, "hold_document", None)
    if callable(hold_document):
        power["hold"] = hold_document()
    log = getattr(controller, "_core_power_log", None)
    last = (
        log.last(POWER_SUSPENDED, POWER_LEASE_ENDED, POWER_SLEPT, POWER_LID_HOLD_ENDED)
        if log is not None
        else None
    )
    if last is not None and last.kind == POWER_LEASE_ENDED and last.reason == LEASE_END_CANCELLED:
        last = None
    power["last_release"] = None if last is None else _release_document(controller, log, last)
    closed_lid = power.get("closed_lid")
    lid = getattr(controller, "closed_lid_awake", None)
    battery = getattr(getattr(controller, "_production_battery_observation", None), "snapshot", None)
    process_running = getattr(keep, "process_running", None)
    lid_active = getattr(lid, "active", None)
    power["battery"] = battery_state_document(
        battery,
        agents_working=int(getattr(keep, "working_count", 0) or 0),
        hold_active=bool(
            (callable(process_running) and process_running())
            or (callable(lid_active) and lid_active())
        ),
        adapter_was_short=bool(getattr(controller, "_core_adapter_short", False)),
    )
    runway = (power["battery"] or {}).get("runway")
    # The last answer is the hysteresis for the next: one spike at the edge
    # must not flap the flag and re-broadcast the state.
    controller._core_adapter_short = bool(isinstance(runway, dict) and runway.get("adapter_short"))
    if isinstance(closed_lid, dict):
        closed_lid["lid_closed"] = lid_closed(controller)
        closed_lid["sleeps_on_release"] = bool(getattr(lid, "sleeper", None) is not None)
        closed_lid["last_sleep_at"] = getattr(lid, "last_sleep_epoch", None)
        closed_lid["sleep_error"] = getattr(lid, "last_sleep_error", None)


def low_battery_by_time_left(controller: Any, snapshot: object) -> bool:
    """The time-left half of the low-battery warning, with the agents in
    it: twice as early while they run on battery under a keep-awake hold."""
    settings = getattr(controller, "settings", None)
    if not bool(getattr(settings, "low_battery_alert_enabled", True)):
        return False
    keep = getattr(controller, "keep_awake", None)
    return battery_time_left_rule(
        snapshot,  # type: ignore[arg-type]
        threshold_minutes=getattr(settings, "low_battery_threshold_minutes", 0.0),
        agents_working=int(getattr(keep, "working_count", 0) or 0),
        hold_on_battery=bool(getattr(settings, "keep_awake_on_battery", True))
        and bool(getattr(keep, "agent_demand", False)),
    )


# --- presence ------------------------------------------------------------------


def presence_facts(controller: Any) -> PresenceFacts | None:
    facts = getattr(controller, "_core_presence", None)
    return facts if isinstance(facts, PresenceFacts) else None


def _quiet_modes(controller: Any) -> tuple[str, str, str]:
    """(call, meeting, away) quiet modes from the settings."""
    settings = getattr(controller, "settings", None)
    return (
        normalize_presence_quiet_mode(
            getattr(settings, "call_quiet_mode", DEFAULT_CALL_QUIET_MODE), DEFAULT_CALL_QUIET_MODE
        ),
        normalize_presence_quiet_mode(
            getattr(settings, "meeting_quiet_mode", DEFAULT_MEETING_QUIET_MODE),
            DEFAULT_MEETING_QUIET_MODE,
        ),
        normalize_presence_quiet_mode(
            getattr(settings, "away_quiet_mode", DEFAULT_AWAY_QUIET_MODE),
            DEFAULT_AWAY_QUIET_MODE,
        ),
    )


def presence_state_document(controller: Any, *, now: float | None = None) -> dict[str, Any]:
    call_mode, meeting_mode, away_mode = _quiet_modes(controller)
    return presence_document(
        presence_facts(controller),
        now=time.time() if now is None else now,
        call_quiet_mode=call_mode,
        meeting_quiet_mode=meeting_mode,
        away_quiet_mode=away_mode,
    )


def on_call(controller: Any, *, now: float | None = None) -> bool:
    facts = presence_facts(controller)
    return bool(facts is not None and facts.on_call(time.time() if now is None else now))


def in_meeting(controller: Any, *, now: float | None = None) -> bool:
    """A calendar meeting the app reported is in progress; it carries its
    own end, so it stands without the app renewing it."""
    facts = presence_facts(controller)
    return bool(facts is not None and facts.in_meeting(time.time() if now is None else now))


def escalation_stage(controller: Any, stage: int, *, now: float | None = None) -> int:
    """The ladder's stage adjusted for whose ask it is and for presence: a
    per-provider ceiling first, then held at the light on a call, past the
    invisible menu-bar pulse while the screen is locked."""
    settings = getattr(controller, "settings", None)
    tiers = getattr(settings, "escalation_tier_by_provider", None)
    if isinstance(tiers, dict) and tiers:
        oldest = getattr(controller, "_core_oldest_ask", None)
        status = oldest() if callable(oldest) else None
        stage = provider_escalation_stage(
            stage, provider=getattr(status, "provider", None), tiers=tiers
        )
    facts = presence_facts(controller)
    if facts is None:
        return stage
    current = time.time() if now is None else now
    call_mode, _meeting_mode, _away_mode = _quiet_modes(controller)
    return presence_escalation_stage(
        stage,
        tier=str(getattr(getattr(controller, "settings", None), "escalation_tier", "menu_bar")),
        call_ceiling=presence_escalation_ceiling(facts, now=current, call_quiet_mode=call_mode),
        away=facts.away(current),
    )


def _apply_presence(controller: Any, facts: PresenceFacts | None) -> None:
    """Hand the facts to the quiet policy, re-judge the escalation stage,
    arm the expiry and publish -- every consumer reads the new fact at once."""
    controller._core_presence = facts
    dnd = getattr(controller, "dnd_controller", None)
    set_presence = getattr(dnd, "set_presence", None)
    if callable(set_presence):
        set_presence(facts)
    apply_escalation = getattr(controller, "apply_escalation", None)
    if callable(apply_escalation):
        apply_escalation(allow_refresh=False)
    _arm_presence_expiry(controller, facts, time.time())
    publish = getattr(controller, "_core_publish_state", None)
    if callable(publish):
        publish()


def _arm_presence_expiry(controller: Any, facts: PresenceFacts | None, now: float) -> None:
    """A call, an empty desk and the app's Focus reading all end on their own
    when the reports stop; arm the moment this report goes stale so the quiet
    does not outlive its evidence. Only a fresh report arms it: the stale one
    the timer re-applies arms nothing, so the timer fires once per report
    rather than every second until the next one arrives."""
    previous = getattr(controller, "_core_presence_timer", None)
    invalidate = getattr(previous, "invalidate", None)
    if callable(invalidate):
        invalidate()
    controller._core_presence_timer = None
    if facts is None or not facts.fresh(now):
        return
    from . import core_runtime

    controller._core_presence_timer = core_runtime._schedule_timer(
        max(1.0, facts.expires_at() - now),
        controller,
        "corePresenceExpired:",
        False,
    )


def set_presence(controller: Any, args: dict[str, Any]) -> dict[str, Any]:
    """The ``presence`` command: the app's report of what it senses."""
    from . import calendar_watch, reminders_watch

    now = time.time()
    try:
        facts = parse_presence(args, now=now, previous=presence_facts(controller))
    except ValueError as error:
        raise _command_error("invalid_args", str(error)) from error
    # The app's own Calendar and Reminders readings, when it sends them: the
    # glows use them and the helper never needs its own EventKit grant. All
    # or nothing -- a malformed half never lands beside a good one.
    previous_calendar = calendar_watch._app_facts
    previous_reminders = reminders_watch._app_due
    try:
        if "next_event_start" in args:
            calendar_watch.adopt_app_calendar_facts(args.get("next_event_start"), now=now)
        if "reminders_due" in args:
            reminders_watch.adopt_app_reminders(args.get("reminders_due"), now=now)
    except ValueError as error:
        calendar_watch._app_facts = previous_calendar
        reminders_watch._app_due = previous_reminders
        raise _command_error("invalid_args", str(error)) from error
    _apply_presence(controller, facts)
    return {"presence": presence_state_document(controller, now=now)}


def presence_expired(controller: Any) -> None:
    """The expiry timer: a report nobody renewed stops counting as a call.
    The facts stay (a meeting carries its own end); the policy re-reads
    them and finds the call over."""
    facts = presence_facts(controller)
    if facts is None:
        return
    now = time.time()
    if facts.fresh(now):
        # Early by the wall clock (it stepped back): wait out the rest.
        _arm_presence_expiry(controller, facts, now)
        return
    _apply_presence(controller, facts)


def augment_presence_document(controller: Any, document: dict[str, Any], *, now: float) -> None:
    document["presence"] = presence_state_document(controller, now=now)
    # Whether the helper itself can read which Focus is on. Full Disk Access
    # is granted per binary, and the app's own probe says "granted" while
    # the helper still cannot see Focus; Setup's row should say so.
    focus = document.get("focus")
    if isinstance(focus, dict):
        readable = getattr(controller, "_focus_observation_available", None)
        focus["named_readable"] = readable if isinstance(readable, bool) else None


def merge_history(
    controller: Any,
    rows: list[dict[str, Any]],
    *,
    since: float | None,
    limit: int,
    last_seen: float,
) -> list[dict[str, Any]]:
    """``list_history`` rows with the power log's rows folded in."""
    log = getattr(controller, "_core_power_log", None)
    if log is None:
        return rows
    return merge_history_rows(
        rows,
        log.history_rows(since=since, last_seen=last_seen),
        limit=limit,
    )


# --- energy per session ----------------------------------------------------------

_ENERGY_SAMPLER_LOCK = threading.Lock()


def energy_sessions(snapshot: object) -> list[tuple[str, str, str]]:
    """``(state id, provider, provider session id)`` for every live main
    session. Sub-agents run inside their parent's process, so the parent's
    tree already carries them."""
    sessions: list[tuple[str, str, str]] = []
    for status in tuple(getattr(snapshot, "statuses", ()) or ()):
        if getattr(status, "is_subagent", False) or getattr(status, "stale", False):
            continue
        agent_id = str(getattr(status, "agent_id", "") or "")
        provider = str(getattr(status, "provider", "") or "")
        session_id = str(getattr(status, "session_id", "") or "")
        if agent_id and provider and session_id:
            sessions.append((agent_id, provider, session_id))
    return sessions


def session_energy(controller: Any, _args: dict[str, Any]) -> dict[str, Any]:
    """Which session is spending the battery (jrbar.session_energy). The
    session list is read on the main thread; the process table off it."""
    from .session_energy import SessionEnergySampler

    on_main = getattr(controller, "_core_on_main", None) or (lambda fn: fn())
    sessions = on_main(lambda: energy_sessions(getattr(controller, "last_snapshot", None)))
    with _ENERGY_SAMPLER_LOCK:
        sampler = getattr(controller, "_core_energy_sampler", None)
        if sampler is None:
            sampler = SessionEnergySampler()
            controller._core_energy_sampler = sampler
    return sampler.measure(sessions)


__all__ = [
    "after_keep_awake_sync",
    "attach",
    "augment_power_document",
    "augment_presence_document",
    "before_keep_awake_sync",
    "energy_sessions",
    "escalation_stage",
    "hold_awake",
    "in_meeting",
    "merge_history",
    "observe_environment",
    "on_call",
    "presence_expired",
    "presence_facts",
    "presence_state_document",
    "release_awake",
    "session_energy",
    "session_facts",
    "set_presence",
]
