#!/usr/bin/env python3
"""Sample every JR-Bar light program through the real firmware and judge it.

The firmware engine (``jrbar/resources/sdled.wasm``) is the only authority on
what a strip actually shows, so this harness parses each program with it and
steps it at 60 Hz for one cycle. From those samples it writes

* ``<out>/png/<name>.png`` -- a strip timeline (rows = time, columns = LEDs),
  so a sweep looks like a diagonal and a blink looks like stripes; and
* ``<out>/metrics.json`` / a printed table -- max per-LED luminance jump per
  frame, effective flash rate (luminance reversals per second above 20%
  contrast, whole-strip and worst single LED), cycle length, bytes and lines.

Run it with the repo venv:

    .venv/bin/python scripts/review_effects.py --out build/effect-review

``--compare BEFORE.json`` prints a before/after table against an earlier run.
"""

from __future__ import annotations

import argparse
import json
import struct
import sys
import zlib
from dataclasses import asdict, dataclass
from itertools import pairwise
from pathlib import Path

REPO = Path(__file__).resolve().parents[1]
if str(REPO / "src") not in sys.path:
    sys.path.insert(0, str(REPO / "src"))

from jrbar import _led_status_legacy as led_status  # noqa: E402
from jrbar import colors as colors_module  # noqa: E402
from jrbar import core_effects  # noqa: E402
from jrbar._led_wasm_legacy import SdLedWasmController  # noqa: E402  raw firmware
from jrbar.animation import (  # noqa: E402
    animation_duration_ms,
    errors_only,
    loop_duration_ms,
    read_program,
)
from jrbar.effect_registry import EFFECT_REGISTRY  # noqa: E402
from jrbar.lid_presets import LID_ANIMATION_PRESETS  # noqa: E402
from jrbar.models import AgentMode  # noqa: E402
from jrbar.presentation_compiler import compile_presentation_program  # noqa: E402

FRAME_HZ = 60.0
FRAME_MS = 1000.0 / FRAME_HZ
MIN_WINDOW_MS = 1000
MAX_WINDOW_MS = 10_000
#: Luminance reversals smaller than this contrast are motion, not a flash.
FLASH_CONTRAST = 0.20
MAX_PROGRAM_BYTES = 512
MAX_PROGRAM_LINES = 20


# --- sampling ---------------------------------------------------------------


def _luminance(pixel: tuple[int, int, int]) -> float:
    red, green, blue = (channel / 255.0 for channel in pixel)
    return 0.2126 * red + 0.7152 * green + 0.0722 * blue


@dataclass(frozen=True, slots=True)
class Metrics:
    name: str
    led_count: int
    cycle_ms: int
    frames: int
    bytes_used: int
    lines_used: int
    max_led_jump: float
    p95_led_jump: float
    max_strip_jump: float
    flash_hz_strip: float
    flash_hz_led: float
    compiled: bool
    parse_ok: bool
    note: str = ""


def window_ms(program: str, led_count: int) -> int:
    animation, problems = read_program(program, led_count=led_count)
    if errors_only(problems):
        return 2000
    loop = loop_duration_ms(animation)
    total = loop if loop else animation_duration_ms(animation)
    if not total:
        total = 1000
    # A finite cue is judged over its whole life; a loop over one cycle,
    # padded to at least a second so a fast rhythm still shows repetitions.
    while total < MIN_WINDOW_MS:
        total *= 2
    return int(min(MAX_WINDOW_MS, total))


def sample(program: str, led_count: int, span_ms: int) -> list[list[tuple[int, int, int]]]:
    controller = SdLedWasmController(led_count)
    controller.reset(0)
    result = controller.parse(program, 0)
    if not result.ok:
        raise ValueError(f"firmware rejected program ({result.error_name})")
    frames = int(span_ms / FRAME_MS) + 1
    return controller.step_batch(0, int(round(FRAME_MS)), frames)


def _flash_hz(series: list[float], seconds: float) -> float:
    """Luminance reversals per second whose contrast clears FLASH_CONTRAST.

    Extrema are collected first, then neighbouring extrema are paired: each
    qualifying rise or fall is half a flash, so a square wave that goes dark
    and bright once per second reports 1 Hz. Michelson contrast keeps the
    test scale-free, so dimming a strobe does not hide it.
    """
    if len(series) < 3 or seconds <= 0:
        return 0.0
    extrema = [series[0]]
    direction = 0
    for previous, value in pairwise(series):
        step = value - previous
        if abs(step) < 1e-6:
            continue
        sign = 1 if step > 0 else -1
        if sign == direction:
            extrema[-1] = value
        else:
            extrema.append(value)
            direction = sign
    halves = 0
    for low, high in pairwise(extrema):
        span = abs(high - low)
        total = abs(high) + abs(low)
        contrast = span / total if total > 1e-9 else 0.0
        if contrast >= FLASH_CONTRAST and span >= 0.02:
            halves += 1
    return halves / 2.0 / seconds


