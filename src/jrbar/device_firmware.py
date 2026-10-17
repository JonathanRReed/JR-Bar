"""Which firmware a SidePulse runs, read from its own STATUS.TXT, and which
releases JR-Bar knows how to install.

The device writes its model and release into STATUS.TXT: a Pro reports
``release_version`` (with ``firmware_version`` and ``firmware_slot`` for its
two update slots), a Dot reports ``app_version`` (with ``app_build`` and
``fw_state``). Reading and comparing never write to a device and never reach
the network: the newest release JR-Bar knows about is the catalog below,
refreshed by hand at each upstream review
(docs/archive/UPSTREAM-REFRESH-2026-10-07.md).

The catalog pins everything an install needs to trust a package without
asking the place that serves it: the exact host and path, the hash of the
zip, the hash and size of the ``FIRMWARE.BIN`` inside it, and the magic bytes
that say which model the image is for. Nothing in this module downloads
anything; ``firmware_package`` does that, once, when a person asks.

Why a person wants to know:

* Pro firmware 1.1.0 balances colour inside the device (calibrated gains for
  its 16-bit LEDs, with brightness and balance rounded once). A hand-tuned
  channel gain made for older firmware then stacks on top of the device's own.
* Dot firmware 1.1.14 fixes drive identification with several Dots attached.
"""

from __future__ import annotations

import json
import re
import sys
from collections.abc import Callable, Mapping
from dataclasses import dataclass
from pathlib import Path
from typing import Final

from .device_clock import FRESH_READ_TIMEOUT_SECONDS, bounded, fresh_read_bytes

STATUS_FILE_NAME: Final = "STATUS.TXT"

MODEL_NAMES: Final[Mapping[str, str]] = {"pro": "SidePulse Pro", "dot": "SidePulse Dot"}
#: The serial prefix each model's firmware writes into STATUS.TXT.
SERIAL_PREFIXES: Final[Mapping[str, str]] = {"pro": "SPP-", "dot": "SPD-"}

#: Where every pinned package lives. A download is refused for any other host,
#: for any scheme but https, and when the server redirects.
PACKAGE_HOST: Final = "raw.githubusercontent.com"
#: The upstream commit the pinned packages were taken from
#: (inteliwear/sidepulse ``firmware/README.md`` at 6d55225, 2026-09-30).
PACKAGE_COMMIT: Final = "6d55225fed20a82521b23d86a4df2c4a15dff295"
#: The file the device applies, and the only one JR-Bar ever copies to it.
IMAGE_FILE_NAME: Final = "FIRMWARE.BIN"
#: The files a package holds, and no others.
PACKAGE_MEMBER_NAMES: Final = ("FIRMWARE.BIN", "README.txt", "RELEASE_NOTES.txt", "SHA256SUMS.txt")


@dataclass(frozen=True, slots=True)
class FirmwareRelease:
    """One published firmware release, pinned."""

    model: str
    version: str
    package_name: str
    #: The package's folder inside the repository, under the pinned commit.
    package_dir: str
    package_sha256: str
    package_size: int
    image_sha256: str
    image_size: int
    #: The first bytes of the image: the letters SDUP for a Pro, a UF2 header for a Dot.
    image_magic: bytes
    #: The drive name the vendor gives (``SidePulse`` or ``PulseDot``).
    drive_name: str
    #: Plain-words release notes for the person.
    notes: tuple[str, ...]

    @property
    def name(self) -> str:
        return MODEL_NAMES[self.model]

    @property
    def package_path(self) -> str:
        return f"/inteliwear/sidepulse/{PACKAGE_COMMIT}/{self.package_dir}/{self.package_name}"

    @property
    def package_url(self) -> str:
        return f"https://{PACKAGE_HOST}{self.package_path}"

    @property
    def member_folder(self) -> str:
        """The folder the zip's files sit in: the package name without ``.zip``."""
        return self.package_name.removesuffix(".zip")


