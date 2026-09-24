"""The Dot's role: what it plays, and what it refuses to play."""

from __future__ import annotations

import pytest

from jrbar.animation import read_program
from jrbar.core_projection import _GLANCE_WHY
from jrbar.dot_role import (
    BLACK,
    DEFAULT_DOT_ROLE,
    DOT_LED_COUNT,
    DOT_ROLE_CHOICES,
    DotBeaconFacts,
    DotRole,
    DotRoleColors,
    apply_brightness_line,
    beacon_program,
    downsample_program,
    migrated_role_for_display,
    normalize_dot_role,
    plan_dot_surface,
    shift_program_phase,
    upsample_program,
    upsample_segment,
)
from jrbar.presentation_compiler import compile_presentation_program

# The exact bytes the live daemon was writing to /Volumes/PulseDot on
# 2026-09-10: an eight-colour chase on a two-LED device. Indices 0 and 1 are
# black in two of its three lit frames, so the Dot read as dead.
LIVE_DOT_DEFECT = (
    "brightness 10\n"
    "#000000 #000000 #000000 #000000 #02111E #000000 #000000 #000000 250ms none\n"
    "off 250ms none\n"
    "#000000 #000000 #02111E #000000 #000000 #02111E #000000 #000000 250ms none\n"
    "off 250ms none\n"
    "#02111E #000000 #000000 #000000 #000000 #000000 #000000 #02111E 250ms none\n"
    "off 250ms none\n"
    "repeat"
)


def stray_indices(program: str, led_count: int = DOT_LED_COUNT) -> tuple[int, ...]:
    from jrbar.device_writer import leds_addressed_beyond

    return leds_addressed_beyond(program, led_count)


# --- the role vocabulary ----------------------------------------------------


def test_roles_are_exactly_four_and_default_to_extend__and_2_more() -> None:
    # --- scenario: roles_are_exactly_four_and_default_to_extend
    assert DOT_ROLE_CHOICES == ("extend", "asks", "status", "call")
    assert DEFAULT_DOT_ROLE == "extend"

    # --- scenario: normalize_dot_role_never_refuses
    for value, expected in [
        ("asks", "asks"),
        ("STATUS", "status"),
        (" Call ", "call"),
        ("  extend  ", "extend"),
        (DotRole.ASKS, "asks"),
        ("beacon", "extend"),
        ("", "extend"),
        (None, "extend"),
        (17, "extend"),
    ]:
        assert normalize_dot_role(value) == expected

    # --- scenario: pinned_dot_displays_migrate_to_status
    for display in ["quota_runway", "studio", "battery"]:
        assert migrated_role_for_display(display) == "status"



def test_uncommitted_dot_displays_do_not_migrate__and_2_more() -> None:
    # --- scenario: uncommitted_dot_displays_do_not_migrate
    for display in ["agent", "", None, "dnd_dark"]:
        assert migrated_role_for_display(display) is None

    # --- scenario: the_live_defect_addresses_leds_the_dot_does_not_have
    assert stray_indices(LIVE_DOT_DEFECT) == (2, 3, 4, 5, 6, 7)

    # --- scenario: extend_never_addresses_leds_beyond_the_dot
    narrowed = downsample_program(LIVE_DOT_DEFECT, source_leds=8)
    assert narrowed is not None
    assert stray_indices(narrowed) == ()



def test_extend_keeps_the_strips_colours_and_never_goes_black_while_lit__and_2_more() -> None:
    # --- scenario: extend_keeps_the_strips_colours_and_never_goes_black_while_lit
    narrowed = downsample_program(LIVE_DOT_DEFECT, source_leds=8)
    assert "#02111E" in narrowed
    # Every lit frame of the strip lights at least one Dot band; the frame
    # whose only lit index was 4 used to arrive as two black LEDs.
    lit_frames = [
        line
        for line in narrowed.splitlines()
        if "#02111E" in line
    ]
    assert len(lit_frames) == 3

    # --- scenario: extend_downsamples_a_colour_list_by_bands
    program = "#FF0000 #FF0000 #FF0000 #FF0000 #00FF00 #00FF00 #00FF00 #00FF00 500ms none"
    assert downsample_program(program, source_leds=8) == "#FF0000 #00FF00 500ms none"

    # --- scenario: extend_takes_the_brightest_member_of_a_band_not_an_average
    program = "#000000 #000000 #000000 #00E5FF #000000 #000000 #000000 #000000 500ms none"
    narrowed = downsample_program(program, source_leds=8)
    assert narrowed == "#00E5FF #000000 500ms none"



def test_extend_leaves_a_whole_bar_program_alone__and_2_more() -> None:
    # --- scenario: extend_leaves_a_whole_bar_program_alone
    program = "#12E3B0 600ms pulse\noff 600ms cosine\nrepeat"
    # "Every LED" already means every LED the listening device has.
    assert downsample_program(program, source_leds=8) == program

    # --- scenario: extend_merges_indexed_segments_that_share_a_shape
    program = "; ".join(f"{index}:#00E5FF" for index in range(8))
    assert downsample_program(program, source_leds=8) == "0:#00E5FF 1:#00E5FF"

    # --- scenario: extend_keeps_a_staggered_wave_as_one_pulse_per_band
    program = "; ".join(
        f"{index}:#FF9F0A 420ms pulse {index * 180}ms" for index in range(8)
    )
    narrowed = downsample_program(program, source_leds=8)
    # The merge shortens the line to 1140 ms of the source's 1680; the hold
    # line after it restores the period so the Dot keeps the strip's clock.
    assert narrowed == (
        "0:#FF9F0A 420ms pulse 0ms; 1:#FF9F0A 420ms pulse 720ms\n"
        "0:#FF9F0A 1:#FF9F0A 540ms none"
    )



