"""Every shipped animation and mix, with explicit fallback expectations."""
import itertools
from dataclasses import replace

import pytest

from jrbar.colors import (
    BLEND_MODE_CHOICES,
    PROVIDER_ANIMATION_CHOICES,
    ColorSettings,
    _active_agents,
    program_for_snapshot,
)
from jrbar.effect_registry import _PROVIDER_PARAMETER_METADATA
from jrbar.led_status import LedDisplayState
from jrbar.led_wasm import RawSdLedWasmController
from jrbar.light_mix import explain_what_plays, plan_agent_mix
from jrbar.models import AgentMode
from tests.test_light_mix import PROVIDERS, cue_for, statuses

CASES = tuple((mix, animation, variant, providers, count)
    for mix, animation, variant, providers, count in itertools.product(
        BLEND_MODE_CHOICES, PROVIDER_ANIMATION_CHOICES, ("default", "low", "high"),
        (1, 2, 3, 4), (2, 8)) if animation != "auto" or variant == "default")


def settings_for_case(mix, animation, variant):
    settings = ColorSettings.defaults().with_blend_mode(mix)
    values = {}
    if variant != "default":
        for spec in _PROVIDER_PARAMETER_METADATA.get(animation, ()):
            value = spec.minimum if variant == "low" else spec.maximum
            if spec.value_type in ("number", "integer") and value is not None:
                values[spec.name] = value
    for provider in PROVIDERS:
        settings = settings.with_agent_animation(provider, animation)
        if values:
            settings = settings.with_agent_animation_parameters(provider, values)
    return settings


def case_key(case):
    return "/".join(map(str, case))


# These expectations describe geometry and reviewed device limits. The
# reporting inventory in fixtures is deliberately not an acceptance oracle.
ONE_LED = {"auto", "breathe", "heartbeat", "steady", "blink", "kitt"}
CYCLE_TOO_LARGE = {"scanner", "pendulum", "flicker", "stack", "twinkle", "drift", "converge", "aurora"}


