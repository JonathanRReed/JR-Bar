"""Preparing a SidePulse drive for a firmware file, and copying it.

The drives are tiny emulated FAT volumes. A Pro's is about 170 KB with a
fixed root directory of 16 entries. A file name that is not a plain 8.3 name
uses an extra entry for every 13 characters, and macOS adds a hidden
``._NAME`` sidecar (an AppleDouble file) beside any file it stamps with its
``com.apple.provenance`` mark: a name like ``._LEDS.LED`` uses two entries.
A plain copy of the 137 KB firmware file onto a Pro failed with "No space
left on device" although 92% of the data area was free, because the root
directory had run out of entries, not the disk of room.

So before it copies, the updater counts the entries, removes the sidecars
macOS left behind (and only those, after reading each one), and refuses with
the names that are in the way if there is still no room. It never removes a
device file: ``LEDS.LED``, ``INIT.LED``, ``STATUS.TXT``, ``keepalive``,
``setup.html``, ``index.html``, ``FIRMWARE.BIN`` and ``.fseventsd`` are
never touched.

All file access goes through ``DriveOps`` so the tests can stand a fake
volume in its place, one that runs out of root-directory entries like the
real one.
"""

from __future__ import annotations

import errno
import math
import os
import stat
from collections.abc import Iterable
from dataclasses import dataclass, field
from pathlib import Path
from typing import Final

from .device_firmware import IMAGE_FILE_NAME

#: A FAT directory entry is 32 bytes.
ENTRY_BYTES: Final = 32
#: The volume label takes one entry that a listing does not show.
LABEL_ENTRIES: Final = 1
#: AppleDouble files start with this magic number.
APPLEDOUBLE_MAGIC: Final = bytes.fromhex("00051607")
#: A sidecar is a few KB; a "sidecar" larger than this is not one.
SIDECAR_MAX_BYTES: Final = 256 * 1024
_FILLER_BYTES: Final = (0x00, 0x20, 0xFF)
_WRITE_CHUNK: Final = 4096
#: Names JR-Bar never removes from a device drive.
PROTECTED_NAMES: Final = frozenset(
    name.lower()
    for name in (
        "INIT.LED",
        "LEDS.LED",
        "STATUS.TXT",
        "keepalive",
        "setup.html",
        "index.html",
        "FIRMWARE.BIN",
        ".fseventsd",
    )
)


class DriveError(Exception):
    """The drive cannot take the update. ``code`` is a short word; the
    message says what to do. The device is still on its old firmware."""

    def __init__(self, code: str, message: str) -> None:
        super().__init__(message)
        self.code = code
        self.message = message


@dataclass(frozen=True, slots=True)
class RootEntry:
    name: str
    kind: str  # "file", "dir", "link" or "other"
    size: int


def entries_for_name(name: str) -> int:
    """How many 32-byte root entries a name takes: one, plus one per 13
    characters of long name when it is not a plain 8.3 name.

    A name is plain when it has an 8-character stem and 3-character extension
    at most, no leading dot, and is all one case in each part (FAT keeps the
    case of such a name in flag bits). Everything else (``keepalive``,
    ``setup.html``, ``._LEDS.LED``, ``.claude``) takes a long-name entry or two.
    """
    stem, dot, extension = name.partition(".")
    plain = (
        bool(stem)
        and len(stem) <= 8
        and len(extension) <= 3
        and "." not in extension
        and (stem.isupper() or stem.islower() or not stem.isalpha())
        and (extension.isupper() or extension.islower() or not extension.isalpha())
        and not name.startswith(".")
        and all(char.isalnum() or char in "_-~$!#%&'()@^`{}" for char in stem + extension)
    )
    if plain:
        return 1
    return 1 + math.ceil(len(name) / 13)


@dataclass(frozen=True, slots=True)
class SidecarVerdict:
    """What reading a ``._`` file said."""

    name: str
    removable: bool
    why: str


def judge_sidecar(entry: RootEntry, content: bytes | None) -> SidecarVerdict:
    """Whether a ``._`` file is a macOS sidecar that is safe to remove.

    Safe: a regular file that is empty, starts with the AppleDouble magic, or
    is nothing but one filler byte (the blanked remains a Pro leaves where
    the firmware file it had applied used to be). Anything else is somebody's
    data and stays."""
    name = entry.name
    if not name.startswith("._") or len(name) <= 2:
        return SidecarVerdict(name, False, "not a macOS sidecar name")
    if entry.kind != "file":
        return SidecarVerdict(name, False, "not a plain file")
    if entry.size > SIDECAR_MAX_BYTES:
        return SidecarVerdict(name, False, "too large to be a sidecar")
    if entry.size == 0:
        return SidecarVerdict(name, True, "empty")
    if content is None:
        return SidecarVerdict(name, False, "could not be read")
    if content.startswith(APPLEDOUBLE_MAGIC):
        return SidecarVerdict(name, True, "AppleDouble sidecar")
    if len(content) == entry.size and len(set(content)) == 1 and content[0] in _FILLER_BYTES:
        return SidecarVerdict(name, True, "blanked file")
    return SidecarVerdict(name, False, "holds other content")