def test_extend_carries_brightness_repeat_and_timing_through_untouched__and_2_more() -> None:
    # --- scenario: extend_carries_brightness_repeat_and_timing_through_untouched
    narrowed = downsample_program(LIVE_DOT_DEFECT, source_leds=8)
    assert narrowed.splitlines()[0] == "brightness 10"
    assert narrowed.splitlines()[-1] == "repeat"
    assert "250ms" in narrowed

    # --- scenario: extend_refuses_a_program_it_cannot_parse
    assert downsample_program("roll sideways forever", source_leds=8) is None
    assert downsample_program("", source_leds=8) is None
    assert downsample_program(None, source_leds=8) is None

    # --- scenario: extend_is_a_no_op_when_the_source_is_already_narrow_enough
    assert downsample_program("0:#FF0000 1:#00FF00", source_leds=2) == "0:#FF0000 1:#00FF00"



def test_every_narrowed_program_passes_the_two_led_safety_gate__and_2_more() -> None:
    # --- scenario: every_narrowed_program_passes_the_two_led_safety_gate
    for program in [
        LIVE_DOT_DEFECT,
        "#FF0000 #FF0000 #FF0000 #FF0000 #00FF00 #00FF00 #00FF00 #00FF00 500ms none\nrepeat",
        "; ".join(f"{index}:#FF9F0A 420ms pulse {index * 180}ms" for index in range(8)) + "\nrepeat",
    ]:
        narrowed = downsample_program(program, source_leds=8)
        compiled = compile_presentation_program(narrowed, led_count=DOT_LED_COUNT)
        assert compiled.accepted
        # Narrowing never introduces a cadence problem of its own: whatever the
        # compiler says about the narrowed program, it said about the strip's.
        source = compile_presentation_program(program, led_count=8)
        assert compiled.reasons == source.reasons

    # --- scenario: beacon_is_dark_when_nobody_is_needed
    program, why, animated = beacon_program(DotBeaconFacts())
    assert program == "off"
    assert why == "idle"
    assert animated is False

    # --- scenario: beacon_pulses_amber_on_an_ask
    program, why, animated = beacon_program(DotBeaconFacts(ask_count=1))
    assert program.startswith(DotRoleColors().ask)
    assert why == "waiting"
    assert animated is True



def test_beacon_returns_to_dark_when_the_ask_resolves__and_2_more() -> None:
    # --- scenario: beacon_returns_to_dark_when_the_ask_resolves
    asking = DotBeaconFacts(ask_count=1, escalation_stage=3)
    assert beacon_program(asking)[0] != "off"
    assert beacon_program(DotBeaconFacts(ask_count=0, escalation_stage=3))[0] == "off"

    # --- scenario: beacon_shows_red_for_a_blocked_error_over_an_ask
    program, why, _animated = beacon_program(DotBeaconFacts(ask_count=2, blocked=True))
    assert program.startswith(DotRoleColors().blocked)
    assert why == "failed"

    # --- scenario: beacon_ignores_an_unseen_completion_unless_asked_to_care
    facts = DotBeaconFacts(unseen_completions=3)
    assert beacon_program(facts)[0] == "off"
    program, why, _animated = beacon_program(facts, include_completions=True)
    assert program.startswith(DotRoleColors().completion)
    assert why == "completed"



def test_an_ask_outranks_an_unseen_completion__and_2_more() -> None:
    # --- scenario: an_ask_outranks_an_unseen_completion
    facts = DotBeaconFacts(ask_count=1, unseen_completions=3)
    assert beacon_program(facts, include_completions=True)[0].startswith(DotRoleColors().ask)

    # --- scenario: escalation_visibly_tightens_the_pulse
    cycles = []
    for stage in range(4):
        program = beacon_program(DotBeaconFacts(ask_count=1, escalation_stage=stage))[0]
        on_ms = int(program.split()[1].removesuffix("ms"))
        cycles.append(on_ms)
    assert cycles == sorted(cycles, reverse=True)
    assert len(set(cycles)) == 4

    # --- scenario: no_beacon_state_ever_exceeds_two_hertz
    for stage in range(4):
        for facts_kwargs in [{"ask_count": 1}, {"blocked": True}, {"unseen_completions": 1}]:
            facts = DotBeaconFacts(escalation_stage=stage, **facts_kwargs)
            program = beacon_program(facts, include_completions=True)[0]
            if program == "off":
                continue
            animation, problems = read_program(program, led_count=DOT_LED_COUNT)
            assert not [problem for problem in problems if problem.code == "strobe"]
            compiled = compile_presentation_program(program, led_count=DOT_LED_COUNT)
            assert compiled.accepted and not compiled.transformed
            on_ms, off_ms = (
                int(line.split()[1].removesuffix("ms"))
                for line in program.splitlines()[:2]
            )
            assert 1000.0 / (on_ms + off_ms) <= 2.0
            assert animation.steps



