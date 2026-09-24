"""A linked Dot on the strip's beat, proved on the real firmware engine.

The Dot's clock runs about 2.7% slow, so after any start the pair drifts
apart by roughly 27 ms a second unless the Dot's program is written for its
own clock and kept there. These tests run the packaged firmware engine for
both devices -- the strip at real time, the Dot at ``now * 0.9734`` -- and
hold the phase error to the tolerance for ten simulated minutes; the same
run with the planner that shipped before must blow past a second, which is
how we know the harness sees the bug at all."""

from __future__ import annotations

import sys
from itertools import pairwise
from pathlib import Path

import pytest

REPO = Path(__file__).resolve().parents[1]
if str(REPO / "scripts") not in sys.path:
    sys.path.insert(0, str(REPO / "scripts"))

from review_effects import builtin_programs, effect_programs  # noqa: E402
from review_linked_sync import SAMPLES, corpus, simulate  # noqa: E402

from jrbar.animation import loop_duration_ms, read_program  # noqa: E402
from jrbar.device_clock import DeviceClocks, DeviceStatus  # noqa: E402
from jrbar.dot_role import downsample_program  # noqa: E402
from jrbar.linked_runtime import LinkedEpoch, LinkedSync  # noqa: E402
from jrbar.linked_sync import (  # noqa: E402
    DeviceTiming,
    apply_device_timing,
    fits_budget,
    period_locked_dot,
    phase_ms,
    predicted_error_ms,
    retime_program,
    rotate_program,
    should_resync,
    wrap_ms,
)

CORPUS = [*effect_programs(), *builtin_programs()]
DOT_RATE = 0.9734


def _lap(program: str, led_count: int) -> int | None:
    animation, _problems = read_program(program, led_count=led_count)
    return loop_duration_ms(animation) if animation is not None else None


def _raw_frames(program: str, *, led_count: int, start: int, count: int, every: int):
    from jrbar.led_wasm import RawSdLedWasmController

    engine = RawSdLedWasmController(led_count)
    assert engine.parse(program, 0).ok, program
    for moment in range(0, start, 16):
        engine.step(moment)
    return [engine.step(start + index * every) for index in range(count)]


def _gap(left, right) -> int:
    return max(
        abs(a - b)
        for frame_a, frame_b in zip(left, right)
        for led_a, led_b in zip(frame_a, frame_b)
        for a, b in zip(led_a, led_b)
    )


# --- retiming ------------------------------------------------------------------


def test_retime_is_exact_over_the_corpus__and_3_more() -> None:
    # --- scenario: every_lap_lands_within_half_a_millisecond
    """The running total is rounded, never each step, so a lap written for
    the Dot's clock is ``rate`` times the strip's to half a millisecond --
    for the strip's programs and the Dot's narrowed ones alike."""
    checked = 0
    for name, program, leds in CORPUS:
        for text, count in ((program, leds), (downsample_program(program, source_leds=leds), 2)):
            if not text:
                continue
            lap = _lap(text, count)
            if not lap:
                continue
            timed = retime_program(text, DOT_RATE, led_count=count)
            assert timed is not None, name
            assert abs(_lap(timed, count) - lap * DOT_RATE) <= 0.5, name
            checked += 1
    assert checked > 60

    # --- scenario: the_live_idle_roll_matches_the_prototype
    """The research prototype took the live idle roll from 12,250 ms to
    11,924 (ideal 11,924.1)."""
    idle = SAMPLES["idle_roll"]
    assert _lap(idle, 8) == 12250
    assert _lap(retime_program(idle, DOT_RATE, led_count=8), 8) == 11924

    # --- scenario: rotated_then_retimed_every_lap_still_lands
    """What the write boundary really writes -- rotated to the phase, then
    retimed -- keeps the promise too, for the Dot's mirror and its
    continuation. A cut line whose two segments tied for longest used to
    shrink only one of them, and the lap came out a millisecond long."""
    from jrbar.dot_continue import continue_program

    written = 0
    for name, program, leds in CORPUS:
        if leds != 8:
            continue
        for locked in (period_locked_dot(program, source_leds=8), continue_program(program, source_leds=8)):
            if locked is None or not locked.lap_ms:
                continue
            for moment in (0.4137, 2.9021, 7.3519):
                timed = apply_device_timing(
                    locked.program,
                    DeviceTiming(anchor=0.0, rate=DOT_RATE, trim_ms=-locked.origin_ms),
                    led_count=2,
                    now=moment,
                    latency_ms=20.0,
                )
                if timed.rotation == "unrotated":
                    continue
                assert abs(_lap(timed.program, 2) - locked.lap_ms * DOT_RATE) <= 0.5, (name, locked.rung, moment)
                written += 1
    assert written > 150

    # --- scenario: the_firmware_loops_the_retimed_program_at_its_new_lap
    """Sampled on the engine, the retimed loop repeats at its own lap: the
    frame at ``t`` and at ``t + lap`` agree within a code."""
    for program in ("#FF0000 1000ms pulse\noff 500ms\nrepeat", "#00FF00 800ms cosine\n#000044 600ms ease-in-out\nrepeat"):
        timed = retime_program(program, DOT_RATE, led_count=2)
        lap = _lap(timed, 2)
        first = _raw_frames(timed, led_count=2, start=2 * lap, count=40, every=13)
        second = _raw_frames(timed, led_count=2, start=3 * lap, count=40, every=13)
        assert _gap(first, second) <= 1


