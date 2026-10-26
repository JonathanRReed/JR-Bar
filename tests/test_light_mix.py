from dataclasses import replace
from datetime import datetime, timezone
from types import SimpleNamespace

import pytest

from jrbar.ambient_effect_consumer import _presentation, active_ambient_presentation
from jrbar.ambient_effect_dispatch import (
    AmbientEffectSurface,
    compile_ambient_effect_dispatch,
)
from jrbar.ambient_layers import compose_ambient_layer
from jrbar.animation import PaintStep, read_program, step_duration_ms
from jrbar.colors import (
    BLEND_MODE_CHOICES,
    ColorSettings,
    _active_agents,
    program_for_snapshot,
)
from jrbar.led_status import AgentLedController, LedDisplayState, _steady_state_variant
from jrbar.led_wasm import RawSdLedWasmController
from jrbar.light_mix import explain_what_plays, plan_agent_mix
from jrbar.models import AgentMode, AgentStatus
from jrbar.semantic_effect_router import SemanticEffectCandidate, SemanticEventKind, route_semantic_effects
from jrbar.turn_length_ember import plan_turn_length_ember

NOW = datetime(2026, 10, 25, tzinfo=timezone.utc)
PROVIDERS = ("codex", "claude", "devin", "cursor")
FAMILIES = ("breathe", "heartbeat", "kitt", "scanner", "gradient", "chase")
PARAMETERS = {
    "breathe": {"duration_seconds": 3.7, "inhale": 0.24},
    "heartbeat": {"duration_seconds": 3.7, "rest_ratio": 0.45},
    "kitt": {"duration_seconds": 3.7, "beam_width": 2, "overlap": 0.8},
    "scanner": {"duration_seconds": 3.7, "beam_width": 2, "trail": 0.6},
    "gradient": {"duration_seconds": 3.7, "hue_span_degrees": 92},
    "chase": {"duration_seconds": 3.7, "crests": 2},
}


def statuses(count, mode=AgentMode.WORKING):
    return tuple(AgentStatus(provider=provider, agent_id=f"{provider}:test",
        display_name=provider, mode=mode, updated_at=NOW, event_name="test")
        for provider in PROVIDERS[:count])


def settings_for(mode, family):
    settings = replace(ColorSettings.defaults().with_blend_mode(mode),
        mix_effect={"effect_id": "marquee", "parameters": {}})
    for provider in PROVIDERS:
        settings = settings.with_agent_animation(provider, family)
        settings = settings.with_agent_animation_parameters(provider, PARAMETERS.get(family, {}))
    return settings


def cue_for(cue, count):
    if cue == "none":
        return None
    if cue == "ember":
        dispatch = compile_ambient_effect_dispatch(turn_length_ember=plan_turn_length_ember(elapsed_seconds=300))
    else:
        dispatch = compile_ambient_effect_dispatch(semantic_selection=route_semantic_effects((
            SemanticEffectCandidate("synthetic:completion", SemanticEventKind.COMPLETION),
        )))
    surface = AmbientEffectSurface.SIDEPULSE_DOT if count == 2 else AmbientEffectSurface.SIDEPULSE_PRO
    output = dispatch.for_surface(surface)
    assert output is not None
    return _presentation(output, 10.0, reduce_motion=False, brightness=255)


@pytest.fixture(scope="module", params=(2, 8))
def firmware(request):
    return RawSdLedWasmController(request.param)


