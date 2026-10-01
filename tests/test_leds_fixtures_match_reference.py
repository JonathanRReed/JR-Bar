"""The Swift LEDS parity fixtures are what the Python reference says today.

``app/Tests/JRBarLEDSTests/Fixtures`` is the only link between the daemon's
parser, firmware renderer and presentation compiler and their Swift ports
(``LEDSParser``, ``LEDSSampler``, ``LEDSPresentationCompiler``). The
generator, ``app/scripts/gen_leds_fixtures.py``, builds every row from a
pure function; these tests compare the stored files to fresh rows without
writing anything, so a change to the Python side fails here until the
fixtures (and the Swift port) follow. The same pattern guards the moments
fixtures in ``tests/test_lid_presets.py``.
"""

from __future__ import annotations

import builtins
import importlib.util
import json
from pathlib import Path

import pytest

import jrbar.led_wasm
from jrbar.led_wasm import LedWasmUnavailableError

ROOT = Path(__file__).resolve().parents[1]
GENERATOR = ROOT / "app" / "scripts" / "gen_leds_fixtures.py"


@pytest.fixture(scope="module")
def generator():
    spec = importlib.util.spec_from_file_location("gen_leds_fixtures", GENERATOR)
    assert spec is not None and spec.loader is not None
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


def _as_stored(rows):
    """What the generator would have written and a reader gets back."""
    return json.loads(json.dumps(rows))


def _needs_firmware(build):
    try:
        return build()
    except LedWasmUnavailableError as error:  # pragma: no cover - macOS only
        pytest.skip(f"firmware engine unavailable: {error}")


def test_compiler_fixtures_are_what_the_compiler_returns_today(generator) -> None:
    stored = json.loads((generator.FIXTURES / "compiler.json").read_text())
    fresh = _as_stored(generator.compiler_rows())
    assert len(stored) == len(fresh), "compiler.json is stale: re-run the generator"
    for old, new in zip(stored, fresh, strict=True):
        assert old == new, f"compiler.json is stale for {new['program']!r}: re-run the generator"


def test_flash_fixtures_are_what_the_analysis_measures_today(generator) -> None:
    stored = json.loads((generator.FIXTURES / "flash.json").read_text())
    fresh = _as_stored(generator.flash_rows())
    assert len(stored) == len(fresh), "flash.json is stale: re-run the generator"
    for old, new in zip(stored, fresh, strict=True):
        assert old == new, f"flash.json is stale for {new['program']!r}: re-run the generator"


def test_the_fixture_set_covers_what_only_the_measured_pass_can_see(generator) -> None:
    """The Swift compiler once passed every recorded row while lacking the
    measured-flash pass, because no row needed it. These rows do, and each
    category below fails a Swift port that leaves the pass out."""
    from jrbar.animation import loop_duration_ms, read_program

    rows = {row["program"]: row for row in _as_stored(generator.compiler_rows())}

    def row_for(program: str, led_count: int = 8) -> dict:
        row = rows[program]
        assert row["led_count"] == led_count
        return row

    def raw_loop_ms(program: str) -> int:
        animation, _problems = read_program(program, led_count=8)
        return loop_duration_ms(animation) or 0

    # A whole-bar blink whose loop already clears the 500 ms floor, so only
    # the measured rate can slow it: 300 ms phases, then 500 ms in red.
    white = generator._alternating("#FFFFFF", 100, 5)
    assert raw_loop_ms(white) >= 500
    assert row_for(white)["reasons"] == ["loop_cadence_clamped"]
    assert row_for(white)["output"] == generator._alternating("#FFFFFF", 300, 5)
    red = generator._alternating("#FF0000", 100, 5)
    assert row_for(red)["output"] == generator._alternating("#FF0000", 500, 5)

    # A loop under the floor by ten short lines: 600 ms, eight flashes a second.
    short = generator._alternating("#FFFFFF", 60, 5)
    assert raw_loop_ms(short) >= 500
    assert row_for(short)["reasons"] == ["loop_cadence_clamped"]

    # A field-wide indexed blink is measured, and slowed.
    field = generator.SUSTAINED_FLASH_PROGRAMS[3][0]
    assert row_for(field)["reasons"] == ["loop_cadence_clamped"]

    # A head that only travels is untouched.
    head = generator.SUSTAINED_FLASH_PROGRAMS[4][0]
    assert row_for(head)["transformed"] is False
    assert row_for(head)["reasons"] == []

    # Untimed indexed lines keep the phase they were written with: Python
    # stretches only the loop, to 336 ms a line.
    assert row_for("0:#FF0000\n1:#FF0000\n2:#000000\nrepeat")["output"] == (
        "0:#FF0000 336ms\n1:#FF0000 336ms\n2:#000000 336ms\nrepeat"
    )

    # The thresholds: 2 Hz and 1 Hz cadences are unchanged.
    for program in (
        "#FFFFFF 250ms none\n#000000 250ms none\nrepeat",
        "#FF0000 500ms none\n#000000 500ms none\nrepeat",
    ):
        assert row_for(program)["transformed"] is False
        assert row_for(program)["reasons"] == []

    # Every easing curve, a roll, a colour list and brightness are in the set.
    programs = "\n".join(rows)
    for needle in ("pulse", "cosine", "linear", "ease", "roll-right", "brightness 128"):
        assert needle in programs, needle