#: The newest firmware published for each model when this table was last
#: reviewed (upstream firmware/README.md at 6d55225, 2026-09-30). The hashes
#: were taken from the downloaded packages on 2026-10-07.
RELEASES: Final[tuple[FirmwareRelease, ...]] = (
    FirmwareRelease(
        model="pro",
        version="1.1.0",
        package_name="sidepulse-pro-1.1.0-ota.zip",
        package_dir="firmware/v1.1.0",
        package_sha256="1efc35498f837932938aaf1b3e4f2889549d09cfbf974ae1132cafb7768b6fac",
        package_size=137875,
        image_sha256="3104ed5b9ebb4e0bd35b2fba3083fe931f5e23d42a322f019a556c31f1a4a1ce",
        image_size=136992,
        image_magic=b"SDUP",
        drive_name="SidePulse",
        notes=(
            "Better white balance and mixed colours through the diffuser: the "
            "firmware now applies calibrated red, green and blue gains.",
            "Dim colours keep more of their detail: brightness and colour "
            "balance are applied together, with one rounding at the end.",
            "Animations and startup programs work as before, and can also be "
            "sent to a drive that macOS mounts read-only, where policy allows.",
            "More reliable updates, and files survive a restart.",
            "Better SD-reader compatibility, and recovery from an interrupted read.",
        ),
    ),
    FirmwareRelease(
        model="dot",
        version="1.1.14",
        package_name="sidepulse-dot-1.1.14-ota.zip",
        package_dir="firmware/v1.1.14",
        package_sha256="1d82c907dfb945f8714e9021afaf793a161eff13182967bcc5d63ebbc212cdb7",
        package_size=31349,
        image_sha256="f377f28e90f419ef83e67e352c3b7bd706e33c7e25ae925008c97a93b8afeb05",
        image_size=57344,
        image_magic=b"UF2\n",
        drive_name="PulseDot",
        notes=(
            "Better drive identification when several Dots are plugged in.",
            "Better direct USB compatibility with Android phones.",
            "Programs up to 512 bytes, and lower power use while the LEDs are off.",
            "Animation updates also work on a drive macOS mounts read-only, "
            "where policy allows.",
        ),
    ),
)

#: The newest version published for each model.
LATEST_KNOWN_VERSIONS: Final[Mapping[str, str]] = {
    release.model: release.version for release in RELEASES
}


def release_for(model: str) -> FirmwareRelease | None:
    """The pinned release for a model, or ``None`` for an unknown one."""
    return next((release for release in RELEASES if release.model == model), None)


#: The first Pro release that balances colour in the firmware.
PRO_COLOUR_BALANCE_VERSION: Final = (1, 1, 0)

_VERSION: Final = re.compile(r"v?(\d+)\.(\d+)(?:\.(\d+))?(-[^+\s]+)?(?:\+\S+)?\Z")


@dataclass(frozen=True, slots=True)
class FirmwareIdentity:
    model: str  # "pro" or "dot"
    version: str
    serial: str | None = None

    @property
    def name(self) -> str:
        return MODEL_NAMES[self.model]


def parse_status_fields(text: str) -> dict[str, str]:
    """``key value`` lines; the first value of a repeated key wins."""
    fields: dict[str, str] = {}
    for line in (text or "").replace("\x00", "").splitlines():
        parts = line.strip().split(None, 1)
        if len(parts) == 2 and parts[0] not in fields:
            fields[parts[0]] = parts[1].strip()
    return fields


def identify_firmware(fields: Mapping[str, str]) -> FirmwareIdentity | None:
    """The model and release a status names, or ``None`` when it does not
    name exactly one model."""
    dot = "app_version" in fields or ("app_build" in fields and "fw_state" in fields)
    pro = "release_version" in fields or (
        "firmware_version" in fields and "firmware_slot" in fields
    )
    if dot == pro:
        return None
    if dot:
        model, version = "dot", fields.get("app_version", "unknown")
    else:
        model, version = "pro", fields.get("release_version", "unknown")
    serial = fields.get("serial")
    return FirmwareIdentity(model=model, version=version, serial=serial or None)


@dataclass(frozen=True, slots=True)
class SlotInfo:
    """One firmware slot of a Pro, from its ``A image=1 valid=1 ...`` line."""

    name: str
    has_image: bool
    valid: bool
    version: str


