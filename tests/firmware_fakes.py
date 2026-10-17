"""Synthetic stand-ins for the firmware update tests.

A fake package (a small zip with the four expected files and a made-up image),
a fake release pinned to it, a fake FAT drive in a temporary folder that runs
out of root-directory entries like the real one, and a fake device whose
STATUS.TXT changes on an injected clock. Nothing here touches a real volume or
the network, and the data is invented.
"""

from __future__ import annotations

import errno
import hashlib
import io
import zipfile
from dataclasses import dataclass, field
from pathlib import Path

from jrbar.device_firmware import (
    PACKAGE_MEMBER_NAMES,
    FirmwareReading,
    FirmwareRelease,
    parse_status_fields,
    reading_from_fields,
)
from jrbar.firmware_drive import (
    APPLEDOUBLE_MAGIC,
    LABEL_ENTRIES,
    DriveOps,
    entries_for_name,
)

PRO_MAGIC = b"SDUP"
DOT_MAGIC = b"UF2\n"


def sha256(data: bytes) -> str:
    return hashlib.sha256(data).hexdigest()


def make_image(model: str = "pro", size: int = 3000, fill: int = 7) -> bytes:
    magic = PRO_MAGIC if model == "pro" else DOT_MAGIC
    return magic + bytes([fill]) * (size - len(magic))


def make_zip(
    release_name: str,
    image: bytes,
    *,
    folder: bool = True,
    extra: dict[str, bytes] | None = None,
    names: dict[str, str] | None = None,
    skip: tuple[str, ...] = (),
) -> bytes:
    """A package zip the way upstream builds it: one folder holding the four files."""
    prefix = release_name.removesuffix(".zip") + "/" if folder else ""
    contents = {
        "FIRMWARE.BIN": image,
        "README.txt": b"Copy only FIRMWARE.BIN to the drive.\n",
        "RELEASE_NOTES.txt": b"# Release\n- something\n",
        "SHA256SUMS.txt": (sha256(image) + "  FIRMWARE.BIN\n").encode(),
    }
    buffer = io.BytesIO()
    with zipfile.ZipFile(buffer, "w", zipfile.ZIP_DEFLATED) as archive:
        for member in PACKAGE_MEMBER_NAMES:
            if member in skip:
                continue
            archive.writestr((names or {}).get(member, prefix + member), contents[member])
        for name, data in (extra or {}).items():
            archive.writestr(name, data)
    return buffer.getvalue()


def make_release(
    model: str = "pro",
    version: str = "1.1.0",
    *,
    image: bytes | None = None,
    package: bytes | None = None,
) -> FirmwareRelease:
    """A release pinned to a synthetic package (built here unless given)."""
    image = image if image is not None else make_image(model)
    drive = "SidePulse" if model == "pro" else "PulseDot"
    package_name = f"sidepulse-{model}-{version}-ota.zip"
    data = package if package is not None else make_zip(package_name, image)
    return FirmwareRelease(
        model=model,
        version=version,
        package_name=package_name,
        package_dir=f"firmware/v{version}",
        package_sha256=sha256(data),
        package_size=len(data),
        image_sha256=sha256(image),
        image_size=len(image),
        image_magic=PRO_MAGIC if model == "pro" else DOT_MAGIC,
        drive_name=drive,
        notes=("Something got better.",),
    )


def pro_status(
    version: str = "1.0.2",
    *,
    slot: str = "A",
    uptime_ms: int = 83_257_187,
    serial: str = "SPP-000901",
    ota: str = "ready",
    state: str = "idle",
    other_valid: bool = True,
    other_version: str = "none",
) -> str:
    other = "B" if slot == "A" else "A"
    slot_a = "A image=1 valid=1 version=27251.50806 build=2026-08-05T23:25:42Z hash=6378ab999ab0"
    slot_b = f"B image={1 if other_version != 'none' else 0} valid={1 if other_valid else 0} version={other_version} build=unknown hash=unknown"
    lines = [
        f"release_version {version}",
        f"serial {serial}",
        "firmware_version 27251.50806",
        "firmware_build 2026-08-05T23:25:42Z",
        f"firmware_slot {slot}",
        f"uptime_ms {uptime_ms}",
        f"state {state}",
        f"active_slot {slot}",
        f"target_slot {other}",
        f"ota {ota}",
        "reboot_requested 0",
        slot_a if slot == "A" else slot_b.replace("B ", "A ", 1),
        slot_b if slot == "A" else slot_a.replace("A ", "B ", 1),
    ]
    return "\n".join(lines) + "\n"


def dot_status(
    version: str = "1.0.4",
    *,
    serial: str = "SPD-000902",
    ticks: int = 84_259_998,
    fw_state: str = "idle",
) -> str:
    return (
        f"reads 12\nticks {ticks}\nserial {serial}\napp_version {version}\n"
        f"app_build 2026-08-19T20:08:39Z\nfw_state {fw_state}\nfw_reboot 0\n"
    )


