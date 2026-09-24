"""Keeping a linked Dot on the strip's beat.

The firmware starts a program's clock the moment it parses the file, and it
has no start time, epoch or sync directive. So two devices can only share a
beat if their programs are built to: the Dot's loop is rotated so that, at
the instant it restarts, it plays the phase the strip is already on.

That alone stopped working within seconds, because the Dot's own clock runs
about 2.7% slow (its ``ticks`` counter advances roughly 973 ms for every
1000 ms of real time; the Pro's clock matches the Mac's). This module holds
the arithmetic that keeps the pair together anyway:

* ``retime_program`` rewrites a program for a clock that runs at ``rate``
  device-ms per real ms, with every lap total exact to half a millisecond;
* ``phase_ms`` is where the strip's loop is at a given moment, from the
  strip's recorded start (``A_pro``), never from "the skew of this pair";
* ``slice_window`` cuts a paint line anywhere -- inside a ``pulse`` too, as
  the two ``cosine`` halves the firmware really plays -- so a rotation lands
  where it was asked to;
* ``apply_device_timing`` is the write boundary's last step for a linked
  Dot: rotate by the phase, then retime, after the safety gate has judged
  the program in real milliseconds;
* ``period_locked_dot`` narrows the strip's compiled program for the Dot
  and steps down a ladder of looks rather than let the Dot's own safety
  check change its loop length;
* ``predicted_error_ms`` and ``should_resync`` close the loop from fresh
  reads of the Dot's ``ticks``.

Everything here is pure: no I/O, no settings, no controller.
"""

from __future__ import annotations

import math
from collections.abc import Callable
from dataclasses import dataclass, replace
from itertools import pairwise
from typing import Final

from .animation import (
    MAX_TIME_MS,
    OFF,
    Animation,
    BrightnessStep,
    ColorList,
    CommentStep,
    IndexedPaint,
    PaintStep,
    RepeatStep,
    RollStep,
    Timing,
    WholeBar,
    errors_only,
    loop_duration_ms,
    normalize_color,
    read_program,
    render_animation,
    step_duration_ms,
)

#: The firmware's own budget for one program.
MAX_PROGRAM_BYTES: Final = 512
MAX_PROGRAM_LINES: Final = 20

#: How far a sliced curve may stray from the one it stands in for, in
#: 8-bit codes per channel. Two codes is below what anyone can see on an
#: LED and is what the two-engine tests hold the rotation to.
MAX_SLICE_ERROR_CODES: Final = 2.0
#: At most this many extra lines may be spent making one cut exact.
MAX_SLICE_EXTRA_LINES: Final = 6

#: Where a Dot's clock starts before anything has been measured: the rate
#: measured on the first Dot (SPD-000120) over sparse reads, 2026-09-24.
WARM_START_DOT_RATE: Final = 0.9734
#: No real clock is this far off; a fit outside means the samples are bad.
MIN_CLOCK_RATE: Final = 0.90
MAX_CLOCK_RATE: Final = 1.10

#: The re-anchor rules (``linked_sync_tolerance_ms``).
DEFAULT_SYNC_TOLERANCE_MS: Final = 40.0
MIN_SYNC_TOLERANCE_MS: Final = 20.0
MAX_SYNC_TOLERANCE_MS: Final = 200.0
#: The fewest seconds between two sync writes to the Dot, and between two
#: fresh reads of its clock. Reads cost the Dot ticks (4 reads a second made
#: it 3.8% slow instead of 2.7%), and writes cost a restart.
SYNC_INTERVAL_SECONDS: Final = 20.0
#: ``linked_dot_phase_trim_ms`` bounds.
MAX_PHASE_TRIM_MS: Final = 250.0


# --- the firmware's curves ---------------------------------------------------


def _bezier(x1: float, y1: float, x2: float, y2: float) -> Callable[[float], float]:
    """A CSS cubic-bezier easing, solved by bisection. The firmware's
    ``ease`` family matches the CSS definitions to within a code."""

    def curve(x: float) -> float:
        low, high = 0.0, 1.0
        for _ in range(32):
            t = (low + high) / 2.0
            at = 3 * (1 - t) ** 2 * t * x1 + 3 * (1 - t) * t * t * x2 + t**3
            if at < x:
                low = t
            else:
                high = t
        t = (low + high) / 2.0
        return 3 * (1 - t) ** 2 * t * y1 + 3 * (1 - t) * t * t * y2 + t**3

    return curve


_CURVES: Final[dict[str, Callable[[float], float]]] = {
    "linear": lambda x: x,
    "ease": _bezier(0.25, 0.1, 0.25, 1.0),
    "ease-in": _bezier(0.42, 0.0, 1.0, 1.0),
    "ease-out": _bezier(0.0, 0.0, 0.58, 1.0),
    "ease-in-out": _bezier(0.42, 0.0, 0.58, 1.0),
    "cosine": lambda x: (1.0 - math.cos(math.pi * x)) / 2.0,
}
#: The easings a sliced piece may be spelled with, cheapest bytes first.
_FIT_EASINGS: Final = ("linear", "cosine", "ease", "ease-in", "ease-out", "ease-in-out")


def curve_weight(easing: str | None, fraction: float) -> float:
    """How far a transition has got toward its target, 0..1, the way the
    firmware plays it. A bare duration is ``ease``; ``none`` is already
    there; ``pulse`` rises to one and falls back."""
    position = max(0.0, min(1.0, fraction))
    name = (easing or "ease").lower()
    if name == "none":
        return 1.0
    if name == "pulse":
        return (1.0 - math.cos(2.0 * math.pi * position)) / 2.0
    return _CURVES.get(name, _CURVES["ease"])(position)


# --- colour helpers ----------------------------------------------------------

RGB = tuple[int, int, int]
_BLACK: Final[RGB] = (0, 0, 0)


