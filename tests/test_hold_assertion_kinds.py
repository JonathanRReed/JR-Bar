"""Which assertion every keep-awake hold takes: the computer, not the
screen, unless the person asked for the display too -- and never the
display with the lid shut on no external screen.

``caffeinate -ims`` keeps the Mac running (idle, disk and system sleep);
``-d`` would hold the display as well. Every hold runs on a fake process,
so no test takes a real assertion."""

from __future__ import annotations

from dataclasses import replace

import pytest

from jrbar.keep_awake import (
    AGENT_LEASE_BACKSTOP_SECONDS,
    LEASE_AGENTS,
    LEASE_DURATION,
    LEASE_INDEFINITE,
    LEASE_PROCESS,
    MAX_LEASE_SECONDS,
    AwakeLease,
)
from jrbar.lid_sleep import ClosedLidAwakeController
from jrbar.models import AgentMode
from jrbar.power_policy import apply_power_hold_settings, display_hold_wanted
from jrbar.process_watch import ProcessIdentity
from jrbar.settings import CLOSED_LID_AWAKE_AGENTS, AgentMonitorSettings
from tests.test_keep_awake_lease import NOW, _Clock, _controller, _Factory

COMPUTER = "-ims"
COMPUTER_AND_DISPLAY = "-dims"


class _Watch:
    def __init__(self, pid, on_exit) -> None:
        self.pid = pid

    def cancel(self) -> None:
        pass


def _leases() -> list[AwakeLease]:
    return [
        AwakeLease(LEASE_DURATION, NOW, NOW + 3600),
        AwakeLease(LEASE_INDEFINITE, NOW, None),
        AwakeLease(LEASE_AGENTS, NOW, NOW + AGENT_LEASE_BACKSTOP_SECONDS, ("claude:a",)),
        AwakeLease(LEASE_PROCESS, NOW, NOW + MAX_LEASE_SECONDS, pid=4242, process_started=1, label="swift"),
    ]


def _ordinary(factory: _Factory, *, keep_display_awake: bool = False):
    controller = _controller(_Clock(), factory, grace_seconds=0, keep_display_awake=keep_display_awake)
    controller.process_watch_factory = _Watch
    controller.process_identity = lambda pid: ProcessIdentity(pid, 1, "swift")
    controller.observe_environment(pending_ids={"claude:a"}, working_count=1)
    return controller


def _lid(factory: _Factory, *, keep_display_awake: bool = False, external: bool | None = False):
    controller = ClosedLidAwakeController(
        process_factory=factory,
        watch_current_process=False,
        sleep_disabled_reader=lambda: False,
        sleep_disabled_setter=lambda _on: None,
        keep_display_awake=keep_display_awake,
        renewal_path=None,
    )
    controller.external_display_reader = lambda: external
    return controller


def _caffeinate(factory: _Factory) -> list[tuple[str, ...]]:
    return [process.command for process in factory.processes if process.command[0] == "/usr/bin/caffeinate"]


# --- the defaults --------------------------------------------------------------


def test_the_settings_default_holds_the_computer_only() -> None:
    settings = AgentMonitorSettings()
    assert settings.keep_display_awake is False
    ordinary_factory, lid_factory = _Factory(), _Factory()
    ordinary = _ordinary(ordinary_factory, keep_display_awake=True)
    lid = _lid(lid_factory, keep_display_awake=True)
    apply_power_hold_settings(ordinary, lid, settings)
    assert ordinary.keep_display_awake is False
    assert lid.keep_display_awake is False


def test_the_agents_hold_takes_the_computer_only_by_default() -> None:
    factory = _Factory()
    controller = _ordinary(factory)
    assert controller.update(AgentMode.WORKING)
    assert factory.processes[-1].command[1] == COMPUTER
    assert controller.hold_document()["display"] is False


@pytest.mark.parametrize("lease", _leases(), ids=lambda lease: lease.kind)
def test_every_manual_lease_takes_the_computer_only_by_default(lease) -> None:
    factory = _Factory()
    controller = _ordinary(factory)
    controller.start_lease(lease)
    assert controller.update(AgentMode.IDLE_READY)
    assert factory.processes[-1].command[1] == COMPUTER


# --- the display on purpose -------------------------------------------------------


def test_the_display_setting_adds_the_display_to_the_agents_hold() -> None:
    factory = _Factory()
    controller = _ordinary(factory, keep_display_awake=True)
    assert controller.update(AgentMode.WORKING)
    assert factory.processes[-1].command[1] == COMPUTER_AND_DISPLAY


