"""Every shape has to be smooth ON THE FIRMWARE, not in principle.

These tests drive the packaged firmware engine (``sdled.wasm``) directly, the
same way ``scripts/review_effects.py`` does, and assert about the LED codes it
returns rather than about the text of the program. A shape that reads well and
samples badly is a shape that looks wrong on the desk.
"""

from __future__ import annotations

from itertools import pairwise

import pytest

from jrbar import motion_shapes as shapes
from jrbar._led_wasm_legacy import (  # raw engine: no safety compiler in the way
    LedWasmUnavailableError,
    SdLedWasmController,
)
from jrbar.flash_analysis import relative_luminance

FRAME_MS = 1000 // 60
COLOR = "#00E5FF"
FLOOR = "#000305"


def sample(program: str, led_count: int, frames: int = 240, start_ms: int = 0):
    """The exact codes the strip shows, one 60 Hz frame at a time.

    ``start_ms`` skips the program's arrival. A loop's first pass begins from
    whatever the strip was already showing -- black here, the previous
    program's colours on a real device -- so judging a shape's smoothness from
    t=0 judges the hand-off, not the shape.
    """
    try:
        controller = SdLedWasmController(led_count)
    except LedWasmUnavailableError as error:  # pragma: no cover - macOS only
        pytest.skip(f"firmware engine unavailable: {error}")
    controller.reset(0)
    result = controller.parse(program, 0)
    assert result.ok, f"firmware rejected {program!r}: {result.error_name}"
    return controller.step_batch(int(start_ms), FRAME_MS, frames)


def luminance(frames):
    return [[relative_luminance(pixel) for pixel in frame] for frame in frames]


def biggest_frame_step(frames) -> float:
    tracks = list(zip(*luminance(frames)))
    return max(
        abs(after - before)
        for track in tracks
        for before, after in pairwise(track)
    )


def program(lines: list[str]) -> str:
    return "\n".join([*lines, "repeat"])


def head_positions(frames) -> list[int]:
    """Where the crest is, frame by frame, with its plateaus collapsed.

    A crest sits on one LED for several frames while its neighbours cross
    over, so the raw sequence is full of repeats; the question here is only
    which way it is walking.
    """
    positions = []
    for frame in luminance(frames):
        brightest = max(range(len(frame)), key=lambda index: frame[index])
        if frame[brightest] > 0.01 and (not positions or positions[-1] != brightest):
            positions.append(brightest)
    return positions


