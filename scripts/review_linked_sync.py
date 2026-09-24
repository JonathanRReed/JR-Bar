#!/usr/bin/env python3
"""Two engines, one beat: a linked Pro + Dot simulated on the real firmware.

The Pro runs on the host's clock; the Dot's clock runs slow (0.9734 of real
time on the first Dot, measured 2026-09-24). This harness plays both on the
packaged firmware engine (``sdled.wasm``), the Pro at real time and the Dot
at ``now * rate``, with the Dot written the way the daemon writes it:

* ``new``: the Dot's program is narrowed from the strip's compiled running
  program, rotated to the strip's phase at the moment it parses and retimed
  for its clock (``linked_sync.apply_device_timing``), and the closed loop
  (``linked_runtime.LinkedSync``) reads its ``ticks`` every 20 s and
  re-anchors it past the tolerance. The strip restarts every 240 s (its
  reassert) and the Dot restarts with it.
* ``old``: what shipped before -- the Dot rotated by the measured write
  skew, never retimed, restarted only with the strip.

It writes ``<out>/<effect>-<planner>.png``: on top, thirty seconds from
minute one with time running left to right -- the Pro's eight LEDs, then
the Dot as simulated, then the Dot as it should look (the strip's narrowed
program on a perfect clock); below, the phase error over the whole run
(the red line is the tolerance). A drifting pair shows as the middle band
shearing away from the one below it; a locked pair shows the two bands as
the same stripes.

With ``--look continue`` the Dot is written as the rest of the strip
(``dot_continue``) and each PNG, ``<effect>-continue.png``, draws the Pro
and the Dot as ONE ten-LED timeline: LEDs 0-7 are the Pro, 8 and 9 the
Dot, so a comet leaving LED 7 should carry on as the same diagonal stripe
through the last two rows. Below it, the Dot as it should look (the true
continuation), then the phase error.

    .venv/bin/python scripts/review_linked_sync.py --out build/linked-sync
    .venv/bin/python scripts/review_linked_sync.py --look continue --effects comet,chase,idle_roll
"""

from __future__ import annotations

import argparse
import random
import sys
from dataclasses import dataclass, field
from pathlib import Path
from types import SimpleNamespace

REPO = Path(__file__).resolve().parents[1]
for extra in (REPO / "src", REPO / "scripts"):
    if str(extra) not in sys.path:
        sys.path.insert(0, str(extra))

from jrbar.animation import loop_duration_ms, read_program  # noqa: E402
from jrbar.device_clock import DeviceClocks, DeviceStatus  # noqa: E402
from jrbar.dot_continue import continue_program  # noqa: E402
from jrbar.dot_role import shift_program_phase  # noqa: E402
from jrbar.led_wasm import RawSdLedWasmController  # noqa: E402  the device's own engine
from jrbar.linked_runtime import LinkedEpoch, LinkedSync  # noqa: E402
from jrbar.linked_sync import (  # noqa: E402
    DeviceTiming,
    apply_device_timing,
    period_locked_dot,
    wrap_ms,
)
from jrbar.presentation_compiler import compile_presentation_program  # noqa: E402

FRAME_S = 1.0 / 60.0
DOT_ID = "sidepulse:dot:sim"
#: The strip's reassert cadence (``LED_REASSERT_SECONDS``).
STRIP_REASSERT_S = 240.0


@dataclass
class _DotProgram:
    parse_real: float
    parse_dot_ms: float
    phase_ms: float
    lap_real: float | None
    lap_dot: float | None
    program: str


@dataclass
class SimResult:
    planner: str
    effect: str
    true_rate: float
    #: ``mirror`` or ``continue``: how the Dot was written.
    look: str = "mirror"
    #: (real seconds, phase error ms) at every frame.
    errors: list[tuple[float, float]] = field(default_factory=list)
    #: Per frame: the worst channel gap between the Dot as simulated and the
    #: Dot as it should look, on the firmware engine.
    engine_gaps: list[int] = field(default_factory=list)
    dot_writes: list[tuple[float, str]] = field(default_factory=list)
    columns: list[tuple[list, list, list, float]] = field(default_factory=list)
    #: ``continue`` only, per column: what LEDs 8 and 9 of a longer strip
    #: would show -- the Pro's LED 7 one and two travel steps ago.
    truth: list[list] = field(default_factory=list)

    @property
    def max_error_ms(self) -> float:
        return max((abs(error) for _t, error in self.errors), default=0.0)

    def max_error_after(self, seconds: float) -> float:
        return max((abs(error) for t, error in self.errors if t >= seconds), default=0.0)

    @property
    def reanchors(self) -> int:
        return sum(1 for _t, reason in self.dot_writes if reason in ("reanchor", "blind"))

    @property
    def mean_engine_gap(self) -> float:
        return sum(self.engine_gaps) / max(1, len(self.engine_gaps))


