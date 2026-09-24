"""Every hardware option on the Devices page does something, or says why not.

"Make sure all of our hardware options are working" needs a test, not a
review. This drives the headless daemon with a scratch SidePulse Pro and a
scratch Dot (real controllers, real write boundary, scratch volumes, no
device I/O) and, for every setting the Devices page writes -- enumerated
from the Swift sources, so a new control cannot skip the matrix -- asserts
that changing it changes what the devices are written or what the Screen
Bar is sent, or that the page disables it with a stated reason.

It also carries the page's other hardware receipts: the eject guard's real
state, the foreign-write watch, and the Creator Micro 2 and Stream Deck
receipts that nobody can check live without Jonathan at the desk.
"""

from __future__ import annotations

import re
import time
from dataclasses import dataclass
from datetime import datetime, timezone
from pathlib import Path
from types import SimpleNamespace
from typing import Any

import pytest

# The headless daemon fixture, shared with test_core_runtime; pytest
# injects it by this name, which ruff reads as a redefinition (F811).
from test_core_runtime import headless as headless_daemon  # noqa: F401

from jrbar import status_bar
from jrbar.core_runtime import get_path, set_path, settings_from_document

APP = Path(__file__).resolve().parents[1] / "app" / "Sources" / "JRBarApp"

def _comet() -> str:
    """The Comet effect as the strip plays it: one head travelling the
    eight LEDs, so the Dot's two looks, and the two sides of Continue,
    differ."""
    import sys

    scripts = str(Path(__file__).resolve().parents[1] / "scripts")
    if scripts not in sys.path:
        sys.path.insert(0, scripts)
    from review_effects import effect_programs

    return next(program for name, program, leds in effect_programs() if name == "effect_comet_8led")


# --- which settings the Devices page writes --------------------------------------

_PATH = re.compile(
    r'(?:path: |Provided\(store, |store\.(?:string|bool|double|optionalString|set)\()"([^"]+)"'
)


def devices_page_paths() -> set[str]:
    """Every settings path the Devices page can write, from the Swift source:
    the page's region of ``SettingsPagesA.swift`` (from its MARK to the end
    of the file) and the Pro & Dot controls it mounts."""
    pages_a = (APP / "SettingsPagesA.swift").read_text(encoding="utf-8")
    region = pages_a[pages_a.index("// MARK: - Devices & Screen Bar") :]
    sources = [region]
    for name in ("DotRoleControls.swift", "LinkedSyncControls.swift"):
        path = APP / name
        if path.exists():
            sources.append(path.read_text(encoding="utf-8"))
    paths = set()
    for source in sources:
        for match in _PATH.finditer(source):
            paths.add(match.group(1).replace("\\(device.prefix)", "devices.N"))
    return paths


# --- the rig -------------------------------------------------------------------


@dataclass
class Rig:
    controller: Any
    tmp: Path
    pro: Any
    dot: Any
    statuses: tuple
    battery: Any

    @property
    def pro_controller(self):
        return self.controller.agent_led_controllers_by_device[self.pro.device_id]

    @property
    def dot_controller(self):
        return self.controller.agent_led_controllers_by_device[self.dot.device_id]

    def set(self, path: str, value: object) -> None:
        """Write a setting the way ``set_setting`` does: through the real
        loader (tolerant decode, clamps), ``devices.N`` resolved to the
        Pro (0) or the Dot (1)."""
        document = self.controller.settings.to_dict()
        assert set_path(document, path, value), path
        self.controller.settings = settings_from_document(document, scratch_dir=self.tmp)
        assert get_path(self.controller.settings.to_dict(), path)[1], path

    def plan(self) -> dict[str, Any]:
        """One refresh's hardware writes, run to completion, plus the lights
        frame: what each device now holds and what the Screen Bar is sent."""
        from jrbar.models import AgentMode
        from jrbar.status_bar_legacy import HardwareWriteRequest

        controller = self.controller
        devices = [
            device
            for device in controller.status_bar_devices(remember=False)
            if device.connected and device.device_id != status_bar.VIRTUAL_DEVICE_ID
        ]
        requests = [
            HardwareWriteRequest(
                device=device,
                mode=AgentMode.WORKING,
                battery_snapshot=self.battery,
                statuses=self.statuses,
                projection=None,
                relay_elapsed_seconds=0.5,
                display_kind=controller.active_led_display_kind_for_device(device, self.battery),
            )
            for device in sorted(devices, key=lambda device: device.device_id)
        ]
        controller._submit_hardware_write_requests(requests, time.monotonic())
        lights = controller._core_build_lights()
        bar = lights.get("surfaces", {}).get("screen_bar") or {}
        return {
            "pro": self.pro_controller.last_nominal_program,
            "pro_bytes": self.pro_controller.last_device_bytes,
            "dot": self.dot_controller.last_nominal_program,
            "dot_bytes": self.dot_controller.last_device_bytes,
            "bar": (bar.get("program"), bar.get("anchor"), bar.get("brightness")),
        }


