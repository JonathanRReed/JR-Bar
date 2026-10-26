"""Exercise native loaders without external actions or private data reads."""
from __future__ import annotations

import ctypes as c
import os
from contextlib import contextmanager
from types import SimpleNamespace

NATIVE_STEPS = ("native_process_info", "native_applications", "native_displays", "native_events",
                "native_eventkit", "native_sound", "native_run_loop", "native_blocks",
                "native_apple_http", "native_workspace", "keychain_read", "hid")


@contextmanager
def replaced(owner, name, value):
    previous = getattr(owner, name)
    setattr(owner, name, value)
    try:
        yield
    finally:
        setattr(owner, name, previous)


def refused(action):
    try:
        action()
    except RuntimeError:
        return
    raise AssertionError("native action was not refused in testing mode")


def native_process_info():
    from .native_process_info import FocusCenter, ProcessInfo

    info = ProcessInfo.processInfo()
    assert info.thermalState() in range(4)
    assert type(info.isLowPowerModeEnabled()) is bool
    center = FocusCenter.defaultCenter()
    center.authorizationStatus()
    center.focusStatus().isFocused()
    refused(lambda: center.requestAuthorizationWithCompletionHandler_(lambda _: None))


def native_applications():
    from .native_applications import URL, RunningApplication, Workspace, bundle_for_executable, url

    workspace = Workspace.sharedWorkspace()
    frontmost = workspace.frontmostApplication()
    if frontmost:
        frontmost.bundleIdentifier()
        frontmost.processIdentifier()
    value = url("file:///nonexistent-jrbar-probe.txt")
    wrapped = URL(value.pointer)
    value.pointer = None
    wrapped.path()
    workspace.URLForApplicationWithBundleIdentifier_("dev.jrbar.packaging.nonexistent")
    workspace.URLForApplicationToOpenURL_(url("file:///nonexistent-jrbar-probe.txt"))
    RunningApplication.runningApplicationsWithBundleIdentifier_("dev.jrbar.packaging.nonexistent")
    bundle_for_executable("/nonexistent-jrbar-probe")
    refused(lambda: RunningApplication("dev.jrbar.packaging.nonexistent", 0).activateWithOptions_(0))
    refused(lambda: workspace.openURL_(url("file:///nonexistent-jrbar-probe.txt")))


def native_displays():
    from . import native_displays as native

    native.display_state(native.main_display_id())
    native.external_display_is_active()
    native.user_is_away(60)


def native_events():
    from . import native_events as native

    native._api()
    # Creating a process-local event does not post input.
    event = native.CGEventCreateKeyboardEvent(None, 0, True)
    assert event is not None
    native.CGEventSetFlags(event, 0)
    native.CGEventGetFlags(event)
    native.CGEventGetIntegerValueField(event, native.kCGKeyboardEventKeycode)
    native.CGEventKeyboardSetUnicodeString(event, 1, "x")
    refused(lambda: native.CGEventPostToPid(0, event))


