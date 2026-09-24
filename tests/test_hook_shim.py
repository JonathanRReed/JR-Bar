"""The compiled hook shim (hook/jrbar-hook.c) against a fake ingress socket."""

from __future__ import annotations

import fcntl
import json
import os
import shutil
import socket
import statistics
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

ROOT = Path(__file__).resolve().parents[1]
SHIM = ROOT / "hook" / "build" / "jrbar-hook"


@pytest.fixture
def sock_dir():
    """AF_UNIX paths are capped at 104 bytes; pytest's tmp_path is too long."""
    import shutil as _shutil
    import tempfile as _tempfile

    path = Path(_tempfile.mkdtemp(prefix="jrbar-", dir=_tempfile.gettempdir()))
    try:
        yield path
    finally:
        _shutil.rmtree(path, ignore_errors=True)


@pytest.fixture(scope="module")
def shim() -> Path:
    if not Path("/usr/bin/clang").exists() and shutil.which("clang") is None:
        pytest.skip("clang not available")
    if not SHIM.exists() or SHIM.stat().st_mtime < (ROOT / "hook" / "jrbar-hook.c").stat().st_mtime:
        subprocess.run([str(ROOT / "hook" / "build.sh")], check=True, capture_output=True)
    return SHIM


class _FakeIngress:
    def __init__(
        self,
        state_dir: Path,
        disposition: HookIngressDisposition = HookIngressDisposition.ACCEPTED,
    ) -> None:
        self.path = state_dir / "hook-ingress.sock"
        self.disposition = disposition
        self.requests: list = []
        self.server = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
        self.server.bind(str(self.path))
        self.server.listen(4)
        self.server.settimeout(0.2)
        self._stop = threading.Event()
        self.arrived = threading.Event()
        self.thread = threading.Thread(target=self._serve, daemon=True)
        self.thread.start()

    def wait_for_request(self, timeout: float = 2.0) -> bool:
        return self.arrived.wait(timeout)

    def _serve(self) -> None:
        while not self._stop.is_set():
            try:
                connection, _ = self.server.accept()
            except TimeoutError:
                continue
            with connection:
                connection.settimeout(1.0)
                chunks = []
                while True:
                    chunk = connection.recv(65536)
                    if not chunk:
                        break
                    chunks.append(chunk)
                self.requests.append(decode_hook_ingress_request(b"".join(chunks)))
                self.arrived.set()
                connection.sendall(encode_hook_ingress_response(self.disposition))

    def close(self) -> None:
        self._stop.set()
        self.thread.join(2.0)
        self.server.close()


def _run(shim: Path, state_dir: Path, provider: str, payload: str, *extra: str) -> subprocess.CompletedProcess:
    env = dict(os.environ, JRBAR_STATE_DIR=str(state_dir))
    return subprocess.run(
        [str(shim), "--provider", provider, *extra],
        input=payload.encode("utf-8"),
        capture_output=True,
        env=env,
        timeout=5,
    )


def test_shim_sends_the_ingress_frame_with_its_parent_pid(shim: Path, sock_dir: Path) -> None:
    ingress = _FakeIngress(sock_dir)
    try:
        payload = json.dumps({"hook_event_name": "SessionStart", "session_id": "abc", "text": "π \"quoted\"\n"})
        result = _run(shim, sock_dir, "claude", payload, "--log", str(sock_dir / "claude.jsonl"))
        assert result.returncode == 0
        assert result.stdout == b""
        assert ingress.wait_for_request(), "no request reached the fake ingress"
        request = ingress.requests[0]
        assert request is not None, "frame did not decode"
        assert request.provider == "claude"
        assert request.log_path == str(sock_dir / "claude.jsonl")
        assert request.payload_text == payload
        # The shim's parent is this test process.
        assert request.ppid == os.getpid()
        assert request.ppid_start is not None and abs(request.ppid_start - _own_start_time()) < 5.0
    finally:
        ingress.close()
    assert not (sock_dir / "claude.pending.jsonl").exists()


def _own_start_time() -> float:
    out = subprocess.run(["/bin/ps", "-p", str(os.getpid()), "-o", "lstart="], capture_output=True, text=True)
    return time.mktime(time.strptime(out.stdout.strip(), "%a %b %d %H:%M:%S %Y"))


