"""The daemon-owned keep-awake lease, the thermal governor and the power log.

One hold for every surface: a duration, "until these agents finish", or
until turned off -- yielding (never ending) to heat and to the low-battery
floor, and leaving a record History can list."""

from __future__ import annotations

import json
from pathlib import Path

import pytest

from jrbar.keep_awake import (
    AGENT_LEASE_BACKSTOP_SECONDS,
    LEASE_AGENTS,
    LEASE_DURATION,
    LEASE_END_CANCELLED,
    LEASE_END_EXPIRED,
    LEASE_END_FINISHED,
    LEASE_FILE_NAME,
    LEASE_INDEFINITE,
    MAX_LEASE_SECONDS,
    POWER_LEASE_ENDED,
    POWER_LEASE_STARTED,
    POWER_RESUMED,
    POWER_SUSPENDED,
    THERMAL_CRITICAL,
    THERMAL_FAIR,
    THERMAL_NOMINAL,
    THERMAL_SERIOUS,
    AwakeLease,
    KeepAwakeController,
    LeaseRefusedError,
    PowerLog,
    ThermalGovernor,
    lease_from_args,
    lease_verdict,
    merge_history_rows,
)
from jrbar.models import AgentMode

NOW = 1_800_000_000.0


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


class _Factory:
    def __init__(self) -> None:
        self.processes: list[_Process] = []

    def __call__(self, command, **kwargs) -> _Process:
        process = _Process(command, **kwargs)
        self.processes.append(process)
        return process


class _Clock:
    def __init__(self, now: float = NOW) -> None:
        self.now = now

    def __call__(self) -> float:
        return self.now


def _controller(clock: _Clock, factory: _Factory | None = None, **kwargs) -> KeepAwakeController:
    controller = KeepAwakeController(
        process_factory=factory or _Factory(),
        watch_current_process=False,
        **kwargs,
    )
    controller.wall_clock = clock
    return controller


# --- parsing the command ------------------------------------------------------


def test_lease_from_args_reads_each_shape() -> None:
    lease = lease_from_args({"seconds": 3600}, now=NOW, pending_ids=frozenset())
    assert (lease.kind, lease.until, lease.display, lease.source) == (LEASE_DURATION, NOW + 3600, False, "app")

    lease = lease_from_args(
        {"until": NOW + 7200, "display": True, "source": "chip"}, now=NOW, pending_ids=frozenset()
    )
    assert (lease.kind, lease.until, lease.display, lease.source) == (LEASE_DURATION, NOW + 7200, True, "chip")

    lease = lease_from_args({"indefinite": True}, now=NOW, pending_ids=frozenset())
    assert (lease.kind, lease.until) == (LEASE_INDEFINITE, None)

    # "Until these agents finish" without names waits on everything running
    # now, and is bounded by the backstop.
    lease = lease_from_args(
        {"until_agents_idle": True}, now=NOW, pending_ids=frozenset({"claude:b", "codex:a"})
    )
    assert lease.kind == LEASE_AGENTS
    assert lease.sessions == ("claude:b", "codex:a")
    assert lease.until == NOW + AGENT_LEASE_BACKSTOP_SECONDS

    # Named sessions are narrowed to the ones actually running.
    lease = lease_from_args(
        {"until_agents_idle": True, "sessions": ["codex:a", "gone:1"]},
        now=NOW,
        pending_ids=frozenset({"claude:b", "codex:a"}),
    )
    assert lease.sessions == ("codex:a",)


@pytest.mark.parametrize(
    "args",
    [
        {},
        {"seconds": 60, "indefinite": True},
        {"seconds": "an hour"},
        {"seconds": -5},
        {"seconds": MAX_LEASE_SECONDS + 60},
        {"until": NOW - 1},
        {"indefinite": "yes"},
        {"seconds": 60, "display": "yes"},
        {"seconds": 60, "source": ""},
        {"until_agents_idle": True, "sessions": "claude:b"},
        {"until_agents_idle": True, "sessions": [3]},
    ],
)
def test_lease_from_args_refuses_malformed_requests(args) -> None:
    with pytest.raises(ValueError):
        lease_from_args(args, now=NOW, pending_ids=frozenset({"claude:b"}))


