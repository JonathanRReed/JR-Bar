"""Auto-dim: the brightness factor that replaced night warmth.

One setting, ``auto_dim``, feeds ``brightness_policy.plan_ambient_brightness``'s
``night_factor`` stage (the trace step is still called ``night_dim``; the
protocol word is ``auto_dim``). Four modes:

* ``off``: the factor is 1.0 (today's behaviour, the default).
* ``schedule``: ``fraction`` inside a daily minutes-of-day window (which may
  wrap midnight), 1.0 outside it.
* ``display``: follow the built-in display's brightness, never below
  ``min_fraction``; an unreadable display (external, asleep) leaves the
  factor at 1.0 and reports ``available: false``.
* ``ambient``: follow the ambient light sensor, ``min_fraction`` at
  ``lux_floor`` rising linearly to 1.0 at ``lux_ceiling``; when the sensor
  cannot be read the policy falls back to ``display`` and reports
  ``available: false``.

The evaluation is pure (readers are injected); the readers live at the
bottom of this module. The ambient reader talks to IOKit's HID event
system from ctypes: ``IOHIDEventSystemClientCreate``, matched on
``PrimaryUsagePage 0xFF00 / PrimaryUsage 4`` (Apple's sensor page), then
``IOHIDServiceClientCopyEvent(service, kIOHIDEventTypeAmbientLightSensor,
0, 0)`` and ``IOHIDEventGetFloatValue(event,
kIOHIDEventFieldAmbientLightSensorLevel)``.
"""

from __future__ import annotations

import ctypes
import math
import threading
from collections.abc import Callable
from dataclasses import dataclass, replace
from typing import Any, Final

AUTO_DIM_MODES: Final = ("off", "schedule", "display", "ambient")
DEFAULT_AUTO_DIM_MODE: Final = "off"
DEFAULT_SCHEDULE_START_MINUTES: Final = 22 * 60
DEFAULT_SCHEDULE_END_MINUTES: Final = 7 * 60
DEFAULT_SCHEDULE_FRACTION: Final = 0.3
DEFAULT_DISPLAY_MIN_FRACTION: Final = 0.15
# The ambient defaults are calibrated for real indoor light, not the
# textbook 300-500 lux office: the Mac's user-facing sensor reads
# ~50-150 lux in a normally lit room, so a 400 lux ceiling would dim
# every indoor surface all day. 15 lux is a genuinely dark room; 150 is
# "the lights are on".
DEFAULT_AMBIENT_MIN_FRACTION: Final = 0.35
DEFAULT_AMBIENT_LUX_FLOOR: Final = 15.0
DEFAULT_AMBIENT_LUX_CEILING: Final = 150.0
MIN_FRACTION: Final = 0.02
MAX_LUX: Final = 200_000.0

# IOKit HID event system constants (IOHIDEventTypes.h).
kIOHIDEventTypeAmbientLightSensor: Final = 12
kIOHIDEventFieldAmbientLightSensorLevel: Final = kIOHIDEventTypeAmbientLightSensor << 16
_SENSOR_USAGE_PAGE: Final = 0xFF00
_ALS_USAGE: Final = 4
_IOKIT_PATH: Final = "/System/Library/Frameworks/IOKit.framework/IOKit"
_CF_PATH: Final = "/System/Library/Frameworks/CoreFoundation.framework/CoreFoundation"
_kCFStringEncodingUTF8: Final = 0x08000100
_kCFNumberSInt32Type: Final = 3


def _fraction(value: object, default: float, *, minimum: float = MIN_FRACTION) -> float:
    if isinstance(value, bool) or not isinstance(value, (int, float)) or not math.isfinite(float(value)):
        return default
    return max(minimum, min(1.0, float(value)))


def _minutes(value: object, default: int) -> int:
    if isinstance(value, bool) or not isinstance(value, (int, float)) or not math.isfinite(float(value)):
        return default
    return max(0, min(24 * 60 - 1, int(value)))


def _lux(value: object, default: float) -> float:
    if isinstance(value, bool) or not isinstance(value, (int, float)) or not math.isfinite(float(value)):
        return default
    return max(0.0, min(MAX_LUX, float(value)))


