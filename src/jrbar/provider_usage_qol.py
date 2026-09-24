"""Reset celebrations, threshold notices, countdowns, and usage totals."""

from __future__ import annotations

import hashlib
import math
from dataclasses import dataclass

from .provider_usage_platform import ProviderSourceState, ProviderUsageSnapshot, UsageLane

#: A TIMING reset: the old window's boundary passed between two reads and
#: remaining rose. The clock proves it, so it is announced at once.
RESET_TRIGGER_TIMING = "timing"
#: A JUMP: remaining leapt by at least ``RESET_JUMP_POINTS`` without the
#: boundary passing on our clock. One odd read can look like that, so a
#: jump is only a candidate until a later read confirms it.
RESET_TRIGGER_JUMP = "jump"
RESET_TIMING_POINTS = 5.0
RESET_JUMP_POINTS = 50.0
#: A confirming read must come at least a minute after the jump (a
#: second look, not the same answer twice) and at most half an hour
#: after it (older evidence says nothing about this read).
RESET_CONFIRM_MIN_S = 60.0
RESET_CONFIRM_MAX_S = 1800.0
#: The confirming read's reset time must match the jump's within two
#: minutes: a real new window keeps its boundary.
RESET_BOUNDARY_TOLERANCE_S = 120.0
#: At or above this remaining percent a lane counts as unused.
RESET_UNUSED_REMAINING = 99.5


@dataclass(frozen=True, slots=True)
class ResetEvent:
    event_id: str
    provider_id: str
    lane_id: str
    label: str
    occurred_at: float
    source_instance_id: str = "default"
    reset_boundary: float | None = None
    #: ``timing`` or ``jump`` (see ``RESET_TRIGGER_*``).
    trigger: str = RESET_TRIGGER_TIMING
    #: The lane's reset time and remaining percent on the read that fired,
    #: and the remaining percent before it: what a confirmation compares.
    after_reset_at: float | None = None
    after_remaining: float | None = None
    before_remaining: float | None = None


@dataclass(frozen=True, slots=True)
class ResetCandidate:
    """A jump waiting for a confirming read. Saved with the reset delivery
    state, so a restart in the middle neither loses it nor fires it twice."""

    event_id: str
    provider_id: str
    source_instance_id: str
    lane_id: str
    label: str
    reset_boundary: float
    after_reset_at: float
    after_remaining: float
    before_remaining: float
    observed_at: float

    def to_dict(self) -> dict[str, object]:
        return {
            "event_id": self.event_id,
            "provider_id": self.provider_id,
            "source_instance_id": self.source_instance_id,
            "lane_id": self.lane_id,
            "label": self.label,
            "reset_boundary": self.reset_boundary,
            "after_reset_at": self.after_reset_at,
            "after_remaining": self.after_remaining,
            "before_remaining": self.before_remaining,
            "observed_at": self.observed_at,
        }

    @classmethod
    def from_dict(cls, raw: object) -> ResetCandidate | None:
        if not isinstance(raw, dict):
            return None
        try:
            numbers = {
                key: float(raw[key])
                for key in (
                    "reset_boundary",
                    "after_reset_at",
                    "after_remaining",
                    "before_remaining",
                    "observed_at",
                )
            }
            words = {
                key: raw[key]
                for key in ("event_id", "provider_id", "source_instance_id", "lane_id", "label")
            }
        except (KeyError, TypeError, ValueError):
            return None
        if not all(math.isfinite(value) for value in numbers.values()):
            return None
        if not all(isinstance(value, str) and value for value in words.values()):
            return None
        return cls(**words, **numbers)


@dataclass(frozen=True, slots=True)
class ResetConfirmation:
    """The resets to announce now, and the jumps still waiting."""

    events: tuple[ResetEvent, ...]
    candidates: tuple[ResetCandidate, ...]


@dataclass(frozen=True, slots=True)
class ThresholdCrossing:
    provider_id: str
    lane_id: str
    label: str
    remaining_percent: float
    threshold_percent: float
    source_instance_id: str = "default"


@dataclass(frozen=True, slots=True)
class UsageTotals:
    input_tokens: int
    cached_input_tokens: int
    output_tokens: int
    providers_with_usage: int
    model_observations: int
    estimated_cost_usd: float | None
    cache_savings_usd: float | None


def _snapshot_map(
    snapshots: tuple[ProviderUsageSnapshot, ...],
) -> dict[tuple[str, str], ProviderUsageSnapshot]:
    return {snapshot.identity: snapshot for snapshot in snapshots}


