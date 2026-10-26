"""Sweeps own their background, including when another effect was lit first."""

import pytest

from jrbar.core_effects import normalize_parameters, render_effect
from jrbar.effect_registry import get_effect
from jrbar.led_wasm import RawSdLedWasmController


def frames(effect_id, led_count, background=None):
    effect = get_effect(effect_id)
    values = {} if background is None else {"background_glow": background}
    program = render_effect(effect, normalize_parameters(effect, values), led_count=led_count, color="#0088FF")
    engine = RawSdLedWasmController(led_count)
    engine.reset(0)
    assert engine.parse("#CC0000", 0).ok
    engine.step(0)
    assert engine.parse(program, 1).ok
    return engine.step_batch(17, 16, 350)


@pytest.mark.parametrize("effect_id", ["kitt", "scanner", "pendulum"])
@pytest.mark.parametrize("led_count", [2, 8])
def test_a_sweep_replaces_the_previous_effects_glowing_background(effect_id, led_count):
    samples = frames(effect_id, led_count)
    assert all(pixel[0] == 0 for frame in samples for pixel in frame), "The previous red light leaked into the blue sweep"
    assert all(any(max(pixel) > 0 for pixel in frame) for frame in samples), "The moving head blinked off"
    if led_count == 8:
        assert all(any(max(pixel) == 0 for pixel in frame) for frame in samples), "The whole strip stayed lit"


@pytest.mark.parametrize("effect_id", ["kitt", "scanner", "pendulum"])
def test_background_glow_changes_the_unlit_leds(effect_id):
    dark = frames(effect_id, 8, 0)
    glow = frames(effect_id, 8, 20)
    assert any(pixel == (0, 0, 0) for frame in dark for pixel in frame)
    assert all(pixel[0] == 0 and pixel[2] > 0 for frame in glow for pixel in frame)
    assert dark != glow


@pytest.mark.parametrize("effect_id", ["kitt", "scanner", "pendulum"])
def test_provider_glow_overrides_the_global_working_floor(effect_id):
    from datetime import datetime, timezone

    from jrbar.colors import ColorSettings, program_for_snapshot
    from jrbar.models import AgentMode, AgentStatus

    status = AgentStatus(provider="codex", agent_id="synthetic", display_name="Codex",
                         mode=AgentMode.WORKING, updated_at=datetime(2026, 10, 1, tzinfo=timezone.utc), event_name="test")
    settings = (ColorSettings.defaults().with_blend_mode("round_robin").with_agent_animation("codex", effect_id)
                .with_agent_color("codex", "#0088FF").with_fade_floor("working", 0.4))
    programs = [program_for_snapshot((status,), colors=settings.with_agent_animation_parameters(
        "codex", {"background_glow": level}), led_count=8)[1] for level in (0, 20)]
    results = []
    for text in programs:
        engine = RawSdLedWasmController(8)
        engine.reset(0)
        assert engine.parse("#CC0000", 0).ok
        engine.step(0)
        assert engine.parse(text, 1).ok
        results.append(engine.step_batch(17, 16, 200))
    assert min(pixel[2] for frame in results[0] for pixel in frame) == 0
    assert min(pixel[2] for frame in results[1] for pixel in frame) > 0
    assert all(pixel[0] == 0 for frames in results for frame in frames for pixel in frame)
