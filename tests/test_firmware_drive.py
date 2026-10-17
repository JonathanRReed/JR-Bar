"""The SidePulse drive is a tiny FAT volume with a fixed root directory.

The hand update on 2026-10-07 failed with "No space left on device" while the
data area was 92% free, because the root directory had no free entry: macOS
sidecars (``._LEDS.LED``, ``._keepalive``, later ``._FIRMWARE.BIN``) and a
stray ``.claude`` each took two. These tests reproduce that on a fake volume
that runs out of entries, and show the cleanup fixes it without touching a
device file.
"""

from __future__ import annotations

import errno
from pathlib import Path

import pytest

from jrbar import firmware_drive as drive
from jrbar.firmware_drive import APPLEDOUBLE_MAGIC, DriveError, RootEntry, entries_for_name
from tests.firmware_fakes import FakeFat, make_image, populate_pro_drive

IMAGE = make_image("pro")


@pytest.mark.parametrize(
    ("name", "entries"),
    [
        ("LEDS.LED", 1),
        ("INIT.LED", 1),
        ("STATUS.TXT", 1),
        ("FIRMWARE.BIN", 1),
        ("keepalive", 2),  # nine characters: a long name
        ("setup.html", 2),  # a four-letter extension
        (".claude", 2),  # a leading dot is never a short name
        ("._LEDS.LED", 2),
        ("._keepalive", 2),
        ("._FIRMWARE.BIN", 3),  # fourteen characters: two long-name entries
        (".fseventsd", 2),
        ("a-very-long-name-that-needs-three-entries.txt", 5),
    ],
)
def test_root_entries_per_name(name: str, entries: int) -> None:
    assert entries_for_name(name) == entries


def test_the_hand_update_failure_is_reproduced(tmp_path: Path) -> None:
    root = tmp_path / "SidePulse"
    populate_pro_drive(root)
    (root / "._INIT.LED").write_bytes(APPLEDOUBLE_MAGIC + bytes(4092))
    ops = FakeFat(capacity_entries=16)
    # label 1 + STATUS, INIT, LEDS 3 + keepalive 2 + .claude 2 + .fseventsd 2
    # + three sidecars 6 = 16 of 16: not one entry left for FIRMWARE.BIN
    assert ops.used_entries(root) == 16
    with pytest.raises(OSError) as caught:
        ops.write_file(root, "FIRMWARE.BIN", IMAGE, replace=False)
    assert caught.value.errno == errno.ENOSPC
    assert not (root / "FIRMWARE.BIN").exists()
    assert ops.free_bytes(root) and ops.free_bytes(root) > len(IMAGE)  # the disk had room


def test_removing_the_sidecars_lets_the_copy_through(tmp_path: Path) -> None:
    root = tmp_path / "SidePulse"
    populate_pro_drive(root)
    (root / "._INIT.LED").write_bytes(APPLEDOUBLE_MAGIC + bytes(4092))
    ops = FakeFat(capacity_entries=16)
    plan = drive.prepare_drive(ops, root, len(IMAGE))
    assert sorted(plan.removed) == ["._INIT.LED", "._LEDS.LED", "._keepalive"]
    assert plan.has_room and plan.image_present is False
    drive.copy_image(ops, root, IMAGE, replace=plan.image_present)
    assert (root / "FIRMWARE.BIN").read_bytes() == IMAGE
    # macOS stamped a sidecar for the new file (there was room); it is removed afterwards.
    assert (root / "._FIRMWARE.BIN").exists()
    report = drive.cleanup_after_copy(ops, root)
    assert report.removed == ["._FIRMWARE.BIN"]
    assert not (root / "._FIRMWARE.BIN").exists()


def test_no_device_file_is_ever_removed(tmp_path: Path) -> None:
    root = tmp_path / "SidePulse"
    populate_pro_drive(root)
    (root / "setup.html").write_text("<html></html>")
    (root / "index.html").write_text("<html></html>")
    assert (root / ".fseventsd").is_dir()
    ops = FakeFat(capacity_entries=64)
    drive.prepare_drive(ops, root, len(IMAGE))
    drive.cleanup_after_copy(ops, root)
    survivors = {item.name for item in root.iterdir()}
    assert {"STATUS.TXT", "INIT.LED", "LEDS.LED", "keepalive", ".claude", "setup.html", "index.html", ".fseventsd"} <= survivors
    assert all(not name.startswith("._") for name in survivors)
    assert all(name.startswith("._") for name in ops.unlinked)


@pytest.mark.parametrize(
    ("content", "removable"),
    [
        (b"", True),
        (APPLEDOUBLE_MAGIC + bytes(100), True),
        (b" " * 600, True),
        (b"\x00" * 600, True),
        (b"\xff" * 600, True),
        (b"my notes about the update\n", False),
        (b" " * 599 + b"x", False),
    ],
)
def test_a_dotunderscore_file_goes_only_when_it_reads_as_a_sidecar(
    tmp_path: Path, content: bytes, removable: bool
) -> None:
    root = tmp_path / "PulseDot"
    root.mkdir()
    (root / "._thing").write_bytes(content)
    ops = FakeFat()
    removed, kept = drive.prune_sidecars(ops, root)
    assert (removed == ["._thing"]) is removable
    assert (kept == []) is removable
    assert (root / "._thing").exists() is (not removable)


