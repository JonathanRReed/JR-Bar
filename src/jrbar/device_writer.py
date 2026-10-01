"""Every physical write to an LED device, and the refusals that guard it.

``write_led_program`` is the one door: it gates the program (the safety
compiler and the firmware parser), writes it to the device atomically, and
records how long the write took. The descriptor-level writer underneath
refuses a real volume while a test is running.
"""

from __future__ import annotations

import errno
import os
import secrets
import stat
import sys
import threading
import time
from collections import deque
from collections.abc import Iterable
from contextlib import contextmanager
from dataclasses import dataclass
from pathlib import Path
from statistics import median

DEFAULT_FILE_NAME = "LEDS.LED"
POWER_UP_FILE_NAME = "INIT.LED"
LED_FILE_NAMES = (DEFAULT_FILE_NAME, POWER_UP_FILE_NAME)
KNOWN_LED_FILE_NAMES = frozenset(name.upper() for name in LED_FILE_NAMES)
MAX_LED_BYTES = 512
MAX_LED_LINES = 20
MOUNT_ROOT = Path("/Volumes")
#: Until a device has been written a few times, the gap between preparing a
#: program and the device taking it is assumed to be this long.
DEFAULT_APPLY_LATENCY_MS = 20.0
DEVICE_NAME_HINTS = (
    "sidepulsepro",
    "sidepulsedot",
    # A first-batch Dot whose volume label is just "PulseDot".
    "pulsedot",
)


class DeviceWriteError(RuntimeError):
    pass


@dataclass(frozen=True)
class DeviceCandidate:
    root: Path
    target: Path
    reason: str


_FileIdentity = tuple[int, int]
_SCRATCH_ATTEMPTS = 32

# The moment the device took the bytes, per writing thread. The firmware
# starts a program's clock when it parses the file, and the best host-side
# estimate of that moment is the return of the fsync that pushed the bytes
# to it -- not the end of the readback after it, which is what the linked
# pair used to measure its skew from (jrbar.linked_sync).
_APPLIED = threading.local()


def _note_applied() -> None:
    _APPLIED.at = time.monotonic()


def take_applied_at() -> float | None:
    """The monotonic fsync-return of this thread's last device write, once."""
    value = getattr(_APPLIED, "at", None)
    _APPLIED.at = None
    return value


def _under_test_on_live_volume(path: Path) -> bool:
    """A test must never write a real device by accident.

    Fixtures name ``/Volumes/SidePulse`` for fake devices, and on a desk
    with a strip or Dot plugged in that path is live. ``JRBAR_TESTING`` is
    set for the whole test process and its children, so it still holds
    when pytest has unset ``PYTEST_CURRENT_TEST`` between tests. Fake
    devices belong in ``tmp_path`` or under ``JRBAR_TEST_VOLUME_ROOT``.
    """
    from .env import env_value

    in_sandbox = env_value("JRBAR_TESTING") == "1" or "PYTEST_CURRENT_TEST" in os.environ
    if not in_sandbox:
        return False
    return os.path.abspath(os.fspath(path)).startswith(str(MOUNT_ROOT) + "/")


