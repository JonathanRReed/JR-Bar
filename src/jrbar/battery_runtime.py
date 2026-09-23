"""Latest-known-good battery observation for the AppKit host.

Subprocess work runs on at most one daemon worker. UI callers receive the most
recent immutable observation immediately and never wait for ``ioreg``.
"""

from __future__ import annotations

import subprocess
import threading
import time
from collections.abc import Callable
from dataclasses import dataclass

from .battery import BatterySnapshot, read_battery_snapshot

BATTERY_OBSERVATION_MIN_INTERVAL_SECONDS = 5.0
BATTERY_REASON_UNAVAILABLE = "battery_unavailable"
BATTERY_REASON_TIMED_OUT = "battery_timed_out"
BATTERY_REASON_MALFORMED = "battery_malformed"


@dataclass(frozen=True, slots=True)
class BatteryObservation:
    snapshot: BatterySnapshot | None
    observed_at: float | None
    attempted_at: float | None
    reason: str | None
    in_flight: bool

    @property
    def available(self) -> bool:
        return self.snapshot is not None


@dataclass(frozen=True, slots=True)
class _BatteryRequest:
    generation: int
    full_charge_watts: float | None
    callback: Callable[[BatteryObservation], None] | None


class BatteryObservationService:
    def __init__(
        self,
        *,
        reader: Callable[..., BatterySnapshot] = read_battery_snapshot,
        monotonic: Callable[[], float] = time.monotonic,
        minimum_interval: float = BATTERY_OBSERVATION_MIN_INTERVAL_SECONDS,
    ) -> None:
        self._reader = reader
        self._monotonic = monotonic
        self._minimum_interval = max(0.1, float(minimum_interval))
        self._lock = threading.RLock()
        self._generation = 0
        self._closed = False
        self._in_flight = False
        self._pending: _BatteryRequest | None = None
        self._snapshot: BatterySnapshot | None = None
        self._observed_at: float | None = None
        self._attempted_at: float | None = None
        self._reason: str | None = None
        self._last_requested_watts: float | None = None

    def observation(self) -> BatteryObservation:
        with self._lock:
            return self._observation_locked()

    def request(
        self,
        *,
        full_charge_watts: float | None,
        callback: Callable[[BatteryObservation], None] | None = None,
        force: bool = False,
    ) -> BatteryObservation:
        now = self._monotonic()
        with self._lock:
            if self._closed:
                return self._observation_locked()
            due = (
                force
                or self._attempted_at is None
                or now - self._attempted_at >= self._minimum_interval
                or full_charge_watts != self._last_requested_watts
            )
            if not due:
                return self._observation_locked()
            self._generation += 1
            request = _BatteryRequest(
                self._generation,
                full_charge_watts,
                callback,
            )
            if self._in_flight:
                self._pending = request
                return self._observation_locked()
            self._start_locked(request, now)
            return self._observation_locked()

    def close(self) -> None:
        with self._lock:
            self._closed = True
            self._generation += 1
            self._pending = None

    def _observation_locked(self) -> BatteryObservation:
        return BatteryObservation(
            snapshot=self._snapshot,
            observed_at=self._observed_at,
            attempted_at=self._attempted_at,
            reason=self._reason,
            in_flight=self._in_flight,
        )

    def _start_locked(self, request: _BatteryRequest, now: float) -> None:
        self._in_flight = True
        self._attempted_at = now
        self._last_requested_watts = request.full_charge_watts
        threading.Thread(
            target=self._run,
            args=(request,),
            name="JRBarBatteryObservation",
            daemon=True,
        ).start()

    def _run(self, request: _BatteryRequest) -> None:
        snapshot = None
        reason = None
        try:
            snapshot = self._reader(full_charge_watts=request.full_charge_watts)
            if not isinstance(snapshot, BatterySnapshot):
                snapshot = None
                reason = BATTERY_REASON_MALFORMED
        except (subprocess.TimeoutExpired, TimeoutError):
            reason = BATTERY_REASON_TIMED_OUT
        except Exception:
            reason = BATTERY_REASON_UNAVAILABLE

        callback = None
        observation = None
        with self._lock:
            if self._closed or request.generation != self._generation:
                self._in_flight = False
            else:
                if snapshot is not None:
                    self._snapshot = snapshot
                    self._observed_at = self._monotonic()
                    self._reason = None
                else:
                    self._reason = reason or BATTERY_REASON_UNAVAILABLE
                self._in_flight = False
                callback = request.callback
                observation = self._observation_locked()
            if not self._closed and self._pending is not None:
                pending = self._pending
                self._pending = None
                self._start_locked(pending, self._monotonic())

        if callback is not None and observation is not None:
            try:
                callback(observation)
            except Exception:
                pass


# --- state.power.battery -------------------------------------------------------
#
# The daemon reads health, cycles, time left, temperature and the adapter,
# and only percent and charging ever reached the app. This is the published
# shape, plus the one reading no battery app can make: whether the agents
# holding the Mac awake will outlast the battery.