# --- rotation --------------------------------------------------------------------


def test_a_mid_pulse_rotation_equals_the_offset_program__and_1_more() -> None:
    # --- scenario: narrowed_pulses_rotate_within_two_codes
    """The narrowed pulse and breathe effects, cut anywhere mid-flight, play
    on the firmware what the unrotated program plays that far in, within two
    codes -- the rotation used to refuse every pulse cut."""
    for name in ("effect_pulse_8led", "effect_breathe_8led"):
        program = next(p for n, p, leds in CORPUS if n == name)
        narrowed = downsample_program(program, source_leds=8)
        lap = _lap(narrowed, 2)
        for shift in (lap * 0.13, lap * 0.41, lap * 0.77):
            rotated = rotate_program(narrowed, shift, led_count=2)
            assert rotated is not None and fits_budget(rotated), (name, shift)
            assert _lap(rotated, 2) == lap
            played = _raw_frames(rotated, led_count=2, start=3 * lap, count=120, every=11)
            expected = _raw_frames(narrowed, led_count=2, start=3 * lap + int(round(shift)), count=120, every=11)
            assert _gap(played, expected) <= 2, (name, shift)

    # --- scenario: the_write_boundary_never_writes_a_wrong_program
    """Over budget, the ladder cuts at the nearest line boundary, then not
    at all -- always a program that fits and parses, never a broken one."""
    heavy = "\n".join(
        f"0:#{index:02X}0000 {97 + index}ms pulse; 1:#00{index:02X}00 {97 + index}ms pulse {index + 3}ms"
        for index in range(1, 11)
    ) + "\nrepeat"
    assert fits_budget(heavy)
    for moment in (0.0131, 0.4, 0.93):
        timed = apply_device_timing(heavy, DeviceTiming(anchor=0.0, rate=DOT_RATE), led_count=2, now=moment, latency_ms=20)
        assert fits_budget(timed.program)
        assert timed.rotation in ("exact", "snapped", "unrotated")
        assert _lap(timed.program, 2) is not None


# --- the two-engine simulation ---------------------------------------------------


