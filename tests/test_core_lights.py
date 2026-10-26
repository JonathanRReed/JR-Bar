"""Light controls the legacy window used to own, over the socket: the
semantic cues by name, the INIT.LED burn behind a confirm, calibration
profile slots, and the Focus roster."""

from __future__ import annotations

from pathlib import Path
from types import SimpleNamespace

import pytest

from jrbar import ambient_effect_runtime, core_runtime, device_writer, focus_sync, led_status
from jrbar.ambient_cues import (
    AMBIENT_CUES,
    SWITCHABLE_CUE_IDS,
    cue_documents,
    disabled_cue_families,
    normalize_disabled_cues,
)
from jrbar.ambient_effect_dispatch import AmbientEffectFamily
from jrbar.core_server import CommandError
from jrbar.settings import AgentMonitorSettings
from tests.test_core_runtime import headless  # noqa: F401  (the headless daemon fixture)

# --- the cue catalogue -----------------------------------------------------------


def test_every_cue_has_a_name_a_meaning_and_a_real_family() -> None:
    assert len(AMBIENT_CUES) == 11
    for cue in AMBIENT_CUES:
        AmbientEffectFamily(cue.id)
        assert cue.name and cue.meaning.endswith(".")
    # The Dot's own display and the assigned effects are not cues.
    ids = {cue.id for cue in AMBIENT_CUES}
    assert "dot_binary_heartbeat" not in ids and "semantic_selection" not in ids
    assert "rainstick_idle" not in SWITCHABLE_CUE_IDS


def test_disabled_cues_normalize_to_known_switchable_ids() -> None:
    assert normalize_disabled_cues(["handoff_baton", "firefly_completion", "nope", "rainstick_idle", "handoff_baton"]) == (
        "firefly_completion",
        "handoff_baton",
    )
    assert normalize_disabled_cues("firefly_completion") == ()
    assert normalize_disabled_cues(None) == ()
    settings = AgentMonitorSettings(ambient_cues_disabled=("turn_length_ember",))
    assert disabled_cue_families(settings) == frozenset({AmbientEffectFamily.TURN_LENGTH_EMBER})
    rows = cue_documents(settings)
    assert [row["priority"] for row in rows] == sorted((row["priority"] for row in rows), reverse=True)
    by_id = {row["id"]: row for row in rows}
    assert by_id["turn_length_ember"]["enabled"] is False
    assert by_id["firefly_completion"]["enabled"] is True
    assert by_id["rainstick_idle"]["enabled"] is False
    assert by_id["rainstick_idle"]["setting"] == "rainstick_idle_enabled"


def test_a_switched_off_cue_never_reaches_the_dispatch(monkeypatch: pytest.MonkeyPatch) -> None:
    seen: dict[str, object] = {}
    sentinel = object()

    def compile_stub(**kwargs):
        seen.update(kwargs)
        return ambient_effect_runtime.AmbientEffectDispatch((), ())

    monkeypatch.setattr(ambient_effect_runtime, "compile_ambient_effect_dispatch", compile_stub)
    monkeypatch.setattr(ambient_effect_runtime, "_typed_plan", lambda value, expected: sentinel)
    monkeypatch.setattr(ambient_effect_runtime, "_decision_plan", lambda value, expected: sentinel)
    monkeypatch.setattr(ambient_effect_runtime, "_first_screen_meniscus", lambda controller: sentinel)
    monkeypatch.setattr(ambient_effect_runtime, "_latest_fleet_cue", lambda controller: sentinel)
    monkeypatch.setattr(ambient_effect_runtime, "_ambient_colors", lambda controller: None)
    controller = SimpleNamespace(
        settings=AgentMonitorSettings(ambient_cues_disabled=("firefly_completion", "handoff_baton"))
    )
    ambient_effect_runtime._compile_runtime_dispatch(controller)
    assert seen["firefly_completion"] is None
    assert seen["handoff_baton"] is None
    for kept in (
        "glance_light",
        "completion_meniscus",
        "recovery_grace",
        "ask_heartbeat",
        "turn_length_ember",
        "fleet_arrival_departure",
        "courtesy_signature",
        "rainstick_idle",
        "milestone_odometer",
        "dot_binary_heartbeat",
    ):
        assert seen[kept] is sentinel, kept


