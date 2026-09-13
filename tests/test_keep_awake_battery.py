"""Battery-aware keep-awake: a positive battery reading may release the
hold when the owner opted out; an unknown power state never does."""

from __future__ import annotations

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
    saved = AgentMonitorSettings().with_keep_awake_on_battery(False)
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

