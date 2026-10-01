"""A payload past the shim's 1 MiB cap is not dropped silently.

A PostToolUse that carries base64 screenshots, or a PermissionRequest for a very
large Write, used to vanish: the daemon never saw the tool finish or the ask.
The shim now hands the daemon a small record for it instead -- the event, the
session, the tool and ``"payload_truncated": true`` -- found by a single pass
over the head of the payload it already holds, never forwarding the content.
"""

from __future__ import annotations

import json
import os
import shutil
import subprocess
import tempfile
import time
from pathlib import Path

import pytest

from jrbar.hook_ingress import HookIngressService
from jrbar.hook_ingress_protocol import HookIngressRequest
from tests.test_hook_shim import _FakeIngress

ROOT = Path(__file__).resolve().parents[1]
SHIM = ROOT / "hook" / "build" / "jrbar-hook"
MIB = 1024 * 1024
# Bounds a hang, never a slow machine.
HANG_BOUND_SECONDS = 15.0
TRANSCRIPT = "/Users/me/.claude/projects/demo/session-1.jsonl"


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


def _compact(document: object) -> str:
    return json.dumps(document, separators=(",", ":"))


def _fingerprint(tool_input: object) -> str:
    """What the shim computes for a call whose input it could not keep: the
    64-bit FNV-1a of the first 64 KiB of the input's JSON text, in 16 hex digits."""
    value = 0xCBF29CE484222325
    for byte in _compact(tool_input).encode()[: 64 * 1024]:
        value = ((value ^ byte) * 0x100000001B3) & 0xFFFFFFFFFFFFFFFF
    return f"{value:016x}"


def _post_tool_use(**overrides: object) -> dict[str, object]:
    """Claude Code's PostToolUse for a screenshot tool: small input, giant response."""
    document: dict[str, object] = {
        "session_id": "session-1",
        "transcript_path": TRANSCRIPT,
        "cwd": "/Users/me/demo",
        "permission_mode": "default",
        "hook_event_name": "PostToolUse",
        "tool_name": "mcp__shots__capture",
        "tool_input": {"url": "https://example.test/", "full_page": True},
        "tool_response": {"image": "A" * (MIB + 4096)},
        "tool_use_id": "toolu_01",
    }
    document.update(overrides)
    return document


def _run(shim: Path, state_dir: Path, provider: str, payload: str, *extra: str) -> subprocess.CompletedProcess:
    return subprocess.run(
        [str(shim), "--provider", provider, *extra],
        input=payload.encode("utf-8"),
        capture_output=True,
        env=dict(os.environ, JRBAR_STATE_DIR=str(state_dir)),
        timeout=HANG_BOUND_SECONDS,
    )


def _delivered(shim: Path, state_dir: Path, provider: str, payload: str, *extra: str):
    """Run the shim against a fake ingress; the decoded request it received."""
    ingress = _FakeIngress(state_dir)
    try:
        result = _run(shim, state_dir, provider, payload, *extra)
        arrived = ingress.wait_for_request()
    finally:
        ingress.close()
    assert result.returncode == 0
    assert result.stdout == b""
    assert arrived, "nothing reached the ingress"
    request = ingress.requests[0]
    assert request is not None
    return request


def test_an_oversize_post_tool_use_reaches_the_daemon_as_a_metadata_record(shim: Path, sock_dir: Path) -> None:
    payload = _compact(_post_tool_use())
    assert len(payload) > MIB
    request = _delivered(shim, sock_dir, "claude", payload)
    assert request.provider == "claude"
    assert request.decide_ms is None
    assert len(request.payload_text) < 4096, "the content was forwarded"
    assert json.loads(request.payload_text) == {
        "hook_event_name": "PostToolUse",
        "session_id": "session-1",
        "tool_name": "mcp__shots__capture",
        "transcript_path": TRANSCRIPT,
        # The call's own input, small: it is what names the request this
        # PostToolUse resolves. The giant tool_response is gone.
        "tool_input": {"url": "https://example.test/", "full_page": True},
        "payload_truncated": True,
    }
    assert not (sock_dir / "claude.pending.jsonl").exists()