def _write_device_file(
    text: str,
    *,
    device_path: Path | None = None,
    file_name: str = DEFAULT_FILE_NAME,
    dry_run: bool = False,
    preserve_existing_inode: bool = False,
) -> Path:
    """Publish one program to one device, atomically, and refuse a live
    volume while a test is running. The gates are ``write_led_program``'s."""
    program = normalize_led_text(text)
    validate_led_text(program)
    target = resolve_target_path(device_path=device_path, file_name=file_name)

    if dry_run:
        return target
    if type(preserve_existing_inode) is not bool:
        raise DeviceWriteError("invalid device write mode")
    if _under_test_on_live_volume(target):
        # An OSError, like an unmounted volume: every caller already handles
        # it, and a DeviceWriteError would count as a refusal on a device card.
        raise OSError(f"refusing a live device write under test: {target}")

    payload = program.encode("utf-8")
    with _device_parent(target) as (parent_descriptor, parent_identity):
        expected_target = _require_safe_leaf(
            target,
            parent_descriptor,
            target.name,
            parent_identity,
        )
        if preserve_existing_inode:
            if expected_target is not None:
                _fallback_in_place(
                    target=target,
                    parent_descriptor=parent_descriptor,
                    parent_identity=parent_identity,
                    expected_target=expected_target,
                    payload=payload,
                )
                return target
            # Fresh and test devices have no firmware-owned directory entry
            # yet. Create that first entry through the private atomic path;
            # subsequent live writes preserve the established identity.
        scratch_name: str | None = None
        scratch_identity: _FileIdentity | None = None
        try:
            scratch_name, descriptor, scratch_identity = _create_scratch(
                target,
                parent_descriptor,
                parent_identity,
            )
            try:
                _write_all(descriptor, payload)
                os.fsync(descriptor)
            finally:
                os.close(descriptor)
            _publish_scratch(
                target=target,
                parent_descriptor=parent_descriptor,
                parent_identity=parent_identity,
                expected_target=expected_target,
                scratch_name=scratch_name,
                scratch_identity=scratch_identity,
                payload=payload,
            )
            return target
        except OSError as error:
            _remove_owned_scratch(
                target,
                parent_descriptor,
                scratch_name,
                scratch_identity,
                parent_identity,
            )
            if error.errno != errno.ENOSPC:
                raise
            _fallback_in_place(
                target=target,
                parent_descriptor=parent_descriptor,
                parent_identity=parent_identity,
                expected_target=expected_target,
                payload=payload,
            )
            return target
        except BaseException:
            _remove_owned_scratch(
                target,
                parent_descriptor,
                scratch_name,
                scratch_identity,
                parent_identity,
            )
            raise


def _directory_open_flags() -> int:
    return (
        os.O_RDONLY
        | getattr(os, "O_DIRECTORY", 0)
        | getattr(os, "O_NOFOLLOW", 0)
        | getattr(os, "O_CLOEXEC", 0)
    )


def _file_open_flags() -> int:
    return getattr(os, "O_NOFOLLOW", 0) | getattr(os, "O_CLOEXEC", 0)


def _identity(info: os.stat_result) -> _FileIdentity:
    return info.st_dev, info.st_ino


def _require_directory(path: Path, info: os.stat_result) -> None:
    if stat.S_ISLNK(info.st_mode) or not stat.S_ISDIR(info.st_mode):
        raise OSError(f"refusing unsafe device directory: {path}")


def _require_regular_leaf(
    path: Path,
    info: os.stat_result,
    parent_identity: _FileIdentity,
) -> None:
    if stat.S_ISLNK(info.st_mode) or not stat.S_ISREG(info.st_mode):
        raise OSError(f"refusing unsafe device file: {path}")
    if info.st_nlink != 1:
        raise OSError(f"refusing multiply-linked device file: {path}")
    if info.st_dev != parent_identity[0]:
        raise OSError(f"device file is not on the intended mount: {path}")


@contextmanager
def _device_parent(target: Path):
    parent = target.parent
    descriptor = _open_directory_without_symlinks(parent)
    try:
        opened = os.fstat(descriptor)
        _require_directory(parent, opened)
        parent_identity = _identity(opened)
        _verify_parent_identity(parent, descriptor, parent_identity)
        yield descriptor, parent_identity
    finally:
        os.close(descriptor)


def _open_directory_without_symlinks(path: Path) -> int:
    """Open one absolute path without following user-controlled components."""
    absolute = Path(os.path.abspath(os.fspath(path)))
    anchor = absolute.anchor
    if not anchor:
        raise OSError(f"device directory has no trusted root: {path}")
    descriptor = os.open(anchor, _directory_open_flags())
    try:
        for component in absolute.parts[1:]:
            next_descriptor = _open_directory_component(
                absolute,
                component,
                descriptor,
            )
            os.close(descriptor)
            descriptor = next_descriptor
        return descriptor
    except BaseException:
        os.close(descriptor)
        raise


