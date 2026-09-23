"""state.power.battery: what the daemon already reads, published, plus the
agent runway -- will the run holding the Mac awake outlast the battery."""

from __future__ import annotations

from dataclasses import replace
from types import SimpleNamespace

from jrbar.battery import BatterySnapshot
from jrbar.battery_runtime import (
    ADAPTER_SHORT_CLEAR_WATTS,
    ADAPTER_SHORT_DRAIN_WATTS,
    AGENT_RUNWAY_WARNING_MINUTES,
    BATTERY_TIME_UNKNOWN,
    adapter_short,
    battery_state_document,
)
from jrbar.core_runtime import doc_significant_equal

ON_BATTERY = BatterySnapshot(
    percent=41,
    is_plugged=False,
    battery_present=True,
    voltage=12.0,
    amperage=-1.5,
    battery_watts=-18.0,
    time_to_empty=95,
    cycle_count=212,
    temperature_c=31.26,
    health_percent=91,
    condition="Normal",
)


def test_the_document_reads_the_snapshot_honestly() -> None:
    document = battery_state_document(ON_BATTERY, agents_working=2, hold_active=True)
    assert document == {
        "percent": 41,
        "charging": False,
        "plugged": False,
        "minutes_left": 95,
        "minutes_to_full": None,
        "health_percent": 91,
        "cycle_count": 212,
        "temperature_c": 31.3,
        "condition": "Normal",
        "draw_watts": 18.0,
        "adapter_watts": None,
        "runway": {
            "agents": 2,
            "minutes_left": 95,
            "short": False,
            "adapter_short": False,
            "full_speed_watts": None,
        },
    }


def test_the_runway_is_short_only_on_battery_with_a_held_run() -> None:
    low = replace(ON_BATTERY, time_to_empty=AGENT_RUNWAY_WARNING_MINUTES - 1)
    assert battery_state_document(low, agents_working=1, hold_active=True)["runway"]["short"] is True
    assert battery_state_document(low, agents_working=0, hold_active=True)["runway"]["short"] is False
    assert battery_state_document(low, agents_working=1, hold_active=False)["runway"]["short"] is False
    plugged = replace(low, is_plugged=True, adapter_watts=67, battery_watts=20.0)
    document = battery_state_document(plugged, agents_working=1, hold_active=True)
    assert document["runway"] == {
        "agents": 1,
        "minutes_left": None,
        "short": False,
        "adapter_short": False,
        "full_speed_watts": None,
    }
    assert document["adapter_watts"] == 67.0 and document["draw_watts"] is None


def test_unknown_estimates_and_missing_batteries() -> None:
    estimating = replace(ON_BATTERY, time_to_empty=BATTERY_TIME_UNKNOWN, cycle_count=-1, health_percent=-1)
    document = battery_state_document(estimating)
    assert document["minutes_left"] is None
    assert document["cycle_count"] is None and document["health_percent"] is None
    charging = replace(ON_BATTERY, is_plugged=True, is_charging=True, time_to_full=40)
    assert battery_state_document(charging)["minutes_to_full"] == 40
    assert battery_state_document(replace(ON_BATTERY, battery_present=False)) is None
    assert battery_state_document(None) is None


def test_a_moving_estimate_alone_does_not_rebroadcast_the_state() -> None:
    def state(snapshot):
        return {"power": {"battery": battery_state_document(snapshot, agents_working=1, hold_active=True)}}

    first = state(ON_BATTERY)
    drifted = state(replace(ON_BATTERY, time_to_empty=93, battery_watts=-17.2, temperature_c=31.9))
    assert doc_significant_equal("state", first, drifted)
    stepped = state(replace(ON_BATTERY, percent=40))
    assert not doc_significant_equal("state", first, stepped)
    short = state(replace(ON_BATTERY, time_to_empty=12))
    assert not doc_significant_equal("state", first, short)


def test_the_warning_by_time_left_comes_twice_as_early_for_a_held_run() -> None:
    from jrbar.battery_runtime import low_battery_by_time_left

    draining = replace(ON_BATTERY, time_to_empty=25)
    assert not low_battery_by_time_left(draining, threshold_minutes=0)
    assert not low_battery_by_time_left(draining, threshold_minutes=20)
    assert low_battery_by_time_left(draining, threshold_minutes=20, agents_working=2, hold_on_battery=True)
    assert not low_battery_by_time_left(draining, threshold_minutes=20, agents_working=2, hold_on_battery=False)
    assert low_battery_by_time_left(draining, threshold_minutes=25)
    # Never on a guess, never on AC.
    assert not low_battery_by_time_left(replace(draining, time_to_empty=BATTERY_TIME_UNKNOWN), threshold_minutes=60)
    assert not low_battery_by_time_left(replace(draining, is_plugged=True), threshold_minutes=60)
    assert not low_battery_by_time_left(None, threshold_minutes=60)


