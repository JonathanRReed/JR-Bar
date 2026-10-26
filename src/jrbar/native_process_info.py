"""The few Foundation and Intents reads the daemon needs, without PyObjC."""
from __future__ import annotations

import ctypes
import os
from functools import lru_cache


@lru_cache(maxsize=1)
def _runtime():
    ctypes.CDLL("/System/Library/Frameworks/Foundation.framework/Foundation")
    runtime = ctypes.CDLL("/usr/lib/libobjc.A.dylib")
    runtime.objc_getClass.argtypes = [ctypes.c_char_p]
    runtime.objc_getClass.restype = ctypes.c_void_p
    runtime.sel_registerName.argtypes = [ctypes.c_char_p]
    runtime.sel_registerName.restype = ctypes.c_void_p
    runtime.objc_retain.argtypes = [ctypes.c_void_p]
    runtime.objc_retain.restype = ctypes.c_void_p
    runtime.objc_release.argtypes = [ctypes.c_void_p]
    runtime.objc_release.restype = None
    runtime.objc_autoreleasePoolPush.restype = ctypes.c_void_p
    runtime.objc_autoreleasePoolPop.argtypes = [ctypes.c_void_p]
    return runtime


@lru_cache(maxsize=32)
def _sender(result_type):
    # Separate typed function pointers keep concurrent readers from changing
    # objc_msgSend's shared ctypes signature underneath another call.
    return ctypes.CFUNCTYPE(result_type, ctypes.c_void_p, ctypes.c_void_p)(
        ("objc_msgSend", _runtime()))


def _send(receiver, selector, result_type=ctypes.c_void_p):
    runtime = _runtime()
    pool = runtime.objc_autoreleasePoolPush()
    try:
        value = _sender(result_type)(receiver, runtime.sel_registerName(selector.encode()))
        if result_type is ctypes.c_void_p and value:
            value = runtime.objc_retain(value)
        return value
    finally:
        runtime.objc_autoreleasePoolPop(pool)


class _Object:
    def __init__(self, pointer):
        if not pointer:
            raise RuntimeError("native object unavailable")
        self.pointer = pointer

    def __del__(self):
        if getattr(self, "pointer", None):
            _runtime().objc_release(self.pointer)


class ProcessInfo(_Object):
    @classmethod
    def processInfo(cls):
        return cls(_send(_runtime().objc_getClass(b"NSProcessInfo"), "processInfo"))

    def thermalState(self):
        return int(_send(self.pointer, "thermalState", ctypes.c_long))

    def isLowPowerModeEnabled(self):
        return bool(_send(self.pointer, "isLowPowerModeEnabled", ctypes.c_bool))


class FocusStatus(_Object):
    def isFocused(self):
        pointer = _send(self.pointer, "isFocused")
        if not pointer:
            return None
        number = _Object(pointer)
        return bool(_send(number.pointer, "boolValue", ctypes.c_bool))


class FocusCenter(_Object):
    @classmethod
    def defaultCenter(cls):
        ctypes.CDLL("/System/Library/Frameworks/Intents.framework/Intents")
        return cls(_send(_runtime().objc_getClass(b"INFocusStatusCenter"), "defaultCenter"))

    def authorizationStatus(self):
        return int(_send(self.pointer, "authorizationStatus", ctypes.c_long))

    def focusStatus(self):
        return FocusStatus(_send(self.pointer, "focusStatus"))

    def requestAuthorizationWithCompletionHandler_(self, callback):
        if os.environ.get("JRBAR_TESTING") == "1" or "PYTEST_CURRENT_TEST" in os.environ:
            raise RuntimeError("tests cannot request Focus access")
        from .native_apple_http import _call
        from .native_blocks import completion, discard

        block = completion(callback, (ctypes.c_long,), b"v@?q")
        try:
            _call(self.pointer, "requestAuthorizationWithCompletionHandler:", None,
                (ctypes.c_void_p,), (ctypes.byref(block),))
        except BaseException:
            discard(block)
            raise
