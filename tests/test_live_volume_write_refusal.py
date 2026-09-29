"""The LED writer refuses a real ``/Volumes`` target while a test is running.

``tests/conftest.py`` guards the ``Path`` writes and the late-bound
``device_writer.write_led_program`` attribute. Callers that bound the
function at import time (the status, battery and CLI writers) keep the
original, and the original talks to the device with fd-level ``os.open``,
``os.write`` and ``os.fsync`` that no ``Path`` patch sees. So the refusal
lives at the one place every device write passes through,
``_device_writer_legacy.write_led_program``.

Every case that could reach a device runs with ``os.open`` replaced by a
function that fails the test, so a regression can never write a mounted
strip. All volume names here are synthetic.
"""

from __future__ import annotations

import argparse
import os
from pathlib import Path
from unittest.mock import patch

import pytest

from jrbar import _battery_legacy, _device_writer_legacy, _led_status_legacy, cli
from jrbar import device_writer, write_health
from jrbar.firmware_validation import (
    FirmwareValidationUnavailableError,
    require_firmware_program,
)

PROGRAM_A = "1:#00FF00 1s"
TWO_LED_PROGRAM = "0:#00FF00 1:#FF0000 1s"
PROBE_ROOT = "/Volumes/JRBarRefusalProbe"
DOT_ROOT = "/Volumes/SidePulseDot"


@pytest.fixture
def no_device_reached():
    """Fail the test, not the hardware, if any fd-level open gets through."""
    with patch(
        "jrbar.device_writer.os.open",
        side_effect=AssertionError("reached the device"),
    ):
        yield


# Every case that could reach a device runs under the guard above; the two
# that write a real temporary device must not, so it is opt-in per test.
guarded = pytest.mark.usefixtures("no_device_reached")


@pytest.fixture(autouse=True)
def _clean_health():
    write_health.reset()
    yield
    write_health.reset()


def _skip_without_firmware_parser() -> None:
    try:
        require_firmware_program(TWO_LED_PROGRAM, led_count=2)
    except FirmwareValidationUnavailableError as error:  # pragma: no cover - macOS only
        pytest.skip(f"firmware parser unavailable: {error}")


@guarded
@pytest.mark.parametrize("preserve_existing_inode", (False, True))
@pytest.mark.parametrize(
    "device_path",
    (
        PROBE_ROOT,
        f"{PROBE_ROOT}/LEDS.LED",
        f"{PROBE_ROOT}/INIT.LED",
    ),
)
def test_the_raw_writer_refuses_a_live_volume_under_test(
    device_path: str,
    preserve_existing_inode: bool,
) -> None:
    with pytest.raises(OSError, match="live device write under test"):
        device_writer._ORIGINAL_WRITE_LED_PROGRAM(
            PROGRAM_A,
            device_path=Path(device_path),
            preserve_existing_inode=preserve_existing_inode,
        )


@guarded
def test_a_refusal_is_an_os_error_not_a_device_write_error() -> None:
    """Callers already treat OSError like an unmounted volume; a
    DeviceWriteError would feed the device card's refusal counter."""
    with pytest.raises(OSError) as raised:
        device_writer._ORIGINAL_WRITE_LED_PROGRAM(PROGRAM_A, device_path=Path(PROBE_ROOT))
    assert not isinstance(raised.value, device_writer.DeviceWriteError)


@guarded
@pytest.mark.parametrize(
    "writer",
    (
        _led_status_legacy.write_led_program,
        _battery_legacy.write_led_program,
        cli.write_led_program,
    ),
    ids=("status", "battery", "cli"),
)
def test_the_import_bound_callers_are_refused_too(writer) -> None:
    _skip_without_firmware_parser()
    with pytest.raises(OSError, match="live device write under test"):
        writer(TWO_LED_PROGRAM, device_path=Path(DOT_ROOT))


