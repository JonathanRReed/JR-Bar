"""The daemon's keep-awake lease over the socket: hold_awake/release_awake,
what state.power says, the power rows in History, and the power events."""

from __future__ import annotations

import time
from pathlib import Path
from types import SimpleNamespace

import pytest

from jrbar import core_power, core_runtime
from jrbar import keep_awake as keep_awake_module
from jrbar.core_server import CommandError
from jrbar.keep_awake import POWER_SUSPENDED, THERMAL_SERIOUS
from jrbar.models import AgentMode
from tests.test_core_runtime import headless  # noqa: F401  (the headless daemon fixture)


def _status(agent_id: str, mode: AgentMode, *, subagent: bool = False, stale: bool = False):
    return SimpleNamespace(agent_id=agent_id, mode=mode, is_subagent=subagent, stale=stale)


class _Process:
    def __init__(self, command, **_kwargs) -> None:
        self.command = tuple(command)
        self.terminated = False

    def poll(self):
        return 0 if self.terminated else None

    def terminate(self) -> None:
        self.terminated = True

    def wait(self, timeout=None) -> int:
        return 0

    def kill(self) -> None:
        self.terminated = True


@pytest.fixture
def powered(headless, monkeypatch: pytest.MonkeyPatch):  # noqa: F811
    controller = headless
    controller.applicationDidFinishLaunching_(None)
    controller.keep_awake.process_factory = _Process
    controller.keep_awake.watch_current_process = False
    controller.closed_lid_awake.process_factory = _Process
    controller.closed_lid_awake.watch_current_process = False
    monkeypatch.setattr(keep_awake_module, "read_thermal_state", lambda: None)
    controller.last_snapshot = SimpleNamespace(
        statuses=(
            _status("claude:session:a", AgentMode.WORKING),
            _status("codex:session:b", AgentMode.WAITING_FOR_INPUT),
            _status("claude:session:worker", AgentMode.WORKING, subagent=True),
            _status("codex:session:old", AgentMode.WORKING, stale=True),
        ),
        stale_statuses=(),
    )
    return controller


def test_session_facts_count_only_live_main_sessions() -> None:
    snapshot = SimpleNamespace(
        statuses=(
            _status("a", AgentMode.WORKING),
            _status("b", AgentMode.WAITING_FOR_INPUT),
            _status("c", AgentMode.COMPLETED),
            _status("w", AgentMode.WORKING, subagent=True),
            _status("s", AgentMode.WORKING, stale=True),
        )
    )
    assert core_power.session_facts(snapshot) == (frozenset({"a", "b"}), 1)
    assert core_power.session_facts(None) == (frozenset(), 0)


def test_hold_awake_starts_a_lease_the_state_reports(powered, tmp_path: Path) -> None:
    controller = powered
    assert {"hold_awake", "release_awake"} <= set(core_runtime.command_names())

    reply = core_runtime._cmd_hold_awake(controller, {"seconds": 3600, "source": "chip"})
    assert reply["lease"]["kind"] == "duration" and reply["lease"]["source"] == "chip"
    assert reply["hold"]["state"] == "manual"
    assert controller.keep_awake.process_running()
    # The lease is kept where a restarted daemon will find it.
    assert (tmp_path / "state" / "keep-awake-lease.json").is_file()

    state = controller._core_build_state()
    hold = state["power"]["hold"]
    assert hold["state"] == "manual"
    assert hold["lease"]["until"] == pytest.approx(time.time() + 3600, abs=5)
    assert state["power"]["keep_awake"] is True
    assert state["power"]["closed_lid"]["sleeps_on_release"] is True
    assert "lid_closed" in state["power"]["closed_lid"]

    released = core_runtime._cmd_release_awake(controller, {})
    assert released["ended"] is True
    assert core_runtime._cmd_release_awake(controller, {})["ended"] is False
    # A cancelled lease is the person's own doing: no release to report.
    assert controller._core_build_state()["power"]["last_release"] is None


