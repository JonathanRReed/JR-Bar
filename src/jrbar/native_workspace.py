"""Workspace fallback for old apps and standalone daemons, without PyObjC."""
from __future__ import annotations

import ctypes as c

from .accessibility_display import _SELECTORS, AccessibilityDisplayPreferences
from .core_environment import EVENTS
from .native_apple_http import _call, _class, _string
from .native_blocks import completion, discard
from .native_run_loop import Pump

NOTIFICATIONS = {
    "NSWorkspaceDidWakeNotification": "wake",
    "NSWorkspaceWillSleepNotification": "sleep",
    "NSWorkspaceScreensDidWakeNotification": "screens_wake",
    "NSWorkspaceScreensDidSleepNotification": "screens_sleep",
    "NSWorkspaceSessionDidBecomeActiveNotification": "session_active",
    "NSWorkspaceSessionDidResignActiveNotification": "session_inactive",
    "NSWorkspaceAccessibilityDisplayOptionsDidChangeNotification": "accessibility",
    "NSSystemClockDidChangeNotification": "clock",
    "NSSystemTimeZoneDidChangeNotification": "timezone",
}


class NativeWorkspace:
    def __init__(self, controller):
        c.CDLL("/System/Library/Frameworks/AppKit.framework/AppKit")
        self.controller = controller
        self.closed = False
        self.workspace = _call(_class("NSWorkspace"), "sharedWorkspace", object_result=True)
        self.tokens = []
        self.pump = Pump()
        workspace_center = _call(self.workspace.pointer, "notificationCenter", object_result=True)
        default_center = _call(_class("NSNotificationCenter"), "defaultCenter", object_result=True)
        try:
            for name, event in NOTIFICATIONS.items():
                center = default_center if name.startswith("NSSystem") else workspace_center
                block = completion(lambda _, edge=event: self.deliver(edge), (c.c_void_p,), b"v@?@", repeating=True)
                notification_name = _string(name)
                token = _call(center.pointer, "addObserverForName:object:queue:usingBlock:",
                              arguments=(c.c_void_p,) * 4,
                              values=(notification_name.pointer, None, None, c.byref(block)), object_result=True)
                if token is None:
                    discard(block)
                    raise RuntimeError("workspace observer unavailable")
                self.tokens.append((center, token, block))
            self.deliver("accessibility")
        except BaseException:
            self.close()
            raise

    def preferences(self):
        return AccessibilityDisplayPreferences(*(
            bool(_call(self.workspace.pointer, selector, c.c_bool)) for selector in _SELECTORS
        ))

    def deliver(self, event):
        from .daemon_loop import application

        application().post(lambda: self._deliver(event))

    def _deliver(self, event):
        if self.closed:
            return
        if event == "accessibility":
            self.controller._apply_accessibility_display_preferences(self.preferences())
        else:
            self.controller.performSelectorOnMainThread_withObject_waitUntilDone_(EVENTS[event].replace("_", ":"), None, False)

    def poll(self):
        self.pump.run(0)

    def close(self):
        self.closed = True
        for center, token, block in self.tokens:
            _call(center.pointer, "removeObserver:", None, (c.c_void_p,), (token.pointer,))
            discard(block)
        self.tokens.clear()
        self.pump.close()