@dataclass(frozen=True, slots=True)
class AutoDimSettings:
    mode: str = DEFAULT_AUTO_DIM_MODE
    schedule_start_minutes: int = DEFAULT_SCHEDULE_START_MINUTES
    schedule_end_minutes: int = DEFAULT_SCHEDULE_END_MINUTES
    schedule_fraction: float = DEFAULT_SCHEDULE_FRACTION
    display_min_fraction: float = DEFAULT_DISPLAY_MIN_FRACTION
    ambient_min_fraction: float = DEFAULT_AMBIENT_MIN_FRACTION
    ambient_lux_floor: float = DEFAULT_AMBIENT_LUX_FLOOR
    ambient_lux_ceiling: float = DEFAULT_AMBIENT_LUX_CEILING

    def to_dict(self) -> dict[str, Any]:
        return {
            "mode": self.mode,
            "schedule": {
                "start_minutes": self.schedule_start_minutes,
                "end_minutes": self.schedule_end_minutes,
                "fraction": self.schedule_fraction,
            },
            "display": {"min_fraction": self.display_min_fraction},
            "ambient": {
                "min_fraction": self.ambient_min_fraction,
                "lux_floor": self.ambient_lux_floor,
                "lux_ceiling": self.ambient_lux_ceiling,
            },
        }

    @classmethod
    def from_dict(cls, value: object) -> AutoDimSettings:
        """Lenient: anything malformed falls back to that field's default."""
        default = cls()
        if not isinstance(value, dict):
            return default
        mode = value.get("mode")
        schedule = value.get("schedule") if isinstance(value.get("schedule"), dict) else {}
        display = value.get("display") if isinstance(value.get("display"), dict) else {}
        ambient = value.get("ambient") if isinstance(value.get("ambient"), dict) else {}
        floor = _lux(ambient.get("lux_floor"), default.ambient_lux_floor)
        ceiling = _lux(ambient.get("lux_ceiling"), default.ambient_lux_ceiling)
        if ceiling <= floor:
            floor, ceiling = default.ambient_lux_floor, default.ambient_lux_ceiling
        return cls(
            mode=mode if isinstance(mode, str) and mode in AUTO_DIM_MODES else default.mode,
            schedule_start_minutes=_minutes(schedule.get("start_minutes"), default.schedule_start_minutes),
            schedule_end_minutes=_minutes(schedule.get("end_minutes"), default.schedule_end_minutes),
            schedule_fraction=_fraction(schedule.get("fraction"), default.schedule_fraction),
            display_min_fraction=_fraction(display.get("min_fraction"), default.display_min_fraction),
            ambient_min_fraction=_fraction(ambient.get("min_fraction"), default.ambient_min_fraction),
            ambient_lux_floor=floor,
            ambient_lux_ceiling=ceiling,
        )

    def with_mode(self, mode: str) -> AutoDimSettings:
        if mode not in AUTO_DIM_MODES:
            raise ValueError(f"unknown auto-dim mode {mode!r}")
        return replace(self, mode=mode)


@dataclass(frozen=True, slots=True)
class AutoDimResult:
    """What the policy decided: the factor applied, which source produced
    it, whether that source could be read, and the raw reading."""

    mode: str
    source: str
    factor: float
    available: bool
    reading: float | None = None

    def to_dict(self) -> dict[str, Any]:
        return {
            "mode": self.mode,
            "source": self.source,
            "factor": round(float(self.factor), 4),
            "available": bool(self.available),
            "reading": None if self.reading is None else round(float(self.reading), 3),
        }


OFF_RESULT: Final = AutoDimResult("off", "off", 1.0, True)


def schedule_active(start_minutes: int, end_minutes: int, now_minutes: int) -> bool:
    """Whether ``now_minutes`` (minutes since local midnight) is inside the
    daily window; a window whose start is after its end wraps midnight."""
    if start_minutes == end_minutes:
        return False
    if start_minutes < end_minutes:
        return start_minutes <= now_minutes < end_minutes
    return now_minutes >= start_minutes or now_minutes < end_minutes


def ambient_factor(lux: float, *, min_fraction: float, lux_floor: float, lux_ceiling: float) -> float:
    if lux_ceiling <= lux_floor:
        return 1.0
    position = (float(lux) - lux_floor) / (lux_ceiling - lux_floor)
    position = max(0.0, min(1.0, position))
    return min_fraction + (1.0 - min_fraction) * position