#: ioreg's "still estimating" answer for a time-to-empty or time-to-full.
BATTERY_TIME_UNKNOWN = 65535
#: On battery, with agents holding the Mac awake, fewer minutes left than
#: this is a run about to die on a flat battery.
AGENT_RUNWAY_WARNING_MINUTES = 30
#: Plugged in, a battery still falling this fast means the charger cannot
#: carry the load -- a phone brick on a laptop running three agents. The
#: flag clears only once the drain falls under the lower mark, so a load
#: spike at the edge does not flap it (and re-broadcast the state).
ADAPTER_SHORT_DRAIN_WATTS = 1.5
ADAPTER_SHORT_CLEAR_WATTS = 0.5


def _estimate_minutes(value: object) -> int | None:
    if isinstance(value, bool) or not isinstance(value, int):
        return None
    return value if 0 < value < BATTERY_TIME_UNKNOWN else None


def low_battery_by_time_left(
    snapshot: BatterySnapshot | None,
    *,
    threshold_minutes: float,
    agents_working: int = 0,
    hold_on_battery: bool = False,
) -> bool:
    """The low-battery warning judged by time left rather than charge.

    Off at a zero threshold, on AC, and while macOS is still estimating --
    never on a guess. While agents run on battery with keep-awake holding
    the Mac, it fires at twice the threshold: the run needs the warning in
    time to plug in, not when the Mac is already going down."""
    if snapshot is None or not getattr(snapshot, "battery_present", False) or snapshot.is_plugged:
        return False
    try:
        threshold = float(threshold_minutes)
    except (TypeError, ValueError):
        return False
    if not threshold > 0.0:
        return False
    minutes = _estimate_minutes(snapshot.time_to_empty)
    if minutes is None:
        return False
    if agents_working > 0 and hold_on_battery:
        threshold *= 2.0
    return minutes <= threshold


def adapter_short(
    snapshot: BatterySnapshot | None,
    *,
    agents_working: int = 0,
    previously: bool = False,
) -> bool:
    """The charger is in and the battery still falls while agents work.

    Only a measured drain counts: a slow charger that keeps up, or macOS
    pausing the charge at 80 %, is not short. Idle, it is nobody's problem
    -- the flag belongs to the run. ``previously`` is the last answer, for
    the hysteresis between the two marks."""
    if (
        snapshot is None
        or not getattr(snapshot, "battery_present", False)
        or not snapshot.is_plugged
        or int(agents_working) <= 0
    ):
        return False
    try:
        drain = -float(snapshot.battery_watts)
    except (TypeError, ValueError):
        return False
    if drain != drain:
        return False
    return drain >= (ADAPTER_SHORT_CLEAR_WATTS if previously else ADAPTER_SHORT_DRAIN_WATTS)


def battery_state_document(
    snapshot: BatterySnapshot | None,
    *,
    agents_working: int = 0,
    hold_active: bool = False,
    adapter_was_short: bool = False,
) -> dict[str, object] | None:
    """``state.power.battery``, or None on a Mac with no battery.

    ``runway`` answers "will this run make it": ``short`` is true only on
    battery, with agents working and a hold keeping the Mac up, when the
    estimate says fewer than ``AGENT_RUNWAY_WARNING_MINUTES`` remain;
    ``adapter_short`` is true while the charger is in and the battery still
    falls under the agents' load (``adapter_short``), with
    ``full_speed_watts`` the adapter this Mac charges at full speed on."""
    if snapshot is None or not getattr(snapshot, "battery_present", False):
        return None
    plugged = bool(snapshot.is_plugged)
    minutes_left = None if plugged else _estimate_minutes(snapshot.time_to_empty)
    minutes_to_full = _estimate_minutes(snapshot.time_to_full) if snapshot.is_charging else None
    watts = float(snapshot.battery_watts)
    draw = round(abs(watts), 1) if not plugged and watts < 0 else None
    adapter = float(snapshot.adapter_power) if plugged else 0.0
    temperature = snapshot.temperature_c
    working = max(0, int(agents_working))
    short_adapter = adapter_short(snapshot, agents_working=working, previously=adapter_was_short)
    full_speed = _finite_watts(getattr(snapshot, "full_charge_watts", None))
    return {
        "percent": int(snapshot.percent),
        "charging": bool(snapshot.is_charging),
        "plugged": plugged,
        "minutes_left": minutes_left,
        "minutes_to_full": minutes_to_full,
        "health_percent": snapshot.health_percent if snapshot.health_percent > 0 else None,
        "cycle_count": snapshot.cycle_count if snapshot.cycle_count >= 0 else None,
        "temperature_c": None if temperature is None else round(float(temperature), 1),
        "condition": snapshot.condition or None,
        "draw_watts": draw,
        "adapter_watts": round(adapter, 1) if adapter > 0 else None,
        "runway": {
            "agents": working,
            "minutes_left": minutes_left if working and hold_active else None,
            "short": bool(
                not plugged
                and working
                and hold_active
                and minutes_left is not None
                and minutes_left < AGENT_RUNWAY_WARNING_MINUTES
            ),
            "adapter_short": short_adapter,
            "full_speed_watts": full_speed if short_adapter else None,
        },
    }


def _finite_watts(value: object) -> float | None:
    if isinstance(value, bool) or not isinstance(value, (int, float)):
        return None
    number = float(value)
    return round(number, 1) if number == number and 0.0 < number < 1000.0 else None