def _rgb(color: str) -> RGB:
    if not isinstance(color, str) or color.strip().lower() == OFF:
        return _BLACK
    text = color.strip().lstrip("#")
    try:
        return (int(text[0:2], 16), int(text[2:4], 16), int(text[4:6], 16))
    except ValueError:
        return _BLACK


def _hex(color: tuple[float, float, float]) -> str:
    return "#" + "".join(f"{max(0, min(255, int(round(value)))):02X}" for value in color)


def _mix(start: RGB, end: RGB, weight: float) -> tuple[float, float, float]:
    return tuple(a + (b - a) * weight for a, b in zip(start, end))  # type: ignore[return-value]


# --- per-LED timelines of one paint line -------------------------------------


@dataclass(frozen=True, slots=True)
class _Curve:
    """One LED's colour over one paint line: hold ``start`` until ``begin``,
    move along ``easing`` to ``target`` by ``end``, then hold.

    A ``pulse`` is never one of these: it is split into its two ``cosine``
    halves before anything reads it, because that is exactly what the
    firmware plays (probed: the sampled values agree within a code)."""

    begin: float
    end: float
    easing: str
    start: RGB
    target: RGB

    def at(self, time_ms: float) -> tuple[float, float, float]:
        if time_ms <= self.begin:
            return tuple(float(v) for v in self.start)  # type: ignore[return-value]
        if self.easing == "none" or self.end <= self.begin:
            return tuple(float(v) for v in self.target)  # type: ignore[return-value]
        fraction = (time_ms - self.begin) / (self.end - self.begin)
        return _mix(self.start, self.target, curve_weight(self.easing, fraction))


def _segment_targets(segment, led_count: int) -> dict[int, RGB]:
    if type(segment) is WholeBar:
        return {index: _rgb(segment.color) for index in range(led_count)}
    if type(segment) is ColorList:
        return {
            index: _rgb(segment.colors[index]) if index < len(segment.colors) else _BLACK
            for index in range(led_count)
        }
    if type(segment) is IndexedPaint:
        return {
            int(index): _rgb(color)
            for index, color in segment.assignments
            if 0 <= int(index) < led_count
        }
    return {}


def line_curves(step: PaintStep, state: list[RGB], led_count: int) -> dict[int, list[_Curve]]:
    """Each LED's curves across one paint line, later segments winning
    (the firmware keeps the last assignment an LED gets on a line)."""
    latest: dict[int, tuple[Timing, RGB]] = {}
    for segment in step.segments:
        for index, target in _segment_targets(segment, led_count).items():
            latest[index] = (segment.timing, target)
    curves: dict[int, list[_Curve]] = {}
    for index, (timing, target) in latest.items():
        start = state[index] if index < len(state) else _BLACK
        begin = float(timing.delay_ms or 0)
        duration = float(timing.effective_duration_ms)
        easing = (timing.easing or "ease").lower()
        if timing.duration_ms is None and timing.easing is None:
            # No timing at all sets the colour at once and lasts a frame.
            easing = "none"
        if easing == "pulse":
            middle = begin + duration / 2.0
            curves[index] = [
                _Curve(begin, middle, "cosine", start, target),
                _Curve(middle, begin + duration, "cosine", target, start),
            ]
        else:
            curves[index] = [_Curve(begin, begin + duration, easing, start, target)]
    return curves


def resting_state(step: PaintStep, state: list[RGB], led_count: int) -> list[RGB]:
    """The per-LED colours one paint line leaves behind."""
    after = list(state)
    for index, curves in line_curves(step, state, led_count).items():
        if 0 <= index < led_count:
            after[index] = curves[-1].target
    return after


def _steady_entry_state(body, led_count: int, *, looping: bool) -> list[RGB]:
    """What a loop's first line is entered with once the loop is running:
    what a whole lap leaves behind, not the black of a cold start. A roll
    ends exactly where it began, so it changes nothing here."""
    state = [_BLACK] * led_count
    if not looping:
        return state
    for step in body:
        if type(step) is PaintStep:
            state = resting_state(step, state, led_count)
    return state


# --- fitting a piece of curve with one firmware easing -----------------------


def _fit(curve: _Curve, t0: float, t1: float) -> tuple[str, float, RGB, RGB]:
    """``(easing, error_codes, from, to)`` for the part of ``curve`` between
    ``t0`` and ``t1``, spelled as one fresh transition.

    The error is the worst channel distance, in codes, between the true
    curve and the fresh one over 24 samples. A whole curve, a linear one
    and a ``none`` jump are exact and cost nothing to check."""
    a = curve.at(t0)
    b = curve.at(t1)
    start = tuple(int(round(v)) for v in a)
    end = tuple(int(round(v)) for v in b)
    if curve.easing == "none" or t1 <= t0:
        return ("none" if curve.easing == "none" else "linear"), 0.0, start, end  # type: ignore[return-value]
    whole = abs(t0 - curve.begin) < 1e-6 and abs(t1 - curve.end) < 1e-6
    if whole or curve.easing == "linear" or start == end:
        return (curve.easing if whole else "linear"), 0.0, start, end  # type: ignore[return-value]
    best = ("linear", float("inf"))
    for easing in _FIT_EASINGS:
        error = 0.0
        for sample in range(1, 24):
            fraction = sample / 24.0
            truth = curve.at(t0 + (t1 - t0) * fraction)
            guess = _mix(start, end, curve_weight(easing, fraction))  # type: ignore[arg-type]
            error = max(error, max(abs(x - y) for x, y in zip(truth, guess)))
            if error >= best[1]:
                break
        if error < best[1]:
            best = (easing, error)
    return best[0], best[1], start, end  # type: ignore[return-value]


def _hold(duration: float) -> Timing:
    """A bare duration to the colour the LED already shows: a hold."""
    return Timing(duration_ms=max(1, int(round(duration))))