def test_the_lights_document_names_the_cue_on_each_surface(monkeypatch: pytest.MonkeyPatch) -> None:
    from jrbar import ambient_effect_consumer as consumer
    from jrbar.ambient_effect_dispatch import AmbientEffectSurface
    from jrbar.core_lights import augment_lights_cues

    staged = {
        AmbientEffectSurface.SCREEN_BAR: SimpleNamespace(family=AmbientEffectFamily.HANDOFF_BATON),
        AmbientEffectSurface.SIDEPULSE_DOT: SimpleNamespace(family=AmbientEffectFamily.DOT_BINARY_HEARTBEAT),
    }
    monkeypatch.setattr(
        consumer,
        "active_ambient_presentation",
        lambda controller, surface, **kwargs: SimpleNamespace(output=staged[surface]) if surface in staged else None,
    )
    document = {"surfaces": {"screen_bar": {"program": "x"}, "hardware": {"program": "y"}, "dot": {"program": "z"}}}
    augment_lights_cues(SimpleNamespace(), document)
    assert document["surfaces"]["screen_bar"]["cue"] == {"id": "handoff_baton", "name": "Handoff baton"}
    # The Dot's own heartbeat is a display, not a cue; nothing is staged on the strip.
    assert "cue" not in document["surfaces"]["dot"]
    assert "cue" not in document["surfaces"]["hardware"]


# --- the commands ---------------------------------------------------------------------


@pytest.fixture
def daemon(headless):  # noqa: F811
    controller = headless
    controller.applicationDidFinishLaunching_(None)
    return controller


def test_list_and_set_cues(daemon) -> None:
    rows = core_runtime._cmd_list_cues(daemon, {})["cues"]
    assert len(rows) == 11
    odometer = next(row for row in rows if row["id"] == "milestone_odometer")
    assert (odometer["count"], odometer["next_step"]) == (0, 10)
    from jrbar.milestone_odometer import MilestoneOdometerState

    daemon._milestone_odometer_state = MilestoneOdometerState(completed_count=37)
    odometer = next(
        row for row in core_runtime._cmd_list_cues(daemon, {})["cues"] if row["id"] == "milestone_odometer"
    )
    assert (odometer["count"], odometer["next_step"]) == (37, 50)

    reply = core_runtime._cmd_set_cue(daemon, {"id": "firefly_completion", "enabled": False})
    assert daemon.settings.ambient_cues_disabled == ("firefly_completion",)
    assert {row["id"]: row["enabled"] for row in reply["cues"]}["firefly_completion"] is False
    core_runtime._cmd_set_cue(daemon, {"id": "firefly_completion", "enabled": True})
    assert daemon.settings.ambient_cues_disabled == ()

    # The older opt-in cues keep their own flags.
    core_runtime._cmd_set_cue(daemon, {"id": "rainstick_idle", "enabled": True})
    assert daemon.settings.rainstick_idle_enabled is True
    assert daemon.settings.to_dict()["ambient_cues_disabled"] == []

    for bad in ({"id": "strobe", "enabled": True}, {"id": "handoff_baton", "enabled": "no"}):
        with pytest.raises(CommandError) as error:
            core_runtime._cmd_set_cue(daemon, bad)
        assert error.value.code == "invalid_args"


def _devices(tmp_path: Path):
    pro_root = tmp_path / "SidePulse"
    dot_root = tmp_path / "PulseDot"
    for root in (pro_root, dot_root):
        root.mkdir()
    return [
        SimpleNamespace(device_id="pro", name="SidePulse", connected=True, root=pro_root, target=pro_root / "LEDS.LED"),
        SimpleNamespace(device_id="dot", name="PulseDot", connected=True, root=dot_root, target=dot_root / "LEDS.LED"),
        SimpleNamespace(device_id="gone", name="Old", connected=False, root=tmp_path, target=tmp_path / "LEDS.LED"),
        SimpleNamespace(device_id="virtual:status-bar", name="Screen Bar", connected=True, root=None, target=None),
    ]


def test_burn_init_plans_per_device_and_writes_only_when_confirmed(
    daemon, tmp_path: Path, monkeypatch: pytest.MonkeyPatch
) -> None:
    devices = _devices(tmp_path)
    daemon.status_bar_devices = lambda remember=True: devices
    monkeypatch.setattr(
        led_status,
        "led_count_for_target",
        lambda target: 2 if "PulseDot" in str(target) else 8,
    )
    writes: list[tuple[str, object, str]] = []

    def writer(program, *, device_path=None, file_name=None):
        writes.append((program, device_path, file_name))
        return Path(device_path) / file_name

    monkeypatch.setattr(device_writer, "write_led_program", writer)
    program = "#FF9F0A 800ms cosine\noff 800ms cosine\nrepeat"

    plan = core_runtime._cmd_burn_init(daemon, {"program": program})
    assert plan["confirmed"] is False and plan["written"] is False
    assert [row["device"] for row in plan["devices"]] == ["pro", "dot"]
    assert [row["led_count"] for row in plan["devices"]] == [8, 2]
    assert all(row["error"] is None and row["firmware_checked"] for row in plan["devices"])
    assert plan["devices"][0]["bytes"] == len(program.encode())
    assert writes == []

    burned = core_runtime._cmd_burn_init(daemon, {"program": program, "device": "dot", "confirm": True})
    assert burned["written"] is True
    assert [row["device"] for row in burned["devices"]] == ["dot"]
    assert writes == [(program, devices[1].root, "INIT.LED")]


