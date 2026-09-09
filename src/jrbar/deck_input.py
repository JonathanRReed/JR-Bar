"""Normalize optional accessory inputs without accepting executable payloads."""
from __future__ import annotations

import math
import re
from dataclasses import dataclass


@dataclass(frozen=True, slots=True)
class ControlInput:
    """Logical input; indices 20..23 are calibrated analog joystick sectors."""

    index: int
    kind: str
    value: float = 1.0

    def __post_init__(self) -> None:
        if (type(self.index) is not int or not 0 <= self.index < 256
                or self.kind not in {"press", "axis_sector", "rotate"}
                or type(self.value) not in (int, float) or not math.isfinite(self.value)
                or not -1 <= self.value <= 1):
            raise ValueError("invalid normalized control input")


class DeckInputRouter:
    def __init__(self, *, analog_enabled: bool = False) -> None:
        self._held: set[int] = set()
        self._sector: int | None = None
        self.analog_enabled = analog_enabled

    def reset(self) -> None:
        self._held.clear()
        self._sector = None

    def normalize(self, message: object) -> ControlInput | None:
        if type(message) is not dict or set(message) != {"method", "params"}:
            return None
        params = message["params"]
        if type(params) is not dict:
            return None
        if message["method"] == "v.oai.rad":
            if not self.analog_enabled or set(params) != {"a", "d"}:
                return None
            angle, distance = params["a"], params["d"]
            if any(type(value) not in (int, float) or not math.isfinite(value) or not 0 <= value <= 1
                   for value in (angle, distance)):
                return None
            # One action per excursion, never a flood of analog samples. The
            # sectors are explicitly numbered: physical orientation is calibrated
            # in the Input Check, not guessed from the firmware's angle origin.
            if distance <= 0.25:
                self._sector = None
            if distance < 0.6 or self._sector is not None:
                return None
            self._sector = int(((angle % 1.0) + 0.125) * 4) % 4
            return ControlInput(20 + self._sector, "axis_sector", float(distance))
        if message["method"] != "v.oai.hid" or set(params) - {"k", "act", "ag"}:
            return None
        key, action = params.get("k"), params.get("act")
        if (type(key) is not str or re.fullmatch(r"AG[01][0-9]", key) is None
                or type(action) is not int or action not in (0, 1)):
            return None
        index = int(key[2:])
        if action == 0:
            self._held.discard(index)
            return None
        if index in self._held:
            return None
        self._held.add(index)
        return ControlInput(index, "press")

    def accept(self, message: object) -> int | None:
        event = self.normalize(message)
        return event.index if event is not None else None
