"""The mock daemon (`app/scripts/mock-core.py`) stops by itself once the
process named by `--parent-pid` is gone, so a killed test run leaves no
mock behind. Without the flag it runs until it is stopped, as it always
has: `run-dev.sh` starts it in the background and exits.

Each test starts real mock processes on sockets of their own under the
temporary directory, never the installed daemon's, and kills whatever is
still running when it ends. Nothing here sleeps: readiness is the mock's
own "listening on" line, and an exit is the kernel's exit event (kqueue),
each waited for with a bound.
"""

from __future__ import annotations

import os
import queue
import select
import shutil
import signal
import subprocess
import sys
import tempfile
import threading
from pathlib import Path
from typing import IO

import pytest

ROOT = Path(__file__).resolve().parents[1]
MOCK_PATH = ROOT / "app" / "scripts" / "mock-core.py"

# Starts the mock as its own child (its stderr inherited, so the test
# hears "listening on"), prints the mock's pid, then waits to be killed:
# the stand-in for a test runner that dies mid-run.
LAUNCHER = """
import os, signal, subprocess, sys
mock, socket_path, guard = sys.argv[1], sys.argv[2], sys.argv[3] == "guard"
args = [sys.executable, mock, "--socket", socket_path, "--step", "60"]
if guard:
    args += ["--parent-pid", str(os.getpid())]
child = subprocess.Popen(args, stdout=subprocess.DEVNULL)
print(child.pid, flush=True)
signal.pause()
"""


class _Lines:
    """A stream's lines, read on a thread so a wait for one is bounded."""

    def __init__(self, stream: IO[str]) -> None:
        self._lines: queue.Queue[str] = queue.Queue()
        threading.Thread(target=self._pump, args=(stream,), daemon=True).start()

    def _pump(self, stream: IO[str]) -> None:
        for line in stream:
            self._lines.put(line.strip())

    def until(self, wanted: str, timeout: float = 10.0) -> str | None:
        """The first line containing `wanted`, or None after `timeout`."""
        waited = threading.Event()
        deadline = threading.Timer(timeout, waited.set)
        deadline.start()
        try:
            while not waited.is_set():
                try:
                    line = self._lines.get(timeout=0.1)
                except queue.Empty:
                    continue
                if wanted in line:
                    return line
            return None
        finally:
            deadline.cancel()


def _exited(pid: int, timeout: float) -> bool:
    """Whether `pid` exits within `timeout`, by its kernel exit event."""
    kq = select.kqueue()
    try:
        watch = select.kevent(pid, filter=select.KQ_FILTER_PROC,
                              flags=select.KQ_EV_ADD | select.KQ_EV_ONESHOT,
                              fflags=select.KQ_NOTE_EXIT)
        try:
            return bool(kq.control([watch], 1, timeout))
        except ProcessLookupError:
            return True   # already gone before the watch went on
    finally:
        kq.close()


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


def _launch_through_parent(socket_path: str, guard: bool) -> tuple[subprocess.Popen, int, _Lines]:
    launcher = subprocess.Popen(
        [sys.executable, "-c", LAUNCHER, str(MOCK_PATH), socket_path, "guard" if guard else "plain"],
        stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)
    pid_line = _Lines(launcher.stdout).until("", timeout=10)
    assert pid_line and pid_line.isdigit(), f"the launcher printed no pid: {pid_line!r}"
    return launcher, int(pid_line), _Lines(launcher.stderr)


def _kill(pid: int) -> None:
    try:
        os.kill(pid, signal.SIGKILL)
    except ProcessLookupError:
        pass


def test_a_mock_stops_when_the_test_run_that_started_it_is_killed(socket_path) -> None:
    launcher, mock_pid, log = _launch_through_parent(socket_path, guard=True)
    try:
        assert log.until("listening on"), "the mock never listened"
        assert _alive(mock_pid)
        launcher.kill()   # SIGKILL: no chance to stop its child
        launcher.wait(timeout=5)
        assert _exited(mock_pid, timeout=5), "the orphaned mock kept running"
        assert not os.path.exists(socket_path), "it took its socket with it"
    finally:
        launcher.kill()
        _kill(mock_pid)


def test_a_mock_stops_when_a_watched_process_that_is_not_its_parent_exits(socket_path) -> None:
    watched = subprocess.Popen(["/bin/sleep", "60"])
    mock = subprocess.Popen(
        [sys.executable, str(MOCK_PATH), "--socket", socket_path, "--step", "60",
         "--parent-pid", str(watched.pid)],
        stdout=subprocess.DEVNULL, stderr=subprocess.PIPE, text=True)
    try:
        assert _Lines(mock.stderr).until("listening on"), "the mock never listened"
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
    launcher, mock_pid, log = _launch_through_parent(socket_path, guard=False)
    try:
        assert log.until("listening on"), "the mock never listened"
        launcher.kill()
        launcher.wait(timeout=5)
        # A guarded mock notices within a quarter second; give this one four.
        assert not _exited(mock_pid, timeout=1.0), "no flag, no watch"
        os.kill(mock_pid, signal.SIGTERM)
        assert _exited(mock_pid, timeout=5)
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