def test_an_oversize_payload_is_spooled_as_the_metadata_record_when_the_daemon_is_down(
    shim: Path, sock_dir: Path
) -> None:
    before_ms = int(time.time() * 1000)
    assert _run(shim, sock_dir, "claude", _compact(_post_tool_use())).returncode == 0
    after_ms = int(time.time() * 1000)
    rows = [json.loads(line) for line in (sock_dir / "claude.pending.jsonl").read_text().splitlines()]
    assert len(rows) == 1
    assert before_ms <= rows[0]["queued_at_ms"] <= after_ms
    record = json.loads(rows[0]["payload"])
    assert record["hook_event_name"] == "PostToolUse" and record["payload_truncated"] is True
    assert len(rows[0]["payload"]) < 4096


def test_a_large_write_permission_request_is_delivered_without_its_input_and_never_held(
    shim: Path, sock_dir: Path
) -> None:
    """The ask must still reach the daemon, but a request whose input cannot be
    shown is not parked for a verdict: the shim waits for none and prints
    nothing, so the agent's own prompt appears at once."""
    payload = _compact(
        {
            "session_id": "session-2",
            "transcript_path": TRANSCRIPT,
            "hook_event_name": "PermissionRequest",
            "tool_name": "Write",
            "tool_input": {"file_path": "/Users/me/demo/big.txt", "content": "x" * (MIB + 10)},
            "permission_suggestions": [],
        }
    )
    started = time.monotonic()
    request = _delivered(shim, sock_dir, "claude", payload, "--decide")
    assert time.monotonic() - started < 5.0
    assert request.decide_ms is None, "an oversize ask asked the daemon to hold it"
    record = json.loads(request.payload_text)
    assert record == {
        "hook_event_name": "PermissionRequest",
        "session_id": "session-2",
        "tool_name": "Write",
        "transcript_path": TRANSCRIPT,
        # What tells this call from another huge one in the same session.
        "payload_fingerprint": _fingerprint({"file_path": "/Users/me/demo/big.txt", "content": "x" * (MIB + 10)}),
        "payload_truncated": True,
    }


