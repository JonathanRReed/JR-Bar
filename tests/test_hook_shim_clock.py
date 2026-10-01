"""The compiled hook shim keeps its budgets on a clock a wall-clock step cannot move.

The shim's 250 ms delivery budget, its spool-lock wait and the 50 s decide
window are all deadlines. Read from the wall clock, an NTP correction that steps
it back stretches the wait by the whole step (a stuck spool lock held the shim
until the agent's own timeout), and a step forward -- a wake from sleep -- makes
every deadline look passed at once (the frame is spooled instead of delivered,
and the decide window collapses before the daemon can answer).

A test cannot move the machine's clock, so ``fixtures/hook_clock_interpose.c``
steps the wall clock read by the shim alone. Run against a shim that still
computes a deadline from the wall clock these tests fail; against one that
keeps its deadlines on a monotonic clock the step is never met.
"""

from __future__ import annotations

import fcntl
import json
import os
import re
import socket
import subprocess
import threading
import time
from pathlib import Path

import pytest

from jrbar.hook_ingress_protocol import (
    HookIngressDisposition,
    decode_hook_ingress_request,
    encode_hook_ingress_response,
)
from tests.test_hook_shim import _FakeIngress, shim, sock_dir  # noqa: F401  (the shim and socket-dir fixtures)

ROOT = Path(__file__).resolve().parents[1]
HOUR = 3600
# Bounds a hang, never a slow machine: a shim that works returns well inside it.
HANG_BOUND_SECONDS = 15.0


@pytest.fixture(scope="module")
def clock_interposer(tmp_path_factory: pytest.TempPathFactory) -> Path:
    interposer = tmp_path_factory.mktemp("clock") / "hook-clock-interpose.dylib"
    subprocess.run(
        [
            "/usr/bin/clang",
            "-dynamiclib",
            str(ROOT / "tests" / "fixtures" / "hook_clock_interpose.c"),
            "-o",
            str(interposer),
        ],
        check=True,
        capture_output=True,
        timeout=60,
    )
    return interposer


def _stepped_env(sock_dir: Path, interposer: Path, step_seconds: int) -> dict[str, str]:
    return dict(
        os.environ,
        JRBAR_STATE_DIR=str(sock_dir),
        DYLD_INSERT_LIBRARIES=str(interposer),
        JRBAR_TEST_WALL_STEP_SECONDS=str(step_seconds),
    )


def test_a_wall_clock_step_back_does_not_stretch_the_spool_lock_wait(
    shim: Path, sock_dir: Path, clock_interposer: Path
) -> None:
    """A lock nobody releases holds the shim for its 250 ms budget. With the
    wall clock stepped back an hour mid-wait, a deadline read from it would
    not pass for an hour."""
    pending = sock_dir / "claude.pending.jsonl"
    pending.write_text("")
    holder = os.open(pending, os.O_RDONLY)
    fcntl.flock(holder, fcntl.LOCK_EX)
    payload = '{"hook_event_name":"Stop","session_id":"clock-back"}'
    try:
        started = time.monotonic()
        result = subprocess.run(
            [str(shim), "--provider", "claude"],
            input=payload.encode(),
            capture_output=True,
            env=_stepped_env(sock_dir, clock_interposer, -HOUR),
            timeout=HANG_BOUND_SECONDS,
        )
        elapsed = time.monotonic() - started
    finally:
        os.close(holder)
    assert result.returncode == 0 and result.stdout == b""
    assert 0.2 <= elapsed < 3.0
    rows = [json.loads(line) for line in pending.read_text().splitlines()]
    assert [row["payload"] for row in rows] == [payload]


def test_a_wall_clock_step_forward_does_not_make_the_delivery_budget_look_spent(
    shim: Path, sock_dir: Path, clock_interposer: Path
) -> None:
    """A Mac that wakes from sleep an hour later: the frame still goes down the
    socket within its budget rather than being spooled as if time had run out."""
    ingress = _FakeIngress(sock_dir)
    payload = json.dumps({"hook_event_name": "PreToolUse", "session_id": "clock-forward"})
    try:
        result = subprocess.run(
            [str(shim), "--provider", "claude"],
            input=payload.encode(),
            capture_output=True,
            env=_stepped_env(sock_dir, clock_interposer, HOUR),
            timeout=HANG_BOUND_SECONDS,
        )
        delivered = ingress.wait_for_request()
    finally:
        ingress.close()
    assert result.returncode == 0 and result.stdout == b""
    assert delivered, "the frame was spooled instead of delivered"
    assert ingress.requests[0] is not None and ingress.requests[0].payload_text == payload
    assert not (sock_dir / "claude.pending.jsonl").exists()