def _lane_map(snapshot: ProviderUsageSnapshot) -> dict[str, UsageLane]:
    return {lane.lane_id: lane for lane in snapshot.lanes}


def _event_id(
    provider_id: str,
    source_instance_id: str,
    lane_id: str,
    old_reset_at: float,
) -> str:
    material = (
        f"{provider_id}\0{source_instance_id}\0{lane_id}\0{old_reset_at:.6f}"
    ).encode()
    digest = hashlib.sha256(material).hexdigest()[:24]
    prefix = (
        f"{provider_id}:{lane_id}"
        if source_instance_id == "default"
        else f"{provider_id}:{source_instance_id}:{lane_id}"
    )
    return f"{prefix}:{digest}"


def merged_edge_baseline(previous, current):
    """The next edge comparison's BEFORE: last COMPARABLE reading per
    provider.

    Edge detectors skip a before-snapshot that is not READY/STALE -- so
    a vendor incident's degraded snapshot, published between two good
    readings, used to WIPE the pre-reset baseline and swallow the
    crossing (2026-08-27: the owner's Codex refill went uncelebrated
    behind exactly that interlude). A degraded or missing current
    snapshot keeps the provider's previous baseline instead.
    """
    from dataclasses import replace as dataclass_replace

    comparable = {ProviderSourceState.READY, ProviderSourceState.STALE}
    before = _snapshot_map(previous.snapshots)
    kept = []
    for snapshot in current.snapshots:
        held = before.get(snapshot.identity)
        if snapshot.state in comparable or held is None:
            kept.append(snapshot)
        else:
            kept.append(held)
    current_ids = {snapshot.identity for snapshot in current.snapshots}
    kept.extend(
        snapshot
        for identity, snapshot in before.items()
        if identity not in current_ids
    )
    return dataclass_replace(current, snapshots=tuple(kept))


def detect_reset_events(
    previous: tuple[ProviderUsageSnapshot, ...],
    current: tuple[ProviderUsageSnapshot, ...],
    *,
    seen_event_ids: frozenset[str],
) -> tuple[ResetEvent, ...]:
    before_by_provider = _snapshot_map(previous)
    events: list[ResetEvent] = []
    for after in current:
        if after.state is not ProviderSourceState.READY:
            continue
        before = before_by_provider.get(after.identity)
        if before is None or before.state not in {
            ProviderSourceState.READY,
            ProviderSourceState.STALE,
        }:
            continue
        before_lanes = _lane_map(before)
        for lane_after in after.lanes:
            lane_before = before_lanes.get(lane_after.lane_id)
            if (
                lane_before is None
                or lane_before.reset_at is None
                or lane_after.reset_at is None
                or lane_before.remaining_percent is None
                or lane_after.remaining_percent is None
                or lane_after.reset_at <= lane_before.reset_at
            ):
                continue
            # Two independent detectors, either fires:
            #   TIMING -- the reset moment passed between our looks. One
            #   failed poll re-stamps observed_at past the boundary
            #   (select_authoritative_snapshot) and blinds this forever,
            #   which is how the owner's live reset went unseen.
            #   JUMP -- remaining leapt >= 50 points while the window
            #   advanced: unmistakably a refill, whatever the clocks
            #   claim (the usage-hook heuristic, promoted).
            crossed = (
                before.observed_at < lane_before.reset_at <= after.observed_at
                and lane_after.remaining_percent
                > lane_before.remaining_percent + 5.0
            )
            jumped = (
                lane_after.remaining_percent
                >= lane_before.remaining_percent + 50.0
            )
            if not crossed and not jumped:
                continue
            event_id = _event_id(
                after.provider_id,
                after.source_instance_id,
                lane_after.lane_id,
                lane_before.reset_at,
            )
            if event_id in seen_event_ids:
                continue
            events.append(
                ResetEvent(
                    event_id,
                    after.provider_id,
                    lane_after.lane_id,
                    f"{lane_after.label} reset",
                    after.observed_at,
                    after.source_instance_id,
                    lane_before.reset_at,
                    RESET_TRIGGER_TIMING if crossed else RESET_TRIGGER_JUMP,
                    lane_after.reset_at,
                    lane_after.remaining_percent,
                    lane_before.remaining_percent,
                )
            )
    return tuple(events)


def _candidate_from(event: ResetEvent) -> ResetCandidate | None:
    if (
        event.reset_boundary is None
        or event.after_reset_at is None
        or event.after_remaining is None
        or event.before_remaining is None
    ):
        return None
    return ResetCandidate(
        event.event_id,
        event.provider_id,
        event.source_instance_id,
        event.lane_id,
        event.label,
        float(event.reset_boundary),
        float(event.after_reset_at),
        float(event.after_remaining),
        float(event.before_remaining),
        float(event.occurred_at),
    )