@dataclass(frozen=True, slots=True)
class FirmwareReading:
    """Everything an update decision needs from one STATUS.TXT."""

    identity: FirmwareIdentity
    active_slot: str | None = None
    build: str | None = None
    #: The device's own clock in milliseconds (a Pro's ``uptime_ms``, a Dot's
    #: ``ticks``); it starts over when the device restarts.
    uptime_ms: int | None = None
    slots: tuple[SlotInfo, ...] = ()
    #: Why the device looks busy (an update or restart in progress), if it does.
    busy: str | None = None

    @property
    def serial_matches_model(self) -> bool:
        """Whether the serial prefix agrees with the fields that named the
        model. A status with no serial at all does not match: an update never
        goes to a drive that cannot say which device it is."""
        serial = self.identity.serial or ""
        return serial.startswith(SERIAL_PREFIXES[self.identity.model])

    def slot(self, name: str | None) -> SlotInfo | None:
        return next((item for item in self.slots if item.name == name), None)

    @property
    def other_slot(self) -> str | None:
        """The slot an update will write into: the one that is not active."""
        if self.active_slot not in ("A", "B"):
            return None
        return "B" if self.active_slot == "A" else "A"


_SLOT_LINE: Final = re.compile(r"image=(\d+)\s+valid=(\d+)\s+version=(\S+)")
#: Words that mean an update or restart is under way. STATUS.TXT does not
#: document its non-idle values, so only these obvious ones count as busy.
_BUSY_WORDS: Final = (
    "receiv", "writ", "stag", "apply", "applying", "reboot", "restart", "erase",
    "verif", "busy", "download", "flash", "updat",
)
_BUSY_FIELDS: Final = ("state", "ota", "fw_state")
_REBOOT_FIELDS: Final = ("reboot_requested", "fw_reboot", "fw_reboot_ms")


def _integer(value: str | None) -> int | None:
    try:
        return int(str(value).strip())
    except (TypeError, ValueError):
        return None


def busy_reason(fields: Mapping[str, str]) -> str | None:
    """A sentence naming why the device looks busy, or ``None``."""
    for name in _REBOOT_FIELDS:
        number = _integer(fields.get(name))
        if number:
            return f"the device reports {name} {number}"
    for name in _BUSY_FIELDS:
        value = (fields.get(name) or "").strip().lower()
        if value and any(word in value for word in _BUSY_WORDS):
            return f"the device reports {name} {value}"
    return None


def reading_from_fields(fields: Mapping[str, str]) -> FirmwareReading | None:
    """The identity and update facts a status names, or ``None`` when it does
    not name exactly one model."""
    identity = identify_firmware(fields)
    if identity is None:
        return None
    slots: list[SlotInfo] = []
    for name in ("A", "B"):
        match = _SLOT_LINE.search(fields.get(name, ""))
        if match is not None:
            slots.append(
                SlotInfo(name, match.group(1) != "0", match.group(2) != "0", match.group(3))
            )
    active = (fields.get("active_slot") or fields.get("firmware_slot") or "").strip().upper()
    uptime = _integer(fields.get("uptime_ms"))
    if uptime is None:
        uptime = _integer(fields.get("ticks"))  # the Dot's own clock
    return FirmwareReading(
        identity=identity,
        active_slot=active if active in ("A", "B") else None,
        build=(fields.get("firmware_build") or fields.get("app_build") or None),
        uptime_ms=uptime,
        slots=tuple(slots),
        busy=busy_reason(fields),
    )


def read_reading(
    root: Path,
    *,
    reader: Callable[[Path], tuple[bytes, float]] | None = None,
    timeout: float = FRESH_READ_TIMEOUT_SECONDS,
) -> FirmwareReading | None:
    """The firmware facts of the device mounted at ``root``, read past the
    host's cache, or ``None`` when the drive does not answer (bounded)."""
    path = Path(root) / STATUS_FILE_NAME
    read = reader or fresh_read_bytes

    def work() -> FirmwareReading | None:
        data, _at = read(path)
        return reading_from_fields(parse_status_fields(data.decode("utf-8", errors="replace")))

    result = bounded(f"firmware-reading:{path}", work, timeout=timeout)
    return result if isinstance(result, FirmwareReading) else None


def _parsed(version: str) -> tuple[tuple[int, int, int], bool] | None:
    match = _VERSION.match(version.strip())
    if match is None:
        return None
    major, minor, patch, suffix = match.groups()
    return (int(major), int(minor), int(patch or 0)), bool(suffix)