def _status(provider: str, mode, index: int):
    from jrbar.models import AgentStatus

    return AgentStatus(
        provider=provider,
        agent_id=f"{provider}:session:{index}",
        display_name=f"{provider} {index}",
        mode=mode,
        updated_at=datetime.now(timezone.utc),
        event_name="PreToolUse",
        session_id=f"s{index}",
    )


@pytest.fixture
def rig(headless_daemon, tmp_path: Path, monkeypatch: pytest.MonkeyPatch) -> Rig:  # noqa: F811
    from jrbar import status_bar_legacy
    from jrbar._device_writer_legacy import DeviceCandidate
    from jrbar.battery import BatterySnapshot
    from jrbar.models import AgentMode

    controller = headless_daemon
    candidates = []
    for volume in ("SidePulsePro", "PulseDot"):
        root = tmp_path / volume
        root.mkdir()
        (root / "LEDS.LED").write_text("off\n", encoding="utf-8")
        candidates.append(DeviceCandidate(root=root, target=root / "LEDS.LED", reason="scratch"))
    controller.discover_device_candidates = lambda: list(candidates)
    devices = {
        device.root.name: device
        for device in controller.status_bar_devices(remember=False)
        if device.connected
    }
    pro, dot = devices["SidePulsePro"], devices["PulseDot"]
    settings = controller.settings
    for device in (pro, dot):
        settings = settings.with_device_display(device.device_id, "agent", name=device.name, path=str(device.root))
    controller.settings = settings.with_devices_linked(True).with_dot_role("extend")
    controller._hardware_write_generation = 1
    controller._hardware_write_active = True

    def run_now(command):
        result = controller._execute_hardware_write_command(command)
        controller._apply_hardware_write_result(command, result)

    controller._hardware_write_worker = SimpleNamespace(submit=run_now, discard_pending_prefix=lambda prefix: None)
    # The display backlight, for auto-brightness: a dim room.
    monkeypatch.setattr(status_bar_legacy.display_brightness, "auto_led_brightness", lambda: 40)
    statuses = (_status("claude", AgentMode.WORKING, 1), _status("codex", AgentMode.WAITING_FOR_INPUT, 2))
    battery = BatterySnapshot(percent=64)
    return Rig(controller, tmp_path, pro, dot, statuses, battery)


# --- the matrix ------------------------------------------------------------------

PRO, DOT = "devices.0", "devices.1"
LINKED_REASON = "Linked: follows the SidePulse"


def _changes(rig: Rig, path: str, value: object, *, field: str, before: object = None) -> None:
    """``path`` set to ``value`` changes ``field`` of the next plan."""
    if before is not None:
        rig.set(path, before)
    rig.plan()
    baseline = rig.plan()[field]
    rig.set(path, value)
    after = rig.plan()[field]
    assert after != baseline, f"{path}={value!r} left {field} unchanged: {baseline!r}"


def _inert_on_a_linked_dot(rig: Rig, leaf: str, value: object) -> None:
    """The Dot's own display control does nothing while its role drives it
    -- which is why the card switches it off and says so -- and does work
    once the Dot is on its own."""
    rig.plan()
    baseline = rig.plan()["dot"]
    rig.set(f"{DOT}.{leaf}", value)
    assert rig.plan()["dot"] == baseline, f"{leaf} reached a role-driven Dot"
    swift = (APP / "SettingsPagesA.swift").read_text(encoding="utf-8") + (
        APP / "LinkedSyncControls.swift"
    ).read_text(encoding="utf-8")
    assert LINKED_REASON in swift
    assert ".disabled(linkedDot" in swift


