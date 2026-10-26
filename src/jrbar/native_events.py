"""Explicit, pid-targeted keyboard delivery through CoreGraphics' C API."""
import ctypes as c
import os
from functools import lru_cache

from .native_displays import library

kCGEventFlagMaskShift = 1 << 17
kCGEventFlagMaskControl = 1 << 18
kCGEventFlagMaskAlternate = 1 << 19
kCGEventFlagMaskCommand = 1 << 20


@lru_cache(maxsize=1)
def _api():
    lib = library()
    lib.CGEventCreateKeyboardEvent.argtypes = [c.c_void_p, c.c_uint16, c.c_bool]
    lib.CGEventCreateKeyboardEvent.restype = c.c_void_p
    lib.CGEventSetFlags.argtypes = [c.c_void_p, c.c_uint64]
    lib.CGEventSetFlags.restype = None
    lib.CGEventKeyboardSetUnicodeString.argtypes = [c.c_void_p, c.c_ulong, c.POINTER(c.c_uint16)]
    lib.CGEventKeyboardSetUnicodeString.restype = None
    lib.CGEventPostToPid.argtypes = [c.c_int32, c.c_void_p]
    lib.CGEventPostToPid.restype = None
    lib.CGEventGetFlags.argtypes = [c.c_void_p]
    lib.CGEventGetFlags.restype = c.c_uint64
    lib.CGEventGetIntegerValueField.argtypes = [c.c_void_p, c.c_int32]
    lib.CGEventGetIntegerValueField.restype = c.c_int64
    return lib


@lru_cache(maxsize=1)
def _release():
    lib = c.CDLL("/System/Library/Frameworks/CoreFoundation.framework/CoreFoundation")
    lib.CFRelease.argtypes = [c.c_void_p]
    lib.CFRelease.restype = None
    return lib.CFRelease


class Event:
    def __init__(self, pointer):
        self.pointer = pointer
        self.release = _release()

    def __del__(self):
        if self.pointer:
            self.release(self.pointer)


kCGKeyboardEventKeycode = 9


def CGEventGetFlags(event):
    return int(_api().CGEventGetFlags(event.pointer))


def CGEventGetIntegerValueField(event, field):
    return int(_api().CGEventGetIntegerValueField(event.pointer, field))


def CGEventCreateKeyboardEvent(source, key_code, down):
    pointer = _api().CGEventCreateKeyboardEvent(source, key_code, down)
    return Event(pointer) if pointer else None


def CGEventSetFlags(event, flags):
    _api().CGEventSetFlags(event.pointer, flags)


def CGEventKeyboardSetUnicodeString(event, length, text):
    data = text.encode("utf-16-le")
    if length != len(data) // 2:
        raise ValueError("invalid UTF-16 length")
    buffer = (c.c_uint16 * length).from_buffer_copy(data)
    _api().CGEventKeyboardSetUnicodeString(event.pointer, length, buffer)


def CGEventPostToPid(pid, event):
    if os.environ.get("JRBAR_TESTING") == "1" or "PYTEST_CURRENT_TEST" in os.environ:
        raise RuntimeError("tests cannot post keyboard events")
    _api().CGEventPostToPid(pid, event.pointer)
