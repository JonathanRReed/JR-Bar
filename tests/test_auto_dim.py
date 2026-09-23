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


def test_default_is_off_and_keeps_todays_factor__and_2_more() -> None:
    # --- scenario: default_is_off_and_keeps_todays_factor
    assert AutoDimSettings().mode == "off"
    result = _evaluate(AutoDimSettings(), display=0.1, ambient=0.0)
    assert result == auto_dim.OFF_RESULT
    assert result.factor == 1.0 and result.available is True

    # --- scenario: schedule_window_math
    for start, end, now, active in [
        (22 * 60, 7 * 60, 23 * 60, True),  # wraps midnight, evening
        (22 * 60, 7 * 60, 3 * 60, True),  # wraps midnight, small hours
        (22 * 60, 7 * 60, 12 * 60, False),
        (22 * 60, 7 * 60, 7 * 60, False),  # end is exclusive
        (22 * 60, 7 * 60, 22 * 60, True),  # start is inclusive
        (9 * 60, 17 * 60, 12 * 60, True),  # same-day window
        (9 * 60, 17 * 60, 20 * 60, False),
        (9 * 60, 9 * 60, 9 * 60, False),  # empty window never dims
    ]:
        assert schedule_active(start, end, now) is active

    # --- scenario: schedule_mode_applies_the_fraction_inside_the_window_only
    settings = AutoDimSettings(mode="schedule", schedule_start_minutes=22 * 60, schedule_end_minutes=7 * 60, schedule_fraction=0.3)
    inside = _evaluate(settings, now_minutes=23 * 60)
    outside = _evaluate(settings, now_minutes=12 * 60)
    assert (inside.source, inside.factor, inside.available) == ("schedule", 0.3, True)
    assert (outside.source, outside.factor) == ("schedule", 1.0)



def test_display_mode_follows_the_display_with_a_floor_and_reports_unavailable__and_1_more() -> None:
    # --- scenario: display_mode_follows_the_display_with_a_floor_and_reports_unavailable
    settings = AutoDimSettings(mode="display", display_min_fraction=0.15)
    assert _evaluate(settings, display=0.6) == AutoDimResult("display", "display", 0.6, True, 0.6)
    assert _evaluate(settings, display=0.02).factor == 0.15
    unreadable = _evaluate(settings, display=None)
    assert (unreadable.source, unreadable.factor, unreadable.available, unreadable.reading) == ("display", 1.0, False, None)

    def boom():
        raise RuntimeError("no display")

    assert _evaluate(settings, display=boom).available is False

    # --- scenario: ambient_mode_interpolates_lux_and_falls_back_to_the_display
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


def test_the_screen_bar_never_follows_the_backlight_twice(headless, monkeypatch: pytest.MonkeyPatch) -> None:  # noqa: F811
    """The Screen Bar is drawn on the display, whose backlight already
    dims with the room: neither auto brightness nor the lux/display
    auto-dim may scale it again. A deliberate night schedule still does,
    and a strip beside the screen still follows both."""
    controller = headless
    controller.applicationDidFinishLaunching_(None)
    monkeypatch.setattr(auto_dim, "display_brightness_fraction", lambda: 0.3)
    monkeypatch.setattr(auto_dim, "ambient_light_lux", lambda: None)
    from jrbar import display_brightness
    from jrbar.status_bar_legacy import VIRTUAL_DEVICE_ID, StatusBarDevice

    monkeypatch.setattr(display_brightness, "auto_led_brightness", lambda: 72)
    bar = StatusBarDevice(VIRTUAL_DEVICE_ID, "Screen Bar", Path("/tmp/x"), Path("/tmp/x/LEDS.LED"), True, "agent", 255,
                          auto_brightness_enabled=True)
    strip = StatusBarDevice("sidepulse:pro:TEST", "SidePulse", Path("/tmp/x"), Path("/tmp/x/LEDS.LED"), True, "agent", 255,
                            auto_brightness_enabled=True)

    def step(device, name: str):
        plan = controller.ambient_brightness_plan_for_device(device)
        return next(entry for entry in plan.trace if entry.name == name)

    for mode in ("ambient", "display"):
        controller.settings = controller.settings.with_auto_dim(AutoDimSettings(mode=mode))
        assert step(bar, "base").after == 255
        assert step(bar, "night_dim").factor == 1.0
        assert step(strip, "base").after == 72
        assert step(strip, "night_dim").factor == 0.3
    controller.settings = controller.settings.with_auto_dim(
        AutoDimSettings(mode="schedule", schedule_start_minutes=0, schedule_end_minutes=1439, schedule_fraction=0.3)
    )
    assert step(bar, "night_dim").factor == 0.3


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


