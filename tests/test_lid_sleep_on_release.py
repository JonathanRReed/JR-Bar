"""Closed-lid release: a shut, displayless laptop sleeps when the agents
finish, heat and a dying battery outrank even "Always stay awake", and the
held stretch is written down for History."""

from __future__ import annotations

from pathlib import Path
from types import SimpleNamespace

import pytest

from jrbar import lid_sleep
from jrbar.keep_awake import PowerLog
from jrbar.lid_sleep import (
    ClosedLidAwakeController,
    SystemSleepSuppressedError,
    parse_bool_ioreg_property,
    read_clamshell_causes_sleep,
    run_pmset_sleepnow,
    system_sleep_suppressed,
)
from jrbar.settings import (
    CLOSED_LID_AWAKE_AGENTS,
    CLOSED_LID_AWAKE_ALWAYS,
    CLOSED_LID_AWAKE_NEVER,
)


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


class _Clock:
    def __init__(self, now: float = 1_800_000_000.0) -> None:
        self.now = now

    def __call__(self) -> float:
        return self.now


def _controller(tmp_path: Path, *, lid_closed, causes_sleep, clock=None):
    slept: list[bool] = []
    controller = ClosedLidAwakeController(
        process_factory=_Process,
        watch_current_process=False,
        renewal_path=tmp_path / "renewal",
    )
    controller.wall_clock = clock or _Clock()
    controller.power_log = PowerLog(clock=controller.wall_clock)
    controller.configure_sleep_on_release(
        lid_closed_reader=lid_closed,
        clamshell_sleep_reader=causes_sleep,
        sleeper=lambda: slept.append(True),
    )
    return controller, slept


def test_the_hold_dropping_with_the_lid_shut_sleeps_the_mac(tmp_path: Path) -> None:
    clock = _Clock()
    controller, slept = _controller(
        tmp_path, lid_closed=lambda: True, causes_sleep=lambda: True, clock=clock
    )
    assert controller.update(CLOSED_LID_AWAKE_AGENTS, agents_active=True)
    clock.now += 9600
    # Every tick while held is not a release.
    controller.update(CLOSED_LID_AWAKE_AGENTS, agents_active=True)
    assert slept == []

    assert not controller.update(CLOSED_LID_AWAKE_AGENTS, agents_active=False)
    assert slept == [True]
    assert controller.last_sleep_epoch == clock.now
    kinds = [(event.kind, event.reason, event.duration) for event in controller.power_log.events]
    assert kinds == [("lid_hold_ended", "agents_idle", 9600.0), ("slept", "agents_idle", None)]

    # Released stays released: no second sleep on the next tick.
    controller.update(CLOSED_LID_AWAKE_AGENTS, agents_active=False)
    assert slept == [True]


@pytest.mark.parametrize(
    ("lid_closed", "causes_sleep"),
    [
        (lambda: False, lambda: True),  # lid open: the person is here
        (lambda: True, lambda: False),  # clamshell on an external display
        (lambda: None, lambda: True),  # unreadable lid
        (lambda: True, lambda: None),  # unreadable clamshell rule
        (lambda: (_ for _ in ()).throw(OSError("ioreg")), lambda: True),
    ],
)
def test_no_sleep_unless_both_readings_agree(tmp_path: Path, lid_closed, causes_sleep) -> None:
    controller, slept = _controller(tmp_path, lid_closed=lid_closed, causes_sleep=causes_sleep)
    controller.update(CLOSED_LID_AWAKE_AGENTS, agents_active=True)
    controller.update(CLOSED_LID_AWAKE_AGENTS, agents_active=False)
    assert slept == []


