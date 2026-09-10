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

from dataclasses import dataclass
from enum import Enum
from typing import Final

from .animation import (
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
)

#: A SidePulse Dot is two LEDs. Not a guess, not a setting.
DOT_LED_COUNT: Final = 2

BLACK: Final = "#000000"


class DotRole(str, Enum):
    """The three answers to "what is the Dot for?"."""

    EXTEND = "extend"
    ASKS = "asks"
    STATUS = "status"


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
    """

    ask: str = "#FF9F0A"
    blocked: str = "#FF0000"
    completion: str = "#00FF66"

    def __post_init__(self) -> None:
        for name in ("ask", "blocked", "completion"):
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

    def __post_init__(self) -> None:
        object.__setattr__(self, "ask_count", max(0, int(self.ask_count)))
        object.__setattr__(self, "unseen_completions", max(0, int(self.unseen_completions)))
        object.__setattr__(self, "blocked", bool(self.blocked))
        object.__setattr__(self, "escalation_stage", max(0, min(3, int(self.escalation_stage))))


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
        elif type(step) in (BrightnessStep, RollStep, RepeatStep, CommentStep):
            steps.append(step)
        else:  # pragma: no cover - the union is closed
            steps.append(step)
    try:
        return render_animation(Animation(animation.name, tuple(steps)))
    except Exception:
        return None


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


def plan_dot_surface(
    *,
    role: object,
    semantic: object = None,
    facts: DotBeaconFacts | None = None,
    strip_program: str | None = None,
    strip_led_count: int = 8,
    strip_anchor: float | None = None,
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
    strip's state and should say so. ``strip_anchor`` is not consumed here
    -- the phase lock is the daemon writing both devices from one command
    -- but it is part of the caller's contract and named so the signature
    reads as the whole surface rather than half of it.
    """
    resolved = normalize_dot_role(role)
    if resolved == DotRole.STATUS.value:
        return None
    facts = facts or DotBeaconFacts()

    if resolved == DotRole.ASKS.value:
        program, why, animated = beacon_program(
            facts, colors=colors, include_completions=include_completions
        )
        return DotSurfacePlan(
            program=apply_brightness_line(program, brightness),
            why=why,
            role=resolved,
            led_count=led_count,
            animated=animated,
            reasons=("beacon", f"stage:{facts.escalation_stage}") if animated else ("beacon", "resting"),
        )

    narrowed = downsample_program(
        strip_program or "", source_leds=max(1, int(strip_led_count)), led_count=led_count
    )
    if narrowed is None:
        return None
    why = _WHY_FOR_SEMANTIC.get(str(getattr(semantic, "value", semantic) or ""), "idle")
    return DotSurfacePlan(
        program=apply_brightness_line(narrowed, brightness),
        why=why,
        role=resolved,
        led_count=led_count,
        animated="repeat" in narrowed or "ms" in narrowed,
        reasons=("extend", f"from:{int(strip_led_count)}"),
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
]
