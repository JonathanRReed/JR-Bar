"""Local workspace readings supplied by the native app, without a GUI bridge."""
from __future__ import annotations

from .accessibility_display import AccessibilityDisplayPreferences
from .core_server import CommandError


class EnvironmentCenter:
    """Subscriptions to native readings received over the local socket."""
    def __init__(self):
        self.observers = []

    @classmethod
    def defaultCenter(cls):
        return _center

    def addObserver_selector_name_object_(self, target, selector, name, _object):
        self.observers.append((target, selector, name))

    def removeObserver_(self, target):
        self.observers = [row for row in self.observers if row[0] is not target]

    def removeObserver_name_object_(self, target, name, _object):
        self.observers = [row for row in self.observers if not (row[0] is target and row[2] == name)]


_center = EnvironmentCenter()
_preferences = None


class Workspace:
    @classmethod
    def sharedWorkspace(cls):
        return _workspace

    def notificationCenter(self):
        return _center

    def __getattr__(self, selector):
        keys = {"accessibilityDisplayShouldReduceMotion": "reduce_motion",
                "accessibilityDisplayShouldReduceTransparency": "reduce_transparency",
                "accessibilityDisplayShouldIncreaseContrast": "increase_contrast",
                "accessibilityDisplayShouldDifferentiateWithoutColor": "differentiate_without_color"}
        if selector not in keys:
            raise AttributeError(selector)
        if _preferences is None:
            raise RuntimeError("native app has not reported display preferences")
        return lambda: getattr(_preferences, keys[selector])


_workspace = Workspace()

EVENTS = {
    "wake": "dndWorkspaceDidWake_", "sleep": "dndWorkspaceWillSleep_",
    "screens_wake": "dndScreensDidWake_", "screens_sleep": "dndScreensDidSleep_",
    "session_active": "dndSessionDidBecomeActive_", "session_inactive": "dndSessionDidResignActive_",
    "clock": "dndSystemClockDidChange_", "timezone": "dndSystemTimeZoneDidChange_",
}
_frontmost = None


def frontmost_bundle():
    return _frontmost


def report(controller, args):
    global _frontmost, _preferences
    event = args.get("event", "snapshot")
    if type(event) is not str or event not in {*EVENTS, "snapshot", "accessibility"}:
        raise CommandError("invalid_args", "unknown workspace event")
    raw = args.get("accessibility")
    preferences = None
    if raw is not None:
        if not isinstance(raw, dict) or any(type(raw.get(key)) is not bool for key in AccessibilityDisplayPreferences.__dataclass_fields__):
            raise CommandError("invalid_args", "accessibility flags must be boolean")
        preferences = AccessibilityDisplayPreferences(**{key: raw[key] for key in AccessibilityDisplayPreferences.__dataclass_fields__})
    frontmost = args.get("frontmost")
    if frontmost is not None and (type(frontmost) is not str or len(frontmost) > 255):
        raise CommandError("invalid_args", "invalid frontmost bundle identifier")
    for key in ("display_asleep", "session_active"):
        if key in args and type(args[key]) is not bool:
            raise CommandError("invalid_args", f"{key} must be boolean")
    _frontmost = frontmost
    if preferences is not None:
        _preferences = preferences
        controller._apply_accessibility_display_preferences(preferences)
    if event in EVENTS:
        getattr(controller, EVENTS[event])(None)
    if event == "snapshot":
        if "display_asleep" in args:
            getattr(controller, "dndScreensDidSleep_" if args["display_asleep"] else "dndScreensDidWake_")(None)
        if "session_active" in args:
            getattr(controller, "dndSessionDidBecomeActive_" if args["session_active"] else "dndSessionDidResignActive_")(None)
    return {"accepted": True}
