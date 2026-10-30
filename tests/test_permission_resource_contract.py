"""The shipping privacy text and hardened runtime resource access stay paired."""

from __future__ import annotations

import plistlib
import re
import subprocess
import sys
from pathlib import Path

import pytest

ROOT = Path(__file__).resolve().parents[1]
# None means TCC requires a description but no hardened-runtime resource key.
USAGE_ENTITLEMENTS = {
    "NSAppleEventsUsageDescription": "com.apple.security.automation.apple-events",
    "NSAudioCaptureUsageDescription": "com.apple.security.device.audio-input",
    "NSBluetoothAlwaysUsageDescription": None,
    "NSCalendarsFullAccessUsageDescription": "com.apple.security.personal-information.calendars",
    "NSCameraUsageDescription": "com.apple.security.device.camera",
    "NSFocusStatusUsageDescription": None,
    "NSLocationUsageDescription": "com.apple.security.personal-information.location",
    "NSLocationWhenInUseUsageDescription": "com.apple.security.personal-information.location",
    "NSRemindersFullAccessUsageDescription": "com.apple.security.personal-information.calendars",
}


def test_usage_descriptions_and_resource_entitlements_are_complete():
    descriptions = plistlib.loads((ROOT / "packaging/privacy_usage.plist").read_bytes())
    entitlements = plistlib.loads((ROOT / "packaging/entitlements.plist").read_bytes())
    assert set(descriptions) == set(USAGE_ENTITLEMENTS)
    required = {value for value in USAGE_ENTITLEMENTS.values() if value is not None}
    assert set(entitlements) == required
    for key, entitlement in USAGE_ENTITLEMENTS.items():
        assert descriptions[key].strip()
        if entitlement:
            assert entitlements[entitlement] is True


@pytest.mark.parametrize("builder", ["app/scripts/build-app.sh", "packaging/build_macos_pkg.sh"])
def test_both_builders_preserve_the_source_privacy_strings(tmp_path, builder):
    source = (ROOT / builder).read_text()
    assert "write_privacy_usage.py" in source
    assert not re.search(r"NS\w+UsageDescription", source), "keep every usage string in privacy_usage.plist"
    assert not re.search(r'PlistBuddy.*NS\w+UsageDescription', source)
    target = tmp_path / "Info.plist"
    target.write_bytes(plistlib.dumps({"CFBundleName": "Synthetic app"}))
    command = [sys.executable, str(ROOT / "packaging/write_privacy_usage.py"), str(target)]
    subprocess.run(command, check=True, timeout=15)
    subprocess.run(command, check=True, timeout=15)
    built = plistlib.loads(target.read_bytes())
    descriptions = plistlib.loads((ROOT / "packaging/privacy_usage.plist").read_bytes())
    assert {key: built[key] for key in descriptions} == descriptions
    assert built["CFBundleName"] == "Synthetic app"
    assert "app's" in built["NSAudioCaptureUsageDescription"]
    assert "notch's" in built["NSAudioCaptureUsageDescription"]
    assert "JR-Bar's" in built["NSLocationUsageDescription"]
    assert '"AirPods connected"' in built["NSBluetoothAlwaysUsageDescription"]
    # The exact words are pinned above against privacy_usage.plist; here the
    # sentence must name every app JR-Bar automates.
    automation = built["NSAppleEventsUsageDescription"]
    for target in ("Terminal", "iTerm2", "Mail", "Music", "Calendar"):
        assert target in automation, target


def test_helper_receives_only_its_automation_description(tmp_path):
    target = tmp_path / "Info.plist"
    target.write_bytes(plistlib.dumps({}))
    subprocess.run(
        [sys.executable, str(ROOT / "packaging/write_privacy_usage.py"), str(target),
         "--key", "NSAppleEventsUsageDescription"], check=True, timeout=15,
    )
    assert set(plistlib.loads(target.read_bytes())) == {"NSAppleEventsUsageDescription"}


def test_standalone_permission_requests_stay_in_the_shared_adapters():
    owners = {
        "AVCaptureDevice.requestAccess": "Setup/SetupModel.swift",
        "INFocusStatusCenter.default.requestAuthorization": "Setup/SetupModel.swift",
        "store.requestFullAccessToEvents": "ShelfEventStore.swift",
        "store.requestFullAccessToReminders": "ShelfEventStore.swift",
        "manager.requestWhenInUseAuthorization": "Setup/NativePermissionRequests.swift",
        "CBCentralManager(delegate:": "Setup/NativePermissionRequests.swift",
    }
    sources = ROOT / "app/Sources/JRBarApp"
    for native_call, owner in owners.items():
        callers = [str(path.relative_to(sources)) for path in sources.rglob("*.swift")
                   if native_call in path.read_text()]
        assert callers == [owner], f"route {native_call} through the shared permission helper"
