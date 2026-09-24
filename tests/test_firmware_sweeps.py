"""What one working agent's light actually does, measured on the firmware.

``test_motion_shapes`` holds each shape to the firmware in isolation. These
tests take the program the Pro is really sent for one working agent --
``compose_presentation_program``, the live solo path -- step it through the
packaged engine (``sdled.wasm``) at 60 Hz, and ask about the light: does the
sweep really go both ways, does the heartbeat really beat twice, does the
tempo follow the cycle speed. The old hand-written solo shapes failed the
first two outright (the Scanner's outbound pass and the Heartbeat's first
beat were thrown away by the firmware's one-assignment-per-line rule).
"""

from __future__ import annotations

from itertools import pairwise
from statistics import median

import pytest

from jrbar import colors as colors_module
from jrbar import motion_shapes as shapes
from jrbar._led_wasm_legacy import LedWasmUnavailableError, SdLedWasmController
from jrbar.accessibility_display import AccessibilityDisplayPreferences
from jrbar.animation import loop_duration_ms, parse_animation
from jrbar.flash_analysis import relative_luminance
from jrbar.presentation_policy import (
    GlanceInputs,
    MotionClass,
    compose_presentation_program,
    resolve_glance,
)

FRAME_MS = 1000 / 60
COLOR = "#00E5FF"
FLOOR = shapes.shade(COLOR, 0.05)


def _solo_program(motion: str, *, cycle_seconds: float = 2.2, led_count: int = 8) -> str:
    """The program the strip is sent for one agent working in ``motion``."""
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
    settings = (
        colors_module.ColorSettings.defaults()
        .with_cycle_speed(cycle_seconds)
        .with_agent_animation("claude", motion)
    )
    presentation = compose_presentation_program(
        resolved,
        presentation_time=100.0,
        led_count=led_count,
        color=COLOR,
        preferences=preferences,
        provider="claude",
        color_settings=settings,
    )
    assert presentation.motion is MotionClass.CONTINUOUS, motion
    return presentation.dsl


def _loop_ms(program: str, led_count: int = 8) -> int:
    loop = loop_duration_ms(parse_animation(program, led_count=led_count))
    assert loop, program
    return loop


def _frames(program: str, led_count: int, *, start_ms: float, span_ms: float):
    try:
        controller = SdLedWasmController(led_count)
    except LedWasmUnavailableError as error:  # pragma: no cover - macOS only
        pytest.skip(f"firmware engine unavailable: {error}")
    controller.reset(0)
    result = controller.parse(program, 0)
    assert result.ok, f"firmware rejected {program!r}: {result.error_name}"
    count = int(span_ms / FRAME_MS) + 1
    frames = controller.step_batch(int(start_ms), int(round(FRAME_MS)), count)
    return [[relative_luminance(pixel) for pixel in frame] for frame in frames]


def _second_loop(program: str, led_count: int = 8):
    """One whole loop, skipping the first: the first pass starts from black
    (or, on a desk, from whatever was showing), which is the hand-off rather
    than the motion."""
    loop = _loop_ms(program, led_count)
    return _frames(program, led_count, start_ms=loop, span_ms=loop), loop


def _head_runs(frames) -> list[list[int]]:
    """The brightest LED frame by frame, plateaus collapsed, cut into runs
    that keep one direction."""
    positions: list[int] = []
    for frame in frames:
        brightest = max(range(len(frame)), key=lambda index: frame[index])
        if frame[brightest] > 0.01 and (not positions or positions[-1] != brightest):
            positions.append(brightest)
    runs: list[list[int]] = []
    for position in positions:
        if runs and len(runs[-1]) >= 2:
            rising = runs[-1][-1] > runs[-1][-2]
            if (position > runs[-1][-1]) == rising:
                runs[-1].append(position)
                continue
            runs.append([runs[-1][-1], position])
        elif runs:
            runs[-1].append(position)
        else:
            runs.append([position])
    return runs


