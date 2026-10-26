"""While a firmware update runs, nothing else may write to the device.

The hold is the guarantee: the one door every LED write goes through, and the
keepalive, look at it first. It always ends, even if the update that took it
never comes back, because it carries a deadline.
"""

from __future__ import annotations

import errno
import threading
from pathlib import Path

import pytest

from jrbar import device_writer, firmware_hold
from jrbar.firmware_hold import DeviceHeldError
from jrbar.keep_awake import KeepAwakeController, touch_keepalive_file


@pytest.fixture(autouse=True)
def _no_leftover_holds():
    firmware_hold.clear_all()
    yield
    firmware_hold.clear_all()


class Clock:
    def __init__(self, now: float = 100.0) -> None:
        self.now = now

    def __call__(self) -> float:
        return self.now


def test_a_hold_covers_the_drive_and_every_file_on_it(tmp_path: Path) -> None:
    clock = Clock()
    firmware_hold.acquire(tmp_path / "SidePulse", "updating firmware", clock=clock)
    assert firmware_hold.held_reason(tmp_path / "SidePulse", clock=clock) == "updating firmware"
    assert firmware_hold.held_reason(tmp_path / "SidePulse" / "LEDS.LED", clock=clock) is not None
    assert firmware_hold.held_reason(tmp_path / "SidePulseOther", clock=clock) is None
    assert firmware_hold.held_reason(tmp_path / "PulseDot" / "LEDS.LED", clock=clock) is None
    assert firmware_hold.any_held(clock=clock)


def test_a_hold_also_covers_the_drive_returning_under_a_collision_name(tmp_path: Path) -> None:
    clock = Clock()
    firmware_hold.acquire(tmp_path / "SidePulse", "updating firmware", clock=clock)
    assert firmware_hold.held_reason(tmp_path / "SidePulse 1", clock=clock) is not None
    assert firmware_hold.held_reason(tmp_path / "SidePulse 12" / "LEDS.LED", clock=clock) is not None
    assert firmware_hold.held_reason(tmp_path / "SidePulse backup", clock=clock) is None
    assert firmware_hold.held_reason(tmp_path / "Other 1", clock=clock) is None


def test_a_hold_ends_at_its_deadline_even_if_nobody_releases_it(tmp_path: Path) -> None:
    clock = Clock()
    firmware_hold.acquire(tmp_path / "SidePulse", "updating firmware", clock=clock, seconds=60)
    clock.now += 59.0
    assert firmware_hold.held_reason(tmp_path / "SidePulse", clock=clock) is not None
    clock.now += 2.0
    assert firmware_hold.held_reason(tmp_path / "SidePulse", clock=clock) is None
    assert not firmware_hold.any_held(clock=clock)


def test_no_hold_can_be_asked_to_outlast_the_maximum(tmp_path: Path) -> None:
    clock = Clock()
    hold = firmware_hold.acquire(tmp_path, "x", clock=clock, seconds=10 * 86400)
    assert hold.expires_at - clock.now == firmware_hold.MAX_HOLD_SECONDS


def test_the_context_manager_releases_on_an_exception(tmp_path: Path) -> None:
    with pytest.raises(RuntimeError), firmware_hold.hold([tmp_path / "a", tmp_path / "b"], "updating firmware"):
        assert firmware_hold.held_reason(tmp_path / "a") and firmware_hold.held_reason(tmp_path / "b")
        raise RuntimeError("boom")
    assert not firmware_hold.any_held()