def test_the_beacon_breathes_rather_than_blinks__and_2_more() -> None:
    # --- scenario: the_beacon_breathes_rather_than_blinks
    program = beacon_program(DotBeaconFacts(ask_count=1))[0]
    assert all("cosine" in line for line in program.splitlines()[:2])

    # --- scenario: the_beacon_leaves_resting_glow_to_the_device
    assert beacon_program(DotBeaconFacts())[0] == "off"
    assert "off" in beacon_program(DotBeaconFacts(ask_count=1))[0]

    # --- scenario: beacon_facts_clamp_rather_than_raise
    facts = DotBeaconFacts(ask_count=-4, unseen_completions=-1, escalation_stage=99)
    assert (facts.ask_count, facts.unseen_completions, facts.escalation_stage) == (0, 0, 3)



# --- plan_dot_surface: the whole surface ------------------------------------


def test_status_role_claims_nothing__and_2_more() -> None:
    # --- scenario: status_role_claims_nothing
    assert plan_dot_surface(role="status", strip_program=LIVE_DOT_DEFECT) is None

    # --- scenario: extend_with_nothing_to_extend_claims_nothing
    assert plan_dot_surface(role="extend", strip_program=None) is None

    # --- scenario: asks_role_needs_no_strip_at_all
    plan = plan_dot_surface(role="asks", facts=DotBeaconFacts(ask_count=1), strip_program=None)
    assert plan is not None
    assert plan.role == "asks"
    assert plan.why == "waiting"
    assert plan.led_count == DOT_LED_COUNT



def test_asks_role_ignores_the_strip_even_when_there_is_one__and_2_more() -> None:
    # --- scenario: asks_role_ignores_the_strip_even_when_there_is_one
    plan = plan_dot_surface(role="asks", facts=DotBeaconFacts(), strip_program=LIVE_DOT_DEFECT)
    assert plan.program == "off"

    # --- scenario: extend_plan_reports_the_strips_state_as_its_why
    class Semantic:
        value = "active"

    plan = plan_dot_surface(
        role="extend", semantic=Semantic(), strip_program=LIVE_DOT_DEFECT, strip_led_count=8
    )
    assert plan.why == "working"
    assert plan.role == "extend"
    assert stray_indices(plan.program) == ()

    # --- scenario: extend_why_table_matches_the_projections
    from jrbar.dot_role import _WHY_FOR_SEMANTIC

    assert _WHY_FOR_SEMANTIC == _GLANCE_WHY



def test_plan_applies_the_dots_brightness_as_one_leading_line__and_2_more() -> None:
    # --- scenario: plan_folds_the_dots_cap_into_the_programs_own_line
    """The strip's authored ``brightness 10`` and the Dot's cap of 42 are
    one line on the Dot, ``round(10 * 42 / 255)``: never two lines, and
    never above the cap (the shared rule, ``led_status.fold_brightness``)."""
    plan = plan_dot_surface(
        role="extend", strip_program=LIVE_DOT_DEFECT, strip_led_count=8, brightness=42
    )
    lines = plan.program.splitlines()
    assert lines[0] == "brightness 2"
    assert sum(1 for line in lines if line.startswith("brightness")) == 1

    # --- scenario: full_brightness_needs_no_line_at_all
    plan = plan_dot_surface(role="asks", facts=DotBeaconFacts(ask_count=1), brightness=255)
    assert not plan.program.startswith("brightness")

    # --- scenario: apply_brightness_line_clamps_and_multiplies
    assert apply_brightness_line("brightness 9\n#FF0000", 300) == "brightness 9\n#FF0000"
    assert apply_brightness_line("brightness 9\n#FF0000", -5) == "brightness 0\n#FF0000"
    assert apply_brightness_line("brightness 200\n#FF0000", 128) == "brightness 100\n#FF0000"
    assert apply_brightness_line("#FF0000", 64) == "brightness 64\n#FF0000"
    assert apply_brightness_line("#FF0000", None) == "#FF0000"



def test_unknown_role_plans_as_extend():
    plan = plan_dot_surface(role="whatever", strip_program=LIVE_DOT_DEFECT, strip_led_count=8)
    assert plan.role == "extend"


# --- skew compensation: the late restart plays the strip's phase ------------


def _firmware_frames(program: str, *, start_ms: int, frames: int, step_ms: int, led_count: int = 2):
    """The firmware engine's frames, stepped the way the device steps: a
    frame at a time from the parse (it advances a line per step, so a single
    jump across laps lands on the wrong line). The RAW engine: the app's
    renderer facade compiles every program first, which is not what the
    device does with the bytes it is sent."""
    from jrbar.led_wasm import RawSdLedWasmController

    engine = RawSdLedWasmController(led_count)
    assert engine.parse(program, 0).ok, program
    for moment in range(0, start_ms, 16):
        engine.step(moment)
    return [engine.step(start_ms + index * step_ms) for index in range(frames)]


def _worst_code_gap(left, right) -> int:
    return max(
        abs(a - b)
        for frame_a, frame_b in zip(left, right)
        for led_a, led_b in zip(frame_a, frame_b)
        for a, b in zip(led_a, led_b)
    )