def check_led_display(rig: Rig) -> None:
    rig.controller.quota_runway_state = lambda: (0.35, "#FFB000")
    for display in ("battery", "studio", "quota_runway"):
        rig.set("studio_program", _comet())
        _changes(rig, f"{PRO}.led_display", display, field="pro", before="agent")
    rig.set(f"{PRO}.led_display", "agent")
    _inert_on_a_linked_dot(rig, "led_display", "studio")
    rig.set("dot_role", "status")
    _changes(rig, f"{DOT}.led_display", "battery", field="dot", before="agent")


def check_brightness(rig: Rig) -> None:
    _changes(rig, f"{PRO}.brightness", 90, field="pro")
    # The Dot's own brightness caps it even while it follows the strip.
    _changes(rig, f"{DOT}.brightness", 90, field="dot")


def check_auto_brightness(rig: Rig) -> None:
    _changes(rig, f"{PRO}.auto_brightness_enabled", True, field="pro")
    # Following the strip, the Dot ignores its own auto-brightness (the
    # card switches it off); not following, it is the Dot's cap again.
    rig.plan()
    baseline = rig.plan()["dot"]
    rig.set(f"{DOT}.auto_brightness_enabled", True)
    assert rig.plan()["dot"] == baseline
    rig.set(f"{DOT}.auto_brightness_enabled", False)
    rig.set("linked_follow_brightness", False)
    _changes(rig, f"{DOT}.auto_brightness_enabled", True, field="dot")


def check_provider_pin(rig: Rig) -> None:
    _changes(rig, f"{PRO}.provider_pin", "codex", field="pro")
    rig.set(f"{PRO}.provider_pin", None)
    _inert_on_a_linked_dot(rig, "provider_pin", "codex")


def check_signal_policy(rig: Rig) -> None:
    rig.set("calendar_alerts_enabled", True)
    rig.controller.calendar_glow_until = time.monotonic() + 600
    _changes(rig, f"{PRO}.signal_policy", "asks_only", field="pro")
    rig.set(f"{PRO}.signal_policy", None)
    _inert_on_a_linked_dot(rig, "signal_policy", "asks_only")


def check_blend_mode(rig: Rig) -> None:
    from jrbar.models import AgentMode

    # Two agents at work: an open ask outranks every blend, so none of them
    # would show.
    rig.statuses = (_status("claude", AgentMode.WORKING, 1), _status("codex", AgentMode.WORKING, 2))
    _changes(rig, f"{PRO}.blend_mode", "spatial_split", field="pro")
    rig.set(f"{PRO}.blend_mode", None)
    _inert_on_a_linked_dot(rig, "blend_mode", "spatial_split")


def check_calibration(rig: Rig) -> None:
    """The calibration profile (Calibrate…, and the profiles that apply it)
    reaches each device's own bytes."""
    for device in (PRO, DOT):
        field = "pro_bytes" if device == PRO else "dot"
        if device == DOT:
            rig.plan()
            baseline = rig.dot_controller.last_program
            rig.set(f"{device}.red_gain", 0.6)
            rig.plan()
            assert rig.dot_controller.last_program != baseline
            continue
        _changes(rig, f"{device}.red_gain", 0.6, field=field)
        _changes(rig, f"{device}.blue_gain", 1.4, field=field)


def check_devices_linked(rig: Rig) -> None:
    _changes(rig, "devices_linked", False, field="dot")


def check_linked_dot_scale(rig: Rig) -> None:
    _changes(rig, "linked_dot_scale", 0.8, field="dot")


def check_dot_role(rig: Rig) -> None:
    from jrbar import core_power

    rig.controller._core_documents["state"] = {"aggregate": {"needs_you": 1, "mode": "needs_you"}}
    _changes(rig, "dot_role", "asks", field="dot", before="extend")
    original = core_power.on_call
    core_power.on_call = lambda controller: True
    try:
        _changes(rig, "dot_role", "call", field="dot")
    finally:
        core_power.on_call = original
    _changes(rig, "dot_role", "status", field="dot")


