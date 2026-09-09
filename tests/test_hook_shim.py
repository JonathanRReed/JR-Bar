"""The compiled hook shim (hook/jrbar-hook.c) against a fake ingress socket."""

from __future__ import annotations

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
    def __init__(self, state_dir: Path) -> None:
        self.path = state_dir / "hook-ingress.sock"
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
                connection.sendall(encode_hook_ingress_response(HookIngressDisposition.ACCEPTED))

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


def test_shim_defaults_the_log_path_when_none_is_given(shim: Path, sock_dir: Path) -> None:
    ingress = _FakeIngress(sock_dir)
    try:
        _run(shim, sock_dir, "codex", "{}")
        assert ingress.wait_for_request()
        assert ingress.requests[0].log_path == str(sock_dir / "codex.jsonl")
    finally:
        ingress.close()


def test_shim_queues_the_payload_when_the_daemon_is_down(shim: Path, sock_dir: Path) -> None:
    payload = '{"hook_event_name":"Stop","session_id":"q\\"1","note":"tab\\there"}'
    result = _run(shim, sock_dir, "claude", payload)
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
    # A second run appends.
    _run(shim, sock_dir, "claude", "{}")
    assert len(pending.read_text().splitlines()) == 2


def test_cursor_prints_an_empty_object_even_when_nothing_listens(shim: Path, sock_dir: Path) -> None:
    result = _run(shim, sock_dir, "cursor", '{"hook_event_name":"beforeSubmitPrompt"}')
    assert result.returncode == 0
    assert result.stdout == b"{}\n"


def test_shim_never_fails_on_bad_arguments_or_oversize_input(shim: Path, sock_dir: Path) -> None:
    env = dict(os.environ, JRBAR_STATE_DIR=str(sock_dir))
    assert subprocess.run([str(shim)], input=b"{}", capture_output=True, env=env, timeout=5).returncode == 0
    assert subprocess.run([str(shim), "--provider", "Bad/Name"], input=b"{}", capture_output=True, env=env, timeout=5).returncode == 0
    big = b"x" * (1024 * 1024 + 1)
    result = _run(shim, sock_dir, "claude", big.decode())
    assert result.returncode == 0
    assert not (sock_dir / "claude.pending.jsonl").exists()


def test_shim_is_fast(shim: Path, sock_dir: Path) -> None:
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