def is_behind_latest(
    identity: FirmwareIdentity,
    latest: Mapping[str, str] = LATEST_KNOWN_VERSIONS,
) -> bool | None:
    """True when a newer release is published, False when this is the newest
    (or newer), ``None`` when the version cannot be read."""
    mine = _parsed(identity.version)
    newest = _parsed(latest.get(identity.model, ""))
    if mine is None or newest is None:
        return None
    (number, prerelease), (target, _) = mine, newest
    return number < target or (number == target and prerelease)


def balances_colour_itself(identity: FirmwareIdentity) -> bool:
    """Whether this device's firmware already corrects colour balance."""
    if identity.model != "pro":
        return False
    parsed = _parsed(identity.version)
    return parsed is not None and not parsed[1] and parsed[0] >= PRO_COLOUR_BALANCE_VERSION


def describe_identity(identity: FirmwareIdentity) -> str:
    behind = is_behind_latest(identity)
    latest = LATEST_KNOWN_VERSIONS.get(identity.model, "?")
    if behind is None:
        return f"{identity.name}: firmware {identity.version} (version not recognised)"
    if behind:
        return (
            f"{identity.name}: firmware {identity.version}; {latest} is published "
            "(run `jrbar firmware upgrade` to install it)"
        )
    return f"{identity.name}: firmware {identity.version}, up to date"


def identity_document(identity: FirmwareIdentity, *, root: Path | str) -> dict[str, object]:
    return {
        "model": identity.model,
        "name": identity.name,
        "version": identity.version,
        "serial": identity.serial,
        "latest_known": LATEST_KNOWN_VERSIONS.get(identity.model),
        "behind": is_behind_latest(identity),
        "device": str(root),
        "color_balance_in_firmware": balances_colour_itself(identity),
    }


def read_identity(
    root: Path,
    *,
    reader: Callable[[Path], tuple[bytes, float]] | None = None,
    timeout: float = FRESH_READ_TIMEOUT_SECONDS,
) -> FirmwareIdentity | None:
    """The firmware of the device mounted at ``root``, or ``None``.

    The host caches STATUS.TXT, so this reads past the cache. The read is
    bounded: a stalled device answers ``None`` instead of holding the caller."""
    path = Path(root) / STATUS_FILE_NAME
    read = reader or fresh_read_bytes

    def work() -> FirmwareIdentity | None:
        data, _at = read(path)
        return identify_firmware(parse_status_fields(data.decode("utf-8", errors="replace")))

    result = bounded(f"firmware:{path}", work, timeout=timeout)
    return result if isinstance(result, FirmwareIdentity) else None


def run_version_command(
    device: Path | None,
    *,
    as_json: bool,
    reader: Callable[[Path], tuple[bytes, float]] | None = None,
    mount_root: Path | None = None,
    out=None,
    err=None,
) -> int:
    """``jrbar firmware version``: print what each connected device runs.

    Read-only. ``device`` names one mounted drive; without it every mounted
    SidePulse is read. Exit 0 when at least one device answered."""
    out = out or sys.stdout
    err = err or sys.stderr
    if device is not None:
        roots = [Path(device).expanduser()]
    else:
        from .device_writer import MOUNT_ROOT, discover_devices

        # Discovery asks for the LED file by name; the volume is the device.
        roots = [
            candidate.root
            for candidate in discover_devices(mount_root=mount_root or MOUNT_ROOT)
        ]
    if not roots:
        print("jrbar firmware: no mounted SidePulse found", file=err)
        return 1
    found: list[tuple[Path, FirmwareIdentity]] = []
    for root in roots:
        identity = read_identity(root, reader=reader)
        if identity is None:
            print(f"jrbar firmware: could not read a SidePulse firmware from {root} (not a SidePulse?)", file=err)
            continue
        found.append((root, identity))
    if as_json:
        print(json.dumps([identity_document(identity, root=root) for root, identity in found]), file=out)
    else:
        for root, identity in found:
            print(f"{describe_identity(identity)}  ({root})", file=out)
            if balances_colour_itself(identity):
                print(
                    "    This firmware balances colour itself; channel gains tuned for "
                    "older firmware may now over-correct (reset them in the Colors window).",
                    file=out,
                )
    return 0 if found else 1