def test_until_these_agents_finish_waits_on_the_live_main_sessions(powered) -> None:
    controller = powered
    reply = core_runtime._cmd_hold_awake(controller, {"until_agents_idle": True})
    assert reply["lease"]["sessions"] == ["claude:session:a", "codex:session:b"]

    with pytest.raises(CommandError) as refused:
        core_runtime._cmd_hold_awake(
            controller, {"until_agents_idle": True, "sessions": ["claude:session:worker"]}
        )
    assert refused.value.code == "refused"

    # Both finish: the next sync ends the lease, History says why, and a
    # power event goes out once.
    controller.last_snapshot = SimpleNamespace(
        statuses=(_status("claude:session:a", AgentMode.COMPLETED),), stale_statuses=()
    )
    server = controller._core
    server.published.clear()
    controller.sync_keep_awake(AgentMode.COMPLETED)
    assert controller.keep_awake.lease is None
    events = [document for kind, document in server.published if kind == "event"]
    assert [(event["kind"], event["power"], event["detail"]) for event in events] == [
        ("power", "lease_ended", "finished")
    ]
    controller.sync_keep_awake(AgentMode.COMPLETED)
    assert [kind for kind, document in server.published if kind == "event"] == ["event"]

    history = core_runtime._cmd_list_history(controller, {})
    power_rows = [row for row in history["rows"] if row["kind"] == "power"]
    assert [(row["label"], row["detail"]) for row in power_rows] == [("Keep awake ended", "agents finished")]
    last = controller._core_build_state()["power"]["last_release"]
    assert last["kind"] == "lease_ended" and last["reason"] == "finished"


def test_an_agents_lease_outlives_a_restart_that_has_not_read_the_sessions(powered) -> None:
    controller = powered
    core_runtime._cmd_hold_awake(controller, {"until_agents_idle": True})
    # A restarted daemon restores the lease before its first refresh lands
    # (or while that refresh keeps failing): no snapshot is not "all done".
    controller.last_snapshot = None
    controller.sync_keep_awake(AgentMode.WORKING)
    assert controller.keep_awake.lease is not None
    assert controller.keep_awake.pending_ids is None
    assert controller._core_build_state()["power"]["last_release"] is None


@pytest.mark.parametrize(
    "args",
    [{}, {"seconds": "soon"}, {"seconds": 60, "indefinite": True}, {"until": 1}],
)
def test_hold_awake_refuses_malformed_arguments(powered, args) -> None:
    with pytest.raises(CommandError) as error:
        core_runtime._cmd_hold_awake(powered, args)
    assert error.value.code == "invalid_args"


def test_zero_seconds_ends_the_lease_like_quiet(powered) -> None:
    controller = powered
    core_runtime._cmd_hold_awake(controller, {"indefinite": True, "display": True})
    assert controller.keep_awake.effective_display() is True
    reply = core_runtime._cmd_hold_awake(controller, {"seconds": 0})
    assert reply == {"ended": True, "hold": controller.keep_awake.hold_document()}


def test_heat_suspends_the_hold_and_is_published(powered, monkeypatch: pytest.MonkeyPatch) -> None:
    controller = powered
    core_runtime._cmd_hold_awake(controller, {"seconds": 600})
    controller.last_lid_closed = True
    monkeypatch.setattr(keep_awake_module, "read_thermal_state", lambda: THERMAL_SERIOUS)
    server = controller._core
    server.published.clear()
    controller.sync_keep_awake(AgentMode.WORKING)
    assert controller.keep_awake.suspension == "thermal"
    assert not controller.keep_awake.process_running()
    assert controller._core_power_log.last(POWER_SUSPENDED).reason == "thermal"
    events = [document for kind, document in server.published if kind == "event"]
    assert [(event["power"], event["detail"]) for event in events] == [("suspended", "thermal")]
    hold = controller._core_build_state()["power"]["hold"]
    assert hold["suspended"] == "thermal" and hold["thermal"] == "serious"
    assert hold["state"] == "manual"


