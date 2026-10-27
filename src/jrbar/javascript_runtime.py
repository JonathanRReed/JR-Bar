"""Retained native JavaScriptCore values for the packaged firmware, without PyObjC."""
from __future__ import annotations

import ctypes
import threading
from functools import lru_cache

from .native_apple_http import _call, _class
from .native_process_info import _Object


@lru_cache(maxsize=1)
def _library():
    library = ctypes.CDLL("/System/Library/Frameworks/JavaScriptCore.framework/JavaScriptCore")
    library.JSObjectIsFunction.argtypes = [ctypes.c_void_p, ctypes.c_void_p]
    library.JSObjectIsFunction.restype = ctypes.c_bool
    return library


def _string(text):
    encoded = text.encode("utf-16-le", "surrogatepass")
    units = (ctypes.c_uint16 * (len(encoded) // 2)).from_buffer_copy(encoded)
    return _call(_class("NSString"), "stringWithCharacters:length:",
                 arguments=(ctypes.POINTER(ctypes.c_uint16), ctypes.c_ulong),
                 values=(units, len(units)), object_result=True)


def _argument(value):
    if type(value) is str:
        return _string(value)
    if value is None:
        return _call(_class("NSNull"), "null", object_result=True)
    if type(value) is bool:
        return _call(_class("NSNumber"), "numberWithBool:", arguments=(ctypes.c_bool,),
                     values=(value,), object_result=True)
    return _call(_class("NSNumber"), "numberWithDouble:", arguments=(ctypes.c_double,),
                 values=(float(value),), object_result=True)


class _Value:
    def __init__(self, text):
        self.text = text

    def toString(self):
        return self.text


class _Function:
    def __init__(self, context, name):
        self.context = context
        with context._lock:
            key = _string(name)
            self._native = _call(context._native.pointer, "objectForKeyedSubscript:",
                                 arguments=(ctypes.c_void_p,), values=(key.pointer,), object_result=True)
            exception = context._read_exception()
            if exception is not None or not self._native or not _call(self._native.pointer, "isObject", ctypes.c_bool):
                raise RuntimeError("JavaScriptCore firmware function unavailable")
            value = _call(self._native.pointer, "JSValueRef")
            if not context.library.JSObjectIsFunction(context.pointer, value):
                raise RuntimeError("JavaScriptCore firmware function unavailable")

    def callWithArguments_(self, arguments):
        context = self.context
        with context._lock:
            values = _call(_class("NSMutableArray"), "array", object_result=True)
            for argument in arguments:
                value = _argument(argument)
                _call(values.pointer, "addObject:", None, (ctypes.c_void_p,), (value.pointer,))
            result = _call(self._native.pointer, "callWithArguments:",
                           arguments=(ctypes.c_void_p,), values=(values.pointer,), object_result=True)
            exception = context._read_exception()
            if exception is not None:
                raise RuntimeError(exception.toString())
            return _Value(context._string(result))


class JavaScriptContext:
    def __init__(self):
        self.library = _library()
        self._native = _Object(_call(_class("JSContext"), "new"))
        self.pointer = _call(self._native.pointer, "JSGlobalContextRef")
        self._lock = threading.Lock()
        self._exception = None

    def _string(self, value):
        # JSValue protects its JSValueRef before returning to Python. Keeping
        # that native object retained closes the C-return-to-JSValueProtect gap.
        if value is None:
            raise RuntimeError("JavaScriptCore value is not readable")
        string = _call(value.pointer, "toString", object_result=True)
        if string is None:
            raise RuntimeError("JavaScriptCore value is not readable")
        length = _call(string.pointer, "length", ctypes.c_ulong)
        units = (ctypes.c_uint16 * length)()
        _call(string.pointer, "getCharacters:", None,
              (ctypes.POINTER(ctypes.c_uint16),), (units,))
        return bytes(units).decode("utf-16-le", "surrogatepass")

    def evaluateScript_(self, source):
        with self._lock:
            script = _string(source)
            result = _call(self._native.pointer, "evaluateScript:",
                           arguments=(ctypes.c_void_p,), values=(script.pointer,), object_result=True)
            exception = self._read_exception()
            return exception if exception is not None else _Value(self._string(result))

    def _read_exception(self):
        exception = _call(self._native.pointer, "exception", object_result=True)
        try:
            self._exception = _Value(self._string(exception)) if exception else None
            return self._exception
        finally:
            if exception:
                # A native exception value retains its context. Keep only its
                # copied text so the context does not retain itself through it.
                _call(self._native.pointer, "setException:", None, (ctypes.c_void_p,), (None,))

    def exception(self):
        return self._exception

    def objectForKeyedSubscript_(self, name):
        if name not in {"sdledParse", "sdledStep", "sdledStepBatch", "sdledReset"}:
            raise ValueError("unknown firmware entry point")
        return _Function(self, name)
