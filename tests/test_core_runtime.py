"""The headless controller: launches without any AppKit surface, publishes
through the core server, and answers commands on the main thread."""

from __future__ import annotations

import os
import sys
import time
from pathlib import Path
from types import SimpleNamespace
from typing import ClassVar
from unittest.mock import MagicMock

import pytest

from jrbar import core_runtime, status_bar
from jrbar.core_runtime import (
    HeadlessNotificationClient,
    command_names,
    device_transitions,
    get_path,
    mono_to_epoch,
    screen_bar_anchor,
    set_path,
    settings_from_document,
)
from jrbar.core_server import CommandError

REQUIRED_COMMANDS = {
    "open_session", "answer_ask", "snooze", "clear_completed", "undo_clear", "set_setting",
    "reset_settings", "set_brightness", "set_device_display", "apply_calibration", "preview_program",
    "apply_effect", "refresh_usage", "install_hooks", "uninstall_hooks", "set_closed_lid_policy",
    "quiet", "list_history", "doctor", "quit", "open_legacy_window",
    # app-proposed extensions (app/README.md): Effect Studio and Usage Center
    "list_effects", "render_effect", "list_assignments", "set_assignment", "clear_assignment",
    "import_effect_pack", "export_effect_pack", "usage_history",
}


def test_every_protocol_command_is_registered() -> None:
    assert REQUIRED_COMMANDS <= set(command_names())


def test_path_helpers() -> None:
    document = {"colors": {"agent_colors": {"claude": "#D97757"}}, "devices": [{"brightness": 255}]}
    assert get_path(document, "colors.agent_colors.claude") == ("#D97757", True)
    assert get_path(document, "devices.0.brightness") == (255, True)
    assert get_path(document, "devices.3.brightness") == (None, False)
    assert set_path(document, "devices.0.brightness", 128) is True
    assert document["devices"][0]["brightness"] == 128
    assert set_path(document, "devices.9.brightness", 1) is False
    assert set_path(document, "new.nested.key", True) is True
    assert document["new"] == {"nested": {"key": True}}
    assert set_path(document, "", 1) is False


def test_screen_bar_follows_the_strip_anchor_when_linked() -> None:
    assert screen_bar_anchor(200.0, 100.0, linked=True) == 100.0
    assert screen_bar_anchor(50.0, 100.0, linked=True) == 100.0
    assert screen_bar_anchor(200.0, 100.0, linked=False) == 200.0
    assert screen_bar_anchor(200.0, None, linked=True) == 200.0
    assert screen_bar_anchor(None, None, linked=True) is None


def test_device_transitions_key_on_the_device_name() -> None:
    def device(device_id, name, connected=True):
        return SimpleNamespace(device_id=device_id, name=name, connected=connected)

    connected, events = device_transitions(None, [device("/Volumes/SidePulse", "SidePulse")])
    assert connected == {"SidePulse": True} and events == []
    # The id moves from the mount path to the firmware serial: no event.
    connected, events = device_transitions(connected, [device("sidepulse:pro:serial:67", "SidePulse")])
    assert events == []
    connected, events = device_transitions(connected, [device("sidepulse:pro:serial:67", "SidePulse", connected=False), device("/Volumes/PulseDot", "PulseDot")])
    assert events == [("device_connected", "PulseDot", "/Volumes/PulseDot"), ("device_disconnected", "SidePulse", "sidepulse:pro:serial:67")]
    assert connected == {"SidePulse": False, "PulseDot": True}
    # A stale path row beside the live serial row for the same device stays "connected".
    connected, events = device_transitions({"SidePulse": True}, [device("/Volumes/SidePulse", "SidePulse", connected=False), device("sidepulse:pro:serial:67", "SidePulse")])
    assert events == [] and connected == {"SidePulse": True}


