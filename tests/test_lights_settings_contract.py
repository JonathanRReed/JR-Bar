"""The light settings the Swift Settings window now writes by path.

Calendar and reminder glows, the idle charging fill, the power-change
preview, Rainstick's night consent, the milestone ladder, per-device
blend modes, saved calibration profiles, Focus -> profile rules and the
hand-written Studio program were reachable only from the retiring PyObjC
window. The native window writes each of them with ``set_setting``,
which rounds the whole document through the real loader. These tests pin
that every one of those paths survives the round trip -- and that the
loader's normalisation matches what the Swift fields promise.
"""

from __future__ import annotations

import copy
from pathlib import Path

from jrbar import core_runtime
from jrbar._settings_legacy import (
    CALIBRATION_PROFILE_SLOTS,
    DEFAULT_MILESTONE_ODOMETER_STEPS,
    MAX_MILESTONE_ODOMETER_STEP_COUNT,
    AgentMonitorSettings,
    DeviceDisplaySetting,
)


def _document_with_device() -> dict:
    settings = AgentMonitorSettings(
        devices=(DeviceDisplaySetting(device_id="sidepulse:pro:A", name="SidePulse", path="/Volumes/SidePulse"),)
    )
    return settings.to_dict()


def _round_trip(tmp_path: Path, path: str, value: object) -> dict:
    document = copy.deepcopy(_document_with_device())
    assert core_runtime.set_path(document, path, value), path
    settings = core_runtime.settings_from_document(document, scratch_dir=tmp_path)
    return settings.to_dict()


def test_every_swift_light_path_exists_in_the_daemon_document() -> None:
    document = _document_with_device()
    for path in (
        "calendar_alerts_enabled",
        "calendar_lead_minutes",
        "reminder_alerts_enabled",
        "battery_monitoring.charging_idle_enabled",
        "battery_monitoring.show_on_power_change",
        "rainstick_night_enabled",
        "milestone_odometer_steps",
        "devices.0.blend_mode",
        "calibration_profiles",
        "focus_profile_rules",
        "studio_program",
        "studio_library",
    ):
        _value, found = core_runtime.get_path(document, path)
        assert found, path


def test_glow_battery_and_rainstick_toggles_round_trip(tmp_path: Path) -> None:
    for path in (
        "calendar_alerts_enabled",
        "reminder_alerts_enabled",
        "rainstick_night_enabled",
    ):
        assert core_runtime.get_path(_round_trip(tmp_path, path, True), path)[0] is True, path
    for path in (
        "battery_monitoring.charging_idle_enabled",
        "battery_monitoring.show_on_power_change",
    ):
        assert core_runtime.get_path(_round_trip(tmp_path, path, False), path)[0] is False, path


def test_calendar_lead_is_clamped_to_the_sliders_range(tmp_path: Path) -> None:
    # The Swift slider offers 1...60 minutes, the loader's own clamp.
    assert _round_trip(tmp_path, "calendar_lead_minutes", 12)["calendar_lead_minutes"] == 12.0
    assert _round_trip(tmp_path, "calendar_lead_minutes", 500)["calendar_lead_minutes"] == 60.0
    assert _round_trip(tmp_path, "calendar_lead_minutes", 0)["calendar_lead_minutes"] == 1.0


def test_milestone_ladder_normalises_the_way_the_swift_field_shows(tmp_path: Path) -> None:
    kept = _round_trip(tmp_path, "milestone_odometer_steps", [50, 5, 5, -3, 20])
    assert kept["milestone_odometer_steps"] == [5, 20, 50]
    # Nothing valid left: the default ladder, which the field also shows.
    empty = _round_trip(tmp_path, "milestone_odometer_steps", [0, -1])
    assert tuple(empty["milestone_odometer_steps"]) == DEFAULT_MILESTONE_ODOMETER_STEPS
    many = _round_trip(tmp_path, "milestone_odometer_steps", list(range(1, 40)))
    assert len(many["milestone_odometer_steps"]) == MAX_MILESTONE_ODOMETER_STEP_COUNT == 16