def test_burn_init_reports_a_bad_program_and_refuses_what_it_cannot_do(
    daemon, tmp_path: Path, monkeypatch: pytest.MonkeyPatch
) -> None:
    devices = _devices(tmp_path)
    daemon.status_bar_devices = lambda remember=True: devices
    monkeypatch.setattr(led_status, "led_count_for_target", lambda target: 8)
    monkeypatch.setattr(
        device_writer,
        "write_led_program",
        lambda *args, **kwargs: pytest.fail("a bad program must never be written"),
    )
    reply = core_runtime._cmd_burn_init(daemon, {"program": "#GG0000 500ms", "confirm": True})
    assert reply["written"] is False
    assert all(row["error"] == "invalid_program" and row["problems"] for row in reply["devices"])

    for args, code in (
        ({"program": ""}, "invalid_args"),
        ({"program": "#FF0000", "confirm": "yes"}, "invalid_args"),
        ({"program": "x" * 5000}, "invalid_args"),
        ({"program": "#FF0000", "device": "gone"}, "not_found"),
    ):
        with pytest.raises(CommandError) as error:
            core_runtime._cmd_burn_init(daemon, args)
        assert error.value.code == code


def test_calibration_profiles_save_apply_and_delete(daemon) -> None:
    daemon.settings = daemon.settings.with_device_channel_gain("pro", "red", 0.8).with_device_resting_glow("pro", 0.1)
    saved = core_runtime._cmd_calibration_profile(daemon, {"action": "save", "slot": "Night"})
    assert saved["slots"] == ["Night"]
    assert daemon.settings.calibration_profiles["Night"]["pro"]["red_gain"] == 0.8

    daemon.settings = daemon.settings.with_device_channel_gain("pro", "red", 1.2).with_device_resting_glow("pro", 0.0)
    applied = core_runtime._cmd_calibration_profile(daemon, {"action": "apply", "slot": "Night"})
    assert applied["matched"] == 1
    device = next(device for device in daemon.settings.devices if device.device_id == "pro")
    assert device.red_gain == 0.8 and device.resting_glow == 0.1

    with pytest.raises(CommandError) as missing:
        core_runtime._cmd_calibration_profile(daemon, {"action": "apply", "slot": "Day"})
    assert missing.value.code == "not_found"
    for bad in ({"action": "save", "slot": "Evening"}, {"action": "rename", "slot": "Day"}):
        with pytest.raises(CommandError) as error:
            core_runtime._cmd_calibration_profile(daemon, bad)
        assert error.value.code == "invalid_args"

    removed = core_runtime._cmd_calibration_profile(daemon, {"action": "delete", "slot": "Night"})
    assert removed["removed"] is True and removed["slots"] == []
    assert core_runtime._cmd_calibration_profile(daemon, {"action": "delete", "slot": "Night"})["removed"] is False


@pytest.mark.parametrize(
    ("path", "value", "attribute", "expected"),
    [
        ("calendar_alerts_enabled", True, "calendar_alerts_enabled", True),
        ("calendar_lead_minutes", 90, "calendar_lead_minutes", 60.0),
        ("reminder_alerts_enabled", True, "reminder_alerts_enabled", True),
        ("battery_monitoring.charging_idle_enabled", False, "battery_charging_idle_enabled", False),
        ("battery_monitoring.show_on_power_change", False, "battery_show_on_power_change", False),
        ("rainstick_night_enabled", True, "rainstick_night_enabled", True),
        ("milestone_odometer_steps", [50, 5, 5], "milestone_odometer_steps", (5, 50)),
        ("ambient_cues_disabled", ["handoff_baton", "bogus"], "ambient_cues_disabled", ("handoff_baton",)),
        ("focus_profile_rules", {"com.apple.focus.work": "Day", "x": "Evening"}, "focus_profile_rules", {"com.apple.focus.work": "Day"}),
        ("call_quiet_mode", "asks_only", "call_quiet_mode", "asks_only"),
        ("meeting_quiet_mode", "loud", "meeting_quiet_mode", "off"),
    ],
)
def test_the_legacy_window_keys_write_through_set_setting(daemon, path, value, attribute, expected) -> None:
    core_runtime._cmd_set_setting(daemon, {"path": path, "value": value})
    assert getattr(daemon.settings, attribute) == expected