def test_mono_to_epoch_is_wall_clock_aligned() -> None:
    import time

    now_mono = time.monotonic()
    assert abs(mono_to_epoch(now_mono) - time.time()) < 0.05
    assert mono_to_epoch(None) is None
    assert mono_to_epoch(True) is None


def test_settings_round_trip_validates_through_the_real_loader(tmp_path: Path) -> None:
    from jrbar.settings import AgentMonitorSettings

    document = AgentMonitorSettings().to_dict()
    document["alert_burst"] = 5
    document["idle_dim_fraction"] = 0.42
    document["closed_lid_awake_policy"] = "not-a-policy"
    settings = settings_from_document(document, scratch_dir=tmp_path)
    assert settings.alert_burst == 5
    assert settings.idle_dim_fraction == 0.42
    # An invalid enum value falls back to the default instead of raising.
    assert settings.closed_lid_awake_policy == AgentMonitorSettings().closed_lid_awake_policy
    assert not list((tmp_path / "core-tmp").iterdir())


def test_headless_notification_client_never_delivers() -> None:
    client = HeadlessNotificationClient()
    assert client.deliver("id", "title", "body", {}) is False
    assert client.set_delegate(object()) is False
    assert client.request_authorization(lambda *_: None) is False
    assert client.authorization_state().value == "unavailable"


class _TimerAPI:
    calls: ClassVar[list[tuple[float, str, bool]]] = []

    @classmethod
    def scheduledTimerWithTimeInterval_target_selector_userInfo_repeats_(cls, interval, _target, selector, _info, repeats):
        cls.calls.append((interval, selector, repeats))
        return SimpleNamespace(invalidate=lambda: None)


class _Thread:
    def __init__(self, *, target, daemon, name=None):
        self.target = target
        self.daemon = daemon
        self.name = name

    def start(self) -> None:
        return None


class _FakeServer:
    def __init__(self, **kwargs) -> None:
        self.kwargs = kwargs
        self.socket_path = kwargs.get("socket_path") or Path("/tmp/core.sock")
        self.published: list[tuple[str, dict]] = []
        self.client_count = 0
        self.stopped = False

    def start(self):
        return self.socket_path

    def stop(self, *, timeout_seconds: float = 2.0) -> None:
        self.stopped = True

    def publish_state(self, document):
        self.published.append(("state", document))

    def publish_lights(self, document):
        self.published.append(("lights", document))

    def publish_settings(self, document):
        self.published.append(("settings", document))

    def publish_event(self, document):
        self.published.append(("event", document))
        return document

    def publish_log(self, line, *, level="info"):
        self.published.append(("log", {"message": line}))


class _FakeDrainer:
    instances: ClassVar[list] = []

    def __init__(self, submit, **kwargs) -> None:
        self.submit = submit
        self.started = False
        _FakeDrainer.instances.append(self)

    def start(self) -> None:
        self.started = True

    def stop(self, timeout_seconds: float = 1.0) -> None:
        self.started = False


