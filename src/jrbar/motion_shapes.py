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
#: The Dot's other way to travel: a wipe rather than a crossfade. Handed to
#: ``travelling_wave`` in place of a tail, it plays LED 0 rising, LED 1
#: rising, LED 0 falling, LED 1 falling -- two LEDs that read as a
#: direction instead of as a swap. The second value is the level each LED
#: falls back to, so the Dot never goes fully dark between passes.
DOT_WIPE: tuple[float, ...] = (1.0, 0.10)


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
    head: str | None = None,
) -> str:
    fractions = _fitted_tail(tail, led_count)
    rest = max(0.0, min(1.0, float(floor)))
    shades = [shade(color, max(rest, fraction)) for fraction in fractions]
    if head is not None and shades:
        # A tinted head: the brightest LED takes the other colour at the
        # same strength, and the tail keeps the identity behind it.
        shades[0] = shade(head, max(rest, fractions[0]))
    return f"{' '.join(shades)} {_time(lead_ms)} cosine"


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
    head: str | None = None,
) -> list[str]:
    """A head-and-tail profile circulating the strip with no seam.

    ``roll`` crossfades between the shifted states, so the crest moves
    continuously rather than hopping LED to LED; repeating the roll line
    several times pays the profile repaint once per ``laps`` laps instead of
    once per lap, which is the difference between a wave and a wave that
    hesitates every time round.

    ``head`` paints the crest in another colour (the tool tint) while the
    tail keeps ``color``. ``tail=DOT_WIPE`` on two LEDs plays the Dot's
    wipe instead of a roll.
    """
    if tail is DOT_WIPE and int(led_count) <= 2:
        return dot_wipe(
            head or color,
            shade(color, max(float(floor), DOT_WIPE[1])),
            lap_ms=lap_ms,
            laps=laps,
            reverse=reverse,
        )
    direction = "roll-left" if reverse else "roll-right"
    duration = max(MIN_STEP_MS * max(1, int(led_count)), int(lap_ms))
    lead = (
        step_ms_for(duration, led_count) if lead_ms is None else int(lead_ms)
    )
    return [
        _profile_line(
            color, tail, led_count=led_count, lead_ms=lead, floor=floor, head=head
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
    ends: tuple[str, str] | None = None,
    reverse: bool = False,
) -> list[str]:
    """A full hue ramp travelling the strip: colour moves, brightness does not.

    The one motion with no dark LED at any instant, so it never reads as a
    flash however fast it is set to run. ``ends`` replaces the hue ramp
    with a blend between two chosen colours.
    """
    from .presentation_policy import _hue_shifted_color

    count = max(1, int(led_count))
    if ends is not None:
        shades = [
            mix(ends[0], ends[1], index / max(1, count - 1)) for index in range(count)
        ]
    else:
        shades = [
            _hue_shifted_color(
                color, (index / max(1, count - 1) - 0.5) * float(span_degrees)
            )
            for index in range(count)
        ]
    duration = max(MIN_STEP_MS * count, int(lap_ms))
    lead = step_ms_for(duration, count) if lead_ms is None else int(lead_ms)
    direction = "roll-left" if reverse else "roll-right"
    return [
        f"{' '.join(shades)} {_time(lead)} cosine",
        *([f"{direction} {_time(duration)} linear"] * max(1, int(laps))),
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
    reverse: bool = False,
    release: str = "all_at_once",
) -> list[str]:
    """A progress bar: each LED eases up in turn, then the whole bar drains.

    The old shape used ``none``, which snaps -- eight hard steps up and one
    hard step down. Easing each arrival makes the same meaning without a
    single discontinuity.

    ``release`` is how the full bar lets go: ``all_at_once`` drains the
    whole bar together, ``hold`` rests full for a beat first, and ``decay``
    empties it LED by LED from the last one filled.
    """
    count = max(1, int(led_count))
    total = max(1, int(cycle_ms))
    step = max(MIN_STEP_MS, int(total * 0.62) // count)
    order = list(range(count))
    if reverse:
        order.reverse()
    segments = [
        f"{led}:{color} {_time(step * 2)} cosine"
        + (f" {_time(position * step)}" if position else "")
        for position, led in enumerate(order)
    ]
    drain = max(MIN_STEP_MS * 2, total - (count - 1) * step - 2 * step)
    if release == "hold":
        return [
            "; ".join(segments),
            f"{color} {_time(max(MIN_STEP_MS * 2, drain // 2))} cosine",
            f"{floor_color} {_time(max(MIN_STEP_MS * 2, drain // 2))} cosine",
        ]
    if release == "decay":
        fade = max(MIN_STEP_MS, drain // max(1, count))
        emptied = [
            f"{led}:{floor_color} {_time(fade * 2)} cosine"
            + (f" {_time(position * fade)}" if position else "")
            for position, led in enumerate(reversed(order))
        ]
        return ["; ".join(segments), "; ".join(emptied)]
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
    jitter_seed: int = 0,
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
        jitter = (index * 137 + int(jitter_seed) * 53) % max(1, room // (2 * count))
        delay = (slot * room // count + jitter) % room
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
    detune: float = 1.0,
    palette: tuple[str, ...] = (),
    bed_fraction: float | None = None,
    jitter_seed: int = 0,
) -> list[str]:
    """Wide, heavily overlapping swells: a cloud passing, not eight lamps.

    ``detune`` scales how far each LED's swell strays from the others (1.0
    is the shipped spread). ``palette`` gives the LEDs their own crest
    colours in turn, each resting on its own shade (``bed_fraction`` of it),
    so an aurora can carry several colours instead of one.
    """
    count = max(1, int(led_count))
    total = max(1, int(cycle_ms))
    slots = _scattered_slots(count, seed)
    spread = max(0.0, float(detune))
    crests = [palette[index % len(palette)] for index in range(count)] if palette else []
    segments = []
    for index, slot in enumerate(slots):
        stray = int(((index * 137 + int(jitter_seed) * 71) % 331) * spread)
        width = max(MIN_STEP_MS * 4, int(total * stretch) + stray)
        delay = slot * (total // 2) // count
        tail = f" {_time(delay)}" if delay else ""
        crest = crests[index] if crests else color
        segments.append(f"{index}:{crest} {_time(width)} pulse{tail}")
    settle = _time(max(MIN_STEP_MS, total // 10))
    if crests and count > 1:
        fraction = 0.22 if bed_fraction is None else float(bed_fraction)
        beds = " ".join(shade(crest, fraction) for crest in crests)
        return [f"{beds} {settle} cosine", "; ".join(segments)]
    return [f"{bed_color} {settle} cosine", "; ".join(segments)]


#: Ember's hottest rim: even the edge LEDs keep a faint coal, so the
#: strip smoulders end to end instead of dying at the borders.
EMBER_RIM_FRACTION = 0.12


def ember(
    color: str,
    floor_color: str,
    *,
    led_count: int,
    cycle_ms: int,
    bed: float = 0.30,
) -> list[str]:
    """Coals glowing: a centre-hot profile swelling as one.

    The upstream idle signature (sidepulse's centre-bright gradient):
    the middle pair burns hottest, the shoulders warm, the rim barely
    smoulders -- but every LED swells together, so it reads as one bed
    of coals breathing rather than eight lamps sharing a metronome.
    Where ``breath`` lifts the whole strip to the same peak, ember
    keeps a spatial shape *at* the peak, and where ``drift`` detunes
    every swell, ember's is a single heartbeat the bed shares.
    """
    count = max(1, int(led_count))
    total = max(2, int(cycle_ms))
    middle = (count - 1) / 2.0
    weights = [
        max(
            EMBER_RIM_FRACTION,
            1.0 - (abs(index - middle) / max(middle, 1.0)) ** 1.5,
        )
        for index in range(count)
    ]
    coal = max(0.0, min(1.0, float(bed)))
    beds = " ".join(
        mix(floor_color, shade(color, coal), weight) for weight in weights
    )
    swell = max(MIN_STEP_MS * 2, int(total * 0.55))
    rest = max(MIN_STEP_MS, total - swell)
    coals = "; ".join(
        f"{index}:{shade(color, coal + (1.0 - coal) * weight)} {_time(swell)} pulse"
        for index, weight in enumerate(weights)
    )
    return [
        f"{beds} {_time(max(MIN_STEP_MS, total // 10))} cosine",
        coals,
        f"{beds} {_time(rest)} cosine",
    ]


def bloom(
    color: str,
    floor_color: str,
    *,
    led_count: int,
    step_ms: int,
    hold_ms: int = 0,
) -> list[str]:
    """Light opens from the centre outward, holds lit, then drains.

    The lid-open signature run as a loop: paired LEDs rise with a
    ``cosine`` at delays set by their distance from the middle, the
    outermost pair's rise finishing the line at full light -- the hold
    is that line-end dwell -- and one drain line eases the whole strip
    back to the floor. ``converge`` throws two heads at each other and
    they part; bloom *arrives and stays*, which is what makes it read
    as an opening instead of a meeting.
    """
    count = max(2, int(led_count))
    step = max(1, int(step_ms))
    middle = (count - 1) / 2.0
    rise = max(MIN_STEP_MS, step * 2)
    segments = []
    for index in range(count):
        distance = abs(index - middle)
        delay = int(round(max(0.0, distance - 0.5) * step))
        tail = f" {_time(delay)}" if delay else ""
        segments.append(f"{index}:{color} {_time(rise)} cosine{tail}")
    lines = ["; ".join(segments)]
    if int(hold_ms) > 0:
        # Every LED already sits at the crest here, so easing to it again
        # holds the open strip lit for the dwell.
        lines.append(f"{color} {_time(int(hold_ms))} cosine")
    lines.append(f"{floor_color} {_time(step * 3)} cosine")
    return lines


def frontier(
    color: str,
    floor_color: str,
    *,
    led_count: int,
    cycle_ms: int,
    level: float = 0.625,
) -> list[str]:
    """A held fill whose leading edge pulses into the dark.

    The battery-bar read: LEDs below the level sit lit and constant
    while the first unfilled LED pulses floor-to-peak once per cycle --
    a tip reaching forward, not a bar sweeping. ``stack`` piles on and
    lets go; frontier *holds* its level, so it can carry a number
    (charge, quota, progress) the way stack cannot.
    """
    count = max(1, int(led_count))
    total = max(2, int(cycle_ms))
    fraction = max(0.0, min(1.0, float(level)))
    filled = max(0, min(count, int(round(count * fraction))))
    tip = min(filled, count - 1)
    lit = shade(color, 0.88)
    pulse = max(MIN_STEP_MS * 2, int(total * 0.45))
    # The line lasts exactly the tip's pulse: the fill's cosine holds
    # ride it out, so the strip is steady except for the breathing tip.
    hold = pulse
    segments = []
    for index in range(count):
        if index < tip:
            segments.append(f"{index}:{lit} {_time(hold)} cosine")
        elif index == tip:
            segments.append(f"{index}:{color} {_time(pulse)} pulse")
        else:
            segments.append(f"{index}:{floor_color} {_time(hold)} cosine")
    return ["; ".join(segments)]


#: One bright LED's worth of glint: a thin crest and a short shoulder,
#: so the pass reads as light catching a rim, not as a comet with a tail.
GLINT_TAIL: tuple[float, ...] = (1.0, 0.18, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0)


def glint(
    color: str,
    *,
    led_count: int,
    lap_ms: int,
    laps: int = 1,
    bed: float = 0.62,
    head: str | None = None,
    reverse: bool = False,
) -> list[str]:
    """A thin bright pass sweeping a strip that stays lit.

    Same roll machinery as the travelling wave, but the floor is held
    at a reading-light level and the profile is a single sharp crest --
    the difference between a specular highlight sliding over a lit
    surface and a comet crossing a dark one.
    """
    return travelling_wave(
        color,
        led_count=led_count,
        lap_ms=lap_ms,
        tail=GLINT_TAIL,
        laps=laps,
        floor=max(0.0, min(1.0, float(bed))),
        head=head,
        reverse=reverse,
    )


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


#: The share of a heartbeat's cycle that is rest after the two thumps. The
#: thumps and the gap between them split what is left 13 : 8 : 13.
HEARTBEAT_REST_RATIO = 0.66


def lub_dub(
    color: str,
    floor_color: str,
    *,
    cycle_ms: int,
    rest_ratio: float = HEARTBEAT_REST_RATIO,
) -> list[str]:
    """Two unequal thumps and a long rest, each thump a bump of its own.

    Every beat gets its own LINE: two segments naming the same LED on one line
    lose the first one outright in the firmware, which is how the old
    heartbeat came out as a single beat on a shared strip.
    """
    total = max(4, int(cycle_ms))
    ratio = max(0.2, min(0.85, float(rest_ratio)))
    # The shipped proportions, spelled as they always were so the default
    # heartbeat keeps its exact bytes; any other rest scales both thumps
    # and the gap together.
    thump_share, gap_share = 0.13, 0.08
    if ratio != HEARTBEAT_REST_RATIO:
        thump_share = (1.0 - ratio) * 13 / 34
        gap_share = (1.0 - ratio) * 8 / 34
    thump = max(MIN_STEP_MS * 2, int(total * thump_share))
    gap = max(MIN_STEP_MS, int(total * gap_share))
    rest = max(MIN_STEP_MS * 2, total - 2 * thump - gap)
    return [
        f"{color} {_time(thump)} pulse",
        f"{floor_color} {_time(gap)} cosine",
        f"{shade(color, 0.6)} {_time(thump)} pulse",
        f"{floor_color} {_time(rest)} cosine",
    ]


# --- The Dot's travel ------------------------------------------------------

#: How a travelling motion plays on two LEDs: the wipe (LED 0 rises, LED 1
#: rises, LED 0 falls, LED 1 falls) or the older soft crossfade.
DOT_TRAVEL_WIPE = "wipe"
DOT_TRAVEL_CROSSFADE = "crossfade"
DOT_TRAVEL_STYLES: tuple[str, ...] = (DOT_TRAVEL_WIPE, DOT_TRAVEL_CROSSFADE)
DEFAULT_DOT_TRAVEL_STYLE = DOT_TRAVEL_WIPE
#: A wipe lap is four quarter-moves, each its own line. Two laps a set
#: keep the program small enough that a linked Pro can still be drawn from
#: it (``dot_role`` widens every Dot line to four LEDs a side).
MAX_WIPE_LAPS = 2


def dot_travel_tail(style: str) -> tuple[float, ...]:
    """The tail a two-LED strip travels with, for ``travelling_wave``.

    ``DOT_WIPE`` for the wipe (the default) and ``DOT_TAIL`` for the
    crossfade; anything unrecognised is the default, so a settings file
    from a newer build never changes how the Dot moves.
    """
    return DOT_TAIL if style == DOT_TRAVEL_CROSSFADE else DOT_WIPE


def dot_wipe(
    color: str,
    floor_color: str,
    *,
    lap_ms: int,
    laps: int = 1,
    reverse: bool = False,
) -> list[str]:
    """Two LEDs that read as a direction: rise, rise, fall, fall.

    zschwendi's directional breathe for a two-LED device. Each quarter of
    the lap moves one LED with a half-cosine, so there is a moment with both
    lit and a moment with both resting -- the light arrives on one side and
    leaves from it, where the rolled crossfade only ever swaps the two.
    """
    quarter = max(MIN_STEP_MS * 2, max(1, int(lap_ms)) // 4)
    first, second = (1, 0) if reverse else (0, 1)
    lap = [
        f"{first}:{color} {_time(quarter)} cosine",
        f"{second}:{color} {_time(quarter)} cosine",
        f"{first}:{floor_color} {_time(quarter)} cosine",
        f"{second}:{floor_color} {_time(quarter)} cosine",
    ]
    return lap * max(1, min(MAX_WIPE_LAPS, int(laps)))


# --- Tails a person can shape -----------------------------------------------


def periodic_tail(tail: tuple[float, ...], *, crests: int, led_count: int) -> tuple[float, ...]:
    """``tail`` repeated ``crests`` times round the strip, one value per LED.

    Sampled as a continuous phase rather than tiled, so three crests on
    eight LEDs are three evenly spaced swells with no seam where a tile
    would have been cut short. One crest returns the profile unchanged.
    """
    count = max(1, int(led_count))
    waves = max(1, int(crests))
    if waves == 1:
        return tail if len(tail) == count else _fitted_tail(tail, count)
    span = len(tail)
    values = []
    for index in range(count):
        position = ((index * waves / count) % 1.0) * span
        low = int(math.floor(position)) % span
        high = (low + 1) % span
        weight = position - math.floor(position)
        values.append(round(tail[low] * (1.0 - weight) + tail[high] * weight, 3))
    return tuple(values)


def blended_tail(soft: tuple[float, ...], hard: tuple[float, ...], softness: float) -> tuple[float, ...]:
    """``softness`` of the way from the ``hard`` profile to the ``soft`` one."""
    weight = max(0.0, min(1.0, float(softness)))
    return tuple(
        round(h + (s - h) * weight, 3) for s, h in zip(soft, hard)
    )


def comet_tail(*, head_width: int, trail_length: int, led_count: int = 8) -> tuple[float, ...]:
    """A comet ``head_width`` LEDs wide, fading by 0.38 per LED for
    ``trail_length`` LEDs, then dark -- never longer than the strip."""
    count = max(2, int(led_count))
    head = max(1, min(count - 1, int(head_width)))
    trail = max(0, min(count - head, int(trail_length)))
    values = [1.0] * head + [round(0.38**step, 3) for step in range(1, trail + 1)]
    return tuple(values + [0.0] * (count - len(values)))


def scaled_tail(tail: tuple[float, ...], *, low: float, high: float) -> tuple[float, ...]:
    """``tail`` stretched so its dimmest value sits at ``low`` and its
    brightest at ``high``."""
    bottom, top = min(tail), max(tail)
    lo = max(0.0, min(1.0, float(low)))
    hi = max(lo, min(1.0, float(high)))
    if top - bottom <= 1e-9:
        return tuple(hi for _ in tail)
    return tuple(
        round(lo + (value - bottom) * (hi - lo) / (top - bottom), 3) for value in tail
    )


# --- New motions ------------------------------------------------------------

#: How much dimmer each ring of a ripple is than the one inside it.
RIPPLE_DECAY = 0.22
#: How much of a ripple's cycle one LED's swell lasts, and how much of it
#: the ring takes to travel from the centre pair to the ends.
RIPPLE_SWELL = 0.55
RIPPLE_TRAVEL = 0.3


def ripple(
    color: str,
    floor_color: str,
    *,
    led_count: int,
    cycle_ms: int,
    decay: float = RIPPLE_DECAY,
) -> list[str]:
    """A stone dropped in water: the centre crests first, a wide ring runs
    outward dimming as it goes, and the next stone falls a moment after it
    reaches the ends.

    Bloom fills from the centre and holds; converge sends two heads to
    meet. A ripple is neither -- every LED swells and settles in turn, a
    little later and a little weaker the further out it is, so the strip
    reads as one disturbance spreading and dying away. Each swell lasts
    over half the cycle and the ring takes most of the rest to reach the
    ends, so the strip is never dark for long: this is a working light,
    not a blip followed by a wait.
    """
    count = max(2, int(led_count))
    total = max(MIN_STEP_MS * 8, int(cycle_ms))
    middle = (count - 1) / 2.0
    farthest = max(0.0, middle - 0.5)
    step = max(MIN_STEP_MS, int(total * RIPPLE_TRAVEL / max(1.0, farthest)))
    width = max(MIN_STEP_MS * 3, int(total * RIPPLE_SWELL))
    fade = max(0.0, min(0.5, float(decay)))
    segments = []
    for index in range(count):
        distance = max(0.0, abs(index - middle) - 0.5)
        ring = shade(color, max(0.25, 1.0 - fade * distance))
        delay = int(round(distance * step))
        tail = f" {_time(delay)}" if delay else ""
        segments.append(f"{index}:{ring} {_time(width)} pulse{tail}")
    spread = int(round(farthest * step)) + width
    rest = max(MIN_STEP_MS, total - spread - MIN_STEP_MS)
    return [
        f"{floor_color} {_time(MIN_STEP_MS)} cosine",
        "; ".join(segments),
        f"{floor_color} {_time(rest)} cosine",
    ]


#: How wide the pendulum's glow is, in LEDs either side of the head.
PENDULUM_TAIL_LEDS = 1.6
#: How much dimmer the swing is as it rushes through the middle than where
#: it hangs at either end.
PENDULUM_MIDDLE_DIM = 0.4


def pendulum(
    color: str,
    floor_color: str,
    *,
    led_count: int,
    cycle_ms: int,
    tail_leds: float = PENDULUM_TAIL_LEDS,
) -> list[str]:
    """A weight on a string: the light hangs at each end, then rushes --
    dimmer, the way a fast thing blurs -- through the middle.

    The head's place in a sweep follows a swing eased twice (the time to
    reach ``x`` is ``g(g(x))`` with ``g(x) = acos(1 - 2x) / pi``), so it
    spends most of each sweep near the ends and crosses the middle in a
    few frames. Each LED's bump is as wide as the time the head spends
    near it and as bright as it is slow there. That is what sets it apart
    from Knight Rider, whose eye keeps one pace and one brightness end to
    end. The ends hand over with the rise-then-open trick ``bounce`` uses,
    so a turn is a dwell at full light, never a blink.
    """
    count = max(2, int(led_count))
    half = max(MIN_STEP_MS * 2, max(2, int(cycle_ms)) // 2)
    reach = max(0.5, min(3.0, float(tail_leds)))
    last = count - 1

    def swing(fraction: float) -> float:
        return math.acos(1.0 - 2.0 * max(0.0, min(1.0, fraction))) / math.pi

    def arrival(fraction: float) -> float:
        return half * swing(swing(fraction))

    def lit(position: int) -> str:
        edge = abs(2.0 * position / last - 1.0)
        level = 1.0 - PENDULUM_MIDDLE_DIM * (1.0 - edge)
        return color if level >= 1.0 else shade(color, level)

    def sweep(order: list[int]) -> str:
        segments = []
        for position, led in enumerate(order):
            early = max(0.0, (position - reach) / last)
            late = min(1.0, (position + reach) / last)
            width = max(MIN_STEP_MS * 2, int(arrival(late) - arrival(early)))
            if position == 0:
                # The swing leaves the end as slowly as it arrived: the
                # crest eases off over the whole time the head is near it.
                segments.append(f"{led}:{floor_color} {_time(max(MIN_STEP_MS, width))} cosine")
            elif position == last:
                rise = max(MIN_STEP_MS, width)
                segments.append(f"{led}:{color} {_time(rise)} cosine {_time(max(0, half - rise))}")
            else:
                delay = max(0, int(arrival(position / last) - width / 2))
                tail = f" {_time(delay)}" if delay else ""
                segments.append(f"{led}:{lit(position)} {_time(width)} pulse{tail}")
        return "; ".join(segments)

    forward = list(range(count))
    return [sweep(forward), sweep(list(reversed(forward)))]


#: The narrowest bump a landing uses. The last LEDs are crossed fastest,
#: and a bump much narrower than this is a flash rather than a light
#: gathering speed (measured: 120 ms bumps jump a third of full scale in
#: one 60 Hz frame; 300 ms keeps every step under the library's ceiling).
LAND_MIN_BUMP_MS = 300


def land(
    color: str,
    floor_color: str,
    *,
    led_count: int,
    cycle_ms: int,
    reverse: bool = False,
    splash: bool = True,
    settle: str | None = None,
) -> list[str]:
    """Something arriving: a light falls toward the far end, gathering
    speed, lands with a small splash, and rests.

    Arrival time grows with the square root of the distance travelled, as a
    dropped thing does, so the gaps between LEDs shrink toward the landing
    and each bump narrows with them. The landing LED does not bump: it
    rises to full as the light arrives and stays lit through the splash
    (its two neighbours thrown back at falling strength), easing to
    ``settle`` -- the glow a finish holds where the light came to rest --
    or, without one, to the floor. There is no moment where it goes dark
    and lights again. On a horizontal strip it reads as "it arrived", which
    is why it is a finish rather than a working loop.
    """
    count = max(2, int(led_count))
    total = max(MIN_STEP_MS * 12, int(cycle_ms))
    order = list(range(count))
    if reverse:
        order.reverse()
    fall = max(400, int(total * 0.45))
    span = max(1, count - 1)
    timings = []
    for step in range(count):
        near = math.sqrt(min(1.0, (step + 1.5) / span))
        far = math.sqrt(max(0.0, (step - 1.5) / span))
        width = max(LAND_MIN_BUMP_MS, int(fall * (near - far)))
        timings.append((fall * math.sqrt(step / span), width))
    # Every bump is centred on its arrival; the release is pushed back just
    # far enough that the first bump's rise fits before it.
    lead = max(0.0, max(width / 2 - arrive for arrive, width in timings))
    landing = order[-1]
    segments = []
    for (arrive, width), led in zip(timings, order):
        if led == landing:
            # Rises into the arrival and holds full until the splash.
            rise = max(MIN_STEP_MS, int(round(width / 2)))
            delay = max(0, int(round(arrive + lead)) - rise)
            tail = f" {_time(delay)}" if delay else ""
            segments.append(f"{led}:{color} {_time(rise)} cosine{tail}")
            continue
        delay = max(0, int(round(arrive + lead - width / 2)))
        tail = f" {_time(delay)}" if delay else ""
        segments.append(f"{led}:{color} {_time(width)} pulse{tail}")
    lines = [f"{floor_color} {_time(MIN_STEP_MS)} cosine", "; ".join(segments)]
    used = MIN_STEP_MS + int(fall + lead)
    rest_color = settle or floor_color
    if splash and count >= 2:
        throw = [f"{landing}:{rest_color} {_time(400)} cosine"]
        throw.append(f"{order[-2]}:{shade(color, 0.35)} {_time(260)} pulse {_time(60)}")
        if count > 3:
            throw.append(f"{order[-3]}:{shade(color, 0.15)} {_time(240)} pulse {_time(140)}")
        lines.append("; ".join(throw))
        used += 400
    elif settle:
        lines.append(f"{landing}:{settle} {_time(400)} cosine")
        used += 400
    lines.append(f"{floor_color} {_time(max(MIN_STEP_MS, total - used))} cosine")
    return lines


# --- Lid transitions (upstream's iris, reimplemented) -----------------------

#: Upstream sidepulse #38's lid-open colours: the working cyan at the centre
#: opening out to the done green at the rim.
IRIS_OPEN_START = "#00E5FF"
IRIS_OPEN_END = "#00FF66"


def iris_open(
    start: str = IRIS_OPEN_START,
    end: str = IRIS_OPEN_END,
    *,
    led_count: int,
    step_ms: int = 80,
) -> list[str]:
    """The lid opens and so does the light: the centre pair rises first and
    each pair outward follows ``step_ms`` later, the colour ramping from
    ``start`` at the centre to ``end`` at the rim; the whole strip settles
    on ``end`` and fades out. Finite, and it ends dark.

    Two LEDs have no centre to open from, so they rise together.
    """
    count = max(2, int(led_count))
    middle = (count - 1) / 2.0
    farthest = max(1.0, middle - 0.5)
    step = max(MIN_STEP_MS, int(step_ms))
    segments = []
    for index in range(count):
        distance = max(0.0, abs(index - middle) - 0.5)
        tone = mix(start, end, distance / farthest)
        delay = int(round(distance * step))
        tail = f" {_time(delay)}" if delay else ""
        segments.append(f"{index}:{tone} {_time(180)} ease{tail}")
    return [
        f"off {_time(90)} cosine",
        "; ".join(segments),
        f"{end} {_time(220)} ease",
        f"off {_time(320)} ease-out",
    ]


def iris_close(
    *,
    led_count: int,
    step_ms: int = 75,
    hold_ms: int = 1000,
    to: str = "#000000",
) -> list[str]:
    """The lid closes and so does the light: the outermost pair goes dark
    first and each pair inward follows ``step_ms`` later, until the centre
    closes; then the strip holds. Finite, and it ends black -- or on ``to``,
    the ember an agent that keeps working leaves behind.

    It starts from whatever the strip was showing, so the close is always
    the light the person was just looking at, drawn shut.
    """
    count = max(2, int(led_count))
    step = max(MIN_STEP_MS, int(step_ms))
    segments = []
    for index in range(count):
        distance = min(index, count - 1 - index)
        tail = f" {_time(distance * step)}" if distance else ""
        segments.append(f"{index}:{to} {_time(step)} ease{tail}")
    return ["; ".join(segments), f"{to} {_time(max(MIN_STEP_MS, int(hold_ms)))}"]


# --- Strip direction --------------------------------------------------------

LED_DIRECTION_FORWARD = "forward"
LED_DIRECTION_REVERSED = "reversed"


def normalize_led_direction(value: object) -> str:
    """``reversed`` or ``forward``; anything else is forward."""
    return LED_DIRECTION_REVERSED if value == LED_DIRECTION_REVERSED else LED_DIRECTION_FORWARD


def oriented_program(program: str, *, led_count: int, direction: str) -> str:
    """``program`` for a strip mounted the other way round.

    Forward returns the text untouched. Reversed mirrors every position:
    LED ``i`` becomes LED ``n - 1 - i``, a colour list is read from the far
    end, and a roll turns the other way -- so a comet that ran left to right
    on the desk still runs left to right after the strip is flipped. Text
    this cannot read, or a mirror that would no longer fit the firmware,
    comes back untouched rather than broken.
    """
    if normalize_led_direction(direction) != LED_DIRECTION_REVERSED or not program:
        return program
    from dataclasses import replace

    from .animation import (
        ROLL_LEFT,
        ROLL_RIGHT,
        Animation,
        ColorList,
        IndexedPaint,
        PaintStep,
        RollStep,
        errors_only,
        read_program,
        render_animation,
    )

    count = max(1, int(led_count))
    animation, problems = read_program(program, led_count=count)
    if errors_only(problems):
        return program

    def mirrored(segment):
        if type(segment) is ColorList:
            colors = list(segment.colors[:count])
            colors += ["#000000"] * (count - len(colors))
            return replace(segment, colors=tuple(reversed(colors)))
        if type(segment) is IndexedPaint:
            return replace(
                segment,
                assignments=tuple(
                    (count - 1 - index if index < count else index, color)
                    for index, color in segment.assignments
                ),
            )
        return segment

    steps = []
    for step in animation.steps:
        if type(step) is PaintStep:
            steps.append(replace(step, segments=tuple(mirrored(s) for s in step.segments)))
        elif type(step) is RollStep:
            turned = ROLL_LEFT if step.direction == ROLL_RIGHT else ROLL_RIGHT
            steps.append(replace(step, direction=turned))
        else:
            steps.append(step)
    text = render_animation(Animation(animation.name, tuple(steps)))
    if len(text.encode("utf-8")) > MAX_PROGRAM_BYTES:
        return program
    _checked, after = read_program(text, led_count=count)
    return program if errors_only(after) else text


# --- One dispatcher ---------------------------------------------------------

# Motion names, spelled here so this module never imports ``colors``.
BREATHE = "breathe"
EMBER = "ember"
DUOTONE = "duotone"
CHASE = "chase"
GRADIENT = "gradient"
HEARTBEAT = "heartbeat"
SCANNER = "scanner"
KITT = "kitt"
COMET = "comet"
GLINT = "glint"
FLICKER = "flicker"
STACK = "stack"
TWINKLE = "twinkle"
DRIFT = "drift"
CONVERGE = "converge"
BLOOM = "bloom"
AURORA = "aurora"
TIDE = "tide"
FRONTIER = "frontier"
MARQUEE = "marquee"
STEADY = "steady"
BLINK = "blink"
RIPPLE = "ripple"
PENDULUM = "pendulum"

#: Motions whose head moves along the strip. On two LEDs there is nowhere
#: for it to go, so they take the Dot's travel instead.
TRAVELLING_MOTIONS = frozenset(
    {CHASE, COMET, MARQUEE, TIDE, GRADIENT, KITT, SCANNER, CONVERGE, STACK, PENDULUM}
)
#: Motions whose head can wear the tool tint.
TINTABLE_MOTIONS = frozenset({CHASE, COMET, GLINT})
#: How many laps a circulating motion rolls before repainting its profile.
#: The repaint is a short hesitation once per set, so amortising it over
#: several laps is the difference between a wave and a wave with a hiccup.
ROLL_LAPS = 6
#: The registry's default seeds. A seed at its default keeps the shipped
#: pattern exactly; any other value picks another repeatable one.
DEFAULT_SCATTER_SEED = 271
DEFAULT_AURORA_SEED = 617
#: Bytes a motion leaves for its caller: a settle ease, ``repeat`` and a
#: ``brightness`` line.
RENDER_RESERVE_BYTES = 48
#: Motions that play without the settle ease in front. The ease goes back
#: to the floor at the top of every loop, and these never rest there: a
#: sweep that turns at a lit end (Knight Rider, Scanner, Pendulum) went
#: dark for up to a fifth of a second at LED 0 on every swing, and a held
#: colour blinked. They keep only ``repeat`` and a brightness line.
UNSETTLED_MOTIONS = frozenset({STEADY, KITT, SCANNER, PENDULUM})
#: What an unsettled motion leaves for its caller: ``repeat`` and a
#: ``brightness`` line, with their line breaks.
UNSETTLED_RESERVE_BYTES = 24
#: ``aurora.wave_count`` 1-4 as the swell width it stands for.
AURORA_STRETCH: dict[int, float] = {1: 2.8, 2: 2.0, 3: 1.5, 4: 1.1}


def _number(params, name: str, default: float, low: float, high: float) -> float:
    value = params.get(name, default)
    if isinstance(value, bool) or not isinstance(value, (int, float)) or not math.isfinite(value):
        return default
    return max(low, min(high, float(value)))


def _whole(params, name: str, default: int, low: int, high: int) -> int:
    value = params.get(name, default)
    if isinstance(value, bool) or not isinstance(value, (int, float)) or not math.isfinite(value):
        return default
    return max(low, min(high, int(round(value))))


def _choice(params, name: str, default: str, choices: tuple[str, ...]) -> str:
    value = params.get(name, default)
    return value if isinstance(value, str) and value in choices else default


def _palette(params, name: str, *, most: int) -> tuple[str, ...]:
    value = params.get(name)
    if not isinstance(value, (list, tuple)):
        return ()
    colors = tuple(
        f"#{item.strip().lstrip('#').upper()}"
        for item in value
        if isinstance(item, str) and len(item.strip().lstrip("#")) == 6
        and all(ch in "0123456789abcdefABCDEF" for ch in item.strip().lstrip("#"))
    )
    return colors[:most] if len(colors) >= 2 else ()


def _seeded(params, name: str, default_seed: int, strides: tuple[int, int]) -> tuple[int, int]:
    """(stride, jitter) for a seed: its default keeps the shipped pattern."""
    seed = _whole(params, name, default_seed, 0, 2_147_483_647)
    offset = seed - default_seed
    stride = strides[0] if offset % 2 == 0 else strides[1]
    return stride, offset // 2


def _travel_step(cycle_ms: int, led_count: int) -> int:
    """The step a bouncing head takes between neighbours: a bounce is two
    sweeps, each one step per LED plus the two its tail needs at the ends,
    so this makes one there-and-back take the whole cycle."""
    span = 2 * (max(2, int(led_count)) + 1)
    return max(MIN_STEP_MS, min(MAX_STEP_MS, max(1, int(cycle_ms)) // span))


def render_motion(
    motion: str,
    peak: str,
    floor_color: str,
    *,
    led_count: int,
    cycle_ms: int,
    params=None,
    compact: bool = False,
    dot_travel: str = DEFAULT_DOT_TRAVEL_STYLE,
    head: str | None = None,
    ceiling: float = 1.0,
    reserve_bytes: int = RENDER_RESERVE_BYTES,
) -> list[str]:
    """One motion as whole-strip lines: the only geometry JR-Bar has.

    The Settings thumbnails, Effect Studio, a Cycle turn and the live Pro
    with one agent working all come here, so what a preview shows is what
    the strip plays. ``motion`` is already decided (urgency and the speed
    guard are the caller's); ``peak`` and ``floor_color`` are the state's
    crest and rest. ``params`` are the motion's Effect Studio values, read
    tolerantly: a missing or out-of-range value is its default.

    ``compact`` gives a circulating motion one lap instead of a set, for a
    program that shares its 512 bytes. ``dot_travel`` is how a travelling
    motion moves on two LEDs. ``head`` is the tool tint for the motions
    whose crest can carry it, and ``ceiling`` is how far ``peak`` was
    scaled from the full colour, so chosen colours are dimmed to match.

    Everything here is drawn with LED 0 on the left. A strip mounted the
    other way round is mirrored once, as the last step, over the whole
    program its renderer builds (``oriented_program``, through
    ``colors._honours_strip_direction`` and the presentation wrapper), so a
    shared strip and a Cycle turn turn round with it, not only one motion.

    When the chosen values would leave less than ``reserve_bytes`` of the
    firmware's 512 for the caller's own lines (a settle ease, ``repeat``, a
    brightness line), the motion is drawn with its default values instead:
    a slightly plainer motion beats a program the strip cannot take.
    """
    values = params if isinstance(params, dict) else {}

    def draw(knobs: dict) -> list[str]:
        return _motion_lines(
            motion,
            peak,
            floor_color,
            led_count=max(1, int(led_count)),
            cycle_ms=max(1, int(cycle_ms)),
            params=knobs,
            compact=compact,
            dot_travel=dot_travel,
            head=head if motion in TINTABLE_MOTIONS else None,
            ceiling=max(0.0, min(1.0, float(ceiling))),
        )

    lines = draw(values)
    if values and not fits(lines, reserve_bytes=reserve_bytes):
        lines = draw({})
    return lines


def _motion_lines(
    motion: str,
    peak: str,
    floor_color: str,
    *,
    led_count: int,
    cycle_ms: int,
    params: dict,
    compact: bool,
    dot_travel: str,
    head: str | None,
    ceiling: float,
) -> list[str]:
    from .presentation_policy import _hue_shifted_color

    count = led_count
    cycle = cycle_ms
    laps = 1 if compact else ROLL_LAPS
    tinted = shade(head, ceiling) if head else None

    if motion == STEADY:
        level = _number(params, "luminance", 1.0, 0.05, 1.0)
        held = peak if level >= 1.0 else shade(peak, level)
        return [f"{held} {cycle}ms cosine"]
    if motion == BLINK:
        # The one shape that is meant to have hard edges. Everything else
        # in the vocabulary eases, which is what keeps a blink readable as
        # an interruption rather than as a faster breath.
        half = max(1, cycle // 2)
        return [f"{peak} {half}ms none", f"{floor_color} {half}ms none"]
    if motion == HEARTBEAT:
        rest = _number(params, "rest_ratio", HEARTBEAT_REST_RATIO, 0.35, 0.8)
        return lub_dub(peak, floor_color, cycle_ms=cycle, rest_ratio=rest)
    if motion == DUOTONE:
        palette = _palette(params, "palette", most=2)
        if palette:
            return crossfade(shade(palette[0], ceiling), shade(palette[1], ceiling), cycle_ms=cycle)
        offset = _number(params, "secondary_hue_offset_degrees", 40.0, -180.0, 180.0)
        return crossfade(peak, _hue_shifted_color(peak, offset), cycle_ms=cycle)
    if motion in (TWINKLE, FLICKER):
        # Twinkle sparks over darkness; flicker shimmers over a lit bed at a
        # shorter spark, so the two read as different weather rather than
        # as one scatter with two names.
        if motion == TWINKLE:
            stride, jitter = _seeded(params, "seed", DEFAULT_SCATTER_SEED, (3, 5))
            density = _number(params, "density", 0.15, 0.02, 0.3)
            return scatter(
                peak,
                floor_color,
                led_count=count,
                cycle_ms=cycle,
                spark_fraction=round(density * 0.26 / 0.15, 3),
                seed=stride,
                jitter_seed=jitter,
            )
        stride, jitter = _seeded(params, "seed", DEFAULT_SCATTER_SEED, (5, 3))
        bed = _number(params, "luminance_floor", 0.35, 0.1, 0.8)
        variation = _number(params, "variation", 0.25, 0.0, 0.5)
        return scatter(
            peak,
            shade(peak, round(bed * 0.12 / 0.35, 4)),
            led_count=count,
            cycle_ms=cycle,
            spark_fraction=round(0.05 + variation * 0.4, 3),
            seed=stride,
            jitter_seed=jitter,
        )
    if motion == DRIFT:
        detune = _number(params, "detune", 0.08, 0.0, 0.25)
        return drift(
            peak,
            shade(peak, 0.06),
            led_count=count,
            cycle_ms=cycle,
            seed=3,
            stretch=1.6,
            detune=round(detune / 0.08, 4),
        )
    if motion == AURORA:
        # Aurora rests on a LUMINOUS bed (light moving on water at night)
        # where drift rests near-dark; the swells are wider still.
        stride, jitter = _seeded(params, "seed", DEFAULT_AURORA_SEED, (5, 3))
        waves = _whole(params, "wave_count", 2, 1, 4)
        palette = tuple(shade(color, ceiling) for color in _palette(params, "palette", most=4))
        return drift(
            peak,
            shade(peak, 0.22),
            led_count=count,
            cycle_ms=cycle,
            seed=stride,
            stretch=AURORA_STRETCH[waves],
            palette=palette,
            bed_fraction=0.22,
            jitter_seed=jitter,
        )
    if motion == EMBER:
        bed = _number(params, "bed", 0.30, 0.05, 0.6)
        return ember(peak, floor_color, led_count=count, cycle_ms=cycle, bed=bed)
    if motion == FRONTIER:
        level = _number(params, "level", 0.625, 0.0, 1.0)
        return frontier(peak, floor_color, led_count=count, cycle_ms=cycle, level=level)
    if motion == RIPPLE:
        decay = _number(params, "fade", RIPPLE_DECAY, 0.0, 0.5)
        return ripple(peak, floor_color, led_count=count, cycle_ms=cycle, decay=decay)

    if motion in TRAVELLING_MOTIONS and not positional(count):
        # Two LEDs have nowhere for a head to travel: the Dot wipes or
        # crossfades, never a two-LED strobe.
        backwards = _choice(params, "direction", "forward", ("forward", "reverse")) == "reverse"
        return travelling_wave(
            peak,
            led_count=count,
            lap_ms=cycle,
            tail=dot_travel_tail(dot_travel),
            laps=laps,
            reverse=backwards,
            head=tinted,
        )
    if motion == CHASE:
        softness = _number(params, "softness", 1.0, 0.0, 1.0)
        crests = _whole(params, "crests", 1, 1, 3)
        profile = periodic_tail(
            blended_tail(CHASE_TAIL, COMET_TAIL, softness), crests=crests, led_count=count
        )
        backwards = _choice(params, "direction", "forward", ("forward", "reverse")) == "reverse"
        return travelling_wave(
            peak, led_count=count, lap_ms=cycle, tail=profile, laps=laps,
            reverse=backwards, head=tinted,
        )
    if motion == COMET:
        head_width = _whole(params, "head_width", 1, 1, 4)
        trail = _whole(params, "trail_length", 3, 1, 6)
        profile = (
            COMET_TAIL
            if (head_width, trail) == (1, 3)
            else comet_tail(head_width=head_width, trail_length=trail, led_count=len(COMET_TAIL))
        )
        backwards = _choice(params, "direction", "forward", ("forward", "reverse")) == "reverse"
        return travelling_wave(
            peak, led_count=count, lap_ms=max(1, int(cycle * 0.6)), tail=profile,
            laps=laps, reverse=backwards, head=tinted,
        )
    if motion == GLINT:
        # Glint keeps its lit bed on every strip length -- even the Dot,
        # where the other travelling shapes wipe or crossfade.
        bed = _number(params, "bed", 0.62, 0.3, 0.9)
        return glint(peak, led_count=count, lap_ms=cycle, laps=laps, bed=bed, head=tinted)
    if motion == MARQUEE:
        crests = _whole(params, "crests", 2, 1, 3)
        rotation = _number(params, "palette_rotation_degrees", 0.0, 0.0, 180.0)
        backwards = _choice(params, "direction", "forward", ("forward", "reverse")) == "reverse"
        profile = periodic_tail(MARQUEE_TAIL[:4], crests=crests, led_count=count)
        lines = travelling_wave(
            peak, led_count=count, lap_ms=cycle, tail=profile, laps=laps, reverse=backwards
        )
        if rotation > 0.0:
            lines[0] = _rotated_bands(lines[0], peak, rotation, crests=crests, led_count=count)
        return lines
    if motion == TIDE:
        low = _number(params, "fill_floor", 0.15, 0.0, 0.8)
        span = _number(params, "fill_range", 0.85, 0.1, 1.0)
        profile = scaled_tail(
            TIDE_TAIL,
            low=min(1.0, low * 0.22 / 0.15),
            high=min(1.0, low * 0.22 / 0.15 + span * 0.78 / 0.85),
        )
        return travelling_wave(peak, led_count=count, lap_ms=2 * cycle, tail=profile, laps=laps)
    if motion == GRADIENT:
        palette = _palette(params, "palette", most=2)
        span = _number(params, "hue_span_degrees", 48.0, 0.0, 120.0)
        backwards = _choice(params, "direction", "forward", ("forward", "reverse")) == "reverse"
        return gradient_wave(
            peak,
            led_count=count,
            lap_ms=cycle,
            span_degrees=span,
            laps=laps,
            ends=(shade(palette[0], ceiling), shade(palette[1], ceiling)) if palette else None,
            reverse=backwards,
        )
    if motion == KITT:
        beam = _whole(params, "beam_width", 3, 2, 6)
        overlap = _number(params, "overlap", 0.5, 0.1, 1.0)
        return bounce(
            peak,
            floor_color,
            led_count=count,
            step_ms=max(MIN_STEP_MS, int(_travel_step(cycle, count) * (1.3 - 0.6 * overlap))),
            tail_leds=round(2.0 * beam / 3.0, 3),
        )
    if motion == SCANNER:
        # The same bounce with a tighter head and a quicker step: a machine
        # looking for something, where KITT is a machine thinking.
        beam = _whole(params, "beam_width", 1, 1, 4)
        trail = _number(params, "trail", 0.35, 0.0, 1.0)
        return bounce(
            peak,
            floor_color,
            led_count=count,
            step_ms=max(MIN_STEP_MS, int(_travel_step(cycle, count) * 0.7)),
            tail_leds=round(1.0 + 0.5 * (beam - 1) + trail / 0.7, 3),
        )
    if motion == PENDULUM:
        reach = _number(params, "glow", PENDULUM_TAIL_LEDS, 1.0, 3.0)
        return pendulum(peak, floor_color, led_count=count, cycle_ms=cycle, tail_leds=reach)
    if motion == CONVERGE:
        return converge(peak, floor_color, led_count=count, step_ms=_travel_step(cycle, count))
    if motion == BLOOM:
        hold = _number(params, "hold_ratio", 0.0, 0.0, 0.7)
        # Two LEDs have no pairs to open outward, only one rise and one
        # drain, so their step follows the cycle all the way up.
        step = _travel_step(cycle, count) if positional(count) else max(MIN_STEP_MS, cycle // 6)
        return bloom(
            peak,
            floor_color,
            led_count=count,
            step_ms=step,
            hold_ms=int(round(hold * cycle)),
        )
    if motion == STACK:
        backwards = _choice(params, "fill_direction", "forward", ("forward", "reverse")) == "reverse"
        release = _choice(params, "release_behavior", "all_at_once", ("all_at_once", "hold", "decay"))
        return fill(
            peak, floor_color, led_count=count, cycle_ms=cycle, reverse=backwards, release=release
        )
    amplitude = _number(params, "amplitude", 1.0, 0.1, 1.0)
    rest = floor_color if amplitude >= 1.0 else mix(peak, floor_color, amplitude)
    return breath(peak, rest, cycle_ms=cycle)


def _rotated_bands(line: str, peak: str, degrees: float, *, crests: int, led_count: int) -> str:
    """A marquee profile line whose alternate crests are hue-rotated, so the
    bar carries a small palette instead of one colour."""
    from .presentation_policy import _hue_shifted_color

    tokens = line.split()
    count = max(1, int(led_count))
    colors, timing = tokens[:count], tokens[count:]
    other = _hue_shifted_color(peak, degrees)
    waves = max(1, int(crests))
    painted = []
    for index, color in enumerate(colors):
        band = int((index * waves / count) % waves)
        if band % 2 == 1:
            level = max(_channels(color)) / max(1, max(_channels(peak)))
            painted.append(shade(other, level))
        else:
            painted.append(color)
    return " ".join([*painted, *timing])


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
    "SCATTER_STEPS",
    "TIDE_TAIL",
    "bloom",
    "bounce",
    "breath",
    "converge",
    "crossfade",
    "drift",
    "ember",
    "fill",
    "fits",
    "frontier",
    "glint",
    "gradient_wave",
    "lub_dub",
    "mix",
    "positional",
    "program_bytes",
    "raised_cosine",
    "scatter",
    "shade",
    "step_ms_for",
    "travelling_wave",
)
