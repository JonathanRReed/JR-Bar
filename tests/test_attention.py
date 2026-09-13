from __future__ import annotations

from dataclasses import replace
from datetime import datetime, timezone

from jrbar.attention import (
    LifecycleMode,
    SignalKind,
    project_attention,
    project_attention_from_operator_state,
    regate_actionable_attention,
    stable_event_key,
)
from jrbar.capacity_types import SourceKey
from jrbar.collector import MonitorSnapshot, aggregate_status
from jrbar.models import AgentMode, AgentStatus
from jrbar.operator_state import (
    AcknowledgementEligibility,
    CanonicalOperatorEvent,
    CanonicalOperatorState,
    CanonicalRequestTruth,
    CanonicalWorkTruth,
    ClockContinuityState,
    ClockContinuityStatus,
    InterruptionClass,
    RequestPhase,
    SemanticEventKey,
    TransitionKind,
)
from jrbar.provider_facts import (
    EventToken,
    NextActor,
    ObservationAuthority,
    ProviderWatermark,
    RequestIdentifier,
    RequestKey,
    RequestKind,
    SourceFreshness,
    SourceHealth,
    WatermarkBasis,
    WorkIdentifier,
    WorkKey,
    WorkLifecycle,
)
from jrbar.settings import AgentMonitorSettings


def status(
    *,
    provider: str = "claude",
    agent_id: str = "claude:session:main",
    event_name: str,
    mode: AgentMode,
    updated_at: datetime = datetime(2026, 8, 12, tzinfo=timezone.utc),
) -> AgentStatus:
    return AgentStatus(
        provider=provider,
        agent_id=agent_id,
        display_name=f"{provider.title()} main",
        mode=mode,
        updated_at=updated_at,
        event_name=event_name,
        session_id="main",
    )


def snapshot_with(*statuses: AgentStatus) -> MonitorSnapshot:
    return MonitorSnapshot(
        aggregate=aggregate_status(statuses),
        statuses=statuses,
        stale_statuses=(),
        sources=(),
        collected_at=max(
            (status.updated_at for status in statuses),
            default=datetime(2026, 8, 12, tzinfo=timezone.utc),
        ),
    )


def test_terminal_failure_is_visible_but_not_actionable__and_2_more() -> None:
    # --- scenario: terminal_failure_is_visible_but_not_actionable
    failed = status(event_name="StopFailure", mode=AgentMode.BLOCKED_ERROR)

    projection = project_attention(snapshot_with(failed), AgentMonitorSettings())

    assert projection.actionable_attention == ()
    assert projection.transient_signals[0].kind is SignalKind.FAILURE
    assert projection.transient_signals[0].repetitions == 2
    assert projection.transient_signals[0].source_agent_id == failed.agent_id

    # --- scenario: transient_tool_failure_never_fires_the_failure_signal
    failed = status(event_name="PostToolUseFailure", mode=AgentMode.WORKING)

    projection = project_attention(snapshot_with(failed), AgentMonitorSettings())

    assert projection.transient_signals == ()

    # --- scenario: main_permission_request_is_persistent_attention
    snapshot = snapshot_with(
        status(event_name="PermissionRequest", mode=AgentMode.WAITING_FOR_INPUT)
    )

    projection = project_attention(snapshot, AgentMonitorSettings())

    assert len(projection.actionable_attention) == 1



def test_subagent_attention_obeys_one_setting_everywhere__and_2_more() -> None:
    # --- scenario: subagent_attention_obeys_one_setting_everywhere
    snapshot = snapshot_with(
        status(
            agent_id="claude:agent:worker",
            event_name="PermissionRequest",
            mode=AgentMode.WAITING_FOR_INPUT,
        )
    )

    assert project_attention(snapshot, AgentMonitorSettings()).actionable_attention == ()
    enabled = replace(AgentMonitorSettings(), subagent_asks_alert=True)
    assert len(project_attention(snapshot, enabled).actionable_attention) == 1

    # --- scenario: consumed_failure_event_does_not_repeat_transient_signal
    failed = status(event_name="PostToolUseFailure", mode=AgentMode.BLOCKED_ERROR)

    projection = project_attention(
        snapshot_with(failed),
        AgentMonitorSettings(),
        consumed_event_keys=(stable_event_key(failed),),
    )

    assert projection.transient_signals == ()

    # --- scenario: duplicate_failure_records_collapse_to_one_signal
    failed = status(event_name="StopFailure", mode=AgentMode.BLOCKED_ERROR)

    projection = project_attention(
        snapshot_with(failed, failed),
        AgentMonitorSettings(),
    )

    assert len(projection.transient_signals) == 1



