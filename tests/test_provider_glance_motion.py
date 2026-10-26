"""The per-provider animation must reach the SOLO-agent render path.

The setting was honored by the multi-agent renderers but a lone agent
renders through compose_presentation_program, which always chased --
picking "Breathe" for a solo Codex changed nothing (reported live
2026-08-21)."""

from __future__ import annotations

from jrbar.colors import ColorSettings
from jrbar.presentation_policy import (
    AccessibilityDisplayPreferences,
    GlanceInputs,
    GlanceOverrideReason,
    MotionClass,
    compose_presentation_program,
    resolve_glance,
)

PREFS = AccessibilityDisplayPreferences(False, False, False, False)


def _active_glance():
    return resolve_glance(
        GlanceInputs(
            actionable_episode_key=None,
            fresh_failure=None,
            fresh_completion=None,
            active=True,
            unresolved_failure=False,
            capacity=None,
            override_reason=GlanceOverrideReason.NONE,
            override_semantic=None,
        ),
        presentation_time=100.0,
        relay_epoch=90.0,
        preferences=PREFS,
    )


def _compose(color_settings=None, provider="codex"):
    return compose_presentation_program(
        _active_glance(),
        presentation_time=100.0,
        led_count=8,
        color="#10A37F",
        preferences=PREFS,
        provider=provider,
        color_settings=color_settings,
    )


def test_solo_agent_honors_the_provider_animation__and_2_more() -> None:
    # --- scenario: solo_agent_honors_the_provider_animation
    base = ColorSettings.defaults().with_blend_mode("round_robin")
    chase = _compose(color_settings=base)
    breathe = _compose(base.with_agent_animation("codex", "breathe"))
    blink = _compose(base.with_agent_animation("codex", "blink"))
    steady = _compose(base.with_agent_animation("codex", "steady"))

    # Automatic keeps the relay chase exactly as before.
    assert "pulse 0ms" in chase.dsl
    # Breathe: unison swell, still CONTINUOUS, still repeat-bounded.
    assert breathe.dsl != chase.dsl
    assert breathe.motion is MotionClass.CONTINUOUS
    assert "cosine" in breathe.dsl and "repeat" in breathe.dsl
    # Blink: hard edges.
    assert "none" in blink.dsl and blink.dsl != chase.dsl
    # Steady: no motion at all.
    assert steady.motion is MotionClass.STATIC

    # Another provider's setting must not leak onto codex.
    other = _compose(
        base.with_agent_animation("claude", "breathe"), provider="codex"
    )
    assert other.dsl == chase.dsl

    # --- scenario: urgent_semantics_ignore_the_override
    base = ColorSettings.defaults().with_blend_mode("round_robin").with_agent_animation("codex", "steady")
    resolved = resolve_glance(
        GlanceInputs(
            actionable_episode_key="attention:req-1",
            fresh_failure=None,
            fresh_completion=None,
            active=True,
            unresolved_failure=False,
            capacity=None,
            override_reason=GlanceOverrideReason.NONE,
            override_semantic=None,
        ),
        presentation_time=100.0,
        relay_epoch=90.0,
        preferences=PREFS,
    )
    program = compose_presentation_program(
        resolved,
        presentation_time=100.0,
        led_count=8,
        color="#10A37F",
        preferences=PREFS,
        provider="codex",
        color_settings=base,
    )
    # An ask must never be flattened to steady by a provider preference.
    assert program.motion is not MotionClass.STATIC

    # --- scenario: every_animation_style_renders_a_distinct_program
    """The expanded vocabulary (heartbeat/scanner/comet/flicker) must
    each survive the safety compiler as its own shape -- a style that
    fails closed to the static glyph is a dead menu entry."""
    from jrbar.colors import PROVIDER_ANIMATION_CHOICES

    base = ColorSettings.defaults().with_blend_mode("round_robin")
    programs = {}
    for style in PROVIDER_ANIMATION_CHOICES:
        if style == "auto":
            continue
        program = _compose(base.with_agent_animation("codex", style))
        programs[style] = program.dsl
        if style != "steady":
            assert program.motion is MotionClass.CONTINUOUS, style
    assert len(set(programs.values())) == len(programs)



