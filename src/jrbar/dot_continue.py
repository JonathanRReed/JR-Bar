"""The Dot as more strip: light that runs off the end of the Pro into it.

``continue`` (the default extend look) treats the Dot as LEDs 8 and 9 of a
longer strip: a comet that leaves LED 7 reaches the Dot's first LED one
travel step later and its second LED a step after that, as if the strip
went on. ``mirror`` folds the strip's eight LEDs into the Dot's two instead,
and it is what a Dot shows when nothing travels -- a breathe, a solid
colour, LEDs that do not follow each other -- because this module returns
``None`` then and the caller mirrors.

How it works: the strip's compiled loop is sampled per LED every few
milliseconds (the curves the firmware plays, ``linked_sync.line_curves``,
and rolls as the sliding crossfades they are); the travel time between
neighbouring LEDs is found by matching each LED against the next one
shifted in time, then refined to the fine samples; and the Dot's two LEDs
are what the strip's end LED showed one and two steps of travel ago (or
will show, when the light runs the other way).

The firmware gives a program 20 lines and 512 bytes, and one line moves
each LED once. A comet makes six passes a lap, so the Dot gets one line per
pass: each LED a ``pulse`` to the head's colour, centred on the moment the
head reaches it and as wide as best fits the strip's own rise and fall,
plus one settle line in the longest stretch between passes that puts both
LEDs back on their resting colour once a lap. The program starts in that
stretch (``LockedDot.origin_ms``), so the write boundary's cut to the
strip's phase rarely has to split a pass, and every spelling is checked to
fit the budget wherever it is cut. (Sixteen colour-list keyframes, the
first spelling, could not hold six passes: four reached the Dot and the
rest smeared into second-long fades.)

The spelling is judged against the true continuation before it is used:
every pass must land on its LED on time, and the worst and the average
channel error must stay within a share of the light's own range. A pulse
is symmetric, so a comet's one-sided tail is the error it pays; a pass
that goes missing or lights early is off by the whole head. A spelling
that fails, or light that does not travel, returns ``None`` and the Dot
mirrors. The work is cached per compiled program: the planner asks on
every Dot write.
"""

from __future__ import annotations

import math
from collections.abc import Callable
from dataclasses import dataclass
from functools import lru_cache
from typing import Final

from .animation import (
    Animation,
    BrightnessStep,
    ColorList,
    IndexedPaint,
    PaintStep,
    RepeatStep,
    RollStep,
    Timing,
    WholeBar,
    errors_only,
    loop_duration_ms,
    read_program,
    render_animation,
    step_duration_ms,
)
from .linked_sync import (
    MAX_PROGRAM_BYTES,
    MAX_PROGRAM_LINES,
    RGB,
    LockedDot,
    _bar,
    _compact,
    curve_weight,
    line_curves,
    resting_state,
)

#: About how finely the strip is sampled, in milliseconds.
_SAMPLE_MS: Final = 5.0
#: The fewest and most samples a lap is cut into.
_MIN_TIMELINE_SAMPLES: Final = 256
_MAX_TIMELINE_SAMPLES: Final = 2048
#: Two neighbouring LEDs whose shifted timelines differ by more than this
#: (mean brightness, in codes) are not one travelling light.
_TRAVEL_MATCH_CODES: Final = 12.0
#: The most samples a lap is matched over when looking for the travel.
_MAX_SAMPLES: Final = 160
#: A pass is a bump at least this bright over its surroundings (in luma),
#: and at least this share of the brightest bump in the lap.
_MIN_PROMINENCE: Final = 4.0
_PROMINENCE_SHARE: Final = 0.25
#: The shortest half-pulse a pass may be spelled with, and the dark gap
#: kept free between passes for the settle line.
_MIN_HALF_PULSE_MS: Final = 20.0
_SETTLE_GAP_MS: Final = 20.0
#: How far a spelling may stray from the true continuation before the Dot
#: mirrors instead, as shares of the light's own range (the widest channel
#: swing the strip's end LED makes in a lap): the worst moment, and the
#: average of every LED's worst channel across the lap. A symmetric pulse
#: standing in for a comet costs about 0.3 and 0.08 (its dim one-sided
#: tail); a chase, whose tail is longer, about 0.36 and 0.11. A pass that
#: goes missing or lights early is off by the whole range.
MAX_CONTINUE_WORST_SHARE: Final = 0.40
MAX_CONTINUE_MEAN_SHARE: Final = 0.12
#: Every pass must reach at least this share of its true brightness at the
#: moment the head arrives.
_LANDING_SHARE: Final = 0.75
#: Where the write boundary may cut a spelling to start it on the strip's
#: phase (``linked_sync.rotate_program``), every line is tried at this many
#: evenly spaced points; a cut through a pass costs up to three extra lines.
#: Retiming for a slow Dot only ever shortens a duration's digits, so the
#: cut text is what has to fit.
_CUTS_PER_LINE: Final = 4