def test_a_device_blend_mode_writes_through_set_setting(daemon) -> None:
    daemon.settings = daemon.settings.with_device_channel_gain("pro", "red", 1.0)
    index = next(i for i, device in enumerate(daemon.settings.devices) if device.device_id == "pro")
    core_runtime._cmd_set_setting(daemon, {"path": f"devices.{index}.blend_mode", "value": "round_robin"})
    assert daemon.settings.device_blend_mode("pro") == "round_robin"
    core_runtime._cmd_set_setting(daemon, {"path": f"devices.{index}.blend_mode", "value": "everyone"})
    assert daemon.settings.device_blend_mode("pro") is None


def test_global_mix_and_legacy_alias_write_the_same_setting(daemon):
    for path, mode in (("colors.mix_mode", "weave"), ("colors.blend_mode", "tide")):
        reply = daemon._core_dispatch("set_setting", {"path": path, "value": mode})
        assert reply["value"] == mode
        saved = daemon.settings.to_dict()["colors"]
        assert saved["blend_mode"] == mode
        assert "mix_mode" not in saved
        published = daemon._core_documents["settings"]["document"]["colors"]
        assert published["blend_mode"] == published["mix_mode"] == mode


def test_what_plays_uses_the_live_mix_and_each_device_override(daemon, tmp_path, monkeypatch):
    from dataclasses import replace

    from jrbar.colors import BLEND_MODE_CHOICES
    from jrbar.settings import DeviceDisplaySetting
    from tests.test_light_mix import statuses

    daemon.current_attention_projection = None
    daemon.last_snapshot = SimpleNamespace(statuses=statuses(2))
    daemon.settings = replace(daemon.settings,
        colors=daemon.settings.colors.with_blend_mode("weave"),
        devices=(DeviceDisplaySetting(device_id="dot", name="Test", path=str(tmp_path / "PulseDot"),
                                      blend_mode="relay"),))
    monkeypatch.setattr(daemon, "status_bar_devices", lambda **_: _devices(tmp_path))
    # The inventory function must not create the fixture paths twice.
    inventory = daemon.status_bar_devices()
    monkeypatch.setattr(daemon, "status_bar_devices", lambda **_: inventory)
    reply = daemon._core_dispatch("what_plays", {})
    assert {row["id"] for row in reply["mixes"]} == set(BLEND_MODE_CHOICES)
    rows = {row["device"]: row for row in reply["devices"]}
    assert rows["pro"]["played"] == "weave"
    assert rows["dot"]["requested_mix"] == "relay"
    assert rows["dot"]["played"] == "alternate"
    assert rows["dot"]["warnings"]
    with pytest.raises(CommandError, match="unknown device"):
        daemon._core_dispatch("what_plays", {"device": "missing"})


