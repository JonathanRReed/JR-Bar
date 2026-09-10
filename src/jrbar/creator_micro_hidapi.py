"""Optional hidapi transport for Creator Micro 2.

The dependency is lazy so JR-Bar remains usable without hardware support.
hidapi is BSD-3-Clause: https://github.com/libusb/hidapi/blob/master/LICENSE.txt
"""

from __future__ import annotations

import ctypes
import sys
import threading
from typing import Any

from .creator_micro_adapter import CreatorMicro2Framer, DeviceTransport, NoDeviceError

_OPEN_LOCK = threading.Lock()


def _enable_macos_nonexclusive(hid_module: Any) -> None:
    """Use the Darwin API exported by the same pinned hidapi extension."""
    try:
        library = ctypes.CDLL(hid_module.__file__)
        setter = library.hid_darwin_set_open_exclusive
        getter = library.hid_darwin_get_open_exclusive
        setter.argtypes = [ctypes.c_int]
        setter.restype = None
        getter.argtypes = []
        getter.restype = ctypes.c_int
        setter(0)
        if getter() != 0:
            raise OSError("nonexclusive HID policy was not applied")
    except (AttributeError, TypeError, OSError) as exc:
        raise OSError("nonexclusive HID open is unavailable in this backend") from exc


class DeviceIdentityError(PermissionError):
    """A connected HID collection cannot be bound to one stable identity."""

    def __init__(self, code: str, message: str):
        super().__init__(message)
        self.code = code


class DeviceAccessError(PermissionError):
    """macOS refuses this process HID access to the pad."""

    def __init__(self, code: str, message: str):
        super().__init__(message)
        self.code = code


#: ``IOHIDRequestType``/``IOHIDAccessType`` from ``IOKit/hid/IOHIDLib.h``.
_LISTEN_EVENT_REQUEST = 1
_ACCESS_DENIED = 1


def macos_input_monitoring_denied() -> bool:
    """Whether macOS has explicitly denied this process Input Monitoring.

    Over Bluetooth the pad's four HID collections share one ``IOHIDDevice``
    (they enumerate on a single ``DevSrvsID:`` path), so opening the vendor
    collection opens the keyboard one with it and TCC gates the open. A
    denial makes every open fail with an unexplained I/O error, which the
    output worker can only read as a device that keeps going away.

    ``IOHIDCheckAccess`` answers without prompting. Only an explicit denial
    refuses the open: ``unknown`` means nobody has been asked yet, and the
    open itself is what raises the prompt.
    """
    if sys.platform != "darwin":
        return False
    try:
        io = ctypes.CDLL("/System/Library/Frameworks/IOKit.framework/IOKit")
        check = io.IOHIDCheckAccess
        check.argtypes = [ctypes.c_uint32]
        check.restype = ctypes.c_uint32
        return check(_LISTEN_EVENT_REQUEST) == _ACCESS_DENIED
    except (AttributeError, TypeError, OSError, ValueError):
        # An OS without the getter is not evidence of a denial.
        return False


def select_unique_stable_serial(devices: list[dict[str, Any]]) -> str:
    """Return the sole stable serial that an explicit enable action can approve."""

    if not devices:
        raise DeviceIdentityError("no_device", "Creator Micro 2 not found")
    if len(devices) != 1:
        raise DeviceIdentityError(
            "ambiguous_device_identity",
            "connect exactly one Creator Micro 2 before enabling output",
        )
    serial = devices[0].get("serial_number")
    if not isinstance(serial, str) or not serial.strip():
        raise DeviceIdentityError(
            "device_identity_unavailable",
            "Creator Micro output requires a stable serial number",
        )
    serial = serial.strip()
    if len(serial) > 256 or not serial.isprintable() or "\x00" in serial:
        raise DeviceIdentityError(
            "device_identity_unavailable",
            "Creator Micro reported an invalid serial number",
        )
    return serial