ALL_SHAPES = {
    "chase": lambda n: shapes.travelling_wave(COLOR, led_count=n, lap_ms=2000, laps=6),
    "comet": lambda n: shapes.travelling_wave(
        COLOR, led_count=n, lap_ms=1200, tail=shapes.COMET_TAIL, laps=6
    ),
    "marquee": lambda n: shapes.travelling_wave(
        COLOR, led_count=n, lap_ms=2000, tail=shapes.MARQUEE_TAIL, laps=6
    ),
    "tide": lambda n: shapes.travelling_wave(
        COLOR, led_count=n, lap_ms=4000, tail=shapes.TIDE_TAIL, laps=4
    ),
    "gradient": lambda n: shapes.gradient_wave(COLOR, led_count=n, lap_ms=2000, laps=6),
    "kitt": lambda n: shapes.bounce(COLOR, FLOOR, led_count=n, step_ms=140),
    "scanner": lambda n: shapes.bounce(
        COLOR, FLOOR, led_count=n, step_ms=95, tail_leds=1.5
    ),
    "converge": lambda n: shapes.converge(COLOR, FLOOR, led_count=n, step_ms=160),
    "stack": lambda n: shapes.fill(COLOR, FLOOR, led_count=n, cycle_ms=2200),
    "twinkle": lambda n: shapes.scatter(COLOR, FLOOR, led_count=n, cycle_ms=2200),
    "drift": lambda n: shapes.drift(
        COLOR, shapes.shade(COLOR, 0.06), led_count=n, cycle_ms=2200
    ),
    "breathe": lambda n: shapes.breath(COLOR, FLOOR, cycle_ms=2200),
    "duotone": lambda n: shapes.crossfade(COLOR, "#12E3B0", cycle_ms=2200),
    "heartbeat": lambda n: shapes.lub_dub(COLOR, FLOOR, cycle_ms=2200),
    "ember": lambda n: shapes.ember(COLOR, FLOOR, led_count=n, cycle_ms=3200),
    "bloom": lambda n: shapes.bloom(COLOR, FLOOR, led_count=n, step_ms=140),
    "frontier": lambda n: shapes.frontier(
        COLOR, FLOOR, led_count=n, cycle_ms=2400
    ),
    "glint": lambda n: shapes.glint(COLOR, led_count=n, lap_ms=2400, laps=6),
    # 2026-09-24: the new motions, the upstream iris lid transitions and
    # the Dot's wipe.
    "ripple": lambda n: shapes.ripple(COLOR, FLOOR, led_count=n, cycle_ms=2200),
    "pendulum": lambda n: shapes.pendulum(COLOR, FLOOR, led_count=n, cycle_ms=2400),
    "land": lambda n: shapes.land(COLOR, FLOOR, led_count=n, cycle_ms=2400),
    "iris_open": lambda n: shapes.iris_open(led_count=n),
    "iris_close": lambda n: shapes.iris_close(led_count=n),
    "dot_wipe": lambda n: shapes.travelling_wave(
        COLOR, led_count=n, lap_ms=2200, tail=shapes.DOT_WIPE, laps=2
    ),
}


def test_every_shape_fits_the_firmware_budget() -> None:
    for name in sorted(ALL_SHAPES):
        for led_count in (8, 2):
            lines = ALL_SHAPES[name](led_count)
            text = program(lines)
            assert len(text.encode("utf-8")) <= shapes.MAX_PROGRAM_BYTES, name
            assert len(text.splitlines()) <= shapes.MAX_PROGRAM_LINES, name
            sample(text, led_count, frames=4)


#: The steepest a shape may move between two 60 Hz frames. 0.16 is a full
#: swing in about 200 ms at the steepest point of a raised cosine -- a thump
#: you can feel, and still an ease. Anything faster than that is a cut.
MAX_FRAME_STEP = 0.16
#: The ambient shapes -- the ones that live beside the work all day -- are
#: held to a much quieter bar than a heartbeat or a mechanical scanner. A
#: roll interpolates linearly in the firmware's drive codes, so its steepest
#: step in RELATIVE LUMINANCE lands at the top of the gamma curve: the bar
#: below is really a floor on how long a crest spends between neighbours.
AMBIENT_SHAPES = (
    "breathe",
    "chase",
    "drift",
    "ember",
    "glint",
    "gradient",
    "marquee",
    "tide",
    "twinkle",
)
GENTLE_FRAME_STEP = 0.10


def test_every_shape_moves_in_small_steps__and_2_more() -> None:
    # --- scenario: every_shape_moves_in_small_steps
    """No shape may jump: adjacent 60 Hz frames stay close in steady state."""
    for name in sorted(ALL_SHAPES):
        frames = sample(program(ALL_SHAPES[name](8)), 8, frames=360, start_ms=2600)
        assert biggest_frame_step(frames) <= MAX_FRAME_STEP, name

    # --- scenario: the_ambient_shapes_are_gentle
    for name in AMBIENT_SHAPES:
        frames = sample(program(ALL_SHAPES[name](8)), 8, frames=360, start_ms=2600)
        assert biggest_frame_step(frames) <= GENTLE_FRAME_STEP, name

    # --- scenario: every_shape_eases
    """Nothing in this library cuts.

    `none` is the firmware's hard edge and the only shape in the product that
    wants one is the blink cadence, which is an interruption on purpose and
    lives outside this module. An assignment with no timing at all is the same
    hard edge spelled differently -- it lasts one 17 ms frame.
    """
    for name in sorted(ALL_SHAPES):
        for led_count in (8, 2):
            for line in ALL_SHAPES[name](led_count):
                assert " none" not in line, f"{name}/{led_count}: {line}"
                for segment in line.split(";"):
                    tokens = segment.split()
                    assert len(tokens) > 1, (
                        f"{name}/{led_count}: untimed paint {segment!r}"
                    )



