#!/usr/bin/env python3
"""Generate LEDS parity fixtures from the Python/firmware reference.

Run from the repository root with the repo venv, so ``jrbar`` imports from
``src/``:

    .venv/bin/python app/scripts/gen_leds_fixtures.py
    .venv/bin/python app/scripts/gen_leds_fixtures.py --compiler-only

The second form rewrites only ``compiler.json`` and ``flash.json`` and needs
no firmware, so the sampler fixtures are not re-sampled and ``programs/`` does
not churn.
``tests/test_leds_fixtures_match_reference.py`` compares every stored file
to the rows built here and fails when one is stale.

What is called, and why
-----------------------
The Python app never samples LED colours itself. Its Screen Bar pipeline
(``screen_bar_pipeline.ScreenBarSampler``) drives the firmware's own parser
and renderer, ``jrbar/resources/sdled.wasm``, through JavaScriptCore via
``jrbar.led_wasm.RawSdLedWasmController``:

    controller = RawSdLedWasmController(led_count)   # raw firmware engine
    controller.reset(0)
    controller.parse(program, 0)                  # anchor at t = 0 ms
    controller.step(t_ms) -> [(r, g, b), ...]     # 8-bit codes after brightness

``jrbar.led_wasm.SdLedWasmController`` (the safety-enforcing controller) runs
``presentation_compiler.compile_presentation_program`` first; that transform
is recorded separately in ``compiler.json`` so the Swift port of the compiler
can be checked as text, and the engine fixtures stay a pure firmware truth.

Every fixture comes from a program embedded here or built by the daemon's own
functions, never from a file on a mounted device, so regenerating is
reproducible. The ``program_rows``, ``verdict_rows`` and ``compiler_rows``
builders return rows and write nothing; ``main`` alone writes.

Outputs (all under app/Tests/JRBarLEDSTests/Fixtures/):

* ``programs/<name>.json``  -- one program, one LED count, samples at the
  required times (0, 0.05, 0.1, 0.25, 0.5, 1.0, 1.5, 2.0, 3.7 s) plus a denser
  sweep so easing curves are actually exercised. ``programs/motions`` belongs
  to ``scripts/export_motion_fixtures.py`` and is left alone.
* ``parse_verdicts.json``   -- firmware parse results (ok / error name) for a
  list of edge-case programs at 8 and 2 LEDs.
* ``compiler.json``         -- ``compile_presentation_program`` results.
* ``flash.json``            -- ``flash_analysis.analyse`` measurements (hertz,
  flashes, span, peak area) of the same programs, so the Swift port of the
  measured-flash pass is checked number for number, not only through the
  compiled text it decides.
"""

from __future__ import annotations

import argparse
import json
import re
import sys
from pathlib import Path

REPO = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(REPO / "src"))

from jrbar import led_status  # noqa: E402
from jrbar.animation import errors_only, read_program  # noqa: E402
from jrbar.flash_analysis import analyse  # noqa: E402

# The raw firmware engine, by name: ``SdLedWasmController`` compiles every
# program before it parses it and would sample the compiler's output instead
# of the text.
from jrbar.led_wasm import RawSdLedWasmController  # noqa: E402
from jrbar.models import AgentMode  # noqa: E402
from jrbar.presentation_compiler import compile_presentation_program  # noqa: E402

FIXTURES = REPO / "app" / "Tests" / "JRBarLEDSTests" / "Fixtures"
REQUIRED_TIMES_S = [0, 0.05, 0.1, 0.25, 0.5, 1.0, 1.5, 2.0, 3.7]
# A provenance label stored in the committed fixtures: it names the module the
# engine lived in before the facade collapse, so it stays as written.
ENGINE = "sdled.wasm via jrbar._led_wasm_legacy.SdLedWasmController: reset(0); parse(program, 0); step(t_ms)"


