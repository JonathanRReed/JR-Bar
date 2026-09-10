"""What a light program actually *flashes*, measured rather than guessed.

The temporal-safety compiler used to reason about cadence from the text of a
program: how long each step lasted, how long the loop was. That is a fine
proxy for a bar that blinks, and a bad one for a bar that moves. A travelling
head that steps to the next LED every 60 ms changes colour twenty times a
second and is not a flash at all -- it is one small bright thing sliding along
a mostly dark strip, which is the same reason a mouse pointer is not a strobe.

So this module renders the program instead, in pure Python (no firmware, no
JavaScriptCore -- the compiler runs on every device write and must work
everywhere), and applies the accessibility definition of a flash rather than a
typographic one. From WCAG 2.2 SC 2.3.1 and ISO 9241-391, a *general flash* is

* a pair of opposing changes in relative luminance,
* of at least ``FLASH_LUMINANCE_DELTA`` where the darker state is below
  ``FLASH_DARK_CEILING`` relative luminance, and
* occupying more than ``FLASH_AREA_FRACTION`` of the field at once.

All three have to hold. Spatial motion fails the third: at any instant a comet
is bright on one or two LEDs, so no matter how fast the head moves, the *field*
is not reversing. A whole-bar blink passes all three at whatever rate it
blinks, and that is exactly what the compiler still slows down.

``roll`` is exempt outright, and the reason is structural rather than a
threshold: it repaints nothing. The firmware slides the arrangement one full
wraparound and leaves it exactly where it began, so a roll can only move light
about, never make more or less of it.

The renderer is deliberately approximate about easing curves -- an ``ease-in``
is treated as a smoothstep rather than the exact cubic -- because the question
being asked is "how many times per second does most of this strip reverse
brightness", and no answer to that turns on the third decimal of a curve.
"""

from __future__ import annotations

import math
from dataclasses import dataclass
from itertools import pairwise

from .animation import (
    OFF,
    Animation,
    BrightnessStep,
    ColorList,
    IndexedPaint,
    PaintStep,
    RepeatStep,
    RollStep,
    WholeBar,
    step_duration_ms,
)

#: The accessibility thresholds, named so a reader can check them against the
#: standards rather than against this file.
FLASH_AREA_FRACTION = 0.25
FLASH_LUMINANCE_DELTA = 0.10
FLASH_DARK_CEILING = 0.80
FLASH_CONTRAST = 0.20
#: Sampling. 20 ms is a little over one firmware frame, which is fine: a
#: reversal the eye can see lasts many frames, and a reversal that does not is
#: not a flash. The cap keeps a very long program from costing real time on
#: the device-write path.
FLASH_SAMPLE_MS = 20
MAX_FLASH_SAMPLES = 1200


@dataclass(frozen=True, slots=True)
class FlashAnalysis:
    """How often the field reverses, and over how long."""

    hertz: float
    flashes: int
    span_ms: int
    peak_area: float

    @property
    def flashing(self) -> bool:
        return self.flashes > 0


def relative_luminance(color: tuple[int, int, int]) -> float:
    """IEC 61966-2-1 relative luminance of one 8-bit colour."""

    def channel(value: int) -> float:
        fraction = max(0.0, min(1.0, value / 255.0))
        if fraction <= 0.04045:
            return fraction / 12.92
        return ((fraction + 0.055) / 1.055) ** 2.4

    red, green, blue = color
    return (
        0.2126 * channel(red) + 0.7152 * channel(green) + 0.0722 * channel(blue)
    )


def _rgb(color: str) -> tuple[int, int, int]:
    if not isinstance(color, str):
        return (0, 0, 0)
    cleaned = color.strip().lower()
    if cleaned == OFF:
        return (0, 0, 0)
    cleaned = cleaned.lstrip("#")
    if len(cleaned) != 6:
        return (0, 0, 0)
    try:
        return (
            int(cleaned[0:2], 16),
            int(cleaned[2:4], 16),
            int(cleaned[4:6], 16),
        )
    except ValueError:
        return (0, 0, 0)


def _eased(easing: str | None, fraction: float) -> float:
    """Where a transition has got to, as a fraction of the way to its target.

    ``pulse`` is the odd one: it returns to where it started, so it reports a
    fraction that rises to one and falls back to zero.
    """
    position = max(0.0, min(1.0, fraction))
    if easing == "none":
        # Measured against the firmware: `none` jumps to its target the moment
        # the delay is up and holds for the rest of the line. It does not wait
        # out the duration, and modelling it that way halved the reported rate
        # of every hard blink.
        return 1.0
    if easing == "pulse":
        return (1.0 - math.cos(2.0 * math.pi * position)) / 2.0
    if easing == "cosine":
        return (1.0 - math.cos(math.pi * position)) / 2.0
    if easing == "linear":
        return position
    # ease / ease-in / ease-out / ease-in-out, and a bare duration, which the
    # firmware treats as `ease`. Smoothstep is close enough for counting
    # reversals and needs no curve table.
    return position * position * (3.0 - 2.0 * position)


