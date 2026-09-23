"""What a linked SidePulse Dot is FOR.

Linked mode used to have exactly one meaning: the Dot is the strip's
continuation. That is one good answer, not the only one. Two LEDs sitting
where the person can see them without turning their head are the best
attention beacon in the room, and spending them on "LEDs 0 and 1 of an
eight-LED wave" throws that away.

So the Dot gets a ROLE:

``extend``
    Today's promise, kept properly: the Dot plays the strip's own program,
    phase-locked, RENDERED FOR TWO LEDS. The strip's eight indices are
    downsampled into two bands (0-3 and 4-7), each band showing its
    brightest lit colour, so a chase still sweeps left to right and a solid
    colour stays that colour. What used to happen -- the strip's raw
    eight-colour text handed to a two-LED device, which parses indices 2..7
    and then discards them -- is why a lit strip could sit next to a Dot
    that looked dead.

``asks``
    A designated attention beacon. Dark (or the device's own resting glow)
    while everything is fine; amber when a session is waiting on the
    person; red when something is blocked or failed; green for an unseen
    completion, only when ``dot_role_include_completions`` is on. A glance
    at the Dot alone answers "do they need me?" -- nothing else can turn it
    on. As an ask ages through the escalation stages the pulse tightens,
    and it goes dark again the moment the ask resolves.

``status``
    The Dot renders its own two-LED semantic display (the binary heartbeat)
    exactly as an unlinked Dot always has. This module claims nothing and
    the daemon falls through to that path.

``call``
    A presence light, the way a busylight is one: a steady red -- no
    flashing, it sits in view of the camera -- while the person is on a call
    (a live microphone, camera or screen share the app reported), and the
    ``asks`` beacon the rest of the time. It works for every call app
    because it reads the devices, not a Teams API, and between calls it
    still says whether an agent needs the person, which no busylight does.

With the lid shut, an ``extend`` Dot has nothing in view to continue: the
strip in the SD slot and the notch band are both behind the closed lid. So
it plays the ``asks`` beacon instead, the only light on the desk that can
still answer "do they need me?", and says so in its reasons.

Everything here is pure: no I/O, no settings object, no controller. The
daemon hands in facts and gets back a program plus the ``why`` the
protocol's ``lights.surfaces.dot`` entry should carry.

Photosensitivity: every program this module emits is built to pass
``presentation_compiler`` untransformed -- phases of at least 500 ms, loop
cycles of at least 1000 ms, so the peak flash rate never exceeds 1 Hz
against the compiler's 2 Hz ceiling (1 Hz for saturated red). The compiler
is still the authority; this module simply never gives it work to do.
"""

from __future__ import annotations

import math
from dataclasses import dataclass
from enum import Enum
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
    normalize_color,
    read_program,
    render_animation,
    step_duration_ms,
)
from .flash_analysis import _paint_transitions
from .led_status import ERROR_RED

#: A SidePulse Dot is two LEDs. Not a guess, not a setting.
DOT_LED_COUNT: Final = 2

BLACK: Final = "#000000"


class DotRole(str, Enum):
    """The answers to "what is the Dot for?"."""

    EXTEND = "extend"
    ASKS = "asks"
    STATUS = "status"
    CALL = "call"


DOT_ROLE_CHOICES: Final = tuple(role.value for role in DotRole)
DEFAULT_DOT_ROLE: Final = DotRole.EXTEND.value

#: Per-device ``led_display`` kinds that are really "the operator picked a
#: dedicated readout for this device". On a Dot whose role is ``extend`` or
#: ``asks`` the role wins, and a stored value from before roles existed is
#: migrated once (``migrated_role_for_display``).
_DISPLAY_TO_ROLE: Final = {
    "quota_runway": DotRole.STATUS.value,
    "studio": DotRole.STATUS.value,
    "battery": DotRole.STATUS.value,
}


class DotRoleError(ValueError):
    """A caller handed this module something it will not guess about."""


def normalize_dot_role(value: object) -> str:
    """Any stored or wire value to one of ``DOT_ROLE_CHOICES``.

    Unknown, missing and malformed all mean ``extend``: the Dot keeps doing
    what it did before roles existed rather than going dark on a typo.
    """
    if isinstance(value, DotRole):
        return value.value
    text = str(value or "").strip().lower()
    return text if text in DOT_ROLE_CHOICES else DEFAULT_DOT_ROLE


def migrated_role_for_display(led_display: object) -> str | None:
    """The one-time migration of a per-device Dot ``led_display`` into a role.

    A Dot that was pinned to a dedicated readout (quota runway, Effect
    Studio, battery) meant "do not follow the strip"; that intent survives
    as ``status``. Everything else -- ``agent`` above all -- carried no
    opinion and is left alone (``None``, "do not migrate").
    """
    text = str(led_display or "").strip().lower()
    return _DISPLAY_TO_ROLE.get(text)