def _lap(program: str, led_count: int) -> float | None:
    animation, _problems = read_program(program, led_count=led_count)
    lap = loop_duration_ms(animation) if animation is not None else None
    return float(lap) if lap else None


def simulate(
    program: str,
    *,
    effect: str = "program",
    planner: str = "new",
    minutes: float = 10.0,
    true_rate: float = 0.9734,
    tolerance_ms: float = 40.0,
    gap_ms: float = 16.0,
    latency_ms: float = 20.0,
    latency_jitter_ms: float = 4.0,
    read_jitter_ms: float = 6.0,
    seed: int = 1,
    column_every_s: float = 0.02,
    columns_from_s: float = 60.0,
    columns_for_s: float = 30.0,
    look: str = "mirror",
) -> SimResult:
    """Play ``program`` on a linked pair for ``minutes`` at 60 Hz, the Dot
    written as the strip's mirror or (``look="continue"``) its
    continuation."""
    generator = random.Random(seed)
    result = SimResult(planner, effect, true_rate, look)
    dot_offset_ms = 5_000_000.0

    def dot_clock(real: float) -> float:
        return dot_offset_ms + real * 1000.0 * true_rate

    compiled = compile_presentation_program(program, led_count=8)
    assert compiled.accepted, effect
    pro_text = compiled.program
    lap = _lap(pro_text, 8)
    locked = continue_program(program, source_leds=8) if look == "continue" else None
    if look == "continue":
        assert locked is not None, f"{effect} does not continue: it mirrors"
    else:
        locked = period_locked_dot(program, source_leds=8)
    assert locked is not None, effect
    ideal = locked.program
    # The strip phase the Dot's program starts at: a continuation starts
    # between two passes, and the daemon rotates from there.
    origin = float(locked.origin_ms)

    pro = RawSdLedWasmController(8)
    dot = RawSdLedWasmController(2)
    reference = RawSdLedWasmController(2)

    now = [0.0]
    from collections import deque

    from jrbar.dot_continue import travel_ms

    step = travel_ms(pro_text, 8) if look == "continue" else None
    history: deque[tuple[float, list]] = deque(maxlen=240)

    def reader(_root):
        moment = now[0]
        ticks = dot_clock(moment) + generator.uniform(-read_jitter_ms, read_jitter_ms)
        return DeviceStatus(moment, {"ticks": f"{ticks:.0f}"})

    link = LinkedSync(DeviceClocks(None), reader=reader, spawn=lambda work: work(), now=lambda: now[0])
    state = SimpleNamespace(pro_anchor=0.0, dot=None, pending=[])

    def restart_strip(at: float) -> None:
        state.pro_anchor = at
        pro.parse(pro_text, int(round(at * 1000.0)))
        # Started a lap early, so its time 0 is strip phase ``origin`` and it
        # is already running when the strip starts.
        reference.parse(ideal, int(round(at * 1000.0 + origin - (_lap(ideal, 2) or 0.0))))
        link.note_epoch(LinkedEpoch(at, at, "pro"))

    def write_dot(at: float, reason: str) -> None:
        """The Dot's write, the way the daemon's write boundary does it."""
        parse_real = at + (latency_ms + generator.uniform(-latency_jitter_ms, latency_jitter_ms)) / 1000.0
        if planner == "new":
            commit = reason != "dot"
            rate = link.rate_for_write(DOT_ID, correction=True, commit=commit)
            timed = apply_device_timing(
                ideal,
                DeviceTiming(anchor=state.pro_anchor, rate=rate, trim_ms=-origin),
                led_count=2,
                now=at,
                latency_ms=latency_ms,
            )
            text, phase = timed.program, timed.phase_ms
            write = SimpleNamespace(timed=timed, applied_at=parse_real)
            now[0] = parse_real + 0.005
            # As the daemon does: no read of the Dot's clock at the write;
            # the loop's next 20 s read carries it back.
            link.note_dot_write(
                dot_id=DOT_ID,
                write=write,
                epoch=link.epoch,
                trim_ms=-origin,
                reason=reason,
                sample=None,
            )
        else:
            # Before: rotated by the measured write gap, on the Dot's own
            # clock as if it were the strip's.
            phase = gap_ms if lap else 0.0
            text = shift_program_phase(ideal, phase) if phase else ideal
            text = text or ideal
        dot.parse(text, int(round(dot_clock(parse_real))))
        state.dot = _DotProgram(
            parse_real=parse_real,
            parse_dot_ms=dot_clock(parse_real),
            phase_ms=phase,
            lap_real=_lap(ideal, 2),
            lap_dot=_lap(text, 2),
            program=text,
        )
        result.dot_writes.append((at, reason))

    restart_strip(0.0)
    reference.step(0)
    pro.step(0)
    write_dot(gap_ms / 1000.0, "coupled")
    frames = int(minutes * 60.0 / FRAME_S)
    next_reassert = STRIP_REASSERT_S
    next_column = columns_from_s
    for index in range(1, frames):
        t = index * FRAME_S
        now[0] = t
        if t >= next_reassert:
            restart_strip(t)
            write_dot(t + gap_ms / 1000.0, "coupled")
            next_reassert += STRIP_REASSERT_S
        if planner == "new":
            if link.read_due(t):
                link.start_read(DOT_ID, None)
            link.consume()
            reason = link.due(tolerance_ms=tolerance_ms, now=t, dot_id=DOT_ID)
            if reason is not None:
                link.note_reanchor_requested(t)
                write_dot(t, reason)
        real_ms = int(round(t * 1000.0))
        pro_frame = pro.step(real_ms)
        expected = reference.step(real_ms)
        current = state.dot
        dot_frame = dot.step(int(round(dot_clock(t)))) if t >= current.parse_real else expected
        if lap and current.lap_dot and current.lap_real:
            content = origin + current.phase_ms + (dot_clock(t) - current.parse_dot_ms) * current.lap_real / current.lap_dot
            strip = (t - state.pro_anchor) * 1000.0
            error = wrap_ms(content - strip, lap)
        else:
            error = 0.0
        result.errors.append((t, error))
        gap = max(abs(a - b) for x, y in zip(dot_frame, expected) for a, b in zip(x, y))
        result.engine_gaps.append(gap)
        history.append((t, pro_frame))
        if t >= next_column and t <= columns_from_s + columns_for_s:
            result.columns.append((pro_frame, dot_frame, expected, error))
            if step is not None and step > 0:
                result.truth.append(
                    [
                        min(history, key=lambda entry: abs(entry[0] - (t - hop * step / 1000.0)))[1][7]
                        for hop in (1, 2)
                    ]
                )
            next_column += column_every_s
    return result


