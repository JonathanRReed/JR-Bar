"""The headless controller: launches without any AppKit surface, publishes
through the core server, and answers commands on the main thread."""

from __future__ import annotations

import os
import sys
import threading
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


REAL_THREAD = threading.Thread


class _Thread:
    def __init__(self, *, target, daemon, name=None, args=()):
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
    # The scan runs off the socket thread, so this command needs a real one.
    # Only this one: the fixture's inert Thread stands in for every other
    # daemon thread, and turning them all on would start the HID probe and
    # the start-up warm-up as a side effect of a usage test.
    controller._core_usage_history_service = core_usage_history.UsageHistoryService(
        lambda provider, days: core_usage_history.scan_provider_records(provider, days=days),
        controller._core_publish_event,
        log=controller._core_log,
        thread_factory=REAL_THREAD,
    )
    document = controller._core_dispatch("usage_history", {"provider": "claude", "range": "7d"})
    assert calls == [("claude", 7)]
    assert document["days"][-1]["tokens_in"] == 10 and len(document["days"]) == 7
    with pytest.raises(CommandError) as bad_range:
        controller._core_dispatch("usage_history", {"provider": "claude", "range": "2d"})
    assert bad_range.value.code == "invalid_range"
    with pytest.raises(CommandError) as unknown:
        controller._core_dispatch("usage_history", {"provider": "grok", "range": "7d"})
    assert unknown.value.code == "not_found"
    # Gemini has no configured account and no transcripts to scan here, but
    # it has a price table: the window still gets a rate card, marked
    # estimated, instead of a not_found the Usage window cannot render.
    gemini = controller._core_dispatch("usage_history", {"provider": "gemini", "range": "7d"})
    assert gemini["records"] == 0 and gemini["pending"] is False
    assert gemini["pricing"]["estimated"] is True
    assert gemini["pricing"]["model"] == core_usage_history.REFERENCE_MODEL["gemini"]


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
    # 30% of the strip's LIGHT (nominal 149), and every LED addressed on the
    # narrowed line -- a band painted once and never again is a band that
    # holds a colour from a finished program forever.
    assert handed == [("brightness 149\n0:#000000; 1:#000000", result.write.state)]
    # The Dot plays the strip's program NARROWED, not the strip's bytes: the
    # Pro's `0:#000000` says nothing about the Dot's second LED, and a line
    # that says nothing about an LED is how one gets stranded.
    assert dot_result.write.program == "brightness 149\n0:#000000; 1:#000000"
    assert dot_result.label.endswith(f"extend with {pro.device.name}")

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


def test_quitting_turns_every_mounted_strip_off_pro_and_dot(headless, monkeypatch: pytest.MonkeyPatch) -> None:
    """Terminating writes ``off`` to each connected strip's own file: the
    Pro and the Dot both, past the controllers' dedupe (a linked Dot's
    last identity is the Pro's program) and the resting glow; an
    unmounted device and the Screen Bar are skipped, and one failing
    volume does not stop the other."""
    from jrbar import device_writer
    from jrbar.status_bar_legacy import StatusBarDevice

    controller = headless
    controller.applicationDidFinishLaunching_(None)
    pro = StatusBarDevice("sidepulse:pro:1", "SidePulse", Path("/Volumes/SidePulse"), Path("/Volumes/SidePulse/LEDS.LED"), True, "agent")
    dot = StatusBarDevice("sidepulse:dot:1", "PulseDot", Path("/Volumes/PulseDot"), Path("/Volumes/PulseDot/LEDS.LED"), True, "agent")
    gone = StatusBarDevice("sidepulse:pro:2", "Spare", Path("/Volumes/Spare"), Path("/Volumes/Spare/LEDS.LED"), False, "agent")
    screen = StatusBarDevice(status_bar.VIRTUAL_DEVICE_ID, "Screen Bar", Path("/virtual"), Path("/virtual/LEDS.LED"), True, "agent")
    controller.status_bar_devices = lambda *, remember=True: [pro, dot, gone, screen]
    writes: list[tuple[str, Path, bool]] = []

    def fake_write(text, *, device_path=None, file_name="LEDS.LED", dry_run=False, preserve_existing_inode=False):
        writes.append((text, device_path, preserve_existing_inode))
        if device_path == pro.target:
            raise OSError("volume busy")
        return device_path

    monkeypatch.setattr(device_writer, "write_led_program", fake_write)
    assert controller._core_lights_off() == ["sidepulse:dot:1"]
    assert writes == [("off", pro.target, True), ("off", dot.target, True)]

    # The real terminate path reaches it, once, after the legacy teardown.
    writes.clear()
    controller.applicationWillTerminate_(None)
    assert [path for _text, path, _keep in writes] == [pro.target, dot.target]
    controller.applicationWillTerminate_(None)
    assert len(writes) == 2


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
    # Default linked scale 0.3 of the Dot's full brightness -- 30% of the
    # LIGHT, so the nominal code is linear_to_srgb(0.3) * 255 = 149. Scaling
    # the CODE (255 * 0.3 = 76) reads like the same thing and is not: the
    # write boundary decodes it, and 76 arrived as 6.7% of the strip's light.
    assert handed == [(f"brightness 149\n{pro_write.program}", pro_write.state)]
    assert result.write.program.endswith(pro_write.program) and result.label == "SidePulse Dot extend"

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