class HidApiTransport(DeviceTransport):
    def __init__(
        self,
        hid_module: Any = None,
        *,
        approved_serial: str | None = None,
    ):
        self._hid = hid_module
        self._device: Any = None
        self._write_enabled = False
        self._approved_serial = approved_serial

    def _module(self) -> Any:
        if self._hid is None:
            try:
                import hid  # type: ignore[import-not-found]
            except ImportError as exc:
                raise OSError("hidapi is not installed") from exc
            self._hid = hid
        return self._hid

    def _matching_devices(self) -> list[dict[str, Any]]:
        from .creator_micro_discovery import native_vendor_collections, preferred_endpoints

        rows = [dict(row) for row in self._module().enumerate(CreatorMicro2Framer.VENDOR_ID)]
        native = frozenset()
        if sys.platform == "darwin" and any(
                row.get("product_id") in CreatorMicro2Framer.PRODUCT_IDS
                and row.get("bus_type") == 2
                and not CreatorMicro2Framer.discover(row) for row in rows):
            try:
                native = native_vendor_collections()
            except (OSError, AttributeError, ValueError):
                pass
        matching = []
        for row in rows:
            identity = (row.get("vendor_id"), row.get("product_id"),
                        row.get("serial_number"), row.get("bus_type"))
            if row.get("bus_type") == 2 and identity in native:
                row["usage_page"], row["usage"] = CreatorMicro2Framer.USAGE_PAGE, CreatorMicro2Framer.USAGE
            if CreatorMicro2Framer.discover(row):
                matching.append(row)
        return preferred_endpoints(matching)

    def enumerate(self) -> list[dict[str, Any]]:
        devices = self._matching_devices()
        if self._approved_serial is None:
            return devices
        return [
            device
            for device in devices
            if device.get("serial_number") == self._approved_serial
        ]

    def open(self, *, nonexclusive: bool = True) -> None:
        if self._approved_serial is None:
            raise PermissionError("Creator Micro output requires an approved device identity")
        matching = self._matching_devices()
        if matching and not all(
            isinstance(device.get("serial_number"), str)
            and bool(device["serial_number"].strip())
            for device in matching
        ):
            raise PermissionError("Creator Micro output requires a stable serial number")
        devices = [
            device
            for device in matching
            if device.get("serial_number") == self._approved_serial
        ]
        if not devices:
            raise NoDeviceError("Creator Micro 2 not found")
        if len(devices) != 1:
            raise PermissionError("Creator Micro device identity is ambiguous")
        if macos_input_monitoring_denied():
            raise DeviceAccessError(
                "input_monitoring_denied",
                "macOS Input Monitoring is denied for this process",
            )
        with _OPEN_LOCK:
            device = self._module().device()
            try:
                # Device creation can call hid_init, which resets the global
                # policy. Apply it afterward and immediately before open.
                if sys.platform == "darwin" and nonexclusive:
                    _enable_macos_nonexclusive(self._module())
                device.open_path(devices[0]["path"])
                # cython-hidapi routes read(..., 0) through hid_read, which
                # otherwise blocks indefinitely on the input polling path.
                # Positive timeouts still use hid_read_timeout.
                device.set_nonblocking(True)
            except Exception:
                try:
                    device.close()
                except OSError:
                    pass
                raise
            self._device = device

    def enable_writes(self) -> None:
        self._write_enabled = True

    def write(self, report: bytes) -> None:
        if not self._write_enabled:
            raise PermissionError("device writes require explicit opt-in")
        if self._device is None:
            raise OSError("transport is not open")
        written = self._device.write(report)
        if written != len(report):
            raise OSError(f"incomplete HID write: {written} of {len(report)} bytes")

    def read(self, *, timeout_ms: int) -> bytes | None:
        if self._device is None:
            return None
        timeout_ms = max(0, min(timeout_ms, 8_000))
        data = self._device.read(CreatorMicro2Framer.REPORT_SIZE, timeout_ms)
        return bytes(data) if data else None

    def close(self) -> None:
        if self._device is not None:
            self._device.close()
            self._device = None
