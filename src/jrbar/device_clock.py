"""How fast each SidePulse's own clock runs, read fresh from the device.

A linked Dot only stays on the strip's beat if its program is written for
the clock it actually has. The Pro's clock matches the Mac's to about 0.02%;
the first Dot's ``ticks`` counter advances about 973 ms for every 1000 ms of
real time, so after a perfect simultaneous start it falls behind by about
27 ms a second (``research/hardware-sync.md``). Nothing here guesses that
number for good: each device's rate is measured from its own STATUS.TXT,
kept per device (another Dot has its own), and persisted, so a restart does
not start from nothing.

Two hard facts shape the reads:

* the host caches STATUS.TXT. Plain reads, ``F_NOCACHE`` and new processes
  all returned the same ``uptime_ms`` for ten minutes and more. Mapping the
  file, ``msync(MS_INVALIDATE)`` and then ``pread`` forces a real device
  read: about half a millisecond on the Pro and five on the Dot;
* a device's USB I/O can stall for seconds (the keepalive touch once hung
  past 2 s). Every read runs on its own worker thread and is abandoned after
  half a second, and a read still stuck from before makes the next one
  answer ``None`` at once rather than pile up.

Reads also cost the Dot ticks -- four a second made it 3.8% slow instead of
2.7% -- so callers sample sparsely (``linked_sync.SYNC_INTERVAL_SECONDS``).
"""

from __future__ import annotations

import ctypes
import ctypes.util
import json
import math
import os
import threading
import time
from collections import deque
from collections.abc import Callable
from dataclasses import dataclass, field
from pathlib import Path
from typing import Final

from .linked_sync import MAX_CLOCK_RATE, MIN_CLOCK_RATE, WARM_START_DOT_RATE

STATUS_FILE_NAME: Final = "STATUS.TXT"
#: No read is waited on longer than this.
FRESH_READ_TIMEOUT_SECONDS: Final = 0.5
#: STATUS.TXT is well under this; LEDS.LED is at most 512 bytes.
_READ_LIMIT: Final = 8192
#: The fit only looks this far back: long enough to average out read
#: jitter, short enough to follow the rate as temperature and USB load move it.
CLOCK_WINDOW_SECONDS: Final = 600.0
#: Pairs of samples closer together than this say more about read jitter
#: than about the clock.
_MIN_PAIR_SECONDS: Final = 4.0
#: Where the measured rates live between runs.
CLOCKS_FILE_NAME: Final = "device-clocks.json"

_MS_INVALIDATE: Final = 0x0002
_PROT_READ: Final = 0x01
_MAP_SHARED: Final = 0x0001


# --- fresh reads -------------------------------------------------------------


def _libc():
    library = ctypes.CDLL(ctypes.util.find_library("c"), use_errno=True)
    library.mmap.restype = ctypes.c_void_p
    library.mmap.argtypes = [
        ctypes.c_void_p,
        ctypes.c_size_t,
        ctypes.c_int,
        ctypes.c_int,
        ctypes.c_int,
        ctypes.c_long,
    ]
    library.msync.argtypes = [ctypes.c_void_p, ctypes.c_size_t, ctypes.c_int]
    library.munmap.argtypes = [ctypes.c_void_p, ctypes.c_size_t]
    return library


_LIBC = None


def _invalidate(descriptor: int, size: int) -> None:
    """Drop the host's cached pages for this file, so the next read goes to
    the device. Best effort: a failure here only means the read may be stale,
    which the estimator notices (the clock stops moving)."""
    global _LIBC
    if size <= 0:
        return
    try:
        if _LIBC is None:
            _LIBC = _libc()
        address = _LIBC.mmap(None, size, _PROT_READ, _MAP_SHARED, descriptor, 0)
        if address in (None, ctypes.c_void_p(-1).value):
            return
        try:
            _LIBC.msync(address, size, _MS_INVALIDATE)
        finally:
            _LIBC.munmap(address, size)
    except Exception:
        return


def _under_test_on_live_volume(path: Path) -> bool:
    """A test suite must never read real hardware by accident: fixtures name
    ``/Volumes/SidePulse`` for fake devices, and on a desk with a SidePulse
    plugged in that path is live (and every read costs the Dot ticks)."""
    return "PYTEST_CURRENT_TEST" in os.environ and str(path).startswith("/Volumes/")