def test_hardware_layers_celebration_on_the_live_program_and_restores_it(daemon, tmp_path, monkeypatch):
    from jrbar import status_bar_legacy as legacy
    from jrbar.ambient_effect_dispatch import compile_ambient_effect_dispatch
    from jrbar.semantic_effect_router import SemanticEffectCandidate, SemanticEventKind, route_semantic_effects
    from tests.test_light_mix import statuses

    clock = [10.0]
    monkeypatch.setattr(ambient_effect_runtime.time, "monotonic", lambda: clock[0])
    daemon.current_attention_projection = None
    daemon.settings = daemon.settings.with_colors(daemon.settings.colors.with_agent_animation("codex", "kitt"))
    daemon._frozen_hardware_render_colors = daemon.settings.colors
    daemon._ambient_effect_dispatch = compile_ambient_effect_dispatch(semantic_selection=route_semantic_effects((
        SemanticEffectCandidate("synthetic:completion", SemanticEventKind.COMPLETION),)))
    daemon._ambient_effect_dispatch_started_at = 10.0
    device = legacy.StatusBarDevice(device_id="pro", name="Test", root=tmp_path,
        target=tmp_path / "LEDS.LED", connected=True, display=legacy.LED_DISPLAY_AGENT)
    controller = led_status.AgentLedController(device_path=tmp_path)
    monkeypatch.setattr(daemon, "agent_controller_for_device", lambda _: controller)
    monkeypatch.setattr(daemon, "reset_led_controllers_for_device", lambda _: None)
    request = legacy.HardwareWriteRequest(device=device, mode=legacy.AgentMode.WORKING,
        battery_snapshot=None, statuses=statuses(1), projection=None, relay_elapsed_seconds=0,
        display_kind=legacy.LED_DISPLAY_AGENT, write_priority=legacy.RuntimeWorkPriority.COALESCIBLE,
        coalesce_identity="test")
    first = daemon._sync_hardware_device(request)
    assert first.write.changed and first.agent_display_rendered
    assert 10.0 < controller.ambient_layer_until <= 12.0
    daemon.agent_led_controllers_by_device["pro"] = controller
    daemon._core_hardware_anchor["pro"] = 100.0
    monkeypatch.setattr(daemon, "status_bar_devices", lambda **_: [device])
    lights = daemon._core_build_lights()["surfaces"]
    assert lights["screen_bar"]["anchor"] == lights["hardware"]["anchor"] == 100.0
    def body(program):
        return [line for line in program.splitlines() if not line.startswith("brightness ")]
    assert body(lights["screen_bar"]["program"]) == body(lights["hardware"]["program"])
    clock[0] = 13.0
    restored = daemon._sync_hardware_device(request)
    assert restored.write.changed and restored.agent_display_rendered
    assert controller.ambient_layer_until is None
    assert restored.write.nominal_program != first.write.nominal_program
    from jrbar.colors import program_for_snapshot

    assert restored.write.nominal_program == program_for_snapshot(statuses(1), colors=daemon.settings.colors)[1]


def test_an_unlinked_screen_bar_layer_repaints_at_its_deadline(daemon):
    daemon._ambient_screen_bar_layer_until = 12.0
    assert daemon._core_repaint_finished_cues(11.9) is False
    assert daemon._core_repaint_finished_cues(12.0) is True
    assert daemon._ambient_screen_bar_layer_until is None


def test_resolve_effect_walks_the_scope_ladder_before_it_happens(
    daemon, monkeypatch: pytest.MonkeyPatch, tmp_path: Path
) -> None:
    from jrbar import core_effects, effect_assignment_store
    from jrbar.effect_assignment_store import EffectAssignmentCache
    from jrbar.effect_registry import EFFECT_REGISTRY

    monkeypatch.setattr(effect_assignment_store, "default_effect_assignment_path", lambda home=None: tmp_path / "assignments.json")
    monkeypatch.setattr(core_effects, "default_state_dir", lambda *_: tmp_path)
    monkeypatch.setattr(type(daemon), "_effect_assignment_cache", EffectAssignmentCache(registry=EFFECT_REGISTRY), raising=False)
    daemon._core_dispatch("set_assignment", {"effect_id": "aurora", "scope": "provider", "target_id": "codex"})
    daemon._core_dispatch("set_assignment", {"effect_id": "pulse", "scope": "scene", "target_id": "night"})

    reply = core_runtime._cmd_resolve_effect(daemon, {"semantic": "work", "scene": "night", "provider": "codex"})
    assert reply["winner"] == {"scope": "provider", "target_id": "codex", "effect_id": "aurora"}
    ladder = {row["scope"]: row for row in reply["ladder"]}
    assert reply["ladder"][0]["scope"] == "device"
    assert ladder["device"]["applicable"] is False
    assert ladder["provider"]["wins"] is True
    # The scene rung has an assignment too; the ladder shows it lost.
    assert ladder["scene"]["effect_id"] == "pulse" and ladder["scene"]["wins"] is False

    claude = core_runtime._cmd_resolve_effect(daemon, {"semantic": "work", "scene": "night", "provider": "claude"})
    assert claude["winner"]["scope"] == "scene"

    # An ask keeps its reserved alert: only the meaning rung is consulted.
    ask = core_runtime._cmd_resolve_effect(daemon, {"semantic": "ask", "provider": "codex"})
    assert ask["urgent"] is True and [row["scope"] for row in ask["ladder"]] == ["semantic"]

    for bad in ({"semantic": "vibes"}, {"semantic": "work", "scene": "disco"}, {"semantic": "work", "provider": ""}):
        with pytest.raises(CommandError) as error:
            core_runtime._cmd_resolve_effect(daemon, bad)
        assert error.value.code == "invalid_args"