def test_linked_dot_program_folds_brightness_lines(headless) -> None:
    controller = headless
    controller.settings = controller.settings.with_linked_dot_scale(0.5)
    dot = SimpleNamespace(brightness=200)
    out = controller._core_dot_plan(dot, "brightness 100\n#112233 500ms\nrepeat")
    # The cap is min(strip 100, dot 200) = 100, and the scale is half the
    # LIGHT that code means, re-encoded: 71. The strip's own line is folded in
    # so the Dot never carries two.
    assert out.program == "brightness 71\n#112233 500ms\nrepeat"
    assert out.program.count("brightness") == 1
    assert (
        controller._core_dot_plan(SimpleNamespace(brightness=255), "#FFFFFF").program
        == "brightness 188\n#FFFFFF"
    )


def test_a_finished_finite_cue_re_arms_the_live_program_on_either_device(headless) -> None:
    """The Pro was found dark, and the Dot holding one lit LED, because the
    completion cue ended in ``repeat 8`` and nothing wrote again for four
    minutes (the reassert backstop). A cue that ends is a cue that has to
    hand the surface back."""
    import time as _time
    from pathlib import Path as _Path

    from jrbar._led_status_legacy import LedDisplayState, LedStatusWrite
    from jrbar.models import AgentMode
    from jrbar.status_bar_legacy import HardwareWriteRequest, HardwareWriteResult, StatusBarDevice

    controller = headless
    for device_id, name, volume, cue in (
        ("sidepulse:pro:1", "SidePulse", "SidePulse",
         "#791BFF 180ms none\noff 120ms none\n#791BFF 180ms none\noff 520ms none\nrepeat 8"),
        ("sidepulse:dot:1", "SidePulse Dot", "PulseDot",
         "0:#722CA1 1:#14732D 250ms none\n0:#000000 1:#14732D 250ms none\nrepeat 8"),
    ):
        device = StatusBarDevice(
            device_id, name, _Path(f"/Volumes/{volume}"),
            _Path(f"/Volumes/{volume}/LEDS.LED"), True, "agent",
        )
        request = HardwareWriteRequest(device, AgentMode.WORKING, None, (), None, 0.5)
        command = controller._hardware_write_command(request, 100.0)
        write = LedStatusWrite(LedDisplayState.DONE, device.target, cue, True)
        controller._core_note_hardware_write(
            command,
            HardwareWriteResult(
                request=request, write=write, label=f"{name} Done",
                agent_display_rendered=True, completed_at=1.0,
            ),
        )
        assert device_id in controller._core_finite_cue_end

        stub = SimpleNamespace(last_program_identity=("program", cue), last_attempt_monotonic=1.0)
        controller.agent_led_controllers_by_device[device_id] = stub
        # Mid-cue: nothing to do, and nothing may disturb the running cue.
        assert controller._core_repaint_finished_cues(_time.monotonic()) is False
        assert stub.last_program_identity is not None
        # The instant it ends: the deduper is cleared so the next refresh
        # genuinely rewrites, instead of deciding the device is up to date.
        assert controller._core_repaint_finished_cues(
            controller._core_finite_cue_end[device_id]
        ) is True
        assert stub.last_program_identity is None
        assert stub.last_attempt_monotonic == 0.0
        assert device_id not in controller._core_finite_cue_end
        # And it fires exactly once.
        assert controller._core_repaint_finished_cues(_time.monotonic() + 1000) is False

    # A program that loops forever is not a cue and arms nothing.
    device = StatusBarDevice(
        "sidepulse:pro:1", "SidePulse", _Path("/Volumes/SidePulse"),
        _Path("/Volumes/SidePulse/LEDS.LED"), True, "agent",
    )
    request = HardwareWriteRequest(device, AgentMode.WORKING, None, (), None, 0.5)
    controller._core_note_hardware_write(
        controller._hardware_write_command(request, 100.0),
        HardwareWriteResult(
            request=request,
            write=LedStatusWrite(
                LedDisplayState.WORKING, device.target,
                "#00E5FF 600ms pulse\noff 600ms cosine\nrepeat", True,
            ),
            label="SidePulse Working", agent_display_rendered=True, completed_at=1.0,
        ),
    )
    assert controller._core_finite_cue_end == {}