def measure(name: str, program: str, led_count: int, *, compiled: bool) -> tuple[Metrics, list]:
    span = window_ms(program, led_count)
    try:
        frames = sample(program, led_count, span)
        parse_ok = True
        note = ""
    except ValueError as error:
        frames = []
        parse_ok = False
        note = str(error)
    lines = [line for line in program.splitlines() if line.strip()]
    if not frames:
        return (
            Metrics(
                name,
                led_count,
                span,
                0,
                len(program.encode("utf-8")),
                len(lines),
                0.0,
                0.0,
                0.0,
                0.0,
                0.0,
                compiled,
                parse_ok,
                note,
            ),
            [],
        )
    luminance = [[_luminance(pixel) for pixel in frame] for frame in frames]
    per_led = list(zip(*luminance))
    jumps = [
        abs(after - before)
        for track in per_led
        for before, after in pairwise(track)
    ]
    jumps.sort()
    strip = [sum(frame) / len(frame) for frame in luminance]
    strip_jumps = [abs(after - before) for before, after in pairwise(strip)]
    seconds = span / 1000.0
    return (
        Metrics(
            name,
            led_count,
            span,
            len(frames),
            len(program.encode("utf-8")),
            len(lines),
            round(max(jumps) if jumps else 0.0, 4),
            round(jumps[int(0.95 * (len(jumps) - 1))] if jumps else 0.0, 4),
            round(max(strip_jumps) if strip_jumps else 0.0, 4),
            round(_flash_hz(strip, seconds), 2),
            round(max(_flash_hz(list(track), seconds) for track in per_led), 2),
            compiled,
            parse_ok,
            note,
        ),
        frames,
    )


# --- PNG --------------------------------------------------------------------


def _png_bytes(rows: list[list[tuple[int, int, int]]]) -> bytes:
    height = len(rows)
    width = len(rows[0]) if rows else 0
    raw = bytearray()
    for row in rows:
        raw.append(0)
        for red, green, blue in row:
            raw += bytes((red, green, blue))

    def chunk(tag: bytes, payload: bytes) -> bytes:
        return (
            struct.pack(">I", len(payload))
            + tag
            + payload
            + struct.pack(">I", zlib.crc32(tag + payload) & 0xFFFFFFFF)
        )

    header = struct.pack(">IIBBBBB", width, height, 8, 2, 0, 0, 0)
    return (
        b"\x89PNG\r\n\x1a\n"
        + chunk(b"IHDR", header)
        + chunk(b"IDAT", zlib.compress(bytes(raw), 9))
        + chunk(b"IEND", b"")
    )


def write_timeline(path: Path, frames: list, *, cell_width: int = 26, cell_height: int = 2) -> None:
    if not frames:
        return
    gap = 1
    rows: list[list[tuple[int, int, int]]] = []
    for frame in frames:
        row: list[tuple[int, int, int]] = []
        for pixel in frame:
            row.extend([pixel] * cell_width)
            row.extend([(24, 24, 28)] * gap)
        rows.extend([row] * cell_height)
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_bytes(_png_bytes(rows))


# --- the catalogue ----------------------------------------------------------


def builtin_programs() -> list[tuple[str, str, int]]:
    """Every program the app can put on a strip, outside the effect registry."""
    from jrbar._settings_legacy import AgentMonitorSettings

    settings = AgentMonitorSettings().colors
    entries: list[tuple[str, str, int]] = []
    for led_count in (8, 2):
        suffix = f"{led_count}led"
        for mode in AgentMode:
            state = led_status.display_state_for_mode(mode)
            entries.append(
                (
                    f"mode_{mode.value}_{state.value}_{suffix}",
                    led_status.program_for_display_state(state, led_count=led_count),
                    led_count,
                )
            )
        entries.append(
            (
                f"done_celebration_{suffix}",
                led_status.program_for_display_state(
                    led_status.LedDisplayState.DONE,
                    led_count=led_count,
                    done_celebrate=True,
                ),
                led_count,
            )
        )
        entries.append(
            (
                f"failed_{suffix}",
                led_status.program_for_display_state(
                    led_status.LedDisplayState.FAILED, led_count=led_count
                ),
                led_count,
            )
        )
        entries.append(
            (
                f"working_relay_{suffix}",
                led_status.rolling_program(
                    colors_module.WORKING_CYAN, led_count=led_count
                ),
                led_count,
            )
        )
        for motion in colors_module.PROVIDER_ANIMATION_CHOICES:
            colors = settings.with_agent_animation("claude", motion)
            entries.append(
                (
                    f"motion_{motion}_{suffix}",
                    colors_module.provider_motion_preview_program(
                        "claude",
                        colors.agent_color("claude"),
                        colors,
                        led_count=led_count,
                    ),
                    led_count,
                )
            )
    entries.append(("first_light_8led", led_status.first_light_program(), 8))
    for kind, presets in LID_ANIMATION_PRESETS.items():
        for label, _seconds, program in presets:
            slug = label.lower().replace(" ", "_")
            entries.append((f"lid_{kind}_{slug}", program, 8))
    return entries