# --- temporal smoothing ---------------------------------------------------------


class _Clock:
    def __init__(self) -> None:
        self.now = 0.0

    def __call__(self) -> float:
        return self.now


def test_a_passing_shadow_does_not_dim_the_desk() -> None:
    from jrbar.auto_dim import LuxSmoother

    clock = _Clock()
    smoother = LuxSmoother(clock=clock)
    assert smoother.update(120.0) == 120.0
    clock.now = 1.0
    # One dark read between bright ones: the median target stays bright.
    assert smoother.update(5.0) == 120.0
    clock.now = 2.0
    assert 115.0 < smoother.update(118.0) <= 120.0
    assert smoother.last_raw == 118.0


def test_dusk_dims_slowly_and_a_lamp_brightens_at_once() -> None:
    from jrbar.auto_dim import LuxSmoother

    clock = _Clock()
    smoother = LuxSmoother(dim_seconds=10.0, brighten_seconds=2.0, clock=clock)
    smoother.update(100.0)
    for second in range(1, 4):
        clock.now = float(second)
        value = smoother.update(10.0)
    # Three seconds of a genuinely darker room: on the way, not there.
    assert 10.0 < value < 100.0
    for second in range(4, 60):
        clock.now = float(second)
        value = smoother.update(10.0)
    assert value < 11.0
    clock.now = 60.0
    brightened = smoother.update(200.0)
    assert brightened > value
    # A two-second time constant: most of the way within five seconds,
    # where a dim of the same size takes most of a minute.
    clock.now = 64.0
    assert smoother.update(200.0) > 180.0


def test_the_readout_carries_the_raw_reading_beside_the_smoothed_one() -> None:
    from jrbar.auto_dim import LuxSmoother, _SmoothedAmbientLight

    clock = _Clock()
    reader = _SmoothedAmbientLight(lambda: 80.0, LuxSmoother(clock=clock))
    settings = AutoDimSettings(mode="ambient")
    result = evaluate_auto_dim(settings, now_minutes=0, display_reader=lambda: None, ambient_reader=reader)
    assert result.reading == 80.0 and result.raw == 80.0
    assert result.to_dict()["raw"] == 80.0
    assert "raw" not in AutoDimResult("display", "display", 0.6, True, 0.6).to_dict()


def test_an_unreadable_sensor_resets_the_smoother() -> None:
    from jrbar.auto_dim import AmbientLightUnavailableError, LuxSmoother, _SmoothedAmbientLight

    def unreadable() -> float:
        raise AmbientLightUnavailableError("no sensor")

    smoother = LuxSmoother(clock=_Clock())
    smoother.update(50.0)
    reader = _SmoothedAmbientLight(unreadable, smoother)
    assert reader() is None
    assert smoother.value is None and reader.last_raw is None


# --- learning from the slider ------------------------------------------------------


def _votes_from(curve, base, luxes):
    from jrbar.auto_dim import BrightnessVote, ambient_factor

    return tuple(
        BrightnessVote(
            lux=lux,
            level=base
            * ambient_factor(
                lux,
                min_fraction=curve.ambient_min_fraction,
                lux_floor=curve.ambient_lux_floor,
                lux_ceiling=curve.ambient_lux_ceiling,
            ),
            at=float(index),
        )
        for index, lux in enumerate(luxes)
    )