@pytest.fixture
def headless(monkeypatch: pytest.MonkeyPatch, tmp_path: Path):
    monkeypatch.setattr(status_bar, "default_settings_path", lambda: tmp_path / "settings.json")
    monkeypatch.setattr(status_bar, "default_latest_state_path", lambda: tmp_path / "latest.json")
    monkeypatch.setattr(status_bar, "default_activity_ledger_path", lambda: tmp_path / "activity-ledger.json")
    monkeypatch.setattr(status_bar, "discover_devices", lambda: [])
    monkeypatch.setattr(status_bar.focus_sync, "active_focus_mode_identifiers", lambda: [])
    monkeypatch.setattr(
        status_bar,
        "runtime_render_environment",
        lambda *, visible, display_asleep=False, process_info=None: SimpleNamespace(
            visible=visible, display_asleep=display_asleep, process_info=process_info
        ),
    )

    def forbidden_status_bar():
        raise AssertionError("headless mode created a status item")

    monkeypatch.setattr(status_bar, "NSStatusBar", SimpleNamespace(systemStatusBar=forbidden_status_bar))
    monkeypatch.setattr(core_runtime, "NSTimer", _TimerAPI)
    monkeypatch.setattr(core_runtime, "NSApp", SimpleNamespace(setActivationPolicy_=MagicMock(), terminate_=MagicMock()))
    monkeypatch.setattr(core_runtime, "CoreServer", _FakeServer)
    monkeypatch.setattr(core_runtime, "PendingHookDrainer", _FakeDrainer)
    monkeypatch.setattr(core_runtime.threading, "Thread", _Thread)
    monkeypatch.setattr(core_runtime, "default_state_dir", lambda *_: tmp_path / "state")
    _TimerAPI.calls.clear()
    _FakeDrainer.instances.clear()

    controller_class = core_runtime.build_headless_controller_class()
    assert controller_class.headless is True
    controller = controller_class.alloc().init()
    controller.virtual_status_device = SimpleNamespace(
        show=MagicMock(name="show"),
        hide=MagicMock(name="hide"),
        terminate=MagicMock(name="terminate"),
        headless=True,
        _enabled=False,
        _live_program_call=None,
        presentation_scheduler_inputs=None,
    )
    for name in (
        "load_operator_local_state", "trim_oversized_state_logs", "start_event_server",
        "start_cloud_ingest_server", "replay_debug_logs", "_install_dnd_environment_observers",
        "_refresh_dnd_environment", "refresh_installed_agent_inventory",
        "_install_accessibility_display_observer", "reconcile_lid_observation",
        "start_remote_peer_timer", "start_remote_peer_refresh", "refresh_intake_report",
    ):
        setattr(controller, name, MagicMock(name=name))
    controller.refresh_ = MagicMock(name="refresh_")
    return controller


def test_headless_launch_skips_every_appkit_surface_and_serves(headless) -> None:
    controller = headless
    controller.applicationDidFinishLaunching_(None)
    assert controller.status_item is None
    controller.virtual_status_device.show.assert_not_called()
    controller.virtual_status_device.hide.assert_called()
    selectors = [selector for _interval, selector, _repeats in _TimerAPI.calls]
    assert "refresh:" in selectors and "pollLiveness:" in selectors and "coreHousekeepingTick:" in selectors
    assert "coreSupervisionTick:" not in selectors
    assert isinstance(controller.notification_client, HeadlessNotificationClient)
    server = controller._core
    assert isinstance(server, _FakeServer)
    assert _FakeDrainer.instances and _FakeDrainer.instances[0].started
    # The settings document went out as soon as the server was up.
    assert any(kind == "settings" for kind, _ in server.published)
    controller.refresh_.assert_called()


def test_settings_property_bumps_the_generation_and_republishes(headless) -> None:
    controller = headless
    controller.applicationDidFinishLaunching_(None)
    server = controller._core
    before = controller._core_settings_generation
    server.published.clear()
    controller.settings = controller.settings.with_alert_burst(4)
    assert controller._core_settings_generation == before + 1
    kinds = [kind for kind, _ in server.published]
    assert kinds == ["settings"]
    assert server.published[0][1]["document"]["alert_burst"] == 4
    assert server.published[0][1]["generation"] == before + 1


def test_commands_run_on_the_main_thread_and_unknown_ones_are_refused(headless) -> None:
    controller = headless
    controller.applicationDidFinishLaunching_(None)
    assert controller._core_dispatch("ping", {})["pong"] is True
    with pytest.raises(CommandError) as refused:
        controller._core_dispatch("nope", {})
    assert refused.value.code == "unknown_command"
    with pytest.raises(CommandError) as missing:
        controller._core_dispatch("open_session", {"session": "claude:session:none"})
    assert missing.value.code == "not_found"
    with pytest.raises(CommandError) as invalid:
        controller._core_dispatch("quiet", {"mode": "loud", "seconds": 60})
    assert invalid.value.code == "invalid_args"
    with pytest.raises(CommandError) as bad_path:
        controller._core_dispatch("set_setting", {"path": "devices.7.brightness", "value": 1})
    assert bad_path.value.code == "invalid_path"


