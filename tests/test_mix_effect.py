"""A library Mix keeps provider turns, parameters and ask priority."""

from dataclasses import replace

import pytest

from jrbar.colors import (
    BLEND_MODE_CHOICES,
    PROVIDER_ANIMATION_CHOICES,
    ColorSettings,
    _active_agents,
    program_for_snapshot,
)
from jrbar.effect_registry import EFFECT_REGISTRY
from jrbar.led_wasm import RawSdLedWasmController
from jrbar.light_mix import explain_what_plays, plan_agent_mix, selected_agents
from jrbar.models import AgentMode
from tests.test_light_mix import statuses


@pytest.mark.parametrize("count", (2, 8))
@pytest.mark.parametrize("providers", (2, 3))
def test_marquee_uses_every_provider_colour_and_its_own_parameters(count, providers):
    settings = replace(ColorSettings.defaults().with_blend_mode("effect"),
        mix_effect={"effect_id": "marquee", "parameters": {"duration_seconds": 1.8, "crests": 2}})
    rows = statuses(providers)
    plan = plan_agent_mix(_active_agents(rows, settings), settings, led_count=count)
    assert plan.played == "effect", plan.warnings
    assert not plan.warnings
    assert "one cycle per provider" in plan.reason
    firmware = RawSdLedWasmController(count)
    assert firmware.parse(plan.program, 0).ok
    frames = firmware.step_batch(0, 20, 1000)
    for agent in selected_agents(_active_agents(rows, settings)):
        # Each turn reaches this provider's half-brightness crest.
        peak = tuple(round(int(agent.color[i:i + 2], 16) * 0.5) for i in (1, 3, 5))
        assert any(all(abs(pixel[i] - peak[i]) <= 2 for i in range(3))
                   for frame in frames for pixel in frame), (agent.provider, peak)
    slower = replace(settings, mix_effect={"effect_id": "marquee", "parameters": {"duration_seconds": 3.6, "crests": 2}})
    assert program_for_snapshot(rows, colors=slower, led_count=count)[1] != plan.program
    solo = statuses(1)
    assert program_for_snapshot(solo, colors=settings, led_count=count) == program_for_snapshot(
        solo, colors=settings.with_blend_mode("round_robin"), led_count=count)
    ask = replace(rows[-1], mode=AgentMode.WAITING_FOR_INPUT)
    assert explain_what_plays((*rows, ask), settings, led_count=count)["played"] == "ask"


def test_missing_and_over_budget_library_effects_name_the_fallback():
    for effect, parameters in (("missing:effect", {}), ("kitt", {"beam_width": 1})):
        settings = replace(ColorSettings.defaults().with_blend_mode("effect"),
            mix_effect={"effect_id": effect, "parameters": parameters})
        plan = plan_agent_mix(_active_agents(statuses(4), settings), settings)
        assert plan.requested_mix == "effect"
        assert plan.played == "alternate"
        assert plan.warnings
        assert "cannot play exactly" in plan.warnings[-1]
        assert settings.mix_effect["effect_id"] == effect


@pytest.mark.parametrize("sessions", (2, 3, 4, 5, 6))
def test_one_provider_keeps_its_animation_for_any_number_of_groups(sessions):
    settings = ColorSettings.defaults().with_blend_mode("round_robin").with_agent_animation("codex", "kitt")
    rows = tuple(replace(statuses(1)[0], agent_id=f"synthetic:{index}") for index in range(sessions))
    selected = selected_agents(_active_agents(rows, settings))
    assert len(selected) == 1
    plan = plan_agent_mix(_active_agents(rows, settings), settings)
    assert plan.played == "kitt"
    assert "only working provider" in plan.reason


def test_a_provider_uses_its_most_urgent_state_but_asks_stay_individual():
    from jrbar.led_status import LedDisplayState

    settings = ColorSettings.defaults()
    rows = (statuses(1)[0], replace(statuses(1)[0], agent_id="synthetic:idle", mode=AgentMode.IDLE_READY))
    selected = selected_agents(_active_agents(rows, settings))
    assert len(selected) == 1 and selected[0].state is LedDisplayState.WORKING
    asks = tuple(replace(row, mode=AgentMode.WAITING_FOR_INPUT) for row in rows)
    assert len(selected_agents(_active_agents(asks, settings))) == 2


