"""Updating a SidePulse's firmware from JR-Bar, as one observable job.

What a person gets: one click, an honest account of every step, and a device
that is either on the new firmware (proved by its own ``STATUS.TXT``) or still
on the old one. The sequence is the vendor's, with the lessons of updating a
Pro and a Dot by hand on 2026-10-07 built in:

1. ``checking``: read the device fresh, refuse if it is not what we think
   (wrong model, unknown facts, busy, already current, Mac low on battery,
   another update running).
2. ``downloading`` / ``verifying``: get the package (cache, a file the person
   named, or the one pinned download, only because they asked) and check it
   against the hashes pinned in the app before anything is opened.
3. ``preparing``: from here every write to the device is held. Count the
   drive's root-directory entries and remove the macOS sidecars in the way.
4. ``copying``: copy ``FIRMWARE.BIN`` alone to the top of the drive, flush.
5. ``restarting``: leave the device untouched for at least ten seconds, then
   wait (bounded) for its drive to come back.
6. ``confirming``: read ``STATUS.TXT`` fresh. Only the version the device
   itself reports counts as success. Then tidy the sidecar macOS made.

A failure at any step leaves the device on its old firmware: the device
applies an update only from a complete valid image. Whatever happens, the
write hold on the device is released.

Nothing here runs by itself. ``begin_update`` is called by a command a person
issued; there is no timer, no launch hook and no background check.
"""

from __future__ import annotations

import itertools
import threading
import time
from collections.abc import Callable, Iterable
from dataclasses import dataclass, field
from pathlib import Path
from typing import Any, Final

from . import firmware_hold
from .device_firmware import (
    MODEL_NAMES,
    PACKAGE_HOST,
    RELEASES,
    FirmwareReading,
    FirmwareRelease,
    balances_colour_itself,
    is_behind_latest,
    read_reading,
)
from .firmware_drive import DriveError, DriveOps, cleanup_after_copy, copy_image, prepare_drive
from .firmware_package import (
    PackageError,
    Progress,
    download_package,
    is_cached,
    load_cached,
    store_cached,
    verify_package,
)

#: The vendor: leave the device untouched at least this long after the copy.
RESTART_MIN_WAIT_SECONDS: Final = 10.0
#: Give up waiting for the drive to come back after this long.
RESTART_TIMEOUT_SECONDS: Final = 120.0
POLL_SECONDS: Final = 1.0
#: A device that is busy or just remounted can be slow to answer; an update's
#: reads wait longer than the keepalive's half second.
STATUS_READ_SECONDS: Final = 3.0
#: Refuse on battery power below this percent: the Pro is powered by the
#: Mac's SD slot, and a Mac that dies mid-update is the worst case.
MIN_BATTERY_PERCENT: Final = 30
#: How long a finished job stays in the daemon's state.
FINISHED_JOB_SECONDS: Final = 600.0
#: No hold outlives this, whatever happens to the update (see firmware_hold).
HOLD_SECONDS: Final = RESTART_TIMEOUT_SECONDS + 240.0

PHASE_LABELS: Final = {
    "checking": "Checking the device",
    "downloading": "Downloading the update",
    "verifying": "Checking the download",
    "preparing": "Preparing the device's drive",
    "copying": "Copying the update to the device",
    "restarting": "Waiting for the device to restart",
    "confirming": "Confirming the new firmware",
    "done": "Done",
}
HELD_REASON: Final = "updating firmware"

Clock = Callable[[], float]


class UpdateRefused(Exception):
    """An update that was not started. ``kind`` picks the protocol error code
    (``not_found``, ``invalid_args``, ``busy`` or ``refused``); ``code`` is
    the specific reason."""

    def __init__(self, kind: str, code: str, message: str) -> None:
        super().__init__(message)
        self.kind = kind
        self.code = code
        self.message = message


@dataclass(frozen=True, slots=True)
class DeviceRef:
    """A connected SidePulse drive, as the daemon (or the CLI) knows it."""

    id: str
    name: str
    root: Path
    connected: bool = True


@dataclass(frozen=True, slots=True)
class Refusal:
    code: str
    message: str

    def to_document(self) -> dict[str, str]:
        return {"code": self.code, "message": self.message}


