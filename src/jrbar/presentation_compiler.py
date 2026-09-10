"""Mandatory temporal-safety compiler for every JR-Bar light surface.

The rule this enforces is the accessibility one, not a typographic one. A
*flash* is a reversal of the field's luminance -- most of the strip getting
brighter and then darker again -- and what is limited is how many of those
happen per second. Motion is not flashing: a head sliding along the strip
changes any given LED constantly while the field it occupies barely moves, so
``flash_analysis`` renders the program and measures the reversal rate instead
of inferring one from step durations.

What that means for an author, in order:

* A per-LED (``0:#RRGGBB``) paint keeps whatever phase it was written with.
  Staggered indexed segments are how every travelling shape is built, and a
  floor on their phase is a floor on how fast light may move -- which is not
  a hazard and was making sweeps look like blinks.
* A field-wide paint (a whole-bar colour or a colour list) inside a loop still
  gets a phase floor when it was written without one, because an untimed
  field-wide paint is a strobe frame.
* Whatever the text says, the compiled loop is rendered and its measured flash
  rate must sit at or under ``MAX_PRESENTATION_HZ`` -- ``MAX_SATURATED_RED_HZ``
  when saturated red is on screen. A loop that flashes faster is slowed by a
  whole-number factor until it does not, which preserves its shape exactly.
* The loop is never shorter than ``MIN_PRESENTATION_CYCLE_MS``.

Nothing is ever refused for being too lively; it is slowed. A refusal would
leave the strip frozen on whatever it was showing, which is worse than a
slower version of what the author asked for.
"""

from __future__ import annotations

import math
from dataclasses import dataclass, replace
from functools import lru_cache

from . import flash_analysis
from .animation import (
    Animation,
    AnimationValidationError,
    ColorList,
    IndexedPaint,
    PaintStep,
    RepeatStep,
    RollStep,
    Timing,
    WholeBar,
    errors_only,
    read_program,
    render_animation,
    validate_animation,
)

MAX_PRESENTATION_HZ = 2.0
MIN_PRESENTATION_CYCLE_MS = 500
MIN_PRESENTATION_PHASE_MS = 250
MAX_SATURATED_RED_HZ = 1.0
MIN_SATURATED_RED_CYCLE_MS = 1000
MIN_SATURATED_RED_PHASE_MS = 500
SAFE_FALLBACK_PROGRAM = "off"
MAX_TIME_MS = 65535


@dataclass(frozen=True, slots=True)
class PresentationCompileResult:
    program: str
    accepted: bool
    transformed: bool
    reasons: tuple[str, ...]


class PresentationSafetyError(ValueError):
    pass


def _is_saturated_red(color: str) -> bool:
    if not isinstance(color, str) or not color.startswith("#") or len(color) != 7:
        return False
    try:
        red, green, blue = (
            int(color[index : index + 2], 16) for index in (1, 3, 5)
        )
    except ValueError:
        return False
    return red >= 192 and green <= 64 and blue <= 64


def _segment_colors(segment) -> tuple[str, ...]:
    if type(segment) is WholeBar:
        return (segment.color,)
    if type(segment) is ColorList:
        return segment.colors
    if type(segment) is IndexedPaint:
        return tuple(color for _index, color in segment.assignments)
    return ()


def _step_has_saturated_red(step) -> bool:
    return type(step) is PaintStep and any(
        _is_saturated_red(color)
        for segment in step.segments
        for color in _segment_colors(segment)
    )


