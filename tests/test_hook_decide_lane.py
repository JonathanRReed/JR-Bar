"""The decide lane end to end: the compiled shim run as ``--decide`` against
the real ingress service, and the Python client's copy of the same mode."""

from __future__ import annotations

import json
import os
import shutil
import socket
import struct
import subprocess
import tempfile
import threading
import time
from pathlib import Path

import pytest

from jrbar import hook_client
from jrbar.answer_decisions import DecisionBroker, DecisionResult, DecisionVerb, decision_document
from jrbar.hook_ingress import HookIngressService
from jrbar.hook_ingress_protocol import (
    HOOK_DECISION_WAIT_MS,
    HookIngressDisposition,
    HookIngressRequest,
    decode_hook_decision,
    decode_hook_ingress_request,
    encode_hook_decision,
    encode_hook_ingress_request,
    submit_hook_ingress_for_decision,
)

ROOT = Path(__file__).resolve().parents[1]
SHIM = ROOT / "hook" / "build" / "jrbar-hook"

PERMISSION = {
    "hook_event_name": "PermissionRequest",
    "session_id": "decide-session",
    "cwd": "/Users/me/project",
    "tool_name": "Bash",
    "tool_input": {"command": "npm test"},
    "permission_suggestions": [
        {
            "type": "addRules",
            "rules": [{"toolName": "Bash", "ruleContent": "npm test"}],
            "behavior": "allow",
            "destination": "localSettings",
        }
    ],
}


@pytest.fixture
def sock_dir():
    """AF_UNIX paths are capped at 104 bytes; pytest's tmp_path is too long."""
    path = Path(tempfile.mkdtemp(prefix="jrbar-", dir=tempfile.gettempdir()))
    try:
        yield path
    finally:
        shutil.rmtree(path, ignore_errors=True)


@pytest.fixture(scope="module")
def shim() -> Path:
    if not Path("/usr/bin/clang").exists() and shutil.which("clang") is None:
        pytest.skip("clang not available")
    if not SHIM.exists() or SHIM.stat().st_mtime < (ROOT / "hook" / "jrbar-hook.c").stat().st_mtime:
        subprocess.run([str(ROOT / "hook" / "build.sh")], check=True, capture_output=True)
    return SHIM


#: Far below the 45 s hold: a hook back inside this was never held.
NOT_HELD_SECONDS = 10.0


class _Seen(list):
    """The payloads the service processed; a test waits for a count."""

    def __init__(self) -> None:
        super().__init__()
        self._condition = threading.Condition()

    def __call__(self, request) -> None:
        with self._condition:
            self.append(request)
            self._condition.notify_all()

    def wait_for(self, count: int) -> bool:
        with self._condition:
            return self._condition.wait_for(lambda: len(self) >= count, timeout=5.0)


def _service(sock_dir: Path, broker: DecisionBroker, seen: _Seen, **kwargs) -> HookIngressService:
    service = HookIngressService(
        process=seen,
        socket_path=sock_dir / "hook-ingress.sock",
        rejection_path=sock_dir / "rejections.jsonl",
        decision_broker=broker,
        **kwargs,
    )
    service.start()
    return service


class _Broker(DecisionBroker):
    """The daemon's broker, signalling each park so a test waits on the
    event instead of polling."""

    def __init__(self) -> None:
        super().__init__(watching=lambda _facts, _pid: False)
        self.parked_event = threading.Event()
        self.last_request_id: str | None = None
        self._parks = 0
        self._parks_changed = threading.Condition()

    def park(self, facts, **kwargs):
        slot = super().park(facts, **kwargs)
        if slot is not None:
            self.last_request_id = facts.request_id
            self.parked_event.set()
            with self._parks_changed:
                self._parks += 1
                self._parks_changed.notify_all()
        return slot

    def wait_for_parks(self, count: int) -> bool:
        with self._parks_changed:
            return self._parks_changed.wait_for(lambda: self._parks >= count, timeout=5.0)

    def next_parked(self) -> str:
        assert self.parked_event.wait(5.0), "nothing was parked"
        self.parked_event.clear()
        assert self.last_request_id is not None
        return self.last_request_id


def _broker() -> _Broker:
    return _Broker()


