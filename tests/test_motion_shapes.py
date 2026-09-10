"""Every shape has to be smooth ON THE FIRMWARE, not in principle.

These tests drive the packaged firmware engine (``sdled.wasm``) directly, the
same way ``scripts/review_effects.py`` does, and assert about the LED codes it
returns rather than about the text of the program. A shape that reads well and
samples badly is a shape that looks wrong on the desk.
"""

from __future__ import annotations

from itertools import pairwise

import pytest

from jrbar import motion_shapes as shapes
from jrbar._led_wasm_legacy import (  # raw engine: no safety compiler in the way
    LedWasmUnavailableError,
    SdLedWasmController,
)
from jrbar.flash_analysis import relative_luminance

FRAME_MS = 1000 // 60
COLOR = "#00E5FF"
FLOOR = "#000305"


def sample(program: str, led_count: int, frames: int = 240, start_ms: int = 0):
    """The exact codes the strip shows, one 60 Hz frame at a time.

    ``start_ms`` skips the program's arrival. A loop's first pass begins from
    whatever the strip was already showing -- black here, the previous
    program's colours on a real device -- so judging a shape's smoothness from
    t=0 judges the hand-off, not the shape.
    """
    try:
        controller = SdLedWasmController(led_count)
    except LedWasmUnavailableError as error:  # pragma: no cover - macOS only
        pytest.skip(f"firmware engine unavailable: {error}")
    controller.reset(0)
    result = controller.parse(program, 0)
    assert result.ok, f"firmware rejected {program!r}: {result.error_name}"
    return controller.step_batch(int(start_ms), FRAME_MS, frames)


def luminance(frames):
    return [[relative_luminance(pixel) for pixel in frame] for frame in frames]


def biggest_frame_step(frames) -> float:
    tracks = list(zip(*luminance(frames)))
    return max(
        abs(after - before)
        for track in tracks
        for before, after in pairwise(track)
    )


def program(lines: list[str]) -> str:
    return "\n".join([*lines, "repeat"])


def head_positions(frames) -> list[int]:
    """Where the crest is, frame by frame, with its plateaus collapsed.

    A crest sits on one LED for several frames while its neighbours cross
    over, so the raw sequence is full of repeats; the question here is only
    which way it is walking.
    """
    positions = []
    for frame in luminance(frames):
        brightest = max(range(len(frame)), key=lambda index: frame[index])
        if frame[brightest] > 0.01 and (not positions or positions[-1] != brightest):
            positions.append(brightest)
    return positions


ALL_SHAPES = {
    "chase": lambda n: shapes.travelling_wave(COLOR, led_count=n, lap_ms=2000, laps=6),
    "comet": lambda n: shapes.travelling_wave(
        COLOR, led_count=n, lap_ms=1200, tail=shapes.COMET_TAIL, laps=6
    ),
    "marquee": lambda n: shapes.travelling_wave(
        COLOR, led_count=n, lap_ms=2000, tail=shapes.MARQUEE_TAIL, laps=6
    ),
    "tide": lambda n: shapes.travelling_wave(
        COLOR, led_count=n, lap_ms=4000, tail=shapes.TIDE_TAIL, laps=4
    ),
    "gradient": lambda n: shapes.gradient_wave(COLOR, led_count=n, lap_ms=2000, laps=6),
    "kitt": lambda n: shapes.bounce(COLOR, FLOOR, led_count=n, step_ms=140),
    "scanner": lambda n: shapes.bounce(
        COLOR, FLOOR, led_count=n, step_ms=95, tail_leds=1.5
    ),
    "converge": lambda n: shapes.converge(COLOR, FLOOR, led_count=n, step_ms=160),
    "stack": lambda n: shapes.fill(COLOR, FLOOR, led_count=n, cycle_ms=2200),
    "twinkle": lambda n: shapes.scatter(COLOR, FLOOR, led_count=n, cycle_ms=2200),
    "drift": lambda n: shapes.drift(
        COLOR, shapes.shade(COLOR, 0.06), led_count=n, cycle_ms=2200
    ),
    "breathe": lambda n: shapes.breath(COLOR, FLOOR, cycle_ms=2200),
    "duotone": lambda n: shapes.crossfade(COLOR, "#12E3B0", cycle_ms=2200),
    "heartbeat": lambda n: shapes.lub_dub(COLOR, FLOOR, cycle_ms=2200),
}


@pytest.mark.parametrize("name", sorted(ALL_SHAPES))
@pytest.mark.parametrize("led_count", (8, 2))
def test_every_shape_fits_the_firmware_budget(name: str, led_count: int) -> None:
    lines = ALL_SHAPES[name](led_count)
    text = program(lines)
    assert len(text.encode("utf-8")) <= shapes.MAX_PROGRAM_BYTES, name
    assert len(text.splitlines()) <= shapes.MAX_PROGRAM_LINES, name
    sample(text, led_count, frames=4)


#: The steepest a shape may move between two 60 Hz frames. 0.16 is a full
#: swing in about 200 ms at the steepest point of a raised cosine -- a thump
#: you can feel, and still an ease. Anything faster than that is a cut.
MAX_FRAME_STEP = 0.16
#: The ambient shapes -- the ones that live beside the work all day -- are
#: held to a much quieter bar than a heartbeat or a mechanical scanner. A
#: roll interpolates linearly in the firmware's drive codes, so its steepest
#: step in RELATIVE LUMINANCE lands at the top of the gamma curve: the bar
#: below is really a floor on how long a crest spends between neighbours.
AMBIENT_SHAPES = ("breathe", "chase", "drift", "gradient", "marquee", "tide", "twinkle")
GENTLE_FRAME_STEP = 0.10