def sample(program: str, led_count: int, times_ms: list[int]) -> list[dict]:
    controller = RawSdLedWasmController(led_count)
    controller.reset(0)
    result = controller.parse(program, 0)
    if not result.ok:
        raise SystemExit(f"firmware rejected fixture program ({result.error_name}): {program!r}")
    samples = []
    for t in times_ms:
        pixels = controller.step(t)
        samples.append({"t_ms": t, "colors": [list(p) for p in pixels]})
    return samples


def times_for(program: str) -> list[int]:
    times = {int(round(t * 1000)) for t in REQUIRED_TIMES_S}
    # Dense-ish sweep through the first four seconds (every 37 ms avoids
    # lining up with 17 ms frames or round durations) plus a few late points.
    times.update(range(0, 4000, 37))
    times.update([5000, 6500, 8000, 12345, 30000])
    return sorted(times)


def slug(name: str) -> str:
    return re.sub(r"[^a-z0-9]+", "_", name.lower()).strip("_")


def program_set() -> dict[str, tuple[str, int]]:
    """Every fixture program as ``name -> (program, led_count)``.

    Pure: nothing is read from a device, written, or sampled. The sampler
    fixtures and the compiler fixtures are both built from this set.
    """
    programs: dict[str, tuple[str, int]] = {}

    # A device program, embedded so the fixture is stable whatever a
    # mounted strip happens to be showing.
    programs["device_quota_ember"] = (
        "#000000 160ms cosine\n"
        "0:#1D050A 420ms pulse 0ms; 1:#1D050A 420ms pulse 180ms; 2:#1D050A 420ms pulse 360ms; "
        "3:#1D050A 420ms pulse 540ms; 4:#1D050A 420ms pulse 720ms; 5:#1D050A 420ms pulse 900ms; "
        "6:#1D050A 420ms pulse 1080ms; 7:#1D050A 420ms pulse 1260ms\n"
        "#000000 600ms none\n"
        "repeat",
        8,
    )

    seen: set[tuple[str, int]] = set()
    for led_count in (8, 2):
        for mode in AgentMode:
            state = led_status.display_state_for_mode(mode)
            program = led_status.program_for_display_state(state, led_count=led_count)
            key = (program, led_count)
            if key in seen:
                continue
            seen.add(key)
            programs[f"mode_{mode.value}_{state.value}_{led_count}led"] = key
        programs[f"done_celebration_{led_count}led"] = (
            led_status.program_for_display_state(
                led_status.LedDisplayState.DONE, led_count=led_count, done_celebrate=True
            ),
            led_count,
        )
        programs[f"failed_{led_count}led"] = (
            led_status.program_for_display_state(led_status.LedDisplayState.FAILED, led_count=led_count),
            led_count,
        )
    programs["first_light_8led"] = (led_status.first_light_program(), 8)
    programs["working_roll_style_8led"] = (
        led_status.program_for_display_state(
            led_status.LedDisplayState.WORKING, led_count=8, working_style=led_status.ANIMATION_STYLE_ROLL
        ),
        8,
    )
    programs["ask_blink_style_brightness_8led"] = (
        led_status.program_for_display_state(
            led_status.LedDisplayState.ASK, led_count=8, ask_style=led_status.ANIMATION_STYLE_BLINK, brightness=140
        ),
        8,
    )

    # Hand-written edge cases: every syntax feature the format supports.
    hand = {
        "edge_all_easings_8led": (
            "#000000\n#FFFFFF 700ms linear\n#000000 700ms ease\n#FF8800 700ms ease-in\n"
            "#000000 700ms ease-out\n#00AAFF 700ms ease-in-out\n#000000 700ms cosine\n"
            "#FF00FF 900ms pulse\n#101010 400ms none\nrepeat",
            8,
        ),
        "edge_default_easing_and_delay_8led": (
            "#ff0000\n#0000ff 1000ms 500ms\n#00ff00 pulse 1s\n#ffffff linear 250ms\n#000000 0.4s",
            8,
        ),
        "edge_color_list_brightness_8led": (
            "brightness 128\n# comment line\n// another\n; and another\n"
            "#ff0000 #00ff00 #0000ff #ffffff #000000 #808080 #ff00ff #00ffff #123456 #654321 500ms linear\n"
            "#00ff00 #0000ff 800ms cosine\nbrightness 200\noff 300ms ease-out\nrepeat 2\n#404040",
            8,
        ),
        "edge_indexed_hold_and_stagger_8led": (
            "#202020\n0:#ff0000 150ms ease 0ms; 1:#ff8000 150ms ease 50ms; 2:#ffff00 150ms ease 100ms; 3:#00ff00 150ms ease 150ms\n"
            "4:#00ccff 150ms ease 0ms; 5:#004cff 150ms ease 50ms; 6:#8800ff 150ms ease 100ms; 7:#ff00cc 150ms ease 150ms\n"
            "3:#ffffff 80ms none\n0:#000000 400ms pulse; 0:#00ffff 900ms linear; 9:#ffffff 5s\nrepeat",
            8,
        ),
        "edge_roll_linear_8led": (
            "#ff0044 #ff8800 #ffff00 #00ff66 #00ccff #004cff #8800ff #ff00cc\nroll 2s linear\nrepeat",
            8,
        ),
        "edge_roll_left_ease_8led": (
            "#ff0000 #00ff00 #0000ff #ffffff #000000 #808080 #ff00ff #00ffff\nroll-left 1.3s ease\nroll-right 900ms cosine\nroll 700ms none\nrepeat",
            8,
        ),
        "edge_finite_repeat_tail_8led": (
            "off\n#ff0000 200ms none\n#00ff00 200ms none\nrepeat 3\n#0000ff 500ms cosine\n#ffffff 1s pulse\noff 250ms",
            8,
        ),
        "edge_zero_and_frame_lines_8led": (
            "#ff0000\n#00ff00\n#0000ff 0ms linear\n#ffffff 0ms linear 100ms\n#101010 1ms linear\n#ff00ff 5ms\nroll 0ms\n#00ffff 300ms linear\n#404040 none 100ms",
            8,
        ),
        "edge_two_led_ignored_indexes_2led": (
            "#ff0000\n0:#00ff00 100ms; 5:#0000ff 1000ms\n#ffffff 400ms linear\n0:#ff00ff 1400ms pulse 0ms; 1:#ff00ff 1400ms pulse 480ms\nrepeat",
            2,
        ),
        "edge_two_led_roll_2led": (
            "#ff0000 #00ff00 #0000ff\nroll 800ms linear\nroll-left 800ms ease-in\nrepeat",
            2,
        ),
        "edge_brightness_fade_8led": (
            "brightness 37\n#123456\n#fedcba 1000ms cosine\n#000000 1s ease-in-out\nrepeat",
            8,
        ),
        "edge_crlf_and_case_8led": (
            "OFF 100MS COSINE\r\n#FfAa00 1S PULSE\r\n0:#00FF00 250ms Ease-In 100ms; 1:#0000FF 0.5s EASE-OUT\r\nRepeat\r\n",
            8,
        ),
    }
    programs.update(hand)
    return programs