def _spawn(shim: Path, sock_dir: Path, provider: str, payload: dict, *extra: str) -> subprocess.Popen:
    process = subprocess.Popen(
        [str(shim), "--provider", provider, "--log", str(sock_dir / f"{provider}.jsonl"), *extra],
        stdin=subprocess.PIPE,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        env=dict(os.environ, JRBAR_STATE_DIR=str(sock_dir)),
    )
    assert process.stdin is not None
    process.stdin.write(json.dumps(payload).encode("utf-8"))
    process.stdin.close()
    # communicate() must not flush the stdin we already closed.
    process.stdin = None
    return process


def test_the_shim_prints_the_verdict_a_click_sends__and_2_more(shim: Path, sock_dir: Path) -> None:
    # --- scenario: approve reaches the agent as its documented allow
    broker = _broker()
    seen = _Seen()
    service = _service(sock_dir, broker, seen)
    try:
        process = _spawn(shim, sock_dir, "claude", PERMISSION, "--decide")
        request_id = broker.next_parked()
        # Parked before it was queued, and queued as an ordinary hook.
        assert seen.wait_for(1)
        assert seen[0].decide_ms == HOOK_DECISION_WAIT_MS
        assert broker.decide("claude", request_id, DecisionVerb.ALLOW) is DecisionResult.SENT
        stdout, _ = process.communicate(timeout=5)
        assert process.returncode == 0
        assert json.loads(stdout) == decision_document("claude", DecisionVerb.ALLOW)
        assert stdout.endswith(b"\n") and stdout.count(b"\n") == 1

        # --- scenario: always allow carries the agent's own rule back
        process = _spawn(shim, sock_dir, "claude", PERMISSION, "--decide")
        request_id = broker.next_parked()
        assert broker.decide("claude", request_id, DecisionVerb.ALWAYS) is DecisionResult.SENT
        stdout, _ = process.communicate(timeout=5)
        decision = json.loads(stdout)["hookSpecificOutput"]["decision"]
        assert decision["behavior"] == "allow"
        assert decision["updatedPermissions"] == PERMISSION["permission_suggestions"]

        # --- scenario: a released hold prints nothing, so the agent's own prompt stays
        process = _spawn(shim, sock_dir, "claude", PERMISSION, "--decide")
        broker.next_parked()
        started = time.monotonic()
        assert broker.release("claude", session_id="decide-session") == 1
        stdout, _ = process.communicate(timeout=NOT_HELD_SECONDS)
        assert process.returncode == 0 and stdout == b""
        assert time.monotonic() - started < NOT_HELD_SECONDS
    finally:
        assert service.close(timeout_seconds=2.0)


def test_what_the_decide_mode_never_holds__and_2_more(shim: Path, sock_dir: Path) -> None:
    broker = _broker()
    service = _service(sock_dir, broker, _Seen())
    try:
        # --- scenario: any other event returns at once and prints nothing
        started = time.monotonic()
        process = _spawn(shim, sock_dir, "claude", {"hook_event_name": "PreToolUse", "session_id": "x"}, "--decide")
        stdout, _ = process.communicate(timeout=NOT_HELD_SECONDS)
        assert stdout == b"" and process.returncode == 0
        assert time.monotonic() - started < NOT_HELD_SECONDS
        assert broker.parked_count() == 0

        # --- scenario: a provider the lane does not answer for is not held
        process = _spawn(shim, sock_dir, "grok", PERMISSION, "--decide")
        stdout, _ = process.communicate(timeout=NOT_HELD_SECONDS)
        assert stdout == b"" and broker.parked_count() == 0
    finally:
        assert service.close(timeout_seconds=2.0)

    # --- scenario: with the daemon down the payload is spooled and nothing printed
    started = time.monotonic()
    process = _spawn(shim, sock_dir, "claude", PERMISSION, "--decide")
    stdout, _ = process.communicate(timeout=NOT_HELD_SECONDS)
    assert stdout == b"" and process.returncode == 0
    assert time.monotonic() - started < NOT_HELD_SECONDS
    rows = (sock_dir / "claude.pending.jsonl").read_text().splitlines()
    assert json.loads(json.loads(rows[-1])["payload"]) == PERMISSION