def _safe_timing(
    timing: Timing,
    *,
    saturated_red: bool,
    force_timed: bool,
) -> tuple[Timing, bool]:
    minimum = (
        MIN_SATURATED_RED_PHASE_MS
        if saturated_red
        else MIN_PRESENTATION_PHASE_MS
    )
    duration = timing.duration_ms
    if duration is None and force_timed:
        # Only a repeating program needs concrete durations: an untimed
        # step inside a loop is a zero-length spin the loop-cadence pass
        # cannot scale. Outside a loop the firmware's own defaults apply
        # and the author's bytes pass through unchanged.
        if timing.easing == "pulse":
            duration = (
                MIN_SATURATED_RED_CYCLE_MS
                if saturated_red
                else MIN_PRESENTATION_CYCLE_MS
            )
        elif timing.easing is not None:
            duration = max(minimum, timing.effective_duration_ms)
        else:
            duration = minimum
    # Explicit durations are the author's phase design. Sustained flash rate
    # is owned by the loop-cadence pass below: a short pulse inside a
    # slow-enough loop is one brief flash per cycle, not a flicker hazard.
    # A delay is a phase offset and can never raise the flash rate; clamping
    # delays collapses deliberately staggered LEDs onto the same phase and
    # makes the surface flash MORE in unison, so it is never done.
    delay = timing.delay_ms
    if (duration is not None and duration > MAX_TIME_MS) or (
        delay is not None and delay > MAX_TIME_MS
    ):
        raise PresentationSafetyError("safe timing exceeds firmware limit")
    updated = replace(timing, duration_ms=duration, delay_ms=delay)
    return updated, updated != timing


def _safe_segment(
    segment,
    *,
    saturated_red: bool,
    force_timed: bool,
):
    if type(segment) is IndexedPaint:
        # A named-LED paint is spatial motion, not a field flash: it moves a
        # few LEDs and leaves the rest holding, so a phase floor on it caps
        # how fast light may TRAVEL rather than how fast the strip may
        # reverse. That floor is what turned every sweep in this product into
        # a row of separate blinks. The measured flash gate below is what
        # keeps staggered paints honest instead.
        return segment, False
    timing, changed = _safe_timing(
        segment.timing,
        saturated_red=saturated_red,
        force_timed=force_timed,
    )
    return replace(segment, timing=timing), changed


def _slowdown_factor(
    animation: Animation,
    *,
    loop_ms: int | None,
    required_cycle_ms: int,
    led_count: int,
    saturated_red: bool,
) -> int:
    """By how much this loop has to be stretched, as a whole number.

    Two independent floors, and the stricter one wins. The cycle floor is a
    product rule -- nothing on this hardware repeats faster than twice a
    second. The flash floor is the accessibility one, and it is measured:
    ``flash_analysis`` renders the loop and counts how often the FIELD
    reverses, so a travelling head contributes nothing to it however fast it
    travels, while a bar that blinks contributes all of it.

    A whole-number factor is deliberate. Scaling every duration and delay by
    the same integer divides the flash rate by exactly that integer and leaves
    the shape -- every overlap, every stagger, every phase relationship --
    untouched. Rounding phases individually is what collapses a stagger into
    unison, and a strip flashing in unison is the thing being prevented.
    """
    if loop_ms is None or loop_ms <= 0:
        return 1
    cycle_factor = (
        math.ceil(required_cycle_ms / loop_ms) if loop_ms < required_cycle_ms else 1
    )
    limit = MAX_SATURATED_RED_HZ if saturated_red else MAX_PRESENTATION_HZ
    measured = flash_analysis.analyse(animation, led_count=led_count).hertz
    flash_factor = math.ceil(measured / limit) if measured > limit else 1
    return max(1, cycle_factor, flash_factor)


