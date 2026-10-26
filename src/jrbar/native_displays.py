"""The daemon's read-only CoreGraphics display queries through its C API."""
import ctypes as c
from functools import lru_cache


@lru_cache(maxsize=1)
def library():
    lib = c.CDLL("/System/Library/Frameworks/CoreGraphics.framework/CoreGraphics")
    lib.CGMainDisplayID.restype = c.c_uint32
    for name in ("CGDisplayIsActive", "CGDisplayIsAsleep", "CGDisplayIsBuiltin"):
        function = getattr(lib, name)
        function.argtypes, function.restype = [c.c_uint32], c.c_bool
    lib.CGGetOnlineDisplayList.argtypes = [c.c_uint32, c.POINTER(c.c_uint32), c.POINTER(c.c_uint32)]
    lib.CGGetOnlineDisplayList.restype = c.c_int32
    return lib


def main_display_id():
    return int(library().CGMainDisplayID())


def display_state(display_id):
    lib = library()
    return (bool(lib.CGDisplayIsActive(display_id)), bool(lib.CGDisplayIsAsleep(display_id)), bool(lib.CGDisplayIsBuiltin(display_id)))


def external_display_is_active():
    lib = library()
    displays = (c.c_uint32 * 32)()
    count = c.c_uint32()
    if lib.CGGetOnlineDisplayList(32, displays, c.byref(count)) or not 0 < count.value < 32:
        return None
    return any(lib.CGDisplayIsActive(display) and not lib.CGDisplayIsBuiltin(display) for display in displays[:count.value])


def user_is_away(idle_seconds):
    lib = library()
    lib.CGSessionCopyCurrentDictionary.restype = c.c_void_p
    lib.CGEventSourceSecondsSinceLastEventType.argtypes = [c.c_int32, c.c_uint32]
    lib.CGEventSourceSecondsSinceLastEventType.restype = c.c_double
    cf = c.CDLL("/System/Library/Frameworks/CoreFoundation.framework/CoreFoundation")
    cf.CFStringCreateWithCString.argtypes = [c.c_void_p, c.c_char_p, c.c_uint32]
    cf.CFStringCreateWithCString.restype = c.c_void_p
    cf.CFDictionaryGetValue.argtypes = [c.c_void_p, c.c_void_p]
    cf.CFDictionaryGetValue.restype = c.c_void_p
    cf.CFBooleanGetValue.argtypes = [c.c_void_p]
    cf.CFBooleanGetValue.restype = c.c_bool
    cf.CFRelease.argtypes = [c.c_void_p]
    session = lib.CGSessionCopyCurrentDictionary()
    key = cf.CFStringCreateWithCString(None, b"CGSSessionScreenIsLocked", 0x08000100)
    try:
        locked = cf.CFDictionaryGetValue(session, key) if session else None
        if locked and cf.CFBooleanGetValue(locked):
            return True
        return float(lib.CGEventSourceSecondsSinceLastEventType(0, 0xFFFFFFFF)) >= idle_seconds
    finally:
        if session:
            cf.CFRelease(session)
        if key:
            cf.CFRelease(key)
