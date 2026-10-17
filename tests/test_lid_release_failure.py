"""Closed-lid release failures keep ownership and defer completion."""

import subprocess
from pathlib import Path

import pytest

from jrbar.keep_awake import PowerLog
from jrbar.lid_sleep import ClosedLidAwakeController
from jrbar.settings import CLOSED_LID_AWAKE_AGENTS as ON
from jrbar.settings import CLOSED_LID_AWAKE_NEVER as OFF


class Process:
    def __init__(self, command):
        self.command = tuple(command)
        self.alive = True
        self.refuse = False
        self.ignore_terminate = False
        self.ignore_kill = False
        self.terminations = 0
        self.kills = 0
        self.waits = []

    def poll(self):
        return None if self.alive else 0

    def terminate(self):
        self.terminations += 1
        if self.refuse:
            raise PermissionError("synthetic terminate refused")
        if not self.ignore_terminate:
            self.alive = False

    def kill(self):
        self.kills += 1
        if self.refuse:
            raise PermissionError("synthetic kill refused")
        if not self.ignore_kill:
            self.alive = False

    def wait(self, timeout=None):
        self.waits.append(timeout)
        if self.alive:
            raise subprocess.TimeoutExpired("synthetic child", timeout)
        return 0


class Rig:
    def __init__(self, directory: Path, *, disabled=False):
        self.children = []
        self.disabled = disabled
        self.refuse_clear = False
        self.settings = []
        self.sleeps = []
        self.now = 1000.0
        self.keep = ClosedLidAwakeController(
            process_factory=self.spawn,
            sleep_disabled_reader=lambda: self.disabled,
            sleep_disabled_setter=self.set_disabled,
            use_system_disable=True,
            watch_current_process=False,
            renewal_path=directory / "renewal",
            watchdog_pid_path=directory / "watchdog.pid",
        )
        self.keep.wall_clock = lambda: self.now
        self.keep.power_log = PowerLog(clock=lambda: self.now)
        self.keep.configure_sleep_on_release(
            lid_closed_reader=lambda: True,
            clamshell_sleep_reader=lambda: True,
            sleeper=lambda: self.sleeps.append(self.now),
        )

    def spawn(self, command, **_kwargs):
        child = Process(command)
        self.children.append(child)
        return child

    def set_disabled(self, value):
        self.settings.append(value)
        if not value and self.refuse_clear:
            raise PermissionError("synthetic disable clear refused")
        self.disabled = value

    def update(self, on):
        return self.keep.update(ON if on else OFF, agents_active=on)

    def caffeinates(self):
        return [p for p in self.children if p.command[0] != "/bin/sh"]

    def watchdogs(self):
        return [p for p in self.children if p.command[0] == "/bin/sh"]


@pytest.mark.parametrize("role", ["caffeinate", "watchdog"])
def test_failed_child_release_retains_handle_and_next_off_retries(tmp_path, role):
    rig = Rig(tmp_path)
    rig.update(True)
    child = rig.caffeinates()[0] if role == "caffeinate" else rig.watchdogs()[0]
    child.refuse = True
    rig.update(False)
    owned = rig.keep.process if role == "caffeinate" else rig.keep.watchdog_process
    assert owned is child
    assert rig.keep.last_error and "synthetic kill refused" in rig.keep.last_error
    child.refuse = False
    rig.update(False)
    assert not child.alive
    assert child.terminations == 2
    assert rig.keep.last_error is None


def test_failed_release_defers_sleep_and_history_until_recovery(tmp_path):
    rig = Rig(tmp_path)
    rig.update(True)
    child = rig.caffeinates()[0]
    child.refuse = True
    rig.now += 10
    rig.update(False)
    assert rig.keep.active()
    assert rig.keep.held_since == 1000
    assert rig.sleeps == []
    assert not rig.keep.power_log.events
    child.refuse = False
    rig.now += 10
    rig.update(False)
    assert rig.sleeps == [1020]
    assert [(e.kind, e.reason, e.duration) for e in rig.keep.power_log.events] == [
        ("lid_hold_ended", "policy", 20), ("slept", "policy", None)
    ]
    rig.update(False)
    assert rig.sleeps == [1020]