def native_eventkit():
    from . import native_eventkit as native
    from .native_apple_http import _class
    from .native_blocks import Block

    native._framework()
    with replaced(native, "os", SimpleNamespace(environ={})):
        for entity in (0, 1):
            native.EKEventStore.authorizationStatusForEntityType_(entity)
    store = native.EKEventStore.alloc().init()
    now = native.Date.date()
    end = native.Date.dateWithTimeIntervalSince1970_(now.timeIntervalSince1970() + 1)
    event_predicate = store.predicateForEventsWithStartDate_endDate_calendars_(now, end, None)
    reminder_predicate = store.predicateForIncompleteRemindersWithDueDateStarting_ending_calendars_(now, end, None)
    for action in (store.requestFullAccessToEventsWithCompletion_, store.requestFullAccessToRemindersWithCompletion_):
        refused(lambda: action(lambda *_: None))
    call = native._call

    def safe_call(receiver, selector, *args, **kwargs):
        if selector == "eventsMatchingPredicate:":
            return None
        if selector == "fetchRemindersMatchingPredicate:completion:":
            block = c.cast(kwargs["values"][1], c.POINTER(Block)).contents
            c.CFUNCTYPE(None, c.c_void_p, c.c_void_p)(block.invoke)(c.byref(block), None)
            return None
        return call(receiver, selector, *args, **kwargs)

    with replaced(native, "_call", safe_call):
        assert store.eventsMatchingPredicate_(event_predicate) == []
        rows = []
        store.fetchRemindersMatchingPredicate_completion_(reminder_predicate, rows.append)
        assert rows == [[]]
    value = call(_class("EKEvent"), "eventWithEventStore:", arguments=(c.c_void_p,),
                 values=(store.pointer,), object_result=True)
    event = native.CalendarEvent(value.pointer)
    value.pointer = None
    event.isAllDay()
    event.startDate()
    value = call(_class("EKReminder"), "reminderWithEventStore:", arguments=(c.c_void_p,),
                 values=(store.pointer,), object_result=True)
    reminder = native.Reminder(value.pointer)
    value.pointer = None
    reminder.isCompleted()
    reminder.calendarItemIdentifier()
    reminder.title()


def native_sound():
    from . import native_sound as native

    library, sound = native._sound()
    refused(native.play_reset_sound)
    played = []
    with replaced(library, "AudioServicesPlaySystemSound", played.append), replaced(native, "os", SimpleNamespace(environ={})):
        assert native.play_reset_sound()
    assert played == [sound]


def native_run_loop():
    from .native_run_loop import Pump

    pump = Pump()
    try:
        pump.run(0)
    finally:
        pump.close()


def native_blocks():
    from .native_blocks import completion, discard

    delivered = []
    block = completion(delivered.append, (c.c_long,), b"v@?q")
    c.CFUNCTYPE(None, c.c_void_p, c.c_long)(block.invoke)(c.byref(block), 1)
    discard(block)
    assert delivered == [1]


def native_apple_http():
    from . import native_apple_http as native

    call = native._call

    def safe_call(receiver, selector, *args, **kwargs):
        if selector == "resume":
            # No task is resumed, so NSURLSession sends no request or DNS.
            for callback in list(native._callbacks.values()):
                callback(None, None, 1)
            return None
        return call(receiver, selector, *args, **kwargs)

    with replaced(native, "_call", safe_call):
        try:
            native.request("https://jrbar.invalid/", method="POST", headers={"X-Probe": "synthetic"}, body=b"probe", timeout=1)
        except OSError:
            pass
        else:
            raise AssertionError("HTTP probe must complete with its synthetic error")


def native_workspace():
    from .native_workspace import CAN_SLEEP, HAS_POWERED_ON, WILL_SLEEP, NativeWorkspace

    owner = NativeWorkspace(SimpleNamespace(_apply_accessibility_display_preferences=lambda _: None,
        performSelectorOnMainThread_withObject_waitUntilDone_=lambda *_: None))
    try:
        owner.poll()
        owner.preferences()
        with replaced(owner, "power", SimpleNamespace(IOAllowPowerChange=lambda *_: 0)):
            for message in (CAN_SLEEP, WILL_SLEEP, HAS_POWERED_ON):
                owner._power_changed(None, 0, message, 0)
    finally:
        owner.close()


def keychain_read():
    from .keychain_read import _load_api

    # Bind Security without opening a Keychain, reading an item, changing
    # interaction policy or requesting a dialog.
    _load_api()


def hid():
    import hid

    from .creator_micro_hidapi import _enable_macos_nonexclusive

    # Import the real extension even with discovery off. Never enumerate,
    # open or exchange reports with physical HID devices in this probe.
    _enable_macos_nonexclusive(hid)


def exercise(snapshot):
    if os.environ.get("JRBAR_TESTING") != "1":
        raise RuntimeError("native probe requires JRBAR_TESTING=1")
    steps = []
    for name in NATIVE_STEPS:
        error = None
        try:
            globals()[name]()
        except Exception as failure:
            error = type(failure).__name__
        steps.append({"name": name, "error": error, **snapshot()})
    return steps
