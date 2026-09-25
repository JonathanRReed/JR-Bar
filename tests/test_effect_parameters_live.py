"""Every Effect Studio knob does something, and nothing it can do is unsafe.

The 2026-09-24 audit found 47 of 69 declared parameters left the rendered
program byte-identical -- all four of Comet's among them -- and a provider
assignment dropped even the tempo on its way to the strip. These tests are
that audit, kept: each knob at its two ends must change the program, every
value must pass the safety compiler untouched, and a provider's values must
reach the live light.
"""

from __future__ import annotations

from types import SimpleNamespace

import pytest

from jrbar import colors as colors_module
from jrbar import core_effects
from jrbar import motion_shapes as shapes
from jrbar.accessibility_display import AccessibilityDisplayPreferences
from jrbar.animation import parse_animation
from jrbar.effect_packs import validate_pack
from jrbar.effect_registry import PROVIDER_ANIMATION_EFFECTS, get_effect
from jrbar.flash_analysis import analyse
from jrbar.presentation_compiler import compile_presentation_program
from jrbar.presentation_policy import (
    GlanceInputs,
    compose_presentation_program,
    resolve_glance,
)

#: Parameters that choose a policy rather than draw anything: which state
#: map Automatic follows, and which geometry a hand-off Moment uses. They
#: are allowed to leave a working loop's bytes alone.
POLICY_PARAMETERS = frozenset(
    {
        ("auto", "mapping_source"),
        ("converge", "variant"),
    }
)
PALETTE = ("#FF2D55", "#5AC8FA", "#FFCC00", "#34C759")


def _extremes(parameter) -> list[object]:
    if parameter.value_type in ("number", "integer"):
        return [parameter.minimum, parameter.maximum]
    if parameter.value_type == "choice":
        return list(parameter.choices)
    if parameter.value_type == "boolean":
        return [True, False]
    if parameter.value_type == "palette":
        return [(), PALETTE[: parameter.maximum_items]]
    raise AssertionError(f"no extremes for {parameter.value_type}")


def _cases():
    for effect in PROVIDER_ANIMATION_EFFECTS:
        for parameter in effect.parameter_metadata:
            yield effect, parameter


def test_every_render_parameter_changes_the_program() -> None:
    """Every value a knob can take that is not its default draws something
    other than the defaults. Counting distinct programs across a knob's
    values was not enough: Stack's ``decay`` release overflowed, fell back
    to the default look, and two different programs among three choices
    still passed."""
    inert = []
    for effect, parameter in _cases():
        if (effect.identifier, parameter.name) in POLICY_PARAMETERS:
            continue
        plain = core_effects.render_effect(
            effect, core_effects.normalize_parameters(effect, {}), led_count=8
        )
        for value in _extremes(parameter):
            parameters = core_effects.normalize_parameters(effect, {parameter.name: value})
            if parameters[parameter.name] == core_effects.normalize_parameters(effect, {})[parameter.name]:
                continue
            if core_effects.render_effect(effect, parameters, led_count=8) == plain:
                inert.append(f"{effect.identifier}.{parameter.name}={value!r}")
    assert inert == []


@pytest.mark.parametrize("knob", ("fill_direction", "release_behavior"))
def test_one_long_knob_does_not_undo_the_others(knob: str) -> None:
    """Stack's ``decay`` release is its longest program. Choosing it keeps
    a reversed fill, and choosing a reversed fill keeps the decay: a value
    that fits is never thrown back to its default because another one was
    chosen alongside it."""
    stack = get_effect("stack")
    both = core_effects.normalize_parameters(
        stack, {"fill_direction": "reverse", "release_behavior": "decay"}
    )
    alone = {name: value for name, value in both.items() if name != knob}
    for cycle in (0.5, 2.2, 10.0):
        both["duration_seconds"] = alone["duration_seconds"] = cycle
        together = core_effects.render_effect(stack, both, led_count=8)
        without = core_effects.render_effect(
            stack, core_effects.normalize_parameters(stack, alone), led_count=8
        )
        assert together != without, (knob, cycle)


