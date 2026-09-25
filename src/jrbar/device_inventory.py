"""Bounded physical-device metadata inventory and a latest-wins cache."""

from __future__ import annotations

import os
import plistlib
import stat
import subprocess
import threading
from collections.abc import Callable
from dataclasses import replace as dataclass_replace
from pathlib import Path

from .device_identity import (
    DeviceHardwareFacts,
    DeviceKind,
    StableDeviceIdentity,
    derive_device_identity,
    device_kind,
)

DISKUTIL = Path("/usr/sbin/diskutil")
DISKUTIL_TIMEOUT_SECONDS = 1.5
DISKUTIL_MAX_BYTES = 1024 * 1024
MAX_MOUNT_CANDIDATES = 16


def _clean_string(value: object) -> str | None:
    if not isinstance(value, str):
        return None
    cleaned = value.strip()
    if not cleaned or len(cleaned) > 256 or "\x00" in cleaned:
        return None
    return cleaned


def diskutil_facts(
    mount_path: Path,
    *,
    runner=subprocess.run,
) -> DeviceHardwareFacts | None:
    mount = Path(mount_path)
    try:
        completed = runner(
            [str(DISKUTIL), "info", "-plist", str(mount)],
            capture_output=True,
            timeout=DISKUTIL_TIMEOUT_SECONDS,
            check=False,
        )
    except (OSError, subprocess.SubprocessError):
        return None
    if completed.returncode != 0:
        return None
    payload = completed.stdout
    if isinstance(payload, str):
        payload = payload.encode("utf-8")
    if not isinstance(payload, bytes) or not payload or len(payload) > DISKUTIL_MAX_BYTES:
        return None
    try:
        document = plistlib.loads(payload)
    except (plistlib.InvalidFileException, ValueError):
        return None
    if not isinstance(document, dict):
        return None

    reported_mount = _clean_string(document.get("MountPoint")) or str(mount)
    product_name = (
        _clean_string(document.get("VolumeName"))
        or _clean_string(document.get("MediaName"))
        or mount.name
    )
    return DeviceHardwareFacts(
        mount_path=reported_mount,
        product_name=product_name,
        volume_uuid=(
            _clean_string(document.get("VolumeUUID"))
            or _clean_string(document.get("APFSVolumeUUID"))
        ),
        disk_identifier=_clean_string(document.get("DeviceIdentifier")),
        serial_number=(
            _clean_string(document.get("DiskUUID"))
            or _clean_string(document.get("MediaUUID"))
        ),
        connected=True,
    )


STATUS_FILE_NAME = "STATUS.TXT"
STATUS_MAX_BYTES = 16 * 1024

# Firmware serial prefixes that name the product family outright. The
# volume label is just "SIDEPULSE" on every device, so without this a Pro
# strip classifies as a Dot (device_kind's bare-name fallback) and its
# stable key -- and therefore its remembered brightness/calibration --
# lands under the wrong identity.
_SERIAL_PREFIX_PRODUCT = {
    "SPP": "SidePulse Pro",
    "SPD": "SidePulse Dot",
}


def hardware_status_serial(mount_path: Path) -> str | None:
    """The device's own serial line from STATUS.TXT, or None.

    STATUS.TXT is written by the firmware itself, so it is the one
    self-identification that survives volume renames and reformats.
    Bounded read; any I/O or parse trouble means "unknown", never an
    exception into the inventory sweep.
    """
    mount_fd: int | None = None
    status_fd: int | None = None
    try:
        mount_flags = os.O_RDONLY | getattr(os, "O_DIRECTORY", 0) | os.O_NOFOLLOW
        mount_fd = os.open(Path(mount_path), mount_flags)
        status_fd = os.open(
            STATUS_FILE_NAME,
            os.O_RDONLY | os.O_NOFOLLOW | os.O_NONBLOCK,
            dir_fd=mount_fd,
        )
        if not stat.S_ISREG(os.fstat(status_fd).st_mode):
            return None
        payload = os.read(status_fd, STATUS_MAX_BYTES + 1)
    except OSError:
        return None
    finally:
        if status_fd is not None:
            os.close(status_fd)
        if mount_fd is not None:
            os.close(mount_fd)
    if len(payload) > STATUS_MAX_BYTES:
        return None
    for raw_line in payload.decode("utf-8", errors="replace").splitlines():
        parts = raw_line.split()
        if len(parts) == 2 and parts[0] == "serial":
            return _clean_string(parts[1])
    return None


def refine_facts_with_hardware_status(
    facts: DeviceHardwareFacts,
    mount_path: Path,
) -> DeviceHardwareFacts:
    """Fold the firmware's STATUS.TXT self-identification into diskutil facts.

    The serial (e.g. SPP-000067) becomes the strongest identity evidence,
    and its prefix corrects the product name so device_kind classifies a
    Pro as a Pro even though the volume is labeled just "SIDEPULSE"."""
    serial = hardware_status_serial(mount_path)
    if serial is None:
        return facts
    product = _SERIAL_PREFIX_PRODUCT.get(serial[:3].upper())
    return dataclass_replace(
        facts,
        serial_number=serial,
        product_name=product or facts.product_name,
    )


