"""LaunchServices and process identities without importing an AppKit host."""
from __future__ import annotations

import ctypes as c
import os
import plistlib
from functools import lru_cache
from pathlib import Path

from .native_apple_http import _call, _class, _string, _text
from .native_process_info import _Object


class SerialNumber(c.Structure):
    _fields_ = [("high", c.c_uint32), ("low", c.c_uint32)]


@lru_cache(maxsize=1)
def _library():
    lib = c.CDLL("/System/Library/Frameworks/ApplicationServices.framework/ApplicationServices")
    pointer = c.c_void_p
    signatures = {
        "GetFrontProcess": (c.c_int32, [c.POINTER(SerialNumber)]),
        "GetProcessPID": (c.c_int32, [c.POINTER(SerialNumber), c.POINTER(c.c_int32)]),
        "GetProcessForPID": (c.c_int32, [c.c_int32, c.POINTER(SerialNumber)]),
        "SetFrontProcessWithOptions": (c.c_int32, [c.POINTER(SerialNumber), c.c_uint32]),
        "ProcessInformationCopyDictionary": (pointer, [c.POINTER(SerialNumber), c.c_uint32]),
        "LSCopyApplicationURLsForBundleIdentifier": (pointer, [pointer, c.POINTER(pointer)]),
        "LSCopyDefaultApplicationURLForURL": (pointer, [pointer, c.c_uint32, c.POINTER(pointer)]),
        "LSOpenCFURLRef": (c.c_int32, [pointer, c.POINTER(pointer)]),
        "CFArrayGetCount": (c.c_long, [pointer]),
        "CFArrayGetValueAtIndex": (pointer, [pointer, c.c_long]),
        "CFRetain": (pointer, [pointer]),
        "CFRelease": (None, [pointer]),
    }
    for name, (result, args) in signatures.items():
        function = getattr(lib, name)
        function.restype, function.argtypes = result, args
    return lib


class URL(_Object):
    def path(self):
        result = _call(self.pointer, "path", object_result=True)
        return _text(result.pointer) if result else ""


def url(text):
    value = _string(text)
    result = _call(_class("NSURL"), "URLWithString:", arguments=(c.c_void_p,), values=(value.pointer,), object_result=True)
    return result


def _application_urls(bundle_id):
    lib = _library()
    key = _string(bundle_id)
    error = c.c_void_p()
    array = lib.LSCopyApplicationURLsForBundleIdentifier(key.pointer, c.byref(error))
    if error.value:
        lib.CFRelease(error)
    if not array:
        return []
    try:
        return [URL(lib.CFRetain(lib.CFArrayGetValueAtIndex(array, index))) for index in range(lib.CFArrayGetCount(array))]
    finally:
        lib.CFRelease(array)


def bundle_for_executable(command):
    for parent in Path(command).parents:
        if parent.suffix == ".app":
            try:
                with (parent / "Contents" / "Info.plist").open("rb") as stream:
                    return plistlib.load(stream).get("CFBundleIdentifier")
            except (OSError, ValueError, plistlib.InvalidFileException):
                return None
    return None


class RunningApplication:
    def __init__(self, bundle_id, pid):
        self.bundle_id, self.pid = bundle_id, pid

    def bundleIdentifier(self):
        return self.bundle_id

    def processIdentifier(self):
        return self.pid

    @classmethod
    def runningApplicationsWithBundleIdentifier_(cls, bundle_id):
        from .process_registry import list_processes

        roots = [Path(candidate.path()) for candidate in _application_urls(bundle_id)]
        return [cls(bundle_id, entry.pid) for entry in list_processes(fresh=True).values()
                if any(root in Path(entry.command).parents for root in roots)
                and bundle_for_executable(entry.command) == bundle_id]

    def activateWithOptions_(self, _options):
        if os.environ.get("JRBAR_TESTING") == "1" or "PYTEST_CURRENT_TEST" in os.environ:
            raise RuntimeError("tests cannot activate applications")
        lib = _library()
        serial = SerialNumber()
        return not lib.GetProcessForPID(self.pid, c.byref(serial)) and not lib.SetFrontProcessWithOptions(c.byref(serial), 1)


class Workspace:
    @classmethod
    def sharedWorkspace(cls):
        return cls()

    def frontmostApplication(self):
        lib = _library()
        serial, pid = SerialNumber(), c.c_int32()
        if lib.GetFrontProcess(c.byref(serial)) or lib.GetProcessPID(c.byref(serial), c.byref(pid)):
            return None
        dictionary = lib.ProcessInformationCopyDictionary(c.byref(serial), 0xFFFFFFFF)
        if not dictionary:
            return None
        try:
            key = _string("CFBundleIdentifier")
            value = _call(dictionary, "objectForKey:", arguments=(c.c_void_p,), values=(key.pointer,), object_result=True)
            bundle = _text(value.pointer) if value else None
            return RunningApplication(bundle, pid.value)
        finally:
            lib.CFRelease(dictionary)

    def URLForApplicationWithBundleIdentifier_(self, bundle_id):
        candidates = _application_urls(bundle_id)
        return candidates[0] if candidates else None

    def URLForApplicationToOpenURL_(self, value):
        error = c.c_void_p()
        result = _library().LSCopyDefaultApplicationURLForURL(value.pointer, 0xFFFFFFFF, c.byref(error))
        if error.value:
            _library().CFRelease(error)
        return URL(result) if result else None

    def openURL_(self, value):
        if os.environ.get("JRBAR_TESTING") == "1" or "PYTEST_CURRENT_TEST" in os.environ:
            raise RuntimeError("tests cannot open applications")
        return _library().LSOpenCFURLRef(value.pointer, None) == 0
