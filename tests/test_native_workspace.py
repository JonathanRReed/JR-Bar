"""Native fallback observations run without Python GUI framework wrappers."""
import os
import subprocess
import sys


def test_native_readings_repeated_wake_delivery_and_observer_teardown(tmp_path):
    script = '''
import ctypes as c
from types import SimpleNamespace
from jrbar.native_workspace import NativeWorkspace
from jrbar.native_apple_http import _call, _string
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
    drain()
    assert all(type(value) is bool for value in (getattr(received[0], key) for key in received[0].__dataclass_fields__))
    center = owner.tokens[0][0]
    sleep_name = _string("NSWorkspaceWillSleepNotification")
    name = _string("NSWorkspaceDidWakeNotification")
    for _ in range(2):
        led.last_attempt_monotonic = 42.0
        _call(center.pointer, "postNotificationName:object:", None,
              (c.c_void_p, c.c_void_p), (sleep_name.pointer, None))
        drain()
        assert led.last_attempt_monotonic == 42.0
        _call(center.pointer, "postNotificationName:object:", None,
              (c.c_void_p, c.c_void_p), (name.pointer, None))
        drain()
        assert led.last_attempt_monotonic == 0.0
    assert received[1:] == ["handle_sleep", "handle_wake", "refresh"] * 2
    owner.close()
    _call(center.pointer, "postNotificationName:object:", None,
          (c.c_void_p, c.c_void_p), (name.pointer, None))
    drain()
    assert len(received) == 7
    assert not {"AppKit", "Foundation", "objc"} & set(sys.modules)
finally:
    owner.close()
'''
    result = subprocess.run([sys.executable, "-c", "import sys\n" + script],
                            env=os.environ.copy(), capture_output=True, text=True, timeout=30)
    assert result.returncode == 0, result.stderr