def program_rows() -> list[dict]:
    """One row per program fixture, sampled through the firmware."""
    rows = []
    for name, (program, led_count) in program_set().items():
        rows.append(
            {
                "name": name,
                "led_count": led_count,
                "program": program,
                "engine": ENGINE,
                "samples": sample(program, led_count, times_for(program)),
            }
        )
    return rows


def verdict_rows() -> list[dict]:
    """Parse verdicts: what the firmware says about edge-case text."""
    verdict_programs = [
        "", "\n", "# c", "#c", "#", "// c", ";c", " ; c", "OFF", "Off", "REPEAT", "#ffffff\nRepeat",
        "BRIGHTNESS 10\n#ffffff", "#FFFFFF", "#fff", "#ffffff 500", "#ffffff 1.5S", "#ffffff .5s",
        "#ffffff 0.3333s", "#ffffff 65535ms", "#ffffff 65536ms", "#ffffff 65.535s", "#ffffff 66s",
        "#ffffff LINEAR", "#ffffff 1s linear 1s 1s", "#ffffff 1s 1s 1s", "#ffffff linear 1s", "#ffffff 1s 1s",
        "0:#ffffff", "0: #ffffff", "8:#ffffff", "99:#ffffff", "0:off", "off 1s", "off #ffffff", "#ffffff off",
        "#ffffff\t500ms", "  #ffffff  500ms  ", "#ffffff 500ms;", "#ffffff;#000000", "#ffffff; ; #000000",
        "#ffffff\r\n#000000", "#ffffff\r#000000", "repeat", "brightness 100\nrepeat\n#ffffff",
        "#ffffff\nrepeat\nrepeat", "#ffffff\nrepeat 0", "#ffffff\nrepeat 1", "#ffffff\nrepeat 65535",
        "#ffffff\nrepeat 65536", "#ffffff\nrepeat x", "brightness", "brightness 256", "brightness -1",
        "brightness 255", "brightness 0255", "roll", "roll 1s", "roll 1s linear 1s", "roll 1s; #ffffff",
        "#ffffff; roll 1s", "roll-left 1s ease", "roll-right 1s cosine", "roll 1s pulse", "roll 1s none",
        "roll 0ms", "ROLL 1s", "#ffffff\n\n\n#000000", "#ffffff x", "#ffffff 500ms x", "0:#ffffff 1:#000000",
        "0:#ffffff #000000", "#ffffff 0:#000000", "#ffffff\xa0500ms", "0:#ffffff 500ms 1:#000000", "#gggggg",
        "#ffffff 1000MS", "repeat 2\n#ffffff", "brightness 100", "# only comment", "#ffffff linear ease",
        "#ffffff 1s 1s ease", "#ffffff 1s ease ease", "#ffffff ease 1s 1s", "roll linear 1s", "roll 1s linear extra",
        "#ffffffff", "#ffffff,", "0:#ffffff,", "99999999999999:#ffffff", "#ffffff 1.0s", "#ffffff 5.s",
        "#ffffff 65535.999s", "brightness 00", "repeat 1", "#ffffff\nrepeat 01", "#ffffff\nrepeat 000",
        "#\tc", "#\t", "# ", "//", "#ffffff # c", "#ffffff // c", "#ffffff ; // c", "#ffffff;# c",
        "5:#ffffff 1s\nrepeat", "roll 1s\nrepeat", "#ffffff\n" * 20, "\n".join(["#ffffff"] * 20) + "\n\n",
        "\n".join(["#ffffff"] * 21), "\n".join(["# c"] * 21), "\n\r".join(["#ffffff"] * 11),
        "#ffffff " + " ".join(["#000000"] * 70), "#ffffff " + " ".join(["#000000"] * 63), "x" * 512,
        "#ffffff\n" + "# " + "x" * 503, "#ffffff\n" + "# " + "x" * 502, "brightness 1a", "brightness 10 20",
        "#ffffff\nrepeat 2 3", "rollx 1s", "-1:#ffffff", "01:#ffffff", "#ffffff 1e3ms", "#ffffff +1s",
    ]
    verdicts = []
    for led_count in (8, 2):
        for program in verdict_programs:
            controller = RawSdLedWasmController(led_count)
            controller.reset(0)
            result = controller.parse(program, 0)
            verdicts.append(
                {
                    "program": program,
                    "led_count": led_count,
                    "ok": result.ok,
                    "error_name": None if result.ok else result.error_name,
                    "line": result.line,
                    "column": result.column,
                }
            )
    return verdicts


