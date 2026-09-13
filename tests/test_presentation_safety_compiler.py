from jrbar.animation import loop_duration_ms, parse_animation
from jrbar.presentation_compiler import (
    MIN_PRESENTATION_CYCLE_MS,
    MIN_SATURATED_RED_CYCLE_MS,
    compile_presentation_program,
)


def test_fast_loop_is_deterministically_slowed_to_the_global_limit__and_2_more() -> None:
    # --- scenario: fast_loop_is_deterministically_slowed_to_the_global_limit
    compiled = compile_presentation_program(
        "#00E5FF 100ms none\noff 100ms none\nrepeat"
    )

    assert compiled.accepted is True
    assert compiled.transformed is True
    animation = parse_animation(compiled.program)
    assert loop_duration_ms(animation) >= MIN_PRESENTATION_CYCLE_MS

    # --- scenario: saturated_red_uses_the_stricter_cadence
    compiled = compile_presentation_program(
        "#FF0000 100ms none\noff 100ms none\nrepeat"
    )

    assert compiled.accepted is True
    animation = parse_animation(compiled.program)
    assert loop_duration_ms(animation) >= MIN_SATURATED_RED_CYCLE_MS

    # --- scenario: invalid_program_fails_closed_to_static_off
    compiled = compile_presentation_program("not valid firmware text")

    assert compiled.accepted is False
    assert compiled.program == "off"



def test_safe_static_program_remains_byte_identical__and_2_more() -> None:
    # --- scenario: safe_static_program_remains_byte_identical
    compiled = compile_presentation_program("#00E5FF")

    assert compiled.accepted is True
    assert compiled.transformed is False
    assert compiled.program == "#00E5FF"

    # --- scenario: a_staggered_sweep_keeps_the_phase_its_author_wrote
    """A travelling head is not a flash, however fine its stagger.

    Sixty milliseconds between LEDs is exactly the case the old phase floor
    destroyed: it rounded every delay up to 250 ms, which collapsed a sweep
    into eight LEDs pulsing nearly in unison.
    """
    segments = "; ".join(
        f"{index}:#00E5FF 120ms pulse" + (f" {index * 60}ms" if index else "")
        for index in range(8)
    )
    compiled = compile_presentation_program(f"{segments}\nrepeat", led_count=8)

    assert compiled.accepted is True
    assert compiled.reasons == ()
    assert "60ms" in compiled.program
    assert "420ms" in compiled.program

    # --- scenario: a_field_wide_paint_written_untimed_still_gets_a_floor
    """An untimed whole-bar paint inside a loop is a strobe frame."""
    compiled = compile_presentation_program("#FFFFFF\noff 800ms cosine\nrepeat")

    assert compiled.accepted is True
    assert "phase_cadence_clamped" in compiled.reasons



def test_a_strobe_hidden_in_a_long_loop_is_slowed__and_2_more() -> None:
    # --- scenario: a_strobe_hidden_in_a_long_loop_is_slowed
    """The hole the text-only rule left open.

    Ten 60 ms lines make a 600 ms loop, which cleared every cadence floor the
    old compiler had while flashing the whole strip eight times a second.
    """
    from jrbar.animation import parse_animation
    from jrbar.flash_analysis import analyse

    program = "\n".join(["#FFFFFF 60ms none", "off 60ms none"] * 5 + ["repeat"])
    compiled = compile_presentation_program(program, led_count=8)

    assert compiled.accepted is True
    assert "loop_cadence_clamped" in compiled.reasons
    measured = analyse(parse_animation(compiled.program), led_count=8)
    assert measured.hertz <= 2.0

    # --- scenario: slowing_scales_the_whole_loop_and_keeps_its_shape
    """Whole-number scaling, so every stagger survives.

    Rounding phases one at a time is what collapses a stagger into unison, and
    a strip flashing in unison is the thing being prevented.
    """
    from jrbar.animation import parse_animation

    compiled = compile_presentation_program(
        "#FFFFFF 100ms none 50ms\noff 100ms none\nrepeat"
    )

    assert compiled.accepted is True
    steps = parse_animation(compiled.program).steps
    first = steps[0].segments[0].timing
    assert first.duration_ms / first.delay_ms == 2.0

    # --- scenario: a_travelling_wave_is_never_touched
    """The Working relay compiles byte-for-byte as it was written."""
    from jrbar._led_status_legacy import rolling_program

    program = rolling_program("#00E5FF", led_count=8)
    compiled = compile_presentation_program(program, led_count=8)

    assert compiled.accepted is True
    assert compiled.program == program
    assert compiled.reasons == ()



def test_knight_rider_is_never_touched__and_2_more() -> None:
    # --- scenario: knight_rider_is_never_touched
    from jrbar import motion_shapes

    lines = motion_shapes.bounce(
        "#00E5FF", "#000305", led_count=8, step_ms=140
    )
    program = "\n".join([*lines, "repeat"])
    compiled = compile_presentation_program(program, led_count=8)

    assert compiled.accepted is True
    assert compiled.program == program
    assert compiled.reasons == ()

    # --- scenario: saturated_red_keeps_the_stricter_measured_limit
    from jrbar.animation import parse_animation
    from jrbar.flash_analysis import analyse

    compiled = compile_presentation_program("#FF0000 200ms pulse\nrepeat")

    assert compiled.accepted is True
    measured = analyse(parse_animation(compiled.program), led_count=8)
    assert measured.hertz <= 1.0

    # --- scenario: the_compiler_is_a_pure_function_of_its_arguments
    """It runs on every device write and every Screen Bar frame source, so it
    is cached -- which is only correct while it stays pure."""
    program = "0:#00E5FF 120ms pulse; 1:#00E5FF 120ms pulse 60ms\nrepeat"
    first = compile_presentation_program(program, led_count=8)
    second = compile_presentation_program(program, led_count=8)

    assert first == second
    assert compile_presentation_program(program, led_count=2) != first