def _whole_pulse(curves: list[_Curve], start: float, stop: float) -> bool:
    """The two cosine halves of one pulse, both inside ``[start, stop)``."""
    if len(curves) != 2:
        return False
    rise, fall = curves
    return (
        rise.easing == fall.easing == "cosine"
        and abs(rise.end - fall.begin) < 1e-6
        and rise.start == fall.target
        and rise.target == fall.start
        and rise.begin >= start - 1e-6
        and fall.end <= stop + 1e-6
    )


def _pulse_breaks(curves: dict[int, list[_Curve]], breaks: set[float]) -> None:
    """Add the midpoint of every pulse a window cuts, until none is cut
    across its middle: one line holds one transition per LED, and a pulse's
    halves are two, unless the whole pulse sits inside one line."""
    changed = True
    while changed:
        changed = False
        points = sorted(breaks)
        for led_curves in curves.values():
            if len(led_curves) != 2:
                continue
            middle = led_curves[0].end
            for left, right in pairwise(points):
                if left + 0.5 < middle < right - 0.5 and not _whole_pulse(led_curves, left, right):
                    breaks.add(middle)
                    changed = True
                    break
            if changed:
                break


def _window_line(
    curves: dict[int, list[_Curve]],
    state_at: dict[int, RGB],
    start: float,
    stop: float,
    led_count: int,
) -> tuple[PaintStep, float]:
    """One line covering ``[start, stop)`` of the original line, and the
    worst fitting error on it. Every LED is addressed, so nothing is left
    holding a colour from somewhere else."""
    segments: list[IndexedPaint] = []
    worst = 0.0
    width = stop - start
    for led in range(led_count):
        pieces = [
            curve
            for curve in curves.get(led, [])
            if curve.end > start + 1e-6 and curve.begin < stop - 1e-6
        ]
        moving = [curve for curve in pieces if curve.easing == "none" or curve.end > curve.begin]
        if not moving:
            color = state_at[led]
            segments.append(IndexedPaint(((led, _hex(color)),), _hold(width)))
            continue
        if _whole_pulse(moving, start, stop):
            # Both halves of a pulse inside the window: still one pulse,
            # exact and a third of the bytes of its halves.
            rise, fall = moving
            delay = int(round(rise.begin - start))
            segments.append(
                IndexedPaint(
                    ((led, _hex(rise.target)),),
                    Timing(
                        duration_ms=max(2, int(round(fall.end - rise.begin))),
                        easing="pulse",
                        delay_ms=delay or None,
                    ),
                )
            )
            continue
        curve = moving[0]
        if curve.easing == "none":
            if curve.begin <= start + 1e-6:
                # Already jumped: ``none`` again, never a bare duration --
                # the firmware eases a bare duration from whatever the LED
                # shows, which after an ``off`` line is a fade-in.
                segments.append(
                    IndexedPaint(
                        ((led, _hex(curve.target)),),
                        Timing(duration_ms=max(1, int(round(width))), easing="none"),
                    )
                )
            else:
                delay = int(round(curve.begin - start))
                segments.append(
                    IndexedPaint(
                        ((led, _hex(curve.target)),),
                        Timing(
                            duration_ms=max(1, int(round(width)) - delay),
                            easing="none",
                            delay_ms=delay or None,
                        ),
                    )
                )
            continue
        begin = max(curve.begin, start)
        end = min(curve.end, stop)
        easing, error, _from, to = _fit(curve, begin, end)
        drift = max(abs(a - b) for a, b in zip(state_at[led], to))
        if drift <= MAX_SLICE_ERROR_CODES:
            # A move too small to see: held (to where it ends) for the
            # whole window, which costs a third of the bytes.
            worst = max(worst, drift)
            segments.append(IndexedPaint(((led, _hex(to)),), _hold(width)))
            continue
        worst = max(worst, error)
        delay = int(round(begin - start))
        duration = max(1, int(round(end - begin)))
        segments.append(
            IndexedPaint(
                ((led, _hex(to)),),
                Timing(duration_ms=duration, easing=easing, delay_ms=delay or None),
            )
        )
    return PaintStep(tuple(segments)), worst


def _state_at(curves: dict[int, list[_Curve]], state: list[RGB], time_ms: float, led_count: int) -> dict[int, RGB]:
    result: dict[int, RGB] = {}
    for led in range(led_count):
        color: tuple[float, ...] = tuple(float(v) for v in (state[led] if led < len(state) else _BLACK))
        for curve in curves.get(led, []):
            if curve.begin < time_ms or (curve.easing == "none" and curve.begin <= time_ms):
                color = curve.at(time_ms)
        result[led] = tuple(int(round(v)) for v in color)  # type: ignore[assignment]
    return result


