"""Auto-dim: the setting, the policy math with fake readers, and the way
it reaches the brightness plan, the settings document and ``lights``."""

from __future__ import annotations

import json
from pathlib import Path

import pytest

from jrbar import auto_dim
from jrbar.auto_dim import AutoDimResult, AutoDimSettings, evaluate_auto_dim, schedule_active
from jrbar.core_projection import LightFacts, build_lights_document, light_why, why_detail
from jrbar.settings import AgentMonitorSettings, load_settings, save_settings
from tests.test_core_runtime import headless  # noqa: F401  (the headless daemon fixture)


def _evaluate(settings: AutoDimSettings, *, now_minutes: int = 12 * 60, display=None, ambient=None) -> AutoDimResult:
    return evaluate_auto_dim(
        settings,
        now_minutes=now_minutes,
        display_reader=lambda: display() if callable(display) else display,
        ambient_reader=lambda: ambient() if callable(ambient) else ambient,
    )


def test_default_is_off_and_keeps_todays_factor() -> None:
    assert AutoDimSettings().mode == "off"
    result = _evaluate(AutoDimSettings(), display=0.1, ambient=0.0)
    assert result == auto_dim.OFF_RESULT
    assert result.factor == 1.0 and result.available is True


@pytest.mark.parametrize(
    "start,end,now,active",
    [
        (22 * 60, 7 * 60, 23 * 60, True),  # wraps midnight, evening
        (22 * 60, 7 * 60, 3 * 60, True),  # wraps midnight, small hours
        (22 * 60, 7 * 60, 12 * 60, False),
        (22 * 60, 7 * 60, 7 * 60, False),  # end is exclusive
        (22 * 60, 7 * 60, 22 * 60, True),  # start is inclusive
        (9 * 60, 17 * 60, 12 * 60, True),  # same-day window
        (9 * 60, 17 * 60, 20 * 60, False),
        (9 * 60, 9 * 60, 9 * 60, False),  # empty window never dims
    ],
)
def test_schedule_window_math(start: int, end: int, now: int, active: bool) -> None:
    assert schedule_active(start, end, now) is active


def test_schedule_mode_applies_the_fraction_inside_the_window_only() -> None:
    settings = AutoDimSettings(mode="schedule", schedule_start_minutes=22 * 60, schedule_end_minutes=7 * 60, schedule_fraction=0.3)
    inside = _evaluate(settings, now_minutes=23 * 60)
    outside = _evaluate(settings, now_minutes=12 * 60)
    assert (inside.source, inside.factor, inside.available) == ("schedule", 0.3, True)
    assert (outside.source, outside.factor) == ("schedule", 1.0)


def test_display_mode_follows_the_display_with_a_floor_and_reports_unavailable() -> None:
    settings = AutoDimSettings(mode="display", display_min_fraction=0.15)
    assert _evaluate(settings, display=0.6) == AutoDimResult("display", "display", 0.6, True, 0.6)
    assert _evaluate(settings, display=0.02).factor == 0.15
    unreadable = _evaluate(settings, display=None)
    assert (unreadable.source, unreadable.factor, unreadable.available, unreadable.reading) == ("display", 1.0, False, None)

    def boom():
        raise RuntimeError("no display")

    assert _evaluate(settings, display=boom).available is False


def test_ambient_mode_interpolates_lux_and_falls_back_to_the_display() -> None:
    settings = AutoDimSettings(
        mode="ambient", ambient_min_fraction=0.1, ambient_lux_floor=5.0, ambient_lux_ceiling=405.0, display_min_fraction=0.2
    )
    dark = _evaluate(settings, ambient=0.0)
    assert (dark.source, dark.factor, dark.available, dark.reading) == ("ambient", 0.1, True, 0.0)
    assert _evaluate(settings, ambient=1000.0).factor == 1.0
    middle = _evaluate(settings, ambient=205.0)
    assert middle.factor == pytest.approx(0.55)
    # No sensor: the display decides, and the document says the sensor was unavailable.
    fallback = _evaluate(settings, ambient=None, display=0.5)
    assert (fallback.mode, fallback.source, fallback.factor, fallback.available) == ("ambient", "display", 0.5, False)
    nothing = _evaluate(settings, ambient=None, display=None)
    assert (nothing.source, nothing.factor, nothing.available) == ("display", 1.0, False)


