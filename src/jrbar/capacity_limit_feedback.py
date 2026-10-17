"""A finite capacity notice, separate from a session failure alarm."""

from __future__ import annotations

from .models import AgentMode
from .provider_facts import ProviderTerminalCause, SourceFreshness
from .provider_usage_platform import ProviderSourceState, most_constrained_lane

CAPACITY_NOTICE_SECONDS = 4.0
_MAX_EPISODES = 256


def is_capacity_terminal(item) -> bool:
    cause = getattr(item, "terminal_cause", None)
    return type(cause) is ProviderTerminalCause and cause in {
        ProviderTerminalCause.CLAUDE_RATE_LIMIT, ProviderTerminalCause.CODEX_USAGE_LIMIT,
    }


def _identity(status) -> tuple[str, str]:
    source = getattr(getattr(status, "work_key", None), "source_key", None)
    instance = getattr(source, "source_instance_id", "global")
    return status.provider, "default" if instance == "global" else instance


def update_capacity_limit_alert(controller, projection, *, wall_now: float, monotonic_now: float, signal_kind, operator_events=()) -> None:
    statuses = tuple(row.source_status for row in projection.all_rows)
    seen = dict(getattr(controller, "_capacity_limit_seen", {}))
    recovered = dict(getattr(controller, "_capacity_limit_recovered", {}))
    limited_lanes = dict(getattr(controller, "_capacity_limit_lanes", {}))
    initialized = bool(getattr(controller, "_capacity_limit_initialized", False))
    usage = getattr(controller, "provider_usage_state", None)
    snapshots = tuple(getattr(usage, "snapshots", ()))
    measured_identities = {snapshot.identity for snapshot in snapshots}
    if not initialized:
        for snapshot in snapshots:
            if snapshot.state not in {ProviderSourceState.READY, ProviderSourceState.STALE}:
                continue
            lane = most_constrained_lane(snapshot, now=wall_now)
            if lane is not None and lane.remaining_percent == 0 and snapshot.effective_read_at <= wall_now:
                seen[snapshot.identity] = snapshot.effective_read_at

    for snapshot in snapshots:
        exhausted = frozenset(
            lane.lane_id for lane in snapshot.lanes
            if getattr(lane, "bindable", True) and lane.remaining_percent == 0
            and getattr(lane, "lane_id", None) is not None
        )
        if exhausted:
            limited_lanes[snapshot.identity] = limited_lanes.get(snapshot.identity, frozenset()) | exhausted

    for status in statuses:
        key = _identity(status)
        at = status.updated_at.timestamp()
        if (key not in measured_identities and key not in limited_lanes
                and status.mode is AgentMode.COMPLETED and not status.stale
                and at > seen.get(key, float("inf"))):
            recovered[key] = max(recovered.get(key, 0.0), at)
            seen.pop(key, None)
            limited_lanes.pop(key, None)
    for snapshot in snapshots:
        key = snapshot.identity
        if key not in seen or snapshot.state is not ProviderSourceState.READY:
            continue
        lanes = tuple(lane for lane in snapshot.lanes if getattr(lane, "bindable", True))
        present = {getattr(lane, "lane_id", None) for lane in lanes}
        if (lanes and limited_lanes.get(key, frozenset()) <= present
                and all(lane.remaining_percent is not None and lane.remaining_percent > 0 for lane in lanes)
                and seen[key] < snapshot.effective_read_at <= wall_now):
            recovered[key] = max(recovered.get(key, 0.0), snapshot.effective_read_at)
            seen.pop(key, None)
            limited_lanes.pop(key, None)

    occurrences = [
        (_identity(status), status.updated_at.timestamp(), status.stale)
        for status in statuses if status.is_capacity_limited
    ]
    for event in operator_events:
        if not is_capacity_terminal(event):
            continue
        source = event.subject_key.source_key
        instance = "default" if source.source_instance_id == "global" else source.source_instance_id
        occurrences.append(((source.provider_id, instance), event.occurred_at_epoch,
                            event.source_freshness is not SourceFreshness.FRESH))
    new = set()
    for key, at, stale in occurrences:
        if at <= recovered.get(key, 0.0):
            continue
        if key not in seen and initialized and not stale and 0 <= wall_now - at <= 60:
            new.add(key)
        seen[key] = max(seen.get(key, 0.0), at)
    controller._capacity_limit_seen = dict(list(seen.items())[-_MAX_EPISODES:])
    controller._capacity_limit_recovered = dict(list(recovered.items())[-_MAX_EPISODES:])
    controller._capacity_limit_lanes = dict(list(limited_lanes.items())[-_MAX_EPISODES:])
    controller._capacity_limit_initialized = True
    if not new or not controller.settings.quota_alerts_enabled:
        return
    if not controller.may_interrupt(signal_kind) or controller.quiet_active():
        return
    controller._capacity_notice_until = monotonic_now + CAPACITY_NOTICE_SECONDS
    controller.quota_blink_until = max(controller.quota_blink_until, controller._capacity_notice_until)
    publish = getattr(controller, "_core_publish_event", None)
    for provider, _instance in sorted(new):
        if not callable(publish):
            break
        publish(
            "quota_crossed", provider=provider, detail="limit reached",
            label="Usage limit reached. Open Usage for the latest reading.",
        )
    controller.schedule_event_refresh()
