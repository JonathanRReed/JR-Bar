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
    value = {"schema": 2, "frozen": True, "socket_ready": True, "doctor_appkit_loaded": False,
            "images": ["/usr/lib/libobjc.A.dylib", "/System/Library/Frameworks/JavaScriptCore.framework/JavaScriptCore"],
            "modules": ["jrbar.core_runtime", "hid", *["jrbar." + name for name in verifier.NATIVE_STEPS if name != "hid"]],
            "samples": [{"rss_bytes": 50000000, "elapsed_seconds": 6 + index, "fallback_active": True} for index in range(4)]}
    value["native_steps"] = [{"name": name, "error": None, "images": list(value["images"]),
                              "modules": list(value["modules"])} for name in verifier.NATIVE_STEPS]
    return value


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
                                    {"samples": []}, {"samples": [{"rss_bytes": 1}]}, {"doctor_appkit_loaded": None},
                                    {"doctor_appkit_loaded": True}])
def test_headless_runtime_rejects_missing_work(change):
    value = receipt() | deepcopy(change)
    assert verifier.check_receipt(value)


@pytest.mark.parametrize("change", [None, [], [{"name": "hid", "error": None}]])
def test_headless_runtime_requires_every_native_step(change):
    assert "native entry point coverage is missing" in verifier.check_receipt(receipt() | {"native_steps": change})


def test_late_hid_load_is_rejected_even_if_final_inventory_is_clean():
    value = receipt()
    value["native_steps"][-1]["images"].append("/System/Library/Frameworks/AppKit.framework/AppKit")
    assert "native probe loaded GUI code: hid" in verifier.check_receipt(value)


def test_native_failure_cannot_skip_coverage():
    value = receipt()
    value["native_steps"][0]["error"] = "OSError"
    assert "native probe failed: native_process_info" in verifier.check_receipt(value)


def test_native_step_requires_the_actual_import():
    value = receipt()
    value["native_steps"][-1]["modules"].remove("hid")
    assert "native probe did not import: hid" in verifier.check_receipt(value)


def test_malformed_extra_step_is_rejected():
    value = receipt()
    value["native_steps"].append(None)
    assert "native entry point coverage is missing" in verifier.check_receipt(value)


def test_native_manifest_covers_every_native_module():
    modules = {path.stem for path in (Path(__file__).resolve().parents[1] / "src/jrbar").glob("native_*.py")}
    assert modules <= set(verifier.NATIVE_STEPS)


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
    assert value["forbidden_modules"] == []
    assert value["doctor_appkit_loaded"] is any("/AppKit.framework/" in name for name in value["images"])
    assert [step["name"] for step in value["native_steps"]] == list(verifier.NATIVE_STEPS)
    assert not [(step["name"], step["error"]) for step in value["native_steps"] if step["error"] is not None]
    # A developer environment can still have the upstream AppKit-linked HID
    # wheel. Only the release build replaces it with our headless wheel.
    assert all(step["forbidden_images"] == [] for step in value["native_steps"][:-1])
