"""The eject guard, as the Devices page sees it and changes it.

``eject_guard`` answers what launchd really has (``sd_eject_guard_status``)
next to the SidePulse that is mounted now, so the page can say "installed,
never started" instead of "installed". ``protect_sidepulse`` reinstalls the
guard for the mounted SidePulse's volume, and runs only when the person
clicks "Protect this SidePulse": nothing in the daemon calls it on its own.
"""

from __future__ import annotations

from pathlib import Path
from typing import Any


def _mounted_strip(runtime: Any):
    """The first connected SidePulse Pro (an SD-card-reader device)."""
    from ._led_status_legacy import led_count_for_target

    legacy = runtime._core_legacy()
    for device in runtime.status_bar_devices(remember=False):
        if device.device_id == legacy.VIRTUAL_DEVICE_ID or not device.connected:
            continue
        if led_count_for_target(device.target) != 2:
            return device
    return None


def status(runtime: Any, args: dict[str, Any]) -> dict[str, Any]:
    del args
    from .sd_eject_guard_launch import mounted_volume_uuid, sd_eject_guard_status

    guard = sd_eject_guard_status()
    document = guard.to_dict()
    strip = _mounted_strip(runtime)
    mounted = None
    if strip is not None:
        mounted = mounted_volume_uuid(Path(strip.target).parent)
    document["mounted_volume_uuid"] = mounted
    document["mounted_name"] = strip.name if strip is not None else None
    document["protects_mounted"] = bool(
        guard.protects and mounted is not None and guard.volume_uuid == mounted
    )
    return document


def protect(runtime: Any, args: dict[str, Any]) -> dict[str, Any]:
    from .core_server import CommandError
    from .sd_eject_guard_launch import SdEjectGuardInstallError, protect_mounted_sidepulse

    strip = _mounted_strip(runtime)
    if strip is None:
        raise CommandError("not_found", "No SidePulse is mounted to protect.")
    try:
        result = protect_mounted_sidepulse(Path(strip.target).parent)
    except SdEjectGuardInstallError as error:
        raise CommandError("refused", str(error)) from error
    except Exception as error:
        raise CommandError("refused", f"could not install the eject guard: {error}") from error
    runtime._core_legacy().log_status_bar(
        f"eject guard: protected {strip.name} (started={result.started})"
    )
    return status(runtime, args)


__all__ = ["protect", "status"]