def test_settings_document_round_trips_and_normalises_bad_values(tmp_path: Path) -> None:
    document = AgentMonitorSettings().to_dict()
    assert document["auto_dim"] == {
        "mode": "off",
        "schedule": {"start_minutes": 1320, "end_minutes": 420, "fraction": 0.3},
        "display": {"min_fraction": 0.15},
        "ambient": {"min_fraction": 0.35, "lux_floor": 15.0, "lux_ceiling": 150.0},
    }
    document["auto_dim"] = {
        "mode": "ambient",
        "schedule": {"start_minutes": 25 * 60, "end_minutes": -3, "fraction": 7},
        "display": {"min_fraction": "loud"},
        "ambient": {"min_fraction": 0.25, "lux_floor": 500, "lux_ceiling": 10},
    }
    target = tmp_path / "settings.json"
    target.write_text(json.dumps(document), encoding="utf-8")
    loaded = load_settings(target)
    assert loaded.auto_dim.mode == "ambient"
    assert loaded.auto_dim.schedule_start_minutes == 1439 and loaded.auto_dim.schedule_end_minutes == 0
    assert loaded.auto_dim.schedule_fraction == 1.0
    assert loaded.auto_dim.display_min_fraction == 0.15
    assert loaded.auto_dim.ambient_min_fraction == 0.25
    # An inverted lux window falls back to the defaults instead of dividing by nothing.
    assert (loaded.auto_dim.ambient_lux_floor, loaded.auto_dim.ambient_lux_ceiling) == (15.0, 150.0)
    save_settings(loaded, target)
    assert load_settings(target).auto_dim == loaded.auto_dim
    assert AutoDimSettings.from_dict({"mode": "warm"}).mode == "off"
    with pytest.raises(ValueError):
        AutoDimSettings().with_mode("warm")


def test_lights_document_carries_the_auto_dim_block_and_the_dimming_word() -> None:
    facts = LightFacts(dimming=("auto_dim",), brightness_factor=0.3)
    document = build_lights_document({}, linked=False, auto_dim=AutoDimResult("schedule", "schedule", 0.3, True, 1380.0).to_dict())
    assert document["auto_dim"] == {"mode": "schedule", "source": "schedule", "factor": 0.3, "available": True, "reading": 1380.0}
    assert "auto_dim" not in build_lights_document({}, linked=False)
    detail = why_detail("working", sessions=[], asks=[], now=0.0, facts=facts)
    assert detail["dimming"] == ["auto_dim"] and detail["brightness_factor"] == 0.3
    # A working light stays "working"; only an idle one changes its word, and never to a night word.
    assert light_why(None, facts) == "unknown"


def test_controller_feeds_the_factor_into_the_night_dim_stage(headless, monkeypatch: pytest.MonkeyPatch) -> None:  # noqa: F811
    controller = headless
    controller.applicationDidFinishLaunching_(None)
    monkeypatch.setattr(auto_dim, "display_brightness_fraction", lambda: 0.5)
    monkeypatch.setattr(auto_dim, "ambient_light_lux", lambda: None)
    from jrbar.status_bar_legacy import StatusBarDevice

    device = StatusBarDevice("sidepulse:pro:TEST", "SidePulse", Path("/tmp/x"), Path("/tmp/x/LEDS.LED"), True, "agent", 200)

    def step(name: str):
        plan = controller.ambient_brightness_plan_for_device(device)
        return next(entry for entry in plan.trace if entry.name == name)

    assert step("night_dim").factor == 1.0
    controller.settings = controller.settings.with_auto_dim(
        AutoDimSettings(mode="schedule", schedule_start_minutes=0, schedule_end_minutes=1439, schedule_fraction=0.3)
    )
    assert step("night_dim").factor == 0.3
    assert controller.auto_dim_result().source == "schedule"
    # Ambient without a sensor falls back to the display and says so.
    controller.settings = controller.settings.with_auto_dim(AutoDimSettings(mode="ambient", display_min_fraction=0.1))
    result = controller.auto_dim_result()
    assert (result.mode, result.source, result.factor, result.available) == ("ambient", "display", 0.5, False)
    assert step("night_dim").factor == 0.5
    # The result is cached for a second, keyed on the settings, so a change is seen at once.
    monkeypatch.setattr(auto_dim, "display_brightness_fraction", lambda: 0.9)
    assert controller.auto_dim_result().factor == 0.5
    controller.settings = controller.settings.with_auto_dim(AutoDimSettings(mode="display"))
    assert controller.auto_dim_result().factor == 0.9
    lights = controller._core_build_lights()
    assert lights["auto_dim"]["source"] == "display" and lights["auto_dim"]["factor"] == 0.9


def test_set_setting_round_trips_auto_dim_by_dot_path(headless) -> None:  # noqa: F811
    controller = headless
    controller.applicationDidFinishLaunching_(None)
    reply = controller._core_dispatch("set_setting", {"path": "auto_dim.mode", "value": "schedule"})
    assert reply["value"] == "schedule" and controller.settings.auto_dim.mode == "schedule"
    reply = controller._core_dispatch("set_setting", {"path": "auto_dim.schedule.fraction", "value": 0.3})
    assert reply["value"] == 0.3 and controller.settings.auto_dim.schedule_fraction == 0.3
    # An unknown mode falls back to the default, as every other enum setting does.
    reply = controller._core_dispatch("set_setting", {"path": "auto_dim.mode", "value": "warm"})
    assert reply["value"] == "off"
    controller._core_dispatch("set_setting", {"path": "auto_dim.mode", "value": "schedule"})
    published = [document for kind, document in controller._core.published if kind == "settings"]
    assert published[-1]["document"]["auto_dim"]["schedule"]["fraction"] == 0.3
    reset = controller._core_dispatch("reset_settings", {"paths": ["auto_dim"]})
    assert reset["reset"] == ["auto_dim"] and controller.settings.auto_dim == AutoDimSettings()
