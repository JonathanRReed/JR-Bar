"""``jrbar firmware upgrade``: the same update the Devices page offers, from a
terminal.

It asks the running JR-Bar to do the update (so the monitor holds its LED
writes while the device restarts) and watches the job. With JR-Bar not
running there is nothing else writing to the device, so it runs the update
itself with the same code. Either way nothing is fetched or written until the
person has read what will happen and said yes (``--yes`` is that answer, given
in advance).
"""

from __future__ import annotations

import sys
import time
from collections.abc import Callable, Iterable
from pathlib import Path
from typing import Any, Protocol, TextIO

from .device_firmware import PACKAGE_HOST

EXIT_OK = 0
EXIT_FAILED = 1
EXIT_USAGE = 2
EXIT_UNCONFIRMED = 3

POLL_SECONDS = 1.0
#: Nothing in a job takes longer than this; the CLI stops watching then.
WATCH_LIMIT_SECONDS = 600.0


class BackendError(Exception):
    """The monitor or the updater refused; the message is for the person."""

    def __init__(self, message: str) -> None:
        super().__init__(message)
        self.message = message


class Backend(Protocol):
    name: str

    def status(self) -> dict[str, Any]: ...

    def start(self, device_id: str, package: Path | None) -> dict[str, Any]: ...

    def job(self) -> dict[str, Any] | None: ...


class LocalBackend:
    """Runs the update in this process (JR-Bar is not running)."""

    name = "this terminal"

    def __init__(self, service) -> None:
        self.service = service

    def status(self) -> dict[str, Any]:
        return self.service.status_document()

    def start(self, device_id: str, package: Path | None) -> dict[str, Any]:
        from .firmware_update import UpdateRefused

        try:
            return self.service.start_update(device_id, confirm=True, from_file=package).to_document()
        except UpdateRefused as refusal:
            raise BackendError(refusal.message) from None

    def job(self) -> dict[str, Any] | None:
        return self.service.job_document()


class DaemonBackend:
    """Asks the running JR-Bar over its socket."""

    name = "JR-Bar"

    def __init__(self, connection) -> None:
        self.connection = connection

    def _ask(self, name: str, args: dict[str, Any]) -> dict[str, Any]:
        from .cli_control import ControlError

        try:
            return self.connection.command(name, args)
        except ControlError as error:
            text = str(error)
            raise BackendError(text.split(": ", 1)[1] if text.startswith(name + ": ") else text) from None

    def status(self) -> dict[str, Any]:
        return self._ask("firmware_status", {})

    def start(self, device_id: str, package: Path | None) -> dict[str, Any]:
        args: dict[str, Any] = {"device": device_id, "confirm": True}
        if package is not None:
            args["package"] = str(package)
        reply = self._ask("firmware_update", args)
        job = reply.get("job")
        return job if isinstance(job, dict) else {}

    def job(self) -> dict[str, Any] | None:
        job = self._ask("firmware_status", {}).get("job")
        return job if isinstance(job, dict) else None


def match_device(devices: Iterable[dict[str, Any]], spec: str) -> list[dict[str, Any]]:
    """The devices a ``--device`` argument names: by id, serial, drive path or
    drive name, ignoring case."""
    wanted = spec.strip().lower().rstrip("/")
    found = []
    for device in devices:
        names = {
            str(device.get("id") or "").lower(),
            str(device.get("serial") or "").lower(),
            str(device.get("root") or "").lower().rstrip("/"),
            Path(str(device.get("root") or "")).name.lower(),
            str(device.get("name") or "").lower(),
        }
        names.discard("")
        if wanted in names:
            found.append(device)
    return found


def _catalog_entry(status: dict[str, Any], model: str | None) -> dict[str, Any] | None:
    return next((item for item in status.get("catalog") or [] if item.get("model") == model), None)


