from __future__ import annotations

import math
from dataclasses import dataclass, replace
from enum import Enum
from itertools import pairwise

from .accessibility_display import AccessibilityDisplayPreferences
from .signals import ATTENTION_ARRIVAL_TAPS
from .temporal_safety import (
    CalibrationState,
    SafeTemporalProgram,
    StaticSemanticFallback,
    TemporalFrame,
    TemporalProgram,
    analyze_temporal_safety,
)

MAX_EPISODE_KEY_BYTES = 128
MAX_PROVIDER_KEY_BYTES = 128
MAX_FINITE_CUE_DURATION_SECONDS = 60.0
RELAY_TRAVERSAL_SECONDS = 1.6
MAX_PROGRAM_BYTES = 512
MAX_PROGRAM_LINES = 20
# An epoch-scale timestamp is not a monotonic presentation anchor. Ten years is
# deliberately far beyond a realistic single boot while remaining far below
# contemporary wall-clock values.
MAX_MONOTONIC_SECONDS = 10.0 * 365.25 * 24.0 * 60.0 * 60.0


class GlanceSemantic(str, Enum):
    ATTENTION = "attention"
    FRESH_FAILURE = "fresh_failure"
    FRESH_COMPLETION = "fresh_completion"
    ACTIVE = "active"
    UNRESOLVED_FAILURE = "unresolved_failure"
    CAPACITY = "capacity"
    REST = "rest"


class GlanceOverrideReason(str, Enum):
    NONE = "none"
    EXPLICIT_DEVICE_MODE = "explicit_device_mode"
    PROVIDER_PIN = "provider_pin"
    SAFETY_SIGNAL = "safety_signal"
    FOCUS = "focus"
    SHARED_SPACE_PRIVACY = "shared_space_privacy"
    UNAVAILABLE = "unavailable"


class MotionClass(str, Enum):
    STATIC = "static"
    FINITE = "finite"
    CONTINUOUS = "continuous"


class SemanticGlyph(str, Enum):
    FULL_ANCHOR = "full_anchor"
    LEFT_ANCHOR = "left_anchor"
    RIGHT_ANCHOR = "right_anchor"
    CENTER_PAIR = "center_pair"
    CAPACITY_FILL = "capacity_fill"
    REST = "rest"


@dataclass(frozen=True, slots=True)
class CapacityGlance:
    provider_key: str
    remaining_fraction: float


@dataclass(frozen=True, slots=True)
class FiniteCue:
    event_key: str
    semantic: GlanceSemantic
    repetitions: int
    duration_seconds: float


@dataclass(frozen=True, slots=True)
class FiniteCueBudget:
    max_repetitions: int = 2
    max_active: int = 1
    max_pending: int = 1
    max_consumed_keys: int = 256


@dataclass(frozen=True, slots=True)
class FiniteCueState:
    active: FiniteCue | None
    pending: FiniteCue | None
    next_deadline: float | None
    overflowed: bool


@dataclass(frozen=True, slots=True)
class GlanceInputs:
    actionable_episode_key: str | None
    fresh_failure: FiniteCue | None
    fresh_completion: FiniteCue | None
    active: bool
    unresolved_failure: bool
    capacity: CapacityGlance | None
    override_reason: GlanceOverrideReason = GlanceOverrideReason.NONE
    override_semantic: GlanceSemantic | None = None


@dataclass(frozen=True, slots=True)
class ResolvedGlance:
    semantic: GlanceSemantic
    glyph: SemanticGlyph
    cue: FiniteCue | None
    override_reason: GlanceOverrideReason
    relay_epoch: float
    next_visual_change_at: float | None


@dataclass(frozen=True, slots=True)
class PresentationProgram:
    semantic: GlanceSemantic
    glyph: SemanticGlyph
    motion: MotionClass
    dsl: str
    static_fallback_dsl: str
    temporal: TemporalProgram | None
    trusted_period_seconds: float | None
    relay_epoch: float
    next_visual_change_at: float | None
    playback_anchor: float | None = None
    # The program's own text when it carries no phase (a chosen motion's
    # loop), so a change of shape, knob or tint is a change of identity even
    # when its period is not. None where the text bakes in a phase (Relay).
    identity_dsl: str | None = None