def test_set_setting_writes_validates_and_reports_the_generation(headless, tmp_path: Path) -> None:
    controller = headless
    controller.applicationDidFinishLaunching_(None)
    reply = controller._core_dispatch("set_setting", {"path": "alert_burst", "value": 2})
    assert reply["path"] == "alert_burst" and reply["value"] == 2
    assert reply["generation"] == controller._core_settings_generation
    assert controller.settings.alert_burst == 2
    # conftest pins every settings facade to one per-test file.
    assert (tmp_path / "pytest-sidepulse-settings.json").exists()
    reset = controller._core_dispatch("reset_settings", {"paths": ["alert_burst", "no.such.path"]})
    assert reset["reset"] == ["alert_burst"]
    assert controller.settings.alert_burst == status_bar.AgentMonitorSettings().alert_burst


def test_app_introduced_settings_are_served_and_the_token_path_is_read_only(headless) -> None:
    """The three keys the app catalogued as "Not provided by core":
    ``menu_bar_icon_style`` and ``quota_alert_thresholds`` are real,
    persisted preferences; ``cloud_ingest_token_path`` is the daemon's own
    fact, in the document but never writable."""
    from jrbar.cloud_ingest import default_token_path

    controller = headless
    controller.applicationDidFinishLaunching_(None)
    server = controller._core
    document = next(payload for kind, payload in server.published if kind == "settings")["document"]
    assert document["menu_bar_icon_style"] == "glyph"
    assert document["quota_alert_thresholds"] == [90.0, 95.0]
    assert document["cloud_ingest_token_path"] == str(default_token_path())

    reply = controller._core_dispatch("set_setting", {"path": "menu_bar_icon_style", "value": "glyph_ring"})
    assert reply["value"] == "glyph_ring" and controller.settings.menu_bar_icon_style == "glyph_ring"
    # An unknown style falls back to the glyph rather than failing.
    assert controller._core_dispatch("set_setting", {"path": "menu_bar_icon_style", "value": "neon"})["value"] == "glyph"
    reply = controller._core_dispatch("set_setting", {"path": "quota_alert_thresholds", "value": [95, 80.5, 95]})
    assert reply["value"] == [80.5, 95.0] and controller.settings.quota_alert_thresholds == (80.5, 95.0)
    assert controller._core_dispatch("set_setting", {"path": "quota_alert_thresholds", "value": []})["value"] == [90.0, 95.0]
    with pytest.raises(CommandError) as refused:
        controller._core_dispatch("set_setting", {"path": "cloud_ingest_token_path", "value": "/tmp/x"})
    assert refused.value.code == "read_only"
    # The path is not a preference, so a reset leaves it alone and the
    # settings file never carries it.
    assert controller._core_dispatch("reset_settings", {"paths": ["cloud_ingest_token_path"]})["reset"] == []
    assert "cloud_ingest_token_path" not in controller.settings.to_dict()
    published = [payload for kind, payload in server.published if kind == "settings"][-1]["document"]
    assert published["cloud_ingest_token_path"] == str(default_token_path())
    assert published["quota_alert_thresholds"] == [90.0, 95.0]


