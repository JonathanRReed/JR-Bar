"""One edge transform for compact accessory-independent controls.

Adapted conceptually from Codenotch's stack-space layout, not its UI code.
All rectangles are in a top-left-origin, flipped native view.
"""
from __future__ import annotations

import math
from dataclasses import dataclass


@dataclass(frozen=True, slots=True)
class SurfacePlacement:
    edge: str
    length: float
    depth: float

    def __post_init__(self):
        if self.edge not in {"left", "right", "top", "bottom"}:
            raise ValueError("unknown display edge")
        if any(type(value) not in (int, float) or not math.isfinite(value) or value <= 0
               for value in (self.length, self.depth)):
            raise ValueError("invalid surface dimensions")

    @property
    def size(self) -> tuple[float, float]:
        return (self.depth, self.length) if self.edge in {"left", "right"} else (self.length, self.depth)

    def rect(self, along: float, across: float, length: float, depth: float) -> tuple:
        if (not all(math.isfinite(value) for value in (along, across, length, depth))
                or min(along, across, length, depth) < 0
                or along + length > self.length or across + depth > self.depth):
            raise ValueError("rectangle is outside the surface")
        if self.edge == "left":
            return ((across, along), (depth, length))
        if self.edge == "right":
            return ((self.depth - across - depth, along), (depth, length))
        if self.edge == "top":
            return ((along, across), (length, depth))
        return ((along, self.depth - across - depth), (length, depth))

    def inverse(self, x: float, y: float) -> tuple[float, float]:
        if not all(type(value) in (int, float) and math.isfinite(value) for value in (x, y)):
            raise ValueError("invalid surface point")
        if self.edge == "left":
            return y, x
        if self.edge == "right":
            return y, self.depth - x
        if self.edge == "top":
            return x, y
        return x, self.depth - y

    def frame(self, visible_frame: tuple) -> tuple:
        (x, y), (width, height) = visible_frame
        if not all(type(value) in (int, float) and math.isfinite(value) for value in (x, y, width, height)):
            raise ValueError("invalid display frame")
        own_width, own_height = self.size
        if own_width > width or own_height > height:
            raise ValueError("display is too small for this surface")
        if self.edge == "left":
            return ((x, y + (height - own_height) / 2), self.size)
        if self.edge == "right":
            return ((x + width - own_width, y + (height - own_height) / 2), self.size)
        if self.edge == "top":
            return ((x + (width - own_width) / 2, y + height - own_height), self.size)
        return ((x + (width - own_width) / 2, y), self.size)