@dataclass(frozen=True, slots=True)
class _Transition:
    delay_ms: int
    duration_ms: int
    easing: str | None
    start: tuple[int, int, int]
    target: tuple[int, int, int]
    returns: bool

    def at(self, offset_ms: float) -> tuple[int, int, int]:
        if offset_ms < self.delay_ms:
            return self.start
        if self.duration_ms <= 0:
            return self.target
        fraction = (offset_ms - self.delay_ms) / self.duration_ms
        if fraction >= 1.0 and not self.returns:
            return self.target
        weight = _eased(self.easing, fraction)
        return tuple(  # type: ignore[return-value]
            max(0, min(255, round(begin + (end - begin) * weight)))
            for begin, end in zip(self.start, self.target)
        )

    @property
    def resting(self) -> tuple[int, int, int]:
        return self.start if self.returns else self.target


def _segment_targets(segment, led_count: int) -> dict[int, tuple[int, int, int]]:
    """Which LEDs this segment paints, and to what.

    ``WholeBar`` and ``ColorList`` name the whole field (a colour list turns
    the LEDs past its end off, which is the firmware's rule and the reason it
    counts as a field-wide paint); ``IndexedPaint`` names only its own LEDs
    and leaves the rest holding.
    """
    if type(segment) is WholeBar:
        return {index: _rgb(segment.color) for index in range(led_count)}
    if type(segment) is ColorList:
        return {
            index: _rgb(segment.colors[index]) if index < len(segment.colors) else (0, 0, 0)
            for index in range(led_count)
        }
    if type(segment) is IndexedPaint:
        return {
            int(index): _rgb(color)
            for index, color in segment.assignments
            if 0 <= int(index) < led_count
        }
    return {}


def _paint_transitions(
    step: PaintStep,
    state: list[tuple[int, int, int]],
    led_count: int,
) -> dict[int, _Transition]:
    """One line's per-LED transitions, later segments winning.

    The firmware keeps the LAST assignment an LED gets on a line and drops the
    earlier ones outright -- measured, and the reason nothing in this codebase
    writes two segments for one LED any more. Modelling it the same way keeps
    the analysis honest about what the strip will really show.
    """
    transitions: dict[int, _Transition] = {}
    for segment in step.segments:
        timing = segment.timing
        duration = timing.effective_duration_ms
        delay = timing.delay_ms or 0
        easing = timing.easing
        for index, target in _segment_targets(segment, led_count).items():
            transitions[index] = _Transition(
                delay,
                duration,
                easing,
                state[index],
                target,
                easing == "pulse",
            )
    return transitions


def loop_steps(animation: Animation) -> tuple[object, ...]:
    """The steps that play over and over, or every step when none repeat."""
    for index, step in enumerate(animation.steps):
        if type(step) is RepeatStep:
            return animation.steps[:index]
    return animation.steps


def _played(
    steps: tuple[object, ...],
    state: list[tuple[int, int, int]],
    interval: int,
    frames: list[list[float]],
) -> list[tuple[int, int, int]]:
    """One pass of the loop: appends its frames, returns the state it leaves."""
    budget = MAX_FLASH_SAMPLES
    for step in steps:
        if type(step) is BrightnessStep:
            # Global and last-one-wins in the firmware, so it scales the whole
            # program uniformly and cannot by itself reverse the field.
            continue
        span = step_duration_ms(step)
        if type(step) is PaintStep:
            transitions = _paint_transitions(step, state, len(state))
            offset = 0
            while offset < span and budget > 0:
                frame = list(state)
                for index, transition in transitions.items():
                    frame[index] = transition.at(offset)
                frames.append([relative_luminance(color) for color in frame])
                budget -= 1
                offset += interval
            for index, transition in transitions.items():
                state[index] = transition.resting
        elif type(step) is RollStep:
            # A roll TRANSLATES the field; it never reverses it. No LED is
            # repainted -- the arrangement slides one full wraparound and ends
            # exactly where it started -- so a roll cannot be a flash however
            # fast it runs, and it is held here at the pre-roll state rather
            # than rotated. (Rotating it would report flashes that are an
            # artefact of crossfading in 8-bit code space, which is sub-linear
            # in light: three lit LEDs sliding along a dark strip make the
            # *mean* dip between positions without anything blinking.)
            #
            # It still costs its own duration, which is what matters for the
            # rate: a loop that spends two seconds rolling is a loop that
            # flashes at most half as often.
            held = [relative_luminance(color) for color in state]
            offset = 0
            while offset < span and budget > 0:
                frames.append(list(held))
                budget -= 1
                offset += interval
        if budget <= 0:
            break
    return state


