"""Safety and firmware-validation facade for physical SidePulse writes."""

from __future__ import annotations

import sys as _sys
import threading as _threading
import time as _time
from collections import deque as _deque
from dataclasses import dataclass as _dataclass
from pathlib import Path
from statistics import median as _median

from . import _device_writer_legacy as _legacy

_ORIGINAL_WRITE_LED_PROGRAM = _legacy.write_led_program

#: Until a device has been written a few times, the gap between preparing a
#: program and the device taking it is assumed to be this long.
DEFAULT_APPLY_LATENCY_MS = 20.0


@_dataclass(frozen=True)
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


_RECEIPTS = _threading.local()
_LATENCIES: dict[str, _deque] = {}
_LATENCY_LOCK = _threading.Lock()


def take_receipt() -> WriteReceipt | None:
    """This thread's last successful device write, once."""
    receipt = getattr(_RECEIPTS, "last", None)
    _RECEIPTS.last = None
    return receipt


def apply_latency_ms(target: Path) -> float:
    """The median prepare-to-apply gap of this device's recent writes."""
    with _LATENCY_LOCK:
        samples = list(_LATENCIES.get(str(Path(target).parent), ()))
    return float(_median(samples)) if samples else DEFAULT_APPLY_LATENCY_MS


def _note_latency(target: Path, milliseconds: float) -> None:
    with _LATENCY_LOCK:
        _LATENCIES.setdefault(str(Path(target).parent), _deque(maxlen=9)).append(
            max(0.0, float(milliseconds))
        )


def _led_count_for_target(target: Path) -> int:
    # One classification, not two: delegate to led_status's table-driven
    # rule so the write path can never disagree with the display path.
    # (Function-level import: _led_status_legacy imports this module.)
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
    file_name: str = _legacy.DEFAULT_FILE_NAME,
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
    normalized = _legacy.normalize_led_text(text)
    _legacy.validate_led_text(normalized)
    target = _legacy.resolve_target_path(
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
    except _legacy.DeviceWriteError as exc:
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
        print(f"jrbar: {message}", file=_sys.stderr)
        raise _legacy.DeviceWriteError(message)
    compiled = compile_presentation_program(normalized, led_count=led_count)
    if not compiled.accepted:
        raise _legacy.DeviceWriteError(
            "LED program failed the presentation safety gate."
        )
    final_program = compiled.program
    timed = None
    prepared = _time.monotonic()
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
    _legacy.validate_led_text(final_program)
    if not dry_run:
        try:
            require_firmware_program(final_program, led_count=led_count)
        except FirmwareValidationUnavailableError as exc:
            raise _legacy.DeviceWriteError(
                "The packaged firmware parser is unavailable; write refused."
            ) from exc
        except FirmwareValidationError as exc:
            raise _legacy.DeviceWriteError(str(exc)) from exc
    started = _time.monotonic()
    _legacy.take_applied_at()
    written = _ORIGINAL_WRITE_LED_PROGRAM(
        final_program,
        device_path=target,
        file_name=file_name,
        dry_run=dry_run,
        preserve_existing_inode=preserve_existing_inode,
    )
    if not dry_run:
        finished = _time.monotonic()
        applied = _legacy.take_applied_at() or finished
        _note_latency(target, (applied - prepared) * 1000.0)
        _note_health(target, seconds=finished - started, transformed=bool(compiled.reasons))
        _RECEIPTS.last = WriteReceipt(target, prepared, applied, final_program, timed)
    return written


_legacy.write_led_program = write_led_program

for _name in dir(_legacy):
    if _name.startswith("__") or _name in globals():
        continue
    globals()[_name] = getattr(_legacy, _name)

__all__ = tuple(sorted(name for name in globals() if not name.startswith("_")))