@pytest.mark.parametrize("motion", ("scanner", "kitt", "pendulum"))
def test_bouncing_motions_light_every_led_in_each_direction(motion: str) -> None:
    frames, _loop = _second_loop(_solo_program(motion))
    runs = _head_runs(frames)
    outbound = [run for run in runs if run[-1] > run[0]]
    inbound = [run for run in runs if run[-1] < run[0]]
    assert any(run == list(range(8)) for run in outbound), runs
    assert any(run == list(range(7, -1, -1)) for run in inbound), runs


def test_heartbeat_beats_twice_every_cycle() -> None:
    frames, _loop = _second_loop(_solo_program("heartbeat"))
    strip = [sum(frame) / len(frame) for frame in frames]
    threshold = 0.2 * max(strip)
    rises = sum(
        1 for before, after in pairwise(strip) if before < threshold <= after
    )
    assert rises == 2, strip


def test_every_motion_follows_the_cycle_speed() -> None:
    """Slower cycle, longer loop -- for every motion that moves at all."""
    for motion in colors_module.PROVIDER_ANIMATION_CHOICES:
        if motion in (colors_module.PROVIDER_ANIMATION_AUTO, colors_module.MOTION_STEADY):
            continue
        for led_count in (8, 2):
            loops = [
                _loop_ms(_solo_program(motion, cycle_seconds=seconds, led_count=led_count), led_count)
                for seconds in (0.5, 2.2, 5.0)
            ]
            assert loops[0] < loops[1] < loops[2], (motion, led_count, loops)


@pytest.mark.parametrize("motion", ("chase", "comet"))
def test_a_fast_cycle_plays_fast_on_the_strip(motion: str) -> None:
    """Regression pin: at a 0.5 s cycle with no per-provider tempo, one lap
    of a chase or a comet takes well under the old fixed ~2.4 s sweep."""
    program = _solo_program(motion, cycle_seconds=0.5)
    frames = _frames(program, 8, start_ms=1000, span_ms=4000)
    first = [frame[0] for frame in frames]
    crest = max(first)
    peaks = [
        index
        for index in range(1, len(first) - 1)
        if first[index] >= 0.6 * crest
        and first[index] >= first[index - 1]
        and first[index] > first[index + 1]
    ]
    assert len(peaks) >= 3, first
    lap_ms = median(after - before for before, after in pairwise(peaks)) * FRAME_MS
    assert lap_ms < 1200, lap_ms


def _end_dwell(motion: str) -> float:
    """How much longer the brightest point sits on each outer LED (the two
    at either end) than on each middle one, over one loop."""
    frames, _loop = _second_loop(_solo_program(motion, cycle_seconds=2.4))
    held = [max(range(8), key=lambda index: frame[index]) for frame in frames]
    outer = sum(1 for led in held if led in (0, 1, 6, 7)) / 4
    middle = sum(1 for led in held if led in (2, 3, 4, 5)) / 4
    return outer / middle


def test_the_pendulum_lingers_at_the_ends() -> None:
    """A weight on a string slows into each turn: the light sits near the
    ends far longer than it takes to cross the middle -- more so than the
    even-paced Knight Rider eye, whose only dwell is the turn itself."""
    pendulum = _end_dwell("pendulum")
    assert pendulum > 2.5, pendulum
    assert pendulum > 2 * _end_dwell("kitt")


def test_the_pendulum_rushes_dimmer_through_the_middle() -> None:
    """Knight Rider's eye is one brightness end to end; the pendulum's
    light blurs as it rushes through the middle and is brightest where it
    hangs -- the other half of why the two never read as one motion."""
    for motion, dims in (("pendulum", True), ("kitt", False)):
        frames, _loop = _second_loop(_solo_program(motion, cycle_seconds=2.4))
        peak = [max(frame[led] for frame in frames) for led in range(8)]
        middle = max(peak[3], peak[4])
        ends = min(peak[0], peak[7])
        if dims:
            assert middle < 0.6 * ends, (motion, peak)
            assert peak[3] < peak[2] < peak[1] < peak[0], (motion, peak)
        else:
            assert middle > 0.9 * ends, (motion, peak)


