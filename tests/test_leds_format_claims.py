"""Every rule LEDS_FORMAT.md states, checked against the firmware's own
parser (the packaged sdled.wasm). The published spec once led hand-written
programs into parse errors; these keep it from drifting again."""

from __future__ import annotations

import pytest

from jrbar.animation import errors_only, read_program
from jrbar.led_wasm import RawSdLedWasmController


def firmware(program: str, led_count: int = 8):
    """The packaged parser's raw result, with no JR-Bar gate in front of it.

    firmware_parse_error goes through the presentation compiler, which is
    deliberately stricter; the spec describes the firmware, so ask it.
    """
    controller = RawSdLedWasmController(led_count=led_count)
    controller.reset(0)
    return controller.parse(program, 0)


def verdict(program: str, led_count: int = 8) -> str | None:
    """None when the firmware accepts; else its error name."""
    result = firmware(program, led_count)
    return None if result.ok else result.error_name


@pytest.mark.parametrize(
    "program",
    [
        # Keywords, easing names and suffixes are case-insensitive.
        "OFF",
        "#ff00ff 330MS COSINE\nRepeat",
        # The three comment spellings, only at the start of a line.
        "// a note\n#ffffff",
        "; a note\n#ffffff",
        "#\n#ffffff",
        "# a note\n#ffffff",
        "#\ta note\n#ffffff",
        # Empty segments are ignored.
        "0:#ff0000 1s;; 1:#00ff00 1s",
        # Separate segments for a colour list and indexes.
        "#ff0000; 0:#00ff00",
        # Three fraction digits kept, the rest dropped.
        "#ff00ff 0.3333s",
        # A repeat after a lit line, with or without a count.
        "#ff0000 200ms none\nrepeat 10",
        "#ff0000 200ms none\nrepeat 65535",
        "#ff0044 #ff8800\nroll 2s linear\nrepeat",
        # One trailing break does not start a line: 20 lines plus a newline.
        "\n".join(["#ffffff 10ms"] * 20) + "\n",
    ],
)
def test_what_the_spec_says_parses_parses(program: str) -> None:
    assert verdict(program) is None


@pytest.mark.parametrize(
    ("program", "error"),
    [
        ("#comment", "bad-color"),
        ("#fff", "bad-color"),
        ("0:off", "bad-index"),
        ("0:", "bad-index"),
        ("0:#fff", "bad-index"),
        ("#ff0000 0:#00ff00", "bad-time"),
        ("brightness 256", "bad-brightness"),
        ("brightness 10 x", "trailing-input"),
        ("#ff00ff .5s", "bad-time"),
        ("roll 2s; #ff0000", "bad-time"),
        ("brightness 50\nrepeat\n#ff0000", "bad-repeat"),
        ("#ff0000 1s\nrepeat\nrepeat", "bad-repeat"),
        ("#ff0000 1s\nrepeat 0", "bad-repeat"),
        ("#ff0000 1s\nrepeat 65536", "bad-repeat"),
        ("\n".join(["#ffffff 10ms"] * 21), "too-many-lines"),
        ("#ffffff " + "x" * 600, "too-long"),
    ],
)
def test_what_the_spec_says_fails_fails_the_way_it_says(program: str, error: str) -> None:
    assert verdict(program) == error


def test_a_premature_repeat_is_reported_on_the_line_after_it() -> None:
    result = firmware("brightness 50\nrepeat\n#ff0000")
    assert (result.ok, result.error_name, result.line) == (False, "bad-repeat", 3)


def test_indexes_past_the_led_count_do_not_light_a_dot() -> None:
    # On a 2-LED Dot, LED 5 is parsed and ignored; a repeat after only that
    # has nothing lit before it.
    assert verdict("5:#ffffff 80ms none", led_count=2) is None
    assert verdict("5:#ffffff 80ms none\nrepeat", led_count=2) == "bad-repeat"


@pytest.mark.parametrize("program", ["#\ta note\n#ffffff", "#ff00ff 0.3333s"])
def test_jrbars_own_reader_is_stricter_where_the_spec_says(program: str) -> None:
    # The firmware takes a tab and drops a fourth fraction digit; JR-Bar
    # refuses both, so nothing it shows reads differently on the device.
    assert verdict(program) is None
    _, problems = read_program(program, led_count=8)
    assert errors_only(problems)