def _safe_animation(
    animation: Animation, *, led_count: int
) -> tuple[Animation, tuple[str, ...]]:
    reasons: list[str] = []
    transformed_steps = []
    saw_red = False
    repeat_index = next(
        (
            index
            for index, step in enumerate(animation.steps)
            if type(step) is RepeatStep
        ),
        None,
    )
    force_timed = repeat_index is not None
    for step in animation.steps:
        if type(step) is PaintStep:
            red = _step_has_saturated_red(step)
            saw_red = saw_red or red
            segments = []
            changed = False
            for segment in step.segments:
                safe, segment_changed = _safe_segment(
                    segment,
                    saturated_red=red,
                    force_timed=force_timed,
                )
                segments.append(safe)
                changed = changed or segment_changed
            transformed_steps.append(replace(step, segments=tuple(segments)))
            if changed:
                reasons.append("phase_cadence_clamped")
        elif type(step) is RollStep:
            duration = max(MIN_PRESENTATION_PHASE_MS, step.duration_ms)
            if duration > MAX_TIME_MS:
                raise PresentationSafetyError("safe roll exceeds firmware limit")
            transformed_steps.append(replace(step, duration_ms=duration))
            if duration != step.duration_ms:
                reasons.append("roll_cadence_clamped")
        else:
            transformed_steps.append(step)

    transformed = Animation(animation.name, tuple(transformed_steps))
    if repeat_index is not None:
        from .animation import loop_duration_ms

        loop_ms = loop_duration_ms(transformed)
        required = (
            MIN_SATURATED_RED_CYCLE_MS if saw_red else MIN_PRESENTATION_CYCLE_MS
        )
        factor = _slowdown_factor(
            transformed,
            loop_ms=loop_ms,
            required_cycle_ms=required,
            led_count=led_count,
            saturated_red=saw_red,
        )
        if factor > 1:
            scaled = []
            for index, step in enumerate(transformed.steps):
                if index >= repeat_index:
                    scaled.append(step)
                    continue
                if type(step) is PaintStep:
                    segments = []
                    for segment in step.segments:
                        timing = segment.timing
                        duration = (
                            timing.effective_duration_ms * factor
                            if timing.duration_ms is None
                            else timing.duration_ms * factor
                        )
                        delay = (
                            None
                            if timing.delay_ms is None
                            else timing.delay_ms * factor
                        )
                        if (duration is not None and duration > MAX_TIME_MS) or (
                            delay is not None and delay > MAX_TIME_MS
                        ):
                            raise PresentationSafetyError(
                                "safe loop timing exceeds firmware limit"
                            )
                        segments.append(
                            replace(
                                segment,
                                timing=replace(
                                    timing,
                                    duration_ms=duration,
                                    delay_ms=delay,
                                ),
                            )
                        )
                    scaled.append(replace(step, segments=tuple(segments)))
                elif type(step) is RollStep:
                    duration = step.duration_ms * factor
                    if duration > MAX_TIME_MS:
                        raise PresentationSafetyError(
                            "safe loop timing exceeds firmware limit"
                        )
                    scaled.append(replace(step, duration_ms=duration))
                else:
                    scaled.append(step)
            transformed = Animation(animation.name, tuple(scaled))
            reasons.append("loop_cadence_clamped")

    return transformed, tuple(dict.fromkeys(reasons))


def compile_presentation_program(
    program: str,
    *,
    led_count: int = 8,
    fallback: str = SAFE_FALLBACK_PROGRAM,
) -> PresentationCompileResult:
    """The one gate every visible program passes through.

    Cached: this runs on every device write and every Screen Bar frame source,
    it is a pure function of its three arguments, and the flash analysis it
    now performs renders the loop.
    """
    return _compiled(str(program), int(led_count), str(fallback))


@lru_cache(maxsize=512)
def _compiled(
    program: str,
    led_count: int,
    fallback: str,
) -> PresentationCompileResult:
    animation, problems = read_program(program, led_count=led_count)
    if errors_only(problems):
        return PresentationCompileResult(
            fallback,
            False,
            program != fallback,
            ("invalid_program",),
        )
    try:
        safe_animation, reasons = _safe_animation(animation, led_count=led_count)
    except (PresentationSafetyError, AnimationValidationError, ValueError):
        return PresentationCompileResult(
            fallback,
            False,
            program != fallback,
            ("unsafe_program",),
        )
    safe_problems = validate_animation(safe_animation, led_count=led_count)
    if errors_only(safe_problems):
        return PresentationCompileResult(
            fallback,
            False,
            program != fallback,
            ("unsafe_program",),
        )
    safe_program = render_animation(safe_animation)
    return PresentationCompileResult(
        safe_program,
        True,
        safe_program != program,
        reasons,
    )