def test_knight_rider_sweeps_out_and_back_without_going_dark__and_2_more() -> None:
    # --- scenario: knight_rider_sweeps_out_and_back_without_going_dark
    """The head reaches both ends, reverses, and never leaves the strip dark.

    This is the whole complaint the redesign started from: the old shape was a
    one-way stagger that blanked the strip to start over, which is a blink,
    not a scanner.
    """
    lines = shapes.bounce(COLOR, FLOOR, led_count=8, step_ms=140)
    cycle_frames = int(2520 / FRAME_MS) + 1
    frames = sample(program(lines), 8, frames=cycle_frames, start_ms=2520)
    positions = head_positions(frames)
    assert min(positions) == 0 and max(positions) == 7, positions
    steps = [
        second - first for first, second in pairwise(positions)
    ]
    assert all(abs(step) == 1 for step in steps), (
        f"the head skipped LEDs: {positions}"
    )
    assert any(first * second < 0 for first, second in pairwise(steps)), (
        f"the head never reversed: {positions}"
    )
    # And something is always lit, which the staggered-pulse version was not.
    strip = [sum(frame) for frame in luminance(frames)]
    assert min(strip) > 0.01, "the strip went dark mid-sweep"

    # --- scenario: a_travelling_wave_never_seams
    """A rolled profile keeps its total light constant all the way round.

    That is the property no staggered-pulse sweep can have: a bump has to die
    before its line may end, so the strip must fade out once per lap.
    """
    lines = shapes.travelling_wave(COLOR, led_count=8, lap_ms=2000, laps=4)
    frames = sample(program(lines), 8, frames=200, start_ms=1000)
    totals = [sum(frame) for frame in luminance(frames)]
    assert min(totals) > 0.5 * max(totals), "the wave dimmed at the seam"

    # --- scenario: two_leds_crossfade_rather_than_strobe
    """A Dot has nowhere for a head to travel, so it gets a slow crossfade."""
    lines = shapes.travelling_wave(
        COLOR, led_count=2, lap_ms=2200, tail=shapes.DOT_TAIL, laps=4
    )
    frames = sample(program(lines), 2, frames=360, start_ms=2400)
    assert biggest_frame_step(frames) <= GENTLE_FRAME_STEP
    totals = [sum(frame) for frame in luminance(frames)]
    assert min(totals) > 0.5 * max(totals)



def test_no_shape_writes_two_segments_for_one_led_on_a_line__and_2_more() -> None:
    # --- scenario: no_shape_writes_two_segments_for_one_led_on_a_line
    """The firmware keeps the LAST assignment and drops the earlier ones.

    A line that names an LED twice therefore throws away work silently, which
    is exactly how the old heartbeat lost its first beat.
    """
    for name, build in sorted(ALL_SHAPES.items()):
        for led_count in (8, 2):
            for line in build(led_count):
                named = [
                    segment.split(":", 1)[0].strip()
                    for segment in line.split(";")
                    if ":" in segment.split()[0]
                ]
                assert len(named) == len(set(named)), f"{name}/{led_count}: {line}"

    # --- scenario: a_heartbeat_has_two_unequal_beats_on_their_own_lines
    lines = shapes.lub_dub(COLOR, FLOOR, cycle_ms=2200)
    beats = [line for line in lines if "pulse" in line]
    assert len(beats) == 2
    assert beats[0].split()[0] != beats[1].split()[0], "both beats are equal"

    # --- scenario: shades_stay_on_the_identity
    for fraction in (0.0, 0.25, 0.5, 1.0):
        shaded = shapes.shade("#00E5FF", fraction)
        assert shaded.startswith("#00")
    assert shapes.shade("#00E5FF", 1.0) == "#00E5FF"
    assert shapes.shade("#00E5FF", 0.0) == "#000000"