def effect_programs() -> list[tuple[str, str, int]]:
    entries: list[tuple[str, str, int]] = []
    for identifier, effect in EFFECT_REGISTRY.as_mapping().items():
        parameters = core_effects.normalize_parameters(effect, {})
        for led_count in (8, 2):
            program = core_effects.render_effect(
                effect, parameters, led_count=led_count
            )
            entries.append((f"effect_{identifier}_{led_count}led", program, led_count))
    return entries


def review(out_dir: Path, *, png: bool = True) -> list[Metrics]:
    rows: list[Metrics] = []
    programs = {}
    for name, program, led_count in [*effect_programs(), *builtin_programs()]:
        compiled = compile_presentation_program(program, led_count=led_count)
        shown = compiled.program if compiled.accepted else program
        metrics, frames = measure(name, shown, led_count, compiled=compiled.transformed)
        rows.append(metrics)
        programs[name] = {
            "authored": program,
            "shown": shown,
            "accepted": compiled.accepted,
            "reasons": list(compiled.reasons),
            "led_count": led_count,
        }
        if png:
            write_timeline(out_dir / "png" / f"{name}.png", frames)
    out_dir.mkdir(parents=True, exist_ok=True)
    (out_dir / "metrics.json").write_text(
        json.dumps([asdict(row) for row in rows], indent=2) + "\n"
    )
    (out_dir / "programs.json").write_text(json.dumps(programs, indent=2) + "\n")
    return rows


HEADERS = (
    ("name", 44),
    ("leds", 4),
    ("cycle", 6),
    ("bytes", 5),
    ("ln", 3),
    ("jump", 6),
    ("p95", 6),
    ("flashHz", 7),
    ("ledHz", 6),
)


def print_table(rows: list[Metrics]) -> None:
    print("  ".join(name.ljust(width) for name, width in HEADERS))
    for row in rows:
        cells = (
            row.name,
            str(row.led_count),
            str(row.cycle_ms),
            str(row.bytes_used),
            str(row.lines_used),
            f"{row.max_led_jump:.3f}",
            f"{row.p95_led_jump:.3f}",
            f"{row.flash_hz_strip:.2f}",
            f"{row.flash_hz_led:.2f}",
        )
        print("  ".join(cell.ljust(width) for cell, (_, width) in zip(cells, HEADERS)))


def print_comparison(before_path: Path, rows: list[Metrics]) -> None:
    before = {
        (row["name"], row["led_count"]): row
        for row in json.loads(before_path.read_text())
    }
    print()
    print("before -> after (max per-frame LED jump | flash Hz strip | flash Hz LED)")
    for row in rows:
        old = before.get((row.name, row.led_count))
        if old is None:
            continue
        if (
            abs(old["max_led_jump"] - row.max_led_jump) < 0.005
            and abs(old["flash_hz_strip"] - row.flash_hz_strip) < 0.05
            and abs(old["flash_hz_led"] - row.flash_hz_led) < 0.05
        ):
            continue
        print(
            f"{row.name:<44} "
            f"{old['max_led_jump']:.3f}->{row.max_led_jump:.3f}  "
            f"{old['flash_hz_strip']:.2f}->{row.flash_hz_strip:.2f}  "
            f"{old['flash_hz_led']:.2f}->{row.flash_hz_led:.2f}"
        )


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--out", default="build/effect-review", type=Path)
    parser.add_argument("--compare", type=Path, default=None)
    parser.add_argument("--no-png", action="store_true")
    parser.add_argument("--filter", default="")
    arguments = parser.parse_args()
    rows = review(arguments.out, png=not arguments.no_png)
    shown = [row for row in rows if arguments.filter in row.name]
    print_table(shown)
    unsafe = [row for row in rows if not row.parse_ok]
    if unsafe:
        print()
        print("REJECTED BY FIRMWARE:")
        for row in unsafe:
            print(f"  {row.name}: {row.note}")
    if arguments.compare is not None:
        print_comparison(arguments.compare, rows)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