def test_multi_agent_segments_support_the_new_rhythms__and_1_more() -> None:
    # --- scenario: multi_agent_segments_support_the_new_rhythms
    """The per-LED segment builder must give heartbeat and flicker real
    shapes and degrade positional sweeps to the travelling wave."""
    from jrbar.colors import _motion_segments
    from jrbar.led_status import LedDisplayState

    base = ColorSettings.defaults().with_blend_mode("round_robin")

    def segments(style):
        return _motion_segments(
            3,
            "#10A37F",
            LedDisplayState.WORKING,
            base.with_agent_animation("codex", style),
            cycle_ms=2400,
            settle_ms=160,
            chase_delay_ms=300,
            provider="codex",
        )

    _, heartbeat = segments("heartbeat")
    # ONE segment, always: a line that names the same LED twice loses the
    # first assignment outright in the firmware (measured 2026-09-10), so a
    # two-segment lub-dub played its second beat only. On a shared strip the
    # readable half of the signature is the single swell and the long rest.
    assert heartbeat.count("pulse") == 1
    assert heartbeat.count(":") == 1

    _, flicker = segments("flicker")
    _, breathe = segments("breathe")
    assert flicker != breathe  # detuned, not unison

    _, scanner = segments("scanner")
    _, chase = segments("chase")
    # 2026-08-26 (owner decision): positional sweeps still ride the
    # travelling-wave conversion in shared layouts, but the CLASSES stay
    # distinguishable -- scanner travels as a narrow flare, chase as the
    # full swell. They used to be byte-identical.
    assert scanner != chase
    assert "pulse" in scanner and "pulse" in chase
    _, stack = segments("stack")
    # Stack arrives and stays -- eased, because a bare `none` made every
    # step of the pile a hard edge on an otherwise smooth strip.
    assert "cosine" in stack and "pulse" not in stack

    # --- scenario: new_motions_pass_firmware_grammar_and_byte_budget
    """EVERY motion must stay CONTINUOUS and firmware-valid on both
    compiled LED counts. Scanner and tide shipped silently STATIC on
    the 2-LED Dot -- their loops landed under the safety envelope's 1s
    minimum and fell closed with no test at that count to notice
    (audit, 2026-08-26)."""
    from jrbar.animation import MAX_LED_BYTES, MAX_LED_LINES
    from jrbar.colors import PROVIDER_ANIMATION_CHOICES
    from jrbar.firmware_validation import validate_firmware_program

    base = ColorSettings.defaults().with_blend_mode("round_robin")
    moving = tuple(
        style
        for style in PROVIDER_ANIMATION_CHOICES
        if style not in ("auto", "steady")
    )
    for style in moving:
        for led_count in (2, 8):
            program = compose_presentation_program(
                _active_glance(),
                presentation_time=100.0,
                led_count=led_count,
                color="#10A37F",
                preferences=PREFS,
                provider="codex",
                color_settings=base.with_agent_animation("codex", style),
            )
            assert program.motion is MotionClass.CONTINUOUS, (style, led_count)
            assert len(program.dsl.encode("utf-8")) <= MAX_LED_BYTES, (
                style,
                led_count,
                len(program.dsl.encode("utf-8")),
            )
            assert program.dsl.count("\n") + 1 <= MAX_LED_LINES
            result = validate_firmware_program(
                program.dsl, led_count=led_count
            )
            assert result.accepted, (style, led_count, result.reason)



def test_calm_solo_presentation_is_steady_and_keeps_attention_and_failure_cues():
    from dataclasses import replace

    from jrbar.led_wasm import RawSdLedWasmController
    from jrbar.presentation_policy import FiniteCue, GlanceSemantic

    for mix in ("classic", "color_blend"):
        settings = ColorSettings.defaults().with_blend_mode(mix).with_agent_animation("codex", "kitt")
        for count in (2, 8):
            active = _active_glance()
            for semantic in (GlanceSemantic.ACTIVE, GlanceSemantic.REST, GlanceSemantic.FRESH_COMPLETION):
                resolved = replace(active, semantic=semantic)
                result = compose_presentation_program(resolved, presentation_time=100, led_count=count,
                    color=settings.agent_color("codex"), preferences=PREFS, provider="codex", color_settings=settings)
                assert result.motion is MotionClass.STATIC
                assert result.next_visual_change_at is None
                firmware = RawSdLedWasmController(count)
                assert firmware.parse(result.dsl, 0).ok
                frames = firmware.step_batch(0, 40, 250)
                assert all(frame == frames[0] for frame in frames)
            for semantic in (GlanceSemantic.ATTENTION, GlanceSemantic.FRESH_FAILURE):
                resolved = replace(active, semantic=semantic,
                    cue=FiniteCue("synthetic", semantic, repetitions=2, duration_seconds=1.8))
                result = compose_presentation_program(resolved, presentation_time=100, led_count=count,
                    color=settings.mode_color("ask"), preferences=PREFS, color_settings=settings)
                assert result.motion is MotionClass.FINITE
                firmware = RawSdLedWasmController(count)
                assert firmware.parse(result.dsl, 0).ok
                frames = firmware.step_batch(0, 40, 100)
                assert any(frame != frames[0] for frame in frames[1:])


def test_calm_mix_does_not_freeze_the_provider_animation_picker():
    from jrbar.presentation_policy import solo_working_program

    for mix in ("classic", "color_blend"):
        settings = ColorSettings.defaults().with_blend_mode(mix).with_agent_animation("codex", "kitt")
        original = settings.to_dict()
        for count in (2, 8):
            assert "repeat" in solo_working_program("codex", settings, led_count=count)
        assert settings.to_dict() == original