def slice_window(
    step: PaintStep,
    *,
    state: list[RGB],
    led_count: int,
    start: float,
    stop: float,
    max_error: float = MAX_SLICE_ERROR_CODES,
    max_lines: int = 1 + MAX_SLICE_EXTRA_LINES,
) -> list[PaintStep] | None:
    """The part ``[start, stop)`` of one paint line as a run of lines.

    ``state`` is what the LEDs show as the ORIGINAL line begins. The run
    lasts exactly ``stop - start`` and plays what the original line plays
    over that window: pulses as their two cosine halves, a transition that
    was cut part-way as the firmware easing that fits its remaining shape,
    bisected until it is within ``max_error`` codes or ``max_lines`` is
    spent. ``None`` only when the window is empty.

    The run's own line boundaries sit on the midpoints of the pulses the
    window cuts, because one line can hold only one transition per LED; a
    pulse wholly inside a line stays one ``pulse``.
    """
    if stop - start < 0.5:
        return None
    curves = line_curves(step, state, led_count)
    breaks = {start, stop}
    _pulse_breaks(curves, breaks)

    def window(left: float, right: float) -> tuple[PaintStep, float]:
        return _window_line(curves, _state_at(curves, state, left, led_count), left, right, led_count)

    while True:
        points = sorted(breaks)
        lines: list[PaintStep] = []
        worst_at: tuple[float, float, float] | None = None
        for left, right in pairwise(points):
            line, error = window(left, right)
            lines.append(line)
            if error > max_error and (worst_at is None or error > worst_at[0]):
                worst_at = (error, left, right)
        if worst_at is None or len(points) - 1 >= max_lines:
            break
        _error, left, right = worst_at
        # Split where it helps most: of a few candidate points inside the
        # curves that are moving in this window, the one whose worse half
        # fits best. Bisecting blindly spent twice the lines on a cosine
        # cut near its inflection, and a split in a stretch where every
        # LED holds spent a line on nothing.
        spans = [
            (max(curve.begin, left), min(curve.end, right))
            for led_curves in curves.values()
            for curve in led_curves
            if curve.easing != "none" and min(curve.end, right) - max(curve.begin, left) > 2.0
        ] or [(left, right)]
        best: tuple[float, float] | None = None
        for low, high in spans:
            for fraction in (0.5, 1.0 / 3.0, 2.0 / 3.0, 0.25, 0.75):
                split = float(round(low + (high - low) * fraction))
                if split <= left + 1 or split >= right - 1:
                    continue
                score = max(window(left, split)[1], window(split, right)[1])
                if best is None or score < best[1]:
                    best = (split, score)
        if best is None:
            break
        breaks.add(best[0])
        _pulse_breaks(curves, breaks)
    points = sorted(breaks)
    padded: list[PaintStep] = []
    for line, left, right in zip(lines, points, points[1:]):
        padded.append(line)
        short = int(round(right - left)) - step_duration_ms(line)
        if short >= 1:
            # Every LED finished early on this line: a hold line keeps the
            # window its full length rather than stretching someone's ramp.
            held = _state_at(curves, state, right, led_count)
            padded.append(
                PaintStep(
                    tuple(
                        IndexedPaint(((led, _hex(held[led])),), _hold(short))
                        for led in range(led_count)
                    )
                )
            )
    _fix_run_length(padded, stop - start)
    return [_compact(line, led_count) for line in padded]


def _compact(step: PaintStep, led_count: int) -> PaintStep:
    """A line that names every LED with one shared timing, spelled as a
    colour list (or one colour for the whole bar): the same instruction in
    half the bytes, which the 512-byte budget needs. With timings that
    differ, the first LED's segment becomes a whole-bar one and the rest
    override it (the firmware keeps an LED's last assignment on a line):
    two bytes a line, which is what lets a Dot's continuation be cut
    anywhere and still fit."""
    segments = step.segments
    if len(segments) != led_count or any(type(s) is not IndexedPaint for s in segments):
        return step
    by_led = {}
    for segment in segments:
        for index, color in segment.assignments:
            by_led[int(index)] = color
    if sorted(by_led) != list(range(led_count)):
        return step
    timings = {s.timing for s in segments}
    if len(timings) != 1:
        first = segments[0]
        if len(first.assignments) != 1 or any(len(s.assignments) != 1 for s in segments):
            return step
        return PaintStep((WholeBar(_bar(first.assignments[0][1]), first.timing), *segments[1:]))
    timing = timings.pop()
    colors = tuple(by_led[index] for index in range(led_count))
    if len(set(colors)) == 1:
        return PaintStep((WholeBar(_bar(colors[0]), timing),))
    return PaintStep((ColorList(colors, timing),))


def _bar(color: str) -> str:
    """A whole-bar colour in its shortest spelling: black is ``off``."""
    return OFF if _rgb(color) == _BLACK and color.strip().lower() in (OFF, "#000000") else color


def _fix_run_length(lines: list[PaintStep], want: float) -> None:
    """Rounding each line's timings can leave the run a millisecond off the
    window it replaces; the last line absorbs the difference so the loop's
    length never moves."""
    have = sum(step_duration_ms(line) for line in lines)
    delta = int(round(want)) - have
    if not lines or delta == 0:
        return
    last = lines[-1]
    span = step_duration_ms(last)
    goal = span + delta
    if delta > 0:
        ends = [max(range(len(last.segments)), key=lambda i: last.segments[i].timing.span_ms)]
    else:
        # Every segment still ending past the goal comes in: one left tied
        # with the longest kept the run a millisecond long.
        ends = [i for i, segment in enumerate(last.segments) if segment.timing.span_ms > goal]
    segments = list(last.segments)
    for index in ends:
        timing = segments[index].timing
        duration = max(1, timing.effective_duration_ms + (goal - timing.span_ms))
        segments[index] = replace(segments[index], timing=replace(timing, duration_ms=duration))
    lines[-1] = PaintStep(tuple(segments))


# --- rolls on a narrow device ------------------------------------------------


def unroll(step: RollStep, state: list[RGB], led_count: int) -> list[PaintStep] | None:
    """A roll as the crossfades it really is, so a cut can land inside it.

    A roll slides the visible arrangement one full wraparound; with
    ``led_count`` LEDs that is ``led_count`` crossfades from each shift to
    the next (probed on the Dot: ``roll 2s`` equals two one-second linear
    crossfades within a code). Exact for a linear roll; an eased roll is
    spelled per crossfade with the easing that fits it best. ``None`` for
    anything wider than two LEDs, which is never rotated.
    """
    if led_count > 2 or led_count < 1:
        return None
    total = float(step.duration_ms)
    if total <= 0:
        return None
    easing = (step.easing or "linear").lower()
    arrangement = list(state[:led_count])
    shifts = led_count
    steps: list[PaintStep] = []
    position_curve = lambda fraction: curve_weight(easing, fraction)  # noqa: E731
    boundaries = [0.0]
    for shift in range(1, shifts + 1):
        goal = shift / shifts
        if easing == "linear":
            boundaries.append(total * goal)
            continue
        low, high = 0.0, 1.0
        for _ in range(40):
            mid = (low + high) / 2.0
            if position_curve(mid) < goal:
                low = mid
            else:
                high = mid
        boundaries.append(total * high)
    boundaries[-1] = total
    emitted = 0
    for shift in range(shifts):
        direction = 1 if step.direction != "roll-left" else -1
        target = [
            arrangement[(index - direction * (shift + 1)) % led_count] for index in range(led_count)
        ]
        begin, end = boundaries[shift], boundaries[shift + 1]
        duration = max(1, int(round(end)) - emitted)
        emitted += duration
        piece_easing = "linear"
        if easing != "linear":
            lo = shift / shifts

            def piece(fraction: float, lo: float = lo, begin: float = begin, end: float = end) -> float:
                return (position_curve((begin + (end - begin) * fraction) / total) - lo) * shifts

            piece_easing = min(
                _FIT_EASINGS,
                key=lambda name: max(
                    abs(piece(i / 16.0) - curve_weight(name, i / 16.0)) for i in range(17)
                ),
            )
        steps.append(
            PaintStep(
                (
                    IndexedPaint(
                        tuple((index, _hex(color)) for index, color in enumerate(target)),
                        Timing(duration_ms=duration, easing=piece_easing),
                    ),
                )
            )
        )
    return steps