class _HoldingIngress:
    """An ingress that reads the whole frame, then answers only when told: the
    daemon holding a request for a click."""

    VERDICT = (
        b'{"hookSpecificOutput":{"hookEventName":"PermissionRequest",'
        b'"decision":{"behavior":"allow"}}}\n'
    )

    def __init__(self, state_dir: Path) -> None:
        self.server = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
        self.server.bind(str(state_dir / "hook-ingress.sock"))
        self.server.listen(4)
        self.server.settimeout(0.2)
        self.received = threading.Event()
        self.release = threading.Event()
        self.request = None
        self._stop = threading.Event()
        self.thread = threading.Thread(target=self._serve, daemon=True)
        self.thread.start()

    def _serve(self) -> None:
        while not self._stop.is_set():
            try:
                connection, _ = self.server.accept()
            except TimeoutError:
                continue
            with connection:
                connection.settimeout(5.0)
                chunks = []
                while True:
                    chunk = connection.recv(65536)
                    if not chunk:
                        break
                    chunks.append(chunk)
                self.request = decode_hook_ingress_request(b"".join(chunks))
                self.received.set()
                if not self.release.wait(HANG_BOUND_SECONDS):
                    return
                connection.sendall(encode_hook_ingress_response(HookIngressDisposition.ACCEPTED))
                connection.sendall(self.VERDICT)

    def close(self) -> None:
        self._stop.set()
        self.release.set()
        self.thread.join(5.0)
        self.server.close()


def test_a_wall_clock_step_forward_does_not_collapse_the_decide_window(
    shim: Path, sock_dir: Path, clock_interposer: Path
) -> None:
    """The decide lane waits up to 50 s for a verdict. A wall clock that jumps
    an hour forward while it waits would end the wait at once and print
    nothing, so the click that arrives a moment later is lost."""
    ingress = _HoldingIngress(sock_dir)
    payload = json.dumps(
        {
            "hook_event_name": "PermissionRequest",
            "session_id": "clock-decide",
            "tool_name": "Bash",
            "tool_input": {"command": "npm test"},
        }
    )
    process = subprocess.Popen(
        [str(shim), "--provider", "claude", "--decide"],
        stdin=subprocess.PIPE,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        env=_stepped_env(sock_dir, clock_interposer, HOUR),
    )
    try:
        assert process.stdin is not None
        process.stdin.write(payload.encode())
        process.stdin.close()
        process.stdin = None
        assert ingress.received.wait(HANG_BOUND_SECONDS), "the frame never reached the ingress"
        ingress.release.set()
        stdout, _ = process.communicate(timeout=HANG_BOUND_SECONDS)
    finally:
        if process.poll() is None:
            process.kill()
        ingress.close()
    assert process.returncode == 0
    assert stdout == _HoldingIngress.VERDICT


def _without_comments(source: str) -> str:
    source = re.sub(r"/\*.*?\*/", "", source, flags=re.DOTALL)
    return re.sub(r"//[^\n]*", "", source)


def test_the_shim_reads_the_wall_clock_only_for_the_time_it_stamps_on_a_spooled_record() -> None:
    """Source-level contract behind the tests above: every elapsed or deadline
    computation runs on ``now_ms`` (a monotonic clock) and the one wall-clock
    read, ``wall_ms``, feeds only ``queued_at_ms``."""
    code = _without_comments((ROOT / "hook" / "jrbar-hook.c").read_text())
    assert "gettimeofday" not in code
    assert code.count("CLOCK_REALTIME") == 1, "one wall-clock read: the queued time"
    now_ms = re.search(r"static uint64_t now_ms\(void\) \{.*?\n\}", code, flags=re.DOTALL)
    assert now_ms is not None and re.search(r"CLOCK_(UPTIME_RAW|MONOTONIC)\b", now_ms.group(0))
    wall_readers = re.findall(r"wall_ms\(\)", code)
    assert len(wall_readers) == 1, "wall_ms() is read once, at start, for the spooled record's time"
    assert re.search(r"uint64_t queued_at = wall_ms\(\);", code)