def render_luminance(
    animation: Animation,
    *,
    led_count: int,
    sample_ms: int = FLASH_SAMPLE_MS,
    passes: int = 1,
) -> tuple[list[list[float]], int]:
    """Per-LED relative luminance through the repeating section.

    Returns the frames and the interval between them. The strip starts dark,
    which is what the firmware shows on a fresh parse from rest.

    ``passes`` plays the loop more than once and returns only the LAST pass.
    That is what makes the reading a steady-state one: a loop's first pass
    arrives from wherever the strip happened to be, and comparing its cold
    start against its own end invents a reversal that never happens again.
    """
    steps = loop_steps(animation)
    state: list[tuple[int, int, int]] = [(0, 0, 0)] * max(1, int(led_count))
    interval = max(1, int(sample_ms))
    for _ in range(max(1, int(passes)) - 1):
        state = _played(steps, state, interval, [])
    frames: list[list[float]] = []
    _played(steps, state, interval, frames)
    if not frames:
        frames.append([relative_luminance(color) for color in state])
    return frames, interval


def _extrema(series: list[float]) -> list[int]:
    """Indexes of the turning points of a signal, ends included."""
    if len(series) < 2:
        return [0]
    points = [0]
    direction = 0
    for index in range(1, len(series)):
        change = series[index] - series[index - 1]
        if abs(change) < 1e-9:
            continue
        sign = 1 if change > 0 else -1
        if sign == direction:
            points[-1] = index
        else:
            points.append(index)
            direction = sign
    if points[-1] != len(series) - 1:
        points.append(len(series) - 1)
    return points


def analyse(animation: Animation, *, led_count: int) -> FlashAnalysis:
    """How many general flashes a second this program sustains.

    A flash is counted only when the field reverses: the strip's mean
    luminance turns around with at least ``FLASH_CONTRAST`` Michelson
    contrast, *and* at least ``FLASH_AREA_FRACTION`` of the LEDs individually
    moved by ``FLASH_LUMINANCE_DELTA`` or more out of a state darker than
    ``FLASH_DARK_CEILING``. Two reversals make one flash, so a bar that goes
    dark and bright once a second reports 1 Hz.
    """
    count = max(1, int(led_count))
    frames, interval = render_luminance(animation, led_count=count, passes=2)
    span_ms = max(interval, len(frames) * interval)
    if len(frames) < 3:
        return FlashAnalysis(0.0, 0, span_ms, 0.0)
    if any(type(step) is RepeatStep for step in animation.steps):
        # The loop seam is a transition like any other, and for a two-phase
        # blink it is HALF the flashes: without it a bar that goes bright and
        # dark once per loop reads as one reversal instead of two.
        frames = [*frames, frames[0]]
    means = [sum(frame) / len(frame) for frame in frames]
    turns = _extrema(means)
    reversals = 0
    peak_area = 0.0
    for first, second in pairwise(turns):
        low, high = sorted((means[first], means[second]))
        total = low + high
        contrast = (high - low) / total if total > 1e-9 else 0.0
        if contrast < FLASH_CONTRAST:
            continue
        # The area rule is about the field moving TOGETHER. Counting every
        # LED that changed makes a travelling wave look like a flash, because
        # the crest brightens one LED while it dims the one behind it -- two
        # changes in opposite directions, which is motion, not a reversal.
        rising = means[second] > means[first]
        moved = 0
        for index in range(count):
            begin = frames[first][index]
            end = frames[second][index]
            if (end > begin) != rising:
                continue
            if abs(end - begin) < FLASH_LUMINANCE_DELTA:
                continue
            if min(begin, end) >= FLASH_DARK_CEILING:
                continue
            moved += 1
        area = moved / count
        peak_area = max(peak_area, area)
        if area >= FLASH_AREA_FRACTION:
            reversals += 1
    seconds = span_ms / 1000.0
    flashes = reversals // 2
    hertz = (reversals / 2.0) / seconds if seconds > 0 else 0.0
    return FlashAnalysis(hertz, flashes, span_ms, peak_area)


__all__ = (
    "FLASH_AREA_FRACTION",
    "FLASH_CONTRAST",
    "FLASH_DARK_CEILING",
    "FLASH_LUMINANCE_DELTA",
    "FLASH_SAMPLE_MS",
    "FlashAnalysis",
    "analyse",
    "loop_steps",
    "relative_luminance",
    "render_luminance",
)