# --- rotation ----------------------------------------------------------------


def _cut_step(
    step, state: list[RGB], led_count: int, within: float, *, max_lines: int
) -> tuple[list, list] | None:
    """``(before, after)``: one step cut ``within`` ms in, as two runs of
    lines that together play exactly what the step plays."""
    span = step_duration_ms(step)
    if type(step) is PaintStep:
        before = slice_window(
            step, state=state, led_count=led_count, start=0.0, stop=within, max_lines=max_lines
        )
        after = slice_window(
            step, state=state, led_count=led_count, start=within, stop=span, max_lines=max_lines
        )
        if before is None or after is None:
            return None
        return before, after
    if type(step) is not RollStep:
        return None
    pieces = unroll(step, state, led_count)
    if pieces is None:
        return None
    before: list = []
    after: list = []
    piece_state = list(state)
    spent = 0.0
    for piece in pieces:
        piece_span = float(step_duration_ms(piece))
        end = spent + piece_span
        if end <= within + 0.5:
            before.append(piece)
        elif spent >= within - 0.5:
            after.append(piece)
        else:
            head = slice_window(
                piece,
                state=piece_state,
                led_count=led_count,
                start=0.0,
                stop=within - spent,
                max_lines=max_lines,
            )
            tail = slice_window(
                piece,
                state=piece_state,
                led_count=led_count,
                start=within - spent,
                stop=piece_span,
                max_lines=max_lines,
            )
            if head is None or tail is None:
                return None
            before.extend(head)
            after.extend(tail)
        piece_state = resting_state(piece, piece_state, led_count)
        spent = end
    return before, after


def rotate_program(
    program: str,
    phase_ms: float,
    *,
    led_count: int,
    max_extra_lines: int = MAX_SLICE_EXTRA_LINES,
) -> str | None:
    """The same loop re-anchored ``phase_ms`` in: written now, it plays what
    the original would be playing ``phase_ms`` after its own start.

    ``repeat`` always loops from the first line and no directive can start a
    program early, so the rotated body itself carries the phase. The cut
    line is sliced (``slice_window``); a cut inside a roll unrolls that roll
    first on a narrow device. Leading ``brightness`` and comment lines stay
    in front, where every parse needs them. A one-shot can only start late
    into itself. ``None`` means the text cannot be rotated honestly and the
    caller should fall back; the text comes back unchanged when the phase
    rounds away.
    """
    if not isinstance(program, str) or not program.strip():
        return None
    try:
        phase = float(phase_ms)
    except (TypeError, ValueError):
        return None
    if not math.isfinite(phase):
        return None
    animation, problems = read_program(program, led_count=led_count)
    if animation is None or errors_only(problems):
        return None
    steps = list(animation.steps)
    repeat_at = next((i for i, step in enumerate(steps) if type(step) is RepeatStep), None)
    if repeat_at is not None and steps[repeat_at + 1 :]:
        return None
    body = steps if repeat_at is None else steps[:repeat_at]
    count = None if repeat_at is None else steps[repeat_at].count
    lead_length = 0
    while lead_length < len(body) and type(body[lead_length]) in (BrightnessStep, CommentStep):
        lead_length += 1
    lead, loop = body[:lead_length], body[lead_length:]
    total = sum(step_duration_ms(step) for step in loop)
    if total <= 0:
        return None
    looping = repeat_at is not None
    offset = phase % total if looping else phase
    if offset < 0.5 or (looping and total - offset < 0.5):
        return program
    if not looping and offset >= total:
        return None
    elapsed = 0.0
    index = len(loop)
    within = 0.0
    for position, step in enumerate(loop):
        span = step_duration_ms(step)
        if offset < elapsed + span:
            index, within = position, offset - elapsed
            break
        elapsed += span
    if index >= len(loop):
        return program
    if step_duration_ms(loop[index]) - within < 0.5:
        index, within = index + 1, 0.0
    if within < 0.5:
        rotated_loop = loop[index:] + loop[:index]
        joined = loop[index:]
    else:
        state = _steady_entry_state(loop, led_count, looping=looping)
        for step in loop[:index]:
            if type(step) is PaintStep:
                state = resting_state(step, state, led_count)
        cut = _cut_step(loop[index], state, led_count, within, max_lines=1 + max(0, max_extra_lines))
        if cut is None:
            return None
        before, after = cut
        rotated_loop = after + loop[index + 1 :] + loop[:index] + before
        joined = after + loop[index + 1 :]
    if looping:
        rotated = lead + rotated_loop + [RepeatStep(count=count)]
    else:
        # A one-shot joins mid-program: what the cut skipped never plays,
        # except the brightness and comment lines that still mean something.
        skipped = [s for s in loop[:index] if type(s) in (BrightnessStep, CommentStep)]
        rotated = lead + skipped + joined
    try:
        return render_animation(Animation(animation.name, tuple(rotated)))
    except Exception:
        return None