def _open_directory_component(
    path: Path,
    component: str,
    parent_descriptor: int,
) -> int:
    before = os.stat(component, dir_fd=parent_descriptor, follow_symlinks=False)
    follows_trusted_system_alias = stat.S_ISLNK(before.st_mode) and before.st_uid == 0
    if stat.S_ISLNK(before.st_mode) and not follows_trusted_system_alias:
        raise OSError(f"refusing symlink ancestor in device path: {path}")
    if not stat.S_ISLNK(before.st_mode):
        _require_directory(path, before)
    flags = _directory_open_flags()
    if follows_trusted_system_alias:
        flags &= ~getattr(os, "O_NOFOLLOW", 0)
    descriptor = os.open(component, flags, dir_fd=parent_descriptor)
    try:
        opened = os.fstat(descriptor)
        _require_directory(path, opened)
        current = os.stat(
            component,
            dir_fd=parent_descriptor,
            follow_symlinks=False,
        )
        if _identity(current) != _identity(before):
            raise OSError(f"device path component changed while opening: {path}")
        if not follows_trusted_system_alias and _identity(opened) != _identity(before):
            raise OSError(f"device path component changed while opening: {path}")
        return descriptor
    except BaseException:
        os.close(descriptor)
        raise


def _verify_parent_identity(
    parent: Path,
    parent_descriptor: int,
    expected: _FileIdentity,
) -> None:
    opened = os.fstat(parent_descriptor)
    _require_directory(parent, opened)
    current_descriptor = _open_directory_without_symlinks(parent)
    try:
        current = os.fstat(current_descriptor)
        _require_directory(parent, current)
    finally:
        os.close(current_descriptor)
    if _identity(current) != expected or _identity(opened) != expected:
        raise OSError(f"device directory changed during write: {parent}")


def _leaf_stat(parent_descriptor: int, name: str) -> os.stat_result | None:
    try:
        return os.stat(name, dir_fd=parent_descriptor, follow_symlinks=False)
    except FileNotFoundError:
        return None


def _require_safe_leaf(
    target: Path,
    parent_descriptor: int,
    name: str,
    parent_identity: _FileIdentity,
) -> _FileIdentity | None:
    info = _leaf_stat(parent_descriptor, name)
    if info is None:
        return None
    _require_regular_leaf(target, info, parent_identity)
    return _identity(info)


def _require_leaf_identity(
    target: Path,
    parent_descriptor: int,
    name: str,
    expected: _FileIdentity | None,
    parent_identity: _FileIdentity,
) -> None:
    current = _require_safe_leaf(
        target,
        parent_descriptor,
        name,
        parent_identity,
    )
    if current != expected:
        raise OSError(f"device file changed during write: {target}")


def _create_scratch(
    target: Path,
    parent_descriptor: int,
    parent_identity: _FileIdentity,
) -> tuple[str, int, _FileIdentity]:
    for _attempt in range(_SCRATCH_ATTEMPTS):
        # Eight-character base plus .TMP stays inside one FAT 8.3 entry.
        scratch_name = f"SP{secrets.token_hex(3).upper()}.TMP"
        try:
            descriptor = os.open(
                scratch_name,
                os.O_WRONLY | os.O_CREAT | os.O_EXCL | _file_open_flags(),
                0o600,
                dir_fd=parent_descriptor,
            )
        except FileExistsError:
            continue
        scratch_identity: _FileIdentity | None = None
        try:
            opened = os.fstat(descriptor)
            scratch_identity = _identity(opened)
            _require_regular_leaf(
                target.with_name(scratch_name),
                opened,
                parent_identity,
            )
            return scratch_name, descriptor, scratch_identity
        except BaseException:
            os.close(descriptor)
            current = _leaf_stat(parent_descriptor, scratch_name)
            if current is not None and _identity(current) == scratch_identity:
                os.unlink(scratch_name, dir_fd=parent_descriptor)
            raise
    raise OSError(errno.EEXIST, "could not allocate a unique device scratch file")


def _write_all(descriptor: int, payload: bytes) -> None:
    remaining = memoryview(payload)
    while remaining:
        written = os.write(descriptor, remaining)
        if written <= 0:
            raise OSError("device write made no progress")
        remaining = remaining[written:]


def _remove_owned_scratch(
    target: Path,
    parent_descriptor: int,
    scratch_name: str | None,
    scratch_identity: _FileIdentity | None,
    parent_identity: _FileIdentity,
) -> None:
    if scratch_name is None:
        return
    current = _require_safe_leaf(
        target.with_name(scratch_name),
        parent_descriptor,
        scratch_name,
        parent_identity,
    )
    if current is None:
        return
    if scratch_identity is None or current != scratch_identity:
        raise OSError("device scratch changed during write")
    os.unlink(scratch_name, dir_fd=parent_descriptor)