def test_land_arrives_faster_and_faster() -> None:
    """Each LED is reached sooner after the last: the gaps shrink toward the
    landing, the way a dropped thing gathers speed."""
    lines = shapes.land(COLOR, FLOOR, led_count=8, cycle_ms=2400)
    program = "\n".join([*lines, "repeat"])
    frames, loop = _second_loop(program)
    # The fall line: the release, the drop and the landing, before the splash.
    fall_frames = frames[: int((shapes.MIN_STEP_MS + 1450) / FRAME_MS)]
    arrivals = [
        max(range(len(fall_frames)), key=lambda index: fall_frames[index][led])
        for led in range(8)
    ]
    gaps = [after - before for before, after in pairwise(arrivals)]
    assert all(gap > 0 for gap in gaps), arrivals
    assert gaps[0] > 3 * gaps[-1], gaps
    # Shrinking, to within one 60 Hz frame of rounding.
    assert all(after <= before + 1 for before, after in pairwise(gaps)), gaps


def test_a_ripple_starts_in_the_middle_and_fades_as_it_spreads() -> None:
    frames, _loop = _second_loop(_solo_program("ripple"))
    peak_at = [max(range(len(frames)), key=lambda index: frames[index][led]) for led in range(8)]
    peak_level = [max(frame[led] for frame in frames) for led in range(8)]
    assert max(peak_at[3], peak_at[4]) < min(peak_at[0], peak_at[7]), peak_at
    assert peak_at[2] < peak_at[1] < peak_at[0], peak_at
    assert peak_level[0] < peak_level[3], peak_level
    assert peak_level[7] < peak_level[4], peak_level


@pytest.mark.parametrize("seconds", (1.0, 2.2, 5.0))
def test_a_ripple_is_never_dark_for_long(seconds: float) -> None:
    """A working light, not a blip and a wait: the ring takes most of the
    cycle to spread, so the strip is never fully dark for as much as a
    third of it (the first cut sat dark for half of every cycle)."""
    frames, _loop = _second_loop(_solo_program("ripple", cycle_seconds=seconds))
    crest = max(max(frame) for frame in frames)
    run = longest = 0
    for frame in frames:
        run = run + 1 if max(frame) < 0.05 * crest else 0
        longest = max(longest, run)
    assert longest < len(frames) / 3, (seconds, longest, len(frames))


@pytest.mark.parametrize("led_count", (8, 2))
def test_a_land_finish_lights_its_landing_once(led_count: int) -> None:
    """The light lands and stays lit where it came to rest until the fade:
    the landing LED rises once. It used to go dark after the splash and
    then light the whole strip again -- a double take."""
    from jrbar import celebrations
    from jrbar.animation import animation_duration_ms

    program = celebrations.done_celebration_program("land", COLOR, led_count=led_count)
    end = animation_duration_ms(parse_animation(program, led_count=led_count))
    frames = _frames(program, led_count, start_ms=0, span_ms=end + 60)
    landing = [frame[led_count - 1] for frame in frames]
    top = max(landing)
    rises = sum(1 for before, after in pairwise(landing) if before < 0.25 * top <= after)
    assert rises == 1, landing
    # Once the splash has thrown back from the neighbours (400 ms), nothing
    # else on the strip lights up again.
    arrived = next(index for index, value in enumerate(landing) if value >= 0.9 * top)
    settled = arrived + int(500 / FRAME_MS)
    others = [max(frame[: led_count - 1]) for frame in frames[settled:]]
    assert all(after <= before + 0.005 for before, after in pairwise(others)), others


def test_the_dot_wipe_reads_as_a_direction() -> None:
    """On two LEDs a travelling motion wipes: LED 0 lights before LED 1 and
    lets go before it, so there is a moment with both lit and a moment with
    only the second -- a crossfade never has both at the crest."""
    frames, _loop = _second_loop(_solo_program("chase", led_count=2), led_count=2)
    first = [frame[0] for frame in frames]
    second = [frame[1] for frame in frames]
    crest = max(max(first), max(second))
    rise_first = next(index for index, value in enumerate(first) if value >= 0.8 * crest)
    rise_second = next(index for index, value in enumerate(second) if value >= 0.8 * crest)
    assert rise_first < rise_second
    both = [a >= 0.8 * crest and b >= 0.8 * crest for a, b in zip(first, second)]
    assert any(both), "the wipe never has both LEDs lit"
