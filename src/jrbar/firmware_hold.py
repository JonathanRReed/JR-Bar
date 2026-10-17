"""Holding every write to a device while its firmware is replaced.

A firmware update copies one file to the device's drive and then waits for the
device to apply it and restart. Anything else written to that drive in the
meantime (the LED program JR-Bar refreshes every few seconds, the keepalive
that stops the SD reader powering a Pro down) can corrupt the transfer or
land on a device that is half way through restarting.

``hold`` marks a drive as being updated. The one door every LED write goes
through (``device_writer``) and the keepalive look here first and refuse
while the mark stands. A hold always ends: the update releases it in a
``finally``, and each hold carries a deadline after which it no longer
counts, so a crashed or wedged update can never leave a device dark.
"""

from __future__ import annotations

import os
import re
import threading
import time
from collections.abc import Callable, Iterable
from contextlib import contextmanager
from dataclasses import dataclass
from pathlib import Path
from typing import Final

#: The longest a hold may last, whatever happens to the update that took it.
#: An update is about a minute; the restart wait alone is bounded at 120 s.
MAX_HOLD_SECONDS: Final = 600.0

Clock = Callable[[], float]


class DeviceHeldError(OSError):
    """A write was refused because the device is having its firmware updated.

    An ``OSError`` like an unmounted volume, so every caller that already
    copes with a device that is not there copes with this one."""


@dataclass(frozen=True, slots=True)
class Hold:
    root: str
    reason: str
    expires_at: float


_LOCK = threading.Lock()
_HOLDS: dict[str, Hold] = {}


def _key(root: Path | str) -> str:
    return os.path.abspath(os.fspath(root)).rstrip("/") or "/"


def _covers(hold_root: str, target: str) -> bool:
    """Whether a hold on ``hold_root`` covers ``target``: the drive itself, a
    file on it, or the same drive mounted again under macOS's collision name
    (``SidePulse`` coming back as ``SidePulse 1`` while the old mount point is
    still being released)."""
    if target == hold_root or target.startswith(hold_root + "/"):
        return True
    parent, _, name = hold_root.rpartition("/")
    head = target[len(parent) + 1 :] if target.startswith(parent + "/") else ""
    first = head.split("/", 1)[0]
    return bool(name) and re.fullmatch(re.escape(name) + r" \d+", first) is not None


def _live(now: float) -> dict[str, Hold]:
    """The holds still in force; expired ones are dropped. Call under the lock."""
    for key in [key for key, hold in _HOLDS.items() if hold.expires_at <= now]:
        del _HOLDS[key]
    return _HOLDS


def acquire(
    root: Path | str,
    reason: str,
    *,
    clock: Clock = time.monotonic,
    seconds: float = MAX_HOLD_SECONDS,
) -> Hold:
    now = clock()
    hold = Hold(_key(root), reason, now + max(1.0, min(float(seconds), MAX_HOLD_SECONDS)))
    with _LOCK:
        _live(now)[hold.root] = hold
    return hold


def release(root: Path | str) -> None:
    with _LOCK:
        _HOLDS.pop(_key(root), None)


@contextmanager
def hold(
    roots: Iterable[Path | str],
    reason: str,
    *,
    clock: Clock = time.monotonic,
    seconds: float = MAX_HOLD_SECONDS,
):
    """Hold these drives for the length of the ``with`` block, whatever ends it."""
    taken = [_key(root) for root in roots]
    try:
        for root in taken:
            acquire(root, reason, clock=clock, seconds=seconds)
        yield
    finally:
        for root in taken:
            release(root)


def held_reason(path: Path | str, *, clock: Clock = time.monotonic) -> str | None:
    """Why a write to ``path`` (a drive or a file on it) must wait, or ``None``."""
    target = _key(path)
    now = clock()
    with _LOCK:
        holds = _live(now)
        if not holds:
            return None
        for root, entry in holds.items():
            if _covers(root, target):
                return entry.reason
    return None


def any_held(*, clock: Clock = time.monotonic) -> bool:
    """Whether any drive is held; the hardware writer pauses on this."""
    with _LOCK:
        return bool(_live(clock()))


def require_not_held(path: Path | str, *, clock: Clock = time.monotonic) -> None:
    reason = held_reason(path, clock=clock)
    if reason is not None:
        raise DeviceHeldError(f"{reason}: {path}")


def clear_all() -> None:
    """Drop every hold (tests, and daemon shutdown)."""
    with _LOCK:
        _HOLDS.clear()
