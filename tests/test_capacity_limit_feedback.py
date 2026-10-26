from datetime import datetime, timezone
from types import SimpleNamespace

from jrbar.capacity_limit_feedback import CAPACITY_NOTICE_SECONDS, update_capacity_limit_alert
from jrbar.dot_role import DotBeaconFacts, beacon_program
from jrbar.models import AgentMode, AgentStatus
from jrbar.provider_facts import ProviderTerminalCause, SourceKey, WorkIdentifier, WorkKey
from jrbar.provider_usage_platform import ProviderSourceState


def status(at=1000, *, instance="global", mode=AgentMode.BLOCKED_ERROR, capacity=True, stale=False):
    key = WorkKey(SourceKey("claude", "hooks", instance, "live_agent_events"), WorkIdentifier("fixture"))
    return AgentStatus("claude", "claude:session:fixture", "Claude", mode,
                       datetime.fromtimestamp(at, timezone.utc), "StopFailure",
                       work_key=key, stale=stale,
                       terminal_cause=ProviderTerminalCause.CLAUDE_RATE_LIMIT if capacity else ProviderTerminalCause.NONE)


def controller(enabled=True, quiet=False):
    events = []
    c = SimpleNamespace(settings=SimpleNamespace(quota_alerts_enabled=enabled),
                        quota_blink_until=0, may_interrupt=lambda _: True,
                        quiet_active=lambda: quiet,
                        _core_publish_event=lambda kind, **fields: events.append((kind, fields)),
                        schedule_event_refresh=lambda: None,
                        provider_usage_state=SimpleNamespace(snapshots=()))
    return c, events


def apply(c, *rows, wall=1000, tick=20, events=()):
    projection = SimpleNamespace(all_rows=tuple(SimpleNamespace(source_status=row) for row in rows))
    update_capacity_limit_alert(c, projection, wall_now=wall, monotonic_now=tick, signal_kind="quota", operator_events=events)


def test_limit_is_one_finite_notice_then_dot_returns_to_normal_without_rearming():
    c, events = controller()
    apply(c)
    apply(c, status())
    assert c.quota_blink_until == 20 + CAPACITY_NOTICE_SECONDS
    assert [kind for kind, _ in events] == ["quota_crossed"]
    before = beacon_program(DotBeaconFacts(capacity_active=23 < c.quota_blink_until))
    after = beacon_program(DotBeaconFacts(capacity_active=25 < c.quota_blink_until))
    assert before[1:] == ("capacity", True)
    assert after == ("off", "idle", False)
    apply(c, status(at=1003), wall=1003, tick=25)
    assert c.quota_blink_until == 24 and len(events) == 1


def test_boot_and_old_replay_do_not_announce_a_known_spent_provider():
    c, events = controller()
    apply(c, status())
    apply(c, status(at=1001), wall=1001)
    assert c.quota_blink_until == 0 and events == []
    other, events = controller()
    apply(other)
    apply(other, status(at=600))
    assert other.quota_blink_until == 0 and events == []


def test_quiet_and_disabled_alerts_do_not_return_as_late_notifications():
    for enabled, quiet in [(False, False), (True, True)]:
        c, events = controller(enabled, quiet)
        apply(c)
        apply(c, status())
        c.settings.quota_alerts_enabled = True
        c.quiet_active = lambda: False
        apply(c, status(at=1002), wall=1002)
        assert c.quota_blink_until == 0 and events == []


def test_recovery_rearms_new_limit_but_never_replays_the_old_limit():
    c, events = controller()
    apply(c)
    apply(c, status())
    apply(c, status(at=1002, mode=AgentMode.COMPLETED, capacity=False), wall=1002)
    apply(c, status(), wall=1003)
    assert len(events) == 1
    apply(c, status(at=1004), wall=1004, tick=30)
    assert len(events) == 2 and c.quota_blink_until == 34


def test_fresh_positive_quota_recovers_only_its_own_instance():
    c, events = controller()
    apply(c)
    apply(c, status(), status(instance="work"))
    c.provider_usage_state = SimpleNamespace(snapshots=(SimpleNamespace(
        identity=("claude", "default"), state=ProviderSourceState.READY,
        effective_read_at=1002, lanes=(SimpleNamespace(remaining_percent=80),)),))
    apply(c, status(), status(instance="work"), wall=1002)
    apply(c, status(at=1003), status(at=1003, instance="work"), wall=1003)
    assert len(events) == 3  # two initial profiles, then only the recovered default