def test_the_grace_epoch_is_stable_across_builds(powered) -> None:
    controller = powered
    controller.sync_keep_awake(AgentMode.WORKING)
    controller.sync_keep_awake(AgentMode.COMPLETED)
    first = controller._core_build_state()["power"]["hold"]["grace_until"]
    second = controller._core_build_state()["power"]["hold"]["grace_until"]
    assert first is not None and first == second


def test_a_closed_lid_stretch_reports_what_finished_and_when_it_slept() -> None:
    from jrbar.keep_awake import POWER_LID_HOLD_ENDED, POWER_SLEPT, PowerLog

    log = PowerLog(clock=lambda: 10_000.0)
    log.record(POWER_LID_HOLD_ENDED, reason="agents_idle", duration=9_600.0, at=10_000.0)
    log.record(POWER_SLEPT, reason="agents_idle", at=10_001.0)
    completed = SimpleNamespace(value="completed")
    asked = SimpleNamespace(value="asked")
    ledger = SimpleNamespace(
        entries=(
            # Finished before the lid was shut: not part of the stretch.
            SimpleNamespace(kind=completed, occurred_at_epoch=300.0),
            SimpleNamespace(kind=completed, occurred_at_epoch=5_000.0),
            SimpleNamespace(kind=asked, occurred_at_epoch=6_000.0),
            SimpleNamespace(kind=completed, occurred_at_epoch=9_990.0),
        )
    )
    published: list[tuple[str, dict]] = []
    controller = SimpleNamespace(
        keep_awake=SimpleNamespace(hold_document=lambda: {}, working_count=0, process_running=lambda: False),
        closed_lid_awake=SimpleNamespace(active=lambda: False, sleeper=None),
        _core_power_log=log,
        _core_power_published=None,
        activity_ledger=ledger,
        _core_publish_event=lambda kind, **fields: published.append((kind, fields)),
    )
    document = {"power": {"closed_lid": {}}}
    core_power.augment_power_document(controller, document)
    assert document["power"]["last_release"] == {
        "kind": "slept",
        "reason": "agents_idle",
        "at": 10_001.0,
        "duration": 9_600.0,
        "finished": 2,
        "slept_at": 10_001.0,
    }
    core_power.after_keep_awake_sync(controller)
    assert [(fields["power"], fields.get("finished")) for _kind, fields in published] == [
        ("lid_hold_ended", 2),
        ("slept", None),
    ]


def test_the_daemons_low_power_reads_time_left_too(powered) -> None:
    from jrbar.battery import BatterySnapshot

    controller = powered
    draining = BatterySnapshot(percent=30, is_plugged=False, battery_present=True, time_to_empty=15)
    assert controller.low_power_active(draining) is False
    core_runtime._cmd_set_setting(
        controller, {"path": "battery_monitoring.low_battery_threshold_minutes", "value": 20}
    )
    assert controller.low_power_active(draining) is True
    # The charge threshold still stands on its own.
    assert controller.low_power_active(BatterySnapshot(percent=3, is_plugged=False, battery_present=True)) is True


# --- presence ------------------------------------------------------------------


def test_presence_quiets_a_call_and_holds_the_ladder_at_the_light(powered, monkeypatch) -> None:
    from jrbar import presence as presence_module
    from tests.test_core_runtime import _TimerAPI

    controller = powered
    controller.dnd_controller.start()
    controller.settings = controller.settings.with_escalation_tier("chime")
    controller.ask_blocked_since = time.monotonic() - 10_000
    assert controller.current_escalation_stage() == 3

    reply = core_runtime._cmd_presence(controller, {"mic": True, "camera": False})
    assert reply["presence"]["on_call"] is True
    assert reply["presence"]["quiet"] == "sounds"
    assert reply["presence"]["celebrations_held"] is True
    assert controller.current_escalation_stage() == 1
    assert any(selector == "corePresenceExpired:" for _interval, selector, _repeats in _TimerAPI.calls)

    state = controller._core_build_state()
    assert state["presence"]["on_call"] is True and state["presence"]["mic"] is True
    assert state["focus"]["source"] == "call"
    assert state["focus"]["audible_allowed"] is False
    assert state["focus"]["banner_allowed"] is True
    assert state["escalation"]["stage"] == "ramp"
    assert controller._core_dot_beacon_facts().on_call is True

    # The app stops renewing: the timer finds the report stale and the call over.
    stale_at = time.time() + presence_module.PRESENCE_TTL_SECONDS + 1
    monkeypatch.setattr(core_power.time, "time", lambda: stale_at)
    controller.dnd_controller._wall_clock = lambda: stale_at
    armed = len(_TimerAPI.calls)
    controller.corePresenceExpired_(None)
    assert controller.current_escalation_stage() == 3
    assert controller._core_build_state()["focus"]["source"] is None
    # ...and arms nothing more: a stale report is judged once, not every second.
    assert not any(
        selector == "corePresenceExpired:" for _interval, selector, _repeats in _TimerAPI.calls[armed:]
    )