def test_until_agents_finish_is_refused_when_nothing_runs() -> None:
    with pytest.raises(LeaseRefusedError):
        lease_from_args({"until_agents_idle": True}, now=NOW, pending_ids=frozenset())
    with pytest.raises(LeaseRefusedError):
        lease_from_args(
            {"until_agents_idle": True, "sessions": ["gone:1"]},
            now=NOW,
            pending_ids=frozenset({"claude:b"}),
        )


def test_lease_model_rejects_what_it_cannot_bound() -> None:
    with pytest.raises(ValueError):
        AwakeLease(LEASE_DURATION, NOW, None)
    with pytest.raises(ValueError):
        AwakeLease(LEASE_DURATION, NOW, NOW + MAX_LEASE_SECONDS + 3600)
    with pytest.raises(ValueError):
        AwakeLease(LEASE_AGENTS, NOW, NOW + 60)
    with pytest.raises(ValueError):
        AwakeLease(LEASE_INDEFINITE, NOW, NOW + 60)
    with pytest.raises(ValueError):
        AwakeLease(LEASE_DURATION, NOW, NOW + 60, sessions=("claude:b",))
    assert AwakeLease.from_dict({"kind": "forever"}) is None
    assert AwakeLease.from_dict("nope") is None
    lease = AwakeLease(LEASE_AGENTS, NOW, NOW + 60, ("claude:b",), display=True, source="deck")
    assert AwakeLease.from_dict(lease.to_dict()) == lease


def test_lease_verdict_ends_on_time_or_on_a_real_observation() -> None:
    duration = AwakeLease(LEASE_DURATION, NOW, NOW + 60)
    assert lease_verdict(duration, now=NOW + 59, pending_ids=frozenset()) is None
    assert lease_verdict(duration, now=NOW + 60, pending_ids=frozenset()) == LEASE_END_EXPIRED

    agents = AwakeLease(LEASE_AGENTS, NOW, NOW + 3600, ("claude:b", "codex:a"))
    assert lease_verdict(agents, now=NOW, pending_ids=frozenset({"codex:a"})) is None
    assert lease_verdict(agents, now=NOW, pending_ids=frozenset({"other"})) == LEASE_END_FINISHED
    # Nobody has looked yet: never a finish.
    assert lease_verdict(agents, now=NOW, pending_ids=None) is None
    assert lease_verdict(agents, now=NOW + 3600, pending_ids=None) == LEASE_END_EXPIRED


# --- the controller ------------------------------------------------------------


def test_a_lease_holds_with_no_agents_and_ends_when_its_time_is_up() -> None:
    clock = _Clock()
    factory = _Factory()
    # No agent grace: the first rest mode ever seen would otherwise open one.
    controller = _controller(clock, factory, grace_seconds=0)
    controller.power_log = PowerLog(clock=clock)
    controller.start_lease(AwakeLease(LEASE_DURATION, NOW, NOW + 3600))

    assert controller.update(AgentMode.IDLE_READY)
    assert controller.holding_requested is True
    assert controller.hold_state() == "manual"
    assert factory.processes[-1].command == ("/usr/bin/caffeinate", "-ims", "-t", "1800")

    clock.now = NOW + 3600
    assert not controller.update(AgentMode.IDLE_READY)
    assert controller.lease is None
    assert controller.hold_state() == "off"
    assert factory.processes[-1].terminated
    ended = controller.power_log.last(POWER_LEASE_ENDED)
    assert ended is not None and ended.reason == LEASE_END_EXPIRED and ended.duration == 3600


def test_a_lease_outranks_the_agent_toggle_and_the_battery_preference() -> None:
    clock = _Clock()
    controller = _controller(clock)
    controller.set_enabled(False)
    controller.start_lease(AwakeLease(LEASE_INDEFINITE, NOW, None))
    # "Keep awake on battery" is about the agents; the person asked.
    assert controller.update(AgentMode.IDLE_READY, on_battery=True, hold_on_battery=False)
    assert controller.process_running()
    assert controller.end_lease() is True
    assert not controller.update(AgentMode.IDLE_READY, on_battery=True, hold_on_battery=False)
    assert controller.end_lease() is False