def _confirmed(candidate: ResetCandidate, observed_at: float) -> ResetEvent:
    return ResetEvent(
        candidate.event_id,
        candidate.provider_id,
        candidate.lane_id,
        candidate.label,
        observed_at,
        candidate.source_instance_id,
        candidate.reset_boundary,
        RESET_TRIGGER_JUMP,
        candidate.after_reset_at,
        candidate.after_remaining,
        candidate.before_remaining,
    )


def _judge_candidate(
    candidate: ResetCandidate,
    snapshot: ProviderUsageSnapshot | None,
) -> str:
    """``keep``, ``confirm`` or ``discard`` for one waiting jump."""
    if snapshot is None or snapshot.state is not ProviderSourceState.READY:
        return "keep"
    lane = _lane_map(snapshot).get(candidate.lane_id)
    if lane is None or lane.remaining_percent is None or lane.reset_at is None:
        return "discard"
    age = snapshot.observed_at - candidate.observed_at
    if age <= 0.0:
        return "keep"
    if age > RESET_CONFIRM_MAX_S:
        return "discard"
    moved = lane.reset_at - candidate.after_reset_at
    # A rolling unused window: nobody has started it, so the provider
    # quotes "now + one window" as its reset on every read, and the reset
    # time moves with the clock. That is a window waiting to start, not
    # one that just reset (CodexBar #3851).
    if (
        lane.remaining_percent >= RESET_UNUSED_REMAINING
        and candidate.after_remaining >= RESET_UNUSED_REMAINING
        and age >= RESET_CONFIRM_MIN_S
        and moved >= age / 2.0
    ):
        return "discard"
    holds = (
        lane.remaining_percent >= candidate.before_remaining + RESET_JUMP_POINTS
        and abs(moved) <= RESET_BOUNDARY_TOLERANCE_S
    )
    if not holds:
        return "discard"
    if age < RESET_CONFIRM_MIN_S:
        return "keep"
    return "confirm"


def confirm_reset_events(
    detected: tuple[ResetEvent, ...],
    current: tuple[ProviderUsageSnapshot, ...],
    *,
    candidates: tuple[ResetCandidate, ...] = (),
    seen_event_ids: frozenset[str] = frozenset(),
) -> ResetConfirmation:
    """The one reset rule every consumer shares.

    ``detected`` is ``detect_reset_events`` over the same reads. A TIMING
    reset is announced at once. A JUMP becomes a candidate, and a later
    READY read confirms it when it comes 60 s to 30 min after the jump,
    still shows remaining at least 50 points above the pre-reset value,
    and names a reset time within two minutes of the jump's. Anything else
    discards it, and so does a rolling unused window. The celebrations,
    the ``quota_reset`` wire event and the usage hooks all take the events
    from here, so they agree, and they share one ``event_id``.
    """
    by_identity = _snapshot_map(current)
    events: list[ResetEvent] = []
    kept: list[ResetCandidate] = []
    announced: set[str] = set()
    for candidate in candidates:
        verdict = _judge_candidate(
            candidate,
            by_identity.get((candidate.provider_id, candidate.source_instance_id)),
        )
        if verdict == "keep":
            kept.append(candidate)
        elif verdict == "confirm" and candidate.event_id not in seen_event_ids:
            snapshot = by_identity[(candidate.provider_id, candidate.source_instance_id)]
            events.append(_confirmed(candidate, snapshot.observed_at))
            announced.add(candidate.event_id)
    waiting = {candidate.event_id for candidate in kept}
    for event in detected:
        if event.event_id in seen_event_ids or event.event_id in announced:
            continue
        if event.trigger == RESET_TRIGGER_TIMING:
            events.append(event)
            announced.add(event.event_id)
            waiting.discard(event.event_id)
            kept = [candidate for candidate in kept if candidate.event_id != event.event_id]
            continue
        if event.event_id in waiting:
            continue
        candidate = _candidate_from(event)
        if candidate is not None:
            kept.append(candidate)
            waiting.add(candidate.event_id)
    return ResetConfirmation(tuple(events), tuple(kept))


