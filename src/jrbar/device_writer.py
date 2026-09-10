"""Safety and firmware-validation facade for physical SidePulse writes."""

from __future__ import annotations

import sys as _sys
from pathlib import Path

from . import _device_writer_legacy as _legacy

_ORIGINAL_WRITE_LED_PROGRAM = _legacy.write_led_program


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
) -> Path:
    from .firmware_validation import (
        FirmwareValidationError,
        FirmwareValidationUnavailableError,
        require_firmware_program,
    )
    from .presentation_compiler import compile_presentation_program

    normalized = _legacy.normalize_led_text(text)
    _legacy.validate_led_text(normalized)
    target = _legacy.resolve_target_path(
        device_path=device_path,
        file_name=file_name,
    )
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
    return _ORIGINAL_WRITE_LED_PROGRAM(
        final_program,
        device_path=target,
        file_name=file_name,
        dry_run=dry_run,
        preserve_existing_inode=preserve_existing_inode,
    )


_legacy.write_led_program = write_led_program

for _name in dir(_legacy):
    if _name.startswith("__") or _name in globals():
        continue
    globals()[_name] = getattr(_legacy, _name)

__all__ = tuple(sorted(name for name in globals() if not name.startswith("_")))