def _assert_safe(effect, values: dict, *, label: str) -> None:
    parameters = core_effects.normalize_parameters(effect, values)
    for led_count in (8, 2):
        source = core_effects.render_effect_source(effect, parameters, led_count=led_count)
        assert len(source.encode("utf-8")) <= shapes.MAX_PROGRAM_BYTES, label
        compiled = compile_presentation_program(source, led_count=led_count)
        assert compiled.accepted and not compiled.transformed, (label, led_count, compiled.reasons)
        hertz = analyse(parse_animation(source, led_count=led_count), led_count=led_count).hertz
        assert hertz <= 2.0, (label, led_count, hertz)


def test_every_parameter_value_passes_the_safety_compiler_untouched() -> None:
    """At either end of every knob, and with every knob at its low or its
    high end together, each program fits the firmware and is at or under
    2 Hz by the compiler's own measure -- so the compiler never has to slow
    what the slider promised."""
    for effect, parameter in _cases():
        for value in _extremes(parameter):
            _assert_safe(effect, {parameter.name: value}, label=f"{effect.identifier}.{parameter.name}={value!r}")
    for effect in PROVIDER_ANIMATION_EFFECTS:
        lows = {p.name: _extremes(p)[0] for p in effect.parameter_metadata}
        highs = {p.name: _extremes(p)[-1] for p in effect.parameter_metadata}
        _assert_safe(effect, lows, label=f"{effect.identifier} all low")
        _assert_safe(effect, highs, label=f"{effect.identifier} all high")


def test_the_slowest_motion_still_fits_under_a_brightness_line() -> None:
    """Play on strip (``preview_program``) and a semantic cue put the
    strip's brightness line in front of what Effect Studio rendered. At the
    longest cycle, with every knob at either end, that still fits the
    firmware: a slow Pendulum came to 520 bytes and the strip refused it."""
    from jrbar._led_status_legacy import apply_brightness

    longest = colors_module.MAX_CYCLE_SPEED_SECONDS
    for effect in PROVIDER_ANIMATION_EFFECTS:
        names = {p.name for p in effect.parameter_metadata}
        choices = [{}]
        choices += [{p.name: v} for p in effect.parameter_metadata for v in _extremes(p)]
        choices.append({p.name: _extremes(p)[-1] for p in effect.parameter_metadata})
        for values in choices:
            if "duration_seconds" in names:
                values = {**values, "duration_seconds": longest}
            parameters = core_effects.normalize_parameters(effect, values)
            for led_count in (8, 2):
                program = apply_brightness(
                    core_effects.render_effect(effect, parameters, led_count=led_count), 128
                )
                assert len(program.encode("utf-8")) <= shapes.MAX_PROGRAM_BYTES, (
                    effect.identifier, values, led_count, len(program.encode("utf-8"))
                )
                assert program.count("\n") + 1 <= shapes.MAX_PROGRAM_LINES


def test_saturated_red_never_passes_one_hertz() -> None:
    """Saturated red is held to 1 Hz. Whatever a knob does in red, the
    program that reaches the strip measures at or under the limit the
    compiler holds it to: 1 Hz wherever saturated red is on screen, 2 Hz
    for the dimmer reds a gentle ceiling makes of it."""
    import re

    from jrbar.presentation_compiler import _is_saturated_red

    for effect, parameter in _cases():
        for value in _extremes(parameter):
            parameters = core_effects.normalize_parameters(effect, {parameter.name: value})
            source = core_effects.render_effect_source(effect, parameters, led_count=8, color="#FF0000")
            compiled = compile_presentation_program(source, led_count=8)
            assert compiled.accepted
            red = any(_is_saturated_red(hex_) for hex_ in re.findall(r"#[0-9A-Fa-f]{6}", compiled.program))
            hertz = analyse(parse_animation(compiled.program, led_count=8), led_count=8).hertz
            assert hertz <= (1.0 if red else 2.0) + 1e-9, (effect.identifier, parameter.name, value, hertz)