def fresh_read_bytes(path: Path) -> tuple[bytes, float]:
    """``(bytes, host moment)`` of one uncached read; the moment is the
    midpoint of the ``pread``, which is when the device answered."""
    if _under_test_on_live_volume(Path(path)):
        raise OSError(f"refusing a live device read under test: {path}")
    descriptor = os.open(str(path), os.O_RDONLY)
    try:
        size = os.fstat(descriptor).st_size
        _invalidate(descriptor, size)
        before = time.monotonic()
        data = os.pread(descriptor, _READ_LIMIT, 0)
        after = time.monotonic()
    finally:
        os.close(descriptor)
    return data, (before + after) / 2.0


_IN_FLIGHT: set[str] = set()
_IN_FLIGHT_LOCK = threading.Lock()


def bounded(key: str, work: Callable[[], object], *, timeout: float) -> object | None:
    """``work()`` on a worker thread, waited on for at most ``timeout``.

    ``None`` when it failed, took too long, or an earlier read of the same
    ``key`` is still stuck -- a stalled device must never stall the caller,
    and must not collect a thread per attempt either."""
    with _IN_FLIGHT_LOCK:
        if key in _IN_FLIGHT:
            return None
        _IN_FLIGHT.add(key)
    finished = threading.Event()
    box: dict[str, object] = {}

    def run() -> None:
        try:
            box["value"] = work()
        except Exception as error:  # an unplugged volume, a permission slip
            box["error"] = error
        finally:
            with _IN_FLIGHT_LOCK:
                _IN_FLIGHT.discard(key)
            finished.set()

    threading.Thread(target=run, name="jrbar-fresh-read", daemon=True).start()
    if not finished.wait(max(0.0, float(timeout))):
        return None
    return box.get("value")


@dataclass(frozen=True, slots=True)
class DeviceStatus:
    """One fresh STATUS.TXT reading."""

    #: Host monotonic seconds at the moment the device answered.
    host_at: float
    fields: dict[str, str] = field(default_factory=dict)

    def number(self, key: str) -> float | None:
        try:
            value = float(self.fields[key])
        except (KeyError, ValueError):
            return None
        return value if math.isfinite(value) else None

    @property
    def uptime_ms(self) -> float | None:
        """The Pro's millisecond clock."""
        return self.number("uptime_ms")

    @property
    def ticks(self) -> float | None:
        """The Dot's millisecond clock (it has no ``uptime_ms``)."""
        return self.number("ticks")

    @property
    def clock_ms(self) -> float | None:
        """Whichever millisecond clock this device reports."""
        uptime = self.uptime_ms
        return uptime if uptime is not None else self.ticks

    @property
    def leds_applies(self) -> int | None:
        value = self.number("leds_applies")
        return None if value is None else int(value)

    @property
    def serial(self) -> str | None:
        return self.fields.get("serial")


def parse_status(text: str) -> dict[str, str]:
    """``key value`` lines, both devices' formats; the rest is ignored."""
    fields: dict[str, str] = {}
    for line in (text or "").splitlines():
        parts = line.strip().split(None, 1)
        if len(parts) == 2 and parts[0] not in fields:
            fields[parts[0]] = parts[1].strip()
    return fields


def read_fresh_status(
    root: Path,
    *,
    timeout: float = FRESH_READ_TIMEOUT_SECONDS,
    reader: Callable[[Path], tuple[bytes, float]] | None = None,
) -> DeviceStatus | None:
    """The device's STATUS.TXT, read past the host's cache, or ``None``.

    ``root`` is the volume (``/Volumes/PulseDot``). Never blocks the caller
    for more than ``timeout``; see the module note on stalls."""
    path = Path(root) / STATUS_FILE_NAME
    read = reader or fresh_read_bytes

    def work() -> DeviceStatus:
        data, host_at = read(path)
        return DeviceStatus(host_at, parse_status(data.decode("utf-8", errors="replace")))

    result = bounded(f"status:{path}", work, timeout=timeout)
    return result if isinstance(result, DeviceStatus) else None