def describe_plan(device: dict[str, Any], entry: dict[str, Any], package: Path | None) -> list[str]:
    """What will happen, in plain sentences, before anything does."""
    name = device.get("name") or "the device"
    root = device.get("root") or "its drive"
    version, latest = device.get("version"), entry.get("version")
    package_info = entry.get("package") or {}
    kilobytes = max(1, round(int(package_info.get("bytes") or 0) / 1024))
    if package is not None:
        fetch = f"Read the package from {package} (checked against the hashes pinned in JR-Bar)."
    elif package_info.get("cached"):
        fetch = "Use the package already on this Mac (checked again against the pinned hashes). Nothing is downloaded."
    else:
        fetch = (
            f"Download the package ({kilobytes} KB) from {package_info.get('host') or PACKAGE_HOST} over https, "
            f"once, and check it against the hashes pinned in JR-Bar before it is opened."
        )
    lines = [
        f"{name}: firmware {version} -> {latest}",
        "",
        "This will:",
        f"  1. {fetch}",
        f"  2. Hold every LED write to {name} (and its linked partner) so the lights go still for about a minute.",
        f"  3. Copy one file, FIRMWARE.BIN, to the top of {root}, after clearing the hidden macOS ._ files "
        "that would stop it fitting. Nothing else on the drive is changed.",
        "  4. Leave the device alone for at least 10 seconds while it applies the update and restarts,",
        "     then read its STATUS.TXT and check it reports the new version.",
        "",
        "The device applies an update only from a complete, valid file, so if anything fails it stays on "
        f"{version}.",
    ]
    other = device.get("other_slot")
    if device.get("model") == "pro" and isinstance(other, dict) and other.get("name"):
        lines.append(
            f"A Pro keeps its previous firmware in the other slot (slot {other['name']}); "
            "JR-Bar writes no rollback."
        )
    lines.append("Keep the Mac awake and plugged in.")
    return lines


def _line(job: dict[str, Any]) -> str:
    label = job.get("phase_label") or job.get("phase") or "working"
    download = job.get("download")
    if isinstance(download, dict) and download.get("bytes"):
        total = download.get("total")
        label += f" ({download['bytes'] // 1024} of {total // 1024} KB)" if total else f" ({download['bytes'] // 1024} KB)"
    return label


def watch(
    backend: Backend,
    *,
    out: TextIO,
    sleep: Callable[[float], None] = time.sleep,
    clock: Callable[[], float] = time.monotonic,
) -> dict[str, Any] | None:
    """Print each phase as it starts until the job ends; the finished job."""
    started = clock()
    last = ""
    job: dict[str, Any] | None = None
    while clock() - started < WATCH_LIMIT_SECONDS:
        job = backend.job()
        if job is not None:
            line = _line(job)
            if line != last and job.get("outcome") is None:
                print(f"  {line}...", file=out)
                last = line
            if job.get("outcome") is not None:
                return job
        sleep(POLL_SECONDS)
    return job


def run_upgrade_command(
    device_spec: str | None,
    package: Path | None,
    *,
    assume_yes: bool,
    backend: Backend,
    out: TextIO | None = None,
    err: TextIO | None = None,
    read_line: Callable[[str], str] | None = None,
    interactive: bool | None = None,
    sleep: Callable[[float], None] = time.sleep,
    clock: Callable[[], float] = time.monotonic,
) -> int:
    out = out or sys.stdout
    err = err or sys.stderr
    try:
        status = backend.status()
    except BackendError as error:
        print(f"jrbar firmware: {error.message}", file=err)
        return EXIT_FAILED
    devices = [item for item in status.get("devices") or [] if isinstance(item, dict)]
    if not devices:
        print("jrbar firmware: no SidePulse is connected.", file=err)
        return EXIT_FAILED
    if device_spec is not None:
        chosen = match_device(devices, device_spec)
        if not chosen:
            print(f"jrbar firmware: no connected device matches {device_spec!r}.", file=err)
            return EXIT_USAGE
        if len(chosen) > 1:
            print("jrbar firmware: that matches more than one device; use its serial.", file=err)
            return EXIT_USAGE
    else:
        chosen = [item for item in devices if item.get("update_available")]
        if not chosen:
            for item in devices:
                print(f"{item.get('name')}: firmware {item.get('version')}, up to date", file=out)
            return EXIT_OK
        if len(chosen) > 1:
            print("More than one device has an update; say which with --device:", file=err)
            for item in chosen:
                print(f"  {item.get('serial') or item.get('id')}  {item.get('name')}  {item.get('version')}", file=err)
            return EXIT_USAGE
    device = chosen[0]
    if not device.get("update_available"):
        print(f"{device.get('name')}: firmware {device.get('version')}, up to date. Nothing to do.", file=out)
        return EXIT_OK
    why = device.get("why_not")
    if not device.get("can_update"):
        message = why.get("message") if isinstance(why, dict) else "it cannot be updated right now."
        print(f"jrbar firmware: {device.get('name')} cannot be updated: {message}", file=err)
        return EXIT_FAILED
    entry = _catalog_entry(status, device.get("model"))
    if entry is None:
        print("jrbar firmware: JR-Bar has no firmware for this model.", file=err)
        return EXIT_FAILED

    for line in describe_plan(device, entry, package):
        print(line, file=out)
    print("", file=out)
    if not assume_yes:
        tty = sys.stdin.isatty() if interactive is None else interactive
        if not tty:
            print("jrbar firmware: not a terminal, so nothing was done. Run it again with --yes to go ahead.", file=err)
            return EXIT_USAGE
        answer = (read_line or input)("Type yes to update: ").strip().lower()
        if answer not in ("y", "yes"):
            print("Nothing was done.", file=out)
            return EXIT_OK
    try:
        backend.start(str(device.get("id")), package)
    except BackendError as error:
        print(f"jrbar firmware: {error.message}", file=err)
        return EXIT_FAILED
    try:
        job = watch(backend, out=out, sleep=sleep, clock=clock)
    except KeyboardInterrupt:
        print(
            f"\nStopped watching. The update keeps running in {backend.name}; "
            "check the result with `jrbar firmware version`.",
            file=out,
        )
        return EXIT_UNCONFIRMED
    return finish(job, device, out=out, err=err)


