"""Check sync: a minute of aligned white flashes on the Pro and the Dot.

Nothing the daemon measures can prove the two devices LOOK in step: the
Dot's animation clock is inferred from its ``ticks`` counter, which is the
only millisecond clock it reports. So the person gets a test they can judge
by eye. Both devices flash white for 80 ms every two seconds for a minute:
the strip from its own write, the Dot rotated and retimed from the strip's
start like any linked write, and re-anchored by the closed loop if it
drifts. Before clock correction the two flashes came apart within about 40
seconds (about 53 ms a flash at 2.66% slow); in step, they stay one flash.

The check holds both devices the way a calibration preview does, so live
status writes wait; when it ends, both go straight back to the live
program (their dedupe identities no longer match it).
"""

from __future__ import annotations

import time
from typing import Any

from .linked_runtime import CHECK_SYNC_PROGRAM, CHECK_SYNC_SECONDS, LinkedEpoch

_MIN_SECONDS = 10.0
_MAX_SECONDS = 120.0


def start_check(runtime: Any, args: dict[str, Any]) -> dict[str, Any]:
    """``linked_sync_check {seconds?}``: write the flash to both devices and
    hold them for ``seconds`` (60 by default, 10-120)."""
    from . import core_runtime
    from ._led_status_legacy import LedDisplayState, apply_brightness, led_count_for_target
    from .core_server import CommandError
    from .dot_role import DotRole, normalize_dot_role

    legacy = runtime._core_legacy()
    try:
        seconds = float(args.get("seconds", CHECK_SYNC_SECONDS))
    except (TypeError, ValueError) as error:
        raise CommandError("invalid_args", "seconds must be a number") from error
    seconds = max(_MIN_SECONDS, min(_MAX_SECONDS, seconds))
    settings = runtime.settings
    if not bool(getattr(settings, "devices_linked", True)):
        raise CommandError("not_ready", "Pro and Dot are not linked.")
    if normalize_dot_role(getattr(settings, "dot_role", None)) != DotRole.EXTEND.value:
        raise CommandError("not_ready", "Check sync needs the Dot to mirror the strip.")
    dot = runtime._core_linked_dot_device()
    strip_id = runtime._core_followed_strip_id()
    devices = runtime.status_bar_devices(remember=False)
    strip = next((device for device in devices if device.device_id == strip_id), None)
    if dot is None or strip is None or led_count_for_target(strip.target) == 2:
        raise CommandError("not_ready", "Plug in both the SidePulse and the Dot to check sync.")
    held = runtime._core_held_preview_devices()
    if strip.device_id in held or dot.device_id in held:
        raise CommandError("busy", "a calibration preview holds a device")

    strip_controller = runtime.agent_controller_for_device(strip)
    program = apply_brightness(CHECK_SYNC_PROGRAM, strip_controller.brightness)
    try:
        write = strip_controller.sync_program(program, LedDisplayState.IDLE, force=True)
    except Exception as exc:
        raise CommandError("refused", f"the SidePulse refused the check: {exc}") from exc
    if write.error is not None or not write.changed:
        raise CommandError("refused", f"the SidePulse refused the check: {write.error}")
    started = write.applied_at or time.monotonic()
    anchor = core_runtime.mono_to_epoch(started) or time.time()
    link = runtime._core_linked
    link.note_epoch(
        LinkedEpoch(
            anchor=float(started),
            anchor_epoch=float(anchor),
            program=write.nominal_program or program,
            state=write.state,
            leds=led_count_for_target(strip.target),
            device_id=strip.device_id,
        )
    )
    runtime._core_linked_pro_program = (write.nominal_program or program, write.state)
    runtime._core_hardware_anchor[strip.device_id] = anchor
    dot_write = _write_dot(runtime, dot, reason="check")
    until = time.monotonic() + seconds
    link.check_until = until
    link.check_started_epoch = anchor
    runtime._core_previews["hardware"] = core_runtime._Preview(
        write.program, until, anchor, (strip.device_id,), held=True
    )
    runtime._core_previews["dot"] = core_runtime._Preview(
        getattr(dot_write, "program", "") or CHECK_SYNC_PROGRAM, until, anchor, (dot.device_id,), held=True
    )
    legacy.log_status_bar(f"linked sync: check started for {int(seconds)} s")
    runtime._core_publish_lights()
    return {"until": time.time() + seconds, "devices": [strip.device_id, dot.device_id]}


def _write_dot(runtime: Any, dot: Any, *, reason: str):
    from ._led_status_legacy import LedDisplayState

    controller = runtime.agent_controller_for_device(dot)
    plan = runtime._core_dot_plan(controller, device=dot)
    if plan is None:
        return None
    return runtime._core_linked_write_dot(controller, plan, dot, LedDisplayState.IDLE, force=True, reason=reason)


def reanchor_check(runtime: Any, reason: str) -> None:
    """The closed loop's re-anchor during a check: the Dot is held by the
    check, so the ordinary write path would refuse it; write it here."""
    dot = runtime._core_linked_dot_device()
    if dot is None:
        return
    try:
        _write_dot(runtime, dot, reason="check" if reason == "reanchor" else reason)
    except Exception:
        return


__all__ = ["reanchor_check", "start_check"]