def check_include_completions(rig: Rig) -> None:
    rig.set("dot_role", "asks")
    rig.controller._core_documents["state"] = {"aggregate": {"needs_you": 0, "ready": 1, "mode": "idle"}}
    _changes(rig, "dot_role_include_completions", True, field="dot")


def check_follow_brightness(rig: Rig) -> None:
    rig.set(f"{DOT}.auto_brightness_enabled", True)
    _changes(rig, "linked_follow_brightness", False, field="dot")


def check_extend_style(rig: Rig) -> None:
    rig.set("studio_program", _comet())
    rig.set(f"{PRO}.led_display", "studio")
    _changes(rig, "dot_extend_style", "mirror", field="dot", before="continue")


def check_extend_side(rig: Rig) -> None:
    rig.set("studio_program", _comet())
    rig.set(f"{PRO}.led_display", "studio")
    rig.set("dot_extend_style", "continue")
    _changes(rig, "dot_extend_side", "before_first", field="dot")


def check_phase_trim(rig: Rig) -> None:
    """The trim moves the Dot against the strip: a rewrite, rotated by it."""
    rig.plan()
    rig.plan()
    before = rig.controller._core_linked.dot_write
    rig.set("linked_dot_phase_trim_ms", 120)
    rig.plan()
    after = rig.controller._core_linked.dot_write
    assert after is not None and after is not before
    assert rig.dot_controller.last_program_identity[1][5] == 120.0


def check_clock_correction(rig: Rig) -> None:
    rig.plan()
    rig.plan()
    assert rig.controller._core_linked.dot_write.rate != 1.0
    rig.set("linked_dot_clock_correction", False)
    rig.plan()
    assert rig.controller._core_linked.dot_write.rate == 1.0


def check_sync_tolerance(rig: Rig) -> None:
    """The tolerance is the closed loop's threshold: the same predicted
    error re-anchors the Dot at 40 ms and leaves it alone at 150."""
    link = rig.controller._core_linked
    rig.plan()
    record = link.dot_write
    assert record is not None
    link.phase_error_ms = 60.0
    link.error_at = link.now()
    link.drift_ms_per_s = 0.0
    link.last_sync_write_at = None
    link.read_failures = 0
    assert link.due(tolerance_ms=40, now=link.now(), dot_id=rig.dot.device_id) == "reanchor"
    assert link.due(tolerance_ms=150, now=link.now(), dot_id=rig.dot.device_id) is None


def check_link_screen_bar(rig: Rig) -> None:
    _changes(rig, "link_screen_bar_to_hardware", False, field="bar")


def check_screen_bar_offset(rig: Rig) -> None:
    _changes(rig, "screen_bar_phase_offset_ms", 250, field="bar")


def check_screen_bar_min_glow(rig: Rig) -> None:
    from jrbar import status_bar_legacy

    settings = rig.controller.settings.with_device_display(
        status_bar_legacy.VIRTUAL_DEVICE_ID, "agent", name="Screen Bar", path=status_bar_legacy.VIRTUAL_DEVICE_ID
    ).with_device_brightness(status_bar_legacy.VIRTUAL_DEVICE_ID, 10)
    rig.controller.settings = settings
    rig.set("virtual_status_device_enabled", True)
    _changes(rig, "screen_bar_min_glow", 0.8, field="bar", before=0.25)


#: Screen Bar geometry the app draws itself (``ScreenBarController``): none
#: of it is a device write or part of the lights frame, so the matrix names
#: where each one lives instead of pretending to measure it here.
APP_DRAWN = {
    "virtual_status_device_enabled": "the app shows or hides its Screen Bar window",
    "screen_bar_follow_alcove": "the app sizes the band to Alcove's capsule",
    "screen_bar_show_in_full_screen": "the app's window level over full-screen spaces",
    "screen_bar_gap_width": "the app's notch geometry",
    "screen_bar_wing_length": "the app's notch geometry",
    "screen_bar_notch_wings": "the app's wing slots beside the notch",
    "screen_bar_notch_profile": "the app's notch outline",
    "screen_bar_notch_corner": "the app's notch corner radius",
}