@pytest.mark.parametrize("effect", ["idle_roll", "comet"])
def test_the_pair_holds_the_tolerance_for_ten_minutes(effect: str) -> None:
    """Strip at real time, Dot at ``now * 0.9734``, written 16 ms apart,
    ten minutes at 60 Hz with the closed loop: the phase error never passes
    the 40 ms tolerance, the Dot on the engine looks like the Dot it should
    be, and the loop never writes the Dot more than once in 20 s. The same
    run with the planner that shipped before passes a whole second."""
    program = corpus([effect])[effect]
    fixed = simulate(program, effect=effect, planner="new", minutes=10.0, true_rate=DOT_RATE)
    assert fixed.max_error_ms <= 40.0
    assert fixed.mean_engine_gap < 4.0
    syncs = [at for at, reason in fixed.dot_writes if reason in ("reanchor", "blind")]
    assert all(later - earlier >= 20.0 for earlier, later in pairwise(syncs))

    before = simulate(program, effect=effect, planner="old", minutes=10.0, true_rate=DOT_RATE)
    assert before.max_error_ms > 1000.0
    assert before.mean_engine_gap > 5.0


def test_another_dot_converges_on_its_own_clock() -> None:
    """A Dot whose clock is not the warm start's (0.9690) is measured and
    held within the tolerance once its first reads are in."""
    program = corpus(["idle_roll"])["idle_roll"]
    outcome = simulate(program, effect="idle_roll", planner="new", minutes=6.0, true_rate=0.9690)
    assert outcome.max_error_after(60.0) <= 40.0
    assert 1 <= outcome.reanchors <= 6


# --- the loop's arithmetic -------------------------------------------------------


def test_the_phase_and_the_predicted_error__and_2_more() -> None:
    # --- scenario: phase_comes_from_the_strips_start_plus_trim
    assert phase_ms(10.25, 10.0, 1000) == pytest.approx(250.0)
    assert phase_ms(10.25, 10.0, 1000, trim_ms=-300) == pytest.approx(950.0)
    assert wrap_ms(900.0, 1000.0) == pytest.approx(-100.0)

    # --- scenario: an_uncorrected_slow_dot_falls_behind_27_ms_a_second
    error = predicted_error_ms(
        initial_error_ms=0.0,
        applied_at=0.0,
        ticks_at_apply=0.0,
        ticks_now=10_000 * DOT_RATE,
        host_now=10.0,
        rate=1.0,
        lap_ms=None,
    )
    assert error == pytest.approx(-266.0)
    corrected = predicted_error_ms(
        initial_error_ms=3.0,
        applied_at=0.0,
        ticks_at_apply=0.0,
        ticks_now=10_000 * DOT_RATE,
        host_now=10.0,
        rate=DOT_RATE,
        lap_ms=1000,
    )
    assert corrected == pytest.approx(3.0)

    # --- scenario: resync_only_past_the_tolerance_and_twenty_seconds_apart
    assert should_resync(45.0, tolerance_ms=40, now=100.0, last_sync_at=None)
    assert not should_resync(39.0, tolerance_ms=40, now=100.0, last_sync_at=None)
    assert not should_resync(-90.0, tolerance_ms=40, now=100.0, last_sync_at=85.0)
    assert should_resync(-90.0, tolerance_ms=40, now=105.0, last_sync_at=85.0)
    assert not should_resync(None, tolerance_ms=40, now=100.0, last_sync_at=None)


def test_the_closed_loop_reanchors_at_most_every_twenty_seconds() -> None:
    """Fed a Dot drifting 26 ms a second (retimed for nothing), the loop asks
    for a re-anchor as soon as the error passes the tolerance and then waits
    out 20 s before asking again, however large the error gets."""
    clock = [100.0]
    ticks = [1_000_000.0]

    def reader(_root):
        return DeviceStatus(clock[0], {"ticks": f"{ticks[0]:.0f}"})

    link = LinkedSync(DeviceClocks(None), reader=reader, spawn=lambda work: work(), now=lambda: clock[0])
    link.note_epoch(LinkedEpoch(100.0, 1.0, "pro"))

    class Timed:
        phase_ms = 0.0
        rate = 1.0
        effective_rate = 1.0
        lap_ms = 100_000
        rotation = "exact"

    class Write:
        timed = Timed()
        applied_at = 100.0

    link.note_dot_write(dot_id="dot", write=Write(), epoch=link.epoch, trim_ms=0.0, reason="coupled", sample=reader(None))
    asked = []
    for second in range(1, 61):
        clock[0] = 100.0 + second
        ticks[0] = 1_000_000.0 + second * 1000.0 * DOT_RATE
        if link.read_due(clock[0]):
            link.start_read("dot", None)
        link.consume()
        if link.due(tolerance_ms=40, now=clock[0], dot_id="dot"):
            link.note_reanchor_requested(clock[0])
            asked.append(second)
    assert asked and asked[0] <= 21
    assert all(later - earlier >= 20 for earlier, later in pairwise(asked))
    document = link.document(dot_id="dot", tolerance_ms=40, correction=True)
    # Asked for and never written (here nothing writes them): not counted.
    # They were counted on the ask, so a refused re-anchor read as a sync.
    assert document["sync_writes_hour"] == 0
    assert document["tolerance_ms"] == 40.0
    for _ in range(2):
        link.note_dot_write(dot_id="dot", write=Write(), epoch=link.epoch, trim_ms=0.0, reason="reanchor", sample=None)
    link.note_dot_write(dot_id="dot", write=Write(), epoch=link.epoch, trim_ms=0.0, reason="coupled", sample=None)
    assert link.document(dot_id="dot", tolerance_ms=40, correction=True)["sync_writes_hour"] == 2