@pytest.mark.parametrize("name", sorted(ALL_SHAPES))
def test_every_shape_moves_in_small_steps(name: str) -> None:
    """No shape may jump: adjacent 60 Hz frames stay close in steady state."""
    frames = sample(program(ALL_SHAPES[name](8)), 8, frames=360, start_ms=2600)
    assert biggest_frame_step(frames) <= MAX_FRAME_STEP, name


@pytest.mark.parametrize("name", AMBIENT_SHAPES)
def test_the_ambient_shapes_are_gentle(name: str) -> None:
    frames = sample(program(ALL_SHAPES[name](8)), 8, frames=360, start_ms=2600)
    assert biggest_frame_step(frames) <= GENTLE_FRAME_STEP, name


@pytest.mark.parametrize("name", sorted(ALL_SHAPES))
@pytest.mark.parametrize("led_count", (8, 2))
def test_every_shape_eases(name: str, led_count: int) -> None:
    """Nothing in this library cuts.

    `none` is the firmware's hard edge and the only shape in the product that
    wants one is the blink cadence, which is an interruption on purpose and
    lives outside this module. An assignment with no timing at all is the same
    hard edge spelled differently -- it lasts one 17 ms frame.
    """
    for line in ALL_SHAPES[name](led_count):
        assert " none" not in line, f"{name}/{led_count}: {line}"
        for segment in line.split(";"):
            tokens = segment.split()
            assert len(tokens) > 1, f"{name}/{led_count}: untimed paint {segment!r}"


def test_knight_rider_sweeps_out_and_back_without_going_dark() -> None:
    """The head reaches both ends, reverses, and never leaves the strip dark.

    This is the whole complaint the redesign started from: the old shape was a
    one-way stagger that blanked the strip to start over, which is a blink,
    not a scanner.
    """
    lines = shapes.bounce(COLOR, FLOOR, led_count=8, step_ms=140)
    cycle_frames = int(2520 / FRAME_MS) + 1
    frames = sample(program(lines), 8, frames=cycle_frames, start_ms=2520)
    positions = head_positions(frames)
    assert min(positions) == 0 and max(positions) == 7, positions
    steps = [
        second - first for first, second in pairwise(positions)
    ]
    assert all(abs(step) == 1 for step in steps), (
        f"the head skipped LEDs: {positions}"
    )
    assert any(first * second < 0 for first, second in pairwise(steps)), (
        f"the head never reversed: {positions}"
    )
    # And something is always lit, which the staggered-pulse version was not.
    strip = [sum(frame) for frame in luminance(frames)]
    assert min(strip) > 0.01, "the strip went dark mid-sweep"


def test_a_travelling_wave_never_seams() -> None:
    """A rolled profile keeps its total light constant all the way round.

    That is the property no staggered-pulse sweep can have: a bump has to die
    before its line may end, so the strip must fade out once per lap.
    """
    lines = shapes.travelling_wave(COLOR, led_count=8, lap_ms=2000, laps=4)
    frames = sample(program(lines), 8, frames=200, start_ms=1000)
    totals = [sum(frame) for frame in luminance(frames)]
    assert min(totals) > 0.5 * max(totals), "the wave dimmed at the seam"


def test_two_leds_crossfade_rather_than_strobe() -> None:
    """A Dot has nowhere for a head to travel, so it gets a slow crossfade."""
    lines = shapes.travelling_wave(
        COLOR, led_count=2, lap_ms=2200, tail=shapes.DOT_TAIL, laps=4
    )
    frames = sample(program(lines), 2, frames=360, start_ms=2400)
    assert biggest_frame_step(frames) <= GENTLE_FRAME_STEP
    totals = [sum(frame) for frame in luminance(frames)]
    assert min(totals) > 0.5 * max(totals)


def test_no_shape_writes_two_segments_for_one_led_on_a_line() -> None:
    """The firmware keeps the LAST assignment and drops the earlier ones.

    A line that names an LED twice therefore throws away work silently, which
    is exactly how the old heartbeat lost its first beat.
    """
    for name, build in sorted(ALL_SHAPES.items()):
        for led_count in (8, 2):
            for line in build(led_count):
                named = [
                    segment.split(":", 1)[0].strip()
                    for segment in line.split(";")
                    if ":" in segment.split()[0]
                ]
                assert len(named) == len(set(named)), f"{name}/{led_count}: {line}"


def test_a_heartbeat_has_two_unequal_beats_on_their_own_lines() -> None:
    lines = shapes.lub_dub(COLOR, FLOOR, cycle_ms=2200)
    beats = [line for line in lines if "pulse" in line]
    assert len(beats) == 2
    assert beats[0].split()[0] != beats[1].split()[0], "both beats are equal"


def test_shades_stay_on_the_identity() -> None:
    for fraction in (0.0, 0.25, 0.5, 1.0):
        shaded = shapes.shade("#00E5FF", fraction)
        assert shaded.startswith("#00")
    assert shapes.shade("#00E5FF", 1.0) == "#00E5FF"
    assert shapes.shade("#00E5FF", 0.0) == "#000000"


def test_a_profile_resamples_onto_a_shorter_strip() -> None:
    fitted = shapes._fitted_tail(shapes.CHASE_TAIL, 4)
    assert len(fitted) == 4
    assert fitted[0] == 1.0
    assert fitted[-1] < fitted[0]