@dataclass(slots=True)
class UpdateJob:
    """One update, from the press of the button to its result."""

    id: str
    device_id: str
    model: str
    name: str
    root: str
    from_version: str
    to_version: str
    serial: str
    from_slot: str | None
    started_at: float
    phase: str = "checking"
    phase_started_at: float = 0.0
    updated_at: float = 0.0
    #: ``None`` while running; then ``updated``, ``failed`` or ``unconfirmed``.
    outcome: str | None = None
    code: str | None = None
    message: str | None = None
    what_to_do: str | None = None
    finished_at: float | None = None
    #: ``download``, ``cache`` or ``file``.
    source: str | None = None
    bytes_done: int = 0
    bytes_total: int | None = None
    removed_sidecars: list[str] = field(default_factory=list)
    new_slot: str | None = None
    previous_kept: dict[str, Any] | None = None
    colour_check: bool = False
    restarted: bool | None = None
    #: A package the person named instead of downloading one. Not published.
    from_file: Path | None = None

    @property
    def running(self) -> bool:
        return self.outcome is None

    def to_document(self) -> dict[str, Any]:
        return {
            "id": self.id,
            "device": self.device_id,
            "model": self.model,
            "name": self.name,
            "serial": self.serial,
            "from_version": self.from_version,
            "to_version": self.to_version,
            "phase": self.phase,
            "phase_label": PHASE_LABELS.get(self.phase, self.phase),
            "outcome": self.outcome,
            "code": self.code,
            "message": self.message,
            "what_to_do": self.what_to_do,
            "source": self.source,
            "started_at": self.started_at,
            "phase_started_at": self.phase_started_at,
            "updated_at": self.updated_at,
            "finished_at": self.finished_at,
            "download": (
                {"bytes": self.bytes_done, "total": self.bytes_total}
                if self.phase == "downloading"
                else None
            ),
            "removed_sidecars": list(self.removed_sidecars),
            "new_slot": self.new_slot,
            "previous_firmware": self.previous_kept,
            "colour_check": self.colour_check,
            "restarted": self.restarted,
        }


# --- the rules ---------------------------------------------------------------------


def battery_refusal(snapshot: object | None) -> Refusal | None:
    """Refuse on battery power below the floor. An unreadable battery or a
    desktop Mac (no battery) does not block: only a known low one does."""
    if snapshot is None:
        return None
    present = bool(getattr(snapshot, "battery_present", False))
    voltage = float(getattr(snapshot, "voltage", 0.0) or 0.0)
    plugged = bool(getattr(snapshot, "is_plugged", False) or getattr(snapshot, "adapter_connected", False))
    percent = int(getattr(snapshot, "percent", 100))
    if present and voltage > 0 and not plugged and percent < MIN_BATTERY_PERCENT:
        return Refusal(
            "battery_low",
            f"This Mac is on battery at {percent}%. Plug in the charger first: a Mac that shuts "
            "down in the middle of an update could leave the device needing a recovery.",
        )
    return None


def eligibility(
    reading: FirmwareReading | None,
    release: FirmwareRelease | None,
    *,
    battery: object | None,
    mounted: bool = True,
) -> Refusal | None:
    """Why this device cannot be updated right now, or ``None`` if it can.

    ``up_to_date`` is a refusal here (there is nothing to do) but not an
    error for the person; callers word it differently."""
    if not mounted or reading is None:
        return Refusal(
            "not_mounted",
            "The device's drive is not mounted, or it did not answer. Reconnect it and try again.",
        )
    identity = reading.identity
    if identity.model not in MODEL_NAMES:
        return Refusal("model_unknown", "This device is not a model JR-Bar knows how to update.")
    if not reading.serial_matches_model:
        return Refusal(
            "model_mismatch",
            "The device's serial number does not match the model it reports, so JR-Bar will not "
            "write firmware to it.",
        )
    if release is None or release.model != identity.model:
        return Refusal("no_release", f"JR-Bar has no firmware pinned for the {identity.name}.")
    behind = is_behind_latest(identity)
    if behind is None:
        return Refusal(
            "facts_unknown",
            f"The device reports a firmware version JR-Bar cannot read ({identity.version!r}).",
        )
    if not behind:
        return Refusal("up_to_date", f"The {identity.name} already runs {identity.version}.")
    complete = reading.active_slot is not None if identity.model == "pro" else reading.build is not None
    if not complete:
        return Refusal(
            "facts_unknown",
            "The device's STATUS.TXT does not say enough (its firmware slot or build) for JR-Bar to "
            "update it safely.",
        )
    if reading.busy is not None:
        return Refusal("device_busy", f"The device looks busy: {reading.busy}. Wait a minute and try again.")
    return battery_refusal(battery)


