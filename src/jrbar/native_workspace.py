"""Headless sleep, display and session observations for standalone daemons."""
from __future__ import annotations

import ctypes as c
import time

from .accessibility_display import AccessibilityDisplayPreferences
from .core_environment import EVENTS
from .native_apple_http import _call, _class, _string
from .native_blocks import completion, discard
from .native_run_loop import Pump

CAN_SLEEP = 0xE0000270
WILL_SLEEP = 0xE0000280
HAS_POWERED_ON = 0xE0000300
POWER_CALLBACK = c.CFUNCTYPE(None, c.c_void_p, c.c_uint32, c.c_uint32, c.c_void_p)
PREFERENCE_KEYS = ("reduceMotion", "reduceTransparency", "increaseContrast", "differentiateWithoutColor")


def _bind(lib, signatures):
    for name, (result, arguments) in signatures.items():
        function = getattr(lib, name)
        function.restype, function.argtypes = result, arguments
    return lib


class NativeWorkspace:
    def __init__(self, controller):
        self.controller = controller
        self.closed = False
        self.tokens = []
        self.pump = Pump()
        self.port, self.notifier = c.c_void_p(), c.c_uint32()
        self.connection = 0
        self.next_read = 0.0
        self.last_display = self.last_session = None
        self.last_preferences = getattr(controller, "_accessibility_display_preferences", None)
        pointer = c.c_void_p
        self.cf = _bind(self.pump.lib, {
            "CFRunLoopAddSource": (None, [pointer, pointer, pointer]),
            "CFPreferencesCopyAppValue": (pointer, [pointer, pointer]),
            "CFDictionaryGetValue": (pointer, [pointer, pointer]),
            "CFBooleanGetValue": (c.c_bool, [pointer]),
            "CFGetTypeID": (c.c_ulong, [pointer]),
            "CFBooleanGetTypeID": (c.c_ulong, []),
        })
        self.graphics = _bind(c.CDLL("/System/Library/Frameworks/CoreGraphics.framework/CoreGraphics"), {
            "CGMainDisplayID": (c.c_uint32, []),
            "CGDisplayIsAsleep": (c.c_uint32, [c.c_uint32]),
            "CGSessionCopyCurrentDictionary": (pointer, []),
        })
        self.power = _bind(c.CDLL("/System/Library/Frameworks/IOKit.framework/IOKit"), {
            "IORegisterForSystemPower": (c.c_uint32, [pointer, c.POINTER(pointer), POWER_CALLBACK, c.POINTER(c.c_uint32)]),
            "IONotificationPortGetRunLoopSource": (pointer, [pointer]),
            "IOAllowPowerChange": (c.c_int, [c.c_uint32, c.c_long]),
            "IODeregisterForSystemPower": (c.c_int, [c.POINTER(c.c_uint32)]),
            "IONotificationPortDestroy": (None, [pointer]),
            "IOServiceClose": (c.c_int, [c.c_uint32]),
        })
        self.power_callback = POWER_CALLBACK(self._power_changed)
        try:
            self.connection = self.power.IORegisterForSystemPower(
                None, c.byref(self.port), self.power_callback, c.byref(self.notifier))
            if not self.connection:
                raise OSError("system power observer unavailable")
            source = self.power.IONotificationPortGetRunLoopSource(self.port)
            if not source:
                raise OSError("system power notification source unavailable")
            self.cf.CFRunLoopAddSource(self.pump.loop, source, self.pump.mode)
            center = _call(_class("NSNotificationCenter"), "defaultCenter", object_result=True)
            for name, event in (("NSSystemClockDidChangeNotification", "clock"),
                                ("NSSystemTimeZoneDidChangeNotification", "timezone")):
                block = completion(lambda _, edge=event: self.deliver(edge), (pointer,), b"v@?@", repeating=True)
                notification_name = _string(name)
                token = _call(center.pointer, "addObserverForName:object:queue:usingBlock:",
                              arguments=(pointer,) * 4,
                              values=(notification_name.pointer, None, None, c.byref(block)), object_result=True)
                if token is None:
                    discard(block)
                    raise RuntimeError("clock observer unavailable")
                self.tokens.append((center, token, block))
            self.poll()
        except BaseException:
            self.close()
            raise

    def _power_changed(self, _context, _service, message, notification):
        # Acknowledge immediately, even if queuing the policy callback fails.
        # Never veto sleep or make powerd wait for Python's event loop.
        try:
            if message == WILL_SLEEP:
                self.deliver("sleep")
            elif message == HAS_POWERED_ON:
                self.deliver("wake")
        finally:
            if message in (CAN_SLEEP, WILL_SLEEP):
                self.power.IOAllowPowerChange(self.connection, notification or 0)

    def _boolean(self, value):
        if value and self.cf.CFGetTypeID(value) == self.cf.CFBooleanGetTypeID():
            return bool(self.cf.CFBooleanGetValue(value))
        return None

    def preferences(self):
        domain = _string("com.apple.universalaccess")
        previous = self.last_preferences
        values = []
        for field, key in zip(AccessibilityDisplayPreferences.__dataclass_fields__, PREFERENCE_KEYS, strict=True):
            name = _string(key)
            value = self.cf.CFPreferencesCopyAppValue(name.pointer, domain.pointer)
            try:
                reading = self._boolean(value)
                # These preference keys are a fallback, not the AppKit API.
                # Missing or unsupported values keep the last good reading,
                # or reduce effects until the app supplies an exact snapshot.
                values.append(reading if reading is not None else getattr(previous, field, True))
            finally:
                if value:
                    self.cf.CFRelease(value)
        return AccessibilityDisplayPreferences(*values)

    def deliver(self, event):
        from .daemon_loop import application

        application().post(lambda: self._deliver(event))

    def _deliver(self, event):
        if not self.closed:
            self.controller.performSelectorOnMainThread_withObject_waitUntilDone_(EVENTS[event].replace("_", ":"), None, False)

    def poll(self):
        if self.closed:
            return
        self.pump.run(0)
        now = time.monotonic()
        if now < self.next_read:
            return
        self.next_read = now + 1.0
        preferences = self.preferences()
        if preferences != self.last_preferences:
            self.last_preferences = preferences
            self.controller._apply_accessibility_display_preferences(preferences)
        display = bool(self.graphics.CGDisplayIsAsleep(self.graphics.CGMainDisplayID()))
        if display != self.last_display:
            self.last_display = display
            self.deliver("screens_sleep" if display else "screens_wake")
        session = self.graphics.CGSessionCopyCurrentDictionary()
        if session:
            try:
                name = _string("kCGSSessionOnConsoleKey")
                active = self._boolean(self.cf.CFDictionaryGetValue(session, name.pointer))
                if active is not None and active != self.last_session:
                    self.last_session = active
                    self.deliver("session_active" if active else "session_inactive")
            finally:
                self.cf.CFRelease(session)

    def close(self):
        if self.closed:
            return
        self.closed = True
        if self.notifier.value:
            self.power.IODeregisterForSystemPower(c.byref(self.notifier))
        if self.port.value:
            self.power.IONotificationPortDestroy(self.port)
        if self.connection:
            self.power.IOServiceClose(self.connection)
        for center, token, block in self.tokens:
            _call(center.pointer, "removeObserver:", None, (c.c_void_p,), (token.pointer,))
            discard(block)
        self.tokens.clear()
        self.pump.close()