def test_the_daemon_warns_by_time_left_when_asked(tmp_path) -> None:
    from jrbar import core_power
    from jrbar.core_runtime import settings_from_document
    from jrbar.settings import AgentMonitorSettings

    settings = AgentMonitorSettings(low_battery_threshold_minutes=20.0)
    keep = SimpleNamespace(working_count=1, agent_demand=True)
    controller = SimpleNamespace(settings=settings, keep_awake=keep)
    draining = replace(ON_BATTERY, time_to_empty=35)
    assert core_power.low_battery_by_time_left(controller, draining) is True
    controller.settings = AgentMonitorSettings(low_battery_threshold_minutes=20.0, keep_awake_on_battery=False)
    assert core_power.low_battery_by_time_left(controller, draining) is False
    controller.settings = AgentMonitorSettings(low_battery_threshold_minutes=40.0, low_battery_alert_enabled=False)
    assert core_power.low_battery_by_time_left(controller, draining) is False
    document = AgentMonitorSettings().to_dict()
    assert document["battery_monitoring"]["low_battery_threshold_minutes"] == 0.0
    document["battery_monitoring"]["low_battery_threshold_minutes"] = 500
    assert settings_from_document(document, scratch_dir=tmp_path).low_battery_threshold_minutes == 120.0


def test_the_state_carries_the_battery(monkeypatch) -> None:
    from jrbar import core_power

    keep = SimpleNamespace(working_count=1, process_running=lambda: True, hold_document=lambda: {})
    controller = SimpleNamespace(
        keep_awake=keep,
        closed_lid_awake=SimpleNamespace(active=lambda: False, sleeper=None),
        _production_battery_observation=SimpleNamespace(snapshot=ON_BATTERY),
        last_lid_closed=False,
    )
    document = {"power": {"keep_awake": True, "closed_lid": {"policy": "never"}}}
    core_power.augment_power_document(controller, document)
    assert document["power"]["battery"]["runway"] == {
        "agents": 1,
        "minutes_left": 95,
        "short": False,
        "adapter_short": False,
        "full_speed_watts": None,
    }


PLUGGED_AND_FALLING = replace(
    ON_BATTERY,
    is_plugged=True,
    adapter_watts=30,
    battery_watts=-6.0,
    full_charge_watts=96.0,
)


def test_a_charger_that_cannot_carry_the_run_is_named() -> None:
    document = battery_state_document(PLUGGED_AND_FALLING, agents_working=3, hold_active=True)
    assert document["runway"]["adapter_short"] is True
    assert document["runway"]["full_speed_watts"] == 96.0
    assert document["adapter_watts"] == 30.0
    # Idle, a slow charger is nobody's problem; on battery there is no
    # charger to blame; a charge paused at 80 % is not a drain.
    assert adapter_short(PLUGGED_AND_FALLING, agents_working=0) is False
    assert adapter_short(replace(PLUGGED_AND_FALLING, is_plugged=False), agents_working=3) is False
    assert adapter_short(replace(PLUGGED_AND_FALLING, battery_watts=0.0), agents_working=3) is False
    assert adapter_short(replace(PLUGGED_AND_FALLING, battery_watts=12.0), agents_working=3) is False
    assert adapter_short(None, agents_working=3) is False
    quiet = battery_state_document(replace(PLUGGED_AND_FALLING, battery_watts=4.0), agents_working=3)
    assert quiet["runway"]["adapter_short"] is False and quiet["runway"]["full_speed_watts"] is None


def test_the_adapter_flag_does_not_flap_at_its_edge() -> None:
    between = replace(
        PLUGGED_AND_FALLING,
        battery_watts=-(ADAPTER_SHORT_CLEAR_WATTS + ADAPTER_SHORT_DRAIN_WATTS) / 2,
    )
    assert adapter_short(between, agents_working=1, previously=False) is False
    assert adapter_short(between, agents_working=1, previously=True) is True
    settled = replace(PLUGGED_AND_FALLING, battery_watts=-(ADAPTER_SHORT_CLEAR_WATTS / 2))
    assert adapter_short(settled, agents_working=1, previously=True) is False


def test_the_daemon_carries_the_adapter_flag_between_reads() -> None:
    from jrbar import core_power

    keep = SimpleNamespace(working_count=2, process_running=lambda: True, hold_document=lambda: {})
    observation = SimpleNamespace(snapshot=PLUGGED_AND_FALLING)
    controller = SimpleNamespace(
        keep_awake=keep,
        closed_lid_awake=SimpleNamespace(active=lambda: False, sleeper=None),
        _production_battery_observation=observation,
        last_lid_closed=False,
    )

    def runway() -> dict:
        document = {"power": {"keep_awake": True, "closed_lid": {"policy": "never"}}}
        core_power.augment_power_document(controller, document)
        return document["power"]["battery"]["runway"]

    assert runway()["adapter_short"] is True
    observation.snapshot = replace(PLUGGED_AND_FALLING, battery_watts=-1.0)
    assert runway()["adapter_short"] is True
    observation.snapshot = replace(PLUGGED_AND_FALLING, battery_watts=-0.2)
    assert runway()["adapter_short"] is False
    observation.snapshot = replace(PLUGGED_AND_FALLING, battery_watts=-1.0)
    assert runway()["adapter_short"] is False