@pytest.mark.parametrize("projection", (False, True))
def test_a_failed_session_wins_over_work_by_the_same_provider(projection):
    from jrbar.led_status import LedDisplayState

    settings = ColorSettings.defaults()
    rows = (*statuses(2), replace(statuses(1)[0], agent_id="synthetic:failed", mode=AgentMode.BLOCKED_ERROR))
    if projection:
        from jrbar.attention import project_attention
        from jrbar.colors import projection_mix_agents
        from jrbar.settings import AgentMonitorSettings
        from tests.test_agent_groups import snapshot, status

        projected = (status("codex:session:working"), status("claude:session:working"),
                     status("codex:session:failed", mode=AgentMode.BLOCKED_ERROR))
        agents = projection_mix_agents(project_attention(snapshot(projected), AgentMonitorSettings()), settings)
    else:
        agents = _active_agents(rows, settings)
    selected = selected_agents(agents, settings)
    assert len(selected) == 2
    assert {agent.provider: agent.state for agent in selected} == {
        "codex": LedDisplayState.FAILED, "claude": LedDisplayState.WORKING}


@pytest.mark.parametrize("animation", PROVIDER_ANIMATION_CHOICES)
@pytest.mark.parametrize("mix", BLEND_MODE_CHOICES)
@pytest.mark.parametrize("count", (2, 8))
@pytest.mark.parametrize("providers", (1, 2))
def test_session_count_does_not_change_any_mix_or_animation(animation, mix, count, providers):
    settings = replace(ColorSettings.defaults().with_blend_mode(mix),
        mix_effect={"effect_id": "marquee", "parameters": {}})
    for provider in ("codex", "claude"):
        settings = settings.with_agent_animation(provider, animation)
    rows = statuses(providers)
    expected = program_for_snapshot(rows, colors=settings, led_count=count)
    for sessions in range(2, 7):
        expanded = tuple(replace(rows[index % providers], agent_id=f"synthetic:{index}") for index in range(sessions))
        assert program_for_snapshot(expanded, colors=settings, led_count=count) == expected


@pytest.mark.parametrize("effect", EFFECT_REGISTRY.list(), ids=lambda effect: effect.identifier)
@pytest.mark.parametrize("count,providers", ((8, 2), (8, 3), (2, 2), (2, 3)))
def test_every_library_mix_plays_or_reports_its_budget_fallback(effect, count, providers):
    settings = replace(ColorSettings.defaults().with_blend_mode("effect"),
        mix_effect={"effect_id": effect.identifier, "parameters": {}})
    original = settings.to_dict()
    rows = statuses(providers)
    plan = plan_agent_mix(_active_agents(rows, settings), settings, led_count=count)
    over_budget = count == 8 and (effect.identifier in {
        "aurora", "converge", "drift", "flicker", "kitt", "pendulum", "scanner", "stack", "twinkle",
    } or (providers == 3 and effect.identifier in {"bloom", "ember", "ripple"}))
    assert plan.played == ("alternate" if over_budget else "effect"), plan.warnings
    if over_budget:
        assert any("512 bytes or 20 lines" in warning for warning in plan.warnings)
    assert len(plan.program.encode()) + 15 <= 512
    assert len(plan.program.splitlines()) + 1 <= 20
    firmware = RawSdLedWasmController(count)
    assert firmware.parse(plan.program, 0).ok
    frames = firmware.step_batch(0, 20, 2000)
    assert any(any(max(pixel) > 0 for pixel in frame) for frame in frames)
    asking = (*rows, replace(rows[-1], agent_id="synthetic:ask", mode=AgentMode.WAITING_FOR_INPUT))
    assert explain_what_plays(asking, settings, led_count=count)["played"] == "ask"
    assert settings.to_dict() == original


def test_installed_library_mix_uses_the_pack_motion(tmp_path, monkeypatch):
    from jrbar import effect_pack_store
    from jrbar.effect_pack_store import EffectPackStore
    from tests.test_core_effects import SAMPLE_PACK

    monkeypatch.setattr(effect_pack_store, "default_effect_pack_store_path", lambda home=None: tmp_path / "packs")
    pack = {**SAMPLE_PACK, "effects": [{**SAMPLE_PACK["effects"][0], "motion": "marquee"}, SAMPLE_PACK["effects"][1]]}
    assert EffectPackStore().install(pack).accepted
    settings = replace(ColorSettings.defaults().with_blend_mode("effect"),
        mix_effect={"effect_id": "pack:nightlab:ember", "parameters": {"duration_seconds": 1.8}})
    plan = plan_agent_mix(_active_agents(statuses(2), settings), settings)
    assert plan.played == "effect", plan.warnings
    assert "roll-right 1800ms" in plan.program
    firmware = RawSdLedWasmController(8)
    assert firmware.parse(plan.program, 0).ok
    assert len({tuple(frame) for frame in firmware.step_batch(0, 40, 200)}) > 10