def test_the_light_log_lists_what_the_lights_tried_to_show(daemon) -> None:
    from jrbar.effect_history import (
        EffectEvent,
        EffectHistory,
        EffectOutcome,
        EffectSemanticCategory,
        EffectSuppressionReason,
        EffectSurface,
    )

    daemon._effect_history = EffectHistory(
        (
            EffectEvent("ev-1", 100.0, "ask-pulse", EffectSemanticCategory.ATTENTION, EffectSurface.SCREEN_BAR, EffectOutcome.SHOWN),
            EffectEvent(
                "ev-2",
                200.0,
                "done-sweep",
                EffectSemanticCategory.COMPLETION,
                EffectSurface.DOT,
                EffectOutcome.SUPPRESSED,
                suppression_reason=EffectSuppressionReason.DO_NOT_DISTURB,
            ),
        ),
        last_seen_epoch=150.0,
    )
    reply = core_runtime._cmd_list_light_log(daemon, {"limit": 5})
    assert reply["total"] == 2 and reply["last_seen"] == 150.0
    newest, oldest = reply["rows"]
    assert (newest["effect"], newest["outcome"], newest["surface"], newest["unseen"]) == (
        "done-sweep",
        "suppressed",
        "dot",
        True,
    )
    assert newest["explanation"].startswith("Suppressed on")
    assert oldest["category"] == "attention" and oldest["unseen"] is False
    assert len(core_runtime._cmd_list_light_log(daemon, {"limit": 1})["rows"]) == 1
    with pytest.raises(CommandError):
        core_runtime._cmd_list_light_log(daemon, {"limit": 0})


def test_list_focuses_names_the_configured_focuses_or_says_why_not(
    daemon, monkeypatch: pytest.MonkeyPatch
) -> None:
    monkeypatch.setattr(
        focus_sync,
        "configured_focus_modes",
        lambda: [("com.apple.focus.work", "Work"), ("com.apple.focus.custom.writing", "Writing")],
    )
    monkeypatch.setattr(focus_sync, "active_focus_mode_identifiers", lambda: ["com.apple.focus.work"])
    reply = core_runtime._cmd_list_focuses(daemon, {})
    assert reply["available"] is True
    assert reply["focuses"][1] == {"id": "com.apple.focus.custom.writing", "name": "Writing"}
    assert reply["active"] == ["com.apple.focus.work"]

    def locked():
        raise focus_sync.FocusSyncUnavailableError("Operation not permitted")

    monkeypatch.setattr(focus_sync, "configured_focus_modes", locked)
    reply = core_runtime._cmd_list_focuses(daemon, {})
    assert reply == {
        "available": False,
        "reason": "Operation not permitted",
        "focuses": [],
        "active": [],
        "active_available": False,
        "active_reason": "Active Focus mode names unavailable",
    }


def test_a_blend_mode_previews_against_a_mixed_fleet() -> None:
    from jrbar import colors as colors_module
    from jrbar.animation import firmware_parse_error

    settings = AgentMonitorSettings()
    daemon = SimpleNamespace(settings=settings)
    reply = core_runtime._cmd_preview_fleet(daemon, {})
    assert reply["scenario"] == "fleet"
    assert reply["label"] == "Three Agents: Two Working, One Done"
    assert reply["blend_mode"] == settings.colors.blend_mode
    assert reply["agents"] == [
        {"provider": "claude", "mode": "working"},
        {"provider": "codex", "mode": "working"},
        {"provider": "gemini", "mode": "completed"},
    ]
    assert firmware_parse_error(reply["program"], 8) is None

    # Every blend mode renders its own playable strip for the same desk.
    programs = {}
    for blend in colors_module.BLEND_MODE_CHOICES:
        played = core_runtime._cmd_preview_fleet(daemon, {"blend_mode": blend})
        assert played["blend_mode"] == blend
        assert firmware_parse_error(played["program"], 8) is None
        programs[blend] = played["program"]
    assert len(set(programs.values())) == len(colors_module.BLEND_MODE_CHOICES)
    # An ask takes the strip whatever the blend: that is the preview's answer.
    asking = {
        core_runtime._cmd_preview_fleet(daemon, {"scenario": "one_needs_you", "blend_mode": blend})["program"]
        for blend in colors_module.BLEND_MODE_CHOICES
    }
    assert len(asking) == 1

    # The asked speed is the speed the mode plays at, even over its override.
    overridden = settings.colors.with_speed_override(colors_module.BLEND_MODE_ROUND_ROBIN, 9.0)
    daemon.settings = settings.with_colors(overridden)
    fast = core_runtime._cmd_preview_fleet(
        daemon, {"blend_mode": colors_module.BLEND_MODE_ROUND_ROBIN, "cycle_speed_seconds": 2.0}
    )
    assert fast["cycle_speed_seconds"] == 2.0

    dot = core_runtime._cmd_preview_fleet(daemon, {"scenario": "busy_team", "led_count": 2})
    assert dot["led_count"] == 2 and firmware_parse_error(dot["program"], 2) is None