MATRIX = {
    "devices.N.led_display": check_led_display,
    "devices.N.brightness": check_brightness,
    "devices.N.auto_brightness_enabled": check_auto_brightness,
    "devices.N.provider_pin": check_provider_pin,
    "devices.N.signal_policy": check_signal_policy,
    "devices.N.blend_mode": check_blend_mode,
    "devices_linked": check_devices_linked,
    "linked_dot_scale": check_linked_dot_scale,
    "dot_role": check_dot_role,
    "dot_role_include_completions": check_include_completions,
    "linked_follow_brightness": check_follow_brightness,
    "dot_extend_style": check_extend_style,
    "dot_extend_side": check_extend_side,
    "linked_dot_phase_trim_ms": check_phase_trim,
    "linked_dot_clock_correction": check_clock_correction,
    "linked_sync_tolerance_ms": check_sync_tolerance,
    "link_screen_bar_to_hardware": check_link_screen_bar,
    "screen_bar_phase_offset_ms": check_screen_bar_offset,
    "screen_bar_min_glow": check_screen_bar_min_glow,
    # Not a path on the page (the Calibrate… sheet writes it), but an option
    # the page offers all the same.
    "calibration": check_calibration,
}


def test_every_devices_page_setting_is_in_the_matrix() -> None:
    """A control added to the Devices page without a row here fails: either
    it changes what a device is written, or it says why not."""
    paths = devices_page_paths()
    assert {"devices.N.led_display", "dot_role", "linked_dot_phase_trim_ms"} <= paths
    missing = sorted(paths - set(MATRIX) - set(APP_DRAWN))
    assert missing == []


@pytest.mark.parametrize("path", sorted(MATRIX))
def test_the_option_does_something(rig: Rig, path: str) -> None:
    MATRIX[path](rig)


# --- the linked settings ---------------------------------------------------------


def test_the_linked_settings_decode_tolerantly_and_round_trip__and_1_more(tmp_path: Path) -> None:
    # --- scenario: missing_keys_take_the_defaults_continue_first
    """A file from before these keys existed gets the defaults: the Dot
    continues the strip (Jonathan's answer, "light flows Pro -> Dot"),
    past LED 7, clock-corrected, 40 ms, no trim, following the strip's
    brightness."""
    settings = settings_from_document({}, scratch_dir=tmp_path)
    assert settings.dot_extend_style == "continue"
    assert settings.dot_extend_side == "after_last"
    assert settings.linked_dot_clock_correction is True
    assert settings.linked_sync_tolerance_ms == 40.0
    assert settings.linked_dot_phase_trim_ms == 0.0
    assert settings.linked_follow_brightness is True

    # --- scenario: nonsense_decodes_to_defaults_and_numbers_clamp
    wrong = {
        "dot_extend_style": "sideways",
        "dot_extend_side": 7,
        "linked_dot_clock_correction": "maybe",
        "linked_sync_tolerance_ms": 5000,
        "linked_dot_phase_trim_ms": -900,
        "linked_follow_brightness": None,
    }
    settings = settings_from_document(wrong, scratch_dir=tmp_path)
    assert settings.dot_extend_style == "continue" and settings.dot_extend_side == "after_last"
    assert settings.linked_dot_clock_correction is True and settings.linked_follow_brightness is True
    assert settings.linked_sync_tolerance_ms == 200.0 and settings.linked_dot_phase_trim_ms == -250.0
    chosen = {
        "dot_extend_style": "mirror",
        "dot_extend_side": "before_first",
        "linked_dot_clock_correction": False,
        "linked_sync_tolerance_ms": 65,
        "linked_dot_phase_trim_ms": 35,
        "linked_follow_brightness": False,
    }
    written = settings_from_document(chosen, scratch_dir=tmp_path).to_dict()
    assert {key: written[key] for key in chosen} == {**chosen, "linked_sync_tolerance_ms": 65.0, "linked_dot_phase_trim_ms": 35.0}
    again = settings_from_document(written, scratch_dir=tmp_path).to_dict()
    assert {key: again[key] for key in chosen} == {key: written[key] for key in chosen}


# --- the eject guard ----------------------------------------------------------