def test_failure_aliases_share_one_stable_key_and_consumed_signal__and_2_more() -> None:
    # --- scenario: failure_aliases_share_one_stable_key_and_consumed_signal
    terminal = status(event_name="PostToolUseFailure", mode=AgentMode.BLOCKED_ERROR)
    legacy = status(event_name="PostToolUse", mode=AgentMode.BLOCKED_ERROR)

    projection = project_attention(
        snapshot_with(terminal, legacy),
        AgentMonitorSettings(),
        consumed_event_keys=(stable_event_key(terminal),),
    )

    assert stable_event_key(terminal) == stable_event_key(legacy)
    assert projection.transient_signals == ()

    # --- scenario: visible_rows_map_agent_modes_to_lifecycle_without_hiding_failure
    statuses = (
        status(event_name="Test", mode=AgentMode.IDLE_READY),
        status(event_name="PreToolUse", mode=AgentMode.TOOL_RUNNING),
        status(event_name="Stop", mode=AgentMode.WAITING_FOR_INPUT),
        status(event_name="Stop", mode=AgentMode.COMPLETED),
        status(event_name="PostToolUseFailure", mode=AgentMode.BLOCKED_ERROR),
        status(event_name="Test", mode=AgentMode.UNKNOWN),
    )

    projection = project_attention(snapshot_with(*statuses), AgentMonitorSettings())

    assert tuple(row.lifecycle_mode for row in projection.visible_rows) == (
        LifecycleMode.IDLE,
        LifecycleMode.ACTIVE,
        LifecycleMode.UNKNOWN,
        LifecycleMode.COMPLETED_RECENTLY,
        LifecycleMode.FAILED_VISIBLE,
        LifecycleMode.UNKNOWN,
    )
    assert projection.visible_rows[4].actionable is False
    assert projection.visible_rows[4].source_status is statuses[4]

    # --- scenario: mixed_snapshot_prioritizes_waiting_attention_and_its_click_target
    base = datetime(2026, 8, 12, 10, tzinfo=timezone.utc)
    first_request = status(
        provider="codex",
        agent_id="codex:session:alpha",
        event_name="PermissionRequest",
        mode=AgentMode.WAITING_FOR_INPUT,
        updated_at=base,
    )
    second_request = status(
        provider="claude",
        agent_id="claude:session:bravo",
        event_name="Notification",
        mode=AgentMode.WAITING_FOR_INPUT,
        updated_at=base.replace(minute=1),
    )
    active = status(
        provider="devin",
        agent_id="devin:session:charlie",
        event_name="PreToolUse",
        mode=AgentMode.TOOL_RUNNING,
        updated_at=base.replace(minute=2),
    )
    failure = status(
        provider="grok",
        agent_id="grok:session:delta",
        event_name="PostToolUseFailure",
        mode=AgentMode.BLOCKED_ERROR,
        updated_at=base.replace(minute=3),
    )

    projection = project_attention(
        snapshot_with(active, failure, second_request, first_request),
        AgentMonitorSettings(),
    )

    assert projection.lifecycle_mode is LifecycleMode.WAITING
    assert projection.dominant_provider == "codex"
    assert tuple(row.agent_id for row in projection.actionable_attention) == (
        "codex:session:alpha",
        "claude:session:bravo",
    )
    assert projection.click_target_agent_id == "codex:session:alpha"