# --- file access ------------------------------------------------------------------


class DriveOps:
    """The real file operations. Tests subclass this to fake a volume."""

    def scan(self, root: Path) -> list[RootEntry]:
        entries: list[RootEntry] = []
        with os.scandir(root) as iterator:
            for item in iterator:
                try:
                    info = item.stat(follow_symlinks=False)
                except OSError:
                    continue
                if stat.S_ISLNK(info.st_mode):
                    kind = "link"
                elif stat.S_ISDIR(info.st_mode):
                    kind = "dir"
                elif stat.S_ISREG(info.st_mode):
                    kind = "file"
                else:
                    kind = "other"
                entries.append(RootEntry(item.name, kind, int(info.st_size)))
        return sorted(entries, key=lambda entry: entry.name.lower())

    def root_capacity(self, root: Path) -> int | None:
        """How many entries the root directory holds, if the volume says."""
        try:
            size = os.stat(root).st_size
        except OSError:
            return None
        count = size // ENTRY_BYTES
        return count if 8 <= count <= 65536 else None

    def free_bytes(self, root: Path) -> int | None:
        try:
            info = os.statvfs(root)
        except OSError:
            return None
        return int(info.f_bavail * info.f_frsize)

    def read_file(self, root: Path, name: str, limit: int) -> bytes:
        descriptor = os.open(root / name, os.O_RDONLY | getattr(os, "O_NOFOLLOW", 0))
        try:
            return os.read(descriptor, limit)
        finally:
            os.close(descriptor)

    def unlink(self, root: Path, name: str) -> None:
        info = os.lstat(root / name)
        if not stat.S_ISREG(info.st_mode):
            raise OSError(errno.EPERM, "not a plain file")
        os.unlink(root / name)

    def write_file(self, root: Path, name: str, data: bytes, *, replace: bool) -> None:
        """Stream ``data`` to ``root/name`` the way ``cp`` does: no extended
        attributes, chunked writes, flushed to the device before returning."""
        flags = os.O_WRONLY | getattr(os, "O_NOFOLLOW", 0) | getattr(os, "O_CLOEXEC", 0)
        flags |= os.O_TRUNC if replace else (os.O_CREAT | os.O_EXCL)
        descriptor = os.open(root / name, flags, 0o644)
        try:
            view = memoryview(data)
            while view:
                written = os.write(descriptor, view[:_WRITE_CHUNK])
                if written <= 0:
                    raise OSError(errno.EIO, "the device accepted no bytes")
                view = view[written:]
            os.fsync(descriptor)
        finally:
            os.close(descriptor)

    def sync(self, root: Path) -> None:
        """Push everything written to the device."""
        os.sync()
        try:
            descriptor = os.open(root, os.O_RDONLY | getattr(os, "O_DIRECTORY", 0))
        except OSError:
            return
        try:
            os.fsync(descriptor)
        except OSError:
            pass
        finally:
            os.close(descriptor)


# --- inspecting and preparing -------------------------------------------------------


@dataclass(frozen=True, slots=True)
class DrivePlan:
    """The state of a drive's root directory and what an update needs of it."""

    capacity: int | None
    used: int
    needed: int
    free_bytes: int | None
    image_present: bool
    removed: tuple[str, ...] = ()
    #: ``(name, why)`` of every ``._`` file left alone.
    kept_sidecars: tuple[tuple[str, str], ...] = ()
    #: Names that use entries and are not JR-Bar's to remove.
    others: tuple[str, ...] = ()

    @property
    def has_room(self) -> bool:
        return self.capacity is None or self.used + self.needed <= self.capacity


def used_entries(entries: Iterable[RootEntry]) -> int:
    return LABEL_ENTRIES + sum(entries_for_name(entry.name) for entry in entries)


def entries_needed_for_image(entries: Iterable[RootEntry]) -> int:
    """New root entries the firmware file needs: its own, unless it is already
    there to be replaced.

    macOS may also stamp a ``._FIRMWARE.BIN`` sidecar beside it. That is best
    effort: on a real Pro-sized volume with no room for it the plain copy
    still lands without it (only a copy that sets extended attributes, like
    ``cp`` without ``-X``, fails for want of the sidecar's entries), so it is
    not counted here; it is cleaned up afterwards if it appears."""
    names = {entry.name for entry in entries}
    return 0 if IMAGE_FILE_NAME in names else entries_for_name(IMAGE_FILE_NAME)