def snap_rotation(program: str, phase_ms: float, *, led_count: int) -> tuple[str, float] | None:
    """The rotation to the line boundary nearest ``phase_ms``: no line is
    cut, so it costs no bytes. ``(program, phase actually used)``."""
    animation, problems = read_program(program, led_count=led_count)
    if animation is None or errors_only(problems):
        return None
    lap = loop_duration_ms(animation)
    if not lap:
        return None
    wanted = phase_ms % lap
    edges = [0.0]
    for step in animation.steps:
        if type(step) is RepeatStep:
            break
        edges.append(edges[-1] + step_duration_ms(step))
    best = min(edges, key=lambda edge: min(abs(edge - wanted), lap - abs(edge - wanted)))
    rotated = rotate_program(program, best, led_count=led_count)
    return (rotated, best) if rotated is not None else None


# --- retiming ----------------------------------------------------------------


def _scale_line(step: PaintStep, target: int) -> PaintStep | None:
    """One paint line stretched or shrunk so it lasts exactly ``target`` ms,
    every delay and duration scaled by the same factor. A segment with no
    timing at all keeps its one-frame meaning."""
    span = step_duration_ms(step)
    if span <= 0:
        return step
    factor = target / span
    segments = []
    for segment in step.segments:
        timing = segment.timing
        if timing.duration_ms is None and timing.easing is None and timing.delay_ms is None:
            segments.append(segment)
            continue
        duration = max(1, int(round(timing.effective_duration_ms * factor)))
        delay = None if timing.delay_ms is None else int(round(timing.delay_ms * factor)) or None
        if duration > MAX_TIME_MS or (delay or 0) > MAX_TIME_MS:
            return None
        segments.append(replace(segment, timing=replace(timing, duration_ms=duration, delay_ms=delay)))
    scaled = PaintStep(tuple(segments))
    have = step_duration_ms(scaled)
    if have != target:
        timed = [
            i
            for i, segment in enumerate(segments)
            if segment.timing.duration_ms is not None
        ]
        if not timed:
            return scaled
        # The line ends at its longest segment. Longer: stretch that one.
        # Shorter: every segment that would still end past the target has
        # to come in, or a second one tied with the longest keeps the line
        # a millisecond long and the lap misses its half-millisecond.
        if have < target:
            ends = [max(timed, key=lambda i: segments[i].timing.span_ms)]
        else:
            ends = [i for i in timed if segments[i].timing.span_ms > target]
        for index in ends:
            segment = segments[index]
            duration = segment.timing.duration_ms + (target - segment.timing.span_ms)
            if duration < 1 or duration > MAX_TIME_MS:
                return scaled
            segments[index] = replace(segment, timing=replace(segment.timing, duration_ms=duration))
        scaled = PaintStep(tuple(segments))
    return scaled


def retime_program(program: str, rate: float, *, led_count: int) -> str | None:
    """The same program for a clock that runs ``rate`` device-ms per real ms.

    Integer durations are error-diffused: the running total is rounded,
    never each step, so every lap lands within half a millisecond of
    ``rate`` times the original (the prototype took the live idle roll from
    12,250 to 11,924 ms against an ideal of 11,924.1). ``None`` when a time
    would pass the firmware's 65,535 ms ceiling.
    """
    if not isinstance(program, str) or not program.strip():
        return None
    try:
        scale = float(rate)
    except (TypeError, ValueError):
        return None
    if not math.isfinite(scale) or scale <= 0:
        return None
    if abs(scale - 1.0) < 1e-9:
        return program
    animation, problems = read_program(program, led_count=led_count)
    if animation is None or errors_only(problems):
        return None
    ideal = 0.0
    emitted = 0
    out: list = []
    for step in animation.steps:
        span = step_duration_ms(step)
        if type(step) is RollStep:
            ideal += span * scale
            duration = max(1, int(round(ideal)) - emitted)
            if duration > MAX_TIME_MS:
                return None
            emitted += duration
            out.append(replace(step, duration_ms=duration))
            continue
        if type(step) is PaintStep and span > 0:
            ideal += span * scale
            want = max(1, int(round(ideal)) - emitted)
            scaled = _scale_line(step, want)
            if scaled is None:
                return None
            emitted += step_duration_ms(scaled)
            out.append(scaled)
            continue
        out.append(step)
    return render_animation(Animation(animation.name, tuple(out)))


# --- the phase of the strip --------------------------------------------------


def phase_ms(at: float, anchor: float, lap_ms: float, *, trim_ms: float = 0.0) -> float:
    """Where the strip's loop is at monotonic time ``at``: the milliseconds
    since its recorded start (``A_pro``), plus the trim, wrapped to a lap."""
    if lap_ms <= 0:
        return 0.0
    return ((at - anchor) * 1000.0 + float(trim_ms)) % float(lap_ms)


def wrap_ms(value: float, lap_ms: float) -> float:
    """A phase difference folded into ``[-lap/2, lap/2)``."""
    if lap_ms <= 0:
        return float(value)
    half = lap_ms / 2.0
    return ((float(value) + half) % lap_ms) - half


def fits_budget(program: str) -> bool:
    text = program or ""
    return len(text.encode("utf-8")) <= MAX_PROGRAM_BYTES and len(text.splitlines()) <= MAX_PROGRAM_LINES


@dataclass(frozen=True, slots=True)
class DeviceTiming:
    """What a linked Dot's write has to know about time.

    ``anchor`` is the strip's recorded start (``A_pro``, monotonic seconds);
    ``rate`` the Dot's clock in device-ms per real ms; ``trim_ms`` the
    person's constant nudge; ``latency_ms`` the expected gap between the
    rotation being computed and the device parsing the file (``None``: the
    writer's own measured median for this device)."""

    anchor: float
    rate: float = 1.0
    trim_ms: float = 0.0
    latency_ms: float | None = None