def test_keys_after_the_giant_value_inside_the_head_are_found(shim: Path, sock_dir: Path) -> None:
    payload = _compact(
        {
            "tool_response": {
                "decoy": {
                    "hook_event_name": "Stop",
                    "session_id": "evil",
                    "text": 'quote " brace } bracket ] \\ "session_id":"evil"',
                    "nested": [{"session_id": "evil"}, [[{"tool_name": "Evil"}]]],
                },
                "filler": "A" * (MIB - 8192),
            },
            "hook_event_name": "PostToolUse",
            "tool_name": "Read",
            "session_id": "real",
            "turn_id": "turn-9",
            "agent_id": "agent-3",
            "after": "B" * (MIB // 2),
        }
    )
    assert payload.index('"session_id":"real"') < MIB < len(payload)
    request = _delivered(shim, sock_dir, "codex", payload)
    assert json.loads(request.payload_text) == {
        "hook_event_name": "PostToolUse",
        "session_id": "real",
        "tool_name": "Read",
        "turn_id": "turn-9",
        "agent_id": "agent-3",
        "payload_truncated": True,
    }


def test_a_tool_input_too_large_to_name_the_call_is_left_out(shim: Path, sock_dir: Path) -> None:
    payload = _compact(
        _post_tool_use(tool_input={"command": "echo " + "z" * (80 * 1024)})
    )
    request = _delivered(shim, sock_dir, "claude", payload)
    record = json.loads(request.payload_text)
    assert "tool_input" not in record
    assert record["hook_event_name"] == "PostToolUse" and record["payload_truncated"] is True
    assert record["payload_fingerprint"] == _fingerprint({"command": "echo " + "z" * (80 * 1024)})
    assert len(request.payload_text) < 4096


def _write_ask_or_done(event: str, session: str, content: str, **extra: object) -> str:
    document: dict[str, object] = {
        "session_id": session,
        "hook_event_name": event,
        "tool_name": "Write",
        "tool_input": {"file_path": "/Users/me/demo/big.txt", "content": content},
    }
    document.update(extra)
    return _compact(document)


def test_two_different_huge_calls_in_one_session_carry_different_fingerprints(shim: Path, sock_dir: Path) -> None:
    """Without the input, two huge Writes in one session would be one request."""
    first = _delivered(shim, sock_dir, "claude", _write_ask_or_done("PermissionRequest", "s", "a" * (MIB + 10)))
    (sock_dir / "hook-ingress.sock").unlink()
    second = _delivered(shim, sock_dir, "claude", _write_ask_or_done("PermissionRequest", "s", "b" * (MIB + 10)))
    one = json.loads(first.payload_text)["payload_fingerprint"]
    other = json.loads(second.payload_text)["payload_fingerprint"]
    assert one != other
    for fingerprint in (one, other):
        assert len(fingerprint) == 16 and all(c in "0123456789abcdef" for c in fingerprint)


def test_an_ask_and_its_post_tool_use_carry_the_same_fingerprint_whatever_follows_the_input(
    shim: Path, sock_dir: Path
) -> None:
    """The same call, whose ask and result both went past the cap, names the
    same request: the fingerprint is of the input alone, however far the event
    around it ran and wherever the head ended."""
    content = "c" * (MIB + 10)
    ask = _delivered(shim, sock_dir, "claude", _write_ask_or_done("PermissionRequest", "s", content))
    (sock_dir / "hook-ingress.sock").unlink()
    done = _delivered(
        shim,
        sock_dir,
        "claude",
        _write_ask_or_done("PostToolUse", "s", content, tool_response={"type": "create", "filePath": "x"}),
    )
    assert json.loads(ask.payload_text)["payload_fingerprint"] == json.loads(done.payload_text)["payload_fingerprint"]


def test_an_input_that_was_kept_needs_no_fingerprint_and_a_missing_one_gets_none(shim: Path, sock_dir: Path) -> None:
    kept = _delivered(shim, sock_dir, "claude", _compact(_post_tool_use()))
    assert "payload_fingerprint" not in json.loads(kept.payload_text)
    (sock_dir / "hook-ingress.sock").unlink()
    no_input = _compact(_post_tool_use(tool_input=None))
    no_input = no_input.replace('"tool_input":null,', "")
    assert "tool_input" not in no_input
    record = json.loads(_delivered(shim, sock_dir, "claude", no_input).payload_text)
    assert "tool_input" not in record and "payload_fingerprint" not in record


def test_values_that_could_not_be_copied_safely_are_left_out(shim: Path, sock_dir: Path) -> None:
    """A value that is not plain printable ASCII (an escape, a control byte,
    UTF-8) or is too long is not copied: the record keeps what it can."""
    payload = _compact(_post_tool_use(tool_name="café", turn_id="t\\u0041", agent_id="a" * 300))
    request = _delivered(shim, sock_dir, "claude", payload)
    record = json.loads(request.payload_text)
    assert record["session_id"] == "session-1" and record["hook_event_name"] == "PostToolUse"
    assert "tool_name" not in record and "turn_id" not in record and "agent_id" not in record


def test_an_oversize_payload_whose_identity_is_not_in_the_head_is_still_dropped(
    shim: Path, sock_dir: Path
) -> None:
    """The scan reads the first MiB it already holds and nothing more: an
    event named only after more than a MiB of content, or never named a
    session, gives the daemon nothing to place, so it is dropped as before."""
    after_the_head = (
        '{"tool_response":{"image":"' + "A" * (MIB + 10) + '"},'
        '"hook_event_name":"PostToolUse","session_id":"s"}'
    )
    no_session = '{"hook_event_name":"PostToolUse","tool_name":"Read","blob":"' + "A" * (MIB + 10) + '"}'
    ingress = _FakeIngress(sock_dir)
    try:
        for payload in (after_the_head, no_session):
            result = _run(shim, sock_dir, "claude", payload)
            assert result.returncode == 0 and result.stdout == b""
        assert not ingress.wait_for_request(0.5)
    finally:
        ingress.close()
    assert not (sock_dir / "claude.pending.jsonl").exists()


def test_only_claude_and_codex_get_a_metadata_record(shim: Path, sock_dir: Path) -> None:
    """Other providers name their identity differently (Cursor's conversation,
    Antigravity's envelope); a record that carried only a session id would be
    read as a malformed one, so their oversize payloads are dropped as before."""
    payload = _compact(_post_tool_use())
    ingress = _FakeIngress(sock_dir)
    try:
        for provider in ("gemini", "opencode", "pi"):
            result = _run(shim, sock_dir, provider, payload)
            assert result.returncode == 0
            assert result.stdout == (b"{}\n" if provider == "gemini" else b"")
        assert not ingress.wait_for_request(0.5)
    finally:
        ingress.close()
    assert not list(sock_dir.glob("*.pending.jsonl"))
    cursor = _run(shim, sock_dir, "cursor", payload)
    assert cursor.returncode == 0 and cursor.stdout == b"{}\n"


def test_an_oversize_status_line_is_still_answered_with_the_daemons_line_and_sent_nowhere(
    shim: Path, sock_dir: Path
) -> None:
    (sock_dir / "statusline.txt").write_text("JR-Bar · idle\n")
    payload = _compact({"session_id": "s", "hook_event_name": "PostToolUse", "blob": "A" * (MIB + 10)})
    ingress = _FakeIngress(sock_dir)
    try:
        result = subprocess.run(
            [str(shim), "--statusline"],
            input=payload.encode(),
            capture_output=True,
            env=dict(os.environ, JRBAR_STATE_DIR=str(sock_dir)),
            timeout=HANG_BOUND_SECONDS,
        )
        assert not ingress.wait_for_request(0.5)
    finally:
        ingress.close()
    assert result.returncode == 0 and result.stdout == b"JR-Bar \xc2\xb7 idle\n"


def test_the_real_ingress_takes_an_oversize_ask_as_an_ordinary_hook_and_parks_nothing(
    shim: Path, sock_dir: Path
) -> None:
    """End to end against the real service: accepted and queued like any hook,
    never handed to the decision broker, and the shim prints nothing."""

    class _Broker:
        def __init__(self) -> None:
            self.parks = 0

        def park(self, *args: object, **kwargs: object) -> None:
            self.parks += 1

        def observe(self, *args: object, **kwargs: object) -> int:
            return 0

        def release_slot(self, *args: object, **kwargs: object) -> None:
            return None

    seen: list[HookIngressRequest] = []
    broker = _Broker()
    service = HookIngressService(
        process=seen.append,
        socket_path=sock_dir / "hook-ingress.sock",
        rejection_path=sock_dir / "rejections.jsonl",
        decision_broker=broker,
        backlog_cleared=lambda: None,
    )
    service.start()
    payload = _compact(
        {
            "session_id": "session-3",
            "hook_event_name": "PermissionRequest",
            "tool_name": "Write",
            "tool_input": {"file_path": "/Users/me/demo/big.txt", "content": "x" * (MIB + 10)},
        }
    )
    try:
        result = _run(shim, sock_dir, "claude", payload, "--decide")
        assert service.wait_idle(timeout_seconds=HANG_BOUND_SECONDS)
    finally:
        assert service.close(timeout_seconds=2.0)
    assert result.returncode == 0 and result.stdout == b""
    assert broker.parks == 0
    assert len(seen) == 1 and seen[0].decide_ms is None
    assert json.loads(seen[0].payload_text)["payload_truncated"] is True