def test_retired_parameters_are_ignored_not_rejected() -> None:
    gradient = get_effect("gradient")
    assert gradient is not None
    normalized = core_effects.normalize_parameters(
        gradient, {"smooth_morph": False, "hue_span_degrees": 90.0}
    )
    assert "smooth_morph" not in normalized
    assert normalized["hue_span_degrees"] == 90.0
    for retired in core_effects.RETIRED_PARAMETERS:
        for effect in PROVIDER_ANIMATION_EFFECTS:
            assert retired not in effect.parameters
    # A pack written before the retirement still loads and still renders.
    pack = validate_pack(
        {
            "id": "old-pack",
            "name": "Old pack",
            "version": 2,
            "safety": {"data_only": True, "network": False},
            "accessibility": {"reduced_motion": True, "high_contrast": True},
            "effects": [
                {
                    "id": "soft-gradient",
                    "label": "Soft gradient",
                    "meaning": "working",
                    "surfaces": ["screen_bar"],
                    "motion": "gradient",
                    "smooth_morph": True,
                    "max_cluster": 2,
                }
            ],
        }
    )
    registry = core_effects.registry_with_packs((pack,))
    effect = registry.get("pack:old-pack:soft-gradient")
    assert effect is not None
    pack_effect = core_effects.pack_effect_for((pack,), effect.identifier)
    parameters = core_effects.normalize_parameters(effect, {}, pack_effect=pack_effect)
    assert "roll-right" in core_effects.render_effect(effect, parameters, led_count=8)


def test_spacing_becomes_crests() -> None:
    chase = get_effect("chase")
    marquee = get_effect("marquee")
    assert core_effects.normalize_parameters(chase, {"spacing": 1})["crests"] == 1
    assert core_effects.normalize_parameters(chase, {"spacing": 5})["crests"] == 3
    assert core_effects.normalize_parameters(marquee, {"spacing": 1})["crests"] == 2
    assert core_effects.normalize_parameters(marquee, {"spacing": 6})["crests"] == 1
    # An explicit crests wins over an old spacing.
    assert core_effects.normalize_parameters(chase, {"spacing": 5, "crests": 1})["crests"] == 1


def test_values_that_would_not_fit_fall_back_to_the_defaults() -> None:
    peak, floor = "#00E5FF", "#000B0D"
    default = shapes.render_motion("aurora", peak, floor, led_count=8, cycle_ms=2200)
    painted = shapes.render_motion(
        "aurora", peak, floor, led_count=8, cycle_ms=2200, params={"palette": list(PALETTE)}
    )
    assert painted != default
    room = shapes.MAX_PROGRAM_BYTES - shapes.program_bytes(default) - 1
    squeezed = shapes.render_motion(
        "aurora",
        peak,
        floor,
        led_count=8,
        cycle_ms=2200,
        params={"palette": list(PALETTE)},
        reserve_bytes=room,
    )
    assert shapes.program_bytes(painted) + room > shapes.MAX_PROGRAM_BYTES
    assert squeezed == default
    # Only the value that does not fit goes back: a wave count chosen
    # alongside the palette stays.
    waves = shapes.render_motion(
        "aurora", peak, floor, led_count=8, cycle_ms=2200, params={"wave_count": 4}
    )
    assert waves != default
    kept = shapes.render_motion(
        "aurora",
        peak,
        floor,
        led_count=8,
        cycle_ms=2200,
        params={"palette": list(PALETTE), "wave_count": 4},
        reserve_bytes=shapes.MAX_PROGRAM_BYTES - shapes.program_bytes(waves),
    )
    assert kept == waves