def test_until_these_agents_finish_follows_the_sessions() -> None:
    clock = _Clock()
    controller = _controller(clock)
    controller.power_log = PowerLog(clock=clock)
    controller.start_lease(AwakeLease(LEASE_AGENTS, NOW, NOW + 3600, ("claude:b",)))

    controller.observe_environment(pending_ids={"claude:b"}, working_count=1)
    assert controller.update(AgentMode.WORKING)
    # An ask is not a finish.
    controller.observe_environment(pending_ids={"claude:b"}, working_count=0)
    assert controller.update(AgentMode.WAITING_FOR_INPUT)
    assert controller.lease is not None

    controller.observe_environment(pending_ids=set(), working_count=0)
    controller.update(AgentMode.COMPLETED)
    assert controller.lease is None
    assert controller.power_log.last(POWER_LEASE_ENDED).reason == LEASE_END_FINISHED


def test_a_display_lease_holds_the_screen_and_gives_it_back() -> None:
    clock = _Clock()
    factory = _Factory()
    controller = _controller(clock, factory)
    assert controller.update(AgentMode.WORKING)
    assert factory.processes[-1].command[1] == "-ims"

    controller.start_lease(AwakeLease(LEASE_DURATION, NOW, NOW + 600, display=True))
    assert controller.update(AgentMode.WORKING)
    assert factory.processes[-2].terminated
    assert factory.processes[-1].command[1] == "-dims"
    assert controller.hold_document()["display"] is True

    controller.end_lease()
    assert controller.update(AgentMode.WORKING)
    assert factory.processes[-1].command[1] == "-ims"
    assert len(factory.processes) == 3


def test_heat_and_the_battery_floor_suspend_every_hold_without_ending_the_lease() -> None:
    clock = _Clock()
    controller = _controller(clock)
    controller.power_log = PowerLog(clock=clock)
    controller.thermal = ThermalGovernor(resume_after_seconds=60)
    controller.start_lease(AwakeLease(LEASE_DURATION, NOW, NOW + 7200))

    # Serious with the lid open is the fans' job; with the lid shut it is not.
    controller.observe_environment(thermal_state=THERMAL_SERIOUS, lid_closed=False)
    assert controller.update(AgentMode.WORKING, now=0.0)
    controller.observe_environment(thermal_state=THERMAL_SERIOUS, lid_closed=True)
    assert not controller.update(AgentMode.WORKING, now=1.0)
    assert controller.holding_requested is False
    assert controller.suspension == "thermal"
    assert controller.lease is not None
    assert controller.power_log.last(POWER_SUSPENDED).reason == "thermal"
    assert controller.hold_document()["suspended"] == "thermal"
    assert controller.hold_document()["thermal"] == "serious"

    # Cooling to fair is not enough on its own: it has to stay cool.
    controller.observe_environment(thermal_state=THERMAL_FAIR, lid_closed=True)
    assert not controller.update(AgentMode.WORKING, now=2.0)
    assert controller.update(AgentMode.WORKING, now=70.0)
    assert controller.power_log.last(POWER_RESUMED).reason == "thermal"

    controller.observe_environment(battery_floor=True, thermal_state=THERMAL_NOMINAL)
    assert not controller.update(AgentMode.WORKING, now=71.0)
    assert controller.suspension == "battery"
    assert controller.lease is not None


def test_heat_on_an_idle_mac_is_not_news() -> None:
    clock = _Clock()
    controller = _controller(clock, grace_seconds=0)
    controller.power_log = PowerLog(clock=clock)
    controller.observe_environment(thermal_state=THERMAL_CRITICAL)
    assert not controller.update(AgentMode.IDLE_READY)
    assert controller.power_log.last(POWER_SUSPENDED) is None


def test_the_thermal_governor_never_acts_on_an_unreadable_sensor() -> None:
    governor = ThermalGovernor(resume_after_seconds=10)
    assert governor.observe(None, lid_closed=True, now=0) is False
    assert governor.observe(THERMAL_CRITICAL, lid_closed=False, now=1) is True
    assert governor.observe(None, lid_closed=False, now=100) is True
    # Still serious (below the open-lid limit) keeps it released.
    assert governor.observe(THERMAL_SERIOUS, lid_closed=False, now=101) is True
    assert governor.observe(THERMAL_NOMINAL, lid_closed=False, now=102) is True
    assert governor.observe(THERMAL_NOMINAL, lid_closed=False, now=112) is False


