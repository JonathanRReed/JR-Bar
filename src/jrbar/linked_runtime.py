"""The linked Pro + Dot's shared clock, as the headless daemon keeps it.

``jrbar.linked_sync`` is the arithmetic; this is the bookkeeping around it:

* the EPOCH (``A_pro``): the moment the followed strip took its current
  program, from the write's own fsync return, recorded on every strip
  restart -- reasserts included -- and never on a write that changed
  nothing. The Dot, the Screen Bar and the lights document all read this
  one start;
* the Dot's last timed write: when it landed, the phase it was rotated to,
  the rate it was retimed for, and the error that write itself left;
* the closed loop: a sparse fresh read of the Dot's ``ticks`` every 20 s,
  the predicted phase error, and a Dot-only re-anchor when that error is
  past ``linked_sync_tolerance_ms`` -- at most one every 20 s. The strip is
  never rewritten for sync (it has flash to spare the Dot does not need);
* ``Check sync``: a minute of aligned 80 ms white flashes on both devices,
  for a person to judge by eye.
"""

from __future__ import annotations

import threading
import time
from collections import deque
from collections.abc import Callable
from dataclasses import dataclass
from pathlib import Path
from typing import Any, Final

from .device_clock import DeviceClocks, DeviceStatus, read_fresh_status
from .linked_sync import (
    SYNC_INTERVAL_SECONDS,
    clamp_tolerance,
    clamp_trim,
    phase_ms,
    predicted_error_ms,
    should_resync,
    wrap_ms,
)

#: Check sync: an 80 ms white flash every two seconds on both devices. Well
#: inside the presentation gate (0.5 Hz, and not a saturated red).
CHECK_SYNC_PROGRAM: Final = "#FFFFFF 80ms none\noff 1920ms none\nrepeat"
CHECK_SYNC_SECONDS: Final = 60.0
#: When fresh reads stop working (the clock never moves: the cache trick
#: broke on some macOS), the loop cannot measure; it re-anchors blind this
#: often instead, on the last good rate.
BLIND_REANCHOR_SECONDS: Final = 60.0
#: Consecutive failed reads before the loop calls itself blind.
_BLIND_AFTER_FAILURES: Final = 3
#: The loop re-anchors at this share of the tolerance: the predicted error
#: carries a few milliseconds of read jitter, and acting a little early is
#: what keeps the true error under the tolerance rather than around it.
REANCHOR_AT_SHARE: Final = 0.75


@dataclass(frozen=True, slots=True)
class LinkedEpoch:
    """The followed strip's current program and the moment it started."""

    anchor: float
    anchor_epoch: float
    program: str
    state: object
    leds: int
    device_id: str


@dataclass(frozen=True, slots=True)
class DotWriteRecord:
    """The Dot's last timed write, and what it promised."""

    device_id: str
    applied_at: float
    phase_ms: float
    rate: float
    lap_ms: int | None
    rotation: str
    initial_error_ms: float
    ticks_at_apply: float | None
    anchor: float
    reason: str