def test_real_asks_and_new_non_capacity_failures_keep_priority():
    assert beacon_program(DotBeaconFacts(ask_count=1, capacity_active=True))[1] == "waiting"
    assert beacon_program(DotBeaconFacts(failure_active=True, capacity_active=True))[1] == "failed"


def test_stale_boot_limit_cannot_become_a_new_notice_when_the_same_event_freshens():
    c, events = controller()
    apply(c, status(stale=True))
    apply(c, status(), wall=1001)
    assert c.quota_blink_until == 0 and events == []


def test_capacity_session_keeps_ended_history_without_failure_attention():
    from jrbar.attention import LifecycleMode, project_attention
    from jrbar.core_projection import build_state_document, session_document
    from jrbar.settings import AgentMonitorSettings

    limited = status()
    snapshot = SimpleNamespace(statuses=(limited,), stale_statuses=(),
                               collected_at=datetime.fromtimestamp(1000, timezone.utc))
    projection = project_attention(snapshot, AgentMonitorSettings())
    assert projection.lifecycle_mode is LifecycleMode.IDLE
    assert projection.transient_signals == ()
    live = build_state_document(generation=1, now=1000, snapshot=snapshot,
                               ask_statuses=[], unseen_completion_ids=frozenset())
    assert live["sessions"] == [] and live["aggregate"]["failed"] == 0
    history = session_document(limited, operator_state=None, ask_ids=frozenset(),
                               extras=None, workers=0, now=1000)
    assert history["lifecycle"] == "ended"
    assert history["axes"]["outcome"] == "unreported"
    assert history["terminal_cause"] == "claude_rate_limit"


def test_capacity_operator_event_cannot_bypass_the_normal_attention_filter():
    from jrbar.accessibility_display import AccessibilityDisplayPreferences
    from jrbar.attention import LifecycleMode, project_attention
    from jrbar.daemon_controller import StatusBarController
    from jrbar.operator_state import CanonicalOperatorEvent, SemanticEventKey, TransitionKind, classify_operator_event
    from jrbar.presentation_policy import GlanceSemantic
    from jrbar.provider_facts import EventToken, ProviderWatermark, SourceFreshness, WatermarkBasis
    from jrbar.settings import AgentMonitorSettings

    limited = status()
    snapshot = SimpleNamespace(statuses=(limited,), stale_statuses=(),
                               collected_at=datetime.fromtimestamp(1000, timezone.utc))
    projection = project_attention(snapshot, AgentMonitorSettings())
    assert projection.lifecycle_mode is LifecycleMode.IDLE
    watermark = ProviderWatermark(limited.work_key.source_key, WatermarkBasis.PROVIDER_EVENT_ID,
                                   1000, EventToken("fixture-event"), None, 0)
    event = CanonicalOperatorEvent(SemanticEventKey(limited.work_key, TransitionKind.FAILED, watermark),
                                   limited.work_key, TransitionKind.FAILED,
                                   classify_operator_event(TransitionKind.FAILED), 1000,
                                   SourceFreshness.FRESH, terminal_cause=limited.terminal_cause)
    c = SimpleNamespace(_accessibility_display_preferences=AccessibilityDisplayPreferences(), _relay_epoch=0)
    result = StatusBarController.resolve_presentation_glance(c, projection,
                operator_events=(event,), capacity=None, presentation_time=20)
    assert result.semantic is GlanceSemantic.REST


def test_failure_followed_by_prompt_in_one_snapshot_still_gives_only_one_capacity_notice():
    from jrbar.operator_state import CanonicalOperatorEvent, SemanticEventKey, TransitionKind, classify_operator_event
    from jrbar.provider_facts import EventToken, ProviderWatermark, SourceFreshness, WatermarkBasis

    limited = status()
    watermark = ProviderWatermark(limited.work_key.source_key, WatermarkBasis.PROVIDER_EVENT_ID,
                                   1000, EventToken("fixture-event"), None, 0)
    event = CanonicalOperatorEvent(SemanticEventKey(limited.work_key, TransitionKind.FAILED, watermark),
                                   limited.work_key, TransitionKind.FAILED,
                                   classify_operator_event(TransitionKind.FAILED), 1000,
                                   SourceFreshness.FRESH, terminal_cause=limited.terminal_cause)
    c, notices = controller()
    apply(c)
    prompted = status(at=1001, mode=AgentMode.WORKING, capacity=False)
    apply(c, prompted, wall=1001, events=(event,))
    assert len(notices) == 1 and c.quota_blink_until == 24
    apply(c, prompted, wall=1002, tick=25, events=(event,))
    assert len(notices) == 1 and c.quota_blink_until == 24