def test_state_builds_feed_the_usage_sample_buffer(headless, tmp_path: Path) -> None:
    """Every state build records the provider lanes into the daemon's
    sample buffer (under the state dir), and the projection reads the
    forecast back from it once there is history."""
    from jrbar.core_usage_samples import SAMPLE_LIMIT, UsageSample

    controller = headless
    controller.applicationDidFinishLaunching_(None)
    buffer = controller._core_usage_samples
    assert buffer.path == tmp_path / "state" / "usage-samples.json" and buffer.is_empty
    controller.provider_usage_state = SimpleNamespace(
        refreshed_at=1.0, next_refresh_at=2.0, refreshing=False,
        snapshots=(
            SimpleNamespace(
                provider_id="claude", source_instance_id="default", account_label="Max",
                state=SimpleNamespace(value="ready"), reason_code=None, action_label=None, observed_at=1.0,
                input_tokens=0, cached_input_tokens=0, output_tokens=0, estimated_cost_usd=None, credits_remaining=None,
                lanes=(SimpleNamespace(lane_id="five-hour", label="5h", remaining_percent=58.0, reset_at=None, scope="account", model=None),),
            ),
        ),
    )
    document = controller._core_build_state()
    assert buffer.samples("claude", "five-hour") == [UsageSample(document["now"], 42.0)]
    claude = document["usage"]["providers"][0]
    assert claude["forecast"] is None  # one sample is not a pace
    assert buffer.path.exists()  # the first change is saved at once
    # Backfill an hour of history: the next build carries a forecast.
    now = document["now"]
    buffer._table["claude|five-hour"] = [UsageSample(now - offset * 60.0, 42.0 - offset * 0.2) for offset in range(60, 0, -5)]
    document = controller._core_build_state()
    forecast = document["usage"]["providers"][0]["forecast"]
    assert forecast["window_id"] == "five-hour" and forecast["pace"] == "ahead"
    assert forecast["rate_pct_per_hour"] == pytest.approx(12.0, abs=0.1)
    assert len(buffer.samples("claude", "five-hour")) <= SAMPLE_LIMIT
    # Quitting writes the buffer out, whatever the save throttle says.
    buffer.path.unlink()
    controller.applicationWillTerminate_(None)
    assert buffer.path.exists()


def test_doctor_and_history_answer_without_a_snapshot(headless) -> None:
    controller = headless
    controller.applicationDidFinishLaunching_(None)
    history = controller._core_dispatch("list_history", {"limit": 10})
    assert history["rows"] == [] and history["total"] == 0
    doctor = controller._core_dispatch("doctor", {})
    assert doctor["core_version"] == core_runtime.CORE_VERSION
    assert doctor["pid"] == os.getpid()
    assert doctor["python"] == sys.executable and "commit" in doctor
    assert {check["name"] for check in doctor["checks"]} >= {"hook shim", "pending hook lines"}
    assert "open_session" in doctor["commands"]


def test_terminate_stops_the_server_and_drainer(headless) -> None:
    controller = headless
    controller.applicationDidFinishLaunching_(None)
    server = controller._core
    controller._core_stop_server()
    assert server.stopped is True
    assert controller._core is None
    assert not _FakeDrainer.instances[0].started