def test_shift_program_phase_reanchors_the_loop_by_the_skew__and_3_more() -> None:
    # --- scenario: a_pulse_cut_at_its_peak_is_its_two_cosine_halves
    """A ``pulse`` is exactly two ``cosine`` halves on the firmware, so a cut
    at the peak is exact -- the rotation used to refuse every pulse."""
    assert shift_program_phase("#FF0000 500ms pulse\noff 500ms\nrepeat", 250) == (
        "off 250ms cosine\noff 500ms\n#FF0000 250ms cosine\nrepeat"
    )

    # --- scenario: a_cut_on_a_step_boundary_is_a_pure_rotation
    assert shift_program_phase("#FF0000 500ms\noff 500ms\nrepeat", 500) == (
        "off 500ms\n#FF0000 500ms\nrepeat"
    )

    # --- scenario: a_shift_of_a_whole_lap_changes_nothing
    program = "#FF0000 500ms\noff 500ms\nrepeat"
    assert shift_program_phase(program, 1000) == program

    # --- scenario: a_mid_flight_cut_plays_the_offset_program_on_the_firmware
    """Written now, the rotated loop plays what the original plays
    ``shift`` ms after its own start -- within two codes on the real
    firmware engine, pulses and eased curves alike, laps later."""
    for source, shift in (
        ("#FF0000 1000ms pulse\noff 500ms\nrepeat", 250),
        ("#FF0000 1000ms pulse\noff 500ms\nrepeat", 777),
        ("#00FF00 800ms cosine\n#000044 600ms ease-in-out\nrepeat", 333),
        ("#FF0000 #0000FF\nroll-right 2s\nrepeat", 1234),
        ("#FF0000 250ms none\noff 250ms none\nrepeat", 100),
        ("0:#FF0000 400ms none; 1:#00FF00 300ms none 100ms\noff 250ms none\nrepeat", 211),
    ):
        rotated = shift_program_phase(source, shift)
        assert rotated is not None
        lap = _loop_span_ms(source, DOT_LED_COUNT)
        assert _loop_span_ms(rotated, DOT_LED_COUNT) == lap
        played = _firmware_frames(rotated, start_ms=3 * lap, frames=160, step_ms=9)
        expected = _firmware_frames(source, start_ms=3 * lap + shift, frames=160, step_ms=9)
        assert _worst_code_gap(played, expected) <= 2, (source, shift, rotated)


def test_the_plan_is_period_locked_and_carries_no_phase__and_2_more() -> None:
    # --- scenario: an_extend_plan_is_timed_at_the_write_boundary
    """The plan narrows; the write boundary rotates and retimes from the
    strip's recorded start (``linked_sync.apply_device_timing``), so the
    plan is the same whenever it is written and reports the strip's lap."""
    plan = plan_dot_surface(
        role="extend",
        strip_program="#FF0000 500ms\noff 500ms\nrepeat",
        strip_led_count=8,
    )
    assert plan is not None
    assert plan.timed is True
    assert plan.lap_ms == 1000
    assert plan.rung == "brightest"
    assert plan.program == "#FF0000 500ms\noff 500ms\nrepeat"
    assert "lock:brightest" in plan.reasons

    # --- scenario: a_pulse_program_is_planned_not_refused
    plan = plan_dot_surface(
        role="extend",
        strip_program="#FF0000 500ms pulse\noff 500ms\nrepeat",
        strip_led_count=8,
    )
    assert plan is not None and plan.program == "#FF0000 500ms pulse\noff 500ms\nrepeat"

    # --- scenario: the_scanner_keeps_the_strips_period_on_the_dot
    """The live regression: the scanner narrowed to two bands read as a
    blink at two LEDs, the Dot's own gate slowed it by 2x (1606 vs 3212 ms)
    and the pair ran different loops forever. The Dot steps down to band
    averages instead, which keep the strip's period."""
    scanner = next(program for name, program, leds in CORPUS if name == "effect_scanner_8led")
    plan = plan_dot_surface(role="extend", strip_program=scanner, strip_led_count=8)
    compiled_strip = compile_presentation_program(scanner, led_count=8).program
    compiled_dot = compile_presentation_program(plan.program, led_count=DOT_LED_COUNT).program
    assert plan.rung == "average"
    assert _loop_span_ms(compiled_dot, DOT_LED_COUNT) == _loop_span_ms(compiled_strip, 8)


# --- the write boundary: no program for the wrong device, ever --------------


@pytest.fixture
def dot_volume(tmp_path):
    """A directory the LED-count table classifies as a two-LED Dot."""
    volume = tmp_path / "PulseDot"
    volume.mkdir()
    (volume / "LEDS.LED").write_text("off\n", encoding="utf-8")
    return volume


def test_a_wide_program_is_refused_at_the_write_boundary__and_2_more(dot_volume) -> None:
    # --- scenario: a_wide_program_is_refused_at_the_write_boundary
    from jrbar.device_writer import DeviceWriteError, write_led_program

    with pytest.raises(DeviceWriteError) as refusal:
        write_led_program(LIVE_DOT_DEFECT, device_path=dot_volume, dry_run=True)
    assert "2-LED device" in str(refusal.value)

    # --- scenario: an_indexed_program_past_the_last_led_is_refused_too
    from jrbar.device_writer import DeviceWriteError, write_led_program

    with pytest.raises(DeviceWriteError):
        write_led_program("0:#FF0000; 5:#00FF00", device_path=dot_volume, dry_run=True)

    # --- scenario: the_narrowed_program_is_accepted_at_the_same_boundary
    from jrbar.device_writer import write_led_program

    narrowed = downsample_program(LIVE_DOT_DEFECT, source_leds=8)
    assert write_led_program(narrowed, device_path=dot_volume, dry_run=True).name == "LEDS.LED"



def test_every_beacon_state_is_accepted_at_the_write_boundary(dot_volume) -> None:
    for stage in range(4):
        from jrbar.device_writer import write_led_program

        for kwargs in ({"ask_count": 1}, {"blocked": True}, {"unseen_completions": 1}, {}):
            program = beacon_program(
                DotBeaconFacts(escalation_stage=stage, **kwargs), include_completions=True
            )[0]
            write_led_program(program, device_path=dot_volume, dry_run=True)


