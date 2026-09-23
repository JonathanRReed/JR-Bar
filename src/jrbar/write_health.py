"""Write health per device: why the strip looks wrong, not just "Connected".

The device card said "Connected" whether the last write landed in 30 ms,
took two seconds on a sleepy SD reader, or was refused outright by the
safety gate. The write path now notes, per device volume, how long the
last write took, how many programs the presentation compiler had to change
(lengthened timing, a clamped flash) and how many it refused, with the last
refusal's reason -- so a strip that looks wrong can say why.

Counts run since the daemon started; nothing here is persisted and no
program text is kept, only its fate.
"""

from __future__ import annotations

import threading
import time
from dataclasses import dataclass
from typing import Final

#: A refusal reason is a sentence for a device card, not a log.
MAX_REASON_CHARACTERS: Final = 160
#: Volumes come and go; a few dozen is every device anyone has plugged in.
MAX_DEVICES: Final = 32


@dataclass(slots=True)
class _Health:
    writes: int = 0
    transformed: int = 0
    refused: int = 0
    last_latency_ms: int | None = None
    last_write_at: float | None = None
    last_refusal: str | None = None
    last_refusal_at: float | None = None


_LOCK = threading.Lock()
_HEALTH: dict[str, _Health] = {}


def _entry(root: str) -> _Health:
    health = _HEALTH.get(root)
    if health is None:
        if len(_HEALTH) >= MAX_DEVICES:
            oldest = min(
                _HEALTH,
                key=lambda key: max(_HEALTH[key].last_write_at or 0.0, _HEALTH[key].last_refusal_at or 0.0),
            )
            del _HEALTH[oldest]
        health = _HEALTH[root] = _Health()
    return health


def record_write(root: str, *, seconds: float, transformed: bool, at: float | None = None) -> None:
    """A program reached the device: how long the write took, and whether
    the safety compiler had to change it on the way (a clamped cadence, a
    slowed flash -- not mere spelling)."""
    with _LOCK:
        health = _entry(str(root))
        health.writes += 1
        health.transformed += 1 if transformed else 0
        health.last_latency_ms = max(0, int(round(float(seconds) * 1000.0)))
        health.last_write_at = time.time() if at is None else float(at)


def record_refusal(root: str, reason: str, *, at: float | None = None) -> None:
    """A program never reached the device, and why."""
    text = " ".join(str(reason or "refused").split())[:MAX_REASON_CHARACTERS]
    with _LOCK:
        health = _entry(str(root))
        health.refused += 1
        health.last_refusal = text
        health.last_refusal_at = time.time() if at is None else float(at)


def health_document(root: str | None) -> dict[str, object] | None:
    """``state.devices[].write_health``, or None before the first write."""
    if not root:
        return None
    with _LOCK:
        health = _HEALTH.get(str(root))
        if health is None:
            return None
        # Failing now: the latest attempt never reached the device. This,
        # not the refusal count, is what the card changes on -- a device
        # that keeps failing retries every few seconds, and each retry is
        # the same news.
        failing = health.last_refusal_at is not None and (
            health.last_write_at is None or health.last_refusal_at >= health.last_write_at
        )
        return {
            "latency_ms": health.last_latency_ms,
            "writes": health.writes,
            "transformed": health.transformed,
            "refused": health.refused,
            "last_refusal": health.last_refusal,
            "last_refusal_at": health.last_refusal_at,
            "failing": failing,
        }


def reset() -> None:
    """Forget every device (tests, and a daemon restart in-process)."""
    with _LOCK:
        _HEALTH.clear()


__all__ = [
    "MAX_DEVICES",
    "MAX_REASON_CHARACTERS",
    "health_document",
    "record_refusal",
    "record_write",
    "reset",
]