def test_a_profile_resamples_onto_a_shorter_strip__and_2_more() -> None:
    # --- scenario: a_profile_resamples_onto_a_shorter_strip
    fitted = shapes._fitted_tail(shapes.CHASE_TAIL, 4)
    assert len(fitted) == 4
    assert fitted[0] == 1.0
    assert fitted[-1] < fitted[0]

    # --- scenario: ember_burns_hottest_in_the_middle
    """The centre pair crests well above the rim, and nothing goes dark."""
    frames = sample(program(shapes.ember(COLOR, FLOOR, led_count=8, cycle_ms=3200)), 8,
                    frames=200, start_ms=700)
    peak_frame = max(luminance(frames), key=lambda frame: sum(frame))
    centre = (peak_frame[3] + peak_frame[4]) / 2
    rim = (peak_frame[0] + peak_frame[7]) / 2
    assert centre > rim * 1.5
    assert min(peak_frame) > 0.0  # coals never fully die

    # --- scenario: bloom_lights_the_centre_before_the_edges
    """At mid-rise the middle is lit while the rim still rests."""
    frames = sample(program(shapes.bloom(COLOR, FLOOR, led_count=8, step_ms=140)), 8,
                    frames=12, start_ms=400)
    mid = luminance(frames)[6]  # ~500ms in: centres risen, rim still climbing
    assert mid[3] > 0.3 and mid[4] > 0.3
    assert mid[0] < mid[3] and mid[7] < mid[4]



def test_frontier_holds_its_fill_while_the_tip_breathes__and_1_more() -> None:
    # --- scenario: frontier_holds_its_fill_while_the_tip_breathes
    """The fill sits constant across the cycle; the tip LED oscillates."""
    # start_ms past the first rise: the fill eases up once, then holds.
    frames = sample(program(shapes.frontier(COLOR, FLOOR, led_count=8, cycle_ms=2400)), 8,
                    frames=150, start_ms=1400)
    tracks = list(zip(*luminance(frames)))
    # LEDs 0..4 hold (level 0.625 of 8): near-constant, well above floor.
    for held in tracks[:5]:
        assert min(held) > 0.4
        assert max(held) - min(held) < 0.1
    # LED 5 is the breathing tip: a real swing, touching both ends.
    tip = tracks[5]
    assert max(tip) - min(tip) > 0.4
    # LEDs 6..7 stay in the dark past the frontier.
    for dark in tracks[6:]:
        assert max(dark) < 0.05

    # --- scenario: glint_sweeps_a_lit_strip
    """A travelling crest, but the bed never drops out from under it."""
    frames = sample(program(shapes.glint(COLOR, led_count=8, lap_ms=2400)), 8,
                    frames=200, start_ms=600)
    assert min(min(frame) for frame in luminance(frames)) > 0.2
    positions = head_positions(frames)
    assert len(set(positions)) >= 6  # the crest actually crosses the strip