def test_an_eight_led_program_still_reaches_an_eight_led_strip(tmp_path):
    from jrbar.device_writer import write_led_program

    volume = tmp_path / "SidePulse"
    volume.mkdir()
    (volume / "LEDS.LED").write_text("off\n", encoding="utf-8")
    write_led_program(LIVE_DOT_DEFECT, device_path=volume, dry_run=True)


# --- the live 2026-09-10 defect: an LED painted once, then stranded ---------

#: Exactly what the SidePulse Pro was playing when the owner caught the Dot
#: holding one lit LED it could not explain. A whole-strip finite cue: four
#: phases, one second, eight times.
LIVE_PRO_FINITE_CUE = (
    "brightness 59\n"
    "#791BFF 180ms none\n"
    "off 120ms none\n"
    "#791BFF 180ms none\n"
    "off 520ms none\n"
    "repeat 8"
)

#: And exactly what was on /Volumes/PulseDot/LEDS.LED beside it. LED 1 is
#: addressed on line one and never again, so it held #14732D -- the old
#: two-LED status green, from a PREVIOUS program -- indefinitely. The owner:
#: "the first LED is still showing bluish-green".
LIVE_DOT_STRANDED = (
    "brightness 59\n"
    "0:#722CA1 1:#14732D 250ms none\n"
    "0:#000000 250ms none\n"
    "0:#722CA1 250ms none\n"
    "0:#000000 250ms none\n"
    "0:#000000 1500ms none\n"
    "repeat 8"
)


def unaddressed_leds(program: str, led_count: int = DOT_LED_COUNT) -> dict[int, int]:
    """LED -> the longest run of consecutive paint lines that never name it.

    The invariant every emitted program has to satisfy: an LED that a line
    does not address holds whatever it was last given, so a run longer than
    one line is an LED showing something the current line never asked for --
    and at the end of a bounded cue, forever.
    """
    from jrbar.animation import ColorList, IndexedPaint, PaintStep, WholeBar, read_program

    animation, _problems = read_program(program, led_count=led_count)
    runs = dict.fromkeys(range(led_count), 0)
    worst = dict.fromkeys(range(led_count), 0)
    for step in animation.steps:
        if type(step) is not PaintStep:
            continue
        addressed: set[int] = set()
        for segment in step.segments:
            if type(segment) in (WholeBar, ColorList):
                addressed = set(range(led_count))
                break
            if type(segment) is IndexedPaint:
                addressed.update(int(index) for index, _color in segment.assignments)
        for led in range(led_count):
            runs[led] = 0 if led in addressed else runs[led] + 1
            worst[led] = max(worst[led], runs[led])
    return worst


def test_the_live_stranded_dot_program_is_exactly_the_defect__and_2_more() -> None:
    # --- scenario: the_live_stranded_dot_program_is_exactly_the_defect
    assert unaddressed_leds(LIVE_DOT_STRANDED) == {0: 0, 1: 4}
    assert "#14732D" not in LIVE_PRO_FINITE_CUE

    # --- scenario: the_pros_finite_cue_narrows_with_every_led_addressed_every_line
    narrowed = downsample_program(LIVE_PRO_FINITE_CUE, source_leds=8)
    assert narrowed is not None
    assert max(unaddressed_leds(narrowed).values()) == 0

    # --- scenario: the_narrowed_cue_carries_the_sources_timing_easing_and_repeat
    narrowed = downsample_program(LIVE_PRO_FINITE_CUE, source_leds=8)
    lines = narrowed.splitlines()
    assert lines[0] == "brightness 59"
    assert lines[-1] == "repeat 8"
    # The source's four phases, at the source's four durations. The live
    # defect ran 250/250/250/250/1500 against a source of 180/120/180/520.
    assert [line for line in lines[1:-1]] == [
        "#791BFF 180ms none",
        "off 120ms none",
        "#791BFF 180ms none",
        "off 520ms none",
    ]



def test_narrowing_invents_no_colour_the_source_did_not_have__and_2_more() -> None:
    # --- scenario: narrowing_invents_no_colour_the_source_did_not_have
    import re

    narrowed = downsample_program(LIVE_PRO_FINITE_CUE, source_leds=8)
    source = set(re.findall(r"#[0-9A-Fa-f]{6}", LIVE_PRO_FINITE_CUE)) | {"#000000"}
    assert set(re.findall(r"#[0-9A-Fa-f]{6}", narrowed)) <= source

    # --- scenario: narrowing_is_a_pure_function_of_the_source_program
    """No state from an earlier program can reach the conversion.

    The stranded green was read back as evidence that the converter had
    invented a colour. It had not -- but it also could not have SEEN that the
    device was still showing one, and a converter whose output depends on
    what happened to be on the hardware cannot be reasoned about at all.
    """
    once = downsample_program(LIVE_PRO_FINITE_CUE, source_leds=8)
    # Narrow something else in between; the answer may not move.
    downsample_program(LIVE_DOT_STRANDED, source_leds=2)
    downsample_program(LIVE_DOT_DEFECT, source_leds=8)
    assert downsample_program(LIVE_PRO_FINITE_CUE, source_leds=8) == once

    # --- scenario: a_source_line_that_names_one_band_still_paints_the_other
    narrowed = downsample_program("0:#00E5FF 500ms\n0:#000000 500ms\nrepeat", source_leds=8)
    assert max(unaddressed_leds(narrowed).values()) == 0
    assert narrowed.splitlines()[0].endswith("1:#000000 500ms")