_GLYPHS = {
    GlanceSemantic.ATTENTION: SemanticGlyph.FULL_ANCHOR,
    GlanceSemantic.FRESH_FAILURE: SemanticGlyph.LEFT_ANCHOR,
    GlanceSemantic.FRESH_COMPLETION: SemanticGlyph.RIGHT_ANCHOR,
    GlanceSemantic.ACTIVE: SemanticGlyph.CENTER_PAIR,
    GlanceSemantic.UNRESOLVED_FAILURE: SemanticGlyph.LEFT_ANCHOR,
    GlanceSemantic.CAPACITY: SemanticGlyph.CAPACITY_FILL,
    GlanceSemantic.REST: SemanticGlyph.REST,
}


def resolve_glance(
    inputs: GlanceInputs,
    *,
    presentation_time: float,
    relay_epoch: float,
    preferences: AccessibilityDisplayPreferences,
) -> ResolvedGlance:
    """Resolve canonical inputs through the exact shared glance ladder."""
    if not _valid_clock_pair(presentation_time, relay_epoch):
        return _rest_result()
    if not isinstance(inputs, GlanceInputs) or not _valid_preferences(preferences):
        return _rest_result()
    if type(inputs.active) is not bool or type(inputs.unresolved_failure) is not bool:
        return _rest_result()

    semantic, cue = _automatic_glance(inputs)
    override_reason = GlanceOverrideReason.NONE
    if (
        isinstance(inputs.override_reason, GlanceOverrideReason)
        and inputs.override_reason is not GlanceOverrideReason.NONE
        and isinstance(inputs.override_semantic, GlanceSemantic)
    ):
        semantic = inputs.override_semantic
        cue = None
        override_reason = inputs.override_reason

    if preferences.reduce_motion:
        cue = None
    deadline = (
        presentation_time + cue.repetitions * cue.duration_seconds
        if cue is not None
        else None
    )
    return ResolvedGlance(
        semantic=semantic,
        glyph=_GLYPHS[semantic],
        cue=cue,
        override_reason=override_reason,
        relay_epoch=relay_epoch,
        next_visual_change_at=deadline,
    )


def compose_presentation_program(
    resolved: ResolvedGlance,
    *,
    presentation_time: float,
    led_count: int,
    color: str,
    preferences: AccessibilityDisplayPreferences,
    capacity_remaining_fraction: float | None = None,
    calibration: CalibrationState = CalibrationState(),
    motion_style: str | None = None,
    provider: str | None = None,
    color_settings=None,
) -> PresentationProgram:
    """Compose one hue-independent semantic glyph for a bounded surface.

    ``motion_style`` is the provider's own chosen rhythm and applies ONLY
    to the ACTIVE semantic; left out, it is the provider's choice in
    ``color_settings``. Urgent semantics ignore it, exactly as agent_motion
    does. A chosen motion is drawn by the same renderer as its Settings
    thumbnail and its Effect Studio preview, so one working agent on the
    Pro plays exactly what those show.

    A device whose strip is mounted the other way round
    (``color_settings.render_led_direction``) gets the whole composition
    mirrored as the last step.
    """
    program = _compose_presentation_program(
        resolved,
        presentation_time=presentation_time,
        led_count=led_count,
        color=color,
        preferences=preferences,
        capacity_remaining_fraction=capacity_remaining_fraction,
        calibration=calibration,
        motion_style=motion_style,
        provider=provider,
        color_settings=color_settings,
    )
    direction = getattr(color_settings, "render_led_direction", "forward")
    if direction != "reversed" or type(led_count) is not int or led_count <= 0:
        return program
    from .motion_shapes import oriented_program

    def mirrored(text: str | None) -> str | None:
        if text is None:
            return None
        return oriented_program(text, led_count=led_count, direction=direction)

    return replace(
        program,
        dsl=mirrored(program.dsl) or program.dsl,
        static_fallback_dsl=mirrored(program.static_fallback_dsl)
        or program.static_fallback_dsl,
        identity_dsl=mirrored(program.identity_dsl),
    )