@pytest.mark.parametrize("mix", BLEND_MODE_CHOICES)
@pytest.mark.parametrize("family", FAMILIES)
@pytest.mark.parametrize("cue", ("none", "ember", "celebration"))
@pytest.mark.parametrize("providers", (1, 2, 3))
def test_mix_animation_cue_grid(firmware, mix, family, cue, providers):
    count = firmware.led_count
    settings = settings_for(mix, family)
    original = settings.to_dict()
    state = statuses(providers)
    plan = plan_agent_mix(_active_agents(state, settings), settings, led_count=count)
    explanation = explain_what_plays(state, settings, led_count=count, ambient=cue_for(cue, count))
    expected = family if providers == 1 else mix
    # Every mix retains the sole working provider's animation.
    if providers > 1:
        if (mix == "relay" and count == 2) or (mix in {"weave", "tide"} and providers > count):
            expected = "alternate"
        elif mix in {"round_robin", "spatial_split"} and count == 2 and (providers > 2 or family not in {"breathe", "heartbeat", "kitt"}):
            expected = "cycle"
        if mix in {"round_robin", "spatial_split"} and count == 8 and providers == 3 and family in {"kitt", "chase", "gradient", "scanner"}:
            expected = "alternate" if family == "scanner" else "cycle"
        if mix == "cycle" and count == 8 and family == "scanner":
            expected = "alternate"
    assert plan.played == expected, plan.warnings
    assert explanation["warnings"] == list(plan.warnings)
    assert all(row["parameters"] == PARAMETERS.get(family, {}) for row in explanation["providers"])
    assert settings.to_dict() == original
    program = explanation["program"]
    assert len(program.encode()) + 15 <= 512
    assert len(program.splitlines()) + 1 <= 20
    firmware.reset(0)
    parsed = firmware.parse(program, 0)
    assert parsed.ok, (parsed, program)
    frames = firmware.step_batch(0, 100, 90)
    assert any(any(sum(pixel) for pixel in frame) for frame in frames)
    if cue == "ember":
        assert explanation["cue"] is None
        assert "Ember is not shown" in explanation["cue_reason"]
    if cue == "celebration":
        assert explanation["cue"] is not None
        # Palette composition retains the complete underlying timeline.
        base, _ = read_program(plan.program, led_count=count)
        layered, _ = read_program(program, led_count=count)
        assert [step_duration_ms(step) for step in base.steps] == [step_duration_ms(step) for step in layered.steps]


@pytest.mark.parametrize("mix", ("spatial_split", "round_robin", "cycle"))
@pytest.mark.parametrize("family", ("breathe", "heartbeat", "kitt"))
def test_share_programs_keep_studio_values_in_the_played_bytes(mix, family):
    from jrbar.light_mix import _body, _share_steps

    settings = settings_for(mix, family)
    agents = _active_agents(statuses(2), settings)
    plan = plan_agent_mix(agents, settings)
    if plan.played != mix:
        assert plan.warnings
        return
    animation, _ = read_program(plan.program)
    paints = [step for step in animation.steps if isinstance(step, PaintStep)]
    assert paints
    for index, agent in enumerate(agents):
        slots = tuple(range(index * 4, (index + 1) * 4)) if mix == "spatial_split" or family == "kitt" else tuple(range(index, 8, 2))
        if mix == "cycle":
            slots = tuple(range(8))
        expected = _share_steps(_body(agent, settings, len(slots)), slots)
        durations = [step_duration_ms(step) for step in expected]
        if mix == "cycle":
            assert sum(step_duration_ms(step) for step in animation.steps) == pytest.approx(8000, abs=12)
        else:
            assert [step_duration_ms(step) for step in paints] == durations
    changed = settings.with_agent_animation_parameters("codex", {**PARAMETERS[family], "duration_seconds": 1.8})
    changed_plan = plan_agent_mix(_active_agents(statuses(2), changed), changed)
    assert mix == "cycle" or changed_plan.program != plan.program or changed_plan.warnings


def test_kitt_moves_inside_each_split_in_the_firmware():
    settings = settings_for("spatial_split", "kitt")
    plan = plan_agent_mix(_active_agents(statuses(2), settings), settings)
    assert plan.played == "spatial_split", plan.warnings
    firmware = RawSdLedWasmController(8)
    assert firmware.parse(plan.program, 0).ok
    visited = [set(), set()]
    for frame in firmware.step_batch(0, 40, 150):
        for group in range(2):
            levels = [sum(pixel) for pixel in frame[group * 4:group * 4 + 4]]
            if max(levels) > 0:
                visited[group].add(levels.index(max(levels)))
    assert visited == [set(range(4)), set(range(4))]


def test_heartbeat_keeps_both_beats_in_every_share():
    settings = settings_for("spatial_split", "heartbeat")
    plan = plan_agent_mix(_active_agents(statuses(2), settings), settings)
    assert plan.played == "spatial_split"
    firmware = RawSdLedWasmController(8)
    assert firmware.parse(plan.program, 0).ok
    levels = [sum(frame[0]) for frame in firmware.step_batch(0, 20, 185)]
    threshold = max(levels) * 0.3
    peaks = [index for index in range(1, len(levels))
             if levels[index] > threshold >= levels[index - 1]]
    assert len(peaks) == 2, peaks