def evaluate_auto_dim(
    settings: AutoDimSettings,
    *,
    now_minutes: int,
    display_reader: Callable[[], float | None],
    ambient_reader: Callable[[], float | None],
) -> AutoDimResult:
    """The factor for the ``night_dim`` stage. Readers return a fraction /
    lux or ``None`` (or raise) when they cannot read."""
    mode = settings.mode
    if mode == "off":
        return OFF_RESULT
    if mode == "schedule":
        active = schedule_active(settings.schedule_start_minutes, settings.schedule_end_minutes, now_minutes)
        return AutoDimResult("schedule", "schedule", settings.schedule_fraction if active else 1.0, True, float(now_minutes))
    available = True
    if mode == "ambient":
        try:
            lux = ambient_reader()
        except Exception:
            lux = None
        if lux is not None and math.isfinite(float(lux)) and float(lux) >= 0.0:
            return AutoDimResult(
                "ambient",
                "ambient",
                ambient_factor(
                    float(lux),
                    min_fraction=settings.ambient_min_fraction,
                    lux_floor=settings.ambient_lux_floor,
                    lux_ceiling=settings.ambient_lux_ceiling,
                ),
                True,
                float(lux),
            )
        # No sensor reading: follow the display instead, and say so.
        available = False
    try:
        fraction = display_reader()
    except Exception:
        fraction = None
    if fraction is None or not math.isfinite(float(fraction)):
        return AutoDimResult(mode, "display", 1.0, False, None)
    fraction = max(0.0, min(1.0, float(fraction)))
    return AutoDimResult(mode, "display", max(settings.display_min_fraction, fraction), available, fraction)


# --- readers ---------------------------------------------------------------


class AmbientLightUnavailableError(RuntimeError):
    pass


def display_brightness_fraction() -> float | None:
    """The built-in display's brightness (0..1) through the same reader the
    per-device auto-brightness uses; ``None`` when it cannot be trusted."""
    from . import display_brightness

    try:
        return float(display_brightness.current_screen_brightness_fraction())
    except display_brightness.DisplayBrightnessUnavailableError:
        return None