# --- PNG ----------------------------------------------------------------------


def render(result: SimResult, path: Path, *, tolerance_ms: float = 40.0, scale_ms: float = 400.0) -> None:
    """Two panels. On top, thirty seconds from minute one at 20 ms a column:
    the Pro's eight LEDs, the Dot as simulated, the Dot as it should be. A
    drifting pair shears (the middle band's stripes slide against the
    bottom band's); a locked pair's two bands are the same stripes. Below,
    the phase error over the whole run, the red line the tolerance."""
    from review_effects import _png_bytes

    background = (18, 18, 22)
    rows: list[list[tuple[int, int, int]]] = []
    width = len(result.columns)

    def band(frames: list, led: int, height: int) -> None:
        line = [frame[led] for frame in frames]
        rows.extend([list(line) for _ in range(height)])

    def spacer(height: int = 4) -> None:
        rows.extend([[background] * width for _ in range(height)])

    for led in range(8):
        band([column[0] for column in result.columns], led, 4)
    spacer(6)
    for led in range(2):
        band([column[1] for column in result.columns], led, 14)
    spacer(3)
    for led in range(2):
        band([column[2] for column in result.columns], led, 14)
    spacer(10)
    trace_height = 70
    trace = [[(30, 30, 36)] * width for _ in range(trace_height)]
    tolerance_row = trace_height - 1 - int(round(min(1.0, tolerance_ms / scale_ms) * (trace_height - 1)))
    per_column = max(1, len(result.errors) // max(1, width))
    for x in range(width):
        chunk = result.errors[x * per_column : (x + 1) * per_column]
        error = max((abs(value) for _t, value in chunk), default=0.0)
        height = int(round(min(1.0, error / scale_ms) * (trace_height - 1)))
        for y in range(trace_height - 1 - height, trace_height):
            trace[y][x] = (90, 200, 240) if error <= tolerance_ms else (240, 170, 60)
        trace[tolerance_row][x] = (190, 50, 50)
    rows.extend(trace)
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_bytes(_png_bytes(rows))


def render_continue(
    result: SimResult,
    path: Path,
    *,
    tolerance_ms: float = 40.0,
    scale_ms: float = 400.0,
    zoom: int = 1,
) -> None:
    """The Pro and the Dot as one ten-LED timeline, thirty seconds from
    minute one at 20 ms a column: rows 0-7 the Pro, a hairline, rows 8-9 the
    Dot as the engine played it. A comet leaving LED 7 should carry straight
    on as the same diagonal through the last two rows, pass for pass. Below,
    what rows 8 and 9 would be on a strip two LEDs longer (the Pro's LED 7
    one and two travel steps ago), then the phase error. ``zoom`` widens
    every column and row that many times."""
    from review_effects import _png_bytes

    background = (18, 18, 22)
    hairline = (70, 70, 80)
    rows: list[list[tuple[int, int, int]]] = []
    width = len(result.columns) * zoom

    def band(frames: list, led: int, height: int = 8) -> None:
        line = [frame[led] for frame in frames for _ in range(zoom)]
        rows.extend([list(line) for _ in range(height * zoom)])

    for led in range(8):
        band([column[0] for column in result.columns], led)
    rows.extend([[hairline] * width for _ in range(zoom)])
    for led in range(2):
        band([column[1] for column in result.columns], led)
    rows.extend([[background] * width for _ in range(8 * zoom)])
    if result.truth:
        for led in range(2):
            band(result.truth, led)
    rows.extend([[background] * width for _ in range(10)])
    trace_height = 50
    trace = [[(30, 30, 36)] * width for _ in range(trace_height)]
    tolerance_row = trace_height - 1 - int(round(min(1.0, tolerance_ms / scale_ms) * (trace_height - 1)))
    per_column = max(1, len(result.errors) // max(1, width))
    for x in range(width):
        chunk = result.errors[x * per_column : (x + 1) * per_column]
        error = max((abs(value) for _t, value in chunk), default=0.0)
        height = int(round(min(1.0, error / scale_ms) * (trace_height - 1)))
        for y in range(trace_height - 1 - height, trace_height):
            trace[y][x] = (90, 200, 240) if error <= tolerance_ms else (240, 170, 60)
        trace[tolerance_row][x] = (190, 50, 50)
    rows.extend(trace)
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_bytes(_png_bytes(rows))


# --- the catalogue -------------------------------------------------------------


#: The live idle roll (colour list + rolls), a travelling chase, a breath.
SAMPLES: dict[str, str] = {
    "idle_roll": (
        "#0A1F3D #102B55 #163A70 #1D4A8C #163A70 #102B55 #0A1F3D #06142A 250ms\n"
        "roll-right 2s\nroll-right 2s\nroll-right 2s\nroll-right 2s\nroll-right 2s\nroll-right 2s\nrepeat"
    ),
}


def corpus(names: list[str] | None = None) -> dict[str, str]:
    from review_effects import effect_programs

    programs = dict(SAMPLES)
    for name, program, leds in effect_programs():
        if leds == 8:
            programs[name.removeprefix("effect_").removesuffix("_8led")] = program
    if names:
        programs = {key: value for key, value in programs.items() if key in names}
    return programs


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--out", default="build/linked-sync", type=Path)
    parser.add_argument("--effects", default="idle_roll,comet,breathe,chase,scanner")
    parser.add_argument("--minutes", type=float, default=5.0)
    parser.add_argument("--look", choices=("mirror", "continue"), default="mirror")
    parser.add_argument("--from-seconds", type=float, default=60.0)
    parser.add_argument("--for-seconds", type=float, default=30.0)
    parser.add_argument("--column-ms", type=float, default=20.0, help="time per pixel column")
    parser.add_argument("--zoom", type=int, default=1, help="pixels per column and per row unit")
    arguments = parser.parse_args()
    names = [name for name in arguments.effects.split(",") if name] or None
    if arguments.look == "continue":
        for effect, program in corpus(names).items():
            if continue_program(program, source_leds=8) is None:
                print(f"{effect:12} continue: mirrors (nothing travels, or no spelling is true enough)")
                continue
            outcome = simulate(
                program,
                effect=effect,
                minutes=arguments.minutes,
                look="continue",
                columns_from_s=arguments.from_seconds,
                columns_for_s=arguments.for_seconds,
                column_every_s=arguments.column_ms / 1000.0,
            )
            render_continue(outcome, arguments.out / f"{effect}-continue.png", zoom=max(1, arguments.zoom))
            print(
                f"{effect:12} continue: max error {outcome.max_error_ms:7.1f} ms, "
                f"re-anchors {outcome.reanchors:2d}, mean engine gap {outcome.mean_engine_gap:5.1f}"
            )
        return 0
    for effect, program in corpus(names).items():
        for planner in ("old", "new"):
            outcome = simulate(program, effect=effect, planner=planner, minutes=arguments.minutes)
            render(outcome, arguments.out / f"{effect}-{planner}.png")
            print(
                f"{effect:12} {planner}: max error {outcome.max_error_ms:7.1f} ms, "
                f"after 60 s {outcome.max_error_after(60):7.1f} ms, "
                f"re-anchors {outcome.reanchors:2d}, mean engine gap {outcome.mean_engine_gap:5.1f}"
            )
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