@dataclass(frozen=True, slots=True)
class TimedProgram:
    """The Dot's program as written, and how it was timed."""

    program: str
    #: The rotation baked in, in real ms (the strip's phase at ``predicted_at``).
    phase_ms: float
    #: When the rotation assumed the device would parse it (monotonic).
    predicted_at: float
    rate: float
    lap_ms: int | None
    #: ``exact`` / ``snapped`` (rotated at a line boundary) / ``unrotated``.
    rotation: str
    #: The rate the written loop really runs at: its lap in device-ms over
    #: the real lap. Whole milliseconds leave it up to half a millisecond a
    #: lap off ``rate``, and the closed loop has to know that to predict.
    effective_rate: float | None = None


def apply_device_timing(
    program: str,
    timing: DeviceTiming,
    *,
    led_count: int,
    now: float,
    latency_ms: float,
) -> TimedProgram:
    """Rotate, then retime, a program the safety gate has already passed.

    The gate reasons in real milliseconds; judging the Dot's scaled
    milliseconds instead would clamp a 250 ms phase written as 243 back to
    250 and break the lap. So this runs after it, and never compiles.

    The budget decides the ladder: an exact cut, then a cut at the nearest
    line boundary, then no rotation at all (the closed loop re-anchors).
    Never a wrong program.
    """
    animation, problems = read_program(program, led_count=led_count)
    lap = loop_duration_ms(animation) if animation is not None and not errors_only(problems) else None
    total = sum(step_duration_ms(step) for step in animation.steps) if animation is not None else 0
    predicted = now + max(0.0, float(latency_ms)) / 1000.0
    rate = min(MAX_CLOCK_RATE, max(MIN_CLOCK_RATE, float(timing.rate or 1.0)))
    span = lap if lap else total
    wanted = phase_ms(predicted, timing.anchor, span, trim_ms=timing.trim_ms) if span else 0.0
    if not lap:
        # A one-shot joins late or not at all: it cannot be started early.
        # One the strip has already finished is joined at its last
        # millisecond, so the Dot holds the strip's final frame too instead
        # of playing the whole cue after the strip has stopped.
        elapsed = (predicted - timing.anchor) * 1000.0 + float(timing.trim_ms)
        wanted = min(elapsed, total - 1.0) if elapsed > 0.0 and total > 1 else 0.0
    candidates: list[tuple[str, float, str]] = []
    if wanted:
        # The finest cut first, then cheaper ones -- the last spends no
        # line on accuracy, each piece in the one easing that fits it
        # best -- before giving up exactness at all: bytes are the Dot's
        # scarcest resource.
        for extra in (MAX_SLICE_EXTRA_LINES, 2, 0):
            rotated = rotate_program(program, wanted, led_count=led_count, max_extra_lines=extra)
            if rotated is not None:
                candidates.append((rotated, wanted, "exact"))
    else:
        candidates.append((program, 0.0, "exact"))
    if lap:
        snapped = snap_rotation(program, wanted, led_count=led_count)
        if snapped is not None:
            candidates.append((snapped[0], snapped[1], "snapped"))
    candidates.append((program, 0.0, "unrotated"))
    for text, used, how in candidates:
        timed = retime_program(text, rate, led_count=led_count)
        if timed is not None and fits_budget(timed):
            written, _problems = read_program(timed, led_count=led_count)
            written_lap = loop_duration_ms(written) if written is not None else None
            effective = written_lap / lap if lap and written_lap else rate
            return TimedProgram(timed, used, predicted, rate, lap, how, effective)
        if fits_budget(text) and how == "unrotated":
            return TimedProgram(text, 0.0, predicted, 1.0, lap, how, 1.0)
    return TimedProgram(program, 0.0, predicted, 1.0, lap, "unrotated", 1.0)


# --- the closed loop ---------------------------------------------------------


def predicted_error_ms(
    *,
    initial_error_ms: float,
    applied_at: float,
    ticks_at_apply: float,
    ticks_now: float,
    host_now: float,
    rate: float,
    lap_ms: float | None = None,
) -> float:
    """How far the Dot's phase is from where it was meant to be, in real ms.

    ``initial_error_ms`` is the error the write itself left (the predicted
    parse moment against the measured one). From then on the Dot's program
    advances ``(ticks_now - ticks_at_apply) / rate`` real ms of content
    while ``host_now - applied_at`` real seconds pass; the difference is
    the drift the rate did not cancel. Positive: the Dot is ahead."""
    content = (float(ticks_now) - float(ticks_at_apply)) / max(1e-6, float(rate))
    elapsed = (float(host_now) - float(applied_at)) * 1000.0
    error = float(initial_error_ms) + content - elapsed
    return wrap_ms(error, float(lap_ms)) if lap_ms else error


def should_resync(
    error_ms: float | None,
    *,
    tolerance_ms: float,
    now: float,
    last_sync_at: float | None,
    interval_seconds: float = SYNC_INTERVAL_SECONDS,
) -> bool:
    """A Dot-only re-anchor is due: the predicted error is past the
    tolerance and the last sync write was at least ``interval_seconds``
    ago. The strip is never rewritten for sync."""
    if error_ms is None or not math.isfinite(error_ms):
        return False
    if abs(error_ms) <= float(tolerance_ms):
        return False
    return last_sync_at is None or now - last_sync_at >= interval_seconds


def clamp_tolerance(value: object) -> float:
    try:
        number = float(value)  # type: ignore[arg-type]
    except (TypeError, ValueError):
        return DEFAULT_SYNC_TOLERANCE_MS
    if not math.isfinite(number):
        return DEFAULT_SYNC_TOLERANCE_MS
    return min(MAX_SYNC_TOLERANCE_MS, max(MIN_SYNC_TOLERANCE_MS, number))


def clamp_trim(value: object) -> float:
    try:
        number = float(value)  # type: ignore[arg-type]
    except (TypeError, ValueError):
        return 0.0
    if not math.isfinite(number):
        return 0.0
    return min(MAX_PHASE_TRIM_MS, max(-MAX_PHASE_TRIM_MS, number))