def test_boot_with_an_already_spent_quota_does_not_realert_on_another_attempt():
    from jrbar.provider_usage_platform import ProviderUsageSnapshot, UsageLane

    snapshot = ProviderUsageSnapshot(
        provider_id="claude", account_label=None, observed_at=1000,
        state=ProviderSourceState.READY, reason_code=None, action_label=None,
        lanes=(UsageLane(provider_id="claude", lane_id="seven_day", label="7d",
                         remaining_percent=0, reset_at=5000, scope="all", model=None,
                         feature=None, bindable=True, source_id="official"),),
        input_tokens=0, cached_input_tokens=0, output_tokens=0, model_count=0,
        estimated_cost_usd=None, cache_savings_usd=None, credits_remaining=None, incident=None)
    c, events = controller()
    c.provider_usage_state = SimpleNamespace(snapshots=(snapshot,))
    apply(c)
    apply(c, status(at=1001), wall=1001)
    assert c.quota_blink_until == 0 and events == []


def usage_snapshot(at, lanes, state=ProviderSourceState.READY):
    return SimpleNamespace(identity=("claude", "default"), state=state,
                           effective_read_at=at,
                           lanes=tuple(SimpleNamespace(lane_id=key, remaining_percent=value)
                                       for key, value in lanes))


def test_completion_cannot_rearm_an_exhausted_weekly_budget():
    for state in (ProviderSourceState.READY, ProviderSourceState.STALE):
        c, events = controller()
        apply(c)
        apply(c, status())
        c.provider_usage_state = SimpleNamespace(snapshots=(usage_snapshot(
            1001, (("seven_day", 0), ("five_hour", 80)), state),))
        apply(c, status(at=1002, mode=AgentMode.COMPLETED, capacity=False), wall=1002)
        apply(c, status(at=1004), wall=1004, tick=30)
        assert len(events) == 1 and c.quota_blink_until == 24


def test_unknown_or_missing_exhausted_lane_cannot_rearm_the_notice():
    for lanes in ((("seven_day", None), ("five_hour", 80)), (("five_hour", 80),)):
        c, events = controller()
        apply(c)
        apply(c, status())
        c.provider_usage_state = SimpleNamespace(snapshots=(usage_snapshot(
            1001, (("seven_day", 0), ("five_hour", 80))),))
        apply(c, status(), wall=1001)
        c.provider_usage_state = SimpleNamespace(snapshots=(usage_snapshot(1002, lanes),))
        apply(c, status(at=1003), wall=1003, tick=30)
        assert len(events) == 1 and c.quota_blink_until == 24


def test_confirmed_weekly_recovery_allows_one_new_limit_notice():
    c, events = controller()
    apply(c)
    apply(c, status())
    c.provider_usage_state = SimpleNamespace(snapshots=(usage_snapshot(
        1001, (("seven_day", 0), ("five_hour", 80))),))
    apply(c, status(), wall=1001)
    c.provider_usage_state = SimpleNamespace(snapshots=(usage_snapshot(
        1002, (("seven_day", 100), ("five_hour", 80))),))
    apply(c, status(), wall=1002)
    apply(c, status(at=1003), wall=1003, tick=30)
    apply(c, status(at=1004), wall=1004, tick=31)
    assert len(events) == 2 and c.quota_blink_until == 34


def test_removed_usage_snapshot_does_not_turn_completion_into_recovery():
    c, events = controller()
    apply(c)
    apply(c, status())
    c.provider_usage_state = SimpleNamespace(snapshots=(usage_snapshot(1001, (("seven_day", 0),)),))
    apply(c, status(), wall=1001)
    c.provider_usage_state = SimpleNamespace(snapshots=())
    apply(c, status(at=1002, mode=AgentMode.COMPLETED, capacity=False), wall=1002)
    apply(c, status(at=1003), wall=1003, tick=30)
    assert len(events) == 1 and c.quota_blink_until == 24


def test_worker_capacity_failure_never_becomes_a_quota_notice_or_blink():
    from dataclasses import replace

    from jrbar.models import ParentLink
    from jrbar.provider_facts import SourceFreshness
    for linked in (False, True):
        worker = replace(status(), agent_id='claude:agent:worker', parent_links=(
            (ParentLink('claude:agent:worker', 'claude:session:root', 'claude', 1000),) if linked else ()
        ))
        event = SimpleNamespace(terminal_cause=worker.terminal_cause, subject_key=worker.work_key,
                                occurred_at_epoch=1000, source_freshness=SourceFreshness.FRESH)
        c, notices = controller()
        apply(c)
        apply(c, worker, events=(event,))
        assert notices == []
        assert c.quota_blink_until == 0
