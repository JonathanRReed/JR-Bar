"""One brightness rule for the strip and the Dot (upstream #38, ported).

"Maximum brightness: caps every light JR-Bar drives" was not true: the
strip put ``brightness N`` in front of a program that carried its own
``brightness 255``, and the firmware obeys the last one, so a custom
program escaped the cap. The Dot deleted authored lines instead, so the same
program read differently on the two devices. Now both multiply: every
authored ``brightness M`` becomes ``round(M * N / 255)``, and ``N`` goes in
front only when the program has none and N is below full scale."""

from __future__ import annotations

import re

from jrbar._led_status_legacy import apply_brightness, fold_brightness, scale_program_brightness
from jrbar.dot_role import apply_brightness_line

_LINE = re.compile(r"(?im)^\s*brightness\s+(\d+)\s*$")

PROGRAMS = (
    "#FFFFFF",
    "brightness 255\n#FFFFFF 500ms\noff 500ms\nrepeat",
    "brightness 128\n#FF0000 1s pulse\nrepeat",
    "#00FF00 400ms\nbrightness 200\n#0000FF 400ms\nbrightness 40\nrepeat",
    "  brightness 9\n#123456",
)


def _levels(program: str) -> list[int]:
    return [int(match.group(1)) for match in _LINE.finditer(program)]


def test_no_emitted_line_exceeds_the_cap_on_either_device__and_3_more() -> None:
    # --- scenario: every_line_stays_under_the_cap_pro_and_dot
    for cap in (0, 1, 17, 64, 128, 200, 254, 255):
        for program in PROGRAMS:
            for device_rule in (apply_brightness, apply_brightness_line):
                emitted = device_rule(program, cap)
                assert all(level <= cap for level in _levels(emitted)), (device_rule, cap, program)
                if cap < 255:
                    assert _levels(emitted), "a capped program always says how bright"

    # --- scenario: an_authored_255_at_cap_64_is_exactly_one_effective_64
    for device_rule in (apply_brightness, apply_brightness_line):
        emitted = device_rule("brightness 255\n#FFFFFF", 64)
        assert _levels(emitted) == [64]

    # --- scenario: both_devices_read_one_program_the_same
    for cap in (30, 99, 255):
        for program in PROGRAMS:
            assert apply_brightness(program, cap) == apply_brightness_line(program, cap)

    # --- scenario: authored_lines_multiply_and_a_bare_program_gets_one_line
    assert fold_brightness("brightness 200\n#FF0000", 128) == "brightness 100\n#FF0000"
    assert fold_brightness("#FF0000", 128) == "brightness 128\n#FF0000"
    assert fold_brightness("#FF0000", 255) == "#FF0000"
    assert fold_brightness("brightness 200\n#FF0000", 255) == "brightness 200\n#FF0000"
    assert _levels(fold_brightness(PROGRAMS[3], 128)) == [100, 20]


def test_the_linked_scale_works_in_light_line_by_line() -> None:
    """``linked_dot_scale`` scales the strip's policy in LIGHT on every
    line (0.5 of a nominal 100 is 71, not 50), and a program with no line
    gets one; full scale changes nothing."""
    assert scale_program_brightness("brightness 100\n#112233", 0.5) == "brightness 71\n#112233"
    assert scale_program_brightness("#112233", 0.5) == "brightness 188\n#112233"
    assert scale_program_brightness("brightness 100\n#112233", 1.0) == "brightness 100\n#112233"
    scaled = _levels(scale_program_brightness(PROGRAMS[3], 0.3))
    original = _levels(PROGRAMS[3])
    assert len(scaled) == len(original)
    assert all(0 < after < before for after, before in zip(scaled, original))
