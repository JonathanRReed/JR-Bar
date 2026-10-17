"""Observable, AppKit-free acceptance contract for adaptive refresh cadence."""

from __future__ import annotations

import math
from dataclasses import dataclass
from enum import Enum

from .provider_usage_platform import USAGE_OFF_REASON, ProviderSourceState, most_constrained_lane

MENU_AGE_LADDER: tuple[tuple[float, float, str], ...] = (
    (300.0, 120.0, "recent_menu"),
    (3600.0, 300.0, "warm_menu"),
    (14400.0, 900.0, "aging_menu"),
)
IDLE_INTERVAL_SECONDS = 1800.0
ACTIVE_WORK_INTERVAL_SECONDS = 120.0
CONSTRAINED_INTERVAL_SECONDS = 1800.0
RESET_WATCH_WINDOW_SECONDS = 600.0
RESET_WATCH_INTERVAL_SECONDS = 120.0
AMBIENT_VISIBLE_CEILING_SECONDS = 300.0
DEGRADED_INTERVAL_SECONDS = 120.0
#: A source that stays degraded the same way is not fixed by asking it again
#: every two minutes: its fix is the person's (sign in, grant access, import a
#: session), and doing that asks for a refresh itself. The quick retry covers
#: the first minutes; a source still broken the same way after that is asked
#: less and less often, never so rarely that the usage pace (whose samples go
#: stale after fifteen minutes) loses its footing. A change in what is
#: degraded starts the ladder over.
DEGRADED_BACKOFF_LADDER: tuple[tuple[float, float], ...] = (
    (600.0, DEGRADED_INTERVAL_SECONDS),
    (3600.0, 300.0),
)
DEGRADED_SETTLED_INTERVAL_SECONDS = 600.0

_DEGRADED_STATES = frozenset(
    {
        ProviderSourceState.NEEDS_CONSENT,
        ProviderSourceState.NEEDS_SIGN_IN,
        ProviderSourceState.SOURCE_NOT_FOUND,
        ProviderSourceState.ERROR,
        ProviderSourceState.UNAVAILABLE,
    }
)


# A provider whose usage the person has not turned on has nothing to retry,
# so it is not degraded.
def _is_degraded(snapshot) -> bool:
    return (
        getattr(snapshot, "state", None) in _DEGRADED_STATES
        and getattr(snapshot, "reason_code", None) != USAGE_OFF_REASON
    )


def degraded_signature(snapshots) -> frozenset[tuple[str, str, str]]:
    """What is degraded, and how, in a set of snapshots: (source, state,
    reason). Two reads that are broken the same way share a signature."""
    return frozenset(
        (
            str(getattr(snapshot, "identity", None) or getattr(snapshot, "provider_id", "")),
            str(getattr(getattr(snapshot, "state", None), "value", "")),
            str(getattr(snapshot, "reason_code", None) or ""),
        )
        for snapshot in snapshots
        if _is_degraded(snapshot)
    )


def degraded_interval_seconds(degraded_for_seconds: float | None) -> float:
    """How soon to ask again when a source has been degraded the same way for
    this long. ``None`` (not known) is the quick retry."""
    if degraded_for_seconds is None:
        return DEGRADED_INTERVAL_SECONDS
    for ceiling, interval in DEGRADED_BACKOFF_LADDER:
        if degraded_for_seconds <= ceiling:
            return interval
    return DEGRADED_SETTLED_INTERVAL_SECONDS


class AdaptiveRefreshReason(str, Enum):
    CONSTRAINED = "constrained"
    RECENT_MENU = "recent_menu"
    WARM_MENU = "warm_menu"
    AGING_MENU = "aging_menu"
    IDLE = "idle"
    ACTIVE_WORK = "active_work"
    AMBIENT_USAGE = "ambient_usage"
    DEGRADED_SOURCE = "degraded_source"
    RESET_WATCH = "reset_watch"
    #: A jump in remaining is waiting for the read that confirms it as a
    #: reset (provider_usage_qol.confirm_reset_events).
    RESET_CONFIRM = "reset_confirm"


@dataclass(frozen=True, slots=True)
class AdaptiveRefreshPlan:
    interval_seconds: float
    reason: AdaptiveRefreshReason
    menu_age_seconds: float | None
    constrained: bool
    ambient_usage_visible: bool

    def __post_init__(self) -> None:
        if (
            type(self.interval_seconds) not in {int, float}
            or not math.isfinite(self.interval_seconds)
            or self.interval_seconds <= 0.0
            or type(self.reason) is not AdaptiveRefreshReason
            or type(self.constrained) is not bool
            or type(self.ambient_usage_visible) is not bool
        ):
            raise ValueError("invalid adaptive refresh plan")
        if self.menu_age_seconds is not None and (
            type(self.menu_age_seconds) not in {int, float}
            or not math.isfinite(self.menu_age_seconds)
            or self.menu_age_seconds < 0.0
        ):
            raise ValueError("invalid adaptive refresh menu age")
        object.__setattr__(self, "interval_seconds", float(self.interval_seconds))
        if self.menu_age_seconds is not None:
            object.__setattr__(self, "menu_age_seconds", float(self.menu_age_seconds))