def _publish_scratch(
    *,
    target: Path,
    parent_descriptor: int,
    parent_identity: _FileIdentity,
    expected_target: _FileIdentity | None,
    scratch_name: str,
    scratch_identity: _FileIdentity,
    payload: bytes,
) -> None:
    _verify_parent_identity(target.parent, parent_descriptor, parent_identity)
    _require_leaf_identity(
        target,
        parent_descriptor,
        target.name,
        expected_target,
        parent_identity,
    )
    _require_leaf_identity(
        target.with_name(scratch_name),
        parent_descriptor,
        scratch_name,
        scratch_identity,
        parent_identity,
    )
    os.replace(
        scratch_name,
        target.name,
        src_dir_fd=parent_descriptor,
        dst_dir_fd=parent_descriptor,
    )
    _note_applied()
    _verify_parent_identity(target.parent, parent_descriptor, parent_identity)
    _require_leaf_identity(
        target,
        parent_descriptor,
        target.name,
        scratch_identity,
        parent_identity,
    )
    _verify_readback(
        target,
        parent_descriptor,
        parent_identity,
        scratch_identity,
        payload,
    )


def _verify_readback(
    target: Path,
    parent_descriptor: int,
    parent_identity: _FileIdentity,
    expected_target: _FileIdentity,
    payload: bytes,
) -> None:
    descriptor = os.open(
        target.name,
        os.O_RDONLY | _file_open_flags(),
        dir_fd=parent_descriptor,
    )
    try:
        opened = os.fstat(descriptor)
        _require_regular_leaf(target, opened, parent_identity)
        if _identity(opened) != expected_target:
            raise OSError(f"device file changed before readback: {target}")
        _require_leaf_identity(
            target,
            parent_descriptor,
            target.name,
            expected_target,
            parent_identity,
        )
        _require_exact_readback(descriptor, payload)
        _require_leaf_identity(
            target,
            parent_descriptor,
            target.name,
            expected_target,
            parent_identity,
        )
    finally:
        os.close(descriptor)


def _require_exact_readback(descriptor: int, payload: bytes) -> None:
    os.lseek(descriptor, 0, os.SEEK_SET)
    limit = len(payload) + 1
    readback = bytearray()
    while len(readback) < limit:
        requested = limit - len(readback)
        chunk = os.read(descriptor, requested)
        if len(chunk) > requested:
            raise DeviceWriteError("LED program readback exceeded its bound.")
        if not chunk:
            break
        readback.extend(chunk)
    if bytes(readback) != payload:
        raise DeviceWriteError("LED program readback did not match the write.")


def _fallback_in_place(
    *,
    target: Path,
    parent_descriptor: int,
    parent_identity: _FileIdentity,
    expected_target: _FileIdentity | None,
    payload: bytes,
) -> None:
    _verify_parent_identity(target.parent, parent_descriptor, parent_identity)
    _require_leaf_identity(
        target,
        parent_descriptor,
        target.name,
        expected_target,
        parent_identity,
    )
    flags = os.O_RDWR | _file_open_flags()
    if expected_target is None:
        flags |= os.O_CREAT | os.O_EXCL
    descriptor = os.open(
        target.name,
        flags,
        0o600,
        dir_fd=parent_descriptor,
    )
    created = expected_target is None
    opened_identity: _FileIdentity | None = None
    try:
        opened = os.fstat(descriptor)
        _require_regular_leaf(target, opened, parent_identity)
        opened_identity = _identity(opened)
        if expected_target is not None and opened_identity != expected_target:
            raise OSError(f"device file changed before fallback write: {target}")
        _require_leaf_identity(
            target,
            parent_descriptor,
            target.name,
            opened_identity,
            parent_identity,
        )
        os.ftruncate(descriptor, 0)
        _write_all(descriptor, payload)
        os.fsync(descriptor)
        _note_applied()
        _require_exact_readback(descriptor, payload)
        _verify_parent_identity(target.parent, parent_descriptor, parent_identity)
        _require_leaf_identity(
            target,
            parent_descriptor,
            target.name,
            opened_identity,
            parent_identity,
        )
    except BaseException:
        if created and opened_identity is not None:
            current = _require_safe_leaf(
                target,
                parent_descriptor,
                target.name,
                parent_identity,
            )
            if current == opened_identity:
                os.unlink(target.name, dir_fd=parent_descriptor)
            elif current is not None:
                raise OSError("created device file changed during failed fallback")
        raise
    finally:
        os.close(descriptor)


