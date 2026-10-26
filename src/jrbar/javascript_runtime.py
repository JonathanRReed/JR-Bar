"""JavaScriptCore's C API for the packaged firmware, without framework wrappers."""
from __future__ import annotations

import ctypes
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
        "JSStringCreateWithCharacters": (pointer, [ctypes.POINTER(ctypes.c_uint16), ctypes.c_size_t]),
        "JSStringRelease": (None, [pointer]),
        "JSEvaluateScript": (pointer, [pointer, pointer, pointer, pointer, ctypes.c_int, ctypes.POINTER(pointer)]),
        "JSValueToStringCopy": (pointer, [pointer, pointer, ctypes.POINTER(pointer)]),
        "JSStringGetMaximumUTF8CStringSize": (ctypes.c_size_t, [pointer]),
        "JSStringGetUTF8CString": (ctypes.c_size_t, [pointer, pointer, ctypes.c_size_t]),
        "JSValueProtect": (None, [pointer, pointer]),
        "JSValueUnprotect": (None, [pointer, pointer]),
        "JSContextGetGlobalObject": (pointer, [pointer]),
        "JSObjectGetProperty": (pointer, [pointer, pointer, pointer, ctypes.POINTER(pointer)]),
        "JSValueToObject": (pointer, [pointer, pointer, ctypes.POINTER(pointer)]),
        "JSObjectIsFunction": (ctypes.c_bool, [pointer, pointer]),
        "JSObjectCallAsFunction": (pointer, [pointer, pointer, pointer, ctypes.c_size_t, ctypes.POINTER(pointer), ctypes.POINTER(pointer)]),
        "JSValueMakeNumber": (pointer, [pointer, ctypes.c_double]),
        "JSValueMakeBoolean": (pointer, [pointer, ctypes.c_bool]),
        "JSValueMakeNull": (pointer, [pointer]),
        "JSValueMakeString": (pointer, [pointer, pointer]),
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
        self.context = context
        self.pointer = None
        lib = context.library
        with context._lock:
            key = lib.JSStringCreateWithUTF8CString(name.encode())
            exception = ctypes.c_void_p()
            try:
                global_object = lib.JSContextGetGlobalObject(context.pointer)
                value = lib.JSObjectGetProperty(context.pointer, global_object, key, ctypes.byref(exception))
                function = lib.JSValueToObject(context.pointer, value, ctypes.byref(exception))
                if exception.value or not function or not lib.JSObjectIsFunction(context.pointer, function):
                    raise RuntimeError("JavaScriptCore firmware function unavailable")
                lib.JSValueProtect(context.pointer, function)
                self.pointer = function
            finally:
                lib.JSStringRelease(key)

    def __del__(self):
        if self.pointer:
            self.context.library.JSValueUnprotect(self.context.pointer, self.pointer)

    def callWithArguments_(self, arguments):
        context = self.context
        lib = context.library
        with context._lock:
            protected = []
            try:
                for argument in arguments:
                    if type(argument) is str:
                        encoded = argument.encode("utf-16-le", "surrogatepass")
                        units = (ctypes.c_uint16 * (len(encoded) // 2)).from_buffer_copy(encoded)
                        string = lib.JSStringCreateWithCharacters(units, len(units))
                        try:
                            value = lib.JSValueMakeString(context.pointer, string)
                        finally:
                            lib.JSStringRelease(string)
                    elif type(argument) is bool:
                        value = lib.JSValueMakeBoolean(context.pointer, argument)
                    elif argument is None:
                        value = lib.JSValueMakeNull(context.pointer)
                    else:
                        value = lib.JSValueMakeNumber(context.pointer, float(argument))
                    lib.JSValueProtect(context.pointer, value)
                    protected.append(value)
                values = (ctypes.c_void_p * len(protected))(*protected)
                exception = ctypes.c_void_p()
                value = lib.JSObjectCallAsFunction(context.pointer, self.pointer, None,
                    len(protected), values, ctypes.byref(exception))
                result_pointer = exception.value or value
                lib.JSValueProtect(context.pointer, result_pointer)
                try:
                    result = _Value(context._string(result_pointer))
                finally:
                    lib.JSValueUnprotect(context.pointer, result_pointer)
                context._exception = result if exception.value else None
                if exception.value:
                    raise RuntimeError(result.toString())
                return result
            finally:
                for value in protected:
                    lib.JSValueUnprotect(context.pointer, value)


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