#: Hand-written loops that stress the temporal-safety compiler's text rules.
COMPILER_EXTRAS: list[tuple[str, int]] = [
    ("#ff0000 50ms none\n#000000 50ms none\nrepeat", 8),
    ("#ffffff 80ms none\n#000000\nrepeat", 8),
    ("#ff0000\n#000000\nrepeat", 8),
    ("0:#ffffff 90ms none\n2:#ff00ee 90ms none\n5:#00ccff 90ms none\noff 120ms ease-out\nrepeat", 8),
    ("#ff0000 #00ff00\nroll 100ms\nrepeat", 8),
    ("#e00000 100ms pulse\nrepeat", 8),
    ("#ffffff pulse\n#000000 ease\nrepeat", 8),
    ("#ffffff 200ms linear 100ms\n#000000 100ms\nrepeat", 8),
    ("#ffffff 1s\nrepeat 3\noff", 8),
    ("#ffffff 1s\noff", 8),
    ("roll 100ms", 8),
    ("#ffffff 40s\n#000000 40s\nrepeat", 8),
]


def _alternating(bright: str, phase_ms: int, cycles: int) -> str:
    """``cycles`` bright/dark pairs of whole-bar lines, then ``repeat``."""
    lines = []
    for _ in range(cycles):
        lines.append(f"{bright} {phase_ms}ms none")
        lines.append(f"#000000 {phase_ms}ms none")
    return "\n".join([*lines, "repeat"])