def test_device_blend_mode_is_per_device_and_nullable(tmp_path: Path) -> None:
    own = _round_trip(tmp_path, "devices.0.blend_mode", "round_robin")
    assert own["devices"][0]["blend_mode"] == "round_robin"
    follows = _round_trip(tmp_path, "devices.0.blend_mode", None)
    assert follows["devices"][0]["blend_mode"] is None


def test_calibration_profile_slots_and_focus_rules_round_trip(tmp_path: Path) -> None:
    snapshot = {"sidepulse:pro:A": {"brightness": 128, "red_gain": 0.9, "green_gain": 1.0,
                                    "blue_gain": 1.1, "resting_glow": 0.02}}
    saved = _round_trip(tmp_path, "calibration_profiles.Night", snapshot)
    assert saved["calibration_profiles"]["Night"] == snapshot
    # A null slot is a deletion: the loader keeps only object entries.
    document = copy.deepcopy(_document_with_device())
    document["calibration_profiles"] = {"Night": snapshot, "Day": snapshot}
    assert core_runtime.set_path(document, "calibration_profiles.Day", None)
    cleared = core_runtime.settings_from_document(document, scratch_dir=tmp_path).to_dict()
    assert set(cleared["calibration_profiles"]) == {"Night"}

    assert set(CALIBRATION_PROFILE_SLOTS) == {"Day", "Night", "Travel"}
    # A dotted focus id is split by the path grammar into nested objects,
    # which the loader drops -- so the Swift rows write the rules object
    # whole, never `focus_profile_rules.<id>`.
    rule = _round_trip(tmp_path, "focus_profile_rules.com.apple.focus.work", "Night")
    assert rule["focus_profile_rules"] == {}
    whole = _round_trip(tmp_path, "focus_profile_rules",
                        {"com.apple.focus.work": "Night", "com.apple.sleep.sleep-mode": "Bogus"})
    assert whole["focus_profile_rules"] == {"com.apple.focus.work": "Night"}


def test_studio_program_is_kept_verbatim(tmp_path: Path) -> None:
    program = "# a note\n#FF00FF 1s pulse\nrepeat"
    assert _round_trip(tmp_path, "studio_program", program)["studio_program"] == program


def test_studio_shelf_keeps_named_pairs_only(tmp_path: Path) -> None:
    # The LEDS Studio writes the shelf whole, as [[name, program]] pairs.
    shelf = [["Glow", "#FF7A00"], ["  ", "#000000"], ["Wave", "roll 2s"], "junk"]
    kept = _round_trip(tmp_path, "studio_library", shelf)["studio_library"]
    assert kept == [["Glow", "#FF7A00"], ["Wave", "roll 2s"]]


def test_focus_dim_rules_survive_only_as_a_whole_object(tmp_path: Path) -> None:
    """The same path trap as the profile rules: a per-focus dotted write
    nests and is dropped, the whole-object write the rows send is kept."""
    dotted = _round_trip(tmp_path, "focus_dim_rules.com.apple.focus.work", 0.3)
    assert dotted["focus_dim_rules"] == {}
    whole = _round_trip(tmp_path, "focus_dim_rules", {"com.apple.focus.work": 0.3})
    assert whole["focus_dim_rules"] == {"com.apple.focus.work": 0.3}


def test_ambient_marks_land_only_as_one_object(tmp_path: Path) -> None:
    # Settings > Auto-dim writes the three ambient marks as one
    # ``auto_dim.ambient`` object ("Use current light", "Use it"): the
    # loader resets a floor/ceiling pair whose ceiling is not above its
    # floor, which two separate writes can pass through on the way.
    moved = {"min_fraction": 0.25, "lux_floor": 600.0, "lux_ceiling": 1500.0}
    ambient = _round_trip(tmp_path, "auto_dim.ambient", dict(moved))["auto_dim"]["ambient"]
    assert ambient == moved
    # The same move as two writes: the floor alone lands above the old
    # ceiling (400), and the loader throws both marks back to defaults.
    halfway = _round_trip(tmp_path, "auto_dim.ambient.lux_floor", 600.0)["auto_dim"]["ambient"]
    assert (halfway["lux_floor"], halfway["lux_ceiling"]) != (600.0, 400.0)
    assert halfway["lux_floor"] < halfway["lux_ceiling"]