def test_heat_releases_even_always_stay_awake(tmp_path: Path) -> None:
    controller, slept = _controller(tmp_path, lid_closed=lambda: True, causes_sleep=lambda: True)
    reason = {"value": None}
    controller.governor = lambda: reason["value"]
    assert controller.update(CLOSED_LID_AWAKE_ALWAYS, agents_active=False)

    reason["value"] = "thermal"
    assert not controller.update(CLOSED_LID_AWAKE_ALWAYS, agents_active=False)
    assert slept == [True]
    assert controller.last_release_reason == "thermal"
    assert controller.power_log.last("slept").reason == "thermal"

    reason["value"] = None
    assert controller.update(CLOSED_LID_AWAKE_ALWAYS, agents_active=False)


def test_a_failed_sleep_is_recorded_not_raised(tmp_path: Path) -> None:
    controller = ClosedLidAwakeController(
        process_factory=_Process,
        watch_current_process=False,
        renewal_path=tmp_path / "renewal",
    )

    def refuse() -> None:
        raise RuntimeError("pmset sleepnow failed")

    controller.configure_sleep_on_release(
        lid_closed_reader=lambda: True,
        clamshell_sleep_reader=lambda: True,
        sleeper=refuse,
    )
    controller.update(CLOSED_LID_AWAKE_AGENTS, agents_active=True)
    controller.update(CLOSED_LID_AWAKE_AGENTS, agents_active=False)
    assert controller.last_sleep_error == "pmset sleepnow failed"
    assert controller.last_sleep_epoch is None


def test_switching_the_policy_off_names_the_reason(tmp_path: Path) -> None:
    controller, slept = _controller(tmp_path, lid_closed=lambda: True, causes_sleep=lambda: False)
    controller.update(CLOSED_LID_AWAKE_ALWAYS, agents_active=False)
    controller.update(CLOSED_LID_AWAKE_NEVER, agents_active=False)
    assert controller.last_release_reason == "policy"
    assert controller.power_log.last("lid_hold_ended").reason == "policy"
    assert slept == []


def test_an_unwired_controller_never_sleeps(tmp_path: Path) -> None:
    """The menu-bar app and older callers construct the controller without
    the daemon's wiring; the release there is exactly what it always was."""
    controller = ClosedLidAwakeController(
        process_factory=_Process,
        watch_current_process=False,
        renewal_path=tmp_path / "renewal",
    )
    controller.update(CLOSED_LID_AWAKE_AGENTS, agents_active=True)
    assert not controller.update(CLOSED_LID_AWAKE_AGENTS, agents_active=False)
    assert controller.last_sleep_epoch is None


def test_the_real_sleeper_refuses_inside_the_test_sandbox() -> None:
    calls: list[list[str]] = []
    assert system_sleep_suppressed() is True
    with pytest.raises(SystemSleepSuppressedError):
        run_pmset_sleepnow(runner=lambda command, **_kwargs: calls.append(command))
    assert calls == []


def test_the_sleeper_runs_pmset_sleepnow_without_sudo(monkeypatch: pytest.MonkeyPatch) -> None:
    calls: list[list[str]] = []
    monkeypatch.setattr(lid_sleep, "system_sleep_suppressed", lambda: False)

    def runner(command, **_kwargs):
        calls.append(command)
        return SimpleNamespace(returncode=0, stdout="", stderr="")

    run_pmset_sleepnow(runner=runner)
    assert calls == [["/usr/bin/pmset", "sleepnow"]]

    def failing(command, **_kwargs):
        return SimpleNamespace(returncode=1, stdout="", stderr="Sleep refused\nmore")

    with pytest.raises(RuntimeError, match="Sleep refused"):
        run_pmset_sleepnow(runner=failing)


def test_the_clamshell_rule_reads_through_ioreg() -> None:
    text = '  | |   "AppleClamshellCausesSleep" = Yes\n'
    assert parse_bool_ioreg_property(text, "AppleClamshellCausesSleep") is True

    def runner(command, **_kwargs):
        assert command[-3] == "AppleClamshellCausesSleep"
        return SimpleNamespace(stdout='"AppleClamshellCausesSleep" = No')

    assert read_clamshell_causes_sleep(runner=runner) is False
