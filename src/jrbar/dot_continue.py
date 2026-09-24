"""The Dot as more strip: light that runs off the end of the Pro into it.

``mirror`` (the default) folds the strip's eight LEDs into the Dot's two.
``continue`` treats the Dot as LEDs 8 and 9 of a longer strip instead: a
comet that leaves LED 7 arrives at the Dot a moment later, as if the strip
went on. It only means something for light that TRAVELS, so a breathe, a
solid colour or anything whose LEDs do not follow each other returns
``None`` and the caller mirrors instead.

How it works: the strip's compiled loop is sampled per LED (the same curves
the firmware plays, ``linked_sync.line_curves``, and rolls as the sliding
crossfades they are); the travel time between neighbouring LEDs is found by
matching each LED against the next one shifted in time; and the Dot's two
LEDs are what the strip's end LED showed one and two steps of travel ago
(or will show, when the light runs the other way). That is spelled as a
loop of colour-list keyframes with linear crossfades -- at most twelve,
placed where the colour turns -- whose lap is the strip's lap exactly, so
it takes the same rotation and retiming as any linked Dot program.
"""

from __future__ import annotations

from collections.abc import Callable
from dataclasses import dataclass
from functools import lru_cache
from itertools import pairwise
from typing import Final

from .animation import (
    Animation,
    BrightnessStep,
    ColorList,
    PaintStep,
    RepeatStep,
    RollStep,
    Timing,
    errors_only,
    loop_duration_ms,
    read_program,
    render_animation,
    step_duration_ms,
)
from .linked_sync import RGB, LockedDot, curve_weight, line_curves, resting_state

#: The Dot program's keyframe budget: 12 lines of ``#RRGGBB #RRGGBB Tms
#: linear`` is about 330 bytes, leaving room for brightness and repeat.
MAX_KEYFRAMES: Final = 12
#: How finely the strip is sampled to find travel and place keyframes.
_SAMPLE_MS: Final = 10.0
#: Two neighbouring LEDs whose shifted timelines differ by more than this
#: (mean brightness, in codes) are not one travelling light.
_TRAVEL_MATCH_CODES: Final = 12.0
#: The most samples a lap is matched over.
_MAX_SAMPLES: Final = 160


@dataclass(frozen=True, slots=True)
class _Sampler:
    """The strip's loop as per-LED colours at any time within one lap."""

    steps: tuple
    entry: list[RGB]
    led_count: int
    lap_ms: float

    def at(self, time_ms: float) -> list[RGB]:
        time_ms %= self.lap_ms
        state = list(self.entry)
        elapsed = 0.0
        for step in self.steps:
            span = float(step_duration_ms(step))
            if type(step) is PaintStep:
                if time_ms < elapsed + span:
                    curves = line_curves(step, state, self.led_count)
                    local = time_ms - elapsed
                    out = list(state)
                    for led, led_curves in curves.items():
                        color = tuple(float(v) for v in state[led])
                        for curve in led_curves:
                            if curve.begin < local or (curve.easing == "none" and curve.begin <= local):
                                color = curve.at(local)
                        out[led] = tuple(int(round(v)) for v in color)  # type: ignore[assignment]
                    return out
                state = resting_state(step, state, self.led_count)
            elif type(step) is RollStep and span > 0:
                if time_ms < elapsed + span:
                    return _rolled(state, step, (time_ms - elapsed) / span)
            elapsed += span
        return state


def _rolled(state: list[RGB], step: RollStep, fraction: float) -> list[RGB]:
    count = len(state)
    position = count * curve_weight(step.easing or "linear", fraction)
    whole = int(position)
    part = position - whole
    sign = -1 if step.direction == "roll-left" else 1
    out: list[RGB] = []
    for led in range(count):
        near = state[(led - sign * whole) % count]
        far = state[(led - sign * (whole + 1)) % count]
        out.append(tuple(int(round(a + (b - a) * part)) for a, b in zip(near, far)))  # type: ignore[arg-type]
    return out


def _sampler(program: str, led_count: int) -> _Sampler | None:
    animation, problems = read_program(program, led_count=led_count)
    if animation is None or errors_only(problems):
        return None
    lap = loop_duration_ms(animation)
    if not lap:
        return None
    body = []
    for step in animation.steps:
        if type(step) is RepeatStep:
            break
        body.append(step)
    entry: list[RGB] = [(0, 0, 0)] * led_count
    for step in body:
        if type(step) is PaintStep:
            entry = resting_state(step, entry, led_count)
    return _Sampler(tuple(body), entry, led_count, float(lap))


def _luma(color: RGB) -> float:
    red, green, blue = color
    return 0.2126 * red + 0.7152 * green + 0.0722 * blue