def test_effect_commands_read_and_write_the_real_stores(headless, monkeypatch: pytest.MonkeyPatch, tmp_path: Path) -> None:
    import json

    from jrbar import core_effects, effect_assignment_store, effect_pack_store
    from jrbar.effect_assignment_store import EffectAssignmentCache
    from jrbar.effect_registry import EFFECT_REGISTRY

    monkeypatch.setattr(effect_assignment_store, "default_effect_assignment_path", lambda home=None: tmp_path / "assignments.json")
    monkeypatch.setattr(effect_pack_store, "default_effect_pack_store_path", lambda home=None: tmp_path / "packs")
    monkeypatch.setattr(core_effects, "default_state_dir", lambda *_: tmp_path)
    controller = headless
    controller.applicationDidFinishLaunching_(None)
    monkeypatch.setattr(type(controller), "_effect_assignment_cache", EffectAssignmentCache(registry=EFFECT_REGISTRY), raising=False)

    catalog = controller._core_dispatch("list_effects", {})
    assert {"none", "pulse", "alert", "aurora"} <= {effect["id"] for effect in catalog["effects"]}
    assert catalog["packs"] == [] and catalog["generation"] == 0
    render = controller._core_dispatch("render_effect", {"effect_id": "blink", "parameters": {"cadence": "double"}, "led_count": 2})
    assert render["led_count"] == 2 and render["cadence"]["id"] == "double" and "300ms" in render["program"]
    with pytest.raises(CommandError) as unknown:
        controller._core_dispatch("render_effect", {"effect_id": "nope"})
    assert unknown.value.code == "unknown_effect"

    assert controller._core_dispatch("list_assignments", {})["assignments"] == []
    reply = controller._core_dispatch(
        "set_assignment", {"effect_id": "aurora", "scope": "provider", "target_id": "codex", "parameters": {"wave_count": 3}}
    )
    assert reply["assignment"] == {"effect_id": "aurora", "scope": "provider", "target_id": "codex", "parameters": reply["assignment"]["parameters"]}
    assert reply["assignment"]["parameters"]["wave_count"] == 3
    assert reply["assignments"][0]["parameters"]["wave_count"] == 3
    assert reply["generation"] == 1
    saved = json.loads((tmp_path / "assignments.json").read_text())
    assert saved["assignments"][0]["effect_id"] == "aurora"
    for scope, target, code in (("semantic", "asking", "reserved_semantic"), ("global", "x", "invalid_target"), ("bogus", None, "invalid_scope")):
        with pytest.raises(CommandError) as refused:
            controller._core_dispatch("set_assignment", {"effect_id": "pulse", "scope": scope, "target_id": target})
        assert refused.value.code == code
    cleared = controller._core_dispatch("clear_assignment", {"scope": "provider", "target_id": "codex"})
    assert cleared["removed"] is True and cleared["assignments"] == []
    assert controller._core_dispatch("clear_assignment", {"scope": "provider", "target_id": "codex"})["removed"] is False

    exported = controller._core_dispatch(
        "export_effect_pack", {"ids": ["pulse", "aurora"], "path": str(tmp_path / "out" / "my pack.json"), "name": "Night Lab"}
    )
    assert exported["effects"] == 2 and exported["id"] == "night-lab"
    imported = controller._core_dispatch("import_effect_pack", {"path": exported["path"]})
    assert imported["imported"] == {"id": "night-lab", "name": "Night Lab", "effects": 2}
    assert "pack:night-lab:aurora" in {effect["id"] for effect in imported["effects"]}
    assert imported["packs"][0]["path"] == exported["path"]
    with pytest.raises(CommandError) as again:
        controller._core_dispatch("import_effect_pack", {"path": exported["path"]})
    assert again.value.code == "conflict"
    with pytest.raises(CommandError) as bad:
        controller._core_dispatch("import_effect_pack", {"path": str(tmp_path / "missing.json")})
    assert bad.value.code == "invalid_pack"
    packed = controller._core_dispatch("render_effect", {"effect_id": "pack:night-lab:aurora", "parameters": {"duration_seconds": 1.0}})
    assert packed["parameters"]["motion"] == "aurora" and packed["program"]


def test_usage_history_scans_the_provider_and_refuses_bad_ranges(headless, monkeypatch: pytest.MonkeyPatch) -> None:
    from jrbar import core_usage_history

    controller = headless
    controller.applicationDidFinishLaunching_(None)
    calls: list[tuple[str, int]] = []

    def fake_scan(provider, *, days, home=None):
        calls.append((provider, days))
        return [("claude", "s", "fable", time.time(), 10, 0, 0, 5, "d")]

    monkeypatch.setattr(core_usage_history, "scan_provider_records", fake_scan)
    document = controller._core_dispatch("usage_history", {"provider": "claude", "range": "7d"})
    assert calls == [("claude", 7)]
    assert document["days"][-1]["tokens_in"] == 10 and len(document["days"]) == 7
    with pytest.raises(CommandError) as bad_range:
        controller._core_dispatch("usage_history", {"provider": "claude", "range": "2d"})
    assert bad_range.value.code == "invalid_range"
    with pytest.raises(CommandError) as unknown:
        controller._core_dispatch("usage_history", {"provider": "grok", "range": "7d"})
    assert unknown.value.code == "not_found"


