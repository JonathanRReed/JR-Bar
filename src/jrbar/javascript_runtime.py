"""JavaScriptCore's C API for the packaged firmware, without framework wrappers."""
from __future__ import annotations

import ctypes
import json
import threading
from functools import lru_cache


@lru_cache(maxsize=1)
def _library():
    lib = ctypes.CDLL("/System/Library/Frameworks/JavaScriptCore.framework/JavaScriptCore")
    pointer = ctypes.c_void_p
    signatures = {
        "JSGlobalContextCreate": (pointer, [pointer]),
        "JSGlobalContextRelease": (None, [pointer]),
        "JSStringCreateWithUTF8CString": (pointer, [ctypes.c_char_p]),
        "JSStringRelease": (None, [pointer]),
        "JSEvaluateScript": (pointer, [pointer, pointer, pointer, pointer, ctypes.c_int, ctypes.POINTER(pointer)]),
        "JSValueToStringCopy": (pointer, [pointer, pointer, ctypes.POINTER(pointer)]),
        "JSStringGetMaximumUTF8CStringSize": (ctypes.c_size_t, [pointer]),
        "JSStringGetUTF8CString": (ctypes.c_size_t, [pointer, pointer, ctypes.c_size_t]),
        "JSValueProtect": (None, [pointer, pointer]),
        "JSValueUnprotect": (None, [pointer, pointer]),
    }
    for name, (result, args) in signatures.items():
        function = getattr(lib, name)
        function.restype, function.argtypes = result, args
    return lib


class _Value:
    def __init__(self, text):
        self.text = text

    def toString(self):
        return self.text


class _Function:
    def __init__(self, context, name):
        self.context, self.name = context, name

    def callWithArguments_(self, arguments):
        expression = self.name + "(" + ",".join(json.dumps(value) for value in arguments) + ")"
        value = self.context.evaluateScript_(expression)
        error = self.context.exception()
        if error is not None:
            raise RuntimeError(error.toString())
        return value


class JavaScriptContext:
    def __init__(self):
        self.library = _library()
        self.pointer = self.library.JSGlobalContextCreate(None)
        if not self.pointer:
            raise RuntimeError("JavaScriptCore context unavailable")
        self._lock = threading.Lock()
        self._exception = None

    def __del__(self):
        if getattr(self, "pointer", None):
            self.library.JSGlobalContextRelease(self.pointer)

    def _string(self, value):
        string = self.library.JSValueToStringCopy(self.pointer, value, None)
        if not string:
            raise RuntimeError("JavaScriptCore value is not readable")
        try:
            capacity = self.library.JSStringGetMaximumUTF8CStringSize(string)
            buffer = ctypes.create_string_buffer(capacity)
            size = self.library.JSStringGetUTF8CString(string, buffer, capacity)
            return buffer.raw[:max(0, size - 1)].decode("utf-8")
        finally:
            self.library.JSStringRelease(string)

    def evaluateScript_(self, source):
        with self._lock:
            script = self.library.JSStringCreateWithUTF8CString(source.encode("utf-8"))
            exception = ctypes.c_void_p()
            try:
                value = self.library.JSEvaluateScript(self.pointer, script, None, None, 1, ctypes.byref(exception))
                pointer = exception.value or value
                self.library.JSValueProtect(self.pointer, pointer)
                try:
                    result = _Value(self._string(pointer))
                finally:
                    self.library.JSValueUnprotect(self.pointer, pointer)
                self._exception = result if exception.value else None
                return result
            finally:
                self.library.JSStringRelease(script)

    def exception(self):
        return self._exception

    def objectForKeyedSubscript_(self, name):
        if name not in {"sdledParse", "sdledStep", "sdledStepBatch", "sdledReset"}:
            raise ValueError("unknown firmware entry point")
        return _Function(self, name)