def normalize_led_text(text: str) -> str:
    return decode_simple_escapes(text)


def decode_simple_escapes(text: str) -> str:
    output: list[str] = []
    index = 0
    while index < len(text):
        char = text[index]
        if char != "\\" or index + 1 >= len(text):
            output.append(char)
            index += 1
            continue

        next_char = text[index + 1]
        if next_char == "n":
            output.append("\n")
            index += 2
        elif next_char == "r":
            output.append("\r")
            index += 2
        elif next_char == "t":
            output.append("\t")
            index += 2
        elif next_char == "\\":
            output.append("\\")
            index += 2
        else:
            output.append(char)
            index += 1
    return "".join(output)


def validate_led_text(text: str) -> None:
    if not text:
        raise DeviceWriteError("LED program is empty.")

    byte_count = len(text.encode("utf-8"))
    if byte_count > MAX_LED_BYTES:
        raise DeviceWriteError(
            f"LED program is {byte_count} bytes; max is {MAX_LED_BYTES}."
        )

    line_count = len(text.splitlines()) or 1
    if line_count > MAX_LED_LINES:
        raise DeviceWriteError(
            f"LED program has {line_count} lines; max is {MAX_LED_LINES}."
        )


def resolve_target_path(
    *,
    device_path: Path | None = None,
    file_name: str = DEFAULT_FILE_NAME,
) -> Path:
    file_name = _validated_file_name(file_name)
    if device_path is not None:
        return target_from_device_path(device_path.expanduser(), file_name)

    candidates = discover_devices(file_name=file_name)
    if not candidates:
        raise DeviceWriteError(
            "No SidePulse Pro or SidePulse Dot device found. "
            "Mount the device, or pass --device /Volumes/SidePulseDot."
        )
    if len(candidates) > 1:
        lines = "\n".join(f"  {candidate.root}" for candidate in candidates)
        raise DeviceWriteError(
            "Multiple possible devices found. Pass --device with one of:\n" + lines
        )
    return candidates[0].target


def target_from_device_path(path: Path, file_name: str) -> Path:
    file_name = _validated_file_name(file_name)
    if path.name in LED_FILE_NAMES:
        return path
    return path / file_name


def discover_devices(
    *,
    mount_root: Path = MOUNT_ROOT,
    file_name: str = DEFAULT_FILE_NAME,
) -> list[DeviceCandidate]:
    file_name = _validated_file_name(file_name)
    if not _is_unlinked_directory(mount_root):
        return []

    candidates: list[DeviceCandidate] = []
    for volume in sorted(iter_mounts(mount_root), key=lambda path: path.name.lower()):
        if not _is_unlinked_directory(mount_root) or not _is_unlinked_directory(
            volume
        ):
            continue
        target = target_from_device_path(volume, file_name)
        name_matches = is_device_name(volume.name)
        file_exists = path_exists(target)
        if not _is_unlinked_directory(mount_root) or not _is_unlinked_directory(
            volume
        ):
            continue
        if file_exists:
            # LEDS.LED alone is not an identity: any SD card or thumb
            # drive can carry one, and treating it as a device meant the
            # app writing status programs to somebody else's storage.
            # A recognized mount name or the firmware's own STATUS.TXT
            # telemetry file is what makes it a device.
            if name_matches or _has_firmware_marker(volume):
                candidates.append(
                    DeviceCandidate(volume, target, f"contains {target.name}")
                )
        elif name_matches or _has_firmware_marker(volume):
            candidates.append(DeviceCandidate(volume, target, "name matches device"))
    return candidates


def _has_firmware_marker(volume: Path) -> bool:
    """The firmware writes STATUS.TXT telemetry at boot; an arbitrary
    volume containing LEDS.LED does not have one."""
    return path_exists(volume / "STATUS.TXT")