def test_the_eject_guard_reports_what_launchd_really_has__and_2_more(tmp_path: Path) -> None:
    # --- scenario: installed_without_a_volume_protects_nothing
    """The shipped install: a plist with no volume UUID, RunAtLoad and
    KeepAlive false, launchd has never run it. Installed, protecting
    nothing -- and the reading says exactly that."""
    import plistlib

    from jrbar import sd_eject_guard_launch as guard

    paths = guard.SdEjectGuardPaths(
        scope="user",
        plist_path=tmp_path / "guard.plist",
        binary_path=tmp_path / "bin" / "guard",
        stdout_path=tmp_path / "out.log",
        stderr_path=tmp_path / "err.log",
    )
    paths.plist_path.write_bytes(plistlib.dumps(guard.build_sd_eject_guard_plist(paths)))
    printed = "state = not running\nruns = 0\nlast exit code = (never exited)\n"
    status = guard.sd_eject_guard_status(
        user_paths=paths, system_paths=paths, launchctl_print=lambda domain: (0, printed)
    )
    assert status.installed and status.loaded and not status.running
    assert status.runs == 0 and status.volume_uuid is None
    assert not status.run_at_load and not status.keep_alive
    assert status.protects is False
    assert status.to_dict()["protects"] is False

    # --- scenario: protect_installs_for_the_mounted_volume_only_on_request
    calls: list[dict] = []

    def installer(**kwargs):
        calls.append(kwargs)
        return SimpleNamespace(started=True)

    guard.protect_mounted_sidepulse(
        tmp_path / "SidePulse", installer=installer, uuid_reader=lambda volume: "B293BB91-193C-3A17-88DC-35CD9BA19B2F"
    )
    assert calls == [{"scope": "user", "volume_uuid": "B293BB91-193C-3A17-88DC-35CD9BA19B2F", "start": True}]
    with pytest.raises(guard.SdEjectGuardInstallError):
        guard.protect_mounted_sidepulse(tmp_path, installer=installer, uuid_reader=lambda volume: None)

    # --- scenario: a_plist_with_the_uuid_protects
    paths.plist_path.write_bytes(
        plistlib.dumps(guard.build_sd_eject_guard_plist(paths, volume_uuid="b293bb91-193c-3a17-88dc-35cd9ba19b2f"))
    )
    status = guard.sd_eject_guard_status(
        user_paths=paths, system_paths=paths, launchctl_print=lambda domain: (0, "state = running\nruns = 3\npid = 4242\n")
    )
    assert status.protects and status.running and status.runs == 3 and status.pid == 4242
    assert status.volume_uuid == "B293BB91-193C-3A17-88DC-35CD9BA19B2F"


# --- the Devices page's commands ---------------------------------------------------


def test_check_sync_holds_both_devices_before_it_writes__and_3_more(rig: Rig) -> None:
    # --- scenario: refused_when_the_pair_is_not_ready
    """Check sync needs a linked Pro and Dot with the Dot extending the
    strip; anything else is refused with the reason, and nothing is held."""
    from jrbar.core_server import CommandError
    from jrbar.linked_check import start_check

    controller = rig.controller
    rig.plan()
    for path, value in (("devices_linked", False), ("dot_role", "asks")):
        before = controller.settings
        rig.set(path, value)
        with pytest.raises(CommandError) as refused:
            start_check(controller, {})
        assert refused.value.code == "not_ready"
        assert controller._core_held_preview_devices() == frozenset()
        controller.settings = before

    # --- scenario: both_holds_exist_before_either_device_is_written
    """A live command queued on the write worker used to land between the
    writes and the holds, paint over the flash and move the strip's
    recorded start. The holds come first now."""
    held_at_write: list[frozenset] = []
    for device_controller in (rig.pro_controller, rig.dot_controller):
        original = device_controller.sync_program

        def watching(program, state, *, _original=original, **kwargs):
            held_at_write.append(controller._core_held_preview_devices())
            return _original(program, state, **kwargs)

        device_controller.sync_program = watching
    reply = start_check(controller, {"seconds": 30})
    both = frozenset({rig.pro.device_id, rig.dot.device_id})
    assert held_at_write and all(held == both for held in held_at_write)
    assert controller._core_held_preview_devices() == both
    assert set(reply["devices"]) == set(both)
    assert controller._core_linked.check_until is not None
    assert controller._core_linked.dot_write.reason == "check"
    assert "FFFFFF" in rig.pro_controller.last_program.upper()

    # --- scenario: a_second_press_says_a_check_is_running
    with pytest.raises(CommandError) as busy:
        start_check(controller, {})
    assert busy.value.code == "busy" and "already running" in busy.value.message

    # --- scenario: a_reanchor_during_the_check_writes_the_held_dot
    """The Dot is held by the check, so the ordinary write path would
    refuse the closed loop's re-anchor; the check writes it itself."""
    from jrbar.linked_check import reanchor_check

    before = controller._core_linked.dot_write
    reanchor_check(controller, "reanchor")
    after = controller._core_linked.dot_write
    assert after is not before and after.reason == "check"