@dataclass(frozen=True, slots=True)
class DotRoleColors:
    """The beacon's vocabulary. Three states, three colours, no gradients.

    ``ask`` is a true amber rather than the product's ``ASK_AMBER``
    (#FF3A00): on two LEDs a red-orange is indistinguishable from the
    blocked red beside it, and #FF3A00 is a saturated red to the
    presentation compiler, which would cap the pulse at 1 Hz for a reason
    that has nothing to do with this surface.

    ``blocked`` is now the shared ``ERROR_RED`` rather than this file's own
    #FF0000 literal. The Dot had solved the ask/blocked collision locally
    and privately, which is why the strip, the pad and the app kept it: the
    separation is a product-wide constant now, and this surface reads it
    from the same place everything else does. #B00020 is also NOT a
    saturated red to the compiler (#FF0000 was), so the blocked pulse is no
    longer sitting exactly on the 1 Hz ceiling it was measured against --
    see _ESCALATION_CADENCES, which needed no change either way.
    """

    ask: str = "#FF9F0A"
    blocked: str = ERROR_RED
    completion: str = "#00FF66"
    #: The ``call`` role's steady busylight red. Held, never pulsed, so it
    #: is told apart from the blocked pulse by motion as well as hue.
    on_call: str = "#FF2D20"

    def __post_init__(self) -> None:
        for name in ("ask", "blocked", "completion", "on_call"):
            value = getattr(self, name)
            try:
                object.__setattr__(self, name, normalize_color(value))
            except Exception as error:  # pragma: no cover - defensive
                raise DotRoleError(f"dot role colour {name} must be #RRGGBB") from error


DEFAULT_DOT_ROLE_COLORS: Final = DotRoleColors()


@dataclass(frozen=True, slots=True)
class DotBeaconFacts:
    """What the daemon knows about whether a person is needed right now."""

    #: Sessions currently waiting on the person (permission prompts, asks).
    ask_count: int = 0
    #: A blocked error or failed session is present.
    blocked: bool = False
    #: Completions the person has not looked at yet.
    unseen_completions: int = 0
    #: ``signals.escalation_stage`` for the oldest unanswered ask, 0-3.
    escalation_stage: int = 0
    #: The person is on a call (jrbar.presence), for the ``call`` role.
    on_call: bool = False
    #: The lid is shut: an ``extend`` Dot has nothing in view to continue.
    lid_closed: bool = False

    def __post_init__(self) -> None:
        object.__setattr__(self, "ask_count", max(0, int(self.ask_count)))
        object.__setattr__(self, "unseen_completions", max(0, int(self.unseen_completions)))
        object.__setattr__(self, "blocked", bool(self.blocked))
        object.__setattr__(self, "escalation_stage", max(0, min(3, int(self.escalation_stage))))
        object.__setattr__(self, "on_call", bool(self.on_call))
        object.__setattr__(self, "lid_closed", bool(self.lid_closed))


@dataclass(frozen=True, slots=True)
class DotSurfacePlan:
    """The Dot's two-LED program and the reason it looks like that."""

    program: str
    why: str
    role: str
    led_count: int = DOT_LED_COUNT
    animated: bool = False
    #: Machine-readable notes for the log and the protocol's ``why_detail``.
    reasons: tuple[str, ...] = ()
    #: The skew this program was re-anchored by, in milliseconds.
    corrected_ms: float = 0.0


# Escalation is meant to be VISIBLE without ever becoming a hazard. Each
# stage is (on_ms, off_ms); the cycle is their sum, so the peak flash rate
# runs 0.42 Hz -> 0.56 Hz -> 0.83 Hz -> 1.0 Hz. The slowest is a breath,
# the fastest is a knock, and even the fastest sits at half the
# presentation compiler's 2 Hz ceiling and exactly at its 1 Hz saturated-red
# ceiling, so the red blocked pulse needs no separate table.
_ESCALATION_CADENCES: Final = (
    (1200, 1200),
    (900, 900),
    (600, 600),
    (500, 500),
)
#: Blocked is not an ask that aged; it starts at the urgency an ask reaches
#: only after the menu-bar stage.
_BLOCKED_CADENCE_STAGE: Final = 2
#: An unseen completion is news, not a demand: one slow breath, always.
_COMPLETION_CADENCE_STAGE: Final = 0


def _luma(color: str) -> float:
    """Rec. 709 relative luminance, for choosing a band's representative."""
    try:
        text = normalize_color(color)
    except Exception:
        return -1.0
    red, green, blue = (int(text[index : index + 2], 16) for index in (1, 3, 5))
    return 0.2126 * red + 0.7152 * green + 0.0722 * blue