def inspect_root(ops: DriveOps, root: Path, image_size: int) -> DrivePlan:
    entries = ops.scan(root)
    sidecars = [entry for entry in entries if entry.name.startswith("._")]
    others = tuple(
        entry.name
        for entry in entries
        if entry not in sidecars and entry.name.lower() not in PROTECTED_NAMES
    )
    return DrivePlan(
        capacity=ops.root_capacity(root),
        used=used_entries(entries),
        needed=entries_needed_for_image(entries),
        free_bytes=ops.free_bytes(root),
        image_present=any(entry.name == IMAGE_FILE_NAME for entry in entries),
        others=others,
    )


def prune_sidecars(ops: DriveOps, root: Path) -> tuple[list[str], list[tuple[str, str]]]:
    """Remove the macOS sidecars in the root; ``(removed, kept with why)``.

    Each is read first, and only an empty file, an AppleDouble file or a
    blanked file goes. Nothing that is not named ``._something`` is touched.
    A sidecar that cannot be removed is reported, not fatal."""
    removed: list[str] = []
    kept: list[tuple[str, str]] = []
    for entry in ops.scan(root):
        if not entry.name.startswith("._"):
            continue
        content: bytes | None = None
        if 0 < entry.size <= SIDECAR_MAX_BYTES and entry.kind == "file":
            try:
                content = ops.read_file(root, entry.name, entry.size)
            except OSError:
                content = None
        verdict = judge_sidecar(entry, content)
        if not verdict.removable:
            kept.append((entry.name, verdict.why))
            continue
        try:
            ops.unlink(root, entry.name)
        except OSError as error:
            kept.append((entry.name, f"could not be removed ({error.strerror or error})"))
            continue
        removed.append(entry.name)
    return removed, kept


def prepare_drive(ops: DriveOps, root: Path, image_size: int) -> DrivePlan:
    """Clear the way for the firmware file, or say why that cannot be done.

    Raises ``DriveError`` (nothing has been written to the firmware path)."""
    removed, kept = prune_sidecars(ops, root)
    after = inspect_root(ops, root, image_size)
    plan = DrivePlan(
        capacity=after.capacity,
        used=after.used,
        needed=after.needed,
        free_bytes=after.free_bytes,
        image_present=after.image_present,
        removed=tuple(removed),
        kept_sidecars=tuple(kept),
        others=after.others,
    )
    if plan.free_bytes is not None and plan.free_bytes < image_size and not plan.image_present:
        raise DriveError(
            "no_space",
            f"The device's drive has {plan.free_bytes // 1024} KB free and the update needs "
            f"{image_size // 1024} KB. Nothing was written.",
        )
    if not plan.has_room:
        names = [*plan.others, *(name for name, _why in plan.kept_sidecars)]
        listed = ", ".join(names) if names else "other files"
        raise DriveError(
            "drive_full",
            "The device's drive has no free directory entry for the update, and the only files "
            f"taking them are not JR-Bar's to remove ({listed}). Remove the ones you do not need "
            "in Finder, eject and reconnect the device, then try again. Nothing was written.",
        )
    return plan


def copy_image(ops: DriveOps, root: Path, image: bytes, *, replace: bool) -> None:
    """Write ``FIRMWARE.BIN`` to the top of the drive and push it to the device.

    A file this call created and could not finish is removed again, so the
    drive is never left holding half an image."""
    created = not replace
    try:
        ops.write_file(root, IMAGE_FILE_NAME, image, replace=replace)
        ops.sync(root)
    except OSError as error:
        if created:
            try:
                ops.unlink(root, IMAGE_FILE_NAME)
            except OSError:
                pass
        if error.errno == errno.ENOSPC:
            raise DriveError(
                "no_room",
                "The drive ran out of room while the file was being copied (its root directory is "
                "full). Nothing was applied; the device is still on its old firmware.",
            ) from error
        raise DriveError(
            "copy_failed",
            f"The file could not be copied to the device ({error.strerror or error}). "
            "The device is still on its old firmware. Reconnect it and try again.",
        ) from error


@dataclass(slots=True)
class CleanupReport:
    removed: list[str] = field(default_factory=list)
    kept: list[tuple[str, str]] = field(default_factory=list)
    error: str | None = None


def cleanup_after_copy(ops: DriveOps, root: Path) -> CleanupReport:
    """Remove the ``._FIRMWARE.BIN`` sidecar macOS made (and any other),
    once the device has applied the file. Never raises."""
    report = CleanupReport()
    try:
        report.removed, report.kept = prune_sidecars(ops, root)
    except OSError as error:
        report.error = error.strerror or str(error)
    return report
