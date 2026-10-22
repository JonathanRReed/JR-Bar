from datetime import datetime, timezone

import pytest

from jrbar.attention import AttentionProjection, LifecycleMode, ProjectedAgentRow
from jrbar.colors import ColorSettings, plan_fleet_projection, program_for_projection, program_for_snapshot
from jrbar.models import AgentMode, AgentStatus

NOW = datetime(2026, 10, 1, tzinfo=timezone.utc)


def status(provider, mode, index=0):
    return AgentStatus(provider=provider, agent_id=f"{provider}:{index}",
                       display_name=provider, mode=mode, updated_at=NOW, event_name="PermissionRequest" if mode is AgentMode.WAITING_FOR_INPUT else "test")


def render(statuses, settings, renderer):
    if renderer == "snapshot":
        return program_for_snapshot(tuple(statuses), colors=settings, led_count=8)
    modes = {AgentMode.WORKING: LifecycleMode.ACTIVE,
             AgentMode.COMPLETED: LifecycleMode.COMPLETED_RECENTLY,
             AgentMode.WAITING_FOR_INPUT: LifecycleMode.WAITING}
    rows = tuple(ProjectedAgentRow(
        agent_id=s.agent_id, provider=s.provider, display_name=s.display_name,
        lifecycle_mode=modes[s.mode], actionable=s.mode is AgentMode.WAITING_FOR_INPUT,
        is_subagent=False, updated_at=NOW, source_status=s,
    ) for s in statuses)
    projection = AttentionProjection(
        lifecycle_mode=LifecycleMode.WAITING if any(r.actionable for r in rows) else LifecycleMode.ACTIVE,
        actionable_attention=tuple(r for r in rows if r.actionable), visible_rows=rows,
        transient_signals=(), dominant_provider="codex", click_target_agent_id=None,
    )
    return program_for_projection(projection, colors=settings, led_count=8,
                                  fleet_plan=plan_fleet_projection(projection, led_count=8) if renderer == "fleet" else None)


@pytest.mark.parametrize("renderer", ("snapshot", "projection", "fleet"))
@pytest.mark.parametrize("blend", ("round_robin", "color_blend", "spatial_split"))
def test_a_providers_chosen_working_shape_survives_more_sessions(renderer, blend):
    settings = ColorSettings.defaults().with_blend_mode(blend).with_agent_animation("codex", "kitt")
    solo = [status("codex", AgentMode.WORKING)]
    crowded = [status("codex", AgentMode.WORKING, i) for i in range(3)]
    crowded.append(status("devin", AgentMode.COMPLETED))

    assert render(crowded, settings, renderer) == render(solo, settings, renderer)


@pytest.mark.parametrize("renderer", ("snapshot", "projection", "fleet"))
def test_a_chosen_working_motion_never_hides_a_permission_request(renderer):
    statuses = [status("codex", AgentMode.WORKING), status("claude", AgentMode.WAITING_FOR_INPUT)]
    automatic = ColorSettings.defaults().with_blend_mode("round_robin")
    chosen = automatic.with_agent_animation("codex", "kitt")

    assert render(statuses, chosen, renderer)[0] == render(statuses, automatic, renderer)[0]
    assert render(statuses, chosen, renderer) != render([statuses[0]], chosen, renderer)