def test_a_held_led_write_is_refused_before_it_touches_the_drive(tmp_path: Path) -> None:
    root = tmp_path / "SidePulse"
    root.mkdir()
    (root / "STATUS.TXT").write_text("serial SPP-000001\n")
    (root / "LEDS.LED").write_text("off\n")
    before = {item.name: item.read_bytes() for item in root.iterdir()}
    firmware_hold.acquire(root, "updating firmware")
    with pytest.raises(DeviceHeldError) as caught:
        device_writer._write_device_file("#ff0000", device_path=root, file_name="LEDS.LED")
    assert isinstance(caught.value, OSError)  # every caller already copes with an absent device
    assert "updating firmware" in str(caught.value)
    with pytest.raises(OSError):
        device_writer._write_device_file(
            "#ff0000", device_path=root, file_name="LEDS.LED", preserve_existing_inode=True
        )
    assert {item.name: item.read_bytes() for item in root.iterdir()} == before
    firmware_hold.release(root)
    device_writer._write_device_file("#00ff00", device_path=root, file_name="LEDS.LED")
    assert (root / "LEDS.LED").read_text() == "#00ff00"


def test_a_dry_run_is_not_a_write_and_is_not_held(tmp_path: Path) -> None:
    firmware_hold.acquire(tmp_path, "updating firmware")
    target = device_writer._write_device_file("off", device_path=tmp_path, dry_run=True)
    assert target == tmp_path / "LEDS.LED"


def test_the_keepalive_waits_for_the_update(tmp_path: Path) -> None:
    root = tmp_path / "SidePulse"
    root.mkdir()
    firmware_hold.acquire(root, "updating firmware")
    with pytest.raises(DeviceHeldError):
        touch_keepalive_file(root / "keepalive")
    assert not (root / "keepalive").exists()
    touched: list[Path] = []
    controller = KeepAwakeController(status_reader=touched.append, status_read_async=False)
    assert controller.poke_status_file(root / "LEDS.LED", now=500.0) is None
    assert touched == []
    firmware_hold.release(root)
    assert controller.poke_status_file(root / "LEDS.LED", now=501.0) == root / "keepalive"
    assert touched == [root / "keepalive"]


def test_the_hardware_writer_pauses_while_anything_is_held(tmp_path: Path) -> None:
    from jrbar.daemon_controller import StatusBarController

    class Inputs:
        app_terminating = False

    class Fake:
        _runtime_started = True
        leds_enabled = True

        def _physical_device_demand(self):
            return True

    should_run = StatusBarController._hardware_write_should_run
    assert should_run(Fake(), Inputs()) is True
    firmware_hold.acquire(tmp_path, "updating firmware")
    assert should_run(Fake(), Inputs()) is False
    firmware_hold.release(tmp_path)
    assert should_run(Fake(), Inputs()) is True


def test_a_full_root_directory_prunes_the_sidecars_on_the_way_to_the_fallback(tmp_path: Path) -> None:
    """The writer's ENOSPC path clears macOS sidecars (and only those)."""
    root = tmp_path / "SidePulse"
    root.mkdir()
    (root / "LEDS.LED").write_text("off\n")
    (root / "._LEDS.LED").write_bytes(bytes.fromhex("00051607") + bytes(100))
    (root / "._notes").write_text("a person wrote this")
    (root / "STATUS.TXT").write_text("serial SPP-000001\n")

    real_replace = device_writer.os.replace

    def full(*args, **kwargs):
        raise OSError(errno.ENOSPC, "No space left on device")

    device_writer.os.replace = full  # type: ignore[assignment]
    try:
        device_writer._write_device_file("#102030", device_path=root, file_name="LEDS.LED")
    finally:
        device_writer.os.replace = real_replace  # type: ignore[assignment]
    assert (root / "LEDS.LED").read_text() == "#102030"
    assert not (root / "._LEDS.LED").exists()
    assert (root / "._notes").exists()
    assert (root / "STATUS.TXT").exists()


def test_holds_from_two_threads_do_not_interfere(tmp_path: Path) -> None:
    done = threading.Event()
    seen: list[bool] = []

    def worker() -> None:
        with firmware_hold.hold([tmp_path / "a"], "updating firmware"):
            seen.append(firmware_hold.held_reason(tmp_path / "a") is not None)
        done.set()

    thread = threading.Thread(target=worker)
    thread.start()
    assert done.wait(5.0)
    thread.join(5.0)
    assert seen == [True] and not firmware_hold.any_held()
