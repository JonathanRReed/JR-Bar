"""Packaged runtime acceptance needs actual images, imports and fallback work."""
import json
import subprocess
import sys
import tempfile
from copy import deepcopy
from importlib.util import module_from_spec, spec_from_file_location
from pathlib import Path

import pytest

spec = spec_from_file_location("daemon_verifier", Path(__file__).resolve().parents[1] / "packaging/verify_daemon_runtime.py")
verifier = module_from_spec(spec)
spec.loader.exec_module(verifier)


def receipt():
    return {"schema": 1, "frozen": True, "socket_ready": True,
            "images": ["/usr/lib/libobjc.A.dylib", "/System/Library/Frameworks/JavaScriptCore.framework/JavaScriptCore"],
            "modules": ["jrbar.core_runtime", "jrbar.native_workspace"],
            "samples": [{"rss_bytes": 50000000, "elapsed_seconds": 6 + index, "fallback_active": True} for index in range(4)]}


def test_headless_runtime_accepts_system_objc_and_javascript_c_api():
    assert verifier.check_receipt(receipt()) == []


@pytest.mark.parametrize("image", ["/System/Library/Frameworks/AppKit.framework/Versions/C/AppKit",
                                   "/System/Library/Frameworks/WebKit.framework/WebKit",
                                   "/System/Library/Frameworks/WebKitLegacy.framework/WebKitLegacy",
                                   "/bundle/objc/_objc.cpython-312-darwin.so"])
def test_headless_runtime_rejects_gui_images(image):
    value = receipt()
    value["images"].append(image)
    assert any("forbidden images" in error for error in verifier.check_receipt(value))


@pytest.mark.parametrize("module", ["objc", "objc._objc", "AppKit", "WebKit", "Quartz", "Foundation"])
def test_headless_runtime_rejects_python_bridges(module):
    value = receipt()
    value["modules"].append(module)
    assert "daemon imported GUI Python bridges" in verifier.check_receipt(value)


@pytest.mark.parametrize("change", [{"frozen": False}, {"socket_ready": False}, {"images": []}, {"modules": []},
                                    {"samples": []}, {"samples": [{"rss_bytes": 1}]}])
def test_headless_runtime_rejects_missing_work(change):
    value = receipt() | deepcopy(change)
    assert verifier.check_receipt(value)


def test_probe_runs_core_and_refuses_external_side_effects(tmp_path, request):
    sandbox = tempfile.TemporaryDirectory(prefix="jrb-probe-test-", dir="/tmp")
    request.addfinalizer(sandbox.cleanup)
    root = Path(sandbox.name)
    env = {"HOME": str(root), "PATH": "/usr/bin:/bin", "JRBAR_TESTING": "1",
           "PYTHONPATH": str(Path(__file__).resolve().parents[1] / "src")}
    for variable, leaf in (("XDG_CONFIG_HOME", "config"), ("XDG_STATE_HOME", "state"), ("XDG_CACHE_HOME", "cache")):
        (root / leaf).mkdir()
        env[variable] = str(root / leaf)
    script = '''
import os, socket, subprocess, sys
from pathlib import Path
from jrbar._packaging_probe import run
assert run(Path.home()) == 0
for operation in (
    lambda: os.open(sys.argv[1], os.O_CREAT | os.O_WRONLY, 0o600),
    lambda: socket.socket(socket.AF_INET).connect(("127.0.0.1", 1)),
    lambda: socket.socket(socket.AF_UNIX).connect(sys.argv[1]),
    lambda: subprocess.Popen(["/usr/bin/true"]),
):
    try:
        operation()
    except OSError:
        pass
    else:
        raise AssertionError("probe allowed an external side effect")
'''
    outside = tmp_path / "probe-must-not-create"
    result = subprocess.run([sys.executable, "-c", script, str(outside)], env=env,
                            capture_output=True, text=True, timeout=40)
    assert result.returncode == 0, result.stderr
    assert not outside.exists()
    value = json.loads((root / "runtime.json").read_text())
    assert value["socket_ready"]
    assert all(sample["fallback_active"] for sample in value["samples"])
    assert value["forbidden_images"] == value["forbidden_modules"] == []