# --- sampling the strip ------------------------------------------------------


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

    def sweep(self, count: int) -> list[list[RGB]]:
        """``at`` for ``count`` evenly spaced moments across one lap, in one
        pass through the loop instead of one per moment."""
        frames: list[list[RGB]] = []
        state = list(self.entry)
        elapsed = 0.0
        index = 0
        for step in self.steps:
            span = float(step_duration_ms(step))
            end = elapsed + span
            if type(step) is PaintStep:
                curves = None
                while index < count and self.lap_ms * index / count < end:
                    if curves is None:
                        curves = line_curves(step, state, self.led_count)
                    local = self.lap_ms * index / count - elapsed
                    out = list(state)
                    for led, led_curves in curves.items():
                        color = tuple(float(v) for v in state[led])
                        for curve in led_curves:
                            if curve.begin < local or (curve.easing == "none" and curve.begin <= local):
                                color = curve.at(local)
                        out[led] = tuple(int(round(v)) for v in color)  # type: ignore[assignment]
                    frames.append(out)
                    index += 1
                state = resting_state(step, state, self.led_count)
            elif type(step) is RollStep and span > 0:
                while index < count and self.lap_ms * index / count < end:
                    frames.append(_rolled(state, step, (self.lap_ms * index / count - elapsed) / span))
                    index += 1
            elapsed = end
        frames.extend(list(state) for _ in range(count - index))
        return frames


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


@dataclass(frozen=True, slots=True)
class _Timeline:
    """One lap of the strip sampled at ``len(frames)`` evenly spaced moments."""

    lap_ms: float
    frames: tuple[tuple[RGB, ...], ...]

    @property
    def spacing(self) -> float:
        return self.lap_ms / len(self.frames)

    def at(self, time_ms: float, led: int) -> tuple[float, float, float]:
        """One LED's colour at any moment, between samples by straight line."""
        count = len(self.frames)
        position = (time_ms % self.lap_ms) / self.spacing
        index = int(position)
        part = position - index
        near = self.frames[index % count][led]
        far = self.frames[(index + 1) % count][led]
        return tuple(a + (b - a) * part for a, b in zip(near, far))  # type: ignore[return-value]


@lru_cache(maxsize=32)
def _timeline(program: str, led_count: int) -> _Timeline | None:
    sampler = _sampler(program, led_count)
    if sampler is None:
        return None
    coarse = max(16, min(_MAX_SAMPLES, int(sampler.lap_ms / (2 * _SAMPLE_MS))))
    per = max(1, int(round(sampler.lap_ms / _SAMPLE_MS / coarse)))
    count = coarse * per
    while count > _MAX_TIMELINE_SAMPLES and per > 1:
        per -= 1
        count = coarse * per
    while count < _MIN_TIMELINE_SAMPLES:
        per += 1
        count = coarse * per
    frames = tuple(tuple(frame) for frame in sampler.sweep(count))
    return _Timeline(sampler.lap_ms, frames)


