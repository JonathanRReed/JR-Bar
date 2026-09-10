"""Flashing is a property of the FIELD, not of how often a pixel changes.

Every case here is a pair: something that looks fast and is not a flash, and
something that is. The compiler's whole job is telling those apart, and the old
cadence-from-text rule got the first column wrong every time.
"""

from __future__ import annotations

import pytest

from jrbar import flash_analysis
from jrbar import motion_shapes as shapes
from jrbar.animation import parse_animation


def hertz(program: str, led_count: int = 8) -> float:
    return flash_analysis.analyse(
        parse_animation(program), led_count=led_count
    ).hertz


# --- things that really flash ------------------------------------------------


def test_a_whole_bar_blink_reports_its_real_rate() -> None:
    assert hertz("#FFFFFF 100ms none\noff 100ms none\nrepeat") == pytest.approx(
        5.0, abs=0.2
    )


def test_a_strobe_hidden_inside_a_long_loop_is_still_a_strobe() -> None:
    """The hole the text-based rule left open.

    Ten 60 ms lines make a 600 ms loop, which clears every cadence floor the
    old compiler had -- and flashes the whole strip eight times a second.
    """
    program = "\n".join(["#FFFFFF 60ms none", "off 60ms none"] * 5 + ["repeat"])
    assert hertz(program) > 8.0


def test_a_fast_whole_strip_breath_counts_even_though_it_eases() -> None:
    """Smoothness is not a defence: a 4 Hz full-field swing is a hazard."""
    assert hertz("#FFFFFF 250ms pulse\nrepeat") == pytest.approx(4.0, abs=0.3)


def test_a_quarter_of_the_strip_is_enough_area() -> None:
    two_of_eight = (
        "0:#FFFFFF 100ms none; 1:#FFFFFF 100ms none\n"
        "0:#000000 100ms none; 1:#000000 100ms none\nrepeat"
    )
    assert hertz(two_of_eight) > 2.0


# --- things that do not -------------------------------------------------------


def test_one_led_blinking_is_below_the_area_rule() -> None:
    """One of eight is 12.5% of the field: under the 25% area rule."""
    one_of_eight = (
        "0:#FFFFFF 100ms none\n0:#000000 100ms none\nrepeat"
    )
    assert hertz(one_of_eight) == 0.0


def test_a_travelling_head_is_not_a_flash_however_fast_it_travels() -> None:
    """A head stepping one LED every 60 ms is motion, not a strobe."""
    segments = "; ".join(
        f"{index}:#00E5FF 120ms pulse" + (f" {index * 60}ms" if index else "")
        for index in range(8)
    )
    assert hertz(f"{segments}\nrepeat") <= 2.0


def test_a_roll_never_counts() -> None:
    """A roll repaints nothing: it slides the field and ends where it began."""
    program = "\n".join(
        [
            "#FF0000 #00FF00 #0000FF 200ms cosine",
            "roll-right 400ms linear",
            "repeat",
        ]
    )
    assert hertz(program) == 0.0


def test_the_working_relay_is_not_a_flash() -> None:
    lines = shapes.travelling_wave("#00E5FF", led_count=8, lap_ms=2000, laps=6)
    assert hertz("\n".join([*lines, "repeat"])) <= 2.0


def test_knight_rider_is_not_a_flash() -> None:
    lines = shapes.bounce("#00E5FF", "#000305", led_count=8, step_ms=140)
    assert hertz("\n".join([*lines, "repeat"])) <= 2.0


def test_the_idle_breath_is_not_a_flash() -> None:
    program = (
        "off 160ms cosine\n#020204 1900ms cosine\noff 2550ms cosine\n"
        "off 850ms none\nrepeat"
    )
    assert hertz(program) < 1.0


# --- the model itself ---------------------------------------------------------


def test_none_jumps_at_its_delay_not_at_the_end_of_its_duration() -> None:
    """Measured against the firmware; modelling it the other way halved every
    hard blink's reported rate."""
    frames, interval = flash_analysis.render_luminance(
        parse_animation("0:#FFFFFF 500ms none 100ms"), led_count=8
    )
    at = lambda ms: frames[ms // interval][0]  # noqa: E731
    assert at(0) == 0.0
    assert at(200) > 0.9


def test_a_line_keeps_only_the_last_segment_for_an_led() -> None:
    """The firmware drops the earlier assignment outright, so the model does."""
    frames, _ = flash_analysis.render_luminance(
        parse_animation("0:#FFFFFF 100ms none; 0:#000000 100ms none"),
        led_count=8,
    )
    assert max(frame[0] for frame in frames) == 0.0


def test_brightness_alone_never_reverses_the_field() -> None:
    assert hertz("brightness 20\n#FFFFFF 600ms none\nrepeat") == 0.0