def test_a_fleet_preview_follows_a_devices_own_blend_and_refuses_nonsense() -> None:
    from jrbar import colors as colors_module

    daemon = SimpleNamespace(
        settings=SimpleNamespace(
            colors=colors_module.ColorSettings.defaults(),
            device_blend_mode=lambda device: colors_module.BLEND_MODE_ROUND_ROBIN if device == "pro" else None,
        )
    )
    assert core_runtime._cmd_preview_fleet(daemon, {"device": "pro"})["blend_mode"] == "round_robin"
    assert (
        core_runtime._cmd_preview_fleet(daemon, {"device": "dot"})["blend_mode"]
        == colors_module.ColorSettings.defaults().blend_mode
    )
    for bad in (
        {"scenario": "live"},
        {"scenario": "everything"},
        {"blend_mode": "plaid"},
        {"led_count": 5},
        {"led_count": True},
        {"cycle_speed_seconds": "fast"},
        {"device": ""},
    ):
        with pytest.raises(CommandError):
            core_runtime._cmd_preview_fleet(daemon, bad)
    assert "preview_fleet" in core_runtime.command_names()


def test_the_fleet_desk_stays_out_of_the_legacy_picker_but_renders_on_every_device() -> None:
    from jrbar import colors as colors_module

    assert colors_module.PREVIEW_SCENARIO_FLEET not in colors_module.PREVIEW_SCENARIO_CHOICES
    statuses = colors_module.preview_statuses_for_scenario(colors_module.PREVIEW_SCENARIO_FLEET)
    for led_count in (2, 8):
        for blend in colors_module.BLEND_MODE_CHOICES:
            palette = colors_module.ColorSettings.defaults().with_blend_mode(blend)
            _state, program = colors_module.program_for_snapshot(statuses, led_count=led_count, colors=palette)
            assert len(program.encode()) <= 512


@pytest.mark.parametrize("active_document", [
    {"storeAssertionRecords": [{"unrecognizedModeIdentifier": "synthetic.work"}]},
    {"storeAssertionRecords": [
        {"assertionDetailsModeIdentifier": "synthetic.work"},
        {"unrecognizedModeIdentifier": "synthetic.sleep"},
    ]},
    {"storeAssertionRecords": [{"assertionDetailsModeIdentifier": "x" * 257}]},
    {"storeAssertionRecords": [{"assertionDetailsModeIdentifier": "é" * 129}]},
    {"storeAssertionRecords": [{"assertionDetailsModeIdentifier": "\ud800"}]},
    {"storeAssertionRecords": [
        {"assertionDetailsModeIdentifier": f"synthetic.mode.{index:02d}"}
        for index in range(65)
    ]},
    {"storeAssertionRecords": None},
])
def test_list_focuses_keeps_roster_when_active_reading_is_unavailable(
    tmp_path: Path, monkeypatch: pytest.MonkeyPatch, active_document: object,
) -> None:
    import json

    assertions = tmp_path / "Assertions.json"
    configurations = tmp_path / "ModeConfigurations.json"
    assertions.write_text(json.dumps(active_document))
    configurations.write_text(json.dumps({"modeIdentifier": "synthetic.work", "name": "Work"}))
    monkeypatch.setattr(focus_sync, "ASSERTIONS_PATH", assertions)
    monkeypatch.setattr(focus_sync, "MODE_CONFIGURATIONS_PATH", configurations)
    reply = core_runtime._cmd_list_focuses(SimpleNamespace(), {})
    assert reply["available"] is True
    assert reply["reason"] is None
    assert reply["focuses"] == [{"id": "synthetic.work", "name": "Work"}]
    assert reply["active"] == []
    assert reply["active_available"] is False
    assert isinstance(reply["active_reason"], str) and 0 < len(reply["active_reason"]) <= 200
    assert str(tmp_path) not in reply["active_reason"]
    assert "synthetic" not in reply["active_reason"]


