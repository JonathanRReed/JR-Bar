"""One exact wall-clock boundary, fenced by generation.

The controller wakes once at the next moment the mailbox changes by itself,
such as a snoozed family coming due.  This schedule owns no timers, AppKit
objects, clocks or persistence.  It hands out a token for the deadline and
answers whether a callback carrying a token is still the current one and is
actually due.
"""

from __future__ import annotations

import math
from dataclasses import dataclass


@dataclass(frozen=True, slots=True)
class BoundaryToken:
    generation: int
    deadline_epoch: float


class ExactBoundarySchedule:
    """Generation-fence one exact wall-clock copy boundary."""

    def __init__(self) -> None:
        self._generation = 0
        self._token: BoundaryToken | None = None

    @property
    def deadline_epoch(self) -> float | None:
        return None if self._token is None else self._token.deadline_epoch

    def replace(self, deadline_epoch: float) -> BoundaryToken:
        if not (
            isinstance(deadline_epoch, (int, float))
            and not isinstance(deadline_epoch, bool)
            and math.isfinite(deadline_epoch)
            and deadline_epoch >= 0.0
        ):
            raise ValueError("invalid menu boundary")
        self._generation += 1
        self._token = BoundaryToken(self._generation, float(deadline_epoch))
        return self._token

    def clear(self) -> None:
        self._generation += 1
        self._token = None

    def callback_due(self, token: BoundaryToken, *, now_epoch: float) -> bool:
        if self._token != token or not math.isfinite(now_epoch):
            return False
        if now_epoch < token.deadline_epoch:
            return False
        self._token = None
        return True
