"""A failed agent and one waiting on you must never be the same light.

Until 2026-09-10 they were, everywhere: ``colors._STATE_TO_MODE_KEY`` routed
``LedDisplayState.FAILED`` to ``MODE_ASK`` under a comment claiming it kept
"failure distinct from actionable Ask semantics", and
``creator_micro_lighting`` mapped ``failure``, ``quota_exhausted`` and
``quota_warning`` to ``"ask"`` as well. Same hex on the strip, on the Dot, on
the pad and in the app -- so "it needs you" and "it broke" were one colour
and JR-Bar's whole promise (a glance tells you what is happening) did not
hold for the two states you most want to tell apart.

MODE_ERROR is the fix. These tests hold it in place on every surface, and
hold the one property that survives any user configuration: after
normalisation, ask and error are never the same value.
"""

from __future__ import annotations

import itertools

import pytest

from jrbar import colors as colors_module
from jrbar.colors import (
    ERROR_ASK_MIN_SEPARATION,
    MODE_ASK,
    MODE_COLOR_KEYS,
    MODE_DONE,
    MODE_ERROR,
    MODE_IDLE,
    MODE_WORKING,
    ColorSettings,
    mode_color_row,
    mode_color_rows,
    perceptual_gap,
    program_for_snapshot,
    separated_error_color,
)
from jrbar.led_status import ASK_AMBER, ERROR_RED, LedDisplayState, program_for_display_state
from jrbar.models import AgentMode, AgentStatus

# --- the key itself --------------------------------------------------------


def test_error_is_a_first_class_mode_colour() -> None:
    assert MODE_ERROR == "error"
    assert MODE_COLOR_KEYS == (MODE_IDLE, MODE_WORKING, MODE_DONE, MODE_ASK, MODE_ERROR)
    defaults = ColorSettings.defaults()
    assert defaults.mode_color(MODE_ERROR) == ERROR_RED
    assert defaults.mode_color(MODE_ASK) == ASK_AMBER
    assert defaults.mode_color(MODE_ERROR) != defaults.mode_color(MODE_ASK)


def test_the_failed_state_wears_the_error_colour_not_the_ask_one() -> None:
    assert colors_module._STATE_TO_MODE_KEY[LedDisplayState.FAILED] == MODE_ERROR
    assert colors_module._STATE_TO_MODE_KEY[LedDisplayState.ASK] == MODE_ASK
    # The fade envelope is deliberately still shared: the split was about
    # colour, not about giving failure its own set of sliders.
    assert colors_module._STATE_TO_FADE_MODE_KEY[LedDisplayState.FAILED] == MODE_ASK


def test_error_is_configurable_exactly_like_the_other_four() -> None:
    changed = ColorSettings.defaults().with_mode_color(MODE_ERROR, "#123456")
    assert changed.mode_color(MODE_ERROR) == "#123456"
    assert ColorSettings.from_dict(changed.to_dict()).mode_color(MODE_ERROR) == "#123456"
    assert changed.to_dict()["mode_colors"][MODE_ERROR] == "#123456"
    with pytest.raises(ValueError):
        ColorSettings.defaults().with_mode_color("not-a-mode", "#123456")


def test_a_settings_file_written_before_the_key_existed_still_loads() -> None:
    """The upgrade path: every JR-Bar installed before 2026-09-10 has a
    settings file with four mode colours and no ``error``."""
    old = {
        "mode_colors": {
            "idle": "#010203",
            "working": "#00E5FF",
            "done": "#00FF66",
            # The owner's, at the time this was found.
            "ask": "#D187F5",
        },
        "blend_mode": "round_robin",
    }
    loaded = ColorSettings.from_dict(old)
    assert loaded.mode_color(MODE_ASK) == "#D187F5"
    assert loaded.mode_color(MODE_ERROR) == ERROR_RED
    assert loaded.rendered_error_color() == ERROR_RED
    # And the hand-set colours it did carry are untouched.
    assert loaded.mode_color(MODE_IDLE) == "#010203"