def test_shim_defaults_the_log_path_when_none_is_given__and_2_more(shim: Path, sock_dir: Path) -> None:
    # --- scenario: shim_defaults_the_log_path_when_none_is_given
    ingress = _FakeIngress(sock_dir)
    try:
        _run(shim, sock_dir, "codex", "{}")
        assert ingress.wait_for_request()
        assert ingress.requests[0].log_path == str(sock_dir / "codex.jsonl")
    finally:
        ingress.close()

    # --- scenario: shim_queues_the_payload_when_the_daemon_is_down
    payload = '{"hook_event_name":"Stop","session_id":"q\\"1","note":"tab\\there"}'
    before_ms = int(time.time() * 1000)
    result = _run(shim, sock_dir, "claude", payload)
    after_ms = int(time.time() * 1000)
    assert result.returncode == 0
    pending = sock_dir / "claude.pending.jsonl"
    assert pending.exists()
    assert oct(pending.stat().st_mode & 0o777) == "0o600"
    lines = pending.read_text().splitlines()
    assert len(lines) == 1
    row = json.loads(lines[0])
    assert row["provider"] == "claude"
    assert row["ppid"] == os.getpid()
    assert row["payload"] == payload
    assert isinstance(row["ppid_start"], float)
    # The time it was queued, so a late drain logs it when it happened.
    assert before_ms <= row["queued_at_ms"] <= after_ms
    # A second run appends.
    _run(shim, sock_dir, "claude", "{}")
    assert len(pending.read_text().splitlines()) == 2

    # --- scenario: cursor_prints_an_empty_object_even_when_nothing_listens
    result = _run(shim, sock_dir, "cursor", '{"hook_event_name":"beforeSubmitPrompt"}')
    assert result.returncode == 0
    assert result.stdout == b"{}\n"



def test_shim_never_fails_on_bad_arguments_or_oversize_input__and_1_more(shim: Path, sock_dir: Path) -> None:
    # --- scenario: shim_never_fails_on_bad_arguments_or_oversize_input
    env = dict(os.environ, JRBAR_STATE_DIR=str(sock_dir))
    assert subprocess.run([str(shim)], input=b"{}", capture_output=True, env=env, timeout=5).returncode == 0
    assert subprocess.run([str(shim), "--provider", "Bad/Name"], input=b"{}", capture_output=True, env=env, timeout=5).returncode == 0
    big = b"x" * (1024 * 1024 + 1)
    result = _run(shim, sock_dir, "claude", big.decode())
    assert result.returncode == 0
    assert not (sock_dir / "claude.pending.jsonl").exists()

    # --- scenario: shim_is_fast
    """Target < 5 ms per hook; the assertion is generous so CI noise cannot fail it."""
    ingress = _FakeIngress(sock_dir)
    try:
        samples = []
        for _ in range(20):
            started = time.perf_counter()
            _run(shim, sock_dir, "claude", '{"hook_event_name":"PreToolUse","session_id":"t"}')
            samples.append((time.perf_counter() - started) * 1000.0)
        median = statistics.median(samples)
        print(f"shim median {median:.1f} ms (min {min(samples):.1f} ms) including fork/exec from Python")
        assert median < 60.0
    finally:
        ingress.close()


def test_shim_rotates_a_full_spool_instead_of_growing_it(shim: Path, sock_dir: Path) -> None:
    """16 MiB cap: the full file becomes the overflow generation and the new
    event starts a fresh spool -- the newest event is never the one dropped."""
    pending = sock_dir / "claude.pending.jsonl"
    overflow = sock_dir / "claude.overflow.jsonl"
    overflow.write_text("previous generation\n")
    with open(pending, "wb") as handle:
        handle.truncate(16 * 1024 * 1024 - 64)  # sparse: the size is what counts
    payload = '{"hook_event_name":"Stop","session_id":"newest"}'
    assert _run(shim, sock_dir, "claude", payload).returncode == 0
    assert overflow.stat().st_size == 16 * 1024 * 1024 - 64
    rows = [json.loads(line) for line in pending.read_text().splitlines()]
    assert [row["payload"] for row in rows] == [payload]
    assert oct(pending.stat().st_mode & 0o777) == "0o600"

    # Under the cap the spool just appends.
    assert _run(shim, sock_dir, "claude", "{}").returncode == 0
    assert len(pending.read_text().splitlines()) == 2
    assert overflow.stat().st_size == 16 * 1024 * 1024 - 64


