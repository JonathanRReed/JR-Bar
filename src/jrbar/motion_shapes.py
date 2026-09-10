"""The geometry of every JR-Bar animation, measured against the firmware.

Every shape here was designed by sampling ``jrbar/resources/sdled.wasm`` at
60 Hz (``scripts/review_effects.py``) and looking at the result, not by
reading the DSL and hoping. The rules that shaped them:

* ``pulse D`` is a raised-cosine bump over ``D`` that starts *and ends* at the
  line's start colour. ``cosine D`` is a half-cosine ramp that holds its
  target for the rest of the line. Those two are the only envelopes the
  firmware offers, so every "head with a tail" is built from them.
* A line lasts the longest ``delay + duration`` on it. A per-LED bump
  therefore cannot outlive its own line: a sweep that has to hand over to the
  next line must finish its far LED on a *rise*, not a bump, or the strip goes
  dark before the turn.
* **Only one segment per LED survives on a line.** The firmware keeps the last
  assignment for an LED and drops every earlier one outright (measured: a line
  reading ``0:#FFF 100ms cosine; 0:#000 300ms cosine 100ms`` never lights
  LED 0). Two beats for one LED need two lines.
* ``roll`` interpolates continuously between the shifted states rather than
  stepping, so a painted head-and-tail profile followed by ``roll-right D
  linear`` is the one travelling shape with no seam anywhere -- which is why
  every circulating motion here is built that way instead of out of staggered
  pulses that all have to die before the line can end.
* Untimed lines last 17 ms, so a re-paint that costs one lap of a roll is
  cheap; several ``roll`` lines after one profile line amortise even that.

Nothing in this module touches a device, a setting, or AppKit. Callers add
their own ``repeat`` and brightness.
"""

from __future__ import annotations

import math

from .animation import format_time

#: Firmware program limits, repeated here so a shape can check its own size.
MAX_PROGRAM_BYTES = 512
MAX_PROGRAM_LINES = 20
#: Below this many LEDs a positional shape has nowhere to travel, so it
#: becomes a crossfade instead of a two-LED strobe.
MIN_POSITIONAL_LEDS = 4
#: The step a travelling head takes between neighbours. Faster than the floor
#: reads as a flicker; slower than the ceiling reads as eight separate lamps.
MIN_STEP_MS = 60
MAX_STEP_MS = 320
#: Ceiling for the lead-in that paints a roll profile. By default the
#: lead-in lasts exactly one roll step, so the wave arrives at its own
#: travelling speed instead of appearing all at once -- and on every lap
#: after the first the repaint has nothing to change, because a full roll
#: leaves the profile exactly where it started.
PROFILE_LEAD_MS = 320

#: Head-and-tail profiles, brightest first. Each is a fraction of the peak
#: colour; the roll carries them around the strip.
CHASE_TAIL: tuple[float, ...] = (1.0, 0.52, 0.24, 0.10, 0.03, 0.0, 0.0, 0.0)
COMET_TAIL: tuple[float, ...] = (1.0, 0.38, 0.14, 0.05, 0.01, 0.0, 0.0, 0.0)
MARQUEE_TAIL: tuple[float, ...] = (1.0, 0.45, 0.14, 0.03, 1.0, 0.45, 0.14, 0.03)
#: Tide never goes dark: a broad swell moving through a lit strip.
TIDE_TAIL: tuple[float, ...] = (1.0, 0.86, 0.60, 0.36, 0.22, 0.24, 0.44, 0.72)
#: Two LEDs cannot carry a tail, so they carry a crossfade.
DOT_TAIL: tuple[float, ...] = (1.0, 0.16)


def _time(milliseconds: int) -> str:
    """A duration or delay, spelled the way the safety compiler will spell it.

    Every program is re-rendered by ``presentation_compiler`` before it
    reaches a device, so writing "2000ms" here would ship as "2s" anyway --
    and the device-write dedupe compares the rendered bytes. Emitting the
    canonical spelling up front keeps "what the shape says" and "what the
    strip gets" the same string.
    """
    return format_time(max(0, int(milliseconds)))


def _channels(color: str) -> tuple[int, int, int]:
    cleaned = str(color).strip().lstrip("#")
    if len(cleaned) != 6:
        return (0, 0, 0)
    try:
        return tuple(int(cleaned[index : index + 2], 16) for index in (0, 2, 4))  # type: ignore[return-value]
    except ValueError:
        return (0, 0, 0)