# --- the period lock ---------------------------------------------------------

#: The looks a linked Dot may step down through, best first. Each keeps the
#: strip's loop length; the Dot never gets a different period.
PERIOD_LOCK_RUNGS: Final = ("brightest", "average", "soft", "static")


@dataclass(frozen=True, slots=True)
class LockedDot:
    """The Dot's narrowed program and how it was kept on the strip's period."""

    program: str
    rung: str
    lap_ms: int | None
    #: The strip's program as the safety gate compiled it: what the strip
    #: really runs, and what the Dot was derived from.
    pro_compiled: str
    #: The strip phase (ms into its lap) the program's first line plays. A
    #: ``continue`` Dot starts in a dark stretch between passes, so the
    #: write boundary's cut rarely has to split a pass; the write rotates
    #: from here.
    origin_ms: float = 0.0


def _soften(program: str, led_count: int) -> str | None:
    animation, problems = read_program(program, led_count=led_count)
    if animation is None or errors_only(problems):
        return None
    steps = []
    for step in animation.steps:
        if type(step) is PaintStep:
            segments = []
            for segment in step.segments:
                timing = segment.timing
                if (timing.easing or "").lower() == "none":
                    timing = replace(timing, easing="linear")
                segments.append(replace(segment, timing=timing))
            step = PaintStep(tuple(segments))
        steps.append(step)
    return render_animation(Animation(animation.name, tuple(steps)))


def mean_color(program: str, led_count: int) -> str:
    """The colour a loop averages to, weighted by how long each line holds
    what it paints: the Dot's last-resort look, a still light."""
    animation, problems = read_program(program, led_count=led_count)
    if animation is None or errors_only(problems):
        return "#000000"
    state = [_BLACK] * led_count
    total = 0.0
    accumulated = [0.0, 0.0, 0.0]
    for step in animation.steps:
        if type(step) is RepeatStep:
            break
        span = float(step_duration_ms(step))
        if type(step) is PaintStep:
            state = resting_state(step, state, led_count)
        if span <= 0:
            continue
        total += span
        for color in state:
            for channel in range(3):
                accumulated[channel] += color[channel] * span / max(1, led_count)
    if total <= 0:
        return _hex(tuple(sum(c[i] for c in state) / max(1, led_count) for i in range(3)))  # type: ignore[arg-type]
    return _hex(tuple(value / total for value in accumulated))  # type: ignore[arg-type]


def period_locked_dot(
    pro_program: str,
    *,
    source_leds: int,
    led_count: int = 2,
    finalize: Callable[[str], str] | None = None,
) -> LockedDot | None:
    """The strip's running program narrowed for the Dot, on the strip's period.

    The strip's program is compiled ONCE, at the strip's LED count, and the
    Dot is derived from that compiled text -- so a loop the gate stretched
    for the strip is the loop the Dot narrows. The Dot's own gate then
    judges the narrowed text at two LEDs, where a chase folded into two
    bands can read as a blink and be slowed; if its lap would change, the
    Dot steps down: band average, then ``none`` softened to ``linear``,
    then the loop's mean colour held still. The period never changes.

    ``finalize`` turns a candidate into the exact text the Dot's write
    boundary will judge (its brightness line and its own transfer), so the
    check here is the check there. ``None`` when nothing can be narrowed.
    """
    from .dot_role import downsample_program
    from .presentation_compiler import compile_presentation_program

    compiled = compile_presentation_program(pro_program, led_count=source_leds)
    if not compiled.accepted:
        return None
    parsed, problems = read_program(compiled.program, led_count=source_leds)
    if parsed is None or errors_only(problems):
        return None
    pro_lap = loop_duration_ms(parsed)
    brightest = downsample_program(compiled.program, source_leds=source_leds, led_count=led_count)
    if brightest is None:
        return None
    for rung in PERIOD_LOCK_RUNGS:
        if rung == "brightest":
            candidate = brightest
        elif rung == "average":
            candidate = downsample_program(
                compiled.program, source_leds=source_leds, led_count=led_count, band="average"
            )
        elif rung == "soft":
            averaged = downsample_program(
                compiled.program, source_leds=source_leds, led_count=led_count, band="average"
            )
            candidate = _soften(averaged, led_count) if averaged else None
        else:
            candidate = mean_color(compiled.program, source_leds)
        if candidate is None:
            continue
        if rung == "static":
            return LockedDot(candidate, rung, None, compiled.program)
        text = finalize(candidate) if finalize is not None else candidate
        check = compile_presentation_program(text, led_count=led_count)
        if not check.accepted:
            continue
        judged, judged_problems = read_program(check.program, led_count=led_count)
        if judged is None or errors_only(judged_problems):
            continue
        if loop_duration_ms(judged) == pro_lap:
            return LockedDot(candidate, rung, pro_lap, compiled.program)
    return LockedDot(mean_color(compiled.program, source_leds), "static", None, compiled.program)


__all__ = [
    "DEFAULT_SYNC_TOLERANCE_MS",
    "MAX_PHASE_TRIM_MS",
    "PERIOD_LOCK_RUNGS",
    "SYNC_INTERVAL_SECONDS",
    "WARM_START_DOT_RATE",
    "DeviceTiming",
    "LockedDot",
    "TimedProgram",
    "apply_device_timing",
    "clamp_tolerance",
    "clamp_trim",
    "curve_weight",
    "fits_budget",
    "mean_color",
    "period_locked_dot",
    "phase_ms",
    "predicted_error_ms",
    "retime_program",
    "rotate_program",
    "should_resync",
    "slice_window",
    "snap_rotation",
    "unroll",
    "wrap_ms",
]


# ``normalize_color`` and ``ColorList`` are re-exported names other modules
# reach through here; keep the linter from calling them unused.
_ = (normalize_color, ColorList, CommentStep)