def test_a_check_sync_the_strip_refuses_holds_nothing(rig: Rig) -> None:
    """A strip write that fails takes back both holds it registered, so the
    live program returns at the next refresh instead of in a minute."""
    from jrbar.core_server import CommandError
    from jrbar.linked_check import start_check

    controller = rig.controller
    rig.plan()

    def refuse(*_args, **_kwargs):
        raise OSError("card pulled")

    rig.pro_controller.sync_program = refuse
    with pytest.raises(CommandError) as refused:
        start_check(controller, {})
    assert refused.value.code == "refused"
    assert controller._core_held_preview_devices() == frozenset()
    assert controller._core_linked.check_until is None


def test_the_eject_guard_commands_answer_for_the_mounted_sidepulse__and_1_more(
    rig: Rig, monkeypatch: pytest.MonkeyPatch
) -> None:
    # --- scenario: status_names_the_sidepulse_plugged_in_now
    from jrbar import eject_guard_commands, sd_eject_guard_launch
    from jrbar.core_server import CommandError

    monkeypatch.setattr(
        sd_eject_guard_launch,
        "sd_eject_guard_status",
        lambda: sd_eject_guard_launch.SdEjectGuardStatus(installed=True, runs=0),
    )
    monkeypatch.setattr(sd_eject_guard_launch, "mounted_volume_uuid", lambda root: "B293BB91-193C-3A17-88DC-35CD9BA19B2F")
    document = eject_guard_commands.status(rig.controller, {})
    assert document["installed"] is True and document["protects"] is False
    assert document["mounted_volume_uuid"] == "B293BB91-193C-3A17-88DC-35CD9BA19B2F"
    assert document["mounted_name"] == rig.pro.name
    assert document["protects_mounted"] is False

    # --- scenario: protect_with_no_sidepulse_mounted_is_refused
    """Only a mounted SidePulse can be protected; with none the command
    says so and installs nothing."""
    installs: list[object] = []
    monkeypatch.setattr(sd_eject_guard_launch, "protect_mounted_sidepulse", lambda root: installs.append(root))
    rig.controller.discover_device_candidates = lambda: []
    with pytest.raises(CommandError) as missing:
        eject_guard_commands.protect(rig.controller, {})
    assert missing.value.code == "not_found"
    assert installs == []
    assert eject_guard_commands.status(rig.controller, {})["mounted_volume_uuid"] is None


# --- foreign writes ---------------------------------------------------------------


def test_a_foreign_write_is_answered_once_then_left_alone(tmp_path: Path) -> None:
    """At the reassert cadence (never faster) a fresh read compares the
    device with what JR-Bar last wrote. The first foreign write is written
    over once and noted; a second inside ten minutes stops the rewrites so
    the two apps never fight over the flash. JR-Bar's own next change still
    goes out."""
    from jrbar._led_status_legacy import AgentLedController, LedDisplayState

    volume = tmp_path / "SidePulsePro"
    volume.mkdir()
    target = volume / "LEDS.LED"
    target.write_text("off\n", encoding="utf-8")
    controller = AgentLedController(device_path=target)
    reads: list[Path] = []

    def reader(path: Path) -> str:
        reads.append(path)
        return path.read_text(encoding="utf-8")

    controller.foreign_status_reader = reader
    program = "#00E5FF 1s cosine\n#000000 1s cosine\nrepeat"
    assert controller.sync_program(program, LedDisplayState.WORKING).changed
    # Inside the reassert window nothing is read at all.
    assert not controller.sync_program(program, LedDisplayState.WORKING).changed
    assert reads == []

    def reassert():
        controller.last_attempt_monotonic -= controller.reassert_after_seconds + 1
        return controller.sync_program(program, LedDisplayState.WORKING)

    # Nobody else wrote: the reassert reads, matches, and writes as before.
    assert reassert().changed and len(reads) == 1 and controller.foreign_writes == []
    target.write_text("#FF00FF\n", encoding="utf-8")
    first = reassert()
    assert first.changed and len(controller.foreign_writes) == 1
    assert not controller.foreign_write_paused
    assert "#FF00FF" not in target.read_text(encoding="utf-8")
    target.write_text("#FF00FF\n", encoding="utf-8")
    second = reassert()
    assert not second.changed and controller.foreign_write_paused
    assert target.read_text(encoding="utf-8") == "#FF00FF\n"
    # A third reassert still leaves the other writer alone.
    assert not reassert().changed
    # JR-Bar's own new program goes out regardless.
    assert controller.sync_program("#FFB000 1s cosine\n#000000 1s cosine\nrepeat", LedDisplayState.WORKING).changed
    assert not controller.foreign_write_paused