def plan_adaptive_refresh_cadence(
    snapshots,
    *,
    observed_at: float,
    menu_last_opened_at: float | None = None,
    constrained: bool = False,
    ambient_usage_visible: bool = False,
    active_work: bool = False,
    reset_confirm_until: float | None = None,
    degraded_for_seconds: float | None = None,
) -> AdaptiveRefreshPlan:
    """Explain the existing cadence without reading clocks or system state.

    ``degraded_for_seconds`` is how long the same sources have been degraded
    the same way (``degraded_signature``); a source that stays broken is
    retried on a widening ladder instead of every two minutes forever.

    ``reset_confirm_until`` is the last moment a waiting reset candidate
    can still be confirmed. Until then the next read comes within
    ``RESET_WATCH_INTERVAL_SECONDS``, even when the Mac is constrained:
    it is one read per jump, and without it the idle half hour lets the
    confirmation window close and the reset is never announced.
    """
    observed = float(observed_at)
    if not math.isfinite(observed):
        raise ValueError("invalid adaptive refresh observation time")
    confirming = False
    if reset_confirm_until is not None:
        until = float(reset_confirm_until)
        if not math.isfinite(until):
            raise ValueError("invalid adaptive refresh reset confirmation time")
        confirming = observed < until
    if constrained and confirming:
        return AdaptiveRefreshPlan(
            RESET_WATCH_INTERVAL_SECONDS,
            AdaptiveRefreshReason.RESET_CONFIRM,
            None,
            True,
            bool(ambient_usage_visible),
        )
    if constrained:
        return AdaptiveRefreshPlan(
            CONSTRAINED_INTERVAL_SECONDS,
            AdaptiveRefreshReason.CONSTRAINED,
            None,
            True,
            bool(ambient_usage_visible),
        )

    interval = IDLE_INTERVAL_SECONDS
    reason = AdaptiveRefreshReason.IDLE
    menu_age = None
    if menu_last_opened_at is not None:
        opened = float(menu_last_opened_at)
        if not math.isfinite(opened):
            raise ValueError("invalid adaptive refresh menu time")
        menu_age = max(0.0, observed - opened)
        for ceiling, candidate, reason_value in MENU_AGE_LADDER:
            if menu_age <= ceiling:
                interval = candidate
                reason = AdaptiveRefreshReason(reason_value)
                break

    if active_work and interval > ACTIVE_WORK_INTERVAL_SECONDS:
        interval = ACTIVE_WORK_INTERVAL_SECONDS
        reason = AdaptiveRefreshReason.ACTIVE_WORK

    if ambient_usage_visible and interval > AMBIENT_VISIBLE_CEILING_SECONDS:
        interval = AMBIENT_VISIBLE_CEILING_SECONDS
        reason = AdaptiveRefreshReason.AMBIENT_USAGE

    degraded_source = False
    reset_watch = False
    for snapshot in snapshots:
        degraded_source = degraded_source or _is_degraded(snapshot)
        lane = most_constrained_lane(snapshot)
        if lane is None or lane.reset_at is None:
            continue
        until_reset = lane.reset_at - observed
        reset_watch = reset_watch or (
            0.0 <= until_reset <= RESET_WATCH_WINDOW_SECONDS
        )

    if interval > RESET_WATCH_INTERVAL_SECONDS:
        if confirming:
            interval = RESET_WATCH_INTERVAL_SECONDS
            reason = AdaptiveRefreshReason.RESET_CONFIRM
        elif reset_watch:
            interval = RESET_WATCH_INTERVAL_SECONDS
            reason = AdaptiveRefreshReason.RESET_WATCH
        elif degraded_source:
            degraded_interval = degraded_interval_seconds(degraded_for_seconds)
            if degraded_interval < interval:
                interval = degraded_interval
                reason = AdaptiveRefreshReason.DEGRADED_SOURCE

    return AdaptiveRefreshPlan(
        interval,
        reason,
        menu_age,
        False,
        bool(ambient_usage_visible),
    )


__all__ = [
    "AdaptiveRefreshPlan",
    "AdaptiveRefreshReason",
    "degraded_interval_seconds",
    "degraded_signature",
    "plan_adaptive_refresh_cadence",
]