def _compose_presentation_program(
    resolved: ResolvedGlance,
    *,
    presentation_time: float,
    led_count: int,
    color: str,
    preferences: AccessibilityDisplayPreferences,
    capacity_remaining_fraction: float | None = None,
    calibration: CalibrationState = CalibrationState(),
    motion_style: str | None = None,
    provider: str | None = None,
    color_settings=None,
) -> PresentationProgram:
    if (
        not isinstance(resolved, ResolvedGlance)
        or not valid_presentation_time(presentation_time)
        or not _valid_preferences(preferences)
        or type(led_count) is not int
        or led_count <= 0
    ):
        return _static_program(
            _rest_result(),
            dsl="off",
        )

    from .colors import (
        normalize_hex,
        relay_led_order,
        relay_phase_index,
        relay_step_ms,
    )
    from .led_status import ASK_AMBER, settle_duration_ms

    if motion_style is None and provider and color_settings is not None:
        from .colors import PROVIDER_ANIMATION_AUTO

        try:
            chosen = color_settings.agent_animation(provider)
        except Exception:
            chosen = PROVIDER_ANIMATION_AUTO
        if chosen != PROVIDER_ANIMATION_AUTO:
            motion_style = chosen

    normalized_color = normalize_hex(color, ASK_AMBER)
    if resolved.semantic is GlanceSemantic.ACTIVE:
        # ACTIVE is the one semantic painted in an agent's IDENTITY color
        # (color_for_resolved_glance) -- floor it so a dark brand or custom
        # pick stays a lit LED. REST keeps its deliberate idle dim.
        from .colors import readable_identity_hex

        normalized_color = readable_identity_hex(normalized_color)
    intensities = _glyph_intensities(
        resolved.semantic,
        led_count=led_count,
        capacity_remaining_fraction=capacity_remaining_fraction,
        differentiate_without_color=preferences.differentiate_without_color,
        increase_contrast=preferences.increase_contrast,
    )
    fallback = _static_glyph_dsl(normalized_color, intensities)
    motion = _motion_for_resolved(resolved, preferences=preferences)

    if motion is MotionClass.STATIC:
        return _static_program(resolved, dsl=fallback)

    if motion is MotionClass.FINITE:
        assert resolved.cue is not None
        cue = resolved.cue
        half_duration = cue.duration_seconds / 2.0
        half_ms = max(1, round(half_duration * 1000.0))
        lowered_intensities = _lowered_glyph_intensities(intensities)
        frames_intensities = tuple(
            vector
            for _ in range(cue.repetitions)
            for vector in (intensities, lowered_intensities)
        )
        lines = [
            _duration_glyph_dsl(
                normalized_color,
                frames_intensities[0],
                duration_ms=half_ms,
            )
        ]
        for previous, current in pairwise(frames_intensities):
            lines.append(
                _duration_glyph_delta_dsl(
                    normalized_color,
                    previous,
                    current,
                    duration_ms=half_ms,
                )
            )
        lines.append(fallback)
        temporal = TemporalProgram(
            frames=tuple(
                TemporalFrame(_mean_intensity(vector), half_duration)
                for vector in frames_intensities
            ),
            repeat_count=1,
            static_fallback=StaticSemanticFallback(
                resolved.semantic.value,
                _mean_intensity(intensities),
            ),
        )
        candidate = PresentationProgram(
            semantic=resolved.semantic,
            glyph=resolved.glyph,
            motion=motion,
            dsl="\n".join(lines),
            static_fallback_dsl=fallback,
            temporal=temporal,
            trusted_period_seconds=None,
            relay_epoch=resolved.relay_epoch,
            next_visual_change_at=resolved.next_visual_change_at,
        )
        return _bounded_and_safe(candidate, calibration=calibration)

    if resolved.semantic is GlanceSemantic.ACTIVE and _chosen_motion(motion_style):
        lines = _chosen_motion_lines(
            motion_style,
            normalized_color,
            provider=provider,
            color_settings=color_settings,
            led_count=led_count,
        )
        if lines is None:
            return _static_program(resolved, dsl=fallback)
        if motion_style == "steady":
            # Steady holds its colour: the preview's hold, written once,
            # with no loop to keep alive.
            return _static_program(resolved, dsl=lines[0])
        cycle_seconds = 1.0
        # The declared period must be the period the firmware will
        # actually loop, or phase-resume drifts a little every cycle
        # (twinkle at 2 LEDs declared 4010ms against a real 1910ms
        # loop). Measure the program we just wrote through the real
        # parser; keep the hand-built value only if the parse refuses.
        try:
            from .animation import loop_duration_ms, parse_animation

            _measured = loop_duration_ms(
                parse_animation("\n".join(lines), led_count=led_count)
            )
        except Exception:
            _measured = None
        if _measured:
            cycle_seconds = _measured / 1000.0
        cycle_ms = max(1, round(cycle_seconds * 1000.0))
        elapsed = max(0.0, float(presentation_time) - resolved.relay_epoch)
        elapsed_ms = round(elapsed * 1000.0)
        anchor = float(presentation_time) - (elapsed_ms % cycle_ms) / 1000.0
        # At least two full periods, and always the period plus the second
        # the safety pass needs: a loop shorter than a second (a fast chase,
        # a Dot's wipe) is still a loop, not a reason to fall back to still.
        frame_count = max(4, math.ceil(2.0 * (cycle_seconds + 1.0) / cycle_seconds))
        temporal = TemporalProgram(
            frames=tuple(
                TemporalFrame(_mean_intensity(intensities), cycle_seconds / 2.0)
                for _ in range(frame_count)
            ),
            repeat_count=1,
            static_fallback=StaticSemanticFallback(
                resolved.semantic.value,
                _mean_intensity(intensities),
            ),
        )
        candidate = PresentationProgram(
            semantic=resolved.semantic,
            glyph=resolved.glyph,
            motion=motion,
            dsl="\n".join(lines),
            static_fallback_dsl=fallback,
            temporal=temporal,
            trusted_period_seconds=cycle_seconds,
            relay_epoch=resolved.relay_epoch,
            next_visual_change_at=resolved.next_visual_change_at,
            playback_anchor=anchor,
            identity_dsl="\n".join(lines),
        )
        return _bounded_and_safe(candidate, calibration=calibration)

    elapsed = max(0.0, float(presentation_time) - resolved.relay_epoch)
    step_ms = relay_step_ms(RELAY_TRAVERSAL_SECONDS, led_count)
    start_index = relay_phase_index(
        elapsed,
        RELAY_TRAVERSAL_SECONDS,
        led_count,
    )
    elapsed_ms = round(elapsed * 1000.0)
    playback_anchor = float(presentation_time) - (elapsed_ms % step_ms) / 1000.0
    order = relay_led_order(led_count, start_index)
    settle_ms = settle_duration_ms(step_ms)
    floor_color = _scaled_color(normalized_color, 0.05)
    peak_color = _scaled_color(normalized_color, 1.0)
    resets = f"{floor_color} {settle_ms}ms cosine"
    pulses = "; ".join(
        f"{index}:{peak_color} {step_ms}ms pulse {turn * step_ms}ms"
        for turn, index in enumerate(order)
    )
    # The loop the firmware runs is settle + traversal, not the bare
    # traversal -- declare the period it will actually repeat (same
    # honesty rule as the styled shapes above).
    try:
        from .animation import loop_duration_ms, parse_animation

        _measured = loop_duration_ms(
            parse_animation(
                "\n".join((resets, pulses, "repeat")),
                led_count=led_count,
            )
        )
    except Exception:
        _measured = None
    trusted_period = (
        _measured / 1000.0 if _measured else RELAY_TRAVERSAL_SECONDS
    )
    temporal = TemporalProgram(
        frames=tuple(
            TemporalFrame(_mean_intensity(intensities), RELAY_TRAVERSAL_SECONDS / led_count)
            for _ in range(led_count * 2)
        ),
        repeat_count=1,
        static_fallback=StaticSemanticFallback(
            resolved.semantic.value,
            _mean_intensity(intensities),
        ),
    )
    candidate = PresentationProgram(
        semantic=resolved.semantic,
        glyph=resolved.glyph,
        motion=motion,
        dsl="\n".join((resets, pulses, "repeat")),
        static_fallback_dsl=fallback,
        temporal=temporal,
        trusted_period_seconds=trusted_period,
        relay_epoch=resolved.relay_epoch,
        next_visual_change_at=resolved.next_visual_change_at,
        playback_anchor=playback_anchor,
    )
    return _bounded_and_safe(candidate, calibration=calibration)


