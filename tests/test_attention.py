from __future__ import annotations

from dataclasses import replace
from datetime import datetime, timezone

from jrbar.ambient_effect_runtime import install_ambient_effect_runtime
from jrbar.attention import (
    LifecycleMode,
    SignalKind,
    project_attention,
    quiet_worker_request_keys,
    regate_actionable_attention,
    stable_event_key,
)
from jrbar.capacity_types import SourceKey
from jrbar.collector import LiveAgentMonitor, MonitorSnapshot, aggregate_status
from jrbar.dnd_policy import compose_dnd_contributions
from jrbar.effect_assignment_store import EffectAssignmentCache
from jrbar.models import AgentMode, AgentStatus, HookEvent
from jrbar.operator_state import BootIdentifier, ClockSample
from jrbar.provider_adapters import minimize_hook_event, provider_facts_for_record
from jrbar.provider_facts import (
    RequestIdentifier,
    RequestKey,
    WorkIdentifier,
    WorkKey,
)
from jrbar.providers import negotiated_provider_sources
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


def test_the_live_path_carries_the_request_identity_and_the_failure_edge__and_1_more() -> None:
    # --- scenario: the_live_path_carries_the_request_identity_and_the_failure_edge
    """The daemon's lights and asks come from project_attention over the
    monitor snapshot: an ask keeps the work and request identity its
    status carries (what regate and the answer path key on), and a
    terminal failure beside it still fires its signal."""
    source = SourceKey("codex", "hooks", "global", "live_agent_events")
    work_key = WorkKey(source, WorkIdentifier("work:canonical"))
    request_key = RequestKey(work_key, RequestIdentifier("request:canonical"))
    asking = replace(
        status(
            provider="codex",
            agent_id="codex:session:asking",
            event_name="PermissionRequest",
            mode=AgentMode.WAITING_FOR_INPUT,
        ),
        work_key=work_key,
        request_key=request_key,
    )
    failed = status(
        provider="codex",
        agent_id="codex:session:failed",
        event_name="StopFailure",
        mode=AgentMode.BLOCKED_ERROR,
    )

    projection = project_attention(snapshot_with(asking, failed), AgentMonitorSettings())

    (row,) = projection.actionable_attention
    assert row.work_key == work_key
    assert row.request_key == request_key
    assert projection.click_target_agent_id == asking.agent_id
    assert [signal.source_agent_id for signal in projection.transient_signals] == [failed.agent_id]

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


def test_regate_demotes_asks_the_canonical_state_no_longer_holds__and_1_more() -> None:
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


_CLAUDE_HOOKS = SourceKey("claude", "hooks", "global", "live_agent_events")
_CANONICAL_BASE = 1_786_536_000.0


def _canonical_permission_request_snapshot(
    *, session_id: str, agent_id: str | None
) -> MonitorSnapshot:
    """One Claude PermissionRequest, carried through the real canonical path."""
    source = next(
        row
        for row in negotiated_provider_sources()
        if row.source_key == _CLAUDE_HOOKS
    )
    boot = BootIdentifier("boot:attention")
    monitor = LiveAgentMonitor(
        clock_sampler=lambda: ClockSample(_CANONICAL_BASE + 1.0, 101.0, boot),
    )
    ingress = HookEvent(
        provider="claude",
        logged_at=datetime.fromtimestamp(_CANONICAL_BASE, tz=timezone.utc),
        event_name="PermissionRequest",
        raw={"request_id": "request:one", "event_id": "event:one", "sequence": 1},
        session_id=session_id,
        agent_id=agent_id,
        tool_name="Bash",
    )
    normalized = minimize_hook_event(
        ingress,
        source_key=source.source_key,
        contract=source.contract,
        observation_authority=source.registration.observation_authority,
    )
    batch = provider_facts_for_record(
        normalized,
        contract=source.contract,
        observation_authority=source.registration.observation_authority,
        observed_at_epoch=_CANONICAL_BASE,
    )
    monitor.ingest_batch(batch, clock=ClockSample(_CANONICAL_BASE, 100.0, boot))
    return monitor.snapshot()


def _ambient_probe(settings: AgentMonitorSettings):
    """A controller that only carries what the ambient runtime reads."""

    class Probe:
        _effect_assignment_cache = EffectAssignmentCache()

        def __init__(self) -> None:
            self.settings = settings
            self.virtual_status_device = object()
            self._notification_action_bindings = {}

        def current_dnd_projection(self):
            return compose_dnd_contributions(())

        def _deliver_semantic_notification(self, *_args, **_kwargs):
            return False

        def _activate_notification_action(self, _token):
            return False

        def observe_operator_history_events(self, _events, _state):
            return None

    install_ambient_effect_runtime(Probe)
    return Probe()


def test_a_workers_permission_request_agrees_across_the_panel_and_the_lights() -> None:
    worker = _canonical_permission_request_snapshot(
        session_id="session:main",
        agent_id="agent:worker",
    )
    main = _canonical_permission_request_snapshot(
        session_id="session:main",
        agent_id=None,
    )
    assert [status.is_subagent for status in worker.statuses] == [True]
    assert [status.is_subagent for status in main.statuses] == [False]

    for alert in (False, True):
        settings = replace(AgentMonitorSettings(), subagent_asks_alert=alert)
        panel_asks = len(project_attention(worker, settings).actionable_attention)
        controller = _ambient_probe(settings)
        controller.observe_operator_history_events(
            worker.operator_events,
            worker.operator_state,
        )
        quiet = quiet_worker_request_keys(
            worker.operator_state,
            subagent_asks_alert=alert,
        )

        # One setting, one answer: the panel's asks, the ambient heartbeat and
        # the quiet set never disagree about whether the worker's ask counts.
        assert panel_asks == (1 if alert else 0)
        assert controller._ask_heartbeat_plan.request_count == panel_asks
        assert len(quiet) == (0 if alert else 1)
        # The request is canonical truth either way.
        assert len(worker.operator_state.requests) == 1

    # A main session's ask is never quiet, and rings with the setting off.
    off = AgentMonitorSettings()
    controller = _ambient_probe(off)
    controller.observe_operator_history_events(main.operator_events, main.operator_state)
    assert len(project_attention(main, off).actionable_attention) == 1
    assert controller._ask_heartbeat_plan.request_count == 1
    assert quiet_worker_request_keys(main.operator_state, subagent_asks_alert=False) == frozenset()


def test_the_quiet_set_is_empty_without_workers_and_when_the_setting_is_on() -> None:
    worker = _canonical_permission_request_snapshot(
        session_id="session:main",
        agent_id="agent:worker",
    )
    state = worker.operator_state
    request_keys = {request.key for request in state.requests}

    assert quiet_worker_request_keys(state, subagent_asks_alert=False) == request_keys
    assert quiet_worker_request_keys(state, subagent_asks_alert=True) == frozenset()