def test_the_blanked_sidecar_a_pro_leaves_after_applying_is_recognised() -> None:
    entry = RootEntry("._FIRMWARE.BIN", "file", 136_992)
    verdict = drive.judge_sidecar(entry, b" " * 136_992)
    assert verdict.removable and verdict.why == "blanked file"


def test_a_directory_or_link_named_like_a_sidecar_is_left_alone(tmp_path: Path) -> None:
    root = tmp_path / "SidePulse"
    root.mkdir()
    (root / "._folder").mkdir()
    (root / "target").write_text("x")
    (root / "._link").symlink_to(root / "target")
    removed, kept = drive.prune_sidecars(FakeFat(), root)
    assert removed == []
    assert {name for name, _why in kept} == {"._folder", "._link"}
    assert (root / "._folder").is_dir() and (root / "._link").is_symlink()


def test_a_sidecar_too_large_to_be_one_is_left_alone() -> None:
    verdict = drive.judge_sidecar(RootEntry("._big", "file", drive.SIDECAR_MAX_BYTES + 1), b"")
    assert not verdict.removable


def test_when_other_files_fill_the_directory_it_says_which(tmp_path: Path) -> None:
    root = tmp_path / "SidePulse"
    populate_pro_drive(root, sidecars=False)
    for index in range(4):
        (root / f"notes-{index}-with-a-long-name.txt").write_text("keep me")
    ops = FakeFat(capacity_entries=16)
    with pytest.raises(DriveError) as caught:
        drive.prepare_drive(ops, root, len(IMAGE))
    assert caught.value.code == "drive_full"
    assert "notes-0-with-a-long-name.txt" in caught.value.message
    assert "Nothing was written" in caught.value.message
    assert not (root / "FIRMWARE.BIN").exists()
    assert all((root / f"notes-{index}-with-a-long-name.txt").exists() for index in range(4))


def test_a_drive_without_room_for_the_bytes_is_refused(tmp_path: Path) -> None:
    root = tmp_path / "SidePulse"
    populate_pro_drive(root, sidecars=False)
    with pytest.raises(DriveError) as caught:
        drive.prepare_drive(FakeFat(free_bytes=1000), root, len(IMAGE))
    assert caught.value.code == "no_space"


def test_an_existing_firmware_file_is_replaced_in_place(tmp_path: Path) -> None:
    root = tmp_path / "PulseDot"
    root.mkdir()
    (root / "STATUS.TXT").write_text("x")
    (root / "FIRMWARE.BIN").write_bytes(b"factory image " * 100)
    ops = FakeFat(capacity_entries=16, stamp_sidecars=False)
    plan = drive.prepare_drive(ops, root, len(IMAGE))
    assert plan.image_present
    drive.copy_image(ops, root, IMAGE, replace=True)
    assert (root / "FIRMWARE.BIN").read_bytes() == IMAGE
    assert ("sync", "PulseDot") in ops.log


def test_a_copy_that_runs_out_of_entries_removes_what_it_started(tmp_path: Path) -> None:
    root = tmp_path / "SidePulse"
    populate_pro_drive(root)  # sidecars still there: the copy cannot fit
    ops = FakeFat(capacity_entries=16)

    class Failing(FakeFat):
        def write_file(self, root, name, data, *, replace):
            (root / name).write_bytes(data[:100])  # a partial file appears
            raise OSError(errno.ENOSPC, "No space left on device")

    with pytest.raises(DriveError) as caught:
        drive.copy_image(Failing(), root, IMAGE, replace=False)
    assert caught.value.code == "no_room"
    assert not (root / "FIRMWARE.BIN").exists()
    assert ops.used_entries(root) == 14  # nothing else changed


def test_other_copy_errors_leave_the_device_on_its_old_firmware(tmp_path: Path) -> None:
    root = tmp_path / "SidePulse"
    root.mkdir()

    class Broken(FakeFat):
        def write_file(self, root, name, data, *, replace):
            raise OSError(errno.EIO, "Input/output error")

    with pytest.raises(DriveError) as caught:
        drive.copy_image(Broken(), root, IMAGE, replace=False)
    assert caught.value.code == "copy_failed"
    assert "old firmware" in caught.value.message


def test_the_real_ops_stream_a_file_without_extended_attributes(tmp_path: Path) -> None:
    root = tmp_path / "SidePulse"
    root.mkdir()
    ops = drive.DriveOps()
    ops.write_file(root, "FIRMWARE.BIN", IMAGE, replace=False)
    assert (root / "FIRMWARE.BIN").read_bytes() == IMAGE
    with pytest.raises(OSError):
        ops.write_file(root, "FIRMWARE.BIN", IMAGE, replace=False)  # exclusive create
    ops.write_file(root, "FIRMWARE.BIN", IMAGE[:100], replace=True)
    assert (root / "FIRMWARE.BIN").stat().st_size == 100
    ops.sync(root)
    (root / "real").mkdir()
    with pytest.raises(OSError):
        ops.unlink(root, "real")  # only plain files are removed