# --- the service --------------------------------------------------------------------


class FirmwareService:
    """Everything the daemon and the CLI need to look at and run an update.

    All the outside world is passed in, so a test can fake the drive, the
    clock, the sleep and the network: ``devices`` lists the connected drives,
    ``find_roots`` every mounted SidePulse drive (the device may come back
    under another name), ``ops`` does the file work, ``read`` reads
    ``STATUS.TXT`` fresh."""

    def __init__(
        self,
        *,
        state_dir: Path,
        devices: Callable[[], Iterable[DeviceRef]],
        find_roots: Callable[[], Iterable[Path]] = lambda: (),
        partners: Callable[[DeviceRef], Iterable[Path]] = lambda ref: (),
        battery: Callable[[], object | None] = lambda: None,
        ops: DriveOps | None = None,
        read: Callable[[Path], FirmwareReading | None] | None = None,
        clock: Clock = time.monotonic,
        wall: Clock = time.time,
        sleep: Callable[[float], None] = time.sleep,
        opener: Any = None,
        on_change: Callable[[], None] | None = None,
        releases: Iterable[FirmwareRelease] = RELEASES,
        restart_min_wait: float = RESTART_MIN_WAIT_SECONDS,
        restart_timeout: float = RESTART_TIMEOUT_SECONDS,
    ) -> None:
        self.state_dir = Path(state_dir)
        self._devices = devices
        self._find_roots = find_roots
        self._partners = partners
        self._battery = battery
        self.ops = ops or DriveOps()
        self._read = read or (lambda root: read_reading(root, timeout=STATUS_READ_SECONDS))
        self.clock = clock
        self.wall = wall
        self._sleep = sleep
        self._opener = opener
        self._on_change = on_change
        self._releases = tuple(releases)
        self.restart_min_wait = restart_min_wait
        self.restart_timeout = restart_timeout
        self._lock = threading.Lock()
        self._job: UpdateJob | None = None
        self._ids = itertools.count(1)

    # -- looking --------------------------------------------------------------------

    def release_for(self, model: str) -> FirmwareRelease | None:
        return next((release for release in self._releases if release.model == model), None)

    @property
    def job(self) -> UpdateJob | None:
        with self._lock:
            return self._job

    def job_document(self) -> dict[str, Any] | None:
        """The job for ``state.firmware``: running, or finished recently."""
        with self._lock:
            job = self._job
            if job is None:
                return None
            if job.finished_at is not None and self.wall() - job.finished_at > FINISHED_JOB_SECONDS:
                self._job = None
                return None
            return job.to_document()

    def catalog_document(self) -> list[dict[str, Any]]:
        return [
            {
                "model": release.model,
                "name": release.name,
                "version": release.version,
                "notes": list(release.notes),
                "package": {
                    "host": PACKAGE_HOST,
                    "name": release.package_name,
                    "bytes": release.package_size,
                    "cached": is_cached(self.state_dir, release),
                },
                "drive": release.drive_name,
                "image_bytes": release.image_size,
            }
            for release in self._releases
        ]

    def device_document(self, ref: DeviceRef, *, reading: FirmwareReading | None = None) -> dict[str, Any]:
        if reading is None and ref.connected:
            reading = self._read(ref.root)
        document: dict[str, Any] = {
            "id": ref.id,
            "name": ref.name,
            "root": str(ref.root),
            "mounted": ref.connected,
            "model": None,
            "serial": None,
            "version": None,
            "active_slot": None,
            "build": None,
            "uptime_ms": None,
            "latest": None,
            "update_available": None,
            "can_update": False,
            "why_not": None,
            "other_slot": None,
            "colour_note": False,
        }
        refusal: Refusal | None
        if reading is None:
            refusal = eligibility(None, None, battery=None, mounted=ref.connected)
            document["why_not"] = refusal.to_document() if refusal else None
            return document
        identity = reading.identity
        release = self.release_for(identity.model)
        document.update(
            model=identity.model,
            name=identity.name,
            serial=identity.serial,
            version=identity.version,
            active_slot=reading.active_slot,
            build=reading.build,
            uptime_ms=reading.uptime_ms,
            latest=release.version if release else None,
            colour_note=balances_colour_itself(identity),
        )
        other = reading.slot(reading.other_slot)
        if other is not None:
            document["other_slot"] = {
                "name": other.name,
                "has_image": other.has_image,
                "valid": other.valid,
                "version": other.version,
            }
        behind = is_behind_latest(identity)
        document["update_available"] = behind
        refusal = eligibility(reading, release, battery=self._battery(), mounted=ref.connected)
        if refusal is None:
            document["can_update"] = True
        elif refusal.code != "up_to_date":
            document["why_not"] = refusal.to_document()
        return document

    def status_document(self) -> dict[str, Any]:
        devices = [self.device_document(ref) for ref in self._devices()]
        return {
            "catalog": self.catalog_document(),
            "devices": devices,
            "job": self.job_document(),
            "download_host": PACKAGE_HOST,
        }

    # -- starting -------------------------------------------------------------------

    def _find(self, device_id: object) -> DeviceRef:
        if not isinstance(device_id, str) or not device_id:
            raise UpdateRefused("invalid_args", "device_required", "Say which device to update.")
        ref = next((item for item in self._devices() if item.id == device_id), None)
        if ref is None:
            raise UpdateRefused("not_found", "no_such_device", "No such device.")
        return ref

    def begin_update(
        self,
        device_id: object,
        *,
        confirm: bool,
        from_file: Path | None = None,
    ) -> UpdateJob:
        """Check everything and register the job. Raises ``UpdateRefused``;
        otherwise the update is ready for ``execute``. Nothing is written and
        nothing is fetched until ``execute``."""
        if confirm is not True:
            raise UpdateRefused("invalid_args", "not_confirmed", "An update needs an explicit confirmation.")
        ref = self._find(device_id)
        with self._lock:
            if self._job is not None and self._job.running:
                raise UpdateRefused("busy", "busy", "Another firmware update is already running.")
        if not ref.connected:
            refusal = eligibility(None, None, battery=None, mounted=False)
            raise UpdateRefused("refused", refusal.code, refusal.message)  # type: ignore[union-attr]
        reading = self._read(ref.root)
        release = self.release_for(reading.identity.model) if reading is not None else None
        refusal = eligibility(reading, release, battery=self._battery())
        if refusal is not None:
            raise UpdateRefused("refused", refusal.code, refusal.message)
        assert reading is not None and release is not None
        now = self.wall()
        job = UpdateJob(
            id=f"fw-{next(self._ids)}",
            device_id=ref.id,
            model=reading.identity.model,
            name=reading.identity.name,
            root=str(ref.root),
            from_version=reading.identity.version,
            to_version=release.version,
            serial=reading.identity.serial or "",
            from_slot=reading.active_slot,
            started_at=now,
            from_file=Path(from_file).expanduser() if from_file is not None else None,
            phase="checking",
            phase_started_at=now,
            updated_at=now,
        )
        with self._lock:
            if self._job is not None and self._job.running:
                raise UpdateRefused("busy", "busy", "Another firmware update is already running.")
            self._job = job
        self._notify()
        return job

    def start_update(
        self,
        device_id: object,
        *,
        confirm: bool,
        from_file: Path | None = None,
    ) -> UpdateJob:
        """``begin_update``, then run the rest on a worker thread."""
        job = self.begin_update(device_id, confirm=confirm, from_file=from_file)
        threading.Thread(
            target=self.execute,
            args=(job,),
            name="JRBarFirmwareUpdate",
            daemon=True,
        ).start()
        return job

    # -- running --------------------------------------------------------------------

    def _notify(self) -> None:
        if self._on_change is not None:
            try:
                self._on_change()
            except Exception:
                pass

    def _phase(self, job: UpdateJob, phase: str) -> None:
        now = self.wall()
        with self._lock:
            job.phase = phase
            job.phase_started_at = now
            job.updated_at = now
        self._notify()

    def _finish(
        self,
        job: UpdateJob,
        outcome: str,
        *,
        code: str | None = None,
        message: str | None = None,
        what_to_do: str | None = None,
    ) -> None:
        now = self.wall()
        with self._lock:
            job.outcome = outcome
            job.code = code
            job.message = message
            job.what_to_do = what_to_do
            job.updated_at = now
            job.finished_at = now
            if outcome == "updated":
                job.phase = "done"
                job.phase_started_at = now
        self._notify()

    def execute(self, job: UpdateJob) -> UpdateJob:
        """Run a registered job to its end. Never raises; the job says what
        happened. The write hold is always released."""
        held: list[Path] = []
        try:
            self._execute(job, held)
        except PackageError as error:
            self._finish(
                job, "failed", code=error.code, message=error.message,
                what_to_do="Nothing was written to the device and it is still on its old firmware. "
                "You can try again.",
            )
        except DriveError as error:
            self._finish(job, "failed", code=error.code, message=error.message,
                         what_to_do="The device is still on its old firmware.")
        except Exception as error:  # a job must always end with an answer
            self._finish(
                job, "failed", code="internal",
                message=f"The update stopped unexpectedly ({type(error).__name__}).",
                what_to_do="Reconnect the device and check its firmware with `jrbar firmware version`.",
            )
        finally:
            for root in held:
                firmware_hold.release(root)
            self._notify()
        return job

    def _execute(self, job: UpdateJob, held: list[Path]) -> None:
        release = self.release_for(job.model)
        assert release is not None
        root = Path(job.root)

        image = self._acquire(job, release, job.from_file)

        # From here nothing but this update writes to the device (or, for a
        # linked pair, to either of them). The hold has its own hard deadline
        # and is released in ``execute``'s finally, whatever happens.
        for target in [root, *self._partner_roots(job, root)]:
            firmware_hold.acquire(target, HELD_REASON, seconds=HOLD_SECONDS)
            held.append(target)
        self._notify()

        # The device may have been swapped or have started something since the
        # button was pressed; look again right before anything is written.
        reading = self._read(root)
        if (
            reading is None
            or reading.identity.model != job.model
            or reading.identity.serial != job.serial
            or reading.identity.version != job.from_version
            or reading.busy is not None
        ):
            self._finish(
                job, "failed", code="device_changed",
                message="The device changed while the update was being prepared, so nothing was written.",
                what_to_do="Check the device is the one you meant and try again.",
            )
            return

        self._phase(job, "preparing")
        plan = prepare_drive(self.ops, root, release.image_size)
        with self._lock:
            job.removed_sidecars = list(plan.removed)

        self._phase(job, "copying")
        copy_image(self.ops, root, image, replace=plan.image_present)
        copied_at = self.clock()

        self._phase(job, "restarting")
        outcome = self._await_device(job, release, reading, copied_at, held)
        if outcome is None:
            return
        found_root, final = outcome

        self._phase(job, "confirming")
        self._confirm(job, release, reading, found_root, final)

    def _partner_roots(self, job: UpdateJob, root: Path) -> list[Path]:
        ref = next((item for item in self._devices() if item.id == job.device_id), None)
        if ref is None:
            return []
        return [Path(path) for path in self._partners(ref) if Path(path) != root]

    def _acquire(self, job: UpdateJob, release: FirmwareRelease, from_file: Path | None) -> bytes:
        if from_file is not None:
            self._phase(job, "verifying")
            try:
                if from_file.stat().st_size > 1 << 20:
                    raise PackageError("too_large", "That file is larger than a firmware package should be.")
                data = from_file.read_bytes()
            except OSError as error:
                raise PackageError("unreadable", f"The package file could not be read ({error.strerror or error}).") from error
            image = verify_package(data, release)
            job.source = "file"
            return image
        cached = load_cached(self.state_dir, release)
        if cached is not None:
            self._phase(job, "verifying")
            job.source = "cache"
            return cached.image
        self._phase(job, "downloading")

        def progress(done: int, total: int | None) -> None:
            with self._lock:
                job.bytes_done, job.bytes_total = done, total
                job.updated_at = self.wall()
            self._notify()

        progress_hook: Progress = progress
        data = download_package(release, opener=self._opener, clock=self.clock, progress=progress_hook)
        self._phase(job, "verifying")
        image = verify_package(data, release)
        try:
            store_cached(self.state_dir, release, data)
        except OSError:
            pass
        job.source = "download"
        return image

    def _candidate_roots(self, original: Path, held: list[Path]) -> list[Path]:
        roots = [original]
        try:
            for root in self._find_roots():
                if Path(root) not in roots:
                    roots.append(Path(root))
        except OSError:
            pass
        return roots

    def _await_device(
        self,
        job: UpdateJob,
        release: FirmwareRelease,
        before: FirmwareReading,
        copied_at: float,
        held: list[Path],
    ) -> tuple[Path, FirmwareReading] | None:
        """Wait for the device to apply the file and come back as itself.

        Returns where it came back and what it reports, or ``None`` after
        finishing the job as failed or unconfirmed (the wait is bounded)."""
        original = Path(job.root)
        deadline = copied_at + self.restart_timeout
        gone_seen = False
        present: tuple[Path, FirmwareReading] | None = None
        while True:
            now = self.clock()
            present = None
            for root in self._candidate_roots(original, held):
                reading = self._read(root)
                if reading is not None and reading.identity.serial == job.serial:
                    present = (root, reading)
                    break
            if present is None:
                gone_seen = True
            else:
                found_root, found = present
                if found_root not in held:
                    # It came back under another name: hold that one too.
                    firmware_hold.acquire(found_root, HELD_REASON, seconds=HOLD_SECONDS)
                    held.append(found_root)
                if now - copied_at >= self.restart_min_wait and found.identity.version == release.version:
                    uptime_before, uptime_after = before.uptime_ms, found.uptime_ms
                    job.restarted = bool(
                        gone_seen
                        or (uptime_before is not None and uptime_after is not None and uptime_after < uptime_before)
                        or found.active_slot != before.active_slot
                    )
                    return present
            if now >= deadline:
                break
            self._sleep(POLL_SECONDS)
        if present is None:
            self._finish(
                job, "unconfirmed", code="no_return",
                message="The device's drive did not come back within two minutes, so JR-Bar cannot say "
                "whether the update was applied.",
                what_to_do="Unplug the device and plug it in again, then check its firmware "
                "(`jrbar firmware version`). It stays dark until it is back.",
            )
        elif present[1].identity.version == job.from_version:
            self._finish(
                job, "failed", code="not_applied",
                message=f"The device is back but still reports firmware {job.from_version}; "
                "it did not apply the update.",
                what_to_do="Unplug the device and plug it in again, check its firmware, and press Update "
                "again if it still reports the old version.",
            )
        else:
            self._finish(
                job, "failed", code="unexpected_version",
                message=f"The device reports firmware {present[1].identity.version}, not {release.version}.",
                what_to_do="Check the device's firmware with `jrbar firmware version` before trying again.",
            )
        return None

    def _confirm(
        self,
        job: UpdateJob,
        release: FirmwareRelease,
        before: FirmwareReading,
        root: Path,
        after: FirmwareReading,
    ) -> None:
        job.new_slot = after.active_slot
        # A Pro keeps the old image in the other slot. Say so only when its
        # own status shows that slot holding a valid image.
        if before.active_slot is not None and after.active_slot not in (None, before.active_slot):
            kept = after.slot(before.active_slot)
            if kept is not None and kept.has_image and kept.valid:
                job.previous_kept = {
                    "version": job.from_version,
                    "slot": before.active_slot,
                    "valid": True,
                    "firmware": kept.version,
                }
        job.colour_check = bool(balances_colour_itself(after.identity) and not balances_colour_itself(before.identity))
        report = cleanup_after_copy(self.ops, root)
        with self._lock:
            job.removed_sidecars = [*job.removed_sidecars, *report.removed]
        self._finish(job, "updated", message=f"The {job.name} now runs firmware {after.identity.version}.")