def test_the_settings_row_is_named_and_offered_like_the_others() -> None:
    rows = mode_color_rows(ColorSettings.defaults())
    assert [row.key for row in rows] == list(MODE_COLOR_KEYS)
    row = mode_color_row(MODE_ERROR, ColorSettings.defaults())
    assert row.label == "Error (something broke)"
    assert row.current_hex == ERROR_RED
    # The shipped colour leads the row as a ringed "Default" chip, the same
    # contract every other state row has.
    default_group = row.group("default")
    assert default_group is not None
    assert [swatch.hex for swatch in default_group.swatches] == [ERROR_RED]
    assert default_group.swatches[0].selected


# --- the invariant that survives any configuration -------------------------


_SAMPLE_COLOURS = (
    "#FF3A00",  # the shipped ask
    "#B00020",  # the shipped error
    "#FF0000",
    "#D187F5",  # the owner's ask
    "#00E5FF",
    "#00FF66",
    "#020204",
    "#FFFFFF",
    "#000000",
    "#7F0011",
    "#FF9F0A",
)


@pytest.mark.parametrize("ask,error", list(itertools.product(_SAMPLE_COLOURS, repeat=2)))
def test_ask_and_error_are_never_the_same_value_after_normalisation(ask: str, error: str) -> None:
    """The property, over every pair including the pathological ones.

    A user can set either colour to anything, so no default -- however
    carefully measured -- can guarantee the pair stays apart on its own.
    """
    settings = (
        ColorSettings.defaults()
        .with_mode_color(MODE_ASK, ask)
        .with_mode_color(MODE_ERROR, error)
    )
    rendered = settings.rendered_error_color()
    assert rendered.upper() != settings.mode_color(MODE_ASK).upper()
    assert perceptual_gap(settings.mode_color(MODE_ASK), rendered) > 0.0


def test_a_colliding_pair_is_pushed_apart_rather_than_left_alone() -> None:
    settings = (
        ColorSettings.defaults()
        .with_mode_color(MODE_ASK, "#FF0000")
        .with_mode_color(MODE_ERROR, "#FF0000")
    )
    rendered = settings.rendered_error_color()
    assert perceptual_gap("#FF0000", rendered) >= ERROR_ASK_MIN_SEPARATION
    # The literal setting is untouched -- the swatch still shows what was
    # picked; only the LIGHT moves.
    assert settings.mode_color(MODE_ERROR) == "#FF0000"


def test_a_separated_pair_is_returned_byte_for_byte() -> None:
    assert separated_error_color("#D187F5", "#B00020") == "#B00020"
    assert separated_error_color(ASK_AMBER, ERROR_RED) == ERROR_RED


def test_the_rescued_colour_is_still_a_light() -> None:
    """A colour separated by being pushed into the dark is not a fix."""
    for ask in ("#B00020", "#A00030", "#7F0011"):
        rendered = separated_error_color(ask, "#B00020")
        assert (
            colors_module.relative_luminance(rendered)
            >= colors_module.IDENTITY_LUMINANCE_FLOOR
        )


# --- every surface ---------------------------------------------------------


def _failed_status() -> AgentStatus:
    from datetime import datetime, timezone

    return AgentStatus(
        provider="claude",
        agent_id="claude:session:broken",
        display_name="Claude broken",
        mode=AgentMode.BLOCKED_ERROR,
        updated_at=datetime.now(timezone.utc),
        event_name="PostToolUseFailure",
    )


def test_the_strip_renders_a_failure_in_the_error_colour() -> None:
    settings = ColorSettings.defaults()
    assert program_for_display_state(LedDisplayState.FAILED) == ERROR_RED
    program = program_for_display_state(
        LedDisplayState.FAILED,
        ask_color="#D187F5",
        error_color=settings.rendered_error_color(),
    )
    assert program == ERROR_RED
    assert "#D187F5" not in program


def test_classic_mode_renders_a_failure_in_the_error_colour() -> None:
    settings = ColorSettings.defaults().with_blend_mode(colors_module.BLEND_MODE_CLASSIC)
    state, program = program_for_snapshot((_failed_status(),), colors=settings)
    assert state == LedDisplayState.FAILED
    assert settings.mode_color(MODE_ERROR) in program
    assert settings.mode_color(MODE_ASK) not in program