#: Room kept for the ``brightness N`` line the caller puts in front.
_BRIGHTNESS_LINE_RESERVE = 16


def _chosen_motion(motion_style: object) -> bool:
    """Whether ``motion_style`` is a motion a person chose (not Automatic)."""
    from .colors import PROVIDER_ANIMATION_AUTO, PROVIDER_ANIMATION_CHOICES

    return (
        isinstance(motion_style, str)
        and motion_style in PROVIDER_ANIMATION_CHOICES
        and motion_style != PROVIDER_ANIMATION_AUTO
    )


def _chosen_motion_lines(
    motion_style: str,
    color: str,
    *,
    provider: str | None,
    color_settings,
    led_count: int,
) -> list[str] | None:
    """The loop one working agent plays for its chosen motion: a short ease
    to the resting colour, then the motion exactly as its preview draws it.

    The ease goes first so an interrupted loop settles instead of snapping,
    and it is the first thing dropped when the firmware's 512 bytes are
    tight -- refusing the write would freeze the strip on its old program.
    """
    from .colors import (
        ColorSettings,
        PROVIDER_ANIMATION_AUTO,
        provider_motion_lines,
    )

    settings = color_settings if isinstance(color_settings, ColorSettings) else ColorSettings.defaults()
    owner = provider or "solo"
    try:
        if settings.agent_animation(owner) != motion_style:
            settings = settings.with_agent_animation(owner, motion_style)
        rendered = provider_motion_lines(owner, color, settings, led_count=led_count)
    except (TypeError, ValueError):
        rendered = None
    if rendered is None or motion_style == PROVIDER_ANIMATION_AUTO:
        return None
    body, settle_text = rendered
    if motion_style == "steady":
        return [*body, "repeat"]
    for candidate in ([settle_text, *body, "repeat"], [*body, "repeat"]):
        text = "\n".join(candidate)
        if (
            len(text.encode("utf-8")) + _BRIGHTNESS_LINE_RESERVE <= MAX_PROGRAM_BYTES
            and len(candidate) + 1 <= MAX_PROGRAM_LINES
        ):
            return candidate
    return None