def _indexed_field(color: str, leds: range, phase_ms: int) -> str:
    return "; ".join(f"{index}:{color} {phase_ms}ms none" for index in leds)


#: Loops the MEASURED flash pass has to judge, because their text alone does
#: not say how fast the field reverses: a sustained whole-bar blink whose loop
#: is long enough to pass the cycle floor, the same in saturated red, an
#: indexed blink that is field-wide, a head that only travels (untouched), the
#: untimed indexed lines the phase floor exempts, the 2 Hz and 1 Hz
#: boundaries, a roll, a colour list, every easing curve, and brightness.
#: Colours are uppercase so an untouched loop reports ``transformed: false``.
SUSTAINED_FLASH_PROGRAMS: list[tuple[str, int]] = [
    (_alternating("#FFFFFF", 100, 5), 8),
    (_alternating("#FF0000", 100, 5), 8),
    (_alternating("#FFFFFF", 60, 5), 8),
    (
        "\n".join(
            [
                _indexed_field("#FFFFFF", range(8), 100),
                "#000000 100ms none",
                "repeat",
            ]
        ),
        8,
    ),
    (
        "\n".join(
            [
                "0:#00CCFF 80ms none",
                *(f"{k - 1}:#000000 80ms none; {k}:#00CCFF 80ms none" for k in range(1, 8)),
                "7:#000000 80ms none",
                "repeat",
            ]
        ),
        8,
    ),
    ("0:#FF0000\n1:#FF0000\n2:#000000\nrepeat", 8),
    ("#FFFFFF 250ms none\n#000000 250ms none\nrepeat", 8),
    ("#FF0000 500ms none\n#000000 500ms none\nrepeat", 8),
    ("#FFFFFF 200ms none\n#000000 200ms none\n#FFFFFF 200ms none\n#000000 200ms none\nrepeat", 8),
    ("#FFFFFF #000000 #FFFFFF #000000 #FFFFFF #000000 #FFFFFF #000000 400ms none\nroll-right 400ms linear\nrepeat", 8),
    ("#00FF00 #0000FF #FFFFFF #000000 #808080 #FF00FF #00FFFF #FFFF00\n#000000 200ms none\nrepeat", 8),
    ("#FFFFFF 200ms pulse\n#000000 200ms none\nrepeat", 8),
    ("#FFFFFF 150ms cosine\n#000000 150ms cosine\nrepeat", 8),
    ("#FFFFFF 200ms linear\n#000000 200ms linear\nrepeat", 8),
    ("#FFFFFF 200ms ease\n#000000 200ms ease\nrepeat", 8),
    ("#FFFFFF 200ms ease-in-out\n#000000 200ms ease-in-out\nrepeat", 8),
    ("#FFFFFF 200ms\n#000000 200ms\nrepeat", 8),
    ("brightness 128\n#FFFFFF 100ms none\n#000000 100ms none\nrepeat", 8),
    # Two of eight LEDs is exactly the area threshold and counts; one does not.
    ("0:#FFFFFF 100ms none; 1:#FFFFFF 100ms none\n0:#000000 100ms none; 1:#000000 100ms none\nrepeat", 8),
    ("0:#FFFFFF 100ms none\n0:#000000 100ms none\nrepeat", 8),
    # A loop long enough to exhaust the sampling budget.
    ("#FFFFFF 20s none\n#000000 20s none\nrepeat", 8),
    # The Dot: two LEDs, and an index the Dot does not have.
    ("0:#FFFFFF 100ms none; 1:#FFFFFF 100ms none\n0:#000000 100ms none; 1:#000000 100ms none\nrepeat", 2),
    ("0:#FFFFFF 100ms none; 5:#FFFFFF 100ms none\n0:#000000 100ms none; 5:#000000 100ms none\nrepeat", 2),
    ("#FF0000 #00FF00 #0000FF\nroll 800ms linear\nrepeat", 2),
    # Three 100 ms pairs: a 600 ms loop that clears the cycle floor at 5 Hz.
    (_alternating("#FFFFFF", 100, 3), 8),
    # Untimed named-LED lines inside a loop that already clears the floor.
    ("0:#FFFFFF\n1:#00FF00\n#000000 500ms\nrepeat", 8),
]