def test_a_finish_can_land_or_ripple__and_ends_dark() -> None:
    """The done celebration's two new looks play once, in the done colour,
    and leave the strip dark -- a finish is a cue, never a held light."""
    from jrbar import celebrations
    from jrbar.animation import animation_duration_ms, loop_duration_ms, parse_animation
    from jrbar.colors import ColorSettings, program_for_snapshot

    for style in (celebrations.DONE_CELEBRATION_LAND, celebrations.DONE_CELEBRATION_RIPPLE):
        for led_count in (8, 2):
            program = celebrations.done_celebration_program(style, "#00FF66", led_count=led_count)
            assert program is not None
            animation = parse_animation(program, led_count=led_count)
            assert loop_duration_ms(animation) is None
            end = animation_duration_ms(animation)
            try:
                controller = SdLedWasmController(led_count)
            except LedWasmUnavailableError as error:  # pragma: no cover
                pytest.skip(str(error))
            controller.reset(0)
            assert controller.parse(program, 0).ok
            last = controller.step_batch(end + 60, FRAME_MS, 1)[0]
            assert all(pixel == (0, 0, 0) for pixel in last), (style, led_count, last)
    assert celebrations.done_celebration_program("bloom", "#00FF66") is None

    # The setting reaches the lights: a finish renders the chosen look.
    from datetime import datetime, timezone

    from jrbar.models import AgentMode, AgentStatus

    done = (
        AgentStatus(
            provider="claude",
            agent_id="a",
            display_name="Claude",
            mode=AgentMode.COMPLETED,
            updated_at=datetime(2026, 9, 24, tzinfo=timezone.utc),
            event_name="Stop",
        ),
    )
    bloom = program_for_snapshot(done, led_count=8, colors=ColorSettings.defaults())[1]
    landed = program_for_snapshot(
        done, led_count=8, colors=ColorSettings.defaults().with_done_celebration_style("land")
    )[1]
    assert bloom != landed
    assert landed.startswith("off 90ms cosine")
    restored = ColorSettings.from_dict(
        ColorSettings.defaults().with_done_celebration_style("ripple").to_dict()
    )
    assert restored.done_celebration_style == "ripple"
    assert ColorSettings.from_dict({"done_celebration_style": "confetti"}).done_celebration_style == "bloom"


def test_a_reversed_strip_mirrors_every_position__and_2_more() -> None:
    # --- scenario: a_reversed_strip_mirrors_every_position
    program = "\n".join(
        [
            "brightness 128",
            "0:#FF0000 200ms cosine; 7:#00FF00 200ms pulse 100ms",
            "#110000 #220000 #330000 300ms cosine",
            "roll-right 2s linear",
            "roll-left 1s",
            "repeat",
        ]
    )
    mirrored = shapes.oriented_program(program, led_count=8, direction="reversed").splitlines()
    assert mirrored[0] == "brightness 128"
    assert mirrored[1] == "7:#FF0000 200ms cosine; 0:#00FF00 200ms pulse 100ms"
    assert mirrored[2].startswith("#000000 #000000 #000000 #000000 #000000 #330000 #220000 #110000")
    assert mirrored[3].startswith("roll-left 2s")
    assert mirrored[4].startswith("roll-right 1s")
    assert shapes.oriented_program(program, led_count=8, direction="forward") == program
    assert shapes.oriented_program("not a program", led_count=8, direction="reversed") == "not a program"
    # Mirroring twice is the original light.
    twice = shapes.oriented_program(
        shapes.oriented_program(program, led_count=8, direction="reversed"),
        led_count=8,
        direction="reversed",
    )
    assert sample(twice, 8, frames=90, start_ms=500) == sample(
        shapes.oriented_program(program, led_count=8, direction="forward"), 8, frames=90, start_ms=500
    )

    # --- scenario: a_comet_on_a_reversed_strip_runs_the_other_way
    from jrbar.colors import ColorSettings, provider_motion_lines

    settings = ColorSettings.defaults().with_agent_animation("claude", "comet")
    body, _lead = provider_motion_lines("claude", COLOR, settings, led_count=8)
    forward = "\n".join([*body, "repeat"])
    reverse = shapes.oriented_program(forward, led_count=8, direction="reversed")

    def travel(text):
        heads = head_positions(sample(text, 8, frames=90, start_ms=1500))
        steps = [b - a for a, b in pairwise(heads) if abs(b - a) == 1]
        return sum(steps)

    assert travel(forward) > 0 and travel(reverse) < 0

    # --- scenario: a_device_draws_its_own_way_round_and_its_own_dot_travel
    from datetime import datetime, timezone

    from jrbar.colors import program_for_snapshot
    from jrbar.models import AgentMode, AgentStatus

    working = (
        AgentStatus(
            provider="claude",
            agent_id="a",
            display_name="Claude",
            mode=AgentMode.WORKING,
            updated_at=datetime(2026, 9, 24, tzinfo=timezone.utc),
            event_name="PreToolUse",
        ),
    )
    base = ColorSettings.defaults().with_agent_animation("claude", "comet")
    pro = program_for_snapshot(working, led_count=8, colors=base)[1]
    flipped = program_for_snapshot(
        working, led_count=8, colors=base.for_device(led_direction="reversed")
    )[1]
    assert flipped == shapes.oriented_program(pro, led_count=8, direction="reversed")
    wiping = program_for_snapshot(working, led_count=2, colors=base)[1]
    fading = program_for_snapshot(
        working, led_count=2, colors=base.for_device(dot_travel_style="crossfade")
    )[1]
    assert "roll" not in wiping and "1:" in wiping
    assert "roll-right" in fading


