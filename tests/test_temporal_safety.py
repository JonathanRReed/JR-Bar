from __future__ import annotations

import math
import random

import pytest

from jrbar.temporal_safety import (
    CalibrationState,
    RefusedTemporalProgram,
    SafeTemporalProgram,
    StaticSemanticFallback,
    TemporalFrame,
    TemporalProgram,
    TemporalSafetyReason,
    TransformRequiredTemporalProgram,
    analyze_temporal_safety,
)


def frame(luminance: float, duration: float = 0.1) -> TemporalFrame:
    return TemporalFrame(luminance=luminance, duration_seconds=duration)


def alternating_frames(
    flashes: int,
    *,
    duration: float = 0.1,
) -> tuple[TemporalFrame, ...]:
    return tuple(
        frame(float(index % 2), duration)
        for index in range((flashes * 2) + 1)
    )


def analyze(
    frames: object,
    *,
    repeat_count: int | None = 1,
    calibration: CalibrationState = CalibrationState(),
    fallback: StaticSemanticFallback = StaticSemanticFallback(
        semantic_key="waiting_for_input",
        luminance=0.35,
    ),
):
    return analyze_temporal_safety(
        TemporalProgram(
            frames=frames,
            repeat_count=repeat_count,
            static_fallback=fallback,
        ),
        calibration=calibration,
    )


def test_static_and_monotonic_programs_are_safe__and_2_more() -> None:
    # --- scenario: static_and_monotonic_programs_are_safe
    static = analyze((frame(0.4, 2.0),))
    monotonic = analyze(tuple(frame(index / 20.0, 0.02) for index in range(21)))

    assert isinstance(static, SafeTemporalProgram)
    assert isinstance(monotonic, SafeTemporalProgram)
    assert static.reason is TemporalSafetyReason.SAFE
    assert static.max_flashes_per_second == 0
    assert monotonic.max_flashes_per_second == 0

    # --- scenario: exactly_three_flashes_in_one_second_are_safe
    result = analyze(alternating_frames(3))

    assert isinstance(result, SafeTemporalProgram)
    assert result.max_flashes_per_second == 3

    # --- scenario: four_uncalibrated_flashes_are_refused
    result = analyze(alternating_frames(4))

    assert isinstance(result, RefusedTemporalProgram)
    assert result.reason is TemporalSafetyReason.UNCALIBRATED_FLASH_RATE
    assert result.max_flashes_per_second == 4



def test_four_calibrated_flashes_require_static_transformation__and_2_more() -> None:
    # --- scenario: four_calibrated_flashes_require_static_transformation
    fallback = StaticSemanticFallback(
        semantic_key="fresh_failure",
        luminance=0.6,
    )

    result = analyze(
        alternating_frames(4),
        calibration=CalibrationState(
            physical_luminance_calibrated=True,
            flash_area_calibrated=True,
        ),
        fallback=fallback,
    )

    assert isinstance(result, TransformRequiredTemporalProgram)
    assert result.reason is TemporalSafetyReason.FLASH_RATE_EXCEEDED
    assert result.max_flashes_per_second == 4
    assert result.static_fallback == fallback

    # --- scenario: partial_calibration_still_fails_closed
    for calibration in (
        CalibrationState(physical_luminance_calibrated=True),
        CalibrationState(flash_area_calibrated=True),
    ):
        result = analyze(alternating_frames(4), calibration=calibration)

        assert isinstance(result, RefusedTemporalProgram)
        assert result.reason is TemporalSafetyReason.UNCALIBRATED_FLASH_RATE

    # --- scenario: sliding_window_detects_flashes_across_fixed_second_buckets
    result = analyze(alternating_frames(4, duration=0.15))

    assert isinstance(result, RefusedTemporalProgram)
    assert result.max_flashes_per_second == 4



def test_one_second_window_endpoints_are_conservative__and_2_more() -> None:
    # --- scenario: one_second_window_endpoints_are_conservative
    exactly_one_second = (0.05, 0.05, 0.4, 0.1, 0.3, 0.1, 0.05, 0.05, 0.1)
    just_over_one_second = (
        0.05,
        0.05,
        0.4,
        0.1,
        0.3,
        0.1,
        0.0500001,
        0.05,
        0.1,
    )

    boundary = analyze(
        tuple(frame(float(index % 2), duration) for index, duration in enumerate(exactly_one_second))
    )
    outside = analyze(
        tuple(frame(float(index % 2), duration) for index, duration in enumerate(just_over_one_second))
    )

    assert isinstance(boundary, RefusedTemporalProgram)
    assert boundary.max_flashes_per_second == 4
    assert isinstance(outside, SafeTemporalProgram)
    assert outside.max_flashes_per_second == 3

    # --- scenario: finite_repeat_is_analyzed_across_cycle_boundaries
    result = analyze(
        (frame(0.0), frame(1.0)),
        repeat_count=6,
    )

    assert isinstance(result, RefusedTemporalProgram)
    assert result.max_flashes_per_second >= 4

    # --- scenario: deterministic_jittered_strobe_is_refused
    rng = random.Random(20260812)
    frames = tuple(
        frame(float(index % 2), rng.uniform(0.04, 0.06))
        for index in range(17)
    )

    result = analyze(frames)

    assert isinstance(result, RefusedTemporalProgram)
    assert result.max_flashes_per_second == 8