def test_the_dot_beacon_uses_the_shared_error_constant() -> None:
    from jrbar.dot_role import DEFAULT_DOT_ROLE_COLORS, DotBeaconFacts, beacon_program

    assert DEFAULT_DOT_ROLE_COLORS.blocked == ERROR_RED
    assert DEFAULT_DOT_ROLE_COLORS.ask != DEFAULT_DOT_ROLE_COLORS.blocked

    blocked, why, _animated = beacon_program(DotBeaconFacts(blocked=True))
    waiting, waiting_why, _ = beacon_program(DotBeaconFacts(ask_count=1))
    assert why == "failed" and waiting_why == "waiting"
    assert ERROR_RED in blocked
    assert ERROR_RED not in waiting
    assert DEFAULT_DOT_ROLE_COLORS.ask not in blocked


def test_the_creator_micro_keys_tell_broken_from_waiting() -> None:
    from jrbar.creator_micro_lighting import creator_micro_light_frame

    def key(state: str) -> int:
        return creator_micro_light_frame(state).color

    assert key("failure") == int(ERROR_RED.lstrip("#"), 16)
    assert key("failure") != key("input_required")
    # Deliberate split, documented at the mapping: exhausted is "stopped",
    # warning is "your call".
    assert key("quota_exhausted") == key("failure")
    assert key("quota_warning") == key("input_required")


def test_the_deck_slot_colour_tells_broken_from_waiting() -> None:
    from jrbar.core_deck import slot_color

    assert slot_color("failure") == ERROR_RED
    assert slot_color("failure") != slot_color("input_required")


def test_the_effect_semantics_tell_broken_from_waiting() -> None:
    from jrbar.core_effects import SEMANTIC_COLORS
    from jrbar.effect_studio_physical_preview import _SEMANTIC_COLORS

    for table in (SEMANTIC_COLORS, _SEMANTIC_COLORS):
        assert table["failure"] == ERROR_RED
        assert table["failure"] != table["asking"]


def test_the_on_screen_virtual_device_no_longer_paints_a_failure_as_working() -> None:
    from jrbar.virtual_device import virtual_led_colors

    lit = virtual_led_colors(LedDisplayState.FAILED, 0.0)
    working = virtual_led_colors(LedDisplayState.WORKING, 0.0)
    ask = virtual_led_colors(LedDisplayState.ASK, 0.8)
    assert lit != working
    assert lit != ask
    # Red-dominant, and a hard blink: fully off for half its cycle.
    red, green, blue, _alpha = lit[0]
    assert red > green and red > blue
    assert virtual_led_colors(LedDisplayState.FAILED, 0.75)[0][3] == 0.0


def test_the_failure_signal_cue_plays_in_the_error_colour() -> None:
    """``program_for_projection``'s active-signal branch -- the finite
    double blink a failure announces itself with."""
    from types import SimpleNamespace

    from jrbar.attention import AttentionProjection, LifecycleMode, SignalKind

    settings = ColorSettings.defaults().with_mode_color(MODE_ASK, "#D187F5")
    signal = SimpleNamespace(
        signal=SimpleNamespace(kind=SignalKind.FAILURE, repetitions=2),
        started_at=0.0,
        ends_at=1.8,
    )
    projection = AttentionProjection(
        lifecycle_mode=LifecycleMode.FAILED_VISIBLE,
        actionable_attention=(),
        visible_rows=(),
        transient_signals=(),
        dominant_provider="claude",
        click_target_agent_id=None,
    )
    state, program = colors_module.program_for_projection(
        projection, active_signal=signal, colors=settings
    )
    assert state == LedDisplayState.FAILED
    assert settings.rendered_error_color() in program
    assert "#D187F5" not in program


def test_the_error_seed_is_reserved_against_provider_colours() -> None:
    """Adding it to STATE_SEED_COLORS is what keeps a provider from being
    auto-assigned a colour that reads as "this one is broken" -- the
    antigravity/#FF3B30 incident, in the other direction."""
    seeds = dict(colors_module.STATE_SEED_COLORS)
    assert seeds["Error"] == ERROR_RED
    assert seeds["Ask"] != seeds["Error"]
