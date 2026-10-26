"""The real CLI and firmware path must not import GUI framework wrappers."""
import os
import subprocess
import sys
from pathlib import Path


def test_cli_controller_and_firmware_work_without_python_framework_bridges(tmp_path):
    env = os.environ.copy()
    env.update(HOME=str(tmp_path), XDG_CONFIG_HOME=str(tmp_path / "config"), XDG_STATE_HOME=str(tmp_path / "state"), JRBAR_TESTING="1")
    env["PYTHONPATH"] = str(Path(__file__).resolve().parents[1] / "src")
    env.pop("PYTEST_CURRENT_TEST", None)
    script = '''
import sys
forbidden = {"AppKit", "Foundation", "WebKit", "Quartz", "objc", "JavaScriptCore", "EventKit"}
attempts = []
class Guard:
    def find_spec(self, fullname, path=None, target=None):
        if fullname.split(".")[0] in forbidden:
            attempts.append(fullname)
            raise ImportError("GUI bridge forbidden")
sys.meta_path.insert(0, Guard())
from jrbar.cli_entry import jrbar_main
from jrbar.application_composition import compose_status_bar_application
from jrbar.core_runtime import build_headless_controller_class
compose_status_bar_application()
controller = build_headless_controller_class()
instance = controller.alloc()
instance._accessibility_display_preferences = None
preferences = []
instance._apply_accessibility_display_preferences = preferences.append
controller._install_accessibility_display_observer(instance)
assert preferences[0].reduce_motion, "unavailable native readings fail conservatively"
from jrbar.led_wasm import RawSdLedWasmController
engine = RawSdLedWasmController()
assert engine.parse("#112233", 0).ok
assert engine.step(0) == [(17,34,51)] * 8
from jrbar.native_process_info import ProcessInfo
assert ProcessInfo.processInfo().thermalState() in range(4)
assert type(ProcessInfo.processInfo().isLowPowerModeEnabled()) is bool
from jrbar.native_eventkit import Date
assert Date.dateWithTimeIntervalSince1970_(1234.5).timeIntervalSince1970() == 1234.5
assert not attempts, attempts
assert not (set(sys.modules) & forbidden)
print("native imports verified")
'''
    result = subprocess.run([sys.executable, "-c", script], env=env, capture_output=True, text=True, timeout=60, check=False)
    assert result.returncode == 0, result.stderr
    assert "native imports verified" in result.stdout