def test_device_direction_and_dot_travel_are_saved_per_device(tmp_path) -> None:
    from jrbar.settings import AgentMonitorSettings, DeviceDisplaySetting, load_settings, save_settings

    dot = DeviceDisplaySetting(
        device_id="dot", name="Dot", path="/Volumes/PulseDot",
        led_direction="reversed", dot_travel_style="crossfade",
    )
    target = tmp_path / "settings.json"
    save_settings(AgentMonitorSettings(devices=(dot,)), target)
    loaded = load_settings(target)
    assert loaded.device_led_direction("dot") == "reversed"
    assert loaded.device_dot_travel_style("dot") == "crossfade"
    assert loaded.device_led_direction("unknown") == "forward"
    assert loaded.device_dot_travel_style("unknown") == "wipe"
    import json

    raw = json.loads(target.read_text())
    raw["devices"][0]["led_direction"] = "sideways"
    raw["devices"][0]["dot_travel_style"] = 7
    target.write_text(json.dumps(raw))
    tolerant = load_settings(target)
    assert tolerant.device_led_direction("dot") == "forward"
    assert tolerant.device_dot_travel_style("dot") == "wipe"


def test_two_chosen_gradient_colours_roll_without_a_seam() -> None:
    """A gradient between two chosen colours goes there and back round the
    strip: the last LED sits beside the first as gently as any two
    neighbours, where a straight ramp put B beside A once a lap."""
    lines = shapes.gradient_wave(COLOR, led_count=8, lap_ms=2200, ends=("#FF2D55", "#5AC8FA"))
    ring = lines[0].split()[:8]
    assert ring[0] == "#FF2D55" and ring[4] == "#5AC8FA"

    def gap(left: str, right: str) -> int:
        return max(abs(a - b) for a, b in zip(shapes._channels(left), shapes._channels(right)))

    gaps = [gap(ring[index], ring[(index + 1) % 8]) for index in range(8)]
    assert max(gaps) - min(gaps) <= 2, gaps
    # The hue ramp with no chosen colours is drawn as it always was.
    assert shapes.gradient_wave(COLOR, led_count=8, lap_ms=2200)[0].split()[0] != COLOR


def test_a_tinted_dot_keeps_the_agents_colour_on_one_led() -> None:
    """The tool tint on a wiping Dot lights only the LED the light travels
    to; the one it sets out from keeps the provider's colour."""
    tool = "#FFD60A"
    forward = shapes.travelling_wave(COLOR, led_count=2, lap_ms=2200, tail=shapes.DOT_WIPE, head=tool)
    assert forward[0].startswith(f"0:{COLOR} ") and forward[1].startswith(f"1:{tool} ")
    backward = shapes.travelling_wave(
        COLOR, led_count=2, lap_ms=2200, tail=shapes.DOT_WIPE, head=tool, reverse=True
    )
    assert backward[0].startswith(f"1:{COLOR} ") and backward[1].startswith(f"0:{tool} ")
    plain = shapes.travelling_wave(COLOR, led_count=2, lap_ms=2200, tail=shapes.DOT_WIPE)
    assert tool not in "\n".join(plain) and plain[1].startswith(f"1:{COLOR} ")


