"""Light controls the legacy window used to own, over the socket: the
semantic cues by name, the INIT.LED burn behind a confirm, calibration
profile slots, and the Focus roster."""

from __future__ import annotations

from pathlib import Path
from types import SimpleNamespace

import pytest

from jrbar import _led_status_legacy, ambient_effect_runtime, core_runtime, device_writer, focus_sync
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
    from jrbar import ambient_effect_runtime as runtime
    from jrbar.ambient_effect_dispatch import AmbientEffectSurface
    from jrbar.core_lights import augment_lights_cues

    staged = {
        AmbientEffectSurface.SCREEN_BAR: SimpleNamespace(family=AmbientEffectFamily.HANDOFF_BATON),
        AmbientEffectSurface.SIDEPULSE_DOT: SimpleNamespace(family=AmbientEffectFamily.DOT_BINARY_HEARTBEAT),
    }
    monkeypatch.setattr(
        runtime,
        "active_ambient_surface_output",
        lambda controller, surface: (staged[surface], 0.0) if surface in staged else None,
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
        _led_status_legacy,
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
    monkeypatch.setattr(_led_status_legacy, "led_count_for_target", lambda target: 8)
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
    assert reply == {"available": False, "reason": "Operation not permitted", "focuses": [], "active": []}


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
