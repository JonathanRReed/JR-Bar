"""Native fallback observations must keep GUI images out of the daemon."""
import os
import subprocess
import sys
from types import SimpleNamespace

import pytest

from jrbar.native_workspace import CAN_SLEEP, HAS_POWERED_ON, WILL_SLEEP, NativeWorkspace


def test_native_readings_repeated_wake_delivery_and_observer_teardown(tmp_path):
    script = '''
import ctypes as c
import sys
from types import SimpleNamespace
from jrbar.native_workspace import NativeWorkspace, WILL_SLEEP, HAS_POWERED_ON
from jrbar.daemon_loop import application
from jrbar.daemon_controller import StatusBarController
received = []
led = SimpleNamespace(last_attempt_monotonic=42.0)
controller = SimpleNamespace(
    agent_led_controllers_by_device={"synthetic": led},
    _refresh_dnd_environment=received.append,
    refresh_=lambda _: received.append("refresh"),
    _apply_accessibility_display_preferences=received.append,
)
def invoke(selector, payload, wait):
    getattr(StatusBarController, selector.replace(":", "_"))(controller, payload)
controller.performSelectorOnMainThread_withObject_waitUntilDone_ = invoke
owner = NativeWorkspace(controller)
loop = application()
def drain():
    while loop.queue:
        loop.queue.popleft()()
try:
    owner.poll()
    assert all(type(getattr(received[0], key)) is bool for key in received[0].__dataclass_fields__)
    drain()
    received.clear()
    native_power = owner.power
    acks = []
    # Exercise the real C callback, but never acknowledge a synthetic ID to powerd.
    owner.power = SimpleNamespace(IOAllowPowerChange=lambda *args: acks.append(args))
    for _ in range(2):
        led.last_attempt_monotonic = 42.0
        owner.power_callback(None, 0, WILL_SLEEP, 123)
        drain()
        assert led.last_attempt_monotonic == 42.0
        owner.power_callback(None, 0, HAS_POWERED_ON, None)
        drain()
        assert led.last_attempt_monotonic == 0.0
    assert received == ["handle_sleep", "handle_wake", "refresh"] * 2
    assert len(acks) == 2
    owner.power = native_power
    owner.close()
    owner.deliver("wake")
    drain()
    assert len(received) == 6
    lib = c.CDLL("/usr/lib/libSystem.B.dylib")
    lib._dyld_image_count.restype = c.c_uint32
    lib._dyld_get_image_name.argtypes = [c.c_uint32]
    lib._dyld_get_image_name.restype = c.c_char_p
    images = [lib._dyld_get_image_name(index).decode() for index in range(lib._dyld_image_count())]
    assert not [name for name in images if any(part in name for part in ("/AppKit.framework/", "/WebKit.framework/", "/objc/_"))]
    assert not {"AppKit", "Foundation", "objc"} & set(sys.modules)
finally:
    owner.close()
'''
    result = subprocess.run([sys.executable, "-c", script],
                            env=os.environ.copy(), capture_output=True, text=True, timeout=30)
    assert result.returncode == 0, result.stderr


@pytest.mark.parametrize("message,edge,ack", [(CAN_SLEEP, None, True), (WILL_SLEEP, "sleep", True),
                                            (HAS_POWERED_ON, "wake", False), (0, None, False)])
def test_power_callback_acknowledges_only_sleep_requests(message, edge, ack):
    events, acknowledgements = [], []
    owner = NativeWorkspace.__new__(NativeWorkspace)
    owner.connection = 12
    owner.power = SimpleNamespace(IOAllowPowerChange=lambda *args: acknowledgements.append(args))
    owner.deliver = events.append
    owner._power_changed(None, 0, message, 345)
    assert events == ([] if edge is None else [edge])
    assert acknowledgements == ([(12, 345)] if ack else [])


def test_sleep_acknowledgement_survives_delivery_failure():
    acks = []
    owner = NativeWorkspace.__new__(NativeWorkspace)
    owner.connection = 12
    owner.power = SimpleNamespace(IOAllowPowerChange=lambda *args: acks.append(args))
    def failed(_):
        raise RuntimeError("queue unavailable")
    owner.deliver = failed
    with pytest.raises(RuntimeError, match="queue unavailable"):
        owner._power_changed(None, 0, WILL_SLEEP, 345)
    assert acks == [(12, 345)]


def test_missing_accessibility_values_keep_last_good_or_conservative_flags(monkeypatch):
    from jrbar.accessibility_display import AccessibilityDisplayPreferences

    owner = NativeWorkspace.__new__(NativeWorkspace)
    owner.last_preferences = None
    owner.cf = SimpleNamespace(CFPreferencesCopyAppValue=lambda *_: None)
    assert owner.preferences() == AccessibilityDisplayPreferences(True, True, True, True)
    owner.last_preferences = AccessibilityDisplayPreferences(False, True, False, True)
    assert owner.preferences() == owner.last_preferences


def test_available_accessibility_values_replace_previous_flags(monkeypatch):
    from jrbar import native_workspace
    from jrbar.accessibility_display import AccessibilityDisplayPreferences

    monkeypatch.setattr(native_workspace, "_string", lambda key: SimpleNamespace(pointer=key))
    values = iter((1, 2, 3, 4))
    released = []
    owner = NativeWorkspace.__new__(NativeWorkspace)
    owner.last_preferences = AccessibilityDisplayPreferences(True, True, True, True)
    owner.cf = SimpleNamespace(CFPreferencesCopyAppValue=lambda *_: next(values), CFRelease=released.append)
    owner._boolean = lambda pointer: pointer % 2 == 0
    assert owner.preferences() == AccessibilityDisplayPreferences(False, True, False, True)
    assert released == [1, 2, 3, 4]