# --- the same invariants over the whole effect corpus -----------------------


def effect_corpus() -> list[tuple[str, str, int]]:
    """Every program the app can put on a strip (scripts/review_effects.py)."""
    import sys
    from pathlib import Path as _Path

    root = _Path(__file__).resolve().parents[1]
    if str(root / "scripts") not in sys.path:
        sys.path.insert(0, str(root / "scripts"))
    from review_effects import builtin_programs, effect_programs

    return [*effect_programs(), *builtin_programs()]


CORPUS = effect_corpus()


def test_the_corpus_is_the_real_one_and_not_empty__and_2_more() -> None:
    # --- scenario: the_corpus_is_the_real_one_and_not_empty
    assert len(CORPUS) > 50
    assert any(name.startswith("effect_") for name, _program, _leds in CORPUS)

    # --- scenario: no_narrowed_program_ever_strands_an_led
    for name, program, source_leds in CORPUS:
        narrowed = downsample_program(program, source_leds=source_leds)
        if narrowed is None:
            continue  # refused outright, which is the other safe answer
        assert stray_indices(narrowed) == ()
        worst = unaddressed_leds(narrowed)
        assert max(worst.values()) == 0, f"{name}: LEDs held across lines: {worst}"

    # --- scenario: no_narrowed_program_ever_invents_a_colour
    for name, program, source_leds in CORPUS:
        import re

        narrowed = downsample_program(program, source_leds=source_leds)
        if narrowed is None:
            continue
        # Black is always available: it is what "this LED is not lit on this
        # line" is spelled as, and `off` is not legal in indexed form.
        source = {
            color.upper() for color in re.findall(r"#[0-9A-Fa-f]{6}", program)
        } | {"#000000"}
        emitted = {color.upper() for color in re.findall(r"#[0-9A-Fa-f]{6}", narrowed)}
        assert emitted <= source, f"{name}: invented {sorted(emitted - source)}"



def _shape(program: str, led_count: int):
    """(brightness levels, repeat markers, per-line durations) of a program."""
    from jrbar.animation import (
        BrightnessStep,
        PaintStep,
        RepeatStep,
        read_program,
        step_duration_ms,
    )

    animation, _problems = read_program(program, led_count=led_count)
    return (
        tuple(step.level for step in animation.steps if type(step) is BrightnessStep),
        tuple(step.count for step in animation.steps if type(step) is RepeatStep),
        tuple(
            step_duration_ms(step)
            for step in animation.steps
            if type(step) is PaintStep
        ),
    )


def test_narrowing_keeps_the_strips_brightness_repeat_and_line_count__and_2_more() -> None:
    # --- scenario: narrowing_keeps_the_strips_brightness_repeat_and_loop_span
    for name, program, source_leds in CORPUS:
        """Whatever the strip's clock is, the Dot runs the same one.

        The same brightness, the same repeat markers, and the same total
        paint-line span: a line may get shorter, and exactly one thing
        shortens it -- a wave staggered across four source LEDs collapsing
        into one pulse in one band, which is ``downsample_step``'s documented
        behaviour and is what the wave looks like on two LEDs. What it
        shortens is then paid back as a hold line, so a shortened line adds
        at most one line and the loop's period is the source's, unchanged.
        """
        from jrbar.animation import errors_only, read_program

        narrowed = downsample_program(program, source_leds=source_leds)
        if narrowed is None:
            continue
        _animation, problems = read_program(program, led_count=source_leds)
        if errors_only(problems):
            continue
        source_brightness, source_repeats, source_lines = _shape(program, source_leds)
        narrow_brightness, narrow_repeats, narrow_lines = _shape(narrowed, DOT_LED_COUNT)
        assert narrow_brightness == source_brightness
        assert narrow_repeats == source_repeats
        assert len(source_lines) <= len(narrow_lines) <= 2 * len(source_lines)
        assert sum(narrow_lines) == sum(source_lines), (
            f"{name}: loop span {sum(narrow_lines)} != {sum(source_lines)}"
        )
        assert max(narrow_lines) <= max(source_lines)

    # --- scenario: narrowing_uses_only_easings_the_source_used
    for name, program, source_leds in CORPUS:
        """Easing is how a step FEELS. Narrowing may not invent a feeling.

        The single exception is the hold line's ``none`` -- a snap to the
        colour the band already shows, which invents no motion at all.

        (Durations are checked numerically above -- ``1.6s`` and ``1600ms`` are
        the same instruction spelled two ways, and the renderer picks the cheaper
        spelling for the bytes.)
        """
        import re

        narrowed = downsample_program(program, source_leds=source_leds)
        if narrowed is None:
            continue
        pattern = r"\b(?:none|linear|pulse|cosine|ease)\b"
        assert set(re.findall(pattern, narrowed)) - {"none"} <= set(
            re.findall(pattern, program)
        )

    # --- scenario: a_reassert_of_a_narrowed_program_still_addresses_every_led
    """The 240s reassert drops the program's first paint line on purpose.

    That is safe only if no LED is named ONLY on the first line. The Dot's
    old heartbeat named its second LED exactly there, so every reassert
    wrote a program that could not address it at all -- a second,
    independent route to the same stranded LED.
    """
    from jrbar.led_status import _steady_state_variant

    narrowed = downsample_program(LIVE_PRO_FINITE_CUE, source_leds=8)
    for variant in (narrowed, _steady_state_variant(narrowed)):
        assert max(unaddressed_leds(variant).values()) == 0
    # And the old shape is exactly what that rule punishes.
    assert max(unaddressed_leds(_steady_state_variant(LIVE_DOT_STRANDED)).values()) > 0


