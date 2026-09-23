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


# --- the commands ---------------------------------------------------------------------


@pytest.fixture
def daemon(headless):  # noqa: F811
    controller = headless
    controller.applicationDidFinishLaunching_(None)
    return controller


def test_list_and_set_cues(daemon) -> None:
    rows = core_runtime._cmd_list_cues(daemon, {})["cues"]
    assert len(rows) == 11

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