@guarded
def test_the_cli_write_command_exits_one_like_an_unmounted_volume(capsys) -> None:
    _skip_without_firmware_parser()
    arguments = argparse.Namespace(
        text=TWO_LED_PROGRAM,
        device=Path(DOT_ROOT),
        file_name="LEDS.LED",
        dry_run=False,
    )
    assert cli.cmd_jrbar_write(arguments) == 1
    assert "live device write under test" in capsys.readouterr().err


@guarded
def test_autodiscovery_lands_on_the_same_refusal(monkeypatch) -> None:
    _skip_without_firmware_parser()
    candidate = _device_writer_legacy.DeviceCandidate(
        Path(DOT_ROOT),
        Path(DOT_ROOT) / "LEDS.LED",
        "synthetic",
    )
    monkeypatch.setattr(
        "jrbar._device_writer_legacy.discover_devices",
        lambda **_keywords: [candidate],
    )
    with pytest.raises(OSError, match="live device write under test"):
        _led_status_legacy.write_led_program(TWO_LED_PROGRAM)


@guarded
def test_a_refusal_leaves_no_write_health_behind() -> None:
    with pytest.raises(OSError):
        device_writer._ORIGINAL_WRITE_LED_PROGRAM(PROGRAM_A, device_path=Path(PROBE_ROOT))
    assert not write_health.health_document(PROBE_ROOT)


@guarded
def test_a_dry_run_to_a_live_volume_still_answers() -> None:
    target = device_writer._ORIGINAL_WRITE_LED_PROGRAM(
        PROGRAM_A,
        device_path=Path(PROBE_ROOT),
        dry_run=True,
    )
    assert target == Path(PROBE_ROOT) / "LEDS.LED"


def test_a_temporary_device_still_writes_and_reads_back(tmp_path: Path) -> None:
    target = device_writer._ORIGINAL_WRITE_LED_PROGRAM(PROGRAM_A, device_path=tmp_path)
    assert target.read_text(encoding="utf-8") == PROGRAM_A


def test_a_sandbox_volume_root_device_still_writes() -> None:
    root = Path(os.environ["JRBAR_TEST_VOLUME_ROOT"]) / "JRBarRefusalProbe"
    root.mkdir(parents=True, exist_ok=True)
    target = device_writer._ORIGINAL_WRITE_LED_PROGRAM(PROGRAM_A, device_path=root)
    assert target.read_text(encoding="utf-8") == PROGRAM_A


@guarded
def test_the_conftest_guard_is_a_second_layer_and_has_a_canary() -> None:
    with pytest.raises(AssertionError, match="mounted hardware path"):
        device_writer.write_led_program(PROGRAM_A, device_path=Path(PROBE_ROOT))


def test_the_predicate_follows_the_test_sandbox_markers(monkeypatch) -> None:
    check = _device_writer_legacy._under_test_on_live_volume
    for name in ("PYTEST_CURRENT_TEST", "JRBAR_TESTING", "SIDEPULSE_TESTING"):
        monkeypatch.delenv(name, raising=False)
    assert check(Path("/Volumes/X")) is False

    monkeypatch.setenv("JRBAR_TESTING", "1")
    assert check(Path("/Volumes/X")) is True
    assert check(Path("/Volumes/../tmp/x")) is False
    assert check(Path("/tmp/../Volumes/X")) is True
    assert check(Path("/Volumes")) is False


def test_the_predicate_leaves_a_temporary_directory_alone(monkeypatch, tmp_path: Path) -> None:
    monkeypatch.setenv("JRBAR_TESTING", "1")
    assert _device_writer_legacy._under_test_on_live_volume(tmp_path) is False


def test_the_predicate_honours_the_legacy_marker_name(monkeypatch) -> None:
    for name in ("PYTEST_CURRENT_TEST", "JRBAR_TESTING"):
        monkeypatch.delenv(name, raising=False)
    monkeypatch.setenv("SIDEPULSE_TESTING", "1")
    assert _device_writer_legacy._under_test_on_live_volume(Path("/Volumes/X")) is True