def _solo_dsl(settings) -> str:
    preferences = AccessibilityDisplayPreferences()
    resolved = resolve_glance(
        GlanceInputs(
            actionable_episode_key=None,
            fresh_failure=None,
            fresh_completion=None,
            active=True,
            unresolved_failure=False,
            capacity=None,
        ),
        presentation_time=100.0,
        relay_epoch=100.0,
        preferences=preferences,
    )
    return compose_presentation_program(
        resolved,
        presentation_time=100.0,
        led_count=8,
        color="#D97757",
        preferences=preferences,
        provider="claude",
        color_settings=settings,
    ).dsl


def test_a_provider_assignment_with_parameters_reaches_the_live_light() -> None:
    """``set_assignment`` for a provider stores the Effect Studio values in
    settings, and the solo light the Pro plays changes with them."""
    from jrbar import core_runtime
    from jrbar._settings_legacy import AgentMonitorSettings
    from jrbar.effect_studio import AssignmentScope

    saved = []
    host = SimpleNamespace(
        settings=AgentMonitorSettings(),
        _core_legacy=lambda: SimpleNamespace(save_settings=saved.append),
        _core_publish_settings=lambda: None,
    )
    comet = get_effect("comet")
    plain = core_effects.normalize_parameters(comet, {})
    tuned = core_effects.normalize_parameters(
        comet, {"head_width": 3, "duration_seconds": 4.0, "pass_mode": "once"}
    )

    assert core_runtime._apply_provider_motion_assignment(
        host, comet, AssignmentScope.PROVIDER, "claude", plain
    ) is None
    before = _solo_dsl(host.settings.colors)
    assert core_runtime._apply_provider_motion_assignment(
        host, comet, AssignmentScope.PROVIDER, "claude", tuned
    ) is None
    stored = host.settings.colors.provider_animation_parameters["claude"]
    assert stored["head_width"] == 3
    assert stored["duration_seconds"] == 4.0
    assert "pass_mode" not in stored, "a working loop cannot play once"
    after = _solo_dsl(host.settings.colors)
    assert after != before
    assert "roll-right 2400ms" in after  # 0.6 of its own 4 s, not the global cycle
    assert len(saved) == 2

    # Clearing the assignment takes the values with it.
    cleared = host.settings.colors.with_agent_animation("claude", "auto")
    assert cleared.agent_animation_parameters("claude") == {}


@pytest.mark.parametrize("motion", ("comet", "breathe", "chase"))
def test_an_old_settings_file_keeps_its_live_tempo(motion: str) -> None:
    """J18: a provider that already had a chosen motion before per-provider
    tempo existed keeps the tempo its lone-agent light played, instead of
    jumping to the global cycle speed."""
    loaded = colors_module.ColorSettings.from_dict(
        {"provider_animation": {"claude": motion}, "cycle_speed_seconds": 0.5}
    )
    seconds = loaded.agent_animation_parameters("claude")["duration_seconds"]
    assert seconds == (5.5 if motion == "breathe" else 2.2)
    # Once written back, the seed is the file's own value, not re-seeded.
    again = colors_module.ColorSettings.from_dict(loaded.to_dict())
    assert again.provider_animation_parameters == loaded.provider_animation_parameters
    fresh = colors_module.ColorSettings.from_dict(
        {"provider_animation": {"claude": motion}, "provider_animation_parameters": {}}
    )
    assert fresh.agent_animation_parameters("claude") == {}


def test_motion_values_round_trip_and_are_bounded() -> None:
    settings = colors_module.ColorSettings.defaults().with_agent_animation(
        "codex", "chase"
    ).with_agent_animation_parameters(
        "codex",
        {"crests": 2, "softness": 0.25, "palette": ["#112233", "#445566"], "bad": object()},
    )
    stored = settings.agent_animation_parameters("codex")
    assert stored == {"crests": 2, "softness": 0.25, "palette": ["#112233", "#445566"]}
    restored = colors_module.ColorSettings.from_dict(settings.to_dict())
    assert restored.agent_animation_parameters("codex") == stored
    garbage = colors_module.ColorSettings.from_dict(
        {"provider_animation_parameters": {"codex": "fast", "": {"a": 1}, "claude": [1, 2]}}
    )
    assert garbage.provider_animation_parameters == {}