def test_ember_renewal_and_reassert_do_not_freeze_the_firmware(tmp_path, monkeypatch):
    clock = [10.0]
    monkeypatch.setattr("jrbar.led_status.time.monotonic", lambda: clock[0])
    cue = cue_for("ember", 8)
    raw = RawSdLedWasmController(8)
    assert raw.parse(cue.nominal_program, 0).ok
    assert len({tuple(frame) for frame in raw.step_batch(49_000, 80, 40)}) > 1
    settings = ColorSettings.defaults().with_blend_mode("round_robin").with_agent_animation("codex", "breathe")
    _state, base = program_for_snapshot(statuses(1), colors=settings)
    controller = AgentLedController(device_path=tmp_path)
    firmware = RawSdLedWasmController(8)
    first = controller.sync_program(base, LedDisplayState.WORKING, ambient=cue)
    assert first.changed
    assert firmware.parse(first.program, 0).ok
    # The old finite ember held its last frame after ~48 seconds.
    frames = firmware.step_batch(49_000, 80, 40)
    assert len({tuple(frame) for frame in frames}) > 1
    clock[0] = 58.0
    renewed = replace(cue, started_at=58.0, next_visual_change_at=60.0,
        dedupe_token=("ambient", "turn_length_ember", 58.0))
    second = controller.sync_program(base, LedDisplayState.WORKING, ambient=renewed)
    assert not second.changed, "an identical ember renewal must not restart the animation"
    clock[0] = 299.0
    reassert = controller.sync_program(base, LedDisplayState.WORKING, ambient=renewed)
    assert reassert.changed
    assert reassert.nominal_program == _steady_state_variant(
        compose_ambient_layer(base, LedDisplayState.WORKING, renewed))
    assert firmware.parse(reassert.program, 100_000).ok
    frames = firmware.step_batch(100_000, 80, 40)
    assert len({tuple(frame) for frame in frames}) > 1
    restored = controller.sync_program(base, LedDisplayState.WORKING)
    assert restored.changed and restored.nominal_program == base


def test_ember_is_bounded_and_kitt_wins_for_one_codex_agent(monkeypatch):
    cue = cue_for("ember", 8)
    owner = SimpleNamespace(_ambient_effect_dispatch=compile_ambient_effect_dispatch(
        turn_length_ember=plan_turn_length_ember(elapsed_seconds=300)),
        _ambient_effect_dispatch_started_at=10.0)
    monkeypatch.setattr("jrbar.ambient_effect_consumer.time.monotonic", lambda: 12.1)
    assert active_ambient_presentation(owner, AmbientEffectSurface.SIDEPULSE_PRO,
        reduce_motion=False, brightness=255) is None
    settings = settings_for("relay", "kitt")
    explanation = explain_what_plays(statuses(1), settings, ambient=cue)
    assert explanation["played"] == "kitt"
    assert explanation["cue"] is None
    assert "Knight Rider" in explanation["cue_reason"]
    assert explanation["program"] == program_for_snapshot(statuses(1), colors=settings)[1]


def test_reassert_keeps_unmarked_breath_halves():
    program = "#050505 3s cosine\n#808080 3s cosine\nrepeat"
    assert _steady_state_variant(program) == program
    marked = "// approach\n#000000 100ms cosine\n" + program
    assert _steady_state_variant(marked) == program


def test_a_solo_provider_does_not_take_the_mix_tempo():
    settings = ColorSettings.defaults().with_agent_animation("codex", "kitt")
    settings = settings.with_speed_override("round_robin", 8.0)
    solo = statuses(1)
    programs = {program_for_snapshot(solo, colors=settings.with_blend_mode(mix))[1]
                for mix in BLEND_MODE_CHOICES}
    assert len(programs) == 1


def test_global_mix_migrates_and_device_overrides_still_win(tmp_path):
    from jrbar.core_runtime import settings_from_document

    migrated = ColorSettings.from_dict({"blend_mode": "spatial_split"})
    assert migrated.to_dict()["blend_mode"] == "spatial_split"
    assert "mix_mode" not in migrated.to_dict()
    restored = ColorSettings.from_dict({"mix_schema_version": 1, "mix_mode": "weave", "blend_mode": "relay"})
    assert restored.mix_mode == "relay"
    settings = settings_from_document({"colors": restored.to_dict(),
        "devices": [{"id": "test:dot", "blend_mode": "alternate"}]}, scratch_dir=tmp_path)
    assert settings.colors.mix_mode == "relay"
    assert settings.device_blend_mode("test:dot") == "alternate"