class FakeFat(DriveOps):
    """A temporary folder that behaves like the SidePulse FAT volume where it
    matters: a root directory with a fixed number of 32-byte entries. Creating
    a name that does not fit raises ENOSPC, and with ``stamp_sidecars`` every
    new file brings a ``._NAME`` AppleDouble sidecar along when there is room
    for it, as macOS does."""

    def __init__(
        self,
        capacity_entries: int = 16,
        *,
        stamp_sidecars: bool = True,
        free_bytes: int | None = 150_000,
    ) -> None:
        self.capacity_entries = capacity_entries
        self.stamp_sidecars = stamp_sidecars
        self.free = free_bytes
        self.log: list[tuple[str, str]] = []
        self.unlinked: list[str] = []

    def root_capacity(self, root: Path) -> int | None:
        return self.capacity_entries

    def free_bytes(self, root: Path) -> int | None:
        return self.free

    def used_entries(self, root: Path) -> int:
        return LABEL_ENTRIES + sum(entries_for_name(item.name) for item in root.iterdir())

    def write_file(self, root: Path, name: str, data: bytes, *, replace: bool) -> None:
        target = root / name
        exists = target.exists()
        if not exists:
            if self.used_entries(root) + entries_for_name(name) > self.capacity_entries:
                raise OSError(errno.ENOSPC, "No space left on device")
            sidecar = "._" + name
            # macOS stamps a sidecar beside a new file when the directory has
            # room for it; when it does not, the file still lands.
            if (
                self.stamp_sidecars
                and not (root / sidecar).exists()
                and self.used_entries(root) + entries_for_name(name) + entries_for_name(sidecar)
                <= self.capacity_entries
            ):
                (root / sidecar).write_bytes(APPLEDOUBLE_MAGIC + bytes(4092))
        super().write_file(root, name, data, replace=replace and exists)
        self.log.append(("write", name))

    def unlink(self, root: Path, name: str) -> None:
        super().unlink(root, name)
        self.unlinked.append(name)
        self.log.append(("unlink", name))

    def sync(self, root: Path) -> None:
        self.log.append(("sync", root.name))


def populate_pro_drive(root: Path, *, sidecars: bool = True) -> None:
    """A Pro's root as the hand update found it: the device files, a stray
    ``.claude``, and the sidecars macOS left."""
    root.mkdir(parents=True, exist_ok=True)
    (root / "STATUS.TXT").write_text(pro_status())
    (root / "INIT.LED").write_text("off\n")
    (root / "LEDS.LED").write_text("#112233\n")
    (root / "keepalive").write_text("")
    (root / ".claude").write_text("")
    (root / ".fseventsd").mkdir(exist_ok=True)
    if sidecars:
        (root / "._LEDS.LED").write_bytes(APPLEDOUBLE_MAGIC + bytes(4092))
        (root / "._keepalive").write_bytes(APPLEDOUBLE_MAGIC + bytes(4092))


@dataclass
class FakeWorld:
    """One or more devices whose STATUS.TXT follows an injected clock.

    The device applies an update ``apply_delay`` seconds after a
    ``FIRMWARE.BIN`` shows up in its root, then its drive is gone for
    ``gone_for`` seconds, then it returns on ``new_version``."""

    now: float = 1000.0
    devices: dict[str, FakeDevice] = field(default_factory=dict)
    sleeps: list[float] = field(default_factory=list)
    hooks: list = field(default_factory=list)

    def clock(self) -> float:
        return self.now

    def wall(self) -> float:
        return 1_700_000_000.0 + self.now

    def sleep(self, seconds: float) -> None:
        self.sleeps.append(seconds)
        self.now += seconds
        for hook in self.hooks:
            hook(self)

    def read(self, root: Path) -> FirmwareReading | None:
        for device in self.devices.values():
            if Path(root) == device.current_root(self.now):
                text = device.status_text(self.now)
                if text is None:
                    return None
                return reading_from_fields(parse_status_fields(text))
        return None

    def find_roots(self) -> list[Path]:
        return [
            device.current_root(self.now)
            for device in self.devices.values()
            if device.status_text(self.now) is not None
        ]


@dataclass
class FakeDevice:
    model: str
    root: Path
    old_status: str
    new_status: str
    apply_delay: float = 3.0
    gone_for: float = 12.0
    applies: bool = True
    returns: bool = True
    #: The path the drive comes back at (None: the same one).
    returned_root: Path | None = None
    seen_image_at: float | None = None
    world: FakeWorld | None = None

    def current_root(self, now: float) -> Path:
        applied_at = self._applied_at()
        if applied_at is not None and now >= applied_at + self.gone_for and self.returned_root:
            return self.returned_root
        return self.root

    def _applied_at(self) -> float | None:
        return None if self.seen_image_at is None else self.seen_image_at + self.apply_delay

    def status_text(self, now: float) -> str | None:
        if self.seen_image_at is None and (self.root / "FIRMWARE.BIN").exists():
            self.seen_image_at = now
        applied_at = self._applied_at()
        if applied_at is None or now < applied_at:
            return self.old_status
        if not self.applies:
            return self.old_status
        if now < applied_at + self.gone_for:
            return None
        if not self.returns:
            return None
        return self.new_status