def enforce_temporal_safety(
    program: PresentationProgram,
    *,
    calibration: CalibrationState,
) -> PresentationProgram:
    """Fail closed to typed steady truth for any untrusted or unsafe motion."""
    if not isinstance(program, PresentationProgram):
        return _static_program(_rest_result(), dsl="off")
    if program.motion is MotionClass.STATIC:
        return program
    if program.motion is MotionClass.FINITE and any(
        line.strip() == "repeat" for line in program.dsl.splitlines()
    ):
        return _fallback_program(program)
    if not isinstance(program.temporal, TemporalProgram):
        return _fallback_program(program)
    if program.motion is MotionClass.CONTINUOUS:
        period = program.trusted_period_seconds
        if (
            not _finite_number(period)
            or float(period) <= 0.0
            or _temporal_duration(program.temporal) < float(period) + 1.0
        ):
            return _fallback_program(program)
    outcome = analyze_temporal_safety(program.temporal, calibration=calibration)
    if not isinstance(outcome, SafeTemporalProgram):
        return _fallback_program(program)
    return program


def _bounded_and_safe(
    program: PresentationProgram,
    *,
    calibration: CalibrationState,
) -> PresentationProgram:
    if (
        len(program.dsl.encode("utf-8")) > MAX_PROGRAM_BYTES
        or len(program.dsl.splitlines()) > MAX_PROGRAM_LINES
    ):
        return _fallback_program(program)
    return enforce_temporal_safety(program, calibration=calibration)