# --- the Dot keeps the strip's clock ----------------------------------------


def _loop_span_ms(program: str, led_count: int) -> int:
    """The span of the section that repeats, or of the whole one-shot."""
    from jrbar.animation import (
        animation_duration_ms,
        loop_duration_ms,
        read_program,
    )

    animation, _problems = read_program(program, led_count=led_count)
    loop = loop_duration_ms(animation)
    return loop if loop is not None else animation_duration_ms(animation)


def test_downsample_preserves_line_span_of_a_chase__and_3_more() -> None:
    # --- scenario: the_live_chases_loop_is_the_strips_1600ms_not_800
    """The program the Pro was playing when the drift was measured: eight
    staggered 200 ms pulses, one per LED, so the line spans 1600 ms. The
    merge alone emitted an 800 ms Dot line and the pair drifted the first
    lap; the hold line pays the missing span back."""
    chase = (
        "brightness 39\n"
        "#000000 40ms cosine\n"
        "1:#1B3B6F 200ms pulse 0ms; 2:#1B3B6F 200ms pulse 200ms; "
        "3:#1B3B6F 200ms pulse 400ms; 4:#1B3B6F 200ms pulse 600ms; "
        "5:#1B3B6F 200ms pulse 800ms; 6:#1B3B6F 200ms pulse 1000ms; "
        "7:#1B3B6F 200ms pulse 1200ms; 0:#1B3B6F 200ms pulse 1400ms\n"
        "repeat"
    )
    narrowed = downsample_program(chase, source_leds=8)
    assert _loop_span_ms(narrowed, DOT_LED_COUNT) == _loop_span_ms(chase, 8) == 1640

    # --- scenario: the_hold_line_paints_every_band_with_a_snap
    """The hold is a pause, not a motion: both bands named in one segment
    with ``none`` -- the easing that jumps to its target and holds."""
    from jrbar.animation import IndexedPaint, PaintStep, read_program

    animation, _problems = read_program(narrowed, led_count=DOT_LED_COUNT)
    hold = [step for step in animation.steps if type(step) is PaintStep][-1]
    assert len(hold.segments) == 1
    segment = hold.segments[0]
    assert type(segment) is IndexedPaint
    assert {index for index, _color in segment.assignments} == {0, 1}
    assert segment.timing.duration_ms == 800
    assert segment.timing.easing == "none"

    # --- scenario: every_corpus_program_keeps_its_loop_span
    for name, program, source_leds in CORPUS:
        narrowed = downsample_program(program, source_leds=source_leds)
        if narrowed is None:
            continue  # refused outright, which is the other safe answer
        assert _loop_span_ms(narrowed, DOT_LED_COUNT) == _loop_span_ms(
            program, source_leds
        ), name

    # --- scenario: a_shifted_narrowed_program_still_keeps_the_loop_span
    """Re-anchoring for the measured write skew must not stretch the loop
    either: the rotated program is the same cycle from another start."""
    shifted = shift_program_phase(downsample_program(chase, source_leds=8), 12)
    assert shifted is not None
    assert _loop_span_ms(shifted, DOT_LED_COUNT) == _loop_span_ms(chase, 8)


# --- the other direction: the Screen Bar mirroring a lone Dot ---------------


def test_upsample_widens_a_dot_program_for_the_screen_bar__and_3_more() -> None:
    # --- scenario: a_two_colour_list_becomes_two_bands_of_four
    """Bar LED j takes dot LED j // 4: the bar compiles at eight, so the
    Dot's two colours land as two bands of four with the timing intact."""
    assert upsample_program(
        "#FF0000 #00FF00 500ms cosine\nrepeat", source_leds=2, led_count=8
    ) == (
        "#FF0000 #FF0000 #FF0000 #FF0000 #00FF00 #00FF00 #00FF00 #00FF00 "
        "500ms cosine\nrepeat"
    )

    # --- scenario: a_list_short_of_the_source_pads_with_black
    """The firmware's "past the list goes dark" rule, kept: a one-colour
    list on the source cannot name the second band, so it pads with black."""
    from jrbar.animation import ColorList, Timing

    segment = upsample_segment(
        ColorList(colors=("#FF0000",), timing=Timing(duration_ms=500)),
        source_leds=2,
        led_count=8,
    )
    assert segment.colors == ("#FF0000",) * 4 + (BLACK,) * 4

    # --- scenario: an_indexed_paint_expands_each_source_led_to_its_band
    assert upsample_program("0:#FF0000 400ms", source_leds=2, led_count=8) == (
        "0:#FF0000 1:#FF0000 2:#FF0000 3:#FF0000 400ms"
    )

    # --- scenario: indices_past_the_source_are_dropped
    assert upsample_program(
        "0:#FF0000 1:#00FF00 5:#0000FF 400ms", source_leds=2, led_count=8
    ) == (
        "0:#FF0000 1:#FF0000 2:#FF0000 3:#FF0000 "
        "4:#00FF00 5:#00FF00 6:#00FF00 7:#00FF00 400ms"
    )
    # A line naming only out-of-range LEDs takes no time on either device;
    # with nothing left to play there is nothing to honestly widen.
    assert upsample_program("5:#0000FF 400ms", source_leds=2, led_count=8) is None