def read_fresh_file(
    path: Path,
    *,
    timeout: float = FRESH_READ_TIMEOUT_SECONDS,
    reader: Callable[[Path], tuple[bytes, float]] | None = None,
) -> str | None:
    """Any small device file (LEDS.LED) read past the cache, or ``None``."""
    read = reader or fresh_read_bytes

    def work() -> str:
        data, _host_at = read(Path(path))
        return data.decode("utf-8", errors="replace")

    result = bounded(f"file:{path}", work, timeout=timeout)
    return result if isinstance(result, str) else None


# --- the estimator -----------------------------------------------------------


@dataclass(slots=True)
class ClockEstimate:
    """Device-ms per real ms, and how much to believe it."""

    rate: float
    samples: int = 0
    span_seconds: float = 0.0
    #: ``warm`` (persisted or the warm start), ``measured``, or ``frozen``
    #: when fresh reads stopped moving (the cache trick broke: the rate
    #: falls back to the last good one and the caller re-anchors blind).
    source: str = "warm"


class DeviceClockEstimator:
    """A robust rate from sparse fresh reads of one device's clock.

    Theil-Sen: the median slope over every pair of samples at least a few
    seconds apart, in a ten-minute window (from the first such pair on: a
    20-second pair already pins the rate to a few hundredths of a percent). One slow read, a burst of reads
    (which really does slow the Dot while it lasts), or a stale cached value
    moves the median very little; a genuine change of rate moves it within
    the window. Anything outside 0.90-1.10 is refused as bad samples."""

    def __init__(self, *, warm_rate: float = 1.0, window_seconds: float = CLOCK_WINDOW_SECONDS) -> None:
        self.window_seconds = float(window_seconds)
        self.samples: deque[tuple[float, float]] = deque()
        self.estimate = ClockEstimate(rate=_clamp_rate(warm_rate))
        self.frozen_reads = 0

    def add(self, host_at: float, clock_ms: float) -> ClockEstimate:
        """Take one sample. A clock that went backwards is a reboot: the
        old samples describe a different run and are dropped. A clock that
        did not move while real time did is a cached read, not a sample."""
        if not (math.isfinite(host_at) and math.isfinite(clock_ms)):
            return self.estimate
        if self.samples:
            last_host, last_clock = self.samples[-1]
            if clock_ms < last_clock:
                self.samples.clear()
            elif clock_ms == last_clock and host_at - last_host > 1.0:
                self.frozen_reads += 1
                if self.frozen_reads >= 3:
                    self.estimate.source = "frozen"
                return self.estimate
        self.frozen_reads = 0
        self.samples.append((float(host_at), float(clock_ms)))
        while self.samples and host_at - self.samples[0][0] > self.window_seconds:
            self.samples.popleft()
        self._fit()
        return self.estimate

    def _fit(self) -> None:
        points = list(self.samples)
        slopes: list[float] = []
        for index, (host_a, clock_a) in enumerate(points):
            for host_b, clock_b in points[index + 1 :]:
                gap = host_b - host_a
                if gap >= _MIN_PAIR_SECONDS:
                    slopes.append((clock_b - clock_a) / (gap * 1000.0))
        if not slopes:
            return
        slopes.sort()
        middle = len(slopes) // 2
        rate = slopes[middle] if len(slopes) % 2 else (slopes[middle - 1] + slopes[middle]) / 2.0
        if not (MIN_CLOCK_RATE <= rate <= MAX_CLOCK_RATE):
            return
        self.estimate = ClockEstimate(
            rate=rate,
            samples=len(points),
            span_seconds=points[-1][0] - points[0][0],
            source="measured",
        )

    def clock_at(self, host_at: float) -> float | None:
        """The device clock the fit expects at ``host_at``, from the newest
        sample: what ``ticks`` read at a moment nobody sampled."""
        if not self.samples:
            return None
        last_host, last_clock = self.samples[-1]
        return last_clock + (host_at - last_host) * 1000.0 * self.estimate.rate


def _clamp_rate(value: object) -> float:
    try:
        rate = float(value)  # type: ignore[arg-type]
    except (TypeError, ValueError):
        return 1.0
    if not math.isfinite(rate):
        return 1.0
    return min(MAX_CLOCK_RATE, max(MIN_CLOCK_RATE, rate))


