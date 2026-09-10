"""The Dot's role: what it plays, and what it refuses to play."""

from __future__ import annotations

import pytest

from jrbar.animation import read_program
from jrbar.core_projection import _GLANCE_WHY
from jrbar.dot_role import (
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


def test_roles_are_exactly_three_and_default_to_extend():
    assert DOT_ROLE_CHOICES == ("extend", "asks", "status")
    assert DEFAULT_DOT_ROLE == "extend"


@pytest.mark.parametrize(
    "value, expected",
    [
        ("asks", "asks"),
        ("STATUS", "status"),
        ("  extend  ", "extend"),
        (DotRole.ASKS, "asks"),
        ("beacon", "extend"),
        ("", "extend"),
        (None, "extend"),
        (17, "extend"),
    ],
)
def test_normalize_dot_role_never_refuses(value, expected):
    # A typo must not put the Dot into a state nobody asked for.
    assert normalize_dot_role(value) == expected


@pytest.mark.parametrize("display", ["quota_runway", "studio", "battery"])
def test_pinned_dot_displays_migrate_to_status(display):
    assert migrated_role_for_display(display) == "status"


@pytest.mark.parametrize("display", ["agent", "", None, "dnd_dark"])
def test_uncommitted_dot_displays_do_not_migrate(display):
    assert migrated_role_for_display(display) is None


# --- extend: the strip, narrowed --------------------------------------------


def test_the_live_defect_addresses_leds_the_dot_does_not_have():
    # The bug as observed, stated as a test so it cannot come back quietly.
    assert stray_indices(LIVE_DOT_DEFECT) == (2, 3, 4, 5, 6, 7)


def test_extend_never_addresses_leds_beyond_the_dot():
    narrowed = downsample_program(LIVE_DOT_DEFECT, source_leds=8)
    assert narrowed is not None
    assert stray_indices(narrowed) == ()


def test_extend_keeps_the_strips_colours_and_never_goes_black_while_lit():
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


def test_extend_downsamples_a_colour_list_by_bands():
    program = "#FF0000 #FF0000 #FF0000 #FF0000 #00FF00 #00FF00 #00FF00 #00FF00 500ms none"
    assert downsample_program(program, source_leds=8) == "#FF0000 #00FF00 500ms none"


def test_extend_takes_the_brightest_member_of_a_band_not_an_average():
    program = "#000000 #000000 #000000 #00E5FF #000000 #000000 #000000 #000000 500ms none"
    narrowed = downsample_program(program, source_leds=8)
    assert narrowed == "#00E5FF #000000 500ms none"


def test_extend_leaves_a_whole_bar_program_alone():
    program = "#12E3B0 600ms pulse\noff 600ms cosine\nrepeat"
    # "Every LED" already means every LED the listening device has.
    assert downsample_program(program, source_leds=8) == program


def test_extend_merges_indexed_segments_that_share_a_shape():
    program = "; ".join(f"{index}:#00E5FF" for index in range(8))
    assert downsample_program(program, source_leds=8) == "0:#00E5FF 1:#00E5FF"


def test_extend_keeps_a_staggered_wave_as_one_pulse_per_band():
    # Four staggered pulses collapsed onto one LED is flicker; the earliest
    # delay in each band is the wave arriving, which is what it looks like.
    program = "; ".join(
        f"{index}:#FF9F0A 420ms pulse {index * 180}ms" for index in range(8)
    )
    narrowed = downsample_program(program, source_leds=8)
    assert narrowed == "0:#FF9F0A 420ms pulse 0ms; 1:#FF9F0A 420ms pulse 720ms"


def test_extend_carries_brightness_repeat_and_timing_through_untouched():
    narrowed = downsample_program(LIVE_DOT_DEFECT, source_leds=8)
    assert narrowed.splitlines()[0] == "brightness 10"
    assert narrowed.splitlines()[-1] == "repeat"
    assert "250ms" in narrowed


def test_extend_refuses_a_program_it_cannot_parse():
    # Refuse, never guess: a device showing its previous program beats a
    # device showing a mangled one.
    assert downsample_program("roll sideways forever", source_leds=8) is None
    assert downsample_program("", source_leds=8) is None
    assert downsample_program(None, source_leds=8) is None


def test_extend_is_a_no_op_when_the_source_is_already_narrow_enough():
    assert downsample_program("0:#FF0000 1:#00FF00", source_leds=2) == "0:#FF0000 1:#00FF00"


@pytest.mark.parametrize(
    "program",
    [
        LIVE_DOT_DEFECT,
        "#FF0000 #FF0000 #FF0000 #FF0000 #00FF00 #00FF00 #00FF00 #00FF00 500ms none\nrepeat",
        "; ".join(f"{index}:#FF9F0A 420ms pulse {index * 180}ms" for index in range(8)) + "\nrepeat",
    ],
)
def test_every_narrowed_program_passes_the_two_led_safety_gate(program):
    narrowed = downsample_program(program, source_leds=8)
    compiled = compile_presentation_program(narrowed, led_count=DOT_LED_COUNT)
    assert compiled.accepted
    # Narrowing never introduces a cadence problem of its own: whatever the
    # compiler says about the narrowed program, it said about the strip's.
    source = compile_presentation_program(program, led_count=8)
    assert compiled.reasons == source.reasons


# --- asks: the attention beacon ---------------------------------------------


def test_beacon_is_dark_when_nobody_is_needed():
    program, why, animated = beacon_program(DotBeaconFacts())
    assert program == "off"
    assert why == "idle"
    assert animated is False


def test_beacon_pulses_amber_on_an_ask():
    program, why, animated = beacon_program(DotBeaconFacts(ask_count=1))
    assert program.startswith(DotRoleColors().ask)
    assert why == "waiting"
    assert animated is True


def test_beacon_returns_to_dark_when_the_ask_resolves():
    asking = DotBeaconFacts(ask_count=1, escalation_stage=3)
    assert beacon_program(asking)[0] != "off"
    assert beacon_program(DotBeaconFacts(ask_count=0, escalation_stage=3))[0] == "off"


def test_beacon_shows_red_for_a_blocked_error_over_an_ask():
    program, why, _animated = beacon_program(DotBeaconFacts(ask_count=2, blocked=True))
    assert program.startswith(DotRoleColors().blocked)
    assert why == "failed"


def test_beacon_ignores_an_unseen_completion_unless_asked_to_care():
    facts = DotBeaconFacts(unseen_completions=3)
    assert beacon_program(facts)[0] == "off"
    program, why, _animated = beacon_program(facts, include_completions=True)
    assert program.startswith(DotRoleColors().completion)
    assert why == "completed"


def test_an_ask_outranks_an_unseen_completion():
    facts = DotBeaconFacts(ask_count=1, unseen_completions=3)
    assert beacon_program(facts, include_completions=True)[0].startswith(DotRoleColors().ask)


def test_escalation_visibly_tightens_the_pulse():
    cycles = []
    for stage in range(4):
        program = beacon_program(DotBeaconFacts(ask_count=1, escalation_stage=stage))[0]
        on_ms = int(program.split()[1].removesuffix("ms"))
        cycles.append(on_ms)
    assert cycles == sorted(cycles, reverse=True)
    assert len(set(cycles)) == 4


@pytest.mark.parametrize("stage", range(4))
@pytest.mark.parametrize(
    "facts_kwargs",
    [{"ask_count": 1}, {"blocked": True}, {"unseen_completions": 1}],
)
def test_no_beacon_state_ever_exceeds_two_hertz(stage, facts_kwargs):
    facts = DotBeaconFacts(escalation_stage=stage, **facts_kwargs)
    program = beacon_program(facts, include_completions=True)[0]
    if program == "off":
        return
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


def test_the_beacon_breathes_rather_than_blinks():
    program = beacon_program(DotBeaconFacts(ask_count=1))[0]
    assert all("cosine" in line for line in program.splitlines()[:2])


def test_the_beacon_leaves_resting_glow_to_the_device():
    # `off` is what the controller substitutes the device's own resting glow
    # into, so the beacon obeys that policy without knowing it exists.
    assert beacon_program(DotBeaconFacts())[0] == "off"
    assert "off" in beacon_program(DotBeaconFacts(ask_count=1))[0]


def test_beacon_facts_clamp_rather_than_raise():
    facts = DotBeaconFacts(ask_count=-4, unseen_completions=-1, escalation_stage=99)
    assert (facts.ask_count, facts.unseen_completions, facts.escalation_stage) == (0, 0, 3)


# --- plan_dot_surface: the whole surface ------------------------------------


def test_status_role_claims_nothing():
    assert plan_dot_surface(role="status", strip_program=LIVE_DOT_DEFECT) is None


def test_extend_with_nothing_to_extend_claims_nothing():
    assert plan_dot_surface(role="extend", strip_program=None) is None


def test_asks_role_needs_no_strip_at_all():
    plan = plan_dot_surface(role="asks", facts=DotBeaconFacts(ask_count=1), strip_program=None)
    assert plan is not None
    assert plan.role == "asks"
    assert plan.why == "waiting"
    assert plan.led_count == DOT_LED_COUNT


def test_asks_role_ignores_the_strip_even_when_there_is_one():
    plan = plan_dot_surface(role="asks", facts=DotBeaconFacts(), strip_program=LIVE_DOT_DEFECT)
    assert plan.program == "off"


def test_extend_plan_reports_the_strips_state_as_its_why():
    class Semantic:
        value = "active"

    plan = plan_dot_surface(
        role="extend", semantic=Semantic(), strip_program=LIVE_DOT_DEFECT, strip_led_count=8
    )
    assert plan.why == "working"
    assert plan.role == "extend"
    assert stray_indices(plan.program) == ()


def test_extend_why_table_matches_the_projections():
    from jrbar.dot_role import _WHY_FOR_SEMANTIC

    assert _WHY_FOR_SEMANTIC == _GLANCE_WHY


def test_plan_applies_the_dots_brightness_as_one_leading_line():
    plan = plan_dot_surface(
        role="extend", strip_program=LIVE_DOT_DEFECT, strip_led_count=8, brightness=42
    )
    lines = plan.program.splitlines()
    assert lines[0] == "brightness 42"
    assert sum(1 for line in lines if line.startswith("brightness")) == 1


def test_full_brightness_needs_no_line_at_all():
    plan = plan_dot_surface(role="asks", facts=DotBeaconFacts(ask_count=1), brightness=255)
    assert not plan.program.startswith("brightness")


def test_apply_brightness_line_clamps_and_replaces():
    assert apply_brightness_line("brightness 9\n#FF0000", 300) == "#FF0000"
    assert apply_brightness_line("brightness 9\n#FF0000", -5) == "brightness 0\n#FF0000"
    assert apply_brightness_line("#FF0000", None) == "#FF0000"


def test_unknown_role_plans_as_extend():
    plan = plan_dot_surface(role="whatever", strip_program=LIVE_DOT_DEFECT, strip_led_count=8)
    assert plan.role == "extend"


# --- the write boundary: no program for the wrong device, ever --------------


@pytest.fixture
def dot_volume(tmp_path):
    """A directory the LED-count table classifies as a two-LED Dot."""
    volume = tmp_path / "PulseDot"
    volume.mkdir()
    (volume / "LEDS.LED").write_text("off\n", encoding="utf-8")
    return volume


def test_a_wide_program_is_refused_at_the_write_boundary(dot_volume):
    from jrbar.device_writer import DeviceWriteError, write_led_program

    with pytest.raises(DeviceWriteError) as refusal:
        write_led_program(LIVE_DOT_DEFECT, device_path=dot_volume, dry_run=True)
    assert "2-LED device" in str(refusal.value)


def test_an_indexed_program_past_the_last_led_is_refused_too(dot_volume):
    from jrbar.device_writer import DeviceWriteError, write_led_program

    with pytest.raises(DeviceWriteError):
        write_led_program("0:#FF0000; 5:#00FF00", device_path=dot_volume, dry_run=True)


def test_the_narrowed_program_is_accepted_at_the_same_boundary(dot_volume):
    from jrbar.device_writer import write_led_program

    narrowed = downsample_program(LIVE_DOT_DEFECT, source_leds=8)
    assert write_led_program(narrowed, device_path=dot_volume, dry_run=True).name == "LEDS.LED"


@pytest.mark.parametrize("stage", range(4))
def test_every_beacon_state_is_accepted_at_the_write_boundary(dot_volume, stage):
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
