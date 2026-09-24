"""The mock daemon (`app/scripts/mock-core.py`) stops by itself once the
process named by `--parent-pid` is gone, so a killed test run leaves no
mock behind. Without the flag it runs until it is stopped, as it always
has: `run-dev.sh` starts it in the background and exits.

Each test starts real mock processes on sockets of their own under the
temporary directory, never the installed daemon's, and kills whatever is
still running when it ends.
"""

from __future__ import annotations

import os
import shutil
import signal
import subprocess
import sys
import tempfile
import time
from pathlib import Path

import pytest

ROOT = Path(__file__).resolve().parents[1]
MOCK_PATH = ROOT / "app" / "scripts" / "mock-core.py"

# Starts the mock as its own child, prints the mock's pid, then waits to be
# killed: the stand-in for a test runner that dies mid-run.
LAUNCHER = """
import os, subprocess, sys, time
mock, socket_path, guard = sys.argv[1], sys.argv[2], sys.argv[3] == "guard"
args = [sys.executable, mock, "--socket", socket_path, "--step", "60"]
if guard:
    args += ["--parent-pid", str(os.getpid())]
child = subprocess.Popen(args, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
print(child.pid, flush=True)
time.sleep(120)
"""


@pytest.fixture()
def socket_path():
    # AF_UNIX paths are capped at 104 bytes; pytest's tmp_path can be longer.
    directory = tempfile.mkdtemp(prefix="jrbar-guard-")
    yield os.path.join(directory, "mock.sock")
    shutil.rmtree(directory, ignore_errors=True)


def _alive(pid: int) -> bool:
    try:
        os.kill(pid, 0)
    except ProcessLookupError:
        return False
    return True


def _wait_for(condition, timeout: float = 10.0) -> bool:
    deadline = time.monotonic() + timeout
    while time.monotonic() < deadline:
        if condition():
            return True
        time.sleep(0.05)
    return condition()


def _launch_through_parent(socket_path: str, guard: bool) -> tuple[subprocess.Popen, int]:
    launcher = subprocess.Popen(
        [sys.executable, "-c", LAUNCHER, str(MOCK_PATH), socket_path, "guard" if guard else "plain"],
        stdout=subprocess.PIPE, text=True)
    line = launcher.stdout.readline().strip()
    assert line.isdigit(), f"the launcher printed no pid: {line!r}"
    return launcher, int(line)


def _kill(pid: int) -> None:
    try:
        os.kill(pid, signal.SIGKILL)
    except ProcessLookupError:
        pass


def test_a_mock_stops_when_the_test_run_that_started_it_is_killed(socket_path) -> None:
    launcher, mock_pid = _launch_through_parent(socket_path, guard=True)
    try:
        assert _wait_for(lambda: os.path.exists(socket_path)), "the mock never listened"
        assert _alive(mock_pid)
        launcher.kill()   # SIGKILL: no chance to stop its child
        launcher.wait(timeout=5)
        assert _wait_for(lambda: not _alive(mock_pid), timeout=5), "the orphaned mock kept running"
        assert _wait_for(lambda: not os.path.exists(socket_path), timeout=2), "it took its socket with it"
    finally:
        launcher.kill()
        _kill(mock_pid)


def test_a_mock_stops_when_a_watched_process_that_is_not_its_parent_exits(socket_path) -> None:
    watched = subprocess.Popen(["/bin/sleep", "60"])
    mock = subprocess.Popen(
        [sys.executable, str(MOCK_PATH), "--socket", socket_path, "--step", "60",
         "--parent-pid", str(watched.pid)],
        stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    try:
        assert _wait_for(lambda: os.path.exists(socket_path)), "the mock never listened"
        assert mock.poll() is None
        watched.terminate()
        watched.wait(timeout=5)
        assert mock.wait(timeout=5) == 0, "it stops cleanly, the way SIGTERM stops it"
        assert not os.path.exists(socket_path)
    finally:
        watched.kill()
        mock.kill()
        mock.wait(timeout=5)


def test_without_the_flag_a_mock_outlives_the_shell_that_started_it(socket_path) -> None:
    # run-dev.sh backgrounds the mock and exits; the mock must stay up.
    launcher, mock_pid = _launch_through_parent(socket_path, guard=False)
    try:
        assert _wait_for(lambda: os.path.exists(socket_path)), "the mock never listened"
        launcher.kill()
        launcher.wait(timeout=5)
        time.sleep(1.0)
        assert _alive(mock_pid), "no flag, no watch"
        os.kill(mock_pid, signal.SIGTERM)
        assert _wait_for(lambda: not _alive(mock_pid), timeout=5)
    finally:
        launcher.kill()
        _kill(mock_pid)


def test_launchd_is_not_a_parent_to_watch(socket_path) -> None:
    refused = subprocess.run(
        [sys.executable, str(MOCK_PATH), "--socket", socket_path, "--parent-pid", "1"],
        capture_output=True, text=True, timeout=10)
    assert refused.returncode == 2
    assert "--parent-pid" in refused.stderr
    assert not os.path.exists(socket_path)