def test_upsample_passes_directives_through_and_refuses_garbage__and_2_more() -> None:
    # --- scenario: brightness_roll_repeat_and_comments_pass_through
    widened = upsample_program(
        "brightness 128\n// keep me\nroll-left 2s\n#FF0000 #00FF00 500ms\nrepeat 3",
        source_leds=2,
        led_count=8,
    )
    lines = widened.splitlines()
    assert lines[0] == "brightness 128"
    assert lines[1] == "// keep me"
    assert lines[2] == "roll-left 2s"
    assert lines[-1] == "repeat 3"

    # --- scenario: a_whole_bar_needs_no_widening
    program = "#12E3B0 600ms pulse\noff 600ms cosine\nrepeat"
    assert upsample_program(program, source_leds=2, led_count=8) == program

    # --- scenario: upsample_refuses_a_program_it_cannot_parse
    assert upsample_program("roll sideways forever", source_leds=2, led_count=8) is None
    assert upsample_program("", source_leds=2, led_count=8) is None
    assert upsample_program(None, source_leds=2, led_count=8) is None



def test_upsample_round_trips_through_downsample() -> None:
    """Widening then narrowing is lossless: the Dot's band is one source
    LED, so down-upsample returns exactly what a straight 2->2 pass gives."""
    saw_dot_program = False
    for name, program, source_leds in CORPUS:
        if source_leds != DOT_LED_COUNT:
            continue
        saw_dot_program = True
        widened = upsample_program(program, source_leds=2, led_count=8)
        assert widened is not None, name
        # Widening preserves the loop's span too: the bar runs the Dot's
        # clock, not a stretched or compressed copy of it.
        assert _loop_span_ms(widened, 8) == _loop_span_ms(program, source_leds), name
        assert (
            downsample_program(widened, source_leds=8, led_count=2)
            == downsample_program(program, source_leds=2, led_count=2)
        ), name
    assert saw_dot_program



# --- the period lock and pulse rotation over the whole corpus ----------------


def test_the_period_lock_holds_for_every_corpus_program__and_1_more() -> None:
    # --- scenario: every_dot_plan_compiles_to_the_strips_period
    """The strip's program is compiled once at eight LEDs and the Dot is
    derived from that; whatever rung the Dot lands on, its compiled loop is
    the strip's compiled loop, or it holds a still colour (no loop at all).
    Before the lock the scanner ran 1606 ms on the strip and 3212 on the Dot."""
    from jrbar.animation import loop_duration_ms, read_program

    checked = 0
    for name, program, source_leds in CORPUS:
        if source_leds == DOT_LED_COUNT:
            continue
        strip = compile_presentation_program(program, led_count=source_leds)
        if not strip.accepted:
            continue
        strip_loop = loop_duration_ms(read_program(strip.program, led_count=source_leds)[0])
        plan = plan_dot_surface(role="extend", strip_program=program, strip_led_count=source_leds)
        assert plan is not None, name
        dot = compile_presentation_program(plan.program, led_count=DOT_LED_COUNT)
        assert dot.accepted, name
        dot_loop = loop_duration_ms(read_program(dot.program, led_count=DOT_LED_COUNT)[0])
        if plan.rung == "static":
            assert dot_loop is None, name
        else:
            assert dot_loop == strip_loop, f"{name}: dot {dot_loop} != strip {strip_loop} ({plan.rung})"
        checked += 1
    assert checked > 20

    # --- scenario: no_rotation_of_a_narrowed_corpus_program_is_refused
    """Pulse programs were refused at a mid-flight cut (64 of 320 attempts
    in the research corpus), so those Dots played unshifted and started a
    whole skew late. Every one rotates now."""
    for name, program, source_leds in CORPUS:
        narrowed = downsample_program(program, source_leds=source_leds)
        if narrowed is None or "repeat" not in narrowed:
            continue
        for shift in (13.3, 25.6, 56.3, 81.4):
            assert shift_program_phase(narrowed, shift) is not None, (name, shift)


def test_the_lights_frame_asks_only_for_role_and_why__and_1_more(monkeypatch) -> None:
    # --- scenario: describing_an_extend_dot_plans_no_program
    """The lights frame reads the plan's role and ``why`` on every build;
    ``describe_only`` gives it those without working out the Dot's
    continuation, which cost the main thread about 50 ms a frame."""
    import sys
    from pathlib import Path

    from jrbar import dot_continue, linked_sync

    scripts = str(Path(__file__).resolve().parents[1] / "scripts")
    if scripts not in sys.path:
        sys.path.insert(0, scripts)
    from review_effects import effect_programs

    comet = next(p for n, p, leds in effect_programs() if n == "effect_comet_8led")

    def refuse(*_args, **_kwargs):
        raise AssertionError("the lights frame planned the Dot's program")

    monkeypatch.setattr(dot_continue, "continue_program", refuse)
    monkeypatch.setattr(linked_sync, "period_locked_dot", refuse)
    plan = plan_dot_surface(
        role="extend", semantic="active", strip_program=comet, extend_style="continue", describe_only=True
    )
    assert plan is not None and plan.program == "" and plan.why == "working" and plan.role == "extend"

    # --- scenario: nothing_to_extend_is_still_nothing
    assert plan_dot_surface(role="extend", strip_program=None, describe_only=True) is None