def _motion_for_resolved(
    resolved: ResolvedGlance,
    *,
    preferences: AccessibilityDisplayPreferences,
) -> MotionClass:
    if preferences.reduce_motion:
        return MotionClass.STATIC
    if resolved.cue is not None:
        return MotionClass.FINITE
    if resolved.semantic is GlanceSemantic.ACTIVE:
        return MotionClass.CONTINUOUS
    return MotionClass.STATIC


def _glyph_intensities(
    semantic: GlanceSemantic,
    *,
    led_count: int,
    capacity_remaining_fraction: float | None,
    differentiate_without_color: bool,
    increase_contrast: bool,
) -> tuple[float, ...]:
    if led_count == 2:
        anchors = {
            GlanceSemantic.ATTENTION: (1.0, 1.0),
            GlanceSemantic.FRESH_FAILURE: (1.0, 0.2),
            GlanceSemantic.FRESH_COMPLETION: (0.2, 1.0),
            GlanceSemantic.ACTIVE: (0.65, 0.65),
            GlanceSemantic.UNRESOLVED_FAILURE: (0.55, 0.1),
            GlanceSemantic.CAPACITY: (0.05, 0.05),
            GlanceSemantic.REST: (0.05, 0.05),
        }
        return anchors[semantic]

    floor = 0.0 if differentiate_without_color else 0.05
    values = [floor] * led_count
    if semantic is GlanceSemantic.ATTENTION:
        values = [1.0] * led_count
    elif semantic is GlanceSemantic.FRESH_FAILURE:
        values[0 : min(2, led_count)] = [1.0] * min(2, led_count)
    elif semantic is GlanceSemantic.FRESH_COMPLETION:
        values[max(0, led_count - 2) :] = [1.0] * min(2, led_count)
    elif semantic is GlanceSemantic.ACTIVE:
        left = max(0, (led_count - 1) // 2)
        right = min(led_count - 1, led_count // 2)
        values[left] = values[right] = 0.65
    elif semantic is GlanceSemantic.UNRESOLVED_FAILURE:
        values[0] = 0.55
    elif semantic is GlanceSemantic.CAPACITY:
        fraction = _valid_fraction_or_zero(capacity_remaining_fraction)
        filled = fraction * led_count
        for index in range(led_count):
            values[index] = max(floor, min(1.0, filled - index))
    else:
        values = [0.05] * led_count

    if increase_contrast:
        values = [0.0 if value <= floor else min(1.0, value * 1.15) for value in values]
    return tuple(values)


def _static_glyph_dsl(color: str, intensities: tuple[float, ...]) -> str:
    return "; ".join(
        f"{index}:{_scaled_color(color, intensity)}"
        for index, intensity in enumerate(intensities)
    )


def _duration_glyph_dsl(
    color: str,
    intensities: tuple[float, ...],
    *,
    duration_ms: int,
) -> str:
    if intensities and all(
        math.isclose(value, intensities[0], rel_tol=0.0, abs_tol=1e-12)
        for value in intensities[1:]
    ):
        return f"{_scaled_color(color, intensities[0])} {duration_ms}ms cosine"
    return "; ".join(
        f"{index}:{_scaled_color(color, intensity)} {duration_ms}ms cosine"
        for index, intensity in enumerate(intensities)
    )


def _duration_glyph_delta_dsl(
    color: str,
    previous: tuple[float, ...],
    current: tuple[float, ...],
    *,
    duration_ms: int,
) -> str:
    if current and all(
        math.isclose(value, current[0], rel_tol=0.0, abs_tol=1e-12)
        for value in current[1:]
    ):
        return f"{_scaled_color(color, current[0])} {duration_ms}ms cosine"
    return "; ".join(
        f"{index}:{_scaled_color(color, value)} {duration_ms}ms cosine"
        for index, (prior, value) in enumerate(zip(previous, current))
        if not math.isclose(prior, value, rel_tol=0.0, abs_tol=1e-12)
    )


def _lowered_glyph_intensities(
    intensities: tuple[float, ...],
) -> tuple[float, ...]:
    if not intensities:
        return ()
    floor = min(intensities)
    if all(
        math.isclose(value, floor, rel_tol=0.0, abs_tol=1e-12)
        for value in intensities
    ):
        return tuple(max(0.05, value * 0.45) for value in intensities)
    return tuple(
        value if math.isclose(value, floor, rel_tol=0.0, abs_tol=1e-12)
        else max(floor + 0.1, value * 0.55)
        for value in intensities
    )


def _scaled_color(color: str, intensity: float) -> str:
    from .led_status import scale_hex_brightness

    return scale_hex_brightness(color, max(0.0, min(1.0, intensity)))


def _hue_shifted_color(color: str, degrees: float) -> str:
    """The same color rotated around the hue wheel, lightness and
    saturation untouched -- the ingredient gradient and duotone are made
    of. Deterministic, so the write dedupe still holds."""
    import colorsys

    try:
        red = int(color[1:3], 16) / 255.0
        green = int(color[3:5], 16) / 255.0
        blue = int(color[5:7], 16) / 255.0
    except (ValueError, IndexError):
        return color
    hue, lightness, saturation = colorsys.rgb_to_hls(red, green, blue)
    if saturation <= 0.001:
        # A gray has no hue to rotate; shifting it invents a color the
        # user never picked.
        return color
    hue = (hue + degrees / 360.0) % 1.0
    shifted = colorsys.hls_to_rgb(hue, lightness, saturation)
    return "#" + "".join(
        f"{max(0, min(255, round(channel * 255.0))):02X}" for channel in shifted
    )


def _mean_intensity(intensities: tuple[float, ...]) -> float:
    if not intensities:
        return 0.0
    return max(0.0, min(1.0, math.fsum(intensities) / len(intensities)))


def _valid_fraction_or_zero(value: object) -> float:
    if not _finite_number(value):
        return 0.0
    return max(0.0, min(1.0, float(value)))


def _temporal_duration(program: TemporalProgram) -> float:
    try:
        return math.fsum(frame.duration_seconds for frame in program.frames) * int(
            program.repeat_count or 0
        )
    except (AttributeError, TypeError, ValueError):
        return 0.0


def _static_program(
    resolved: ResolvedGlance,
    *,
    dsl: str,
    playback_anchor: float | None = None,
) -> PresentationProgram:
    return PresentationProgram(
        semantic=resolved.semantic,
        glyph=resolved.glyph,
        motion=MotionClass.STATIC,
        dsl=dsl,
        static_fallback_dsl=dsl,
        temporal=None,
        trusted_period_seconds=None,
        relay_epoch=resolved.relay_epoch,
        next_visual_change_at=None,
        playback_anchor=playback_anchor,
    )


def _fallback_program(program: PresentationProgram) -> PresentationProgram:
    return replace(
        program,
        motion=MotionClass.STATIC,
        dsl=program.static_fallback_dsl or "off",
        static_fallback_dsl=program.static_fallback_dsl or "off",
        temporal=None,
        trusted_period_seconds=None,
        next_visual_change_at=None,
    )


def continuous_presentation_identity(program: object) -> tuple[object, ...] | None:
    """Return phase-independent identity for one continuous presentation."""
    if not isinstance(program, PresentationProgram):
        return None
    if program.motion is not MotionClass.CONTINUOUS:
        return None
    return (
        program.semantic,
        program.glyph,
        program.motion,
        program.static_fallback_dsl,
        program.trusted_period_seconds,
        program.relay_epoch,
        program.identity_dsl,
    )


def valid_finite_cue(
    cue: object,
    *,
    expected_semantic: GlanceSemantic | None = None,
) -> bool:
    if not isinstance(cue, FiniteCue):
        return False
    if not isinstance(cue.semantic, GlanceSemantic):
        return False
    if expected_semantic is not None and cue.semantic is not expected_semantic:
        return False
    if cue.semantic not in {
        GlanceSemantic.ATTENTION,
        GlanceSemantic.FRESH_FAILURE,
        GlanceSemantic.FRESH_COMPLETION,
    }:
        return False
    if not valid_opaque_key(cue.event_key, max_bytes=MAX_EPISODE_KEY_BYTES):
        return False
    if type(cue.repetitions) is not int or not 1 <= cue.repetitions <= 2:
        return False
    return _finite_number(cue.duration_seconds) and (
        0.0 < float(cue.duration_seconds) <= MAX_FINITE_CUE_DURATION_SECONDS
    )


def valid_opaque_key(value: object, *, max_bytes: int) -> bool:
    if not isinstance(value, str) or not value:
        return False
    try:
        encoded = value.encode("utf-8")
    except UnicodeError:
        return False
    return 0 < len(encoded) <= max_bytes


def valid_presentation_time(value: object) -> bool:
    return _finite_number(value) and 0.0 <= float(value) <= MAX_MONOTONIC_SECONDS


def _automatic_glance(inputs: GlanceInputs) -> tuple[GlanceSemantic, FiniteCue | None]:
    if inputs.actionable_episode_key is not None:
        cue = FiniteCue(
            event_key=inputs.actionable_episode_key,
            semantic=GlanceSemantic.ATTENTION,
            repetitions=ATTENTION_ARRIVAL_TAPS,
            duration_seconds=0.24,
        )
        return (
            GlanceSemantic.ATTENTION,
            cue if valid_finite_cue(cue) else None,
        )
    if inputs.fresh_failure is not None:
        return (
            GlanceSemantic.FRESH_FAILURE,
            inputs.fresh_failure
            if valid_finite_cue(
                inputs.fresh_failure,
                expected_semantic=GlanceSemantic.FRESH_FAILURE,
            )
            else None,
        )
    if inputs.fresh_completion is not None:
        return (
            GlanceSemantic.FRESH_COMPLETION,
            inputs.fresh_completion
            if valid_finite_cue(
                inputs.fresh_completion,
                expected_semantic=GlanceSemantic.FRESH_COMPLETION,
            )
            else None,
        )
    if inputs.active:
        return GlanceSemantic.ACTIVE, None
    if inputs.unresolved_failure:
        return GlanceSemantic.UNRESOLVED_FAILURE, None
    if _valid_capacity(inputs.capacity):
        return GlanceSemantic.CAPACITY, None
    return GlanceSemantic.REST, None


def _valid_capacity(value: object) -> bool:
    return (
        isinstance(value, CapacityGlance)
        and valid_opaque_key(value.provider_key, max_bytes=MAX_PROVIDER_KEY_BYTES)
        and _finite_number(value.remaining_fraction)
        and 0.0 <= float(value.remaining_fraction) <= 1.0
    )


def _valid_preferences(value: object) -> bool:
    return isinstance(value, AccessibilityDisplayPreferences) and all(
        type(preference) is bool
        for preference in (
            value.reduce_motion,
            value.reduce_transparency,
            value.increase_contrast,
            value.differentiate_without_color,
        )
    )


def _valid_clock_pair(presentation_time: object, relay_epoch: object) -> bool:
    return (
        valid_presentation_time(presentation_time)
        and valid_presentation_time(relay_epoch)
        and float(relay_epoch) <= float(presentation_time)
    )


def _finite_number(value: object) -> bool:
    return type(value) in {int, float} and math.isfinite(float(value))


def _rest_result() -> ResolvedGlance:
    return ResolvedGlance(
        semantic=GlanceSemantic.REST,
        glyph=SemanticGlyph.REST,
        cue=None,
        override_reason=GlanceOverrideReason.NONE,
        relay_epoch=0.0,
        next_visual_change_at=None,
    )