class _AmbientLightSensor:
    """One IOKit HID event-system client, created lazily, reused for every
    reading. Thread-safe; a failure to load or match marks the sensor
    unavailable for the process lifetime (the hardware does not appear
    later)."""

    def __init__(self) -> None:
        self._lock = threading.Lock()
        self._client: int | None = None
        self._service: int | None = None
        self._failed: str | None = None
        self._iokit: Any = None
        self._cf: Any = None

    def _load(self) -> None:
        iokit = ctypes.CDLL(_IOKIT_PATH)
        cf = ctypes.CDLL(_CF_PATH)
        iokit.IOHIDEventSystemClientCreate.restype = ctypes.c_void_p
        iokit.IOHIDEventSystemClientCreate.argtypes = [ctypes.c_void_p]
        iokit.IOHIDEventSystemClientSetMatching.restype = None
        iokit.IOHIDEventSystemClientSetMatching.argtypes = [ctypes.c_void_p, ctypes.c_void_p]
        iokit.IOHIDEventSystemClientCopyServices.restype = ctypes.c_void_p
        iokit.IOHIDEventSystemClientCopyServices.argtypes = [ctypes.c_void_p]
        iokit.IOHIDServiceClientCopyEvent.restype = ctypes.c_void_p
        iokit.IOHIDServiceClientCopyEvent.argtypes = [ctypes.c_void_p, ctypes.c_int64, ctypes.c_int32, ctypes.c_int64]
        iokit.IOHIDEventGetFloatValue.restype = ctypes.c_double
        iokit.IOHIDEventGetFloatValue.argtypes = [ctypes.c_void_p, ctypes.c_int32]
        cf.CFArrayGetCount.restype = ctypes.c_long
        cf.CFArrayGetCount.argtypes = [ctypes.c_void_p]
        cf.CFArrayGetValueAtIndex.restype = ctypes.c_void_p
        cf.CFArrayGetValueAtIndex.argtypes = [ctypes.c_void_p, ctypes.c_long]
        cf.CFRetain.restype = ctypes.c_void_p
        cf.CFRetain.argtypes = [ctypes.c_void_p]
        cf.CFRelease.restype = None
        cf.CFRelease.argtypes = [ctypes.c_void_p]
        cf.CFStringCreateWithCString.restype = ctypes.c_void_p
        cf.CFStringCreateWithCString.argtypes = [ctypes.c_void_p, ctypes.c_char_p, ctypes.c_uint32]
        cf.CFNumberCreate.restype = ctypes.c_void_p
        cf.CFNumberCreate.argtypes = [ctypes.c_void_p, ctypes.c_int, ctypes.c_void_p]
        cf.CFDictionaryCreate.restype = ctypes.c_void_p
        cf.CFDictionaryCreate.argtypes = [
            ctypes.c_void_p,
            ctypes.POINTER(ctypes.c_void_p),
            ctypes.POINTER(ctypes.c_void_p),
            ctypes.c_long,
            ctypes.c_void_p,
            ctypes.c_void_p,
        ]
        key_callbacks = ctypes.c_void_p.in_dll(cf, "kCFTypeDictionaryKeyCallBacks")
        value_callbacks = ctypes.c_void_p.in_dll(cf, "kCFTypeDictionaryValueCallBacks")
        allocator = ctypes.c_void_p.in_dll(cf, "kCFAllocatorDefault")

        def cf_string(text: str) -> int:
            return cf.CFStringCreateWithCString(None, text.encode("utf-8"), _kCFStringEncodingUTF8)

        def cf_number(value: int) -> int:
            boxed = ctypes.c_int32(value)
            return cf.CFNumberCreate(None, _kCFNumberSInt32Type, ctypes.byref(boxed))

        keys = (ctypes.c_void_p * 2)(cf_string("PrimaryUsagePage"), cf_string("PrimaryUsage"))
        values = (ctypes.c_void_p * 2)(cf_number(_SENSOR_USAGE_PAGE), cf_number(_ALS_USAGE))
        matching = cf.CFDictionaryCreate(None, keys, values, 2, ctypes.byref(key_callbacks), ctypes.byref(value_callbacks))
        client = iokit.IOHIDEventSystemClientCreate(allocator)
        if not client:
            raise AmbientLightUnavailableError("IOHIDEventSystemClientCreate returned NULL")
        iokit.IOHIDEventSystemClientSetMatching(client, matching)
        services = iokit.IOHIDEventSystemClientCopyServices(client)
        if not services or cf.CFArrayGetCount(services) <= 0:
            raise AmbientLightUnavailableError("no ambient light sensor service")
        service = cf.CFRetain(cf.CFArrayGetValueAtIndex(services, 0))
        cf.CFRelease(services)
        for item in (*keys, *values, matching):
            if item:
                cf.CFRelease(item)
        self._iokit, self._cf, self._client, self._service = iokit, cf, client, service

    def read_lux(self) -> float:
        with self._lock:
            if self._failed is not None:
                raise AmbientLightUnavailableError(self._failed)
            if self._service is None:
                try:
                    self._load()
                except Exception as exc:
                    self._failed = f"{exc.__class__.__name__}: {exc}"
                    raise AmbientLightUnavailableError(self._failed) from exc
            event = self._iokit.IOHIDServiceClientCopyEvent(self._service, kIOHIDEventTypeAmbientLightSensor, 0, 0)
            if not event:
                raise AmbientLightUnavailableError("no ambient light event")
            try:
                value = float(self._iokit.IOHIDEventGetFloatValue(event, kIOHIDEventFieldAmbientLightSensorLevel))
            finally:
                self._cf.CFRelease(event)
            if not math.isfinite(value) or value < 0.0:
                raise AmbientLightUnavailableError(f"implausible reading {value!r}")
            return value


_SENSOR = _AmbientLightSensor()


def ambient_light_lux() -> float | None:
    """The ambient light level in lux from the built-in sensor, or ``None``
    when this Mac has none (or the sensor cannot be read)."""
    try:
        return _SENSOR.read_lux()
    except AmbientLightUnavailableError:
        return None


__all__ = [
    "AUTO_DIM_MODES",
    "OFF_RESULT",
    "AmbientLightUnavailableError",
    "AutoDimResult",
    "AutoDimSettings",
    "ambient_factor",
    "ambient_light_lux",
    "display_brightness_fraction",
    "evaluate_auto_dim",
    "schedule_active",
]