def mounted_device_kind(mount_path: Path, product_name: str | None = None) -> DeviceKind:
    """Classify one mounted volume's role for diagnostics.

    Reads the firmware serial first (a Pro labeled just "SIDEPULSE" would
    otherwise classify as a Dot by the bare-name rule), then falls back
    to the mount-name heuristic. ``product_name`` lets a caller supply a
    name it already knows instead of re-deriving it from the path.
    """
    serial = hardware_status_serial(mount_path)
    product = _SERIAL_PREFIX_PRODUCT.get(serial[:3].upper()) if serial else None
    return device_kind(product or product_name or mount_path.name, str(mount_path))


def _jrbar_candidate(path: Path) -> bool:
    normalized = "".join(character for character in path.name.lower() if character.isalnum())
    # "PulseDot": the volume label old Dot firmware ships with.
    return normalized.startswith("sidepulse") or normalized.startswith("pulsedot")


def inventory_mounts(
    mount_root: Path = Path("/Volumes"),
    *,
    runner=subprocess.run,
    carried: dict[str, tuple[tuple[int, int], StableDeviceIdentity]] | None = None,
) -> tuple[StableDeviceIdentity, ...]:
    """Every mounted SidePulse volume's stable identity.

    ``carried`` is the caller's memory across rounds: a mount whose
    ``diskutil`` probe fails (it does under load) keeps the identity its
    last good probe gave it while the mount itself -- its device and inode
    -- is unchanged. Without it the device fell back to its path id for a
    round, which read as a disconnect and a reconnect and rewrote both
    strips about six times an hour. An unmounted or remounted volume loses
    what was carried."""
    root = Path(mount_root)
    try:
        candidates = sorted(
            (
                path
                for path in root.iterdir()
                if path.is_dir() and not path.is_symlink() and _jrbar_candidate(path)
            ),
            key=lambda path: path.name.casefold(),
        )[:MAX_MOUNT_CANDIDATES]
    except OSError:
        return ()

    identities: dict[str, StableDeviceIdentity] = {}
    present: set[str] = set()
    for candidate in candidates:
        try:
            before = candidate.lstat()
        except OSError:
            continue
        mount = (before.st_dev, before.st_ino)
        present.add(str(candidate))
        facts = diskutil_facts(candidate, runner=runner)
        if facts is None:
            held = carried.get(str(candidate)) if carried is not None else None
            if held is not None and held[0] == mount:
                identities[held[1].key] = held[1]
            continue
        try:
            after = candidate.lstat()
        except OSError:
            continue
        if mount != (after.st_dev, after.st_ino):
            continue
        facts = refine_facts_with_hardware_status(facts, candidate)
        identity = derive_device_identity(facts, trusted_mount_root=root)
        if identity is not None:
            identities[identity.key] = identity
            if carried is not None:
                carried[str(candidate)] = (mount, identity)
    if carried is not None:
        for gone in [path for path in carried if path not in present]:
            del carried[gone]
    return tuple(sorted(identities.values(), key=lambda row: (row.label, row.key)))


class DeviceIdentityCache:
    """Latest-wins worker whose reads are always an in-memory snapshot."""

    def __init__(
        self,
        *,
        inventory: Callable[[], tuple[StableDeviceIdentity, ...]] | None = None,
    ) -> None:
        # What each mount's last good probe said, carried across a failed
        # probe of the same mount (inventory_mounts). Only the worker reads
        # and writes it, one round at a time.
        self._carried: dict[str, tuple[tuple[int, int], StableDeviceIdentity]] = {}
        self._inventory = inventory or (lambda: inventory_mounts(carried=self._carried))
        self._condition = threading.Condition()
        self._snapshot: tuple[StableDeviceIdentity, ...] = ()
        self._thread: threading.Thread | None = None
        self._pending = False
        self._running = False
        self._closed = False

    def request_refresh(self) -> bool:
        with self._condition:
            if self._closed:
                return False
            if self._running:
                self._pending = True
                return False
            self._running = True
            self._pending = False
            self._thread = threading.Thread(
                target=self._run,
                name="jrbar-device-inventory",
                daemon=True,
            )
            self._thread.start()
            return True

    def _run(self) -> None:
        while True:
            try:
                rows = self._inventory()
            except Exception:
                rows = self.snapshot()
            if type(rows) is not tuple or not all(
                type(row) is StableDeviceIdentity for row in rows
            ):
                rows = ()
            with self._condition:
                if not self._closed:
                    self._snapshot = tuple(rows)
                if self._pending and not self._closed:
                    self._pending = False
                    continue
                self._running = False
                self._thread = None
                self._condition.notify_all()
                return

    def snapshot(self) -> tuple[StableDeviceIdentity, ...]:
        with self._condition:
            return self._snapshot

    def identity_for_mount(self, mount_path: Path) -> StableDeviceIdentity | None:
        target = str(Path(mount_path))
        with self._condition:
            return next(
                (row for row in self._snapshot if row.mount_path == target),
                None,
            )

    def wait(self, timeout: float) -> bool:
        with self._condition:
            return self._condition.wait_for(
                lambda: not self._running and not self._pending,
                timeout=max(0.0, float(timeout)),
            )

    def close(self) -> None:
        with self._condition:
            self._closed = True
            self._pending = False
            thread = self._thread
        if thread is not None and thread is not threading.current_thread():
            thread.join(timeout=2.0)
        with self._condition:
            self._running = False
            self._thread = None
            self._condition.notify_all()


__all__ = [
    "DeviceIdentityCache",
    "diskutil_facts",
    "inventory_mounts",
]