@pytest.mark.parametrize("mix", BLEND_MODE_CHOICES)
def test_asks_win_over_every_mix_and_cue(mix):
    settings = settings_for(mix, "kitt")
    state = (*statuses(1), replace(statuses(2)[1], mode=AgentMode.WAITING_FOR_INPUT))
    base = explain_what_plays(state, settings)
    for cue in ("ember", "celebration"):
        layered = explain_what_plays(state, settings, ambient=cue_for(cue, 8))
        assert layered["played"] == "ask"
        assert layered["program"] == base["program"]
        assert layered["cue"] is None


def test_explicit_session_colours_blend_and_keep_the_provider_animation():
    from jrbar.colors import _single_agent_program, weighted_blend

    rows = (statuses(1)[0], replace(statuses(1)[0], agent_id="codex:second"))
    for animation in ("auto", "kitt", "breathe"):
        settings = ColorSettings.defaults().with_blend_mode("round_robin").with_agent_animation("codex", animation)
        settings = settings.with_session_color(rows[0].agent_id, "#22CC88")
        agents = _active_agents(rows, settings)
        assert agents[0].color != agents[1].color
        blended = weighted_blend([(agent.color, float(agent.weight)) for agent in agents])
        expected = _single_agent_program(blended, LedDisplayState.WORKING, led_count=8,
            brightness=255, settings=settings, provider="codex")
        assert program_for_snapshot(rows, colors=settings)[1] == expected


def test_one_led_kitt_shares_name_the_compact_form():
    for mode in ("spatial_split", "round_robin"):
        settings = settings_for(mode, "kitt")
        explanation = explain_what_plays(statuses(2), settings, led_count=2)
        assert explanation["played"] == mode
        assert any("one-LED share" in warning for warning in explanation["warnings"])


@pytest.mark.parametrize("mix", ("classic", "color_blend"))
@pytest.mark.parametrize("providers", (0, 1, 3))
@pytest.mark.parametrize("mode", (AgentMode.IDLE_READY, AgentMode.WORKING, AgentMode.COMPLETED))
def test_calm_mixes_hold_still_except_for_a_solo_working_provider(firmware, mix, providers, mode):
    settings = settings_for(mix, "kitt")
    rows = statuses(providers, mode)
    state, program = program_for_snapshot(rows, colors=settings, led_count=firmware.led_count)
    explanation = explain_what_plays(rows, settings, led_count=firmware.led_count)
    assert explanation["program"] == program
    firmware.reset(0)
    assert firmware.parse(program, 0).ok
    frames = firmware.step_batch(0, 40, 250)
    assert any(sum(pixel) for pixel in frames[0])
    if providers == 1 and mode is AgentMode.WORKING:
        assert explanation["played"] == "kitt"
        assert any(frame != frames[0] for frame in frames[1:])
    else:
        assert all(frame == frames[0] for frame in frames)


@pytest.mark.parametrize("mix", ("classic", "color_blend"))
def test_calm_asks_still_blink_and_failures_stay_visible(firmware, mix):
    settings = settings_for(mix, "kitt")
    ask = replace(statuses(2)[1], mode=AgentMode.WAITING_FOR_INPUT, event_name="PermissionRequest")
    rows = (*statuses(1), ask)
    explanation = explain_what_plays(rows, settings, led_count=firmware.led_count, ambient=cue_for("celebration", firmware.led_count))
    assert explanation["played"] == "ask"
    assert explanation["cue"] is None
    firmware.reset(0)
    assert firmware.parse(explanation["program"], 0).ok
    frames = firmware.step_batch(0, 40, 250)
    assert any(frame != frames[0] for frame in frames[1:])
    failure = replace(ask, mode=AgentMode.BLOCKED_ERROR, event_name="failure")
    state, program = program_for_snapshot((failure,), colors=settings, led_count=firmware.led_count)
    assert state is LedDisplayState.FAILED
    if mix == "classic":
        assert program == settings.rendered_error_color()
    with_ask = explain_what_plays((*statuses(1), failure, ask), settings, led_count=firmware.led_count)
    assert with_ask["played"] == "ask"
    firmware.reset(0)
    assert firmware.parse(program, 0).ok
    frames = firmware.step_batch(0, 40, 250)
    assert all(any(sum(pixel) for pixel in frame) for frame in frames)
    assert all(frame == frames[0] for frame in frames)