def test_the_lights_frame_carries_the_foreign_write_receipt(rig: Rig) -> None:
    rig.plan()
    controller = rig.pro_controller
    controller.foreign_writes = [time.monotonic()]
    controller.foreign_write_paused = False
    receipts = rig.controller._core_build_lights()["device_receipts"]
    assert receipts[rig.pro.device_id]["foreign_writes"] == 1
    assert receipts[rig.pro.device_id]["paused"] is False
    assert rig.dot.device_id not in receipts


# --- Creator Micro 2 and Stream Deck receipts -----------------------------------------


def test_the_creator_micro_receipts_stay_truthful__and_2_more(headless_daemon) -> None:  # noqa: F811
    # --- scenario: a_pad_that_is_paired_but_not_found_says_reconnecting_not_found
    """The pad is paired but Bluetooth says Not Connected: the receipt says
    "reconnecting" with the device's own "not found", and the card never
    claims a connection."""
    from jrbar.optional_integration_runtime import CreatorMicroOutputReceipt

    controller = headless_daemon
    controller._core_deck_probe_rows = lambda: []
    controller._core_deck_integration = lambda: (True, "D0CF130481EC")
    controller.applyCreatorMicroOutputReceipt_(
        CreatorMicroOutputReceipt(False, "reconnecting", "Creator Micro 2 not found")
    )
    receipt = controller._core_deck_receipt
    assert receipt["code"] == "reconnecting"
    assert receipt["detail"] == "Creator Micro 2 not found"
    assert receipt["message"] == "Creator Micro 2: reconnecting."
    device = controller._core_deck_document([])["device"]
    assert device["connected"] is False
    assert device["receipt"]["code"] == "reconnecting"

    # --- scenario: no_device_is_worded_as_nothing_connected
    controller.applyCreatorMicroOutputReceipt_(CreatorMicroOutputReceipt(False, "no_device"))
    assert controller._core_deck_receipt["message"] == "No Creator Micro 2 is connected."
    assert controller._core_deck_document([])["device"]["connected"] is False

    # --- scenario: the_same_receipt_twice_is_one_receipt
    stamp = controller._core_deck_receipt["at"]
    controller.applyCreatorMicroOutputReceipt_(CreatorMicroOutputReceipt(False, "no_device"))
    assert controller._core_deck_receipt["at"] == stamp


def test_the_stream_deck_endpoint_reports_off_as_off(
    headless_daemon,  # noqa: F811
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    """With ``serve_enabled`` off the endpoint is off and says so; switched
    on in a daemon launched without a token it is "enabled, not serving",
    never "serving"."""
    from jrbar.cli import SERVE_ACCESS_TOKEN_ENV

    controller = headless_daemon
    monkeypatch.delenv(SERVE_ACCESS_TOKEN_ENV, raising=False)
    reply = controller._core_dispatch("serve_token", {})
    assert reply["enabled"] is False and reply["running"] is False and reply["token"] is None
    document = controller.settings.to_dict()
    document["serve_enabled"] = True
    controller.settings = settings_from_document(document)
    controller._core_sync_serve_server()
    reply = controller._core_dispatch("serve_token", {})
    assert reply["enabled"] is True and reply["running"] is False
