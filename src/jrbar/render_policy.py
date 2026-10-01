"""What the daemon still reads of the machine's render state.

The Swift app draws the Screen Bar, so the only thing left here is the
low-power and thermal reading the status-bar controller asks for.
"""

from __future__ import annotations

from dataclasses import dataclass


@dataclass(frozen=True, slots=True)
class RenderEnvironment:
    visible: bool = True
    display_asleep: bool = False
    low_power: bool = False
    thermal: str = "nominal"


_THERMAL_NAMES = {
    0: "nominal",
    1: "fair",
    2: "serious",
    3: "critical",
}


def runtime_render_environment(
    *,
    visible: bool,
    display_asleep: bool = False,
    process_info=None,
) -> RenderEnvironment:
    """Read public ProcessInfo power state with a fail-open fallback."""
    if process_info is None:
        try:
            from Foundation import NSProcessInfo

            process_info = NSProcessInfo.processInfo()
        except Exception:
            process_info = None

    low_power = False
    thermal = "nominal"
    if process_info is not None:
        try:
            low_power = bool(process_info.isLowPowerModeEnabled())
        except Exception:
            pass
        try:
            thermal = _THERMAL_NAMES.get(int(process_info.thermalState()), "nominal")
        except Exception:
            pass
    return RenderEnvironment(
        visible=bool(visible),
        display_asleep=bool(display_asleep),
        low_power=low_power,
        thermal=thermal,
    )