def test_every_slider_end_changes_the_light() -> None:
    """A single-crest Marquee takes its palette rotation (the tail behind
    the head turns), and Tide's range and floor act all the way to the top
    of their sliders, with the default look unchanged."""
    def draw(motion: str, **params) -> list[str]:
        return shapes.render_motion(motion, COLOR, FLOOR, led_count=8, cycle_ms=2200, params=params)

    assert draw("marquee", crests=1, palette_rotation_degrees=90.0) != draw("marquee", crests=1)
    assert draw("marquee", crests=2) == draw("marquee")

    shipped = shapes.travelling_wave(COLOR, led_count=8, lap_ms=4400, tail=shapes.TIDE_TAIL, laps=6)
    assert draw("tide") == shipped
    assert draw("tide", fill_range=0.8) != draw("tide")
    assert draw("tide", fill_floor=0.7) != draw("tide", fill_floor=0.8)
    assert draw("tide", fill_floor=0.8) != draw("tide", fill_floor=0.8, fill_range=0.5)


def test_the_relay_on_a_dot_travels_the_way_its_travel_row_says() -> None:
    """The Working relay (Automatic, and every roll-styled mode) on two LEDs
    takes the Dot's Travel row, exactly as a chosen travelling motion does:
    the wipe by default, the older rolled crossfade when asked for. It used
    to be the crossfade whatever the row said (``DOT_TAIL``, X7). A strip
    of eight never changes."""
    from datetime import datetime, timezone

    from jrbar._led_status_legacy import rolling_program
    from jrbar.colors import ColorSettings, program_for_snapshot
    from jrbar.models import AgentMode, AgentStatus

    wipe = rolling_program(COLOR, led_count=2)
    fade = rolling_program(COLOR, led_count=2, dot_travel="crossfade")
    assert wipe == rolling_program(COLOR, led_count=2, dot_travel="wipe")
    assert wipe == rolling_program(COLOR, led_count=2, dot_travel="from a newer build")
    assert "roll" not in wipe and wipe.startswith("0:") and "\n1:" in wipe
    assert fade == program(
        shapes.travelling_wave(
            COLOR, led_count=2, lap_ms=2200, tail=shapes.DOT_TAIL, laps=shapes.MAX_PROGRAM_LINES // 3
        )
    )
    assert rolling_program(COLOR, led_count=8, dot_travel="crossfade") == rolling_program(COLOR, led_count=8)

    # On the firmware the wipe shows a direction: LED 0 lights before LED 1.
    frames = luminance(sample(wipe, 2, frames=132, start_ms=0))
    first_lit = [next(i for i, frame in enumerate(frames) if frame[led] > 0.2) for led in (0, 1)]
    assert first_lit[0] < first_lit[1]

    # The live path: the Dot's own row reaches the relay a working agent plays.
    working = (
        AgentStatus(
            provider="claude",
            agent_id="a",
            display_name="Claude",
            mode=AgentMode.WORKING,
            updated_at=datetime(2026, 9, 24, tzinfo=timezone.utc),
            event_name="PreToolUse",
        ),
    )
    base = ColorSettings.defaults()
    wiping = program_for_snapshot(working, led_count=2, colors=base.for_device(dot_travel_style="wipe"))[1]
    fading = program_for_snapshot(working, led_count=2, colors=base.for_device(dot_travel_style="crossfade"))[1]
    assert "roll" not in wiping and "\n1:" in wiping
    assert "roll-right" in fading