def test_the_dots_role_decides_what_it_plays(headless) -> None:
    """``dot_role`` is the authority over the Dot, not the strip and not a
    per-device display kind. The live 0.8 bug: an eight-LED chase written to
    a two-LED Dot (LEDs 0 and 1 black in most frames, so the Dot looked
    dead), while the Dot's ``why`` stayed frozen on a long-gone quota alert
    because linked mode had taken its render path away."""
    from pathlib import Path as _Path

    from jrbar.device_writer import leds_addressed_beyond
    from jrbar.models import AgentMode
    from jrbar.status_bar_legacy import HardwareWriteRequest, StatusBarDevice

    controller = headless
    controller.settings = controller.settings.with_devices_linked(True)
    dot_device = StatusBarDevice(
        "sidepulse:dot:1", "SidePulse Dot", _Path("/Volumes/PulseDot"),
        _Path("/Volumes/PulseDot/LEDS.LED"), True, "quota_runway",
    )
    request = HardwareWriteRequest(dot_device, AgentMode.WORKING, None, (), None, 0.5)
    chase = (
        "#000000 #000000 #000000 #000000 #02111E #000000 #000000 #000000 250ms none\n"
        "off 250ms none\nrepeat"
    )
    controller._core_linked_pro_program = (chase, None)
    controller._core_linked_pro_leds = 8

    # extend: the strip's colours, rendered for two LEDs, never wider.
    controller.settings = controller.settings.with_dot_role("extend")
    assert controller._core_linked_dot_follows(request) is True
    plan = controller._core_dot_plan(SimpleNamespace(brightness=255))
    assert leds_addressed_beyond(plan.program, 2) == ()
    assert "#02111E" in plan.program
    assert plan.role == "extend"

    # asks: dark while nobody is needed, amber the moment someone is.
    controller.settings = controller.settings.with_dot_role("asks")
    with controller._core_lock:
        controller._core_documents["state"] = {"aggregate": {"needs_you": 0}}
    # The brightness line still applies: it scales the device's resting glow.
    # ``asks`` is a beacon, not a continuation: linked_dot_scale does not
    # apply to it, so a full-brightness Dot carries no brightness line at all.
    assert controller._core_dot_plan(SimpleNamespace(brightness=255)).program == "off"
    # A session merely waiting on input carries no answerable ask row, but
    # the fleet headline still says needs_you -- and a person is still needed.
    with controller._core_lock:
        controller._core_documents["state"] = {
            "aggregate": {"needs_you": 0, "mode": "needs_you"}
        }
    assert controller._core_dot_beacon_facts().ask_count == 1
    with controller._core_lock:
        controller._core_documents["state"] = {"aggregate": {"needs_you": 1}}
    asking = controller._core_dot_plan(SimpleNamespace(brightness=255))
    assert asking.program.splitlines()[0].startswith("#FF9F0A") and asking.why == "waiting"
    # No strip needed: a beacon is not a continuation of anything.
    controller._core_linked_pro_program = None
    assert controller._core_linked_dot_follows(request) is True

    # status: the Dot renders its own two-LED display, as it always has.
    controller.settings = controller.settings.with_dot_role("status")
    assert controller._core_linked_dot_follows(request) is False
    assert controller._core_dot_plan(SimpleNamespace(brightness=255)) is None