def test_system_disable_failure_defers_completion_and_keeps_original_reason(tmp_path):
    rig = Rig(tmp_path)
    rig.update(True)
    rig.refuse_clear = True
    rig.now += 10
    rig.update(False)
    assert rig.keep.active()
    assert rig.sleeps == []
    assert rig.keep.held_since == 1000
    rig.refuse_clear = False
    rig.now += 10
    rig.update(False)
    assert rig.sleeps == [1020]
    assert rig.keep.power_log.events[0].reason == "policy"
    assert rig.keep.power_log.events[0].duration == 20


@pytest.mark.parametrize("failure", ["caffeinate", "disablesleep"])
def test_new_demand_cancels_pending_release_without_sleeping(tmp_path, failure):
    rig = Rig(tmp_path)
    rig.update(True)
    child = rig.caffeinates()[0]
    child.refuse = failure == "caffeinate"
    rig.refuse_clear = failure == "disablesleep"
    rig.update(False)
    rig.now += 10
    rig.update(True)
    assert rig.sleeps == []
    assert rig.keep.last_error is None
    if failure == "caffeinate":
        assert rig.caffeinates() == [child]
    child.refuse = False
    rig.refuse_clear = False
    rig.update(False)
    assert rig.sleeps == [1010]
    assert rig.keep.power_log.events[0].duration == 10


def test_direct_shutdown_release_does_not_invoke_sleep_or_history(tmp_path):
    rig = Rig(tmp_path)
    rig.update(True)
    rig.keep.release()
    assert not rig.keep.active()
    assert rig.sleeps == []
    assert not rig.keep.power_log.events


def test_failed_sleep_is_not_retried_by_subsequent_off_updates(tmp_path):
    rig = Rig(tmp_path)
    rig.update(True)
    attempts = []

    def refused_sleep():
        attempts.append(True)
        raise PermissionError("synthetic sleep refused")

    rig.keep.sleeper = refused_sleep
    rig.update(False)
    rig.update(False)
    assert attempts == [True]
    assert [event.kind for event in rig.keep.power_log.events] == ["lid_hold_ended"]
    assert rig.keep.last_sleep_error == "synthetic sleep refused"


def test_retiring_watchdog_cannot_protect_new_system_disable(tmp_path):
    rig = Rig(tmp_path)
    rig.update(True)
    watchdog = rig.watchdogs()[0]
    rig.keep.watchdog_pid_path.write_text("synthetic pid")
    watchdog.refuse = True
    rig.update(False)
    assert not rig.keep.watchdog_pid_path.exists()
    rig.update(True)
    assert rig.settings == [True, False]
    assert len(rig.watchdogs()) == 1
    assert rig.keep.last_error and "watchdog" in rig.keep.last_error
    watchdog.refuse = False
    rig.update(True)
    assert not watchdog.alive
    assert len(rig.watchdogs()) == 2
    assert rig.settings == [True, False, True]


def test_failed_display_replacement_retries_without_duplicate_child(tmp_path):
    rig = Rig(tmp_path)
    rig.update(True)
    child = rig.caffeinates()[0]
    child.refuse = True
    rig.keep.set_keep_display_awake(True)
    rig.update(True)
    assert len(rig.caffeinates()) == 1
    assert rig.keep.last_error and "caffeinate" in rig.keep.last_error
    child.refuse = False
    rig.update(True)
    assert len(rig.caffeinates()) == 2
    assert not child.alive
    assert "-d" in rig.caffeinates()[1].command[1]


def test_successful_kill_request_still_requires_confirmed_exit(tmp_path):
    rig = Rig(tmp_path)
    rig.update(True)
    child = rig.caffeinates()[0]
    child.ignore_terminate = True
    child.ignore_kill = True
    rig.update(False)
    assert rig.keep.process is child
    assert rig.keep.active()
    assert child.waits == [1, 1]
    assert rig.sleeps == []
    child.alive = False
    rig.update(False)
    assert rig.keep.process is None
    assert rig.sleeps == [1000]


def test_failed_orphan_reclaim_is_active_and_retries_next_off(tmp_path):
    rig = Rig(tmp_path, disabled=True)
    rig.refuse_clear = True
    rig.update(False)
    assert rig.keep.active()
    assert rig.keep.last_error and "synthetic disable clear refused" in rig.keep.last_error
    rig.refuse_clear = False
    rig.update(False)
    assert rig.settings == [False, False]
    assert not rig.keep.active()
    assert rig.keep.last_error is None
    assert rig.sleeps == []