def _band_bounds(source_leds: int, led_count: int) -> tuple[tuple[int, int], ...]:
    """Contiguous, near-equal source ranges, one per destination LED."""
    return tuple(
        (index * source_leds // led_count, (index + 1) * source_leds // led_count)
        for index in range(led_count)
    )


def _band_for_index(index: int, bounds: tuple[tuple[int, int], ...]) -> int | None:
    for band, (start, stop) in enumerate(bounds):
        if start <= index < stop:
            return band
    return None


def _earliest(left: int | None, right: int | None) -> int | None:
    """The earlier of two delays; ``None`` means "no delay", the earliest."""
    if left is None or right is None:
        return None
    return min(left, right)


def _brightest(colors: tuple[str, ...]) -> str:
    """The colour a band shows: its brightest lit member, else black.

    Not an average. Averaging a chase produces a permanent dim smear that
    never moves; taking the brightest keeps the wave's shape -- the band
    lights when the wave is inside it and goes dark when it leaves.
    """
    best = BLACK
    best_luma = 0.0
    for color in colors:
        value = _luma(color)
        if value > best_luma:
            best, best_luma = normalize_color(color), value
    return best


def downsample_segment(segment, *, source_leds: int, led_count: int = DOT_LED_COUNT):
    """One paint segment re-rendered for a narrower device.

    ``WholeBar`` needs no work: "every LED" means every LED on whatever is
    listening. ``ColorList`` and ``IndexedPaint`` are banded. Indexed paint
    keeps indexed form so its "unmentioned LEDs hold" rule survives -- but
    see ``downsample_step``: what an unmentioned band holds is resolved from
    the SOURCE program, never from whatever the device happened to be
    showing.
    """
    bounds = _band_bounds(source_leds, led_count)
    if type(segment) is WholeBar:
        return segment
    if type(segment) is ColorList:
        colors = tuple(
            _brightest(segment.colors[start:stop]) for start, stop in bounds
        )
        return ColorList(colors=colors, timing=segment.timing)
    if type(segment) is IndexedPaint:
        by_band: dict[int, str] = {}
        for index, color in segment.assignments:
            band = _band_for_index(int(index), bounds)
            if band is None:
                continue
            current = by_band.get(band)
            if current is None or _luma(color) > _luma(current):
                by_band[band] = normalize_color(color)
        return IndexedPaint(
            assignments=tuple(sorted(by_band.items())),
            timing=segment.timing,
        )
    return segment


def _paint_source_state(step: PaintStep, *, source_leds: int, state: list[str]) -> list[str]:
    """The source strip's own per-index colours after one paint LINE.

    Pure: it starts from black at line one and only ever reads the program
    it was handed, so nothing an EARLIER program left on the device can
    reach the conversion. That was the second half of the live defect -- an
    unaddressed LED holding a colour from the Dot's previous program, which
    then looked like the converter had invented a colour.
    """
    after = list(state)
    for segment in step.segments:
        if type(segment) is WholeBar:
            color = BLACK if segment.color == OFF else normalize_color(segment.color)
            after = [color] * source_leds
        elif type(segment) is ColorList:
            # The firmware's rule: LEDs past the list go dark.
            colors = [normalize_color(color) for color in segment.colors]
            after = [
                colors[index] if index < len(colors) else BLACK
                for index in range(source_leds)
            ]
        elif type(segment) is IndexedPaint:
            for index, color in segment.assignments:
                position = int(index)
                if 0 <= position < source_leds:
                    after[position] = normalize_color(color)
    return after


def _addressed_bands(segments, led_count: int) -> set[int]:
    """Which destination LEDs a rendered line actually paints.

    A ``WholeBar`` and a ``ColorList`` both paint every LED (the list's rule
    is that LEDs past it go dark, which is still an instruction). Indexed
    paint only claims what it names.
    """
    addressed: set[int] = set()
    for segment in segments:
        if type(segment) in (WholeBar, ColorList):
            return set(range(led_count))
        if type(segment) is IndexedPaint:
            addressed.update(int(index) for index, _color in segment.assignments)
    return addressed


def downsample_step(
    step: PaintStep,
    *,
    source_leds: int,
    led_count: int = DOT_LED_COUNT,
    resolved: tuple[str, ...] | None = None,
) -> PaintStep:
    """One paint LINE re-rendered, not one segment at a time.

    A renderer that writes ``0:#RRGGBB; 1:#RRGGBB; ...`` emits eight
    separate indexed segments on one line. Narrowing each in isolation
    produces eight segments that all address band 0 or band 1 -- the same
    LED painted four times, last write winning, which is not the brightest
    and is not what the strip is showing.

    So indexed segments are merged by SHAPE -- the same duration and
    easing -- and each band keeps its brightest colour at its earliest
    delay. Delay is the strip's staggering, and collapsing four staggered
    pulses onto one LED is exactly the flicker the presentation compiler
    warns about; keeping the earliest turns a wave crossing four LEDs into
    one pulse crossing one band, which is what the wave looks like from
    across the room anyway.

    Then the line is made TOTAL. ``resolved`` is what every band shows
    according to the source program at this line; any band the merged
    segments did not name is painted with it explicitly. Without that a
    band could be addressed on line one and never again -- the live defect
    of 2026-09-10, where the Dot's second LED held a green from a finished
    program "forever" because no later line ever mentioned it.
    """
    bounds = _band_bounds(source_leds, led_count)
    slots: list[object] = []
    # (duration_ms, easing) -> band -> (colour, earliest delay)
    merged: dict[tuple[int | None, str | None], dict[int, tuple[str, int | None]]] = {}
    for segment in step.segments:
        if type(segment) is IndexedPaint:
            shape = (segment.timing.duration_ms, segment.timing.easing)
            table = merged.get(shape)
            if table is None:
                table = merged[shape] = {}
                slots.append(shape)
            delay = segment.timing.delay_ms
            for index, color in segment.assignments:
                band = _band_for_index(int(index), bounds)
                if band is None:
                    continue
                current = table.get(band)
                if current is None:
                    table[band] = (normalize_color(color), delay)
                    continue
                color_now = (
                    normalize_color(color) if _luma(color) > _luma(current[0]) else current[0]
                )
                delay_now = _earliest(current[1], delay)
                table[band] = (color_now, delay_now)
            continue
        slots.append(
            downsample_segment(segment, source_leds=source_leds, led_count=led_count)
        )
    segments: list[object] = []
    for slot in slots:
        if not isinstance(slot, tuple):
            segments.append(slot)
            continue
        duration_ms, easing = slot
        table = merged[slot]
        # One segment per distinct delay: a band that starts later still
        # starts later, it just no longer drags three redundant copies.
        for delay in sorted({entry[1] for entry in table.values()}, key=lambda value: (value is None, value)):
            assignments = tuple(
                sorted((band, color) for band, (color, band_delay) in table.items() if band_delay == delay)
            )
            if not assignments:
                continue
            segments.append(
                IndexedPaint(
                    assignments=assignments,
                    timing=Timing(duration_ms=duration_ms, easing=easing, delay_ms=delay),
                )
            )
    if resolved is not None and segments:
        missing = sorted(set(range(led_count)) - _addressed_bands(segments, led_count))
        if missing:
            segments.append(
                IndexedPaint(
                    assignments=tuple(
                        (band, resolved[band] if band < len(resolved) else BLACK)
                        for band in missing
                    ),
                    # No delay, and never longer than the line already is, so
                    # making the line total cannot re-time the animation.
                    timing=Timing(duration_ms=_line_duration_ms(segments)),
                )
            )
    return PaintStep(segments=tuple(segments))


def _line_duration_ms(segments) -> int | None:
    """The longest duration already on this line, so a fill matches it."""
    durations = [
        segment.timing.duration_ms
        for segment in segments
        if getattr(segment, "timing", None) is not None
        and segment.timing.duration_ms is not None
    ]
    return max(durations) if durations else None


def _line_span_ms(segments) -> int:
    """When a paint line finishes: the longest delay-plus-duration on it.

    ``Timing.span_ms`` already knows the firmware's clock -- an easing with
    no duration runs 330 ms, a bare timing one 60 Hz frame -- so this is
    only the max over the line's segments.
    """
    return max(
        (
            segment.timing.span_ms
            for segment in segments
            if getattr(segment, "timing", None) is not None
        ),
        default=0,
    )


def downsample_program(
    program: str,
    *,
    source_leds: int,
    led_count: int = DOT_LED_COUNT,
) -> str | None:
    """A strip program re-rendered for ``led_count`` LEDs, or ``None``.

    ``None`` means "this text is not something I can honestly narrow" --
    the caller must refuse the write rather than send bytes addressed to
    LEDs that are not there. Timing, easing, delays, rolls, repeats and
    brightness are carried through untouched: the Dot stays phase-locked to
    the strip because it is running the same clock, not a re-timed copy.

    Two invariants hold over everything this returns, and
    ``tests/test_dot_role.py`` asserts both over the whole effect corpus:

    * every LED the destination device has is addressed on every paint line
      (or the line paints the whole strip at once), so nothing is painted
      once and then stranded; and
    * it is a pure function of ``program`` -- the source's own per-index
      state is resolved here, from black, so no colour a previous program
      left on the device can appear in the output.
    """
    if not isinstance(program, str) or not program.strip():
        return None
    source_leds = max(1, int(source_leds))
    led_count = max(1, int(led_count))
    animation, problems = read_program(
        program, led_count=max(source_leds, led_count)
    )
    if errors_only(problems):
        return None
    bounds = _band_bounds(max(source_leds, led_count), led_count)
    state = [BLACK] * max(source_leds, led_count)
    steps: list[object] = []
    for step in animation.steps:
        if type(step) is PaintStep:
            state = _paint_source_state(step, source_leds=max(source_leds, led_count), state=state)
            resolved = tuple(
                _brightest(tuple(state[start:stop])) for start, stop in bounds
            )
            narrowed = downsample_step(
                step,
                source_leds=max(source_leds, led_count),
                led_count=led_count,
                resolved=resolved,
            )
            if not narrowed.segments:
                return None
            steps.append(narrowed)
            # The earliest-delay merge shortens a staggered line, and a
            # shorter line loops faster: the Dot drifts off the strip's
            # clock the first lap. The hold line paints every band with
            # the colour the source line left it on and sits for the
            # missing span -- visually a pause, arithmetically the same
            # period.
            shortfall = _line_span_ms(step.segments) - _line_span_ms(narrowed.segments)
            if shortfall > 0:
                steps.append(
                    PaintStep(
                        segments=(
                            IndexedPaint(
                                assignments=tuple(
                                    (
                                        band,
                                        resolved[band]
                                        if band < len(resolved)
                                        else BLACK,
                                    )
                                    for band in range(led_count)
                                ),
                                timing=Timing(
                                    duration_ms=min(shortfall, MAX_TIME_MS),
                                    easing="none",
                                ),
                            ),
                        )
                    )
                )
        elif type(step) in (BrightnessStep, RollStep, RepeatStep, CommentStep):
            steps.append(step)
        else:  # pragma: no cover - the union is closed
            steps.append(step)
    try:
        return render_animation(Animation(animation.name, tuple(steps)))
    except Exception:
        return None


def upsample_segment(segment, *, source_leds: int, led_count: int):
    """One paint segment re-rendered for a wider device, or ``None``.

    Destination LED ``j`` takes source LED ``j * source_leds // led_count``:
    each source LED claims a contiguous run, so the Dot's two colours land
    on the bar as two bands of four. ``None`` is an indexed segment that
    names no destination LED -- the caller drops it the way the firmware
    drops a line that addresses nothing.
    """
    if type(segment) is WholeBar:
        return segment
    if type(segment) is ColorList:
        colors = tuple(
            segment.colors[band] if band < len(segment.colors) else BLACK
            for band in (
                led * source_leds // led_count for led in range(led_count)
            )
        )
        return ColorList(colors=colors, timing=segment.timing)
    if type(segment) is IndexedPaint:
        by_led: dict[int, str] = {}
        for index, color in segment.assignments:
            position = int(index)
            if position < 0 or position >= source_leds:
                continue
            for led in range(led_count):
                if led * source_leds // led_count == position:
                    by_led[led] = normalize_color(color)
        if not by_led:
            return None
        return IndexedPaint(
            assignments=tuple(sorted(by_led.items())),
            timing=segment.timing,
        )
    return segment


def upsample_program(
    program: str,
    *,
    source_leds: int,
    led_count: int,
) -> str | None:
    """A narrow program re-rendered for ``led_count`` LEDs, or ``None``.

    The Screen Bar mirroring a lone Dot: the Dot's two LEDs each claim a
    contiguous run of the bar's eight, so a two-colour pulse still reads as
    two colours. ``None`` means "this text is not something I can honestly
    widen" -- the caller keeps its own render rather than play a wrong one.

    The inverse of ``downsample_program``, and simpler than it: expansion
    is one-to-many, so no band is ever left unaddressed and no "make
    total" pass is needed. Brightness, roll, repeat and comment lines pass
    through untouched -- the bar runs the same clock as the Dot.
    """
    if not isinstance(program, str) or not program.strip():
        return None
    source_leds = max(1, int(source_leds))
    led_count = max(1, int(led_count))
    animation, problems = read_program(
        program, led_count=max(source_leds, led_count)
    )
    if errors_only(problems):
        return None
    steps: list[object] = []
    for step in animation.steps:
        if type(step) is PaintStep:
            widened = [
                segment
                for segment in (
                    upsample_segment(
                        original, source_leds=source_leds, led_count=led_count
                    )
                    for original in step.segments
                )
                if segment is not None
            ]
            if widened:
                steps.append(PaintStep(segments=tuple(widened)))
            # A line that named only LEDs the source does not have took no
            # time on either device; dropping it is exact.
        elif type(step) in (BrightnessStep, RollStep, RepeatStep, CommentStep):
            steps.append(step)
        else:  # pragma: no cover - the union is closed
            steps.append(step)
    try:
        rendered = render_animation(Animation(animation.name, tuple(steps)))
    except Exception:
        return None
    return rendered if rendered.strip() else None


def beacon_program(
    facts: DotBeaconFacts,
    *,
    colors: DotRoleColors = DEFAULT_DOT_ROLE_COLORS,
    include_completions: bool = False,
) -> tuple[str, str, bool]:
    """``(program, why, animated)`` for the ``asks`` role.

    Precedence is the person's, not the machine's: something that is stuck
    outranks something that is waiting, which outranks something that
    merely finished. Nothing else lights this surface at all.
    """
    if facts.blocked:
        return (
            _pulse(colors.blocked, _BLOCKED_CADENCE_STAGE),
            "failed",
            True,
        )
    if facts.ask_count > 0:
        return (
            _pulse(colors.ask, facts.escalation_stage),
            "waiting",
            True,
        )
    if include_completions and facts.unseen_completions > 0:
        return (
            _pulse(colors.completion, _COMPLETION_CADENCE_STAGE),
            "completed",
            True,
        )
    # Dark. The device's own resting glow (settings.devices[].resting_glow)
    # turns this into the faint ember if the operator asked for one -- the
    # controller substitutes it on every `off` and every #000000, so the
    # beacon obeys the same resting-glow policy as the strip without
    # knowing what it is.
    return "off", "idle", False


def _pulse(color: str, stage: int) -> str:
    """One colour breathing at the cadence for ``stage``.

    ``cosine`` on both phases is what makes it a breath rather than a
    blink: the firmware ramps between the two, so there is no instantaneous
    luminance step for a photosensitive viewer to catch.
    """
    on_ms, off_ms = _ESCALATION_CADENCES[max(0, min(len(_ESCALATION_CADENCES) - 1, int(stage)))]
    return f"{normalize_color(color)} {on_ms}ms cosine\noff {off_ms}ms cosine\nrepeat"


def apply_brightness_line(program: str, brightness: int | None) -> str:
    """A ``brightness N`` line in front, the firmware's last-one-wins rule
    respected by removing any the body already carried."""
    if brightness is None:
        return program
    value = max(0, min(255, int(round(float(brightness)))))
    kept = [
        line
        for line in program.splitlines()
        if line.strip().split()[:1] != ["brightness"]
    ]
    body = "\n".join(kept)
    return body if value >= 255 else f"brightness {value}\n{body}"


#: The largest skew a linked write will bake into the Dot's program. A gap
#: bigger than this is not write latency -- it is a stuck worker or a batch
#: that did not couple -- and re-sequencing the loop by half a second would
#: be a confident fix for a problem nobody measured.
LINKED_SKEW_SHIFT_MAX_MS: Final = 250.0


def _rgb_to_hex(color: tuple[int, int, int]) -> str:
    red, green, blue = color
    return f"#{max(0, min(255, int(red))):02X}{max(0, min(255, int(green))):02X}{max(0, min(255, int(blue))):02X}"


def _ms(value: float) -> int:
    """A positive duration in whole ms -- zero is not a legal duration."""
    return max(1, int(round(value)))


def _delay_ms(value: float) -> int | None:
    """A delay token, omitted when it rounds away."""
    rounded = int(round(value))
    return rounded if rounded >= 1 else None


def _played_state(steps, state: list, led_count: int) -> list:
    """The per-LED resting colours a run of steps leaves behind.

    A roll is skipped rather than modelled: it slides the arrangement one
    full wraparound and ends exactly where it began, so the state it leaves
    is the state it found.
    """
    state = list(state)
    for step in steps:
        if type(step) is not PaintStep:
            continue
        for led, transition in _paint_transitions(step, state, led_count).items():
            if 0 <= led < led_count:
                state[led] = transition.resting
    return state


def _split_paint_step(
    step: PaintStep, within_ms: float, *, state: list, led_count: int
) -> tuple[PaintStep, PaintStep] | None:
    """``(tail, head)`` steps: ``[within, span)`` of the line, then ``[0, within)``.

    The tail plays where the rotated loop starts; the head plays where it
    wraps. Per-LED the transition the cut lands in decides the emission:
    untouched transitions keep their shape with less delay, finished ones
    hold their resting colour, and a mid-flight one continues toward its
    target with what's left of its window. ``None`` is the honest refusal:
    a ``pulse`` cut mid-flight cannot be spelled in the DSL.
    """
    span = step_duration_ms(step)
    transitions = _paint_transitions(step, list(state), led_count)
    tail: list[IndexedPaint] = []
    head: list[IndexedPaint] = []
    for led in range(led_count):
        transition = transitions.get(led)
        start = state[led]
        at_cut = transition.at(within_ms) if transition is not None else start
        if transition is None or within_ms >= transition.delay_ms + transition.duration_ms:
            resting = transition.resting if transition is not None else start
            tail.append(
                IndexedPaint(
                    assignments=((led, _rgb_to_hex(resting)),),
                    timing=Timing(duration_ms=_ms(span - within_ms)),
                )
            )
        elif within_ms <= transition.delay_ms:
            tail.append(
                IndexedPaint(
                    assignments=((led, _rgb_to_hex(transition.target)),),
                    timing=Timing(
                        duration_ms=_ms(transition.duration_ms),
                        easing=transition.easing,
                        delay_ms=_delay_ms(transition.delay_ms - within_ms),
                    ),
                )
            )
        else:
            if transition.easing == "pulse":
                return None
            tail.append(
                IndexedPaint(
                    assignments=((led, _rgb_to_hex(transition.target)),),
                    timing=Timing(
                        duration_ms=_ms(
                            transition.delay_ms + transition.duration_ms - within_ms
                        ),
                        easing=transition.easing,
                    ),
                )
            )
        if (
            transition is not None
            and within_ms >= transition.delay_ms + transition.duration_ms
        ):
            # The transition finished inside the head -- replay it verbatim,
            # pulses and all, and let it hold to the line's end.
            head.append(
                IndexedPaint(
                    assignments=((led, _rgb_to_hex(transition.target)),),
                    timing=Timing(
                        duration_ms=_ms(transition.duration_ms),
                        easing=transition.easing,
                        delay_ms=_delay_ms(transition.delay_ms),
                    ),
                )
            )
        elif transition is None or at_cut == start:
            head.append(
                IndexedPaint(
                    assignments=((led, _rgb_to_hex(start)),),
                    timing=Timing(duration_ms=_ms(within_ms)),
                )
            )
        elif transition.easing == "pulse":
            return None
        else:
            head.append(
                IndexedPaint(
                    assignments=((led, _rgb_to_hex(at_cut)),),
                    timing=Timing(
                        duration_ms=_ms(within_ms - min(transition.delay_ms, within_ms)),
                        easing=transition.easing,
                        delay_ms=_delay_ms(min(transition.delay_ms, within_ms)),
                    ),
                )
            )
    head_span = max((segment.timing.span_ms for segment in head), default=0)
    if head and head_span < within_ms - 0.5:
        # Every transition finished before the cut: no segment reaches the
        # boundary, so the line would end early and shorten the lap. The
        # last-finishing LED stretches its ramp to the edge instead.
        led = max(
            range(led_count),
            key=lambda index: (
                transitions[index].delay_ms + transitions[index].duration_ms
                if index in transitions
                else 0
            ),
        )
        transition = transitions.get(led)
        resting = transition.resting if transition is not None else state[led]
        delay = min(transition.delay_ms, within_ms) if transition is not None else 0.0
        head[led] = IndexedPaint(
            assignments=((led, _rgb_to_hex(resting)),),
            timing=Timing(
                duration_ms=_ms(within_ms - delay),
                easing="ease" if transition is not None else None,
                delay_ms=_delay_ms(delay),
            ),
        )
    return PaintStep(tuple(tail)), PaintStep(tuple(head))


def shift_program_phase(
    program: str,
    shift_ms: float,
    *,
    led_count: int = DOT_LED_COUNT,
) -> str | None:
    """The same program re-anchored ``shift_ms`` earlier, or ``None``.

    A linked Dot is written ``skew`` milliseconds after its strip, and the
    firmware starts every program at its own write -- the Dot's restart is
    that many milliseconds late, every lap, forever. Re-sequencing the loop
    so it begins ``shift_ms`` in is the same cycle from the same instant
    the strip's write landed, and it is the only shift the hardware can
    actually run: no directive can reach back and start a program early,
    and ``repeat`` always loops from step one, so the rotated body itself
    has to carry the phase.

    ``None`` means the text is not something this can honestly re-time --
    the cut lands on a ``roll`` or inside a ``pulse`` -- and the caller
    writes the unshifted program rather than a wrong one. The program
    itself comes back unchanged when the shift is too small to matter or
    lands on the loop boundary.
    """
    if not isinstance(program, str) or not program.strip():
        return None
    try:
        shift_ms = float(shift_ms)
    except (TypeError, ValueError):
        return None
    if not math.isfinite(shift_ms) or abs(shift_ms) < 0.5:
        return program
    animation, problems = read_program(program, led_count=led_count)
    if animation is None or errors_only(problems):
        return None
    steps = list(animation.steps)
    repeat_at = next(
        (index for index, step in enumerate(steps) if type(step) is RepeatStep), None
    )
    if repeat_at is not None:
        if any(type(step) is RepeatStep for step in steps[:repeat_at]):
            return None
        if steps[repeat_at + 1 :]:
            return None
        count = steps[repeat_at].count
        body = steps[:repeat_at]
    else:
        count = None
        body = steps
    total = sum(step_duration_ms(step) for step in body)
    if total <= 0:
        return None
    if repeat_at is not None:
        offset = shift_ms % total
    else:
        offset = shift_ms
        # A one-shot can only start late into itself: a negative shift would
        # have to start the program before it exists.
        if offset <= 0 or offset >= total:
            return None
    if offset == 0:
        return program
    elapsed = 0.0
    index = -1
    within = 0.0
    for position, step in enumerate(body):
        span = step_duration_ms(step)
        if offset < elapsed + span:
            index, within = position, offset - elapsed
            break
        elapsed += span
    if index < 0:  # pragma: no cover - offset < total guarantees a home
        return None
    split = None
    if within > 0.0:
        step = body[index]
        if type(step) is not PaintStep:
            return None
        # Steady state: the state a loop's step is really entered in is what
        # a lap leaves behind, not the black a cold start begins from.
        state = [(0, 0, 0)] * led_count
        if repeat_at is not None:
            state = _played_state(body, state, led_count)
        state = _played_state(body[:index], state, led_count)
        split = _split_paint_step(step, within, state=state, led_count=led_count)
        if split is None:
            return None
    if repeat_at is not None:
        rotated = (
            ([split[0]] if split else [body[index]])
            + body[index + 1 :]
            + body[:index]
            + ([split[1]] if split else [])
            + [RepeatStep(count=count)]
        )
    else:
        # A one-shot joins mid-program: what the cut skipped never plays,
        # except the brightness and comment lines that still mean something.
        prefix = [
            step
            for step in body[:index]
            if type(step) in (BrightnessStep, CommentStep)
        ]
        rotated = prefix + ([split[0]] if split else []) + body[index + 1 :]
        if split is None:
            rotated = prefix + body[index:]
    try:
        return render_animation(Animation(animation.name, tuple(rotated)))
    except Exception:
        return None


def plan_dot_surface(
    *,
    role: object,
    semantic: object = None,
    facts: DotBeaconFacts | None = None,
    strip_program: str | None = None,
    strip_led_count: int = 8,
    skew_correction_ms: float | None = None,
    brightness: int | None = None,
    colors: DotRoleColors = DEFAULT_DOT_ROLE_COLORS,
    include_completions: bool = False,
    led_count: int = DOT_LED_COUNT,
) -> DotSurfacePlan | None:
    """The Dot's whole surface for this instant, or ``None`` to fall through.

    ``None`` is a real answer with two meanings, and both mean "this module
    is not driving the Dot right now": the role is ``status`` (the Dot owns
    its own display), or the role is ``extend`` and there is no strip
    program that can be narrowed honestly.

    ``semantic`` is the resolved glance's semantic value; it only ever
    supplies the ``why`` for ``extend``, because ``extend`` shows the
    strip's state and should say so. ``skew_correction_ms`` is the rolling
    median of measured write gaps between the pair. A nonzero correction
    re-times the narrowed program ``shift`` milliseconds in -- the Dot
    writes late but plays the phase the strip is on -- and the plan reports
    the shift it baked in (``corrected_ms``). The published program is
    already rotated, so its true on-device start is the Dot's own write
    completion pulled back by the shift; the runtime derives that anchor
    from the write result, not from anything the plan could guess.
    """
    resolved = normalize_dot_role(role)
    if resolved == DotRole.STATUS.value:
        return None
    facts = facts or DotBeaconFacts()

    if resolved == DotRole.CALL.value and facts.on_call:
        # Held, not breathed: the Dot is in view of the camera, and a
        # busylight that pulses is a distraction to the other side too.
        return DotSurfacePlan(
            program=apply_brightness_line(normalize_color(colors.on_call), brightness),
            why="on_call",
            role=resolved,
            led_count=led_count,
            animated=False,
            reasons=("presence", "on_call"),
        )

    auto_asks = resolved == DotRole.EXTEND.value and facts.lid_closed
    if resolved in (DotRole.ASKS.value, DotRole.CALL.value) or auto_asks:
        program, why, animated = beacon_program(
            facts, colors=colors, include_completions=include_completions
        )
        reasons = ("beacon", f"stage:{facts.escalation_stage}") if animated else ("beacon", "resting")
        if auto_asks:
            reasons = (*reasons, "auto:lid_closed")
        return DotSurfacePlan(
            program=apply_brightness_line(program, brightness),
            why=why,
            role=DotRole.ASKS.value if auto_asks else resolved,
            led_count=led_count,
            animated=animated,
            reasons=reasons,
        )

    narrowed = downsample_program(
        strip_program or "", source_leds=max(1, int(strip_led_count)), led_count=led_count
    )
    if narrowed is None:
        return None
    corrected_ms = 0.0
    if skew_correction_ms:
        shift = max(
            -LINKED_SKEW_SHIFT_MAX_MS,
            min(LINKED_SKEW_SHIFT_MAX_MS, float(skew_correction_ms)),
        )
        shifted = shift_program_phase(narrowed, shift, led_count=led_count)
        if shifted is not None and shifted != narrowed:
            narrowed = shifted
            corrected_ms = shift
    why = _WHY_FOR_SEMANTIC.get(str(getattr(semantic, "value", semantic) or ""), "idle")
    reasons = ["extend", f"from:{int(strip_led_count)}"]
    if corrected_ms:
        reasons.append(f"skew:{int(round(corrected_ms))}")
    return DotSurfacePlan(
        program=apply_brightness_line(narrowed, brightness),
        why=why,
        role=resolved,
        led_count=led_count,
        animated="repeat" in narrowed or "ms" in narrowed,
        reasons=tuple(reasons),
        corrected_ms=corrected_ms,
    )


#: The same table ``core_projection.why_for_glance`` uses; duplicated as a
#: literal rather than imported so this module stays free of the projection
#: layer. ``tests/test_dot_role.py`` asserts the two never drift.
_WHY_FOR_SEMANTIC: Final = {
    "attention": "waiting",
    "fresh_completion": "completed",
    "active": "working",
    "rest": "idle",
    "fresh_failure": "failed",
    "unresolved_failure": "failed",
    "capacity": "capacity",
}


__all__ = [
    "BLACK",
    "DEFAULT_DOT_ROLE",
    "DEFAULT_DOT_ROLE_COLORS",
    "DOT_LED_COUNT",
    "DOT_ROLE_CHOICES",
    "LINKED_SKEW_SHIFT_MAX_MS",
    "DotBeaconFacts",
    "DotRole",
    "DotRoleColors",
    "DotRoleError",
    "DotSurfacePlan",
    "apply_brightness_line",
    "beacon_program",
    "downsample_program",
    "downsample_segment",
    "migrated_role_for_display",
    "normalize_dot_role",
    "plan_dot_surface",
    "shift_program_phase",
    "upsample_program",
    "upsample_segment",
]
