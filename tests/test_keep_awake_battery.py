"""Battery-aware keep-awake: a positive battery reading may release the
hold when the owner opted out; an unknown power state never does."""

from __future__ import annotations

from dataclasses import replace

from jrbar.keep_awake import KeepAwakeController
from jrbar.models import AgentMode


class _Process:
    def __init__(self, *args, **kwargs):
        self.terminated = False

    def poll(self):
        return 1 if self.terminated else None

    def terminate(self):
        self.terminated = True

    def wait(self, timeout=None):
        return 0


def _controller() -> KeepAwakeController:
    return KeepAwakeController(process_factory=_Process, watch_current_process=False)


def test_on_battery_with_default_setting_still_holds__and_2_more() -> None:
    # --- scenario: on_battery_with_default_setting_still_holds
    controller = _controller()
    assert controller.update(AgentMode.WORKING, on_battery=True, hold_on_battery=True)
    assert controller.process_running()

    # --- scenario: on_battery_opt_out_releases_and_stays_released
    controller = _controller()
    assert controller.update(AgentMode.WORKING, on_battery=False, hold_on_battery=False)
    assert not controller.update(
        AgentMode.WORKING, on_battery=True, hold_on_battery=False
    )
    assert not controller.process_running()

    # --- scenario: unknown_power_state_never_releases
    controller = _controller()
    assert controller.update(AgentMode.WORKING, on_battery=None, hold_on_battery=False)
    assert controller.process_running()



def test_settings_round_trip_keep_awake_on_battery(tmp_path) -> None:
    from jrbar.settings import AgentMonitorSettings, load_settings, save_settings

    path = tmp_path / "settings.json"
    saved = replace(AgentMonitorSettings(), keep_awake_on_battery=False)
    save_settings(saved, path)
    assert load_settings(path).keep_awake_on_battery is False


def test_hold_self_expires_and_the_next_tick_renews_it__and_1_more() -> None:
    # --- scenario: hold_self_expires_and_the_next_tick_renews_it
    """`caffeinate -t` bounds every assertion by time: when the child
    exits at expiry the hold is gone until the next sync tick respawns
    it -- so a wedged app cannot keep the machine awake forever."""
    import os

    from jrbar.keep_awake import (
        CAFFEINATE_COMMAND,
        CAFFEINATE_SELF_EXPIRE_SECONDS,
    )

    assert CAFFEINATE_COMMAND[:2] == ("/usr/bin/caffeinate", "-ims")
    flag_at = CAFFEINATE_COMMAND.index("-t")
    assert CAFFEINATE_COMMAND[flag_at + 1] == str(CAFFEINATE_SELF_EXPIRE_SECONDS)

    processes: list[_Process] = []

    def factory(command, **_kwargs):
        process = _Process(command)
        process.command = tuple(command)
        processes.append(process)
        return process

    controller = KeepAwakeController(process_factory=factory)
    assert controller.update(AgentMode.WORKING)
    command = controller.caffeinate_command()
    assert command[:4] == ["/usr/bin/caffeinate", "-ims", "-t", "1800"]
    assert "-w" in command and command[-1] == str(os.getpid())

    # The assertion expired (child exited on its own): the running check
    # sees it and the next tick respawns instead of believing a stale
    # handle.
    processes[-1].terminated = True
    assert controller.update(AgentMode.WORKING)
    assert len(processes) == 2

    # --- scenario: battery_yield_is_independent_of_the_reminder_toggle
    """The safety yield judges the battery DIRECTLY: routing it through
    low_power_active silently disabled it whenever the cosmetic charge
    reminder was off (regression review, round two)."""
    from types import SimpleNamespace

    from jrbar.keep_awake import battery_yields_hold

    settings = SimpleNamespace(
        low_battery_alert_enabled=False,  # reminder OFF — must not matter
        low_battery_threshold_percent=5.0,
    )
    dying = SimpleNamespace(battery_present=True, is_plugged=False, percent=4.0)
    healthy = SimpleNamespace(battery_present=True, is_plugged=False, percent=60.0)
    plugged = SimpleNamespace(battery_present=True, is_plugged=True, percent=4.0)

    assert battery_yields_hold(dying, settings)
    assert not battery_yields_hold(healthy, settings)
    assert not battery_yields_hold(plugged, settings)
    assert not battery_yields_hold(None, settings)



