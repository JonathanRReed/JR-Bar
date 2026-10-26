"""Mixed sweeps visit the entire physical share on the firmware."""

from dataclasses import replace
from datetime import datetime, timezone

import pytest

from jrbar.animation import IndexedPaint, PaintStep, animation_duration_ms, read_program
from jrbar.colors import ColorSettings, _active_agents, program_for_snapshot
from jrbar.led_status import _steady_state_variant
from jrbar.led_wasm import RawSdLedWasmController
from jrbar.models import AgentMode, AgentStatus


def owner_setup(groups, mix, glow=0):
    settings = ColorSettings.from_dict({
        "blend_mode": mix, "mix_schema_version": 1, "cycle_speed_seconds": 1.5,
        "provider_animation": {"codex": "kitt"},
        "provider_animation_parameters": {"codex": {
            "beam_width": 3, "duration_seconds": 2.2, "overlap": 0.5,
            "background_glow": glow}},
        "fade_floor": {"working": 0.01}, "fade_ceiling": {"working": 0.5},
        "mode_animation": {"working": "roll"}, "tint_by_tool": True,
    })
    rows = tuple(AgentStatus(provider=provider, agent_id=f"synthetic:{index}",
        display_name=provider, mode=AgentMode.WORKING,
        updated_at=datetime(2026, 10, 1, tzinfo=timezone.utc), event_name="test")
        for index, provider in enumerate(("codex", "claude", "claude")[:groups]))
    return rows, settings


@pytest.mark.parametrize("groups", (2, 3))
@pytest.mark.parametrize("mix", ("round_robin", "spatial_split"))
@pytest.mark.parametrize("glow", (0, 20))
def test_owner_sweep_lights_every_position_to_its_peak_each_cycle(groups, mix, glow):
    rows, settings = owner_setup(groups, mix, glow)
    _state, program = program_for_snapshot(rows, colors=settings, led_count=8)
    from jrbar.light_mix import plan_agent_mix

    agents = _active_agents(rows, settings)
    plan = plan_agent_mix(agents, settings)
    assert plan.played == mix, plan.warnings
    animation, problems = read_program(program, led_count=8)
    assert not [problem for problem in problems if problem.severity == "error"]
    assert all(0 <= index < 8 for step in animation.steps if isinstance(step, PaintStep)
               for segment in step.segments if isinstance(segment, IndexedPaint)
               for index, _ in segment.assignments)
    period = animation_duration_ms(animation)
    # Reassert must keep the returning head and the whole geometry.
    assert _steady_state_variant(program) == program
    firmware = RawSdLedWasmController(8)
    firmware.reset(0)
    assert firmware.parse(program, 0).ok
    frames = firmware.step_batch(0, 10, period * 4 // 10 + 1)
    for cycle in range(3):
        current = frames[cycle * period // 10:(cycle + 1) * period // 10]
        for index, agent in enumerate(agents):
            if mix == "round_robin":
                share = tuple(range(index, 8, groups))
            else:
                sizes = [8 // groups + (i < 8 % groups) for i in range(groups)]
                start = sum(sizes[:index])
                share = tuple(range(start, start + sizes[index]))
            peak = max(int(agent.color[i:i + 2], 16) for i in (1, 3, 5)) * 0.5
            assert all(max(max(frame[led]) for frame in current) >= peak * 0.95
                       for led in share), (share, cycle)
            assert all(max(max(frame[led]) for led in share) > peak * 0.1
                       for frame in current), (share, cycle)


@pytest.mark.parametrize("motion", ("kitt", "scanner", "pendulum"))
@pytest.mark.parametrize("groups", (2, 3))
def test_automatic_sweep_path_uses_its_own_share_size(motion, groups):
    from jrbar.light_mix import _body, _share_steps, _shares

    rows, settings = owner_setup(groups, "round_robin")
    settings = settings.with_agent_animation("codex", motion).with_agent_animation_parameters("codex", {})
    agents = _active_agents(rows, settings)
    # Check the native local render before any physical share mapping.
    for count in (2, 3, 4):
        local = _share_steps(_body(agents[0], settings, count, compact=True), tuple(range(count)))
        addressed = {index for step in local for segment in step.segments
                     for index, _ in segment.assignments}
        assert addressed == set(range(count))
    program = _shares(agents, settings, 8, "round_robin")
    firmware = RawSdLedWasmController(8)
    assert firmware.parse(program, 0).ok
    animation, _ = read_program(program, led_count=8)
    period = animation_duration_ms(animation)
    frames = firmware.step_batch(0, 10, period * 4 // 10 + 1)
    for cycle in range(3):
        current = frames[cycle * period // 10:(cycle + 1) * period // 10]
        for index in range(groups):
            share = tuple(range(index, 8, groups))
            heads = {max(share, key=lambda led: max(frame[led])) for frame in current}
            assert heads == set(share), (motion, share, cycle, heads)
            assert all(any(max(frame[led]) > 0 for frame in current) for led in share)


def test_solo_knight_rider_matches_09172():
    from pathlib import Path

    rows, settings = owner_setup(1, "round_robin")
    # Rendered at 740c1b92 with the same settings and one synthetic Codex session.
    expected = Path(__file__).with_name("fixtures").joinpath("knight-rider-09172.led").read_text()
    assert program_for_snapshot(rows, colors=settings)[1] == expected
    assert program_for_snapshot(rows, colors=replace(settings, blend_mode="spatial_split"))[1] == expected