def compiler_programs() -> list[tuple[str, int]]:
    """Every ``(program, led_count)`` the compiler and flash fixtures cover."""
    return [*program_set().values(), *COMPILER_EXTRAS, *SUSTAINED_FLASH_PROGRAMS]


def compiler_rows() -> list[dict]:
    """``compile_presentation_program`` over every program fixture and the
    hand-written loops above. Pure Python: no firmware is needed."""
    compiled = []
    for program, led_count in compiler_programs():
        result = compile_presentation_program(program, led_count=led_count)
        compiled.append(
            {
                "program": program,
                "led_count": led_count,
                "accepted": result.accepted,
                "transformed": result.transformed,
                "reasons": list(result.reasons),
                "output": result.program,
            }
        )
    return compiled


def flash_rows() -> list[dict]:
    """``flash_analysis.analyse`` over the same programs, as the raw text
    parses (before any compiler pass). Pure Python: no firmware is needed."""
    rows = []
    for program, led_count in compiler_programs():
        animation, problems = read_program(program, led_count=led_count)
        if errors_only(problems):
            continue
        measured = analyse(animation, led_count=led_count)
        rows.append(
            {
                "program": program,
                "led_count": led_count,
                "hertz": measured.hertz,
                "flashes": measured.flashes,
                "span_ms": measured.span_ms,
                "peak_area": measured.peak_area,
            }
        )
    return rows


def write_program_fixtures(rows: list[dict]) -> None:
    programs_dir = FIXTURES / "programs"
    programs_dir.mkdir(parents=True, exist_ok=True)
    # Top level only: programs/motions is written by export_motion_fixtures.py.
    for stale in programs_dir.glob("*.json"):
        stale.unlink()
    for row in rows:
        (programs_dir / f"{slug(row['name'])}.json").write_text(json.dumps(row, indent=1) + "\n")
    print(f"wrote {len(rows)} program fixtures")


def write_json(name: str, rows: list[dict], label: str) -> None:
    (FIXTURES / name).write_text(json.dumps(rows, indent=1) + "\n")
    print(f"wrote {len(rows)} {label}")


def main(argv: list[str] | None = None) -> None:
    parser = argparse.ArgumentParser(description="Regenerate the Swift LEDS parity fixtures.")
    parser.add_argument(
        "--compiler-only",
        action="store_true",
        help="rewrite only compiler.json and flash.json: no firmware sampling, programs/ untouched",
    )
    options = parser.parse_args(argv)
    if not options.compiler_only:
        write_program_fixtures(program_rows())
        write_json("parse_verdicts.json", verdict_rows(), "parse verdicts")
    write_json("compiler.json", compiler_rows(), "compiler fixtures")
    write_json("flash.json", flash_rows(), "flash measurements")


if __name__ == "__main__":
    main()