class LinkedSync:
    """The pair's clock and the Dot's closed loop. Main-thread state, except
    where noted: the write worker records writes through ``note_*`` and the
    loop's reads land through ``_deliver`` under the lock."""

    def __init__(
        self,
        clocks: DeviceClocks | None = None,
        *,
        reader: Callable[[Path], DeviceStatus | None] | None = None,
        spawn: Callable[[Callable[[], None]], None] | None = None,
        now: Callable[[], float] = time.monotonic,
    ) -> None:
        self.clocks = clocks or DeviceClocks()
        self.reader = reader or (lambda root: read_fresh_status(root))
        self.spawn = spawn or _spawn_daemon
        self.now = now
        self.epoch: LinkedEpoch | None = None
        self.dot_write: DotWriteRecord | None = None
        self.committed: dict[str, float] = {}
        self.phase_error_ms: float | None = None
        self.error_at: float | None = None
        #: How fast the error is moving, ms per second: the measured rate
        #: against the rate the Dot's loop was written for. Between reads
        #: the loop predicts from it, so the error is caught when it
        #: crosses the tolerance rather than at the next read.
        self.drift_ms_per_s = 0.0
        self.last_sync_write_at: float | None = None
        self.last_dot_write_epoch: float | None = None
        self.reanchors: deque[float] = deque()
        self.last_read_at: float | None = None
        self.read_failures = 0
        #: A running Check sync's end: monotonic, for the loop, and the
        #: wall-clock moment the lights frame names -- fixed once, so every
        #: build during a check does not look like a new frame.
        self.check_until: float | None = None
        self.check_until_epoch: float | None = None
        self._force_reason: str | None = None
        self._lock = threading.Lock()
        self._pending: tuple[str, DeviceStatus | None] | None = None
        self._reading = False

    # -- the epoch ---------------------------------------------------------

    def note_epoch(self, epoch: LinkedEpoch) -> None:
        self.epoch = epoch

    def forget(self) -> None:
        """The strip left: nothing the link claimed is true any more."""
        self.epoch = None
        self.dot_write = None
        self.phase_error_ms = None
        self.error_at = None
        self.check_until = None
        self.check_until_epoch = None

    def start_check(self, until: float, until_epoch: float) -> None:
        self.check_until = float(until)
        self.check_until_epoch = float(until_epoch)

    def end_check(self) -> None:
        self.check_until = None
        self.check_until_epoch = None

    # -- forcing the Dot ---------------------------------------------------

    def request_force(self, reason: str) -> None:
        self._force_reason = reason

    def take_force(self) -> str | None:
        """The reason the next Dot write must happen whatever the deduper
        says, once. Read on the write worker."""
        reason, self._force_reason = self._force_reason, None
        return reason

    # -- the rate ----------------------------------------------------------

    def rate_for_write(self, dot_id: str, *, correction: bool, commit: bool) -> float:
        """The rate the Dot's next program is retimed for.

        It only moves when the Dot is written anyway for another reason (a
        strip restart) or re-anchored: the dedupe token carries it, and a
        rate that crept with every estimate would rewrite the Dot for
        nothing."""
        if not correction:
            return 1.0
        if commit or dot_id not in self.committed:
            self.committed[dot_id] = round(self.clocks.rate(dot_id, dot=True), 5)
        return self.committed[dot_id]

    # -- a Dot write landed (worker thread) --------------------------------

    def note_dot_write(
        self,
        *,
        dot_id: str,
        write: Any,
        epoch: LinkedEpoch,
        trim_ms: float,
        reason: str,
        sample: DeviceStatus | None,
    ) -> None:
        timed = getattr(write, "timed", None)
        applied = getattr(write, "applied_at", None)
        if timed is None or applied is None:
            return
        lap = getattr(timed, "lap_ms", None)
        rate = float(getattr(timed, "effective_rate", None) or getattr(timed, "rate", 1.0) or 1.0)
        used = float(getattr(timed, "phase_ms", 0.0) or 0.0)
        wanted = phase_ms(applied, epoch.anchor, lap, trim_ms=trim_ms) if lap else used
        initial = wrap_ms(used - wanted, lap) if lap else 0.0
        ticks_at_apply = None
        if sample is not None and sample.ticks is not None:
            estimate = self.clocks.add(dot_id, dot=True, host_at=sample.host_at, clock_ms=sample.ticks)
            ticks_at_apply = sample.ticks - estimate.rate * (sample.host_at - applied) * 1000.0
        record = DotWriteRecord(
            device_id=dot_id,
            applied_at=float(applied),
            phase_ms=used,
            rate=rate,
            lap_ms=lap,
            rotation=str(getattr(timed, "rotation", "exact")),
            initial_error_ms=initial,
            ticks_at_apply=ticks_at_apply,
            anchor=epoch.anchor,
            reason=reason,
        )
        drift = (self.clocks.rate(dot_id, dot=True) / rate - 1.0) * 1000.0
        with self._lock:
            self.dot_write = record
            self.phase_error_ms = initial
            self.error_at = float(applied)
            self.drift_ms_per_s = drift
            self.last_dot_write_epoch = time.time()
            if reason in ("reanchor", "blind", "check"):
                self.last_sync_write_at = self.now()
            if reason in ("reanchor", "blind"):
                # Counted when written, not when asked for: a re-anchor the
                # write path refused never reached the Dot.
                self.reanchors.append(self.now())

    # -- the closed loop (main thread) -------------------------------------

    def _deliver(self, dot_id: str, status: DeviceStatus | None) -> None:
        with self._lock:
            self._pending = (dot_id, status)
            self._reading = False

    def start_read(self, dot_id: str, root: Path) -> bool:
        with self._lock:
            if self._reading:
                return False
            self._reading = True
        self.last_read_at = self.now()

        def work() -> None:
            try:
                status = self.reader(root)
            except Exception:
                status = None
            self._deliver(dot_id, status)

        self.spawn(work)
        return True

    def consume(self) -> float | None:
        """Take the latest read, if one arrived: feed the estimator and
        recompute the predicted phase error."""
        with self._lock:
            pending, self._pending = self._pending, None
        if pending is None:
            return self.phase_error_ms
        dot_id, status = pending
        if status is None or status.ticks is None:
            self.read_failures += 1
            return self.phase_error_ms
        self.read_failures = 0
        estimate = self.clocks.add(dot_id, dot=True, host_at=status.host_at, clock_ms=status.ticks)
        record = self.dot_write
        if record is None or record.device_id != dot_id:
            return self.phase_error_ms
        ticks_at_apply = record.ticks_at_apply
        if ticks_at_apply is None:
            # No read right after the write: the fit's rate carries the
            # newest reading back to the moment the Dot parsed.
            ticks_at_apply = status.ticks - estimate.rate * (status.host_at - record.applied_at) * 1000.0
        error = predicted_error_ms(
            initial_error_ms=record.initial_error_ms,
            applied_at=record.applied_at,
            ticks_at_apply=ticks_at_apply,
            ticks_now=status.ticks,
            host_now=status.host_at,
            rate=record.rate,
            lap_ms=record.lap_ms,
        )
        with self._lock:
            self.phase_error_ms = error
            self.error_at = status.host_at
            self.drift_ms_per_s = (estimate.rate / record.rate - 1.0) * 1000.0
        return error

    def current_error(self, now: float) -> float | None:
        """The error now: the last one measured, carried forward at the
        measured drift (wrapped to the loop)."""
        error = self.phase_error_ms
        if error is None or self.error_at is None:
            return error
        moved = error + self.drift_ms_per_s * max(0.0, now - self.error_at)
        record = self.dot_write
        return wrap_ms(moved, record.lap_ms) if record is not None and record.lap_ms else moved

    def blind(self, dot_id: str) -> bool:
        estimator = self.clocks.estimator(dot_id, dot=True)
        return (
            estimator.estimate.source == "frozen"
            or self.read_failures >= _BLIND_AFTER_FAILURES
        )

    def due(self, *, tolerance_ms: object, now: float, dot_id: str) -> str | None:
        """``"reanchor"`` or ``"blind"`` when the Dot should be re-phased now."""
        if self.dot_write is None:
            return None
        if self.blind(dot_id):
            last = self.last_sync_write_at
            if last is None or now - last >= BLIND_REANCHOR_SECONDS:
                return "blind"
            return None
        if should_resync(
            self.current_error(now),
            tolerance_ms=clamp_tolerance(tolerance_ms) * REANCHOR_AT_SHARE,
            now=now,
            last_sync_at=self.last_sync_write_at,
        ):
            return "reanchor"
        return None

    def note_reanchor_requested(self, now: float) -> None:
        """A re-anchor was asked for: the loop waits out the interval from
        now rather than ask again every second while it is queued. It is
        counted in ``sync_writes_hour`` only once it is written."""
        self.last_sync_write_at = now
        while self.reanchors and now - self.reanchors[0] > 3600.0:
            self.reanchors.popleft()

    def read_due(self, now: float) -> bool:
        return self.last_read_at is None or now - self.last_read_at >= SYNC_INTERVAL_SECONDS

    # -- the lights document -----------------------------------------------

    def document(self, *, dot_id: str | None, tolerance_ms: object, correction: bool) -> dict[str, Any]:
        """The additive ``lights.dot_link`` fields (``docs/CORE-PROTOCOL.md``)."""
        now = self.now()
        while self.reanchors and now - self.reanchors[0] > 3600.0:
            self.reanchors.popleft()
        rate = None
        source = None
        if dot_id is not None:
            estimate = self.clocks.estimator(dot_id, dot=True).estimate
            rate = round(self.committed.get(dot_id, estimate.rate), 5) if correction else 1.0
            source = estimate.source if correction else "off"
        record = self.dot_write
        error = self.current_error(now)
        return {
            "phase_error_ms": None if error is None else round(error, 1),
            "clock_rate": rate,
            "clock_source": source,
            "tolerance_ms": clamp_tolerance(tolerance_ms),
            "last_sync_at": self.last_dot_write_epoch,
            "sync_writes_hour": len(self.reanchors),
            "rotation": record.rotation if record is not None else None,
            "check_until": (
                None if self.check_until is None or self.check_until <= now else self.check_until_epoch
            ),
        }


#: The timing readout's resolution: the lights frame is re-sent when the
#: Dot's phase error moves to another 5 ms step or across the tolerance,
#: not on every tenth of a millisecond it drifts.
READOUT_STEP_MS: Final = 5.0


def readout_mark(error_ms: float | None, tolerance_ms: object) -> tuple[int, bool] | None:
    """What the "Within N ms" readout can show of an error: its 5 ms step
    and whether it is past the tolerance. ``None``: nothing measured."""
    if error_ms is None:
        return None
    size = abs(float(error_ms))
    return int(size // READOUT_STEP_MS), size > clamp_tolerance(tolerance_ms)


def _spawn_daemon(work: Callable[[], None]) -> None:
    threading.Thread(target=work, name="jrbar-linked-sync", daemon=True).start()


def trim_setting(settings: object) -> float:
    return clamp_trim(getattr(settings, "linked_dot_phase_trim_ms", 0.0))


__all__ = [
    "BLIND_REANCHOR_SECONDS",
    "CHECK_SYNC_PROGRAM",
    "CHECK_SYNC_SECONDS",
    "READOUT_STEP_MS",
    "DotWriteRecord",
    "LinkedEpoch",
    "LinkedSync",
    "readout_mark",
    "trim_setting",
]