def test_canonical_attention_uses_request_truth_and_semantic_failure_edges__and_1_more() -> None:
    # --- scenario: canonical_attention_uses_request_truth_and_semantic_failure_edges
    source = SourceKey("codex", "hooks", "global", "live_agent_events")
    work_key = WorkKey(source, WorkIdentifier("work:canonical"))
    request_key = RequestKey(work_key, RequestIdentifier("request:canonical"))
    watermark = ProviderWatermark(
        source,
        WatermarkBasis.PROVIDER_SEQUENCE,
        1_786_632_000.0,
        EventToken("event:canonical"),
        1,
        10,
    )
    request_event_key = SemanticEventKey(
        request_key,
        TransitionKind.REQUEST_OPENED,
        watermark,
    )
    request = CanonicalRequestTruth(
        request_key,
        RequestPhase.LIVE_UNACKNOWLEDGED,
        RequestKind.PERMISSION,
        NextActor.USER,
        watermark,
        SourceFreshness.FRESH,
        AcknowledgementEligibility.ELIGIBLE,
        request_event_key,
        watermark.occurred_at_epoch,
        1.0,
    )
    work = CanonicalWorkTruth(
        work_key,
        WorkLifecycle.WAITING,
        watermark,
        ObservationAuthority.DIRECT_PROVIDER_OBSERVATION,
        SourceHealth.HEALTHY,
        SourceFreshness.FRESH,
        NextActor.USER,
        "Codex work:canonical",
        None,
        (request_key,),
        False,
    )
    failure_key = SemanticEventKey(work_key, TransitionKind.FAILED, watermark)
    failure = CanonicalOperatorEvent(
        failure_key,
        work_key,
        TransitionKind.FAILED,
        InterruptionClass.IMPORTANT_OUTCOME,
        watermark.occurred_at_epoch,
        SourceFreshness.FRESH,
    )
    state = CanonicalOperatorState(
        1,
        1,
        (work,),
        (request,),
        ((source, watermark),),
        (),
        ClockContinuityState(ClockContinuityStatus.STABLE, None, 0),
        None,
    )

    projection = project_attention_from_operator_state(
        state,
        (failure,),
        AgentMonitorSettings(),
    )

    row = projection.actionable_attention[0]
    assert row.work_key == work_key
    assert row.request_key == request_key
    assert projection.click_target_agent_id is None
    assert projection.transient_signals[0].event_key == failure_key

    # --- scenario: completed_settles_to_idle_on_the_live_projection_path
    from datetime import timedelta

    from jrbar.operator_state import COMPLETED_RECENT_SECONDS

    finished_at = datetime(2026, 8, 12, 12, 0, 0, tzinfo=timezone.utc)
    done = status(
        event_name="Stop",
        mode=AgentMode.COMPLETED,
        updated_at=finished_at,
    )

    fresh = replace(
        snapshot_with(done),
        collected_at=finished_at
        + timedelta(seconds=COMPLETED_RECENT_SECONDS - 30.0),
    )
    fresh_row = project_attention(fresh, AgentMonitorSettings()).visible_rows[0]
    assert fresh_row.lifecycle_mode is LifecycleMode.COMPLETED_RECENTLY

    stale = replace(
        snapshot_with(done),
        collected_at=finished_at
        + timedelta(seconds=COMPLETED_RECENT_SECONDS + 60.0),
    )
    stale_row = project_attention(stale, AgentMonitorSettings()).visible_rows[0]
    assert stale_row.lifecycle_mode is LifecycleMode.IDLE, (
        "done is a moment on the LIVE path too"
    )



# --- Delegation: a paused main whose sub-agents still work ------------------


def _worker(
    mode: AgentMode,
    *,
    event_name: str,
    updated_at: datetime = datetime(2026, 8, 12, tzinfo=timezone.utc),
) -> AgentStatus:
    return AgentStatus(
        provider="claude",
        agent_id="claude:agent:worker-1",
        display_name="Task worker",
        mode=mode,
        updated_at=updated_at,
        event_name=event_name,
        session_id="main",
    )


def test_stopped_main_with_working_subagents_projects_as_working__and_2_more() -> None:
    # --- scenario: stopped_main_with_working_subagents_projects_as_working
    """Claude fires Stop the moment the main turn ends, even while its
    sub-agents carry the work -- a live ledger showed a session
    'completed' for 30+ minutes of continuous delegation."""
    stopped_main = status(event_name="Stop", mode=AgentMode.COMPLETED)
    worker = _worker(AgentMode.TOOL_RUNNING, event_name="PreToolUse")

    projection = project_attention(
        snapshot_with(stopped_main, worker), AgentMonitorSettings()
    )

    (main_row,) = projection.visible_rows
    assert main_row.lifecycle_mode is LifecycleMode.ACTIVE
    assert main_row.source_status.mode is AgentMode.WORKING, (
        "the dropdown must tell the same story as the light"
    )

    # --- scenario: stopped_main_with_finished_subagents_stays_completed
    stopped_main = status(event_name="Stop", mode=AgentMode.COMPLETED)
    finished = _worker(AgentMode.COMPLETED, event_name="SubagentStop")

    projection = project_attention(
        snapshot_with(stopped_main, finished), AgentMonitorSettings()
    )

    (main_row,) = projection.visible_rows
    assert main_row.lifecycle_mode is LifecycleMode.COMPLETED_RECENTLY

    # --- scenario: asking_main_keeps_asking_while_subagents_work
    """The promotion must never mask an ask."""
    asking_main = status(
        event_name="Notification", mode=AgentMode.WAITING_FOR_INPUT
    )
    worker = _worker(AgentMode.TOOL_RUNNING, event_name="PreToolUse")

    projection = project_attention(
        snapshot_with(asking_main, worker), AgentMonitorSettings()
    )

    (main_row,) = projection.visible_rows
    assert main_row.lifecycle_mode is LifecycleMode.WAITING
    assert main_row.actionable