def test_the_daemon_passes_low_power_mode_only_while_the_setting_allows() -> None:
    """core_power reads Low Power Mode and the keep_awake_yield_low_power_mode
    setting (on by default) before each sync."""
    from types import SimpleNamespace

    import jrbar.core_power as core_power
    import jrbar.keep_awake as keep_awake

    seen: list[bool] = []
    controller = SimpleNamespace(
        keep_awake=SimpleNamespace(observe_environment=lambda **kwargs: seen.append(kwargs["low_power"])),
        last_snapshot=None,
        settings=SimpleNamespace(keep_awake_yield_low_power_mode=True, low_battery_threshold_percent=5.0),
    )
    original = keep_awake.read_low_power_mode
    keep_awake.read_low_power_mode = lambda **_kwargs: True
    try:
        core_power.observe_environment(controller)
        controller.settings.keep_awake_yield_low_power_mode = False
        core_power.observe_environment(controller)
    finally:
        keep_awake.read_low_power_mode = original
    assert seen == [True, False]


def test_the_low_power_setting_round_trips(tmp_path) -> None:
    import json

    from jrbar.settings import load_settings, save_settings

    target = tmp_path / "settings.json"
    assert load_settings(target).keep_awake_yield_low_power_mode is True
    target.write_text(json.dumps({"keep_awake_yield_low_power_mode": "no"}))
    assert load_settings(target).keep_awake_yield_low_power_mode is True
    target.write_text(json.dumps({"keep_awake_yield_low_power_mode": False}))
    loaded = load_settings(target)
    assert loaded.keep_awake_yield_low_power_mode is False
    save_settings(loaded, target)
    assert json.loads(target.read_text())["keep_awake_yield_low_power_mode"] is False


def test_a_stale_battery_reading_never_drives_the_yield__and_3_more(monkeypatch) -> None:
    from types import SimpleNamespace

    from jrbar.battery_runtime import BatteryObservation
    from jrbar.keep_awake import (
        BATTERY_READING_MAX_AGE_SECONDS,
        battery_yields_hold,
        fresh_battery_snapshot,
    )

    low = SimpleNamespace(battery_present=True, is_plugged=False, percent=3.0)
    settings = SimpleNamespace(low_battery_threshold_percent=5.0)

    def observation(snapshot, observed_at):
        return BatteryObservation(snapshot, observed_at, observed_at, None, False)

    # --- scenario: a_fresh_reading_is_used
    fresh = observation(low, 1000.0)
    assert fresh_battery_snapshot(fresh, now=1000.0 + 5) is low
    assert battery_yields_hold(fresh_battery_snapshot(fresh, now=1005.0), settings)

    # --- scenario: a_reading_past_its_age_is_unknown_not_a_floor
    old = observation(low, 1000.0)
    later = 1000.0 + BATTERY_READING_MAX_AGE_SECONDS + 1
    assert fresh_battery_snapshot(old, now=later) is None
    assert not battery_yields_hold(fresh_battery_snapshot(old, now=later), settings)

    # --- scenario: no_observation_or_no_stamp_is_unknown
    assert fresh_battery_snapshot(None, now=1000.0) is None
    assert fresh_battery_snapshot(observation(low, None), now=1000.0) is None
    assert fresh_battery_snapshot(observation(None, 1000.0), now=1000.0) is None

    # --- scenario: the_core_power_floor_reads_only_fresh_readings
    from jrbar import core_power

    monkeypatch.setattr(core_power.keep_awake_module, "read_thermal_state", lambda: None)
    monkeypatch.setattr(core_power.keep_awake_module, "read_low_power_mode", lambda: False)
    stale_controller = SimpleNamespace(
        _production_battery_observation=observation(low, 1000.0),
        settings=settings,
    )
    seen = {}

    class _Keep:
        def observe_environment(self, **kwargs):
            seen.update(kwargs)

    stale_controller.keep_awake = _Keep()
    stale_controller.last_snapshot = None
    stale_controller.last_lid_closed = None
    core_power.observe_environment(stale_controller, monotonic=lambda: later)
    assert seen["battery_floor"] is False
    seen.clear()
    core_power.observe_environment(stale_controller, monotonic=lambda: 1002.0)
    assert seen["battery_floor"] is True