def test_a_stopping_daemon_lets_parked_hooks_fall_through(shim: Path, sock_dir: Path) -> None:
    broker = _broker()
    service = _service(sock_dir, broker, _Seen())
    process = _spawn(shim, sock_dir, "codex", {**PERMISSION, "turn_id": "t-1"}, "--decide")
    broker.next_parked()
    started = time.monotonic()
    assert service.close(timeout_seconds=3.0)
    stdout, _ = process.communicate(timeout=NOT_HELD_SECONDS)
    assert stdout == b"" and process.returncode == 0
    assert time.monotonic() - started < NOT_HELD_SECONDS
    assert broker.parked_count() == 0


#: A sub-agent's hook payload names its own agent next to the parent session.
WORKER_PERMISSION = {**PERMISSION, "agent_id": "decide-worker"}


def _not_held(shim: Path, sock_dir: Path, provider: str, payload: dict) -> None:
    """Run ``--decide`` for a request and prove it came straight back."""
    started = time.monotonic()
    process = _spawn(shim, sock_dir, provider, payload, "--decide")
    stdout, _ = process.communicate(timeout=NOT_HELD_SECONDS)
    assert stdout == b"" and process.returncode == 0
    assert time.monotonic() - started < NOT_HELD_SECONDS


def test_a_sub_agents_request_is_not_held_while_worker_asks_are_off(shim: Path, sock_dir: Path) -> None:
    broker = _broker()
    seen = _Seen()
    service = _service(sock_dir, broker, seen, subagent_asks_alert=lambda: False)
    try:
        # --- scenario: a Claude worker's hook returns at once and holds nothing
        _not_held(shim, sock_dir, "claude", WORKER_PERMISSION)
        assert broker.parked_count() == 0
        assert not broker.parked_event.is_set()

        # --- scenario: a Codex worker's prompt is not delayed behind the hook
        codex_worker = {**WORKER_PERMISSION, "turn_id": "t-1"}
        _not_held(shim, sock_dir, "codex", codex_worker)
        assert broker.parked_count() == 0
        assert not broker.parked_event.is_set()

        # --- scenario: the payload is still queued, so canonical state stays honest
        assert seen.wait_for(2)
        assert [json.loads(request.payload_text).get("agent_id") for request in seen] == [
            "decide-worker",
            "decide-worker",
        ]

        # --- scenario: a main session's request still parks and still takes a click
        process = _spawn(shim, sock_dir, "claude", PERMISSION, "--decide")
        request_id = broker.next_parked()
        assert broker.decide("claude", request_id, DecisionVerb.ALLOW) is DecisionResult.SENT
        stdout, _ = process.communicate(timeout=5)
        assert json.loads(stdout) == decision_document("claude", DecisionVerb.ALLOW)
    finally:
        assert service.close(timeout_seconds=2.0)


def test_a_sub_agents_request_is_held_when_worker_asks_are_on(shim: Path, sock_dir: Path) -> None:
    for reader in (lambda: True, None):
        broker = _broker()
        service = _service(sock_dir, broker, _Seen(), subagent_asks_alert=reader)
        try:
            process = _spawn(shim, sock_dir, "claude", WORKER_PERMISSION, "--decide")
            request_id = broker.next_parked()
            assert broker.decide("claude", request_id, DecisionVerb.DENY) is DecisionResult.SENT
            stdout, _ = process.communicate(timeout=5)
            assert json.loads(stdout) == decision_document("claude", DecisionVerb.DENY)
        finally:
            assert service.close(timeout_seconds=2.0)