def test_linked_pro_and_dot_are_written_in_one_worker_command(headless) -> None:
    """With ``devices_linked`` and both mounted, the Dot's request rides on
    the Pro's command: one submission, the Dot written right after the Pro
    from the same presentation, both results applied on the main thread,
    the skew measured, and the lights document saying so."""
    from jrbar._led_status_legacy import LedDisplayState, LedStatusWrite
    from jrbar.models import AgentMode
    from jrbar.status_bar_legacy import HardwareWriteRequest, HardwareWriteResult, StatusBarDevice

    controller = headless
    pro_device = StatusBarDevice("sidepulse:pro:1", "SidePulse", Path("/Volumes/SidePulse"), Path("/Volumes/SidePulse/LEDS.LED"), True, "agent")
    dot_device = StatusBarDevice("sidepulse:dot:1", "SidePulse Dot", Path("/Volumes/PulseDot"), Path("/Volumes/PulseDot/LEDS.LED"), True, "agent")
    pro = HardwareWriteRequest(pro_device, AgentMode.WORKING, None, (), None, 0.5)
    dot = HardwareWriteRequest(dot_device, AgentMode.WORKING, None, (), None, 0.5)
    submitted: list = []
    discarded: list = []
    controller._hardware_write_worker = SimpleNamespace(
        submit=lambda command: submitted.append(command),
        discard_pending_prefix=lambda prefix: discarded.append(prefix),
    )
    controller._hardware_write_generation = 1
    controller._hardware_write_active = True
    controller.settings = controller.settings.with_devices_linked(True)

    controller._submit_hardware_write_requests([pro, dot], 100.0)
    assert [command.payload for command in submitted] == [pro]
    assert controller._core_linked_companion[2] is dot
    assert discarded == [controller._hardware_worker_key(dot_device)]

    completed = {"pro": 100.0, "dot": 100.011}

    def fake_sync(request):
        which = "dot" if request is dot else "pro"
        return HardwareWriteResult(
            request=request,
            write=LedStatusWrite(LedDisplayState.WORKING, request.device.target, "0:#000000", True),
            label=f"{request.device.name} Working",
            agent_display_rendered=True,
            completed_at=completed[which],
        )

    controller._sync_hardware_device = fake_sync
    # The linked Dot write hands the Dot the Pro's program bytes through the
    # Dot's own controller; stub that path so the timing fixture holds.
    handed = []

    class FakeDotController:
        def sync_program(self, program, state):
            handed.append((program, state))
            return LedStatusWrite(state, dot.device.target, program, True)

    controller.agent_controller_for_device = lambda device: FakeDotController()
    controller._runtime_worker_monotonic = lambda: completed["dot"]
    result = controller._execute_hardware_write_command(submitted[0])
    assert result.request is pro
    dot_command, dot_result = controller._core_linked_results[submitted[0].key]
    assert dot_command.payload is dot and dot_result.request is dot
    assert handed == [(result.write.program, result.write.state)]
    assert dot_result.write.program == result.write.program
    assert dot_result.label.endswith(f"linked to {pro.device.name}")

    controller._apply_hardware_write_result(submitted[0], result)
    assert controller._core_linked_results == {}
    assert controller._core_linked_skew_ms == 11.0
    assert set(controller._core_hardware_anchor) == {"sidepulse:pro:1", "sidepulse:dot:1"}

    # Unlinked: every device gets its own command, nothing rides along.
    submitted.clear()
    controller.settings = controller.settings.with_devices_linked(False)
    controller._submit_hardware_write_requests([pro, dot], 100.0)
    assert [command.payload for command in submitted] == [pro, dot]
    assert controller._core_linked_companion is None