def test_parse_verdict_fixtures_are_what_the_firmware_says_today(generator) -> None:
    stored = json.loads((generator.FIXTURES / "parse_verdicts.json").read_text())
    fresh = _as_stored(_needs_firmware(generator.verdict_rows))
    assert len(stored) == len(fresh), "parse_verdicts.json is stale: re-run the generator"
    for old, new in zip(stored, fresh, strict=True):
        assert old == new, f"parse_verdicts.json is stale for {new['program']!r}: re-run the generator"


def test_program_fixtures_are_what_the_firmware_renders_today(generator) -> None:
    rows = _needs_firmware(generator.program_rows)
    directory = generator.FIXTURES / "programs"
    # Only the top level: programs/motions belongs to export_motion_fixtures.py.
    stored_files = sorted(path.name for path in directory.glob("*.json"))
    fresh_files = sorted(f"{generator.slug(row['name'])}.json" for row in rows)
    assert stored_files == fresh_files, "programs/ is stale: re-run the generator"
    for row in rows:
        path = directory / f"{generator.slug(row['name'])}.json"
        stored = json.loads(path.read_text())
        fresh = _as_stored(row)
        assert stored["program"] == fresh["program"], path.name
        assert stored["led_count"] == fresh["led_count"], path.name
        assert stored["engine"] == fresh["engine"], path.name
        assert stored["samples"] == fresh["samples"], f"{path.name} is stale: re-run the generator"


def test_the_generator_samples_the_raw_engine_not_the_safety_facade(generator) -> None:
    """``jrbar.led_wasm.SdLedWasmController`` compiles a program before it
    parses it. The fixtures must be the firmware's own answers, so the
    generator holds the raw engine by name: a program the safety compiler
    refuses still samples."""
    assert generator.RawSdLedWasmController is jrbar.led_wasm.RawSdLedWasmController
    refused = "#ff0000\n#00ff00\n#0000ff 0ms linear\nroll 0ms\n#404040 none 100ms"
    _needs_firmware(lambda: generator.sample(refused, 8, [0, 100]))


def test_the_generator_reads_no_device_volume() -> None:
    """Fixtures come from embedded programs, never from whatever a mounted
    strip happens to show, so regenerating is reproducible and reads no
    device. It also no longer names the package it was renamed from."""
    source = GENERATOR.read_text().lower()
    assert "/volumes" not in source
    assert "sidepulse" not in source


def test_the_builders_write_nothing(generator, monkeypatch) -> None:
    def tree(directory: Path) -> dict[str, tuple[int, int]]:
        return {
            str(path.relative_to(directory)): (path.stat().st_size, path.stat().st_mtime_ns)
            for path in sorted(directory.rglob("*"))
            if path.is_file()
        }

    before = tree(generator.FIXTURES)

    def refuse(*_arguments, **_keywords):
        raise AssertionError("a builder wrote to disk")

    real_open = builtins.open

    def guarded_open(file, mode="r", *arguments, **keywords):
        if any(flag in mode for flag in "wax+"):
            raise AssertionError(f"a builder opened {file!r} for writing")
        return real_open(file, mode, *arguments, **keywords)

    with monkeypatch.context() as scoped:
        scoped.setattr(Path, "write_text", refuse)
        scoped.setattr(Path, "write_bytes", refuse)
        scoped.setattr(Path, "mkdir", refuse)
        scoped.setattr(Path, "unlink", refuse)
        scoped.setattr(builtins, "open", guarded_open)

        generator.compiler_rows()
        _needs_firmware(generator.verdict_rows)
        _needs_firmware(generator.program_rows)

    assert tree(generator.FIXTURES) == before