def test_a_main_and_a_sub_agent_making_the_same_call_are_answered_apart(shim: Path, sock_dir: Path) -> None:
    broker = _broker()
    service = _service(sock_dir, broker, _Seen(), subagent_asks_alert=lambda: True)
    try:
        # Same session, same tool, same input: one derived request id.
        main = _spawn(shim, sock_dir, "claude", PERMISSION, "--decide")
        assert broker.wait_for_parks(1)
        worker = _spawn(shim, sock_dir, "claude", WORKER_PERMISSION, "--decide")
        assert broker.wait_for_parks(2)
        assert broker.parked_count() == 2
        request_id = broker.last_request_id
        assert request_id is not None

        # The sub-agent's card denies the sub-agent's hold and leaves the main's.
        assert (
            broker.decide("claude", request_id, DecisionVerb.DENY, work_id="decide-worker")
            is DecisionResult.SENT
        )
        stdout, _ = worker.communicate(timeout=5)
        assert json.loads(stdout) == decision_document("claude", DecisionVerb.DENY)
        assert main.poll() is None
        assert broker.parked_count() == 1

        # The main session's card then allows the main's own hold.
        assert (
            broker.decide("claude", request_id, DecisionVerb.ALLOW, work_id="decide-session")
            is DecisionResult.SENT
        )
        stdout, _ = main.communicate(timeout=5)
        assert json.loads(stdout) == decision_document("claude", DecisionVerb.ALLOW)
    finally:
        assert service.close(timeout_seconds=2.0)


def test_the_worker_ask_reader_is_a_callable_or_nothing(sock_dir: Path) -> None:
    for bad in ("yes", True, 1):
        with pytest.raises(ValueError):
            HookIngressService(
                socket_path=sock_dir / "hook-ingress.sock",
                rejection_path=sock_dir / "rejections.jsonl",
                subagent_asks_alert=bad,
            )


def test_the_wire_carries_the_decide_wait_and_the_verdict_line__and_2_more(sock_dir: Path) -> None:
    # --- scenario: decide_ms round-trips and is bounded
    request = HookIngressRequest("claude", "/tmp/c.jsonl", "{}", decide_ms=HOOK_DECISION_WAIT_MS)
    assert decode_hook_ingress_request(encode_hook_ingress_request(request)).decide_ms == HOOK_DECISION_WAIT_MS
    for bad in (0, 999, 60_001, True, 1.5):
        with pytest.raises(ValueError):
            HookIngressRequest("claude", "/tmp/c.jsonl", "{}", decide_ms=bad)

    # --- scenario: only a whole hookSpecificOutput line is ever printed
    verdict = decision_document("codex", DecisionVerb.DENY)
    line = encode_hook_decision(verdict)
    assert decode_hook_decision(line) == line[:-1].decode()
    assert decode_hook_decision(line[:-1]) is None
    assert decode_hook_decision(line + line) is None
    assert decode_hook_decision(b'{"other":1}\n') is None
    assert decode_hook_decision(b"\n") is None
    with pytest.raises(ValueError):
        encode_hook_decision({"decision": "allow"})

    # --- scenario: the Python client waits for the verdict and prints it
    broker = _broker()
    service = _service(sock_dir, broker, _Seen())
    try:
        result: list = []
        thread = threading.Thread(
            target=lambda: result.append(
                submit_hook_ingress_for_decision(
                    HookIngressRequest(
                        "claude",
                        "/tmp/c.jsonl",
                        json.dumps(PERMISSION),
                        decide_ms=HOOK_DECISION_WAIT_MS,
                    ),
                    socket_path=sock_dir / "hook-ingress.sock",
                    timeout_seconds=1.0,
                )
            ),
            daemon=True,
        )
        thread.start()
        request_id = broker.next_parked()
        assert broker.decide("claude", request_id, DecisionVerb.DENY) is DecisionResult.SENT
        thread.join(5.0)
        disposition, printed = result[0]
        assert disposition is HookIngressDisposition.ACCEPTED
        assert json.loads(printed) == decision_document("claude", DecisionVerb.DENY)
    finally:
        assert service.close(timeout_seconds=2.0)


def test_a_session_start_from_the_shim_reaches_the_surface_recorder(shim: Path, sock_dir: Path) -> None:
    noted: list = []
    told = threading.Event()

    class Recorder:
        def note_session_start(self, provider, payload_text, ppid):
            noted.append((provider, json.loads(payload_text)["session_id"], ppid))
            told.set()
            return True

    service = HookIngressService(
        process=_Seen(),
        socket_path=sock_dir / "hook-ingress.sock",
        rejection_path=sock_dir / "rejections.jsonl",
        decision_broker=_broker(),
        surface_recorder=Recorder(),
    )
    service.start()
    try:
        start = {"hook_event_name": "SessionStart", "session_id": "surface-1", "cwd": "/tmp"}
        _spawn(shim, sock_dir, "claude", start).communicate(timeout=5)
        assert told.wait(5.0)
        # The shim's parent is this test process: the pid the probe walks up from.
        assert noted == [("claude", "surface-1", os.getpid())]
    finally:
        assert service.close(timeout_seconds=2.0)


