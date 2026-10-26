from datetime import datetime, timezone

import pytest

from jrbar.attention import AttentionProjection, LifecycleMode, ProjectedAgentRow
from jrbar.colors import (
    ColorSettings,
    _active_agents,
    _single_agent_program,
    plan_fleet_projection,
    program_for_projection,
    program_for_snapshot,
    weighted_blend,
)
from jrbar.led_status import LedDisplayState
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
@pytest.mark.parametrize("blend", ("round_robin", "spatial_split"))
def test_a_providers_chosen_working_shape_survives_more_sessions(renderer, blend):
    settings = ColorSettings.defaults().with_blend_mode(blend).with_agent_animation("codex", "kitt")
    solo = [status("codex", AgentMode.WORKING)]
    crowded = [status("codex", AgentMode.WORKING, i) for i in range(3)]
    crowded.append(status("devin", AgentMode.COMPLETED))

    working = [agent for agent in _active_agents(tuple(crowded), settings)
               if agent.state is LedDisplayState.WORKING]
    assert len({agent.color for agent in working}) == 3
    blended = weighted_blend([(agent.color, float(agent.weight)) for agent in working])
    expected = _single_agent_program(blended, LedDisplayState.WORKING, led_count=8,
        brightness=255, settings=settings, provider="codex")
    assert render(crowded, settings, renderer) == (LedDisplayState.WORKING, expected)
    assert expected != render(solo, settings, renderer)[1]


@pytest.mark.parametrize("renderer", ("snapshot", "projection", "fleet"))
def test_a_chosen_working_motion_never_hides_a_permission_request(renderer):
    statuses = [status("codex", AgentMode.WORKING), status("claude", AgentMode.WAITING_FOR_INPUT)]
    automatic = ColorSettings.defaults().with_blend_mode("round_robin")
    chosen = automatic.with_agent_animation("codex", "kitt")

    assert render(statuses, chosen, renderer)[0] == render(statuses, automatic, renderer)[0]
    assert render(statuses, chosen, renderer) != render([statuses[0]], chosen, renderer)


@pytest.mark.parametrize("renderer", ("snapshot", "projection", "fleet"))
@pytest.mark.parametrize("mix", ("classic", "color_blend"))
def test_calm_overrides_solo_motion_in_every_light_renderer(renderer, mix):
    from jrbar.led_wasm import RawSdLedWasmController

    # Calm is the explicit exception to solo-provider animation equivalence.
    settings = ColorSettings.defaults().with_blend_mode(mix).with_agent_animation("codex", "kitt")
    rows = [status("codex", AgentMode.WORKING)]
    state, program = render(rows, settings, renderer)
    assert state is LedDisplayState.WORKING
    firmware = RawSdLedWasmController(8)
    assert firmware.parse(program, 0).ok
    frames = firmware.step_batch(0, 40, 250)
    assert all(frame == frames[0] for frame in frames)
    state, attention = render([*rows, status("claude", AgentMode.WAITING_FOR_INPUT)], settings, renderer)
    assert state is LedDisplayState.ASK
    assert attention != program