def _validated_file_name(file_name: str) -> str:
    if not isinstance(file_name, str) or file_name not in LED_FILE_NAMES:
        allowed = ", ".join(LED_FILE_NAMES)
        raise DeviceWriteError(f"LED file name must be one of: {allowed}.")
    return file_name


def _is_unlinked_directory(path: Path) -> bool:
    try:
        info = path.lstat()
    except OSError:
        return False
    return not stat.S_ISLNK(info.st_mode) and stat.S_ISDIR(info.st_mode)


def iter_mounts(mount_root: Path) -> Iterable[Path]:
    if not _is_unlinked_directory(mount_root):
        return ()
    try:
        children = list(mount_root.iterdir())
    except OSError:
        return ()

    mounts: list[Path] = []
    for child in children:
        if child.name in {".timemachine", "Macintosh HD"}:
            continue
        if not _is_unlinked_directory(child):
            continue
        try:
            if not child.is_dir():
                continue
        except OSError:
            continue
        if _is_unlinked_directory(child):
            mounts.append(child)
    return mounts


def path_exists(path: Path) -> bool:
    try:
        return path.exists()
    except OSError:
        return False


def is_device_name(name: str) -> bool:
    normalized = "".join(char for char in name.lower() if char.isalnum())
    return any(hint in normalized for hint in DEVICE_NAME_HINTS)


@dataclass(frozen=True)
class WriteReceipt:
    """What one device write actually did, for the caller on the same thread.

    ``applied_at`` is the monotonic fsync return (the device's parse, as
    near as the host can see it); ``prepared_at`` the moment the program
    was final; ``program`` the exact bytes; ``timed`` the linked timing
    baked in (``linked_sync.TimedProgram``), when there was any."""

    target: Path
    prepared_at: float
    applied_at: float
    program: str
    timed: object | None = None


_RECEIPTS = threading.local()
_LATENCIES: dict[str, deque] = {}
_LATENCY_LOCK = threading.Lock()


def take_receipt() -> WriteReceipt | None:
    """This thread's last successful device write, once."""
    receipt = getattr(_RECEIPTS, "last", None)
    _RECEIPTS.last = None
    return receipt


def apply_latency_ms(target: Path) -> float:
    """The median prepare-to-apply gap of this device's recent writes."""
    with _LATENCY_LOCK:
        samples = list(_LATENCIES.get(str(Path(target).parent), ()))
    return float(median(samples)) if samples else DEFAULT_APPLY_LATENCY_MS


def _note_latency(target: Path, milliseconds: float) -> None:
    with _LATENCY_LOCK:
        _LATENCIES.setdefault(str(Path(target).parent), deque(maxlen=9)).append(
            max(0.0, float(milliseconds))
        )


def _led_count_for_target(target: Path) -> int:
    # One classification, not two: delegate to led_status's table-driven
    # rule so the write path can never disagree with the display path.
    # (Function-level import: led_status imports this module.)
    from .led_status import led_count_for_target

    return led_count_for_target(target)


def leds_addressed_beyond(text: str, led_count: int) -> tuple[int, ...]:
    """LED indices this program paints that the device does not have.

    Both spellings count: a colour list longer than the device
    ("color-list-too-long") and a named index past its last LED
    ("index-out-of-range"). The firmware parses either and then throws the
    extra away, and the animation validator agrees with it -- both are
    WARNINGS, not errors, so nothing on this path used to notice. That is
    how an eight-colour strip program reached a two-LED Dot and rendered as
    two black LEDs beside a lit strip. A program is written for one device
    or it is not written at all.
    """
    from .animation import ColorList, IndexedPaint, PaintStep, read_program

    try:
        animation, _problems = read_program(text, led_count=led_count)
    except Exception:
        return ()
    indices: set[int] = set()
    for step in animation.steps:
        if type(step) is not PaintStep:
            continue
        for segment in step.segments:
            if type(segment) is ColorList:
                indices.update(range(led_count, len(segment.colors)))
            elif type(segment) is IndexedPaint:
                indices.update(
                    int(index) for index, _color in segment.assignments if int(index) >= led_count
                )
    return tuple(sorted(indices))