def shade(color: str, fraction: float) -> str:
    """``color`` scaled toward black, as the firmware's own 8-bit codes."""
    red, green, blue = _channels(color)
    scale = max(0.0, min(1.0, float(fraction)))
    return "#" + "".join(
        f"{max(0, min(255, round(channel * scale))):02X}"
        for channel in (red, green, blue)
    )


def mix(color: str, other: str, fraction: float) -> str:
    """``fraction`` of the way from ``color`` to ``other``."""
    weight = max(0.0, min(1.0, float(fraction)))
    return "#" + "".join(
        f"{max(0, min(255, round(left + (right - left) * weight))):02X}"
        for left, right in zip(_channels(color), _channels(other))
    )


def step_ms_for(cycle_ms: int, led_count: int) -> int:
    """How long a travelling head spends between two neighbours."""
    span = max(1, int(led_count))
    return max(MIN_STEP_MS, min(MAX_STEP_MS, max(1, int(cycle_ms)) // span))


def positional(led_count: int) -> bool:
    """Whether this strip is long enough for a shape to travel along it."""
    return int(led_count) >= MIN_POSITIONAL_LEDS


def _profile_line(
    color: str,
    tail: tuple[float, ...],
    *,
    led_count: int,
    lead_ms: int,
    floor: float = 0.0,
) -> str:
    fractions = _fitted_tail(tail, led_count)
    rest = max(0.0, min(1.0, float(floor)))
    colors = " ".join(
        shade(color, max(rest, fraction)) for fraction in fractions
    )
    return f"{colors} {_time(lead_ms)} cosine"


def _fitted_tail(tail: tuple[float, ...], led_count: int) -> tuple[float, ...]:
    """``tail`` resampled onto ``led_count`` LEDs, brightest LED first.

    A profile is a shape, not a list of LEDs: resampling keeps the head bright
    and the tail proportional whether the strip has eight LEDs or four.
    """
    count = max(1, int(led_count))
    if count == len(tail):
        return tail
    if count <= 2:
        return DOT_TAIL[:count]
    return tuple(
        tail[min(len(tail) - 1, round(index * (len(tail) - 1) / (count - 1)))]
        for index in range(count)
    )


def travelling_wave(
    color: str,
    *,
    led_count: int,
    lap_ms: int,
    tail: tuple[float, ...] = CHASE_TAIL,
    laps: int = 1,
    reverse: bool = False,
    lead_ms: int | None = None,
    floor: float = 0.0,
) -> list[str]:
    """A head-and-tail profile circulating the strip with no seam.

    ``roll`` crossfades between the shifted states, so the crest moves
    continuously rather than hopping LED to LED; repeating the roll line
    several times pays the profile repaint once per ``laps`` laps instead of
    once per lap, which is the difference between a wave and a wave that
    hesitates every time round.
    """
    direction = "roll-left" if reverse else "roll-right"
    duration = max(MIN_STEP_MS * max(1, int(led_count)), int(lap_ms))
    lead = (
        step_ms_for(duration, led_count) if lead_ms is None else int(lead_ms)
    )
    return [
        _profile_line(
            color, tail, led_count=led_count, lead_ms=lead, floor=floor
        ),
        *([f"{direction} {_time(duration)} linear"] * max(1, int(laps))),
    ]


def gradient_wave(
    color: str,
    *,
    led_count: int,
    lap_ms: int,
    span_degrees: float = 48.0,
    laps: int = 1,
    lead_ms: int | None = None,
) -> list[str]:
    """A full hue ramp travelling the strip: colour moves, brightness does not.

    The one motion with no dark LED at any instant, so it never reads as a
    flash however fast it is set to run.
    """
    from .presentation_policy import _hue_shifted_color

    count = max(1, int(led_count))
    colors = " ".join(
        _hue_shifted_color(
            color, (index / max(1, count - 1) - 0.5) * float(span_degrees)
        )
        for index in range(count)
    )
    duration = max(MIN_STEP_MS * count, int(lap_ms))
    lead = step_ms_for(duration, count) if lead_ms is None else int(lead_ms)
    return [
        f"{colors} {_time(lead)} cosine",
        *([f"roll-right {_time(duration)} linear"] * max(1, int(laps))),
    ]


def bounce(
    color: str,
    floor_color: str,
    *,
    led_count: int,
    step_ms: int,
    tail_leds: float = 2.0,
) -> list[str]:
    """One bright head with a decaying tail, sweeping out and back forever.

    Two lines, one per direction. Each LED gets a raised-cosine bump centred
    on the moment the head passes it and ``tail_leds`` LEDs wide, so at any
    instant three LEDs are lit at roughly 50/100/50 and the crest slides
    between them rather than hopping.

    The ends are where a naive sweep breaks: a line cannot end until its
    longest bump does, so a strip built only of bumps must go dark before it
    can turn around. Here the LED the head is *arriving* at rises with a
    ``cosine`` that finishes exactly when the line does, and the LED it is
    *leaving* opens the next line already at the crest and falls from it. The
    turn is therefore a brief dwell at full brightness -- what a real scanner
    does -- instead of a blink.
    """
    count = max(2, int(led_count))
    step = max(1, int(step_ms))
    half = max(1, int(round(step * float(tail_leds))))
    width = 2 * half

    def sweep(order: list[int]) -> str:
        segments = []
        for position, led in enumerate(order):
            if position == 0:
                segments.append(f"{led}:{floor_color} {_time(half)} cosine")
            elif position == len(order) - 1:
                delay = (len(order) - 1) * step
                segments.append(f"{led}:{color} {_time(half)} cosine {_time(delay)}")
            else:
                delay = (position - 1) * step
                tail = f" {_time(delay)}" if delay else ""
                segments.append(f"{led}:{color} {_time(width)} pulse{tail}")
        return "; ".join(segments)

    forward = list(range(count))
    return [sweep(forward), sweep(list(reversed(forward)))]


def converge(
    color: str,
    floor_color: str,
    *,
    led_count: int,
    step_ms: int,
    tail_leds: float = 2.0,
) -> list[str]:
    """Two heads leaving the ends, meeting in the middle, and parting again."""
    count = max(2, int(led_count))
    step = max(1, int(step_ms))
    half = max(1, int(round(step * float(tail_leds))))
    width = 2 * half
    last = count - 1
    middle = last / 2.0

    def line(inward: bool) -> str:
        segments = []
        for index in range(count):
            distance = min(index, last - index)
            position = distance if inward else middle - distance
            delay = int(round(max(0.0, position - 1.0) * step))
            if position <= 0.0:
                segments.append(f"{index}:{floor_color} {_time(half)} cosine")
                continue
            tail = f" {_time(delay)}" if delay else ""
            segments.append(f"{index}:{color} {_time(width)} pulse{tail}")
        return "; ".join(segments)

    return [line(True), line(False)]


def fill(
    color: str,
    floor_color: str,
    *,
    led_count: int,
    cycle_ms: int,
) -> list[str]:
    """A progress bar: each LED eases up in turn, then the whole bar drains.

    The old shape used ``none``, which snaps -- eight hard steps up and one
    hard step down. Easing each arrival makes the same meaning without a
    single discontinuity.
    """
    count = max(1, int(led_count))
    total = max(1, int(cycle_ms))
    step = max(MIN_STEP_MS, int(total * 0.62) // count)
    segments = [
        f"{index}:{color} {_time(step * 2)} cosine"
        + (f" {_time(index * step)}" if index else "")
        for index in range(count)
    ]
    drain = max(MIN_STEP_MS * 2, total - (count - 1) * step - 2 * step)
    return ["; ".join(segments), f"{floor_color} {_time(drain)} cosine"]


#: A step that is co-prime with 8 and is neither 1 nor 7, so walking the strip
#: by it visits every LED in an order that reads as scattered rather than as a
#: diagonal. (An offset of the form ``index * k mod room`` looks random in a
#: table and renders as a SWEEP -- which is what the old twinkle was.)
SCATTER_STEPS: tuple[int, ...] = (3, 5)


def _scattered_slots(count: int, step: int) -> list[int]:
    """A frozen permutation of 0..count-1 that no two LEDs share.

    Deterministic, so the same bytes come out on every render and the device
    write dedupe still holds; scrambled, so no two LEDs light together and the
    order is not a line walking down the strip.
    """
    span = max(1, int(count))
    stride = int(step) % span or 1
    while math.gcd(stride, span) != 1:
        stride += 1
        if stride >= span:
            stride = 1
            break
    return [(index * stride) % span for index in range(span)]


def scatter(
    color: str,
    bed_color: str,
    *,
    led_count: int,
    cycle_ms: int,
    spark_fraction: float = 0.24,
    seed: int = 3,
) -> list[str]:
    """Short soft sparks at frozen scattered offsets over a resting bed.

    Each LED takes one slot of the cycle, and the slots are dealt out by a
    co-prime walk so the sparks are spread over the strip rather than marching
    along it -- the difference between a twinkle and a sweep.
    """
    count = max(1, int(led_count))
    total = max(1, int(cycle_ms))
    spark = max(MIN_STEP_MS * 2, int(total * max(0.05, min(0.6, spark_fraction))))
    room = max(1, total - spark)
    slots = _scattered_slots(count, seed)
    segments = []
    for index, slot in enumerate(slots):
        # The jitter keeps the sparks off a strict grid without letting any
        # two of them collide.
        delay = (slot * room // count + (index * 137) % max(1, room // (2 * count))) % room
        tail = f" {_time(delay)}" if delay else ""
        segments.append(f"{index}:{color} {_time(spark)} pulse{tail}")
    return [
        f"{bed_color} {_time(max(MIN_STEP_MS, total // 12))} cosine",
        "; ".join(segments),
    ]


def drift(
    color: str,
    bed_color: str,
    *,
    led_count: int,
    cycle_ms: int,
    seed: int = 3,
    stretch: float = 1.6,
) -> list[str]:
    """Wide, heavily overlapping swells: a cloud passing, not eight lamps."""
    count = max(1, int(led_count))
    total = max(1, int(cycle_ms))
    slots = _scattered_slots(count, seed)
    segments = []
    for index, slot in enumerate(slots):
        width = max(MIN_STEP_MS * 4, int(total * stretch) + (index * 137) % 331)
        delay = slot * (total // 2) // count
        tail = f" {_time(delay)}" if delay else ""
        segments.append(f"{index}:{color} {_time(width)} pulse{tail}")
    return [
        f"{bed_color} {_time(max(MIN_STEP_MS, total // 10))} cosine",
        "; ".join(segments),
    ]


def breath(
    color: str,
    floor_color: str,
    *,
    cycle_ms: int,
    inhale: float = 0.38,
) -> list[str]:
    """An asymmetric breath: quicker in, slower out, both half-cosines.

    A symmetric ``pulse`` is a machine breathing; a real one exhales longer
    than it inhales, and the difference is what makes an idle strip read as
    alive rather than as a metronome.
    """
    total = max(2, int(cycle_ms))
    rise = max(1, int(total * max(0.15, min(0.6, inhale))))
    return [
        f"{color} {_time(rise)} cosine",
        f"{floor_color} {_time(total - rise)} cosine",
    ]


def crossfade(color: str, other: str, *, cycle_ms: int) -> list[str]:
    """Two tones trading places without either of them ever going dark."""
    total = max(2, int(cycle_ms))
    half = max(1, total // 2)
    return [
        f"{color} {_time(half)} cosine",
        f"{other} {_time(total - half)} cosine",
    ]


def lub_dub(
    color: str,
    floor_color: str,
    *,
    cycle_ms: int,
) -> list[str]:
    """Two unequal thumps and a long rest, each thump a bump of its own.

    Every beat gets its own LINE: two segments naming the same LED on one line
    lose the first one outright in the firmware, which is how the old
    heartbeat came out as a single beat on a shared strip.
    """
    total = max(4, int(cycle_ms))
    thump = max(MIN_STEP_MS * 2, int(total * 0.13))
    gap = max(MIN_STEP_MS, int(total * 0.08))
    rest = max(MIN_STEP_MS * 2, total - 2 * thump - gap)
    return [
        f"{color} {_time(thump)} pulse",
        f"{floor_color} {_time(gap)} cosine",
        f"{shade(color, 0.6)} {_time(thump)} pulse",
        f"{floor_color} {_time(rest)} cosine",
    ]


def raised_cosine(fraction: float) -> float:
    """The firmware's own ``pulse`` envelope, for tests and previews."""
    return (1.0 - math.cos(2.0 * math.pi * max(0.0, min(1.0, fraction)))) / 2.0


def program_bytes(lines: list[str]) -> int:
    return len("\n".join(lines).encode("utf-8"))


def fits(lines: list[str], *, reserve_bytes: int = 0) -> bool:
    """Whether these lines still leave room for the caller's own lines."""
    return (
        program_bytes(lines) + int(reserve_bytes) <= MAX_PROGRAM_BYTES
        and len(lines) <= MAX_PROGRAM_LINES
    )


__all__ = (
    "CHASE_TAIL",
    "COMET_TAIL",
    "DOT_TAIL",
    "MARQUEE_TAIL",
    "MAX_PROGRAM_BYTES",
    "MAX_PROGRAM_LINES",
    "MIN_POSITIONAL_LEDS",
    "MIN_STEP_MS",
    "PROFILE_LEAD_MS",
    "TIDE_TAIL",
    "bounce",
    "breath",
    "converge",
    "crossfade",
    "drift",
    "fill",
    "fits",
    "gradient_wave",
    "lub_dub",
    "mix",
    "positional",
    "program_bytes",
    "SCATTER_STEPS",
    "raised_cosine",
    "scatter",
    "shade",
    "step_ms_for",
    "travelling_wave",
)