def test_canonical_completed_parent_with_active_child_projects_active__and_2_more() -> None:
    # --- scenario: canonical_completed_parent_with_active_child_projects_active
    source = SourceKey("claude", "hooks", "global", "live_agent_events")
    parent_key = WorkKey(source, WorkIdentifier("work:parent"))
    child_key = WorkKey(source, WorkIdentifier("work:child"))
    watermark = ProviderWatermark(
        source,
        WatermarkBasis.PROVIDER_SEQUENCE,
        1_786_632_000.0,
        EventToken("event:delegation"),
        1,
        10,
    )
    parent = CanonicalWorkTruth(
        parent_key,
        WorkLifecycle.COMPLETED,
        watermark,
        ObservationAuthority.DIRECT_PROVIDER_OBSERVATION,
        SourceHealth.HEALTHY,
        SourceFreshness.FRESH,
        NextActor.PROVIDER,
        "Claude main",
        None,
        (),
        False,
    )
    child = CanonicalWorkTruth(
        child_key,
        WorkLifecycle.ACTIVE,
        watermark,
        ObservationAuthority.DIRECT_PROVIDER_OBSERVATION,
        SourceHealth.HEALTHY,
        SourceFreshness.FRESH,
        NextActor.PROVIDER,
        "Task worker",
        parent_key,
        (),
        False,
    )
    state = CanonicalOperatorState(
        1,
        1,
        (parent, child),
        (),
        ((source, watermark),),
        (),
        ClockContinuityState(ClockContinuityStatus.STABLE, None, 0),
        None,
    )

    projection = project_attention_from_operator_state(
        state, (), AgentMonitorSettings()
    )

    (main_row,) = projection.visible_rows
    assert main_row.lifecycle_mode is LifecycleMode.ACTIVE

    # --- scenario: regate_demotes_asks_the_canonical_state_no_longer_holds
    source = SourceKey("codex", "hooks", "global", "live_agent_events")
    work_key = WorkKey(source, WorkIdentifier("work:held"))
    held_key = RequestKey(work_key, RequestIdentifier("request:held"))
    live_key = RequestKey(work_key, RequestIdentifier("request:live"))
    held = replace(
        status(event_name="PermissionRequest", mode=AgentMode.WAITING_FOR_INPUT),
        request_key=held_key,
    )
    live = replace(
        status(
            agent_id="codex:session:other",
            event_name="PermissionRequest",
            mode=AgentMode.WAITING_FOR_INPUT,
        ),
        request_key=live_key,
    )
    projection = project_attention(
        snapshot_with(held, live), AgentMonitorSettings()
    )
    assert len(projection.actionable_attention) == 2

    gated = regate_actionable_attention(projection, frozenset({live_key}))

    (survivor,) = gated.actionable_attention
    assert survivor.request_key == live_key
    held_row = next(
        row for row in gated.visible_rows if row.request_key == held_key
    )
    assert held_row.actionable is False
    assert held_row.lifecycle_mode is LifecycleMode.UNKNOWN
    assert gated.click_target_agent_id == "codex:session:other"

    # --- scenario: regate_without_live_asks_clears_the_attention_aggregates
    source = SourceKey("codex", "hooks", "global", "live_agent_events")
    held_key = RequestKey(
        WorkKey(source, WorkIdentifier("work:held")),
        RequestIdentifier("request:held"),
    )
    held = replace(
        status(event_name="PermissionRequest", mode=AgentMode.WAITING_FOR_INPUT),
        request_key=held_key,
    )
    projection = project_attention(snapshot_with(held), AgentMonitorSettings())

    gated = regate_actionable_attention(projection, frozenset())

    assert gated.actionable_attention == ()
    assert gated.lifecycle_mode is LifecycleMode.UNKNOWN
    assert gated.click_target_agent_id is None



def test_regate_keeps_keyless_asks_and_returns_identity_when_unchanged() -> None:
    keyless = status(
        event_name="PermissionRequest", mode=AgentMode.WAITING_FOR_INPUT
    )
    projection = project_attention(
        snapshot_with(keyless), AgentMonitorSettings()
    )

    assert regate_actionable_attention(projection, frozenset()) is projection