def write_led_program(
    text: str,
    *,
    device_path: Path | None = None,
    file_name: str = DEFAULT_FILE_NAME,
    dry_run: bool = False,
    preserve_existing_inode: bool = False,
    timing=None,
) -> Path:
    """Gate, time, validate and write one program to one device.

    ``timing`` (a ``linked_sync.DeviceTiming``) is for a linked Dot: after
    the safety gate has judged the program in real milliseconds, it is
    rotated to the strip's phase and retimed for the Dot's clock, and the
    firmware parser still checks the result. The scaled text is never
    judged again -- the gate would clamp a 250 ms phase written as 243
    straight back to 250 and break the loop."""
    normalized = normalize_led_text(text)
    validate_led_text(normalized)
    target = resolve_target_path(
        device_path=device_path,
        file_name=file_name,
    )
    try:
        return _checked_write(
            normalized,
            target,
            file_name=file_name,
            dry_run=dry_run,
            preserve_existing_inode=preserve_existing_inode,
            timing=timing,
        )
    except DeviceWriteError as exc:
        if not dry_run:
            _note_health(target, refusal=str(exc))
        raise


def _note_health(
    target: Path,
    *,
    seconds: float | None = None,
    transformed: bool = False,
    refusal: str | None = None,
) -> None:
    """The device card's write-health line (jrbar.write_health). Never
    raises: a bookkeeping slip must not cost a write."""
    try:
        from . import write_health

        root = str(Path(target).parent)
        if refusal is not None:
            write_health.record_refusal(root, refusal)
        elif seconds is not None:
            write_health.record_write(root, seconds=seconds, transformed=transformed)
    except Exception:
        pass


def _checked_write(
    normalized: str,
    target: Path,
    *,
    file_name: str,
    dry_run: bool,
    preserve_existing_inode: bool,
    timing=None,
) -> Path:
    from .firmware_validation import (
        FirmwareValidationError,
        FirmwareValidationUnavailableError,
        require_firmware_program,
    )
    from .presentation_compiler import compile_presentation_program

    led_count = _led_count_for_target(target)
    stray = leds_addressed_beyond(normalized, led_count)
    if stray:
        # Refuse and say so, rather than writing bytes the device will
        # silently drop. Rendering for the wrong LED count is a caller bug
        # every time; a device left showing its previous program is a far
        # better outcome than one showing the wrong four-fifths of someone
        # else's animation.
        message = (
            f"LED program addresses LED{'s' if len(stray) > 1 else ''} "
            f"{', '.join(str(index) for index in stray)} on a {led_count}-LED device; "
            "render for this device's LED count."
        )
        print(f"jrbar: {message}", file=sys.stderr)
        raise DeviceWriteError(message)
    compiled = compile_presentation_program(normalized, led_count=led_count)
    if not compiled.accepted:
        raise DeviceWriteError(
            "LED program failed the presentation safety gate."
        )
    final_program = compiled.program
    timed = None
    prepared = time.monotonic()
    if timing is not None:
        from .linked_sync import apply_device_timing

        latency = getattr(timing, "latency_ms", None)
        timed = apply_device_timing(
            final_program,
            timing,
            led_count=led_count,
            now=prepared,
            latency_ms=apply_latency_ms(target) if latency is None else float(latency),
        )
        final_program = timed.program
    validate_led_text(final_program)
    if not dry_run:
        try:
            require_firmware_program(final_program, led_count=led_count)
        except FirmwareValidationUnavailableError as exc:
            raise DeviceWriteError(
                "The packaged firmware parser is unavailable; write refused."
            ) from exc
        except FirmwareValidationError as exc:
            raise DeviceWriteError(str(exc)) from exc
    started = time.monotonic()
    take_applied_at()
    written = _write_device_file(
        final_program,
        device_path=target,
        file_name=file_name,
        dry_run=dry_run,
        preserve_existing_inode=preserve_existing_inode,
    )
    if not dry_run:
        finished = time.monotonic()
        applied = take_applied_at() or finished
        _note_latency(target, (applied - prepared) * 1000.0)
        _note_health(target, seconds=finished - started, transformed=bool(compiled.reasons))
        _RECEIPTS.last = WriteReceipt(target, prepared, applied, final_program, timed)
    return written