def test_extra_lookups_serve_new_sessions_before_refreshing_expired_ones() -> None:
    from jrbar.core_runtime import plan_extra_lookups

    cached = {"a": (0.0, None), "b": (1.0, None), "c": (50.0, None)}
    ids = ["a", "b", "c", "d", "e"]
    # d and e were never looked up: they win, then the stalest expired (a, b); c is fresh.
    assert plan_extra_lookups(ids, cached, now=60.0, ttl=30.0, budget=3) == ["d", "e", "a"]
    assert plan_extra_lookups(ids, cached, now=60.0, ttl=30.0, budget=10) == ["d", "e", "a", "b"]
    assert plan_extra_lookups(ids, cached, now=60.0, ttl=30.0, budget=0) == []
    assert plan_extra_lookups([], cached, now=60.0, ttl=30.0, budget=3) == []


def test_linked_dot_replays_the_strip_for_ambient_and_plain_writes(headless) -> None:
    """Once the strip has written, every ordinary or ambient request for
    the Dot replays the strip's program through the Dot's controller. The
    live bug: an ambient "binary heartbeat" write landed on the Dot right
    after the linked write and left it on a solid colour at full brightness.
    Operator previews still reach the Dot."""
    from jrbar._led_status_legacy import LedDisplayState, LedStatusWrite
    from jrbar.models import AgentMode
    from jrbar.status_bar_legacy import HardwareWriteRequest, HardwareWriteResult, StatusBarDevice

    controller = headless
    pro_device = StatusBarDevice("sidepulse:pro:1", "SidePulse", Path("/Volumes/SidePulse"), Path("/Volumes/SidePulse/LEDS.LED"), True, "agent")
    dot_device = StatusBarDevice("sidepulse:dot:1", "SidePulse Dot", Path("/Volumes/PulseDot"), Path("/Volumes/PulseDot/LEDS.LED"), True, "agent")
    controller.settings = controller.settings.with_devices_linked(True)
    controller._runtime_worker_monotonic = lambda: 5.0

    pro = HardwareWriteRequest(pro_device, AgentMode.WORKING, None, (), None, 0.5)
    pro_write = LedStatusWrite(LedDisplayState.WORKING, pro_device.target, "#112233 500ms pulse\nrepeat", True)
    controller._hardware_write_generation = 1
    controller._hardware_write_active = True
    command = controller._hardware_write_command(pro, 100.0)
    controller._core_note_hardware_write(
        command,
        HardwareWriteResult(request=pro, write=pro_write, label="SidePulse Working", agent_display_rendered=True, completed_at=4.0),
    )
    assert controller._core_linked_pro_program == (pro_write.program, pro_write.state)

    handed = []

    class FakeDotController:
        def sync_program(self, program, state):
            handed.append((program, state))
            return LedStatusWrite(state, dot_device.target, program, True)

    controller.agent_controller_for_device = lambda device: FakeDotController()
    ambient = HardwareWriteRequest(
        dot_device, AgentMode.WORKING, None, (), None, 0.5,
        override_program="0:#001B22 1:#14732D", override_state=LedDisplayState.WORKING,
        coalesce_identity="ambient-dot-heartbeat",
    )
    result = controller._sync_hardware_device(ambient)
    assert handed == [(pro_write.program, pro_write.state)]
    assert result.write.program == pro_write.program and result.label == "SidePulse Dot linked"

    plain = HardwareWriteRequest(dot_device, AgentMode.WORKING, None, (), None, 0.5)
    controller._sync_hardware_device(plain)
    assert len(handed) == 2

    preview = HardwareWriteRequest(
        dot_device, AgentMode.WORKING, None, (), None, 0.5,
        override_program="#FFFFFF 500ms\nrepeat", override_state=LedDisplayState.ASK,
        coalesce_identity="preview-effect-studio", preview_session_id="s",
    )
    assert controller._core_linked_dot_follows(preview) is False

    controller.settings = controller.settings.with_devices_linked(False)
    assert controller._core_linked_dot_follows(plain) is False