def test_the_apps_focus_reading_expires_with_its_report(powered, monkeypatch) -> None:
    from jrbar import presence as presence_module
    from tests.test_core_runtime import _TimerAPI

    controller = powered
    controller.settings = controller.settings.with_focus_sync_enabled(True)
    controller.dnd_controller.start()
    armed = len(_TimerAPI.calls)
    core_runtime._cmd_presence(controller, {"focus": True})
    assert controller._core_build_state()["focus"]["source"] == "focus"
    expiries = [
        interval
        for interval, selector, _repeats in _TimerAPI.calls[armed:]
        if selector == "corePresenceExpired:"
    ]
    assert expiries == [pytest.approx(presence_module.PRESENCE_TTL_SECONDS, abs=5)]

    # The app quits and stops reporting: its Focus reading does not keep
    # JR-Bar quiet past the report's own life.
    stale_at = time.time() + presence_module.PRESENCE_TTL_SECONDS + 1
    monkeypatch.setattr(core_power.time, "time", lambda: stale_at)
    controller.dnd_controller._wall_clock = lambda: stale_at
    controller.corePresenceExpired_(None)
    assert controller._core_build_state()["focus"]["source"] is None


def test_an_early_expiry_waits_out_the_rest_of_the_report(powered, monkeypatch) -> None:
    from tests.test_core_runtime import _TimerAPI

    controller = powered
    controller.dnd_controller.start()
    core_runtime._cmd_presence(controller, {"camera": True})
    published = len(controller._core.published)
    armed = len(_TimerAPI.calls)
    # The wall clock stepped back under the timer: the report still stands,
    # so the timer re-arms for what is left and nothing is re-judged.
    controller.corePresenceExpired_(None)
    assert [
        selector for _interval, selector, _repeats in _TimerAPI.calls[armed:]
    ] == ["corePresenceExpired:"]
    assert len(controller._core.published) == published
    assert controller._core_build_state()["presence"]["on_call"] is True


def test_the_focus_document_says_whether_the_helper_can_read_focus(powered) -> None:
    controller = powered
    controller._focus_observation_available = None
    assert controller._core_build_state()["focus"]["named_readable"] is None
    controller._focus_observation_available = False
    assert controller._core_build_state()["focus"]["named_readable"] is False
    controller._focus_observation_available = True
    assert controller._core_build_state()["focus"]["named_readable"] is True


def test_presence_refuses_a_malformed_report(powered) -> None:
    with pytest.raises(CommandError) as error:
        core_runtime._cmd_presence(powered, {"mic": "yes"})
    assert error.value.code == "invalid_args"
    assert core_power.presence_facts(powered) is None
    assert powered._core_build_state()["presence"]["on_call"] is False


def test_the_call_quiet_setting_can_switch_calls_off(powered) -> None:
    controller = powered
    controller.dnd_controller.start()
    reply = core_runtime._cmd_set_setting(controller, {"path": "call_quiet_mode", "value": "off"})
    assert reply["value"] == "off"
    core_runtime._cmd_presence(controller, {"camera": True})
    state = controller._core_build_state()
    assert state["presence"]["on_call"] is True and state["presence"]["quiet"] == "off"
    assert state["focus"]["source"] is None