def test_opencode_swings_its_own_motion_until_told_otherwise() -> None:
    """J17's OpenCode check: its purple moves as a Pendulum by default -- a
    rhythm no Automatic provider has -- and choosing Automatic sticks."""
    defaults = colors_module.ColorSettings.defaults()
    assert defaults.agent_color("opencode") == "#AF52DE"
    assert defaults.agent_animation("opencode") == colors_module.MOTION_PENDULUM
    assert defaults.agent_animation("claude") == colors_module.PROVIDER_ANIMATION_AUTO
    assert defaults.agent_cycle_ms("opencode", 500) == 2400
    preview = colors_module.provider_motion_preview_program(
        "opencode", defaults.agent_color("opencode"), defaults
    )
    assert "pulse" in preview and "7:" in preview  # a swing across the strip
    automatic = defaults.with_agent_animation("opencode", colors_module.PROVIDER_ANIMATION_AUTO)
    assert automatic.agent_animation("opencode") == colors_module.PROVIDER_ANIMATION_AUTO
    reloaded = colors_module.ColorSettings.from_dict(automatic.to_dict())
    assert reloaded.agent_animation("opencode") == colors_module.PROVIDER_ANIMATION_AUTO
    assert reloaded.provider_animation_parameters == {}
    # Automatic is still never stored for a provider without a motion of its own.
    assert "claude" not in defaults.with_agent_animation("claude", "auto").provider_animation


def test_clearing_an_assignment_gives_back_the_providers_own_motion() -> None:
    """Undoing an Effect Studio assignment puts OpenCode back on its own
    Pendulum, not on an Automatic nobody chose, and takes the values with
    it; a provider without a motion of its own goes back to Automatic."""
    from jrbar import core_runtime
    from jrbar._settings_legacy import AgentMonitorSettings
    from jrbar.effect_assignment_store import EffectAssignmentRecord
    from jrbar.effect_registry import EFFECT_REGISTRY
    from jrbar.effect_studio import AssignmentScope

    class Host:
        _effect_assignment_cache = SimpleNamespace(registry=lambda: EFFECT_REGISTRY)

        def __init__(self) -> None:
            self.settings = AgentMonitorSettings()
            self.saved: list = []
            self.published = 0

        def _core_legacy(self):
            return SimpleNamespace(save_settings=self.saved.append)

        def _core_publish_settings(self) -> None:
            self.published += 1

    host = Host()
    comet = get_effect("comet")
    values = core_effects.normalize_parameters(comet, {"duration_seconds": 0.5})
    for provider in ("opencode", "claude"):
        assert core_runtime._apply_provider_motion_assignment(
            host, comet, AssignmentScope.PROVIDER, provider, values
        ) is None
        assert host.settings.colors.agent_animation(provider) == "comet"
        core_runtime._clear_provider_motion_assignment(
            host, EffectAssignmentRecord("comet", AssignmentScope.PROVIDER, provider)
        )
    colors = host.settings.colors
    assert colors.provider_animation == {}
    assert colors.provider_animation_parameters == {}
    assert colors.agent_animation("opencode") == colors_module.MOTION_PENDULUM
    assert colors.agent_cycle_ms("opencode", 500) == 2400
    assert colors.agent_animation("claude") == colors_module.PROVIDER_ANIMATION_AUTO
    assert len(host.saved) == 4 and host.published == 4
    # Choosing Automatic in Settings is still a choice, and it sticks.
    chosen = colors.with_agent_animation("opencode", colors_module.PROVIDER_ANIMATION_AUTO)
    assert chosen.agent_animation("opencode") == colors_module.PROVIDER_ANIMATION_AUTO