@pytest.mark.parametrize("lease", _leases(), ids=lambda lease: lease.kind)
def test_a_display_lease_adds_the_display(lease) -> None:
    factory = _Factory()
    controller = _ordinary(factory)
    controller.start_lease(replace(lease, display=True))
    assert controller.update(AgentMode.IDLE_READY)
    assert factory.processes[-1].command[1] == COMPUTER_AND_DISPLAY


# --- the lid ---------------------------------------------------------------------


@pytest.mark.parametrize(
    ("lid_closed", "external", "flags"),
    [
        (None, None, COMPUTER_AND_DISPLAY),
        (False, None, COMPUTER_AND_DISPLAY),
        (True, False, COMPUTER),
        (True, None, COMPUTER),
        (True, True, COMPUTER_AND_DISPLAY),
    ],
)
def test_a_shut_lid_lets_the_display_sleep_unless_a_screen_is_on(lid_closed, external, flags) -> None:
    assert display_hold_wanted(True, lid_closed=lid_closed, external_display=external) is (
        flags == COMPUTER_AND_DISPLAY
    )
    factory = _Factory()
    controller = _ordinary(factory, keep_display_awake=True)
    controller.observe_environment(
        pending_ids={"claude:a"}, working_count=1, lid_closed=lid_closed, external_display=external
    )
    assert controller.update(AgentMode.WORKING)
    assert factory.processes[-1].command[1] == flags


def test_the_display_setting_off_never_holds_the_display() -> None:
    for lid_closed in (None, False, True):
        for external in (None, False, True):
            assert display_hold_wanted(False, lid_closed=lid_closed, external_display=external) is False


def test_closing_the_lid_retakes_the_agents_hold_without_the_display() -> None:
    factory = _Factory()
    controller = _ordinary(factory, keep_display_awake=True)
    assert controller.update(AgentMode.WORKING)
    assert factory.processes[-1].command[1] == COMPUTER_AND_DISPLAY
    controller.observe_environment(pending_ids={"claude:a"}, working_count=1, lid_closed=True, external_display=False)
    assert controller.update(AgentMode.WORKING)
    assert factory.processes[-2].terminated
    assert factory.processes[-1].command[1] == COMPUTER
    assert controller.process_running(), "the computer stays held"
    controller.observe_environment(pending_ids={"claude:a"}, working_count=1, lid_closed=False)
    assert controller.update(AgentMode.WORKING)
    assert factory.processes[-1].command[1] == COMPUTER_AND_DISPLAY


def test_the_closed_lid_hold_takes_the_computer_only_by_default(tmp_path) -> None:
    factory = _Factory()
    lid = _lid(factory)
    lid.renewal_path = tmp_path / "renewal"
    lid.watchdog_pid_path = tmp_path / "watchdog.pid"
    lid.observe_lid(True)
    assert lid.update(CLOSED_LID_AWAKE_AGENTS, agents_active=True)
    assert _caffeinate(factory)[-1][1] == COMPUTER
    lid.release()


@pytest.mark.parametrize(
    ("lid_closed", "external", "flags"),
    [
        (False, None, COMPUTER_AND_DISPLAY),
        (True, False, COMPUTER),
        (True, True, COMPUTER_AND_DISPLAY),
    ],
)
def test_the_closed_lid_hold_follows_the_lid_for_the_display(tmp_path, lid_closed, external, flags) -> None:
    factory = _Factory()
    lid = _lid(factory, keep_display_awake=True, external=external)
    lid.renewal_path = tmp_path / "renewal"
    lid.watchdog_pid_path = tmp_path / "watchdog.pid"
    lid.observe_lid(lid_closed)
    assert lid.update(CLOSED_LID_AWAKE_AGENTS, agents_active=True)
    assert _caffeinate(factory)[-1][1] == flags
    lid.release()


def test_shutting_the_lid_drops_the_closed_lid_hold_s_display(tmp_path) -> None:
    factory = _Factory()
    lid = _lid(factory, keep_display_awake=True, external=False)
    lid.renewal_path = tmp_path / "renewal"
    lid.watchdog_pid_path = tmp_path / "watchdog.pid"
    lid.observe_lid(False)
    assert lid.update(CLOSED_LID_AWAKE_AGENTS, agents_active=True)
    assert _caffeinate(factory)[-1][1] == COMPUTER_AND_DISPLAY
    lid.observe_lid(True)
    assert lid.update(CLOSED_LID_AWAKE_AGENTS, agents_active=True)
    assert _caffeinate(factory)[-1][1] == COMPUTER
    assert lid.process_running(), "the computer stays held with the lid shut"
    lid.release()
