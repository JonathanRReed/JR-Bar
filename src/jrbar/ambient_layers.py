"""Short colour layers that keep the underlying animation's geometry."""

from __future__ import annotations

import re

from .led_status import LedDisplayState
from .motion_shapes import mix, shade

LAYER_SECONDS = 2.0
_COLOR = re.compile(r"#[0-9a-fA-F]{6}\b")


def compose_ambient_layer(program, state, ambient):
    """Tint painted colours, retaining every position, duration and repeat.

    The overlay scales with the base's light, so a dark gap stays dark and
    heartbeat's two beats and KITT's moving eye remain visible. The daemon
    restores the untinted program at the layer deadline, even when the
    device's normal write dedupe window has not elapsed.
    """
    if ambient is None or state in {LedDisplayState.ASK, LedDisplayState.FAILED}:
        return program
    match = _COLOR.search(ambient.nominal_static_fallback_program)
    if match is None:
        return program
    color = match.group()

    def tint(match):
        base = match.group()
        level = max(int(base[index:index + 2], 16) for index in (1, 3, 5)) / 255
        return mix(base, shade(color, level), 0.28)

    return _COLOR.sub(tint, program)
