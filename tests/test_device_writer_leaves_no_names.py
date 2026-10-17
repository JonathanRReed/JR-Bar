"""JR-Bar's own device writes must not use up root-directory entries.

The drives hold 16 root entries; macOS adds a ``._NAME`` sidecar beside any
file a process creates (it stamps ``com.apple.provenance``, which FAT stores as
a sidecar), so the only thing JR-Bar can control is to create no new names. A
live write rewrites the existing file in place; the atomic path renames its
scratch file over the target and removes it if anything fails.
"""

from __future__ import annotations

import errno
from pathlib import Path

import pytest

from jrbar import device_writer


def _names(root: Path) -> set[str]:
    return {item.name for item in root.iterdir()}


@pytest.fixture
def drive(tmp_path: Path) -> Path:
    root = tmp_path / "SidePulse"
    root.mkdir()
    (root / "STATUS.TXT").write_text("serial SPP-000001\n")
    (root / "LEDS.LED").write_text("off\n")
    return root


def test_a_live_write_rewrites_the_existing_file_and_adds_no_name(drive: Path) -> None:
    before = _names(drive)
    for color in ("#102030", "#203040", "#304050"):
        device_writer._write_device_file(
            color, device_path=drive, file_name="LEDS.LED", preserve_existing_inode=True
        )
    assert _names(drive) == before
    assert (drive / "LEDS.LED").read_text() == "#304050"


def test_the_atomic_path_leaves_only_the_target_behind(drive: Path) -> None:
    before = _names(drive)
    device_writer._write_device_file("#102030", device_path=drive, file_name="LEDS.LED")
    assert _names(drive) == before


def test_a_failed_atomic_write_removes_its_scratch_file(
    drive: Path, monkeypatch: pytest.MonkeyPatch
) -> None:
    before = _names(drive)

    def refuse(*args, **kwargs):
        raise OSError(errno.EIO, "Input/output error")

    monkeypatch.setattr(device_writer.os, "replace", refuse)
    with pytest.raises(OSError):
        device_writer._write_device_file("#102030", device_path=drive, file_name="LEDS.LED")
    assert _names(drive) == before
    assert (drive / "LEDS.LED").read_text() == "off\n"


def test_the_writer_never_sets_extended_attributes() -> None:
    source = Path(device_writer.__file__).read_text()
    for call in ("setxattr", "copyfile", "shutil.copy"):
        assert call not in source