def test_shim_appends_past_the_cap_when_the_spool_cannot_rotate(shim: Path, sock_dir: Path) -> None:
    """A rename that fails leaves the full file at the pending path, so a
    shim that retried would find it at the cap every pass and spin until the
    agent's own hook timeout killed it (still spinning after 3 s with the
    state directory read-only). The line goes on the end of the full file
    instead, within the budget."""
    pending = sock_dir / "claude.pending.jsonl"
    overflow = sock_dir / "claude.overflow.jsonl"
    full = 16 * 1024 * 1024 - 10

    def fill() -> None:
        with open(pending, "wb") as handle:
            handle.seek(full - 1)  # sparse: the size is what counts
            handle.write(b"\n")

    def spool_quickly(payload: str) -> None:
        started = time.monotonic()
        assert _run(shim, sock_dir, "claude", payload).returncode == 0
        assert time.monotonic() - started < 2.0
        assert pending.stat().st_size > full
        with open(pending, "rb") as handle:
            handle.seek(full)
            assert json.loads(handle.read())["payload"] == payload

    # --- scenario: the overflow path is a directory the file cannot replace
    fill()
    overflow.mkdir()
    (overflow / "keep").write_text("")
    spool_quickly('{"hook_event_name":"Stop","session_id":"overflow-is-a-directory"}')
    assert (overflow / "keep").exists()
    shutil.rmtree(overflow)

    # --- scenario: the state directory is read-only (root renames regardless)
    if os.geteuid() == 0:
        return
    fill()
    sock_dir.chmod(0o555)
    try:
        spool_quickly('{"hook_event_name":"Stop","session_id":"read-only-state"}')
    finally:
        sock_dir.chmod(0o700)
    assert not overflow.exists()


def test_shim_follows_the_spool_when_a_drain_moves_it_under_the_lock(shim: Path, sock_dir: Path) -> None:
    """Every appender holds the spool's lock from its size check through its
    write. A shim waiting on it while the daemon renames the file to drain
    it must write to a fresh pending file, not follow the renamed one: that
    file is read and unlinked, and a line landing in it after the read was
    lost (19 of 200 shims racing a drain every 10 ms)."""
    pending = sock_dir / "claude.pending.jsonl"
    draining = sock_dir / "claude.pending.jsonl.draining-1-1"
    pending.write_text("")
    holder = os.open(pending, os.O_RDONLY)
    fcntl.flock(holder, fcntl.LOCK_EX)  # another appender, mid-write
    process = subprocess.Popen(
        [str(shim), "--provider", "claude"],
        stdin=subprocess.PIPE,
        env=dict(os.environ, JRBAR_STATE_DIR=str(sock_dir)),
    )
    payload = '{"hook_event_name":"Stop","session_id":"moved"}'
    try:
        process.stdin.write(payload.encode())
        process.stdin.close()
        # No daemon listens, so the shim goes straight to the spool, where
        # the held lock is the one thing it can be waiting on.
        with pytest.raises(subprocess.TimeoutExpired):
            process.wait(timeout=0.05)
        pending.rename(draining)
    finally:
        os.close(holder)
    assert process.wait(timeout=5) == 0
    assert draining.read_text() == ""
    rows = [json.loads(line) for line in pending.read_text().splitlines()]
    assert [row["payload"] for row in rows] == [payload]


def test_shim_waits_on_a_stuck_spool_lock_only_until_its_budget_runs_out(shim: Path, sock_dir: Path) -> None:
    """A lock nobody releases (an appender stopped mid-write) holds the shim
    for its 250 ms budget, not longer, and the line is still written."""
    pending = sock_dir / "claude.pending.jsonl"
    pending.write_text("")
    holder = os.open(pending, os.O_RDONLY)
    fcntl.flock(holder, fcntl.LOCK_EX)
    payload = '{"hook_event_name":"Stop","session_id":"stuck"}'
    try:
        started = time.monotonic()
        assert _run(shim, sock_dir, "claude", payload).returncode == 0
        elapsed = time.monotonic() - started
    finally:
        os.close(holder)
    assert 0.2 <= elapsed < 2.0
    rows = [json.loads(line) for line in pending.read_text().splitlines()]
    assert [row["payload"] for row in rows] == [payload]