# --- persistence and the per-device registry ---------------------------------


def default_clocks_path() -> Path:
    from .providers import default_state_dir

    return default_state_dir() / CLOCKS_FILE_NAME


def load_rates(path: Path) -> dict[str, float]:
    """``{device_id: rate}`` from ``device-clocks.json``; a missing,
    unreadable or hand-mangled file is an empty one."""
    try:
        document = json.loads(Path(path).read_text(encoding="utf-8"))
    except (OSError, ValueError):
        return {}
    if not isinstance(document, dict):
        return {}
    rates: dict[str, float] = {}
    for device_id, entry in document.items():
        rate = entry.get("rate") if isinstance(entry, dict) else None
        if isinstance(rate, (int, float)) and not isinstance(rate, bool):
            if MIN_CLOCK_RATE <= float(rate) <= MAX_CLOCK_RATE:
                rates[str(device_id)] = float(rate)
    return rates


def save_rates(path: Path, estimates: dict[str, ClockEstimate], *, now: float | None = None) -> None:
    """Write the measured rates atomically; only measured ones are worth
    keeping, and a failed save costs nothing but a warm start next time."""
    document = {
        device_id: {
            "rate": round(estimate.rate, 6),
            "samples": estimate.samples,
            "window_seconds": round(estimate.span_seconds, 1),
            "updated_at": round(time.time() if now is None else now, 3),
        }
        for device_id, estimate in estimates.items()
        if estimate.source == "measured"
    }
    if not document:
        return
    target = Path(path)
    try:
        target.parent.mkdir(parents=True, exist_ok=True)
        merged = {
            key: {"rate": value}
            for key, value in load_rates(target).items()
            if key not in document
        }
        merged.update(document)
        scratch = target.with_name(f".{target.name}.{os.getpid()}.tmp")
        scratch.write_text(json.dumps(merged, indent=2, sort_keys=True), encoding="utf-8")
        os.replace(scratch, target)
    except OSError:
        return


class DeviceClocks:
    """Every device's estimator, warm-started from disk.

    A Dot with no history starts at ``WARM_START_DOT_RATE``; a Pro at 1.0
    (measured the same way whenever it is read). Saved at most once a
    minute, and only rates that were actually measured."""

    SAVE_EVERY_SECONDS: Final = 60.0

    def __init__(self, path: Path | None = None) -> None:
        self.path = path
        self._persisted = load_rates(path) if path is not None else {}
        self._estimators: dict[str, DeviceClockEstimator] = {}
        self._saved_at: float | None = None
        self._lock = threading.Lock()

    def estimator(self, device_id: str, *, dot: bool) -> DeviceClockEstimator:
        with self._lock:
            found = self._estimators.get(device_id)
            if found is None:
                warm = self._persisted.get(device_id, WARM_START_DOT_RATE if dot else 1.0)
                found = self._estimators[device_id] = DeviceClockEstimator(warm_rate=warm)
            return found

    def rate(self, device_id: str, *, dot: bool) -> float:
        return self.estimator(device_id, dot=dot).estimate.rate

    def add(self, device_id: str, *, dot: bool, host_at: float, clock_ms: float) -> ClockEstimate:
        estimate = self.estimator(device_id, dot=dot).add(host_at, clock_ms)
        self._maybe_save(host_at)
        return estimate

    def _maybe_save(self, now: float) -> None:
        if self.path is None:
            return
        if self._saved_at is not None and now - self._saved_at < self.SAVE_EVERY_SECONDS:
            return
        self._saved_at = now
        with self._lock:
            estimates = {key: est.estimate for key, est in self._estimators.items()}
        save_rates(self.path, estimates)


__all__ = [
    "CLOCKS_FILE_NAME",
    "CLOCK_WINDOW_SECONDS",
    "FRESH_READ_TIMEOUT_SECONDS",
    "ClockEstimate",
    "DeviceClockEstimator",
    "DeviceClocks",
    "DeviceStatus",
    "bounded",
    "default_clocks_path",
    "fresh_read_bytes",
    "load_rates",
    "parse_status",
    "read_fresh_file",
    "read_fresh_status",
    "save_rates",
]