def expected_played(mix, animation, variant, providers, count):
    if mix == "classic":
        return mix
    # The low Gradient preset requests 300 ms, below the standing speed
    # safety gate. A solo uses Chase; a share/cycle explicitly falls back.
    unsafe_gradient = animation == "gradient" and variant == "low"
    if providers == 1:
        return "chase" if unsafe_gradient else animation
    if mix == "relay" and count < 4:
        return "alternate"
    if mix in {"weave", "tide"} and providers > count:
        return "alternate"
    if mix in {"round_robin", "spatial_split"}:
        if providers > count or (count // providers == 1 and animation not in ONE_LED):
            return expected_played("cycle", animation, variant, providers, count)
        if unsafe_gradient:
            return "alternate"
    if mix == "cycle":
        over_budget = count == 8 and (
            animation in CYCLE_TOO_LARGE
            or (animation in {"ember", "ripple"} and providers >= 3)
            or (animation == "kitt" and variant != "high" and providers == 4)
            or (animation == "bloom" and (providers == 4 or (variant == "high" and providers == 3))))
        if unsafe_gradient or over_budget:
            return "alternate"
    return mix


@pytest.fixture(scope="module", params=(2, 8))
def raw_firmware(request):
    return RawSdLedWasmController(request.param)


@pytest.mark.parametrize("mix,animation,variant,providers", sorted({case[:4] for case in CASES}))
def test_all_mix_animation_parameter_provider_combinations(raw_firmware, mix, animation, variant, providers):
    count = raw_firmware.led_count
    settings = settings_for_case(mix, animation, variant)
    rows = statuses(providers)
    plan = plan_agent_mix(_active_agents(rows, settings), settings, led_count=count)
    expected = expected_played(mix, animation, variant, providers, count)
    assert plan.played == expected, (plan.played, plan.warnings)
    if expected != (animation if providers == 1 and mix != "classic" else mix):
        assert any("cannot play exactly" in warning for warning in plan.warnings)
    if providers > 1 and plan.played == "cycle":
        from jrbar.animation import animation_duration_ms, read_program

        timeline, _ = read_program(plan.program)
        assert animation_duration_ms(timeline) == pytest.approx(providers * 4000, abs=100)
    for asking in (False, True):
        current = (*rows[:-1], replace(rows[-1], mode=AgentMode.WAITING_FOR_INPUT)) if asking else rows
        state, live = program_for_snapshot(current, colors=settings, led_count=count)
        if asking:
            assert state is LedDisplayState.ASK
            ordinary = settings_for_case(mix, "auto", "default")
            assert live == program_for_snapshot(current, colors=ordinary, led_count=count)[1]
        for cue in ("none", "ember", "celebration"):
            explanation = explain_what_plays(current, settings, led_count=count, ambient=cue_for(cue, count))
            program = explanation["program"]
            assert len(program.encode()) + 15 <= 512
            assert len(program.splitlines()) + 1 <= 20
            assert explanation["warnings"] == ([] if asking else list(plan.warnings))
            if asking:
                assert explanation["cue"] is None
                assert explanation["played"] == "ask"
            if explanation["cue"] is None:
                assert program == live
            raw_firmware.reset(0)
            assert raw_firmware.parse(program, 0).ok, program


@pytest.mark.parametrize("mix", ("alternate", "relay", "weave", "tide"))
@pytest.mark.parametrize("value", (-1000, 1000, 10 ** 1000, True, "bad", float("nan")))
def test_rejected_and_clamped_mix_parameters_are_named(mix, value):
    settings = replace(ColorSettings.defaults().with_blend_mode(mix),
        mix_parameters={mix: {"duration_seconds": value, "width": value, "softness": value, "unknown": 1}})
    plan = plan_agent_mix(_active_agents(statuses(2), settings), settings)
    for key in ("duration_seconds", "width", "softness", "unknown"):
        assert any(key in warning for warning in plan.warnings), (key, plan.warnings)


def test_targeted_default_combinations_do_not_fall_back():
    for mix, animation, providers, count in (
        ("round_robin", "auto", 3, 8), ("spatial_split", "auto", 3, 8),
        ("cycle", "kitt", 2, 8), ("spatial_split", "kitt", 2, 2),
        ("round_robin", "kitt", 2, 2),
        *(("tide", "auto", n, 8) for n in (2, 3, 4)),
    ):
        settings = settings_for_case(mix, animation, "default")
        plan = plan_agent_mix(_active_agents(statuses(providers), settings), settings, led_count=count)
        assert plan.played == mix, plan.warnings




@pytest.mark.parametrize("mix", ("alternate", "relay", "weave", "tide"))
@pytest.mark.parametrize("duration,width,softness", ((0.3, 1, 0), (10, 8, 1)))
@pytest.mark.parametrize("providers", (2, 3, 4))
def test_mix_parameter_extremes_have_only_named_geometry_fallbacks(raw_firmware, mix, duration, width, softness, providers):
    count = raw_firmware.led_count
    settings = replace(ColorSettings.defaults().with_blend_mode(mix),
        mix_parameters={mix: {"duration_seconds": duration, "width": width, "softness": softness}})
    plan = plan_agent_mix(_active_agents(statuses(providers), settings), settings, led_count=count)
    fallback = ((mix == "relay" and count == 2)
        or (mix == "weave" and (width == 8 or providers > count))
        or (mix == "tide" and count == 2 and providers > 2))
    assert plan.played == ("alternate" if fallback else mix), plan.warnings
    assert len(plan.program.encode()) + 15 <= 512
    assert len(plan.program.splitlines()) + 1 <= 20
    raw_firmware.reset(0)
    assert raw_firmware.parse(plan.program, 0).ok


def test_split_extra_leds_follow_need_then_start():
    from jrbar.animation import ColorList, IndexedPaint, PaintStep, WholeBar, read_program
    from jrbar.light_mix import _shares

    settings = settings_for_case("spatial_split", "steady", "default")
    agents = _active_agents(statuses(3), settings)
    agents = [replace(agent, started_at=start) for agent, start in zip(agents, (100, 200, 50))]
    def shares(agents):
        program = _shares(agents, settings, 8, "spatial_split")
        animation, _ = read_program(program)
        frame = {}
        for step in animation.steps:
            if isinstance(step, PaintStep):
                for segment in step.segments:
                    if isinstance(segment, ColorList):
                        frame.update(enumerate(segment.colors))
                    elif isinstance(segment, IndexedPaint):
                        frame.update(segment.assignments)
                    elif isinstance(segment, WholeBar):
                        frame.update(enumerate([segment.color] * 8))
                break
        return frame
    first = shares(agents)
    from jrbar.colors import _peak_for_state

    peaks = [_peak_for_state(agent.color, agent.state, settings) for agent in agents]
    assert [list(first.values()).count(color) for color in peaks] == [3, 2, 3]
    # Working tool activity is not a request for the person.
    agents[1] = replace(agents[1], weight=20)
    second = shares(agents)
    assert [list(second.values()).count(color) for color in peaks] == [3, 2, 3]
    agents[1] = replace(agents[1], state=LedDisplayState.FAILED)
    urgent_peaks = [_peak_for_state(agent.color, agent.state, settings) for agent in agents]
    urgent = shares(agents)
    assert [list(urgent.values()).count(color) for color in urgent_peaks] == [2, 3, 3]


def test_split_start_order_uses_observed_turn_starts_and_keeps_unknowns_unknown():
    from jrbar.capacity_types import SourceKey
    from jrbar.provider_facts import WorkIdentifier, WorkKey

    rows = tuple(replace(row, work_key=WorkKey(SourceKey(row.provider, "synthetic", "local", "work"),
        WorkIdentifier("synthetic-turn"))) for row in statuses(3))
    starts = {rows[0].work_key: 200.0, rows[1].work_key: 100.0}
    settings = replace(ColorSettings.defaults(), render_turn_starts=starts)
    agents = _active_agents(rows, settings)
    assert [(agent.identity, agent.started_at) for agent in agents] == [
        (rows[0].agent_id, 200.0), (rows[1].agent_id, 100.0), (rows[2].agent_id, None)]


@pytest.mark.parametrize("mix", ("round_robin", "spatial_split"))
@pytest.mark.parametrize("other", ("auto", "breathe", "chase"))
@pytest.mark.parametrize("providers", (2, 3, 4))
def test_chosen_knight_rider_and_other_provider_animations_play_together(mix, other, providers):
    settings = ColorSettings.defaults().with_blend_mode(mix).with_agent_animation("codex", "kitt")
    for provider in PROVIDERS[1:]:
        settings = settings.with_agent_animation(provider, other)
    plan = plan_agent_mix(_active_agents(statuses(providers), settings), settings, led_count=8)
    assert plan.played == mix, plan.warnings
    raw = RawSdLedWasmController(8)
    assert raw.parse(plan.program, 0).ok
    frames = raw.step_batch(0, 40, 150)
    assert len({tuple(frame) for frame in frames}) > 4
    # Both provider colours are present together, rather than taking turns.
    assert any(any(b > r * 2 for r, g, b in frame)
               and any(r > b * 2 for r, g, b in frame) for frame in frames)


def test_owner_codex_knight_rider_everyone_on_eight_led_sidepulse():
    settings = ColorSettings.defaults().with_blend_mode("round_robin").with_agent_animation("codex", "kitt")
    explanation = explain_what_plays(statuses(2), settings, led_count=8)
    assert explanation["played"] == "round_robin", explanation["warnings"]
    assert explanation["program"] == program_for_snapshot(statuses(2), colors=settings, led_count=8)[1]


@pytest.mark.parametrize("mix", ("round_robin", "spatial_split"))
@pytest.mark.parametrize("animation", ("kitt", "chase", "comet", "gradient", "bloom", "marquee"))
def test_three_providers_share_eight_leds_on_a_common_period(mix, animation):
    settings = settings_for_case(mix, animation, "default")
    plan = plan_agent_mix(_active_agents(statuses(3), settings), settings, led_count=8)
    assert plan.played == mix, plan.warnings


def test_automatic_follows_a_chosen_cycle_without_stretching_it():
    from jrbar.animation import animation_duration_ms, read_program

    settings = ColorSettings.defaults().with_blend_mode("round_robin").with_agent_animation("codex", "kitt")
    settings = settings.with_agent_animation_parameters("codex", {"duration_seconds": 3.7})
    plan = plan_agent_mix(_active_agents(statuses(3), settings), settings)
    assert plan.played == "round_robin", plan.warnings
    animation, _ = read_program(plan.program)
    assert animation_duration_ms(animation) == 3700


@pytest.mark.parametrize("providers", (2, 3))
def test_owner_automatic_follows_the_chosen_knight_rider_curve_exactly(providers):
    from jrbar.light_mix import _body

    settings = ColorSettings.defaults().with_blend_mode("round_robin").with_agent_animation("codex", "kitt")
    agents = _active_agents(statuses(providers), settings)
    share = tuple(range(0, 8, providers))
    plan = plan_agent_mix(agents, settings, led_count=8)
    reference = RawSdLedWasmController(8)
    actual = RawSdLedWasmController(8)
    assert reference.parse("\n".join([*_body(agents[0], settings, len(share), compact=True), "repeat"]), 0).ok
    assert actual.parse(plan.program, 0).ok
    expected = reference.step_batch(0, 20, 330)
    frames = actual.step_batch(0, 20, 330)
    assert [[frame[index] for index in share] for frame in frames] == [frame[:len(share)] for frame in expected]
