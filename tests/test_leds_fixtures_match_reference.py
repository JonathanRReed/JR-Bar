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

from jrbar._led_wasm_legacy import LedWasmUnavailableError

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
