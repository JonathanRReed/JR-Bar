"""The lid-hold fail-safe: a hold whose renewals stop must die alone.

The burn: release depended entirely on the app's own sync tick, and a
tick that stops (display-asleep App Nap, a wedge, a bootout mid-hold)
left `pmset disablesleep 1` burning a closed laptop all night."""

from __future__ import annotations

import os
import subprocess
import threading
import time
from pathlib import Path

import pytest

from jrbar.lid_sleep import (
    CAFFEINATE_CLOSED_LID_COMMAND,
    RENEWAL_STALE_SECONDS,
    WATCHDOG_PID_FILE_NAME,
    WATCHDOG_POLL_SECONDS,
    ClosedLidAwakeController,
    watchdog_script,
)
from jrbar.settings import CLOSED_LID_AWAKE_AGENTS, CLOSED_LID_AWAKE_NEVER


class FakeProcess:
    def __init__(self, argv):
        self.argv = argv
        self.terminated = False

    def poll(self):
        return 1 if self.terminated else None

    def terminate(self):
        self.terminated = True

    def kill(self):
        self.terminated = True

    def wait(self, timeout=None):
        return 0


def _controller(tmp_path: Path, spawned: list):
    def factory(argv, **_kwargs):
        process = FakeProcess(argv)
        spawned.append(process)
        return process

    return ClosedLidAwakeController(
        process_factory=factory,
        sleep_disabled_reader=lambda: False,
        sleep_disabled_setter=lambda _enabled: None,
        use_system_disable=True,
        renewal_path=tmp_path / "lid-hold-renewal",
    )


def test_holding_writes_the_heartbeat_and_spawns_the_watchdog__and_1_more(tmp_path) -> None:
    # --- scenario: holding_writes_the_heartbeat_and_spawns_the_watchdog
    spawned: list[FakeProcess] = []
    controller = _controller(tmp_path, spawned)
    controller.update(CLOSED_LID_AWAKE_AGENTS, agents_active=True)

    assert (tmp_path / "lid-hold-renewal").exists()
    watchdog = [p for p in spawned if p.argv[0] == "/bin/sh"]
    assert len(watchdog) == 1
    script = watchdog[0].argv[2]
    assert "pmset -a disablesleep 0" in script
    assert str(RENEWAL_STALE_SECONDS) in script
    # One watchdog per hold, not one per tick.
    controller.update(CLOSED_LID_AWAKE_AGENTS, agents_active=True)
    assert len([p for p in spawned if p.argv[0] == "/bin/sh"]) == 1

    # --- scenario: clean_release_retires_the_heartbeat
    spawned: list[FakeProcess] = []
    controller = _controller(tmp_path, spawned)
    controller.update(CLOSED_LID_AWAKE_AGENTS, agents_active=True)
    assert (tmp_path / "lid-hold-renewal").exists()

    controller.update(CLOSED_LID_AWAKE_NEVER, agents_active=False)
    assert not (tmp_path / "lid-hold-renewal").exists()


def test_normal_release_leaves_no_watchdog(tmp_path) -> None:
    spawned: list[FakeProcess] = []
    controller = _controller(tmp_path, spawned)
    controller.update(CLOSED_LID_AWAKE_AGENTS, agents_active=True)

    pidfile = tmp_path / WATCHDOG_PID_FILE_NAME
    # The spawned script records itself here; fake that so release must
    # clean it up.
    pidfile.write_text("4242\n")
    watchdog = next(p for p in spawned if p.argv[0] == "/bin/sh")
    assert str(pidfile) in watchdog.argv[2]

    controller.update(CLOSED_LID_AWAKE_NEVER, agents_active=False)

    assert not (tmp_path / "lid-hold-renewal").exists()
    assert not pidfile.exists()
    assert watchdog.terminated



def test_caffeinate_hold_is_time_bounded() -> None:
    assert "-t" in CAFFEINATE_CLOSED_LID_COMMAND


def test_watchdog_script_is_selfcontained_and_quoted(tmp_path) -> None:
    script = watchdog_script(tmp_path / "weird name with spaces")
    assert "'" in script  # the path survived quoting
    assert "exit 0" in script


def test_watchdog_script_owns_a_pidfile_and_reclaims_it(tmp_path) -> None:
    renewal = tmp_path / "lid-hold-renewal"
    pidfile = tmp_path / WATCHDOG_PID_FILE_NAME
    script = watchdog_script(renewal)

    # The pidfile lives alongside the marker and the script both claims
    # it and re-verifies ownership every poll.
    assert str(pidfile) in script
    assert "echo $$ > " in script
    assert '"$(cat ' in script  # re-reads the pidfile inside the loop
    # Reclaim kills the recorded predecessor only after a same-script
    # sanity check on its command line.
    assert "kill -0" in script
    assert "-o command=" in script
    assert "grep -F" in script
    # Stale pidfiles (empty, non-numeric, dead pid) are just overwritten.
    assert "case \"$old\" in" in script
    # Only the staleness path touches pmset.
    assert script.count("disablesleep") == 1