def test_python_decide_client_falls_back_without_a_verdict__and_1_more(tmp_path: Path) -> None:
    # --- scenario: an unreachable daemon gets the payload through the fallback, a refusing one through the spool
    for disposition in (HookIngressDisposition.UNAVAILABLE, HookIngressDisposition.REFUSED_FULL):
        fallback: list = []
        spooled: list = []
        verdict = hook_client.run_decide_hook_client(
            "claude",
            tmp_path / "claude.jsonl",
            json.dumps(PERMISSION),
            submit=lambda request: (disposition, '{"hookSpecificOutput":{}}'),
            fallback=lambda *args: fallback.append(args),
            spool=lambda *args: spooled.append(args),
        )
        assert verdict is None
        refused = disposition is HookIngressDisposition.REFUSED_FULL
        assert (len(fallback), len(spooled)) == ((0, 1) if refused else (1, 0))

    # --- scenario: the verdict is returned only for an accepted frame
    captured: list = []

    def submit(request):
        captured.append(request)
        return HookIngressDisposition.ACCEPTED, '{"hookSpecificOutput":{}}'

    assert hook_client.run_decide_hook_client("claude", tmp_path / "c.jsonl", "{}", submit=submit) == (
        '{"hookSpecificOutput":{}}'
    )
    assert captured[0].decide_ms == HOOK_DECISION_WAIT_MS
    assert hook_client.run_decide_hook_client(
        "claude",
        tmp_path / "c.jsonl",
        "{}",
        submit=lambda request: (HookIngressDisposition.REFUSED_INVALID, '{"hookSpecificOutput":{}}'),
        fallback=lambda *args: pytest.fail("an unreadable frame was processed"),
        spool=lambda *args: pytest.fail("an unreadable frame was spooled"),
    ) is None


def _raw_decide_frame(payload: dict, **header_fields: object) -> bytes:
    """A ``--decide`` frame written by hand, so a test can give it any ppid."""
    header = json.dumps(
        {
            "version": 1,
            "provider": "claude",
            "log_path": "/tmp/state/claude.jsonl",
            "decide_ms": HOOK_DECISION_WAIT_MS,
            **header_fields,
        },
        separators=(",", ":"),
    ).encode()
    body = json.dumps(payload).encode()
    return b"JRBARHOOK\x01" + struct.pack("!II", len(header), len(body)) + header + body


def _send_raw(sock_dir: Path, frame: bytes) -> socket.socket:
    client = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
    client.settimeout(5.0)
    client.connect(str(sock_dir / "hook-ingress.sock"))
    client.sendall(frame)
    client.shutdown(socket.SHUT_WR)
    return client


def test_an_orphaned_decide_hook_is_refused_and_parks_nothing(sock_dir: Path) -> None:
    """A hook the agent outlived (ppid 1) is delivered when it is an ordinary
    event, but a ``--decide`` one is refused: nobody is left to read a
    verdict, and without a ppid it would look like the Python decide client
    and park an ask that can never be answered."""
    broker = _broker()
    seen = _Seen()
    service = _service(sock_dir, broker, seen)
    try:
        orphan = _send_raw(sock_dir, _raw_decide_frame(PERMISSION, ppid=1, ppid_start=1.5))
        try:
            assert orphan.recv(64) == b"refused_invalid\n"
        finally:
            orphan.close()
        assert broker.parked_count() == 0
        assert not broker.parked_event.is_set()
        assert len(seen) == 0

        # Positive control: the same frame from a live parent does park, so
        # the absence above is the ppid's doing.
        live = _send_raw(sock_dir, _raw_decide_frame(PERMISSION, ppid=os.getpid(), ppid_start=1.5))
        try:
            assert live.recv(64) == b"accepted\n"
            broker.next_parked()
            assert broker.parked_count() == 1
        finally:
            live.close()
    finally:
        assert service.close(timeout_seconds=2.0)