def test_the_slider_teaches_a_curve_that_is_offered_not_applied() -> None:
    from jrbar.auto_dim import AutoDimSettings, learn_ambient_curve

    wanted = AutoDimSettings(mode="ambient", ambient_min_fraction=0.2, ambient_lux_floor=30.0, ambient_lux_ceiling=300.0)
    votes = _votes_from(wanted, 0.8, (8.0, 30.0, 90.0, 180.0, 300.0, 600.0))
    current = AutoDimSettings(mode="ambient")
    learned = learn_ambient_curve(votes, current, current_base=1.0)
    assert learned["ready"] is True and learned["reason"] is None
    suggested = learned["suggested"]
    assert suggested["brightness"] == 0.8
    assert suggested["lux_floor"] == 30.0 and suggested["lux_ceiling"] == 300.0
    assert abs(suggested["min_fraction"] - 0.2) < 1e-9
    assert learned["error_suggested"] < learned["error_now"]
    # Votes that the current curve already explains ask for nothing.
    fits = learn_ambient_curve(_votes_from(current, 1.0, (5.0, 40.0, 150.0, 400.0)), current, current_base=1.0)
    assert fits["ready"] is False and fits["reason"] == "already_fits"


def test_a_curve_needs_enough_votes_across_enough_light() -> None:
    from jrbar.auto_dim import AutoDimSettings, BrightnessVote, learn_ambient_curve

    current = AutoDimSettings(mode="ambient")
    two = (BrightnessVote(10.0, 0.3, 1.0), BrightnessVote(200.0, 0.9, 2.0))
    assert learn_ambient_curve(two, current, current_base=1.0)["reason"] == "needs_votes"
    narrow = (BrightnessVote(40.0, 0.3, 1.0), BrightnessVote(60.0, 0.5, 2.0), BrightnessVote(100.0, 0.9, 3.0))
    assert learn_ambient_curve(narrow, current, current_base=1.0)["reason"] == "needs_range"


def test_the_latest_vote_at_a_light_stands_and_nonsense_is_dropped() -> None:
    from jrbar.auto_dim import MAX_LEARN_SAMPLES, BrightnessVote, record_vote

    votes = record_vote((), BrightnessVote(100.0, 0.5, 1.0))
    votes = record_vote(votes, BrightnessVote(110.0, 0.7, 2.0))
    assert votes == (BrightnessVote(110.0, 0.7, 2.0),)
    for bad in (BrightnessVote(float("nan"), 0.5, 3.0), BrightnessVote(10.0, 0.0, 3.0), BrightnessVote(-1.0, 0.5, 3.0)):
        assert record_vote(votes, bad) == votes
    for index in range(MAX_LEARN_SAMPLES + 10):
        votes = record_vote(votes, BrightnessVote(2.0 * 1.5**index, 0.5, float(index)))
    assert len(votes) == MAX_LEARN_SAMPLES


def test_the_daemon_counts_a_slider_move_only_while_following_the_sensor() -> None:
    from types import SimpleNamespace

    from jrbar import core_lights, core_runtime
    from jrbar.auto_dim import AutoDimResult, AutoDimSettings

    result = [AutoDimResult("ambient", "ambient", 0.5, True, 40.0)]
    controller = SimpleNamespace(
        auto_dim_result=lambda: result[0],
        settings=SimpleNamespace(auto_dim=AutoDimSettings(mode="ambient")),
    )
    core_lights.note_brightness_nudge(controller, 0.8, now=10.0)
    assert [(vote.lux, vote.level) for vote in controller._core_brightness_votes] == [(40.0, 0.4)]
    # The display fallback, another mode, or an unread sensor is no vote.
    for other in (
        AutoDimResult("ambient", "display", 0.7, False, 0.7),
        AutoDimResult("schedule", "schedule", 0.3, True, 600.0),
        AutoDimResult("ambient", "ambient", 1.0, True, None),
    ):
        result[0] = other
        core_lights.note_brightness_nudge(controller, 0.5, now=11.0)
    assert len(controller._core_brightness_votes) == 1
    assert controller._core_brightness_base == 0.5

    reply = core_runtime._cmd_auto_dim_learning(controller, {})
    assert reply["mode"] == "ambient" and reply["votes"] == 1 and reply["reason"] == "needs_votes"
    assert reply["samples"] == [{"lux": 40.0, "level": 0.4, "at": 10.0}]
    assert core_runtime._cmd_auto_dim_learning(controller, {"clear": True})["votes"] == 0
    import pytest

    from jrbar.core_server import CommandError

    with pytest.raises(CommandError):
        core_runtime._cmd_auto_dim_learning(controller, {"clear": "yes"})
    assert "auto_dim_learning" in core_runtime.command_names()