def _fast_watchdog_script(renewal: Path, pidfile: Path) -> str:
    """The real script with the poll interval patched down so process
    semantics are testable in seconds instead of 300 s."""
    return watchdog_script(renewal, pidfile).replace(
        f"sleep {WATCHDOG_POLL_SECONDS}", "sleep 1"
    )


def _spawn_watchdog(script: str) -> subprocess.Popen:
    return subprocess.Popen(
        ["/bin/sh", "-c", script],
        stdout=subprocess.DEVNULL,
        stderr=subprocess.DEVNULL,
        stdin=subprocess.DEVNULL,
        start_new_session=True,
    )


def _wait_for(predicate, timeout: float = 10.0) -> bool:
    tick = threading.Event()
    deadline = time.monotonic() + timeout
    while time.monotonic() < deadline:
        if predicate():
            return True
        tick.wait(0.05)
    return False


def _pidfile_names(pidfile: Path, pid: int) -> bool:
    try:
        return pidfile.read_text().strip() == str(pid)
    except OSError:
        return False


needs_sh = pytest.mark.skipif(
    not Path("/bin/sh").exists(), reason="needs /bin/sh"
)


@needs_sh
def test_spawn_reclaims_the_recorded_predecessor(tmp_path) -> None:
    renewal = tmp_path / "lid-hold-renewal"
    renewal.touch()
    pidfile = tmp_path / WATCHDOG_PID_FILE_NAME
    script = _fast_watchdog_script(renewal, pidfile)

    first = _spawn_watchdog(script)
    assert _wait_for(lambda: _pidfile_names(pidfile, first.pid))

    second = _spawn_watchdog(script)
    try:
        # The new watchdog killed the recorded predecessor and took over
        # the pidfile -- at most one is ever alive.
        assert _wait_for(lambda: first.poll() is not None)
        assert _wait_for(lambda: _pidfile_names(pidfile, second.pid))
    finally:
        for proc in (first, second):
            if proc.poll() is None:
                proc.terminate()


@needs_sh
def test_watchdog_exits_when_superseded(tmp_path) -> None:
    renewal = tmp_path / "lid-hold-renewal"
    renewal.touch()
    pidfile = tmp_path / WATCHDOG_PID_FILE_NAME
    watchdog = _spawn_watchdog(_fast_watchdog_script(renewal, pidfile))
    assert _wait_for(lambda: _pidfile_names(pidfile, watchdog.pid))

    # Another watchdog took the pidfile over without killing us: the
    # ownership check still retires this loop on its next poll.
    pidfile.write_text("999999\n")
    assert _wait_for(lambda: watchdog.poll() is not None)


@needs_sh
def test_watchdog_exits_when_marker_is_removed(tmp_path) -> None:
    renewal = tmp_path / "lid-hold-renewal"
    renewal.touch()
    pidfile = tmp_path / WATCHDOG_PID_FILE_NAME
    watchdog = _spawn_watchdog(_fast_watchdog_script(renewal, pidfile))
    assert _wait_for(lambda: _pidfile_names(pidfile, watchdog.pid))

    renewal.unlink()
    assert _wait_for(lambda: watchdog.poll() is not None)
    assert not pidfile.exists()


@needs_sh
def test_stale_marker_still_clears_the_hold(tmp_path) -> None:
    renewal = tmp_path / "lid-hold-renewal"
    renewal.touch()
    stale = time.time() - RENEWAL_STALE_SECONDS - 60
    os.utime(renewal, (stale, stale))
    pidfile = tmp_path / WATCHDOG_PID_FILE_NAME

    watchdog = _spawn_watchdog(_fast_watchdog_script(renewal, pidfile))
    # sudo -n pmset either runs (harmless: it restores sleep) or fails
    # silently; either way the staleness path removes the marker and
    # the pidfile and exits.
    assert _wait_for(lambda: watchdog.poll() is not None)
    assert not renewal.exists()
    assert not pidfile.exists()


@needs_sh
def test_stale_pidfile_and_non_watchdog_pid_are_left_alone(tmp_path) -> None:
    renewal = tmp_path / "lid-hold-renewal"
    renewal.touch()
    pidfile = tmp_path / WATCHDOG_PID_FILE_NAME
    script = _fast_watchdog_script(renewal, pidfile)

    # A pidfile naming a live process that is NOT our script (its
    # command line does not reference the marker) must not be killed.
    bystander = subprocess.Popen(
        ["/bin/sh", "-c", "sleep 60"],
        stdout=subprocess.DEVNULL,
        stderr=subprocess.DEVNULL,
        stdin=subprocess.DEVNULL,
        start_new_session=True,
    )
    pidfile.write_text(f"{bystander.pid}\n")
    watchdog = _spawn_watchdog(script)
    try:
        assert _wait_for(lambda: _pidfile_names(pidfile, watchdog.pid))
        assert bystander.poll() is None
    finally:
        for proc in (bystander, watchdog):
            if proc.poll() is None:
                proc.terminate()

    # Garbage content is treated as stale and overwritten, not killed.
    pidfile.write_text("not-a-pid\n")
    watchdog = _spawn_watchdog(script)
    try:
        assert _wait_for(lambda: _pidfile_names(pidfile, watchdog.pid))
    finally:
        if watchdog.poll() is None:
            watchdog.terminate()