def test_shim_spools_a_frame_the_budget_cut_short(shim: Path, sock_dir: Path) -> None:
    """A listener that never reads fills the socket buffers mid-send; the
    truncated frame never decodes on the daemon side, so it must be spooled
    rather than dropped."""
    server = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
    server.bind(str(sock_dir / "hook-ingress.sock"))
    server.listen(4)
    try:
        payload = json.dumps({"hook_event_name": "PostToolUse", "session_id": "big", "body": "x" * 512 * 1024})
        assert _run(shim, sock_dir, "claude", payload).returncode == 0
    finally:
        server.close()
    rows = [json.loads(line) for line in (sock_dir / "claude.pending.jsonl").read_text().splitlines()]
    assert [row["payload"] for row in rows] == [payload]


def test_shim_spools_what_a_full_or_closing_daemon_refused__and_2_more(shim: Path, sock_dir: Path) -> None:
    """refused_full and refused_closed leave the payload with nobody: the
    daemon never processes a frame it answered that way. The shim spools it
    for the drain, inside its budget. refused_invalid and accepted spool
    nothing: the first would not read any better from the spool, and the
    second is already queued."""
    pending = sock_dir / "claude.pending.jsonl"
    # --- scenario: refused_full and refused_closed are spooled
    for disposition in (HookIngressDisposition.REFUSED_FULL, HookIngressDisposition.REFUSED_CLOSED):
        ingress = _FakeIngress(sock_dir, disposition)
        payload = json.dumps({"hook_event_name": "Stop", "session_id": disposition.value})
        try:
            started = time.monotonic()
            result = _run(shim, sock_dir, "claude", payload)
            elapsed = time.monotonic() - started
            assert ingress.wait_for_request()
        finally:
            ingress.close()
        assert result.returncode == 0 and result.stdout == b""
        assert elapsed < 2.0
        rows = [json.loads(line) for line in pending.read_text().splitlines()]
        assert [row["payload"] for row in rows] == [payload]
        assert rows[0]["ppid"] == os.getpid()
        pending.unlink()
        (sock_dir / "hook-ingress.sock").unlink()

    # --- scenario: accepted and refused_invalid spool nothing
    for disposition in (HookIngressDisposition.ACCEPTED, HookIngressDisposition.REFUSED_INVALID):
        ingress = _FakeIngress(sock_dir, disposition)
        try:
            assert _run(shim, sock_dir, "claude", '{"hook_event_name":"Stop"}').returncode == 0
            assert ingress.wait_for_request()
        finally:
            ingress.close()
        assert not pending.exists()
        (sock_dir / "hook-ingress.sock").unlink()

    # --- scenario: a --decide hook the daemon refused is spooled and prints nothing
    ingress = _FakeIngress(sock_dir, HookIngressDisposition.REFUSED_FULL)
    payload = json.dumps({"hook_event_name": "PermissionRequest", "session_id": "decide", "tool_name": "Bash"})
    try:
        result = _run(shim, sock_dir, "claude", payload, "--decide")
        assert ingress.wait_for_request()
    finally:
        ingress.close()
    assert result.returncode == 0 and result.stdout == b""
    rows = [json.loads(line) for line in pending.read_text().splitlines()]
    assert [row["payload"] for row in rows] == [payload]


def test_shim_spools_a_hook_that_arrives_past_every_ingress_slot(
    shim: Path, sock_dir: Path, monkeypatch: pytest.MonkeyPatch
) -> None:
    """The real ingress with its connection slots all held: it used to
    close the socket unanswered and the shim, reading EOF, counted the hook
    delivered. The ingress now answers refused_full, and the shim spools
    whether that answer or the close reaches it first."""
    from jrbar.hook_ingress import HookIngressService

    monkeypatch.setattr("jrbar.hook_ingress.MAX_HOOK_INGRESS_CONNECTIONS", 1)
    processed: list = []
    service = HookIngressService(
        process=processed.append,
        socket_path=sock_dir / "hook-ingress.sock",
        rejection_path=sock_dir / "rejections.jsonl",
        backlog_cleared=lambda: None,
    )
    service.start()
    pending = sock_dir / "claude.pending.jsonl"
    payload = json.dumps({"hook_event_name": "Stop", "session_id": "past-the-slots"})
    try:
        holder = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
        holder.connect(str(sock_dir / "hook-ingress.sock"))
        holder.sendall(b"J")
        try:
            result = _run(shim, sock_dir, "claude", payload)
        finally:
            holder.close()
    finally:
        assert service.close(timeout_seconds=1.0)
    assert result.returncode == 0 and result.stdout == b""
    assert processed == []
    rows = [json.loads(line) for line in pending.read_text().splitlines()]
    assert [row["payload"] for row in rows] == [payload]