def test_the_legacy_semantics_of_holding_requested_survive() -> None:
    """With no lease and no environment reported, the agent demand is what
    it always was -- the closed-lid policy reads it even when the ordinary
    agent hold is switched off."""
    controller = _controller(_Clock())
    controller.set_enabled(False)
    assert not controller.update(AgentMode.WORKING)
    assert controller.holding_requested is True
    assert controller.hold_state() == "off"


def test_the_hold_document_counts_agents_and_its_grace() -> None:
    clock = _Clock()
    controller = _controller(clock, grace_seconds=300)
    controller.observe_environment(pending_ids={"a", "b"}, working_count=2)
    controller.update(AgentMode.WORKING, now=100.0)
    document = controller.hold_document(now_monotonic=100.0)
    assert document["state"] == "agents" and document["agents"] == 2
    assert document["grace_until"] is None and document["lease"] is None

    controller.update(AgentMode.COMPLETED, now=110.0)
    document = controller.hold_document(now_monotonic=110.0)
    assert document["state"] == "agents"
    assert document["grace_until"] == pytest.approx(NOW + 300)


# --- persistence -------------------------------------------------------------------


def test_a_lease_survives_a_daemon_restart_and_an_expired_one_does_not(tmp_path: Path) -> None:
    clock = _Clock()
    first = _controller(clock)
    first.attach_store(tmp_path)
    first.start_lease(AwakeLease(LEASE_DURATION, NOW, NOW + 600, source="chip"))
    assert json.loads((tmp_path / LEASE_FILE_NAME).read_text())["source"] == "chip"

    second = _controller(clock)
    second.attach_store(tmp_path)
    assert second.lease == first.lease

    clock.now = NOW + 601
    third = _controller(clock)
    third.attach_store(tmp_path)
    assert third.lease is None
    assert not (tmp_path / LEASE_FILE_NAME).exists()


def test_the_power_log_is_bounded_persisted_and_reads_as_history(tmp_path: Path) -> None:
    clock = _Clock()
    log = PowerLog(tmp_path / "power-log.json", limit=3, clock=clock)
    log.record(POWER_LEASE_STARTED, reason="duration")
    clock.now += 10
    log.record(POWER_SUSPENDED, reason="thermal")
    clock.now += 10
    log.record(POWER_LEASE_ENDED, reason=LEASE_END_CANCELLED)
    clock.now += 10
    log.record(POWER_LEASE_ENDED, reason=LEASE_END_EXPIRED, duration=30)
    assert [event.kind for event in log.events] == [POWER_SUSPENDED, POWER_LEASE_ENDED, POWER_LEASE_ENDED]

    reloaded = PowerLog(tmp_path / "power-log.json", clock=clock)
    reloaded.load()
    assert reloaded.events == log.events

    rows = reloaded.history_rows(last_seen=NOW + 15)
    # A cancelled lease is the person's own doing: not news.
    assert [(row["label"], row["detail"]) for row in rows] == [
        ("Keep awake ended", "time up"),
        ("Keep awake let go", "Mac too hot"),
    ]
    assert rows[0]["kind"] == "power" and rows[0]["duration"] == 30
    assert [row["unseen"] for row in rows] == [True, False]
    assert reloaded.history_rows(since=NOW + 25)[0]["detail"] == "time up"
    assert len(reloaded.history_rows(since=NOW + 25)) == 1


def test_a_damaged_power_log_starts_empty(tmp_path: Path) -> None:
    path = tmp_path / "power-log.json"
    path.write_text("{not json")
    path.chmod(0o600)
    log = PowerLog(path)
    log.load()
    assert log.events == () and log.last_error


def test_history_rows_merge_newest_first_within_the_limit() -> None:
    rows = [{"at": 30.0, "kind": "completed"}, {"at": 10.0, "kind": "asked"}]
    power = [{"at": 20.0, "kind": "power"}]
    merged = merge_history_rows(rows, power, limit=2)
    assert [row["kind"] for row in merged] == ["completed", "power"]