def finish(job: dict[str, Any] | None, device: dict[str, Any], *, out: TextIO, err: TextIO) -> int:
    if job is None or job.get("outcome") is None:
        print("jrbar firmware: still running. Check the result with `jrbar firmware version`.", file=err)
        return EXIT_UNCONFIRMED
    outcome = job["outcome"]
    if outcome == "updated":
        print(f"\n{job.get('message')}", file=out)
        previous = job.get("previous_firmware")
        if isinstance(previous, dict):
            print(
                f"Its previous firmware ({previous.get('version')}) is kept in slot {previous.get('slot')}.",
                file=out,
            )
        if job.get("colour_check"):
            print(
                "This firmware balances colour itself. If your colour calibration was tuned for the old "
                "firmware, check it again in Settings > Devices & Lighting.",
                file=out,
            )
        return EXIT_OK
    stream = out if outcome == "unconfirmed" else err
    print(f"\n{job.get('message')}", file=stream)
    if job.get("what_to_do"):
        print(job["what_to_do"], file=stream)
    return EXIT_UNCONFIRMED if outcome == "unconfirmed" else EXIT_FAILED


def local_service(state_dir: Path | None = None):
    """A ``FirmwareService`` over the Mac's real mounted devices."""
    from .device_writer import MOUNT_ROOT, discover_devices
    from .firmware_update import DeviceRef, FirmwareService
    from .state_paths import default_state_dir

    def refs() -> list:
        found = []
        for candidate in discover_devices(mount_root=MOUNT_ROOT):
            found.append(
                DeviceRef(id=str(candidate.root), name=candidate.root.name, root=candidate.root, connected=True)
            )
        return found

    def battery():
        try:
            from .battery import read_battery_snapshot

            return read_battery_snapshot()
        except Exception:
            return None

    return FirmwareService(
        state_dir=state_dir or default_state_dir(),
        devices=refs,
        find_roots=lambda: [candidate.root for candidate in discover_devices(mount_root=MOUNT_ROOT)],
        partners=lambda ref: [other.root for other in refs() if other.id != ref.id],
        battery=battery,
    )


def run_from_args(
    device: str | None,
    package: Path | None,
    yes: bool,
    *,
    connect: Callable[[], Any] | None = None,
    local: Callable[[], Any] = local_service,
) -> int:
    """The CLI entry: JR-Bar if it is running, else this process."""
    from .cli_control import EXIT_NO_CORE, ControlError, CoreConnection, default_socket_path

    package = Path(package).expanduser().resolve() if package is not None else None
    connection = (connect or (lambda: CoreConnection(default_socket_path())))()
    try:
        with connection as core:
            return run_upgrade_command(device, package, assume_yes=yes, backend=DaemonBackend(core))
    except ControlError as error:
        if error.status != EXIT_NO_CORE:
            print(f"jrbar firmware: {error}", file=sys.stderr)
            return EXIT_FAILED
    return run_upgrade_command(device, package, assume_yes=yes, backend=LocalBackend(local()))