@lru_cache(maxsize=64)
def travel_ms(program: str, led_count: int) -> float | None:
    """How long light takes to move one LED, signed: positive when it runs
    toward the last LED, negative toward the first. ``None`` when the LEDs
    do not follow one another (a breathe, a blink, a solid colour).

    Matched on brightness over at most 160 samples a lap, and cached: the
    planner asks on every Dot plan, and the answer only changes with the
    program."""
    sampler = _sampler(program, led_count)
    if sampler is None or led_count < 3:
        return None
    count = max(16, min(_MAX_SAMPLES, int(sampler.lap_ms / _SAMPLE_MS)))
    times = [sampler.lap_ms * index / count for index in range(count)]
    frames = [sampler.at(time) for time in times]
    series = [[_luma(frame[led]) for frame in frames] for led in range(led_count)]
    if all(max(values) - min(values) < 2.0 for values in series):
        return None  # nothing moves at all
    if all(
        max(abs(a - b) for a, b in zip(series[0], values)) < 2.0 for values in series[1:]
    ):
        return None  # every LED the same: nothing travels
    def mismatch(shift: int) -> float:
        return max(
            sum(
                abs(series[led][(index - shift) % count] - series[led + 1][index])
                for index in range(count)
            )
            / count
            for led in range(led_count - 1)
        )

    # Neighbours that already look alike unshifted are a shimmer, not a
    # travelling light: a one-sample "travel" would only be noise.
    unshifted = mismatch(0)
    best: tuple[float, int] | None = None
    for shift in range(1, count):
        score = 0.0
        for led in range(led_count - 1):
            leader, follower = series[led], series[led + 1]
            error = sum(
                abs(leader[(index - shift) % count] - follower[index]) for index in range(count)
            ) / count
            score = max(score, error)
            if best is not None and score >= best[0]:
                break
        if best is None or score < best[0]:
            best = (score, shift)
    if best is None or best[0] > _TRAVEL_MATCH_CODES or best[0] > 0.5 * unshifted:
        return None
    step_ms = sampler.lap_ms * best[1] / count
    if step_ms > sampler.lap_ms / 2.0:
        step_ms -= sampler.lap_ms
    return step_ms if abs(step_ms) >= 1.0 else None


def _keyframes(values: Callable[[float], list[RGB]], lap_ms: float) -> list[float]:
    """Keyframe times across one lap, placed where a linear crossfade
    between neighbours strays furthest from the real colour."""
    samples = max(16, min(4 * _MAX_SAMPLES, int(lap_ms / _SAMPLE_MS)))
    grid = [lap_ms * index / samples for index in range(samples + 1)]
    colors = [values(time) for time in grid]
    chosen = {0, samples}
    while len(chosen) < MAX_KEYFRAMES + 1:
        ordered = sorted(chosen)
        worst: tuple[float, int] | None = None
        for left, right in pairwise(ordered):
            for index in range(left + 1, right):
                fraction = (index - left) / (right - left)
                guess = [
                    tuple(a + (b - a) * fraction for a, b in zip(pa, pb))
                    for pa, pb in zip(colors[left], colors[right])
                ]
                error = max(abs(x - y) for pg, pc in zip(guess, colors[index]) for x, y in zip(pg, pc))
                if worst is None or error > worst[0]:
                    worst = (error, index)
        if worst is None or worst[0] <= 3.0:
            break
        chosen.add(worst[1])
    return [grid[index] for index in sorted(chosen)]


def continue_program(
    strip_program: str,
    *,
    source_leds: int,
    led_count: int = 2,
    side: str = "after_last",
    dot_direction: str = "forward",
    finalize: Callable[[str], str] | None = None,
) -> LockedDot | None:
    """The Dot's ``continue`` program, locked to the strip's period, or
    ``None`` to mirror instead (nothing travels, or the Dot's own safety
    gate would change the loop's length)."""
    from .presentation_compiler import compile_presentation_program

    compiled = compile_presentation_program(strip_program, led_count=source_leds)
    if not compiled.accepted:
        return None
    step = travel_ms(compiled.program, source_leds)
    sampler = _sampler(compiled.program, source_leds)
    if step is None or sampler is None:
        return None
    end_led = source_leds - 1 if side != "before_first" else 0
    # Light moving toward the Dot's end arrives later at each Dot LED; light
    # moving away passed it earlier. ``outward`` is +1 when it moves toward.
    outward = 1.0 if (step > 0) == (side != "before_first") else -1.0
    travel = abs(step)

    def dot_at(time_ms: float) -> list[RGB]:
        colors = [
            sampler.at(time_ms - outward * (index + 1) * travel)[end_led]
            for index in range(led_count)
        ]
        return colors[::-1] if dot_direction == "reversed" else colors

    times = _keyframes(dot_at, sampler.lap_ms)
    lap = int(round(sampler.lap_ms))
    steps: list = [
        BrightnessStep(level=s.level)
        for s in read_program(compiled.program, led_count=source_leds)[0].steps
        if type(s) is BrightnessStep
    ][:1]
    emitted = 0
    for left, right in pairwise(times):
        duration = max(1, int(round(right)) - emitted)
        emitted += duration
        colors = tuple(
            "#" + "".join(f"{value:02X}" for value in color) for color in dot_at(right)
        )
        steps.append(PaintStep((ColorList(colors, Timing(duration_ms=duration, easing="linear")),)))
    if emitted != lap and len(steps) > 1:
        last = steps[-1]
        segment = last.segments[0]
        fixed = max(1, segment.timing.duration_ms + (lap - emitted))
        steps[-1] = PaintStep((ColorList(segment.colors, Timing(duration_ms=fixed, easing="linear")),))
    steps.append(RepeatStep())
    program = render_animation(Animation("continue", tuple(steps)))
    text = finalize(program) if finalize is not None else program
    check = compile_presentation_program(text, led_count=led_count)
    judged, problems = read_program(check.program, led_count=led_count)
    if not check.accepted or judged is None or errors_only(problems):
        return None
    if loop_duration_ms(judged) != lap:
        return None
    return LockedDot(program, "continue", lap, compiled.program)


__all__ = ["MAX_KEYFRAMES", "continue_program", "travel_ms"]