def _coarse_step(timeline: _Timeline) -> int:
    """How many fine samples one coarse matching sample spans."""
    count = len(timeline.frames)
    coarse = max(16, min(_MAX_SAMPLES, int(timeline.lap_ms / (2 * _SAMPLE_MS))))
    return max(1, count // coarse)


def _luma(color) -> float:
    red, green, blue = color
    return 0.2126 * red + 0.7152 * green + 0.0722 * blue


@lru_cache(maxsize=64)
def travel_ms(program: str, led_count: int) -> float | None:
    """How long light takes to move one LED, signed: positive when it runs
    toward the last LED, negative toward the first. ``None`` when the LEDs
    do not follow one another (a breathe, a blink, a solid colour).

    Matched on brightness over at most 160 samples a lap, then refined on
    the fine samples within one coarse step either side -- a comet's step
    of 165 ms used to come out as 155, and every pass reached the Dot that
    much early. Cached: the answer only changes with the program."""
    timeline = _timeline(program, led_count)
    if timeline is None or led_count < 3:
        return None
    fine = [[_luma(frame[led]) for frame in timeline.frames] for led in range(led_count)]
    if all(max(values) - min(values) < 2.0 for values in fine):
        return None  # nothing moves at all
    if all(max(abs(a - b) for a, b in zip(fine[0], values)) < 2.0 for values in fine[1:]):
        return None  # every LED the same: nothing travels
    per = _coarse_step(timeline)
    series = [values[::per] for values in fine]
    count = len(series[0])

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
    total = len(fine[0])
    stride = max(1, total // 256)
    moments = range(0, total, stride)

    def fine_mismatch(shift: int) -> float:
        return max(
            sum(abs(fine[led][(index - shift) % total] - fine[led + 1][index]) for index in moments)
            for led in range(led_count - 1)
        )

    centre = best[1] * per
    refined = min(range(centre - per, centre + per + 1), key=fine_mismatch)
    step_ms = timeline.lap_ms * refined / total
    if step_ms > timeline.lap_ms / 2.0:
        step_ms -= timeline.lap_ms
    return step_ms if abs(step_ms) >= 1.0 else None


# --- the spellings -----------------------------------------------------------


@dataclass(frozen=True, slots=True)
class _Spelling:
    """One way to write the Dot's continuation, and how true it is."""

    program: str
    #: The strip phase the program's first line plays (ms into the lap).
    origin_ms: float
    #: Channel error against the true continuation, in codes.
    worst: float
    mean: float
    #: The widest channel swing of the light being continued, in codes.
    span: float
    #: Every pass reached its LED on time.
    landed: bool

    @property
    def acceptable(self) -> bool:
        return (
            self.landed
            and self.span > 0
            and self.worst <= MAX_CONTINUE_WORST_SHARE * self.span
            and self.mean <= MAX_CONTINUE_MEAN_SHARE * self.span
        )


def _hex(color) -> str:
    return "#" + "".join(f"{max(0, min(255, int(round(value)))):02X}" for value in color)


def _peaks(values: list[float]) -> list[float]:
    """Where a looping series has its bumps, as fractional sample indexes:
    local maxima (a flat top counts once, at its middle) standing at least
    ``_MIN_PROMINENCE`` and ``_PROMINENCE_SHARE`` of the tallest bump above
    the higher of the two valleys either side."""
    count = len(values)
    if count < 3:
        return []
    found: list[tuple[float, float]] = []
    index = 0
    while index < count:
        value = values[index]
        if not value > values[index - 1]:
            index += 1
            continue
        end = index
        while end - index < count and values[(end + 1) % count] == value:
            end += 1
        if values[(end + 1) % count] > value:
            index = end + 1
            continue
        left = right = value
        for back in range(1, count):
            sample = values[(index - back) % count]
            if sample > value:
                break
            left = min(left, sample)
        for ahead in range(1, count):
            sample = values[(end + ahead) % count]
            if sample > value:
                break
            right = min(right, sample)
        found.append((((index + end) / 2.0) % count, value - max(left, right)))
        index = end + 1
    if not found:
        return []
    tallest = max(prominence for _at, prominence in found)
    need = max(_MIN_PROMINENCE, _PROMINENCE_SHARE * tallest)
    return sorted(at for at, prominence in found if prominence >= need)


def _resting(
    timeline: _Timeline, led: int, lumas: list[float], peaks: list[float]
) -> tuple[float, float, float]:
    """The colour an LED rests on between passes: the median of the
    darkest moment between each pass and the next. Not the darkest moment
    of the lap -- a glint rests on a dim teal, and the strip's own fade
    between laps would have put the Dot's rest at black."""
    count = len(lumas)
    valleys: list[tuple[float, int]] = []
    marks = [int(round(at)) % count for at in peaks]
    for index, mark in enumerate(marks):
        following = marks[(index + 1) % len(marks)]
        length = (following - mark) % count or count
        lowest = min(range(1, length), key=lambda step: lumas[(mark + step) % count], default=0)
        spot = (mark + lowest) % count
        valleys.append((lumas[spot], spot))
    valleys.sort()
    _luma_at, spot = valleys[len(valleys) // 2]
    return tuple(float(v) for v in timeline.frames[spot][led])  # type: ignore[return-value]


def _pulse_weight(offset_ms: float, half_ms: float) -> float:
    if abs(offset_ms) >= half_ms:
        return 0.0
    return (1.0 + math.cos(math.pi * offset_ms / half_ms)) / 2.0


def _fit_half(
    timeline: _Timeline,
    led: int,
    *,
    peak_ms: float,
    peak: tuple[float, float, float],
    floor: tuple[float, float, float],
    before_ms: float,
    after_ms: float,
    low: float,
    high: float,
) -> float:
    """The half-width of the pulse that best stands in for one bump of the
    strip's end LED: the smallest worst-channel error over the bump."""
    spacing = timeline.spacing
    stride = max(1, int(round(10.0 / spacing)))
    offsets = [
        index * spacing * stride
        for index in range(-int(before_ms / (spacing * stride)), int(after_ms / (spacing * stride)) + 1)
    ]
    truth = [timeline.at(peak_ms + offset, led) for offset in offsets]
    rise = [p - f for p, f in zip(peak, floor)]

    def error(half: float) -> float:
        worst = 0.0
        for offset, actual in zip(offsets, truth):
            weight = _pulse_weight(offset, half)
            for channel in range(3):
                gap = abs(floor[channel] + rise[channel] * weight - actual[channel])
                if gap > worst:
                    worst = gap
        return worst

    candidates = [low + (high - low) * index / 12.0 for index in range(13)]
    best = min(candidates, key=error)
    step = (high - low) / 12.0
    refined = [best + step * index / 4.0 for index in range(-4, 5) if low <= best + step * index / 4.0 <= high]
    return min(refined or [best], key=error)


def _pass_program(
    timeline: _Timeline,
    *,
    end_led: int,
    lags: list[float],
    order: list[int],
    lead: list,
) -> tuple[str, float] | None:
    """The one-line-per-pass spelling, and the strip phase it starts at.

    ``lags[j]`` is how far behind the strip's end LED the Dot's LED ``j``
    runs (negative: ahead); ``order`` maps those to the Dot's own LED
    indexes. ``None`` when the passes sit too close for a line each."""
    lap = timeline.lap_ms
    lumas = [_luma(frame[end_led]) for frame in timeline.frames]
    peaks = _peaks(lumas)
    if not peaks:
        return None
    spacing = timeline.spacing
    floor = _resting(timeline, end_led, lumas, peaks)
    spread = max(lags) - min(lags)
    times = [at * spacing for at in peaks]
    passes: list[tuple[float, float, tuple[float, float, float]]] = []
    for position, peak_ms in enumerate(times):
        previous = times[position - 1] - (lap if position == 0 else 0.0)
        following = times[(position + 1) % len(times)] + (lap if position == len(times) - 1 else 0.0)
        if len(times) == 1:
            previous, following = peak_ms - lap, peak_ms + lap
        room = min(peak_ms - previous, following - peak_ms) - spread - _SETTLE_GAP_MS
        high = room / 2.0
        low = max(_MIN_HALF_PULSE_MS, 2.0 * spacing)
        if high < low:
            return None
        color = timeline.at(peak_ms, end_led)
        half = _fit_half(
            timeline,
            end_led,
            peak_ms=peak_ms,
            peak=color,
            floor=floor,
            before_ms=(peak_ms - previous) / 2.0,
            after_ms=(following - peak_ms) / 2.0,
            low=low,
            high=high,
        )
        start = (peak_ms + min(lags) - half) % lap
        passes.append((start, half, color))
    passes.sort(key=lambda item: item[0])
    width = [spread + 2.0 * half for _start, half, _color in passes]
    gaps = [
        (passes[(index + 1) % len(passes)][0] - (passes[index][0] + width[index])) % lap
        for index in range(len(passes))
    ]
    last = max(range(len(passes)), key=gaps.__getitem__)
    origin = (passes[last][0] + width[last]) % lap
    ordered = passes[last + 1 :] + passes[: last + 1]
    lap_int = int(round(lap))
    floors = [floor] * len(lags)
    steps: list = list(lead)
    first_start = int(round((ordered[0][0] - origin) % lap))
    if first_start >= 1:
        colors = tuple(_hex(floors[j]) for j in order)
        settle = Timing(duration_ms=first_start)
        segment = WholeBar(_bar(colors[0]), settle) if len(set(colors)) == 1 else ColorList(colors, settle)
        steps.append(PaintStep((segment,)))
    line_start = first_start
    for position, (start, half, color) in enumerate(ordered):
        relative = (start - origin) % lap
        ends = [relative + (lag - min(lags)) + 2.0 * half for lag in lags]
        line_end = lap_int if position == len(ordered) - 1 else int(round(max(ends)))
        segments = []
        for dot_led, source in enumerate(order):
            begin = int(round(relative + lags[source] - min(lags)))
            duration = max(1, int(round(2.0 * half)))
            if ends[source] >= max(ends) - 1e-6:
                duration = max(1, line_end - begin)
            delay = max(0, begin - line_start)
            segments.append(
                IndexedPaint(
                    ((dot_led, _hex(color)),),
                    Timing(duration_ms=duration, easing="pulse", delay_ms=delay or None),
                )
            )
        steps.append(_compact(PaintStep(tuple(segments)), len(lags)))
        line_start = line_end
    steps.append(RepeatStep())
    program = render_animation(Animation("continue", tuple(steps)))
    animation, problems = read_program(program, led_count=len(lags))
    if animation is None or errors_only(problems) or loop_duration_ms(animation) != lap_int:
        return None
    return program, origin


def _judge(
    program: str,
    origin_ms: float,
    truth: Callable[[float], list[tuple[float, float, float]]],
    *,
    lap_ms: float,
    arrivals: list[list[float]],
    led_count: int,
    span: float,
) -> _Spelling | None:
    """How closely ``program`` (starting at strip phase ``origin_ms``) plays
    the true continuation, sampled every 10 ms of a lap on the firmware's
    own curves, and whether every pass reaches its LED on time."""
    model = _sampler(program, led_count)
    if model is None:
        return None
    worst = 0.0
    total = 0.0
    count = max(64, int(lap_ms / 10.0))
    for index, played in enumerate(model.sweep(count)):
        moment = lap_ms * index / count
        expected = truth(origin_ms + moment)
        for led in range(led_count):
            gap = max(abs(a - b) for a, b in zip(played[led], expected[led]))
            worst = max(worst, gap)
            total += gap
    landed = True
    for led, moments in enumerate(arrivals):
        for arrival in moments:
            want = _luma(truth(arrival)[led])
            got = _luma(model.at(arrival - origin_ms)[led])
            if got < _LANDING_SHARE * want:
                landed = False
    return _Spelling(program, origin_ms, worst, total / (count * led_count), span, landed)


@lru_cache(maxsize=64)
def _cuts_fit(program: str, led_count: int) -> bool:
    """Whether the write boundary can start this program anywhere in its
    lap and still fit the firmware's budget, with the brightest brightness
    line the Dot's own policy could put in front. A spelling that only fits
    uncut would be written snapped to a line boundary -- half a pass off
    the strip -- whenever the phase lands inside a pass."""
    from .linked_sync import rotate_program

    lines = [line for line in program.splitlines() if not line.startswith("brightness")]
    text = "\n".join(["brightness 255", *lines])
    animation, problems = read_program(text, led_count=led_count)
    if animation is None or errors_only(problems):
        return False
    edges = [0.0]
    spans: list[tuple[float, float]] = []
    seen: set[str] = set()
    for step in animation.steps:
        if type(step) is RepeatStep:
            break
        edges.append(edges[-1] + step_duration_ms(step))
        line = render_animation(Animation("", (step,)))
        if type(step) in (PaintStep, RollStep) and line not in seen:
            # A pass line like one already tried costs the same to cut.
            seen.add(line)
            spans.append((edges[-2], edges[-1]))
    for left, right in spans:
        for index in range(1, _CUTS_PER_LINE + 1):
            phase = left + (right - left) * index / (_CUTS_PER_LINE + 1)
            rotated = rotate_program(text, phase, led_count=led_count, max_extra_lines=0)
            if rotated is None:
                return False
            if len(rotated.encode("utf-8")) > MAX_PROGRAM_BYTES:
                return False
            if len(rotated.splitlines()) > MAX_PROGRAM_LINES:
                return False
    return True


@lru_cache(maxsize=64)
def _continuation(
    compiled: str,
    source_leds: int,
    led_count: int,
    side: str,
    dot_direction: str,
) -> _Spelling | None:
    """The Dot's continuation of this compiled strip program, before the
    Dot's own brightness and transfer, or ``None`` when it cannot be
    spelled truly enough. Cached: it depends only on its arguments."""
    step = travel_ms(compiled, source_leds)
    timeline = _timeline(compiled, source_leds)
    if step is None or timeline is None:
        return None
    end_led = source_leds - 1 if side != "before_first" else 0
    # Light moving toward the Dot's end arrives later at each Dot LED; light
    # moving away passed it earlier. ``outward`` is +1 when it moves toward.
    outward = 1.0 if (step > 0) == (side != "before_first") else -1.0
    lags = [outward * (index + 1) * abs(step) for index in range(led_count)]
    order = list(range(led_count))[::-1] if dot_direction == "reversed" else list(range(led_count))

    def truth(time_ms: float) -> list[tuple[float, float, float]]:
        return [timeline.at(time_ms - lags[source], end_led) for source in order]

    lead = [
        BrightnessStep(level=s.level)
        for s in read_program(compiled, led_count=source_leds)[0].steps
        if type(s) is BrightnessStep
    ][:1]
    lumas = [_luma(frame[end_led]) for frame in timeline.frames]
    peak_times = [at * timeline.spacing for at in _peaks(lumas)]
    arrivals = [[peak + lags[source] for peak in peak_times] for source in order]
    span = max(
        max(frame[end_led][channel] for frame in timeline.frames)
        - min(frame[end_led][channel] for frame in timeline.frames)
        for channel in range(3)
    )
    passes = _pass_program(timeline, end_led=end_led, lags=lags, order=order, lead=lead)
    if passes is None:
        return None
    program, origin = passes
    spelling = _judge(
        program,
        origin,
        truth,
        lap_ms=timeline.lap_ms,
        arrivals=arrivals,
        led_count=led_count,
        span=float(span),
    )
    if spelling is None or not spelling.acceptable or not _cuts_fit(program, led_count):
        return None
    return spelling


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
    ``None`` to mirror instead: nothing travels, no spelling is true enough
    to the strip, or the Dot's own safety gate would change the loop."""
    from .presentation_compiler import compile_presentation_program

    compiled = compile_presentation_program(strip_program, led_count=source_leds)
    if not compiled.accepted:
        return None
    spelling = _continuation(
        compiled.program,
        int(source_leds),
        int(led_count),
        str(side),
        str(dot_direction),
    )
    if spelling is None:
        return None
    lap = int(round(_timeline(compiled.program, source_leds).lap_ms))  # type: ignore[union-attr]
    text = finalize(spelling.program) if finalize is not None else spelling.program
    check = compile_presentation_program(text, led_count=led_count)
    judged, problems = read_program(check.program, led_count=led_count)
    if not check.accepted or judged is None or errors_only(problems):
        return None
    if loop_duration_ms(judged) != lap:
        return None
    return LockedDot(spelling.program, "continue", lap, compiled.program, spelling.origin_ms)


def continuation_quality(
    strip_program: str,
    *,
    source_leds: int,
    led_count: int = 2,
    side: str = "after_last",
    dot_direction: str = "forward",
) -> tuple[float, float, float] | None:
    """``(worst, mean, span)`` in codes for the spelling ``continue_program``
    would use -- its error against the true continuation and the light's own
    range -- for the review harness and the tests. ``None``: it mirrors."""
    from .presentation_compiler import compile_presentation_program

    compiled = compile_presentation_program(strip_program, led_count=source_leds)
    if not compiled.accepted:
        return None
    spelling = _continuation(compiled.program, int(source_leds), int(led_count), str(side), str(dot_direction))
    return None if spelling is None else (spelling.worst, spelling.mean, spelling.span)


__all__ = [
    "MAX_CONTINUE_MEAN_SHARE",
    "MAX_CONTINUE_WORST_SHARE",
    "continuation_quality",
    "continue_program",
    "travel_ms",
]