def test_nonfinite_frame_values_fail_closed__and_2_more() -> None:
    # --- scenario: nonfinite_frame_values_fail_closed
    for value in [math.nan, math.inf, -math.inf]:
        for field in ["luminance", "duration"]:
            invalid = frame(value, 0.1) if field == "luminance" else frame(0.5, value)

            result = analyze((invalid,))

            assert isinstance(result, RefusedTemporalProgram)
            assert result.reason is TemporalSafetyReason.NONFINITE_FRAME

    # --- scenario: negative_out_of_range_and_zero_duration_frames_fail_closed
    for invalid, reason in [
        (frame(-0.1), TemporalSafetyReason.INVALID_LUMINANCE),
        (frame(1.1), TemporalSafetyReason.INVALID_LUMINANCE),
        (frame(0.5, -0.1), TemporalSafetyReason.NEGATIVE_DURATION),
        (frame(0.5, 0.0), TemporalSafetyReason.ZERO_DURATION),
    ]:
        result = analyze((invalid,))

        assert isinstance(result, RefusedTemporalProgram)
        assert result.reason is reason

    # --- scenario: non_numeric_frame_values_fail_closed
    for value in [True, "0.5", object()]:
        result = analyze((TemporalFrame(luminance=value, duration_seconds=0.1),))

        assert isinstance(result, RefusedTemporalProgram)
        assert result.reason is TemporalSafetyReason.INVALID_FRAME



def test_unbounded_frame_iterable_is_refused_without_iteration__and_2_more() -> None:
    # --- scenario: unbounded_frame_iterable_is_refused_without_iteration
    def unbounded():
        raise AssertionError("the analyzer must not consume an unbounded iterable")
        yield frame(0.0)

    result = analyze(unbounded())

    assert isinstance(result, RefusedTemporalProgram)
    assert result.reason is TemporalSafetyReason.UNBOUNDED_INPUT

    # --- scenario: unbounded_and_invalid_repeat_counts_fail_closed
    for repeat_count, reason in [
        (None, TemporalSafetyReason.UNBOUNDED_REPEAT),
        (0, TemporalSafetyReason.INVALID_REPEAT),
        (-1, TemporalSafetyReason.INVALID_REPEAT),
        (True, TemporalSafetyReason.INVALID_REPEAT),
        (1.5, TemporalSafetyReason.INVALID_REPEAT),
    ]:
        result = analyze((frame(0.5),), repeat_count=repeat_count)

        assert isinstance(result, RefusedTemporalProgram)
        assert result.reason is reason

    # --- scenario: empty_and_oversized_programs_fail_closed
    for frames, repeat_count in [
        ((), 1),
        ((frame(0.5, 301.0),), 1),
        (tuple(frame(0.5) for _ in range(4097)), 1),
        ((frame(0.5),), 4097),
    ]:
        result = analyze(frames, repeat_count=repeat_count)

        assert isinstance(result, RefusedTemporalProgram)
        assert result.reason in {
            TemporalSafetyReason.EMPTY_PROGRAM,
            TemporalSafetyReason.OVERSIZED_PROGRAM,
        }



def test_invalid_frame_object_fails_closed__and_2_more() -> None:
    # --- scenario: invalid_frame_object_fails_closed
    result = analyze((frame(0.0), object()))

    assert isinstance(result, RefusedTemporalProgram)
    assert result.reason is TemporalSafetyReason.INVALID_FRAME

    # --- scenario: invalid_program_object_fails_closed_with_a_static_fallback
    result = analyze_temporal_safety(object())

    assert isinstance(result, RefusedTemporalProgram)
    assert result.reason is TemporalSafetyReason.INVALID_PROGRAM
    assert result.static_fallback.is_static is True
    assert result.static_fallback.semantic_key == "safe_static_state"

    # --- scenario: every_result_exposes_a_bounded_static_semantic_fallback
    for frames in [
        (frame(0.5),),
        alternating_frames(3),
        alternating_frames(4),
        (frame(math.nan),),
    ]:
        fallback = StaticSemanticFallback(
            semantic_key="completed_recently",
            luminance=0.2,
        )

        result = analyze(frames, fallback=fallback)

        assert result.static_fallback == fallback
        assert result.static_fallback.is_static is True
        assert len(result.static_fallback.semantic_key) <= 64
        assert isinstance(result.reason, TemporalSafetyReason)



def test_invalid_fallback_fails_closed_to_the_canonical_static_contract__and_1_more() -> None:
    # --- scenario: invalid_fallback_fails_closed_to_the_canonical_static_contract
    for fallback in [
        StaticSemanticFallback(semantic_key="", luminance=0.2),
        StaticSemanticFallback(semantic_key="x" * 65, luminance=0.2),
        StaticSemanticFallback(semantic_key="unsafe path/value", luminance=0.2),
        StaticSemanticFallback(semantic_key="safe", luminance=math.nan),
        StaticSemanticFallback(semantic_key="safe", luminance=-0.1),
    ]:
        result = analyze((frame(0.5),), fallback=fallback)

        assert isinstance(result, RefusedTemporalProgram)
        assert result.reason is TemporalSafetyReason.INVALID_STATIC_FALLBACK
        assert result.static_fallback.semantic_key == "safe_static_state"
        assert result.static_fallback.luminance == 0.0

    # --- scenario: analysis_is_deterministic_and_does_not_mutate_the_program
    frames = alternating_frames(4)
    program = TemporalProgram(
        frames=frames,
        repeat_count=1,
        static_fallback=StaticSemanticFallback("active", 0.4),
    )

    first = analyze_temporal_safety(program)
    second = analyze_temporal_safety(program)

    assert first == second
    assert program.frames is frames
    assert program.repeat_count == 1

