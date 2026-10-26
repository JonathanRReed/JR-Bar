"""Provider changes stay smooth in the firmware, including fallback turns."""

from dataclasses import replace

import pytest
from light_audit import Firmware, catalogue, frame_error, settings_for, statuses

from jrbar.colors import _active_agents
from jrbar.light_mix import plan_agent_mix


@pytest.fixture(scope="module")
def firmware():
    return Firmware()


@pytest.mark.parametrize("motion", [v for v in catalogue() if v.name.endswith(".default")],
                         ids=lambda variant: variant.motion)
@pytest.mark.parametrize("mix", ("cycle", "effect", "alternate", "relay", "round_robin"))
@pytest.mark.parametrize("leds", (2, 8))
@pytest.mark.parametrize("providers", (2, 3))
def test_every_provider_boundary_fades(firmware, motion, mix, leds, providers):
    settings = settings_for(motion, mix).with_fade_ceiling("working", 1)
    for provider, color in zip(("codex", "claude", "devin"), ("#FF0000", "#00FF00", "#0000FF")):
        settings = settings.with_agent_color(provider, color)
    if mix == "effect":
        settings = replace(settings, mix_effect={"effect_id": motion.motion, "parameters": {}})
    rows = statuses((1,) * providers, "working")
    plan = plan_agent_mix(_active_agents(rows, settings), settings, led_count=leds)
    if plan.played not in {"cycle", "effect", "alternate", "relay"}:
        return  # Simultaneous shares do not hand over the strip.
    trace = firmware.trace(plan.program, leds)
    # Include internal provider changes and the repeat into the first provider.
    for provider in range(providers + 1):
        index = round(trace.period * (1 + provider / providers) / trace.interval)
        error = frame_error(trace.frames[index - 1:index], trace.frames[index + 1:index + 2])
        assert error <= 41, (motion.name, mix, leds, plan.played, provider, error)


@pytest.mark.parametrize("motion", ("scanner", "kitt", "pendulum"))
@pytest.mark.parametrize("profile", ("default", "low", "high"))
@pytest.mark.parametrize("providers", (2, 3))
def test_seed_fade_is_inside_each_four_second_hold(firmware, motion, profile, providers):
    variant = next(v for v in catalogue() if v.name == f"{motion}.{profile}")
    settings = settings_for(variant, "cycle")
    rows = statuses((1,) * providers, "working")
    plan = plan_agent_mix(_active_agents(rows, settings), settings, led_count=2)
    assert plan.played == "cycle", plan.warnings
    trace = firmware.trace(plan.program, 2)
    assert trace.period == pytest.approx(4000 * providers, abs=6)
    # Both LEDs still reach each provider's peak during its own turn.
    for turn, provider in enumerate(("codex", "claude", "devin")[:providers]):
        color = settings.agent_color(provider)
        peak = tuple(round(int(color[i:i + 2], 16) * 0.5) for i in (1, 3, 5))
        start = round((trace.period + turn * 4000 + 400) / trace.interval)
        stop = round((trace.period + (turn + 1) * 4000) / trace.interval)
        for led in range(2):
            assert any(max(abs(a - b) for a, b in zip(frame[led], peak)) <= 2
                       for frame in trace.frames[start:stop]), (motion, profile, provider, led)


@pytest.mark.parametrize("first,second", (
    ("steady", "scanner"), ("scanner", "heartbeat"), ("blink", "pendulum"),
    ("frontier", "steady"), ("heartbeat", "blink"),
))
@pytest.mark.parametrize("leds", (2, 8))
def test_different_animations_hand_over_without_retaining_the_previous_colour(firmware, first, second, leds):
    variant = next(v for v in catalogue() if v.name == first + ".default")
    settings = settings_for(variant, "cycle").with_agent_animation("claude", second)
    settings = settings.with_fade_ceiling("working", 1)
    settings = settings.with_agent_color("codex", "#FF0000").with_agent_color("claude", "#00FF00")
    rows = statuses((1, 1), "working")
    plan = plan_agent_mix(_active_agents(rows, settings), settings, led_count=leds)
    trace = firmware.trace(plan.program, leds)
    for milliseconds in (trace.period, trace.period * 1.5):
        index = round(milliseconds / trace.interval)
        assert frame_error(trace.frames[index - 1:index], trace.frames[index + 1:index + 2]) <= 41
    if plan.played == "cycle":
        # After the entry has settled, a pulse must not return to red.
        # The safety compiler can lengthen these full-brightness programs.
        start = round(trace.period * 1.9 / trace.interval)
        stop = round(trace.period * 1.95 / trace.interval)
        assert max(pixel[0] for frame in trace.frames[start:stop] for pixel in frame) <= 1