def test_the_period_lock_steps_down_rather_than_change_the_period() -> None:
    """The scanner's brightest-band fold blinks at two LEDs and would be
    slowed by the Dot's own gate; the lock takes the band average instead,
    whose compiled loop is the strip's."""
    from jrbar.presentation_compiler import compile_presentation_program

    scanner = next(p for n, p, leds in CORPUS if n == "effect_scanner_8led")
    locked = period_locked_dot(scanner, source_leds=8)
    assert locked.rung == "average"
    strip_lap = _lap(compile_presentation_program(scanner, led_count=8).program, 8)
    dot_lap = _lap(compile_presentation_program(locked.program, led_count=2).program, 2)
    assert locked.lap_ms == strip_lap == dot_lap


# --- Continue: the light runs on into the Dot ------------------------------------


def _luma(color) -> float:
    return 0.2126 * color[0] + 0.7152 * color[1] + 0.0722 * color[2]


def _bump_tops(series: list[tuple[int, float]], *, share: float = 0.6, apart: int = 80) -> list[int]:
    """The moments a sampled LED peaks: each run of samples at least
    ``share`` of its brightest is one bump, and its top is the middle of
    the samples within a code of that run's highest (an engine rounds a
    pulse's crest to a few equal frames)."""
    top = max(value for _moment, value in series)
    runs: list[list[tuple[int, float]]] = []
    for moment, value in series:
        if value < share * top:
            continue
        if runs and moment - runs[-1][-1][0] <= apart:
            runs[-1].append((moment, value))
        else:
            runs.append([(moment, value)])
    tops = []
    for run in runs:
        highest = max(value for _moment, value in run)
        crest = [moment for moment, value in run if value >= highest - 1.0]
        tops.append((crest[0] + crest[-1]) // 2)
    return tops


@pytest.mark.parametrize("effect", ["effect_comet_8led", "effect_chase_8led"])
def test_continue_carries_every_pass_onto_the_dot__and_1_more(effect: str) -> None:
    # --- scenario: every_head_leaving_led_7_reaches_the_dot_one_step_later
    """Written the way the daemon writes a linked Dot -- rotated to the
    strip's phase from its recorded start, from the program's own origin --
    and played on the firmware engine beside the strip: every time the head
    peaks on LED 7, the Dot's first LED peaks one travel step later and its
    second a step after that, within a frame, and no pass is missed or
    added. The first spelling lost two passes in six and lit the Dot early."""
    from jrbar.dot_continue import continue_program
    from jrbar.led_wasm import RawSdLedWasmController
    from jrbar.presentation_compiler import compile_presentation_program

    program = next(p for n, p, leds in CORPUS if n == effect)
    strip = compile_presentation_program(program, led_count=8).program
    locked = continue_program(program, source_leds=8)
    assert locked is not None and locked.rung == "continue"
    lap = locked.lap_ms
    joined_at = 3.217
    timed = apply_device_timing(
        locked.program,
        DeviceTiming(anchor=0.0, rate=1.0, trim_ms=-locked.origin_ms),
        led_count=2,
        now=joined_at,
        latency_ms=0.0,
    )
    assert timed.rotation == "exact" and fits_budget(timed.program)
    pro = RawSdLedWasmController(8)
    dot = RawSdLedWasmController(2)
    assert pro.parse(strip, 0).ok and dot.parse(timed.program, int(joined_at * 1000)).ok
    led6: list[tuple[int, float]] = []
    led7: list[tuple[int, float]] = []
    first: list[tuple[int, float]] = []
    second: list[tuple[int, float]] = []
    for moment in range(0, 3 * lap, 5):
        pro_frame = pro.step(moment)
        dot_frame = dot.step(moment) if moment >= joined_at * 1000 else None
        if moment < lap or dot_frame is None:
            continue
        led6.append((moment, _luma(pro_frame[6])))
        led7.append((moment, _luma(pro_frame[7])))
        first.append((moment, _luma(dot_frame[0])))
        second.append((moment, _luma(dot_frame[1])))
    exits = _bump_tops(led7)
    step = min(exit - top for exit in exits[1:2] for top in _bump_tops(led6) if top < exit)
    assert 150 <= step <= 290
    arrivals, onward = _bump_tops(first), _bump_tops(second)
    frame = 17
    checked = 0
    for exit in exits:
        if exit + 2 * step + frame >= 3 * lap:
            continue
        assert any(abs(top - (exit + step)) <= frame for top in arrivals), (effect, exit, arrivals)
        assert any(abs(top - (exit + 2 * step)) <= frame for top in onward), (effect, exit, onward)
        checked += 1
    assert checked >= 10
    # One Dot pass for every strip pass: nothing missing, nothing extra.
    window = [top for top in arrivals if lap + step + frame < top < 3 * lap - frame]
    expected = [exit for exit in exits if lap + frame < exit + step < 3 * lap - frame]
    assert abs(len(window) - len(expected)) <= 1

    # --- scenario: cut_anywhere_it_still_fits_exactly
    """Wherever the strip is when the Dot is written, the rotation is exact
    and inside the firmware's budget, with the Dot's brightness line in
    front -- never snapped to a line boundary half a pass off."""
    from jrbar.dot_role import apply_brightness_line

    dressed = apply_brightness_line(locked.program, 77)
    for index in range(40):
        moment = 0.001 + lap * index / 40 / 1000.0
        timed = apply_device_timing(
            dressed,
            DeviceTiming(anchor=0.0, rate=DOT_RATE, trim_ms=-locked.origin_ms),
            led_count=2,
            now=moment,
            latency_ms=20.0,
        )
        assert timed.rotation == "exact", (effect, index)
        assert fits_budget(timed.program)


def test_continue_mirrors_what_it_cannot_carry__and_1_more() -> None:
    # --- scenario: nothing_travels_so_the_dot_mirrors
    """A breathe lights every LED together; there is nothing to carry on,
    so Continue answers ``None`` and the caller mirrors."""
    from jrbar.dot_continue import continuation_quality, continue_program

    breathe = next(p for n, p, leds in CORPUS if n == "effect_breathe_8led")
    assert continue_program(breathe, source_leds=8) is None

    # --- scenario: what_it_carries_it_carries_truly
    """Every program it does continue stays within the gate: the worst
    moment inside 40% of the light's own range, the average inside 12%. The
    marquee, twelve passes a lap, does not fit a line per pass and mirrors
    rather than skip ten of them."""
    marquee = next(p for n, p, leds in CORPUS if n == "effect_marquee_8led")
    assert continue_program(marquee, source_leds=8) is None
    carried = 0
    for name, program, leds in CORPUS:
        if leds != 8:
            continue
        quality = continuation_quality(program, source_leds=8)
        if quality is None:
            continue
        worst, mean, span = quality
        assert worst <= 0.40 * span and mean <= 0.12 * span, name
        carried += 1
    assert carried >= 4
