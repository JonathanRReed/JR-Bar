"""The headless daemon's power glue: the keep-awake lease commands, the
environment the holds yield to, and what ``state.power`` says about them.

``core_runtime`` registers the commands and calls in here from its
controller seams; everything below takes the controller as an argument and
reads it defensively, so a controller built without a piece (a test
harness, an older composition) degrades to "no extra facts" rather than an
error on the socket.
"""

from __future__ import annotations

import math
import time
from typing import Any

from . import keep_awake as keep_awake_module
from . import lid_sleep as lid_sleep_module
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


def observe_environment(controller: Any) -> None:
    """Tell the keep-awake hold what it yields to, before each sync."""
    keep = getattr(controller, "keep_awake", None)
    observe = getattr(keep, "observe_environment", None)
    if not callable(observe):
        return
    pending, working = session_facts(getattr(controller, "last_snapshot", None))
    battery = getattr(getattr(controller, "_production_battery_observation", None), "snapshot", None)
    lid_closed = getattr(controller, "last_lid_closed", None)
    observe(
        pending_ids=pending,
        working_count=working,
        battery_floor=battery_yields_hold(battery, getattr(controller, "settings", None)),
        thermal_state=keep_awake_module.read_thermal_state(),
        lid_closed=lid_closed if isinstance(lid_closed, bool) else None,
    )


def before_keep_awake_sync(controller: Any) -> None:
    attach(controller)
    observe_environment(controller)


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
    power["last_release"] = (
        None
        if last is None
        else {"kind": last.kind, "reason": last.reason, "at": last.at, "duration": last.duration}
    )
    closed_lid = power.get("closed_lid")
    lid = getattr(controller, "closed_lid_awake", None)
    if isinstance(closed_lid, dict):
        lid_closed = getattr(controller, "last_lid_closed", None)
        closed_lid["lid_closed"] = lid_closed if isinstance(lid_closed, bool) else None
        closed_lid["sleeps_on_release"] = bool(getattr(lid, "sleeper", None) is not None)
        closed_lid["last_sleep_at"] = getattr(lid, "last_sleep_epoch", None)
        closed_lid["sleep_error"] = getattr(lid, "last_sleep_error", None)


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


__all__ = [
    "after_keep_awake_sync",
    "attach",
    "augment_power_document",
    "before_keep_awake_sync",
    "hold_awake",
    "merge_history",
    "observe_environment",
    "release_awake",
    "session_facts",
]