def threshold_crossings(
    previous: tuple[ProviderUsageSnapshot, ...],
    current: tuple[ProviderUsageSnapshot, ...],
    thresholds: dict[object, float],
) -> tuple[ThresholdCrossing, ...]:
    before_by_provider = _snapshot_map(previous)
    crossings: list[ThresholdCrossing] = []
    for after in current:
        if after.state is not ProviderSourceState.READY:
            continue
        threshold = thresholds.get(
            after.identity,
            thresholds.get(after.provider_id),
        )
        if (
            isinstance(threshold, bool)
            or not isinstance(threshold, (int, float))
            or not math.isfinite(float(threshold))
            or not 0.0 <= float(threshold) <= 100.0
        ):
            continue
        before = before_by_provider.get(after.identity)
        if before is None:
            continue
        before_lanes = _lane_map(before)
        for lane_after in after.lanes:
            lane_before = before_lanes.get(lane_after.lane_id)
            if (
                lane_before is None
                or lane_before.remaining_percent is None
                or lane_after.remaining_percent is None
                or not (
                    lane_before.remaining_percent > float(threshold)
                    >= lane_after.remaining_percent
                )
            ):
                continue
            crossings.append(
                ThresholdCrossing(
                    after.provider_id,
                    lane_after.lane_id,
                    lane_after.label,
                    lane_after.remaining_percent,
                    float(threshold),
                    after.source_instance_id,
                )
            )
    return tuple(crossings)


#: Eight meter cells, one per LED -- the meter speaks the strip's own
#: language (codebar/t3code-style at-a-glance limits).
METER_CELLS = 8


def format_lane_meter(remaining: float) -> str:
    filled = int(round(max(0.0, min(100.0, float(remaining))) / 100.0 * METER_CELLS))
    if filled == 0 and remaining > 0.0:
        # A nearly-exhausted lane still shows one lit cell: "almost out"
        # and "out" must not render identically.
        filled = 1
    return "▰" * filled + "▱" * (METER_CELLS - filled)


def format_reset_countdown(reset_at: float | None, *, now: float) -> str:
    if (
        reset_at is None
        or isinstance(reset_at, bool)
        or not isinstance(reset_at, (int, float))
        or not math.isfinite(float(reset_at))
    ):
        return "reset unknown"
    seconds = max(0, int(math.ceil(float(reset_at) - float(now))))
    if seconds <= 0:
        # A reset moment more than a couple of minutes in the past is
        # not "resetting now" -- it means the READING predates the
        # reset. Three stale lanes all chanting "resetting now" forever
        # (live, 2026-08-26) told the user the provider was stuck when
        # it was the number that was old.
        if float(now) - float(reset_at) > 120.0:
            return "reset passed — reading is older"
        return "resetting now"
    minutes = max(1, seconds // 60)
    if minutes < 60:
        return f"resets in {minutes}m"
    hours, remaining_minutes = divmod(minutes, 60)
    if hours < 24:
        return f"resets in {hours}h {remaining_minutes}m"
    days, remaining_hours = divmod(hours, 24)
    return f"resets in {days}d {remaining_hours}h"


def usage_totals(
    snapshots: tuple[ProviderUsageSnapshot, ...],
) -> UsageTotals:
    input_tokens = sum(snapshot.input_tokens for snapshot in snapshots)
    cached_input_tokens = sum(snapshot.cached_input_tokens for snapshot in snapshots)
    output_tokens = sum(snapshot.output_tokens for snapshot in snapshots)
    providers_with_usage = sum(
        1
        for snapshot in snapshots
        if snapshot.input_tokens
        or snapshot.cached_input_tokens
        or snapshot.output_tokens
        or snapshot.estimated_cost_usd is not None
    )
    model_observations = sum(snapshot.model_count for snapshot in snapshots)
    cost_values = tuple(
        snapshot.estimated_cost_usd
        for snapshot in snapshots
        if snapshot.estimated_cost_usd is not None
    )
    saving_values = tuple(
        snapshot.cache_savings_usd
        for snapshot in snapshots
        if snapshot.cache_savings_usd is not None
    )
    return UsageTotals(
        input_tokens,
        cached_input_tokens,
        output_tokens,
        providers_with_usage,
        model_observations,
        sum(cost_values) if cost_values else None,
        sum(saving_values) if saving_values else None,
    )


__all__ = [
    "RESET_CONFIRM_MAX_S",
    "RESET_CONFIRM_MIN_S",
    "RESET_TRIGGER_JUMP",
    "RESET_TRIGGER_TIMING",
    "ResetCandidate",
    "ResetConfirmation",
    "ResetEvent",
    "ThresholdCrossing",
    "UsageTotals",
    "confirm_reset_events",
    "detect_reset_events",
    "format_lane_meter",
    "format_reset_countdown",
    "threshold_crossings",
    "usage_totals",
]