@pytest.mark.parametrize("records, expected", [
    ([], []),
    ([{"assertionDetailsModeIdentifier": "synthetic.work"}], ["synthetic.work"]),
])
def test_list_focuses_reports_successful_active_reading(
    tmp_path: Path, monkeypatch: pytest.MonkeyPatch, records: list, expected: list,
) -> None:
    import json

    assertions = tmp_path / "Assertions.json"
    configurations = tmp_path / "ModeConfigurations.json"
    assertions.write_text(json.dumps({"storeAssertionRecords": records}))
    configurations.write_text(json.dumps({"modeIdentifier": "synthetic.work", "name": "Work"}))
    monkeypatch.setattr(focus_sync, "ASSERTIONS_PATH", assertions)
    monkeypatch.setattr(focus_sync, "MODE_CONFIGURATIONS_PATH", configurations)
    reply = core_runtime._cmd_list_focuses(SimpleNamespace(), {})
    assert reply["available"] is True
    assert reply["active"] == expected
    assert reply["active_available"] is True
    assert reply["active_reason"] is None


def test_list_focuses_configuration_failure_marks_both_readings_unavailable(
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    def unavailable():
        raise focus_sync.FocusSyncUnavailableError("Operation not permitted")

    monkeypatch.setattr(focus_sync, "configured_focus_modes", unavailable)
    reply = core_runtime._cmd_list_focuses(SimpleNamespace(), {})
    assert reply["available"] is False
    assert reply["reason"] == "Operation not permitted"
    assert reply["focuses"] == [] and reply["active"] == []
    assert reply["active_available"] is False
    assert isinstance(reply["active_reason"], str) and 0 < len(reply["active_reason"]) <= 200


def test_list_focuses_invalid_unicode_configuration_marks_both_readings_unavailable(
    tmp_path: Path, monkeypatch: pytest.MonkeyPatch,
) -> None:
    assertions = tmp_path / "Assertions.json"
    configurations = tmp_path / "ModeConfigurations.json"
    assertions.write_text('{"storeAssertionRecords": []}')
    configurations.write_bytes(b"\xff\xfe")
    monkeypatch.setattr(focus_sync, "ASSERTIONS_PATH", assertions)
    monkeypatch.setattr(focus_sync, "MODE_CONFIGURATIONS_PATH", configurations)
    reply = core_runtime._cmd_list_focuses(SimpleNamespace(), {})
    assert reply["available"] is False
    assert isinstance(reply["reason"], str) and 0 < len(reply["reason"]) <= 200
    assert "decode" in reply["reason"]
    assert reply["focuses"] == [] and reply["active"] == []
    assert reply["active_available"] is False
    assert reply["active_reason"] == "Active Focus mode names unavailable"


def test_screen_bar_layer_applies_brightness_once_to_both_programs(daemon, monkeypatch):
    from dataclasses import replace
    from unittest.mock import MagicMock

    from jrbar import status_bar_legacy as legacy
    from jrbar.ambient_effect_dispatch import compile_ambient_effect_dispatch
    from jrbar.semantic_effect_router import SemanticEffectCandidate, SemanticEventKind, route_semantic_effects
    from tests.test_light_mix import statuses

    monkeypatch.setattr(legacy, "SCREEN_BAR_FEATURE_ENABLED", True)
    monkeypatch.setattr(ambient_effect_runtime.time, "monotonic", lambda: 10.5)
    daemon.settings = replace(daemon.settings, virtual_status_device_enabled=True,
        colors=daemon.settings.colors.with_agent_animation("codex", "kitt"))
    daemon._frozen_hardware_render_colors = daemon.settings.colors
    daemon.current_attention_projection = None
    daemon.virtual_status_device = MagicMock()
    device = SimpleNamespace(device_id=legacy.VIRTUAL_DEVICE_ID, resting_glow=0.0, channel_gains=(1, 1, 1))
    monkeypatch.setattr(daemon, "status_bar_devices", lambda remember=False: [device])
    monkeypatch.setattr(daemon, "active_led_display_kind_for_device", lambda *_: legacy.LED_DISPLAY_AGENT)
    monkeypatch.setattr(daemon, "effective_brightness_for_device", lambda _: 128)
    daemon._ambient_effect_dispatch = compile_ambient_effect_dispatch(semantic_selection=route_semantic_effects((
        SemanticEffectCandidate("synthetic:completion", SemanticEventKind.COMPLETION),)))
    daemon._ambient_effect_dispatch_started_at = 10.0
    daemon.sync_virtual_status_device(legacy.AgentMode.WORKING, None, statuses(1))
    call = daemon.virtual_status_device.set_program.call_args
    assert call is not None
    assert call.args[0].splitlines()[0] == "brightness 128"
    assert call.kwargs["static_fallback_program"].splitlines()[0] == "brightness 128"
