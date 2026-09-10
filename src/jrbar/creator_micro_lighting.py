"""Translate JR-Bar's shared state colours into explicit vendor light fields."""

from __future__ import annotations

import math
from dataclasses import dataclass

from .colors import ColorSettings


@dataclass(frozen=True, slots=True)
class CreatorMicroBrightnessProfile:
    device_id: str = "creator-micro"
    brightness: int = 102
    auto_brightness_enabled: bool = False


@dataclass(frozen=True, slots=True)
class CreatorMicroLightFrame:
    color: int
    brightness: float
    effect: int
    slots: tuple[tuple[int, int, float, int], ...] = ()

    def __post_init__(self) -> None:
        if type(self.slots) is not tuple or len(self.slots) > 20:
            raise ValueError("invalid light slots")
        indices = set()
        for index, color, brightness, effect in ((-1, self.color, self.brightness, self.effect), *self.slots):
            if (type(index) is not int or not -1 <= index < 20 or index in indices
                    or type(color) is not int or not 0 <= color <= 0xFFFFFF
                    or type(brightness) not in (int, float) or not math.isfinite(brightness)
                    or not 0 <= brightness <= 1 or type(effect) is not int or not 0 <= effect <= 6):
                raise ValueError("invalid light frame")
            indices.add(index)

    def params(self) -> list[dict[str, int | float]]:
        values = {index: (color, brightness, effect) for index, color, brightness, effect in self.slots}
        output = []
        for index in range(20):
            color, brightness, effect = values.get(index, (self.color, self.brightness, self.effect))
            output.append({"id": index, "c": color, "b": brightness, "e": effect, "s": 0.5, "sk": 0, "sa": 0})
        return output


def creator_micro_session_frame(board, *, colors: ColorSettings | None = None,
                                brightness: float = 0.4) -> CreatorMicroLightFrame:
    slots = []
    for slot in board.slots:
        state = slot.state if slot.state not in {"stale", "unavailable", "unknown", "ended_unconfirmed"} else "idle"
        frame = creator_micro_light_frame(state, colors=colors, brightness=brightness)
        slots.append((slot.index, frame.color, frame.brightness, frame.effect))
    # Unassigned and auxiliary AG slots stay off. An explicit global signal can
    # still replace this projection through the shared runtime signal policy.
    return CreatorMicroLightFrame(0, 0, 0, tuple(slots))


def creator_micro_light_frame(
    state: str, *, colors: ColorSettings | None = None, brightness: float = 0.4,
    idle_off: bool = True,
) -> CreatorMicroLightFrame:
    colors = colors if colors is not None else ColorSettings()
    # Every state that is not plainly "working", "done" or "idle" used to
    # land on "ask", so a key for a crashed session and a key for a session
    # holding a permission prompt were the same colour under your fingers.
    # The three that moved, and why:
    #
    #   failure          -> error. It broke. Nothing you type answers it.
    #   quota_exhausted  -> error. Work has STOPPED and no answer restarts
    #                       it; only time or a different plan does. That is
    #                       the "this is not going anywhere" family, not the
    #                       "press a key" one -- an Ask key you cannot
    #                       actually answer is the same lie as before.
    #   quota_warning    -> ask. Still running, still yours to steer: slow
    #                       down, switch model, or spend the rest knowingly.
    #                       A decision is wanted, which is what Ask means.
    modes = {
        "input_required": "ask", "failure": "error", "quota_exhausted": "error",
        "quota_warning": "ask", "reset": "done", "completed": "done",
        "active": "working", "idle": "idle",
    }
    if state not in modes or not math.isfinite(brightness) or not 0 <= brightness <= 1:
        raise ValueError("invalid Creator Micro light state")
    dark = (state == "idle" and idle_off) or brightness == 0
    key = modes[state]
    hex_value = colors.rendered_error_color() if key == "error" else colors.mode_color(key)
    color = int(hex_value.lstrip("#"), 16)
    return CreatorMicroLightFrame(color, 0 if dark else brightness, 0 if dark else 1)


def creator_micro_light_params(state: str) -> list[dict[str, int | float]]:
    return creator_micro_light_frame(state).params()