# --- clear_completed / undo_clear over the real command path -----------------


def _visibility_snapshot(now):
    """A snapshot shaped like the owner's report: one live session and four
    rows the panel keeps calling "Done · stale" an hour later."""
    from datetime import datetime, timedelta, timezone

    from jrbar.capacity_types import SourceKey
    from jrbar.models import AgentMode, AgentStatus
    from jrbar.provider_facts import WorkIdentifier, WorkKey

    collected_at = datetime.fromtimestamp(now, tz=timezone.utc)

    def status(agent_id, *, provider, mode, event_name, minutes_ago, stale):
        source = SourceKey(provider, "hooks", "local", "agent_events")
        return AgentStatus(
            provider=provider,
            agent_id=agent_id,
            display_name=agent_id.rsplit(":", 1)[-1],
            mode=mode,
            updated_at=collected_at - timedelta(minutes=minutes_ago),
            event_name=event_name,
            session_id=agent_id.rsplit(":", 1)[-1],
            stale=stale,
            work_key=WorkKey(source, WorkIdentifier(agent_id.replace(":", "."))),
        )

    live = status("claude:session:live", provider="claude", mode=AgentMode.WORKING, event_name="UserPromptSubmit", minutes_ago=0.2, stale=False)
    done = status("devin:session:troubled", provider="devin", mode=AgentMode.COMPLETED, event_name="Stop", minutes_ago=3.5, stale=True)
    done_18 = status("devin:session:fair-tal", provider="devin", mode=AgentMode.COMPLETED, event_name="Stop", minutes_ago=18.1, stale=True)
    closed = status("codex:session:closed", provider="codex", mode=AgentMode.COMPLETED, event_name="SessionEnd", minutes_ago=5.0, stale=True)
    quiet = status("devin:session:lapis-fl", provider="devin", mode=AgentMode.IDLE_READY, event_name="SessionStart", minutes_ago=6.0, stale=True)
    return SimpleNamespace(
        aggregate=SimpleNamespace(mode=AgentMode.WORKING),
        statuses=(live,),
        stale_statuses=(done, done_18, closed, quiet),
        collected_at=collected_at,
    )


@pytest.fixture()
def cleared(headless, tmp_path: Path):
    controller = headless
    controller.applicationDidFinishLaunching_(None)
    controller.clear_agents_path = tmp_path / "clear-agents.json"
    controller.last_snapshot = _visibility_snapshot(time.time())
    controller._core_publish_state()
    return controller


def _listed(controller) -> list[str]:
    with controller._core_lock:
        return [row["id"] for row in (controller._core_documents["state"] or {})["sessions"]]


def test_clear_completed_leaves_only_live_sessions_and_undo_puts_them_back(cleared) -> None:
    controller = cleared
    before = _listed(controller)
    assert before == [
        "claude:session:live",
        "devin:session:troubled",
        "devin:session:fair-tal",
        "codex:session:closed",
        "devin:session:lapis-fl",
    ]

    reply = controller._core_dispatch("clear_completed", {"sessions": "all"})

    assert reply["batch"]
    # Every row that was over, including the closed session and the quiet
    # one -- not only "completed recently".
    assert reply["cleared"] == [
        "codex:session:closed",
        "devin:session:fair-tal",
        "devin:session:lapis-fl",
        "devin:session:troubled",
    ]
    assert _listed(controller) == ["claude:session:live"]
    with controller._core_lock:
        state = controller._core_documents["state"]
    assert state["hidden_count"] == 4
    assert state["unseen_completions"] == [] and state["aggregate"]["ready"] == 0
    assert controller.clear_agents_path.exists()

    undone = controller._core_dispatch("undo_clear", {"batch": reply["batch"]})
    assert undone["batch"] == reply["batch"]
    assert undone["restored"] == reply["cleared"]
    assert _listed(controller) == before


def test_clear_completed_can_name_a_subset_and_never_touches_live_rows(cleared) -> None:
    controller = cleared

    reply = controller._core_dispatch(
        "clear_completed",
        {"sessions": ["devin:session:troubled", "claude:session:live"]},
    )

    # The live row was asked for and refused; only the finished one cleared.
    assert reply["cleared"] == ["devin:session:troubled"]
    assert _listed(controller) == [
        "claude:session:live",
        "devin:session:fair-tal",
        "codex:session:closed",
        "devin:session:lapis-fl",
    ]


def test_clearing_a_list_with_nothing_over_is_a_no_op(cleared) -> None:
    controller = cleared
    controller._core_dispatch("clear_completed", {"sessions": "all"})
    again = controller._core_dispatch("clear_completed", {"sessions": "all"})
    assert again == {"batch": None, "cleared": []}
    assert controller._core_dispatch("clear_completed", {"sessions": []}) == {"batch": None, "cleared": []}
    with pytest.raises(CommandError) as bad:
        controller._core_dispatch("clear_completed", {"sessions": "some"})
    assert bad.value.code == "invalid_args"


def test_undo_clear_expires_after_its_window(cleared, monkeypatch: pytest.MonkeyPatch) -> None:
    controller = cleared
    reply = controller._core_dispatch("clear_completed", {"sessions": "all"})
    later = time.time() + 301.0
    monkeypatch.setattr(core_runtime.time, "time", lambda: later)
    with pytest.raises(CommandError) as expired:
        controller._core_dispatch("undo_clear", {"batch": reply["batch"]})
    assert expired.value.code == "expired"
    with pytest.raises(CommandError) as unknown:
        controller._core_dispatch("undo_clear", {"batch": "nope"})
    assert unknown.value.code == "not_found"


def test_a_dead_process_reads_ended_not_done(cleared, monkeypatch: pytest.MonkeyPatch) -> None:
    """The green check is a claim about the provider, and a session whose
    process is gone has nobody left to make it."""
    from jrbar import process_registry

    monkeypatch.setattr(
        process_registry,
        "load_record",
        lambda provider, session_id: SimpleNamespace(pid=999_999, cwd="/tmp/x", ended_at_epoch=None),
    )
    monkeypatch.setattr(process_registry, "pid_exists", lambda pid: False)
    controller = cleared
    controller._core_extras.clear()
    controller._core_publish_state()
    with controller._core_lock:
        rows = {row["id"]: row for row in controller._core_documents["state"]["sessions"]}
    done = rows["devin:session:troubled"]
    assert done["lifecycle"] == "ended" and done["mode"] == "ended_unconfirmed"
    assert done["stale"] is True and done["pid"] is None


def test_every_hid_probe_runs_on_the_same_thread(headless, monkeypatch: pytest.MonkeyPatch) -> None:
    """hidapi's IOHIDManager keeps the run loop of whichever thread first
    touched it. A fresh thread per probe leaves it holding a run loop that
    went with its thread, and the next enumeration -- or a device arriving
    during one -- dies on a pointer-authentication trap inside
    CoreFoundation. That is not an exception anything can catch: it takes
    the daemon down, and the supervisor restarts it into the same crash
    ten seconds later.
    """
    monkeypatch.setattr(threading, "Thread", REAL_THREAD)
    threads: list[int] = []

    def fake_probe() -> list:
        threads.append(threading.get_ident())
        return []

    monkeypatch.setattr(core_runtime, "deck_probe", fake_probe)
    controller = headless
    for _ in range(3):
        controller._core_deck_probe_now(wait=True)
    assert len(threads) == 3
    assert len(set(threads)) == 1, "each probe enumerated on a different thread"
    assert threads[0] != threading.get_ident()
