"""The Python hook client keeps an oversize payload the way the compiled shim does.

``python -m jrbar.hook_client`` is the command that runs when no compiled shim
is installed. A payload past 1 MiB (a PostToolUse carrying screenshots, a
PermissionRequest for a very large Write) used to vanish there, so the daemon
never saw the tool finish or the ask. For Claude and Codex it now sends the
same small ``payload_truncated`` record as hook/jrbar-hook.c, and these tests
feed the same payload to both and compare the two records byte for byte.
"""

from __future__ import annotations

import io
import json
import shutil
import subprocess
import tempfile
from pathlib import Path

import pytest

from jrbar import hook_client
from jrbar.hook_ingress_protocol import MAX_HOOK_INGRESS_PAYLOAD_BYTES
from tests.test_hook_shim_oversize import (
    MIB,
    TRANSCRIPT,
    _compact,
    _post_tool_use,
    _run,
    _write_ask_or_done,
)

ROOT = Path(__file__).resolve().parents[1]
SHIM = ROOT / "hook" / "build" / "jrbar-hook"
LOG = Path("/tmp/jrbar-test/claude.jsonl")


@pytest.fixture
def state_dir():
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


class _Buffer(io.BytesIO):
    def __init__(self, value: bytes) -> None:
        super().__init__(value)
        self.read_sizes: list[int] = []

    def read(self, size: int | None = -1) -> bytes:
        self.read_sizes.append(-1 if size is None else size)
        return super().read(size)


class _Stdin:
    def __init__(self, value: bytes) -> None:
        self.buffer = _Buffer(value)


class _Stdout(io.StringIO):
    pass


def _feed(monkeypatch: pytest.MonkeyPatch, payload: str | bytes) -> _Stdin:
    source = _Stdin(payload if isinstance(payload, bytes) else payload.encode("utf-8"))
    monkeypatch.setattr(hook_client.sys, "stdin", source)
    return source


def _capture_client(monkeypatch: pytest.MonkeyPatch) -> list[tuple[str, Path, str]]:
    sent: list[tuple[str, Path, str]] = []
    monkeypatch.setattr(hook_client, "run_hook_client", lambda *args: sent.append(args) or 0)
    monkeypatch.setattr(
        hook_client,
        "run_decide_hook_client",
        lambda *_args: pytest.fail("an oversize ask was held for a verdict"),
    )
    return sent


@pytest.mark.parametrize("provider", ["claude", "codex"])
def test_an_oversize_payload_reaches_the_client_as_the_metadata_record(
    monkeypatch: pytest.MonkeyPatch, provider: str
) -> None:
    sent = _capture_client(monkeypatch)
    payload = _compact(_post_tool_use())
    assert len(payload) > MIB
    source = _feed(monkeypatch, payload)

    assert hook_client.hook_client_main(provider, LOG) == 0

    # Never more than the head is read: the whole payload is never buffered.
    assert source.buffer.read_sizes == [MAX_HOOK_INGRESS_PAYLOAD_BYTES + 1]
    assert [(name, path) for name, path, _ in sent] == [(provider, LOG)]
    record = json.loads(sent[0][2])
    assert record == {
        "hook_event_name": "PostToolUse",
        "session_id": "session-1",
        "tool_name": "mcp__shots__capture",
        "transcript_path": TRANSCRIPT,
        "tool_input": {"url": "https://example.test/", "full_page": True},
        "payload_truncated": True,
    }
    assert len(sent[0][2]) < 4096, "the content was forwarded"


def test_an_oversize_ask_is_sent_plain_and_never_held_for_a_verdict(
    monkeypatch: pytest.MonkeyPatch, capsys: pytest.CaptureFixture[str]
) -> None:
    """The decide lane waits for a verdict the person gives against the
    ask's input. A record cannot show that input, so nothing is held and
    nothing is printed: the agent's own prompt appears at once."""
    sent = _capture_client(monkeypatch)
    payload = _write_ask_or_done("PermissionRequest", "session-2", "x" * (MIB + 10))
    _feed(monkeypatch, payload)

    assert hook_client.hook_client_main("claude", LOG, decide=True) == 0

    assert len(sent) == 1
    record = json.loads(sent[0][2])
    assert record["hook_event_name"] == "PermissionRequest"
    assert record["payload_truncated"] is True and len(record["payload_fingerprint"]) == 16
    assert capsys.readouterr().out == ""


@pytest.mark.parametrize("provider", ["gemini", "opencode", "pi", "cursor", "devin", "grok"])
def test_other_providers_are_dropped_as_before(
    monkeypatch: pytest.MonkeyPatch, capsys: pytest.CaptureFixture[str], provider: str
) -> None:
    _capture_client(monkeypatch)
    monkeypatch.setattr(
        hook_client,
        "run_hook_client",
        lambda *_args: pytest.fail(f"an oversize {provider} payload reached admission"),
    )
    _feed(monkeypatch, _compact(_post_tool_use()))

    assert hook_client.hook_client_main(provider, LOG) == 0

    assert capsys.readouterr().out == ("{}\n" if provider in ("cursor", "gemini") else "")


def test_a_head_that_names_no_session_is_dropped(monkeypatch: pytest.MonkeyPatch) -> None:
    monkeypatch.setattr(
        hook_client,
        "run_hook_client",
        lambda *_args: pytest.fail("a payload that names no session reached admission"),
    )
    _feed(monkeypatch, '{"hook_event_name":"PostToolUse","blob":"' + "A" * (MIB + 10) + '"}')
    assert hook_client.hook_client_main("claude", LOG) == 0


def _corpus() -> dict[str, str | bytes]:
    """Payloads that stress the scan the same way tests/test_hook_shim_oversize.py does."""
    giant_input = {"command": "echo " + "z" * (80 * 1024)}
    cases: dict[str, str | bytes] = {
        "small input kept": _compact(_post_tool_use()),
        "large write fingerprinted": _write_ask_or_done("PermissionRequest", "s", "a" * (MIB + 10)),
        "tool input too large to keep": _compact(_post_tool_use(tool_input=giant_input)),
        "post tool use of a huge write": _write_ask_or_done(
            "PostToolUse", "s", "a" * (MIB + 10), tool_response={"type": "create", "filePath": "x"}
        ),
        "keys after the giant value": _compact(
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
        ),
        "identity after the head": (
            '{"tool_response":{"image":"' + "A" * (MIB + 10) + '"},'
            '"hook_event_name":"PostToolUse","session_id":"s"}'
        ),
        "no session": '{"hook_event_name":"PostToolUse","tool_name":"Read","blob":"' + "A" * (MIB + 10) + '"}',
        "no tool input": _compact(_post_tool_use(tool_input=None)).replace('"tool_input":null,', ""),
        "tool input is a list": _compact(_post_tool_use(tool_input=["a", "b"])),
        "tool input is a string": _compact(_post_tool_use(tool_input="plain")),
        "head ends inside the tool input": _compact(
            {
                "hook_event_name": "PostToolUse",
                "session_id": "s",
                "filler": "F" * (MIB - 30_000),
                "tool_input": {"content": "y" * 60_000},
            }
        ),
        "head ends inside a short tool input": _compact(
            {
                "hook_event_name": "PostToolUse",
                "session_id": "s",
                "filler": "F" * (MIB - 200),
                "tool_input": {"content": "y" * 60_000},
            }
        ),
        "second tool input is ignored": (
            '{"hook_event_name":"PostToolUse","session_id":"s","tool_input":{"a":1},'
            '"tool_input":{"b":2},"blob":"' + "A" * (MIB + 10) + '"}'
        ),
        "tool input of exactly the cap": _compact(
            {
                "hook_event_name": "PostToolUse",
                "session_id": "s",
                "tool_input": {"content": "y" * (64 * 1024 - 14)},
                "blob": "A" * (MIB + 10),
            }
        ),
        "tool input one byte past the cap": _compact(
            {
                "hook_event_name": "PostToolUse",
                "session_id": "s",
                "tool_input": {"content": "y" * (64 * 1024 - 13)},
                "blob": "A" * (MIB + 10),
            }
        ),
        "duplicate keys keep the first": (
            '{"session_id":"one","session_id":"two","hook_event_name":"Stop","hook_event_name":"Start",'
            '"tool_name":"a","tool_name":"b","blob":"' + "A" * (MIB + 10) + '"}'
        ),
        "values that cannot be copied": _compact(
            _post_tool_use(tool_name="café", turn_id="t\\u0041", agent_id="a" * 300)
        ),
        "value of exactly the cap": _compact(_post_tool_use(agent_id="a" * 256, turn_id="t" * 257)),
        "empty and non-string values": (
            '{"hook_event_name":"PostToolUse","session_id":"s","tool_name":"","turn_id":7,"agent_id":null,'
            '"transcript_path":' + json.dumps("/p" * 400) + ',"blob":"' + "A" * (MIB + 10) + '"}'
        ),
        "path at the cap": _compact(_post_tool_use(transcript_path="/" + "p" * 1023)),
        "path past the cap": _compact(_post_tool_use(transcript_path="/" + "p" * 1024)),
        "pretty printed": json.dumps(_post_tool_use(), indent=2),
        "whitespace around everything": (
            " \n\t{ \"hook_event_name\" : \"PostToolUse\" ,\r\n \"session_id\" : \"s\" , "
            + '"tool_input" : { "k" : 1 } , "blob" : "' + "A" * (MIB + 10) + '" }'
        ),
        "scalars and nested values between the keys": (
            '{"a":1,"b":true,"c":null,"d":-2.5e3,"e":[1,[2,{"f":"}"}]],"hook_event_name":"PostToolUse",'
            '"g":{"h":{"i":[]}},"session_id":"s","blob":"' + "A" * (MIB + 10) + '"}'
        ),
        "escaped quotes and backslashes in skipped strings": (
            '{"x":"a\\"b\\\\","y":"\\\\\\"","hook_event_name":"PostToolUse","session_id":"s",'
            '"blob":"' + "A" * (MIB + 10) + '"}'
        ),
        "raw utf-8 in a skipped value cut by the head": (
            '{"hook_event_name":"PostToolUse","session_id":"s","text":"' + "é" * MIB + '"}'
        ).encode("utf-8"),
        "raw utf-8 in the tool input": json.dumps(
            _post_tool_use(tool_input={"note": "café ☃"}), separators=(",", ":"), ensure_ascii=False
        ).encode("utf-8"),
        "control byte in a value": _compact(_post_tool_use()).encode().replace(b"session-1", b"sess\x01on"),
        "not json": b"x" * (MIB + 10),
        "array at the top": b"[" + b'"x",' * (MIB // 4),
        "unterminated string key": b'{"hook_event_name' + b"A" * (MIB + 10),
        "key without a colon": b'{"hook_event_name" "PostToolUse"' + b" " * (MIB + 10),
        "stray comma runs": b'{,,,"hook_event_name":"Stop",,"session_id":"s",,' + b"," * (MIB + 10),
        "no event": _compact({"session_id": "s", "blob": "A" * (MIB + 10)}),
    }
    return cases


_CORPUS = _corpus()


def _spooled_record(shim: Path, state_dir: Path, provider: str, payload: str | bytes) -> str | None:
    """What the compiled shim spools for ``payload`` when no daemon is listening."""
    assert _run(shim, state_dir, provider, payload).returncode == 0
    spool = state_dir / f"{provider}.pending.jsonl"
    if not spool.exists():
        return None
    rows = [json.loads(line) for line in spool.read_text(encoding="utf-8").splitlines()]
    spool.unlink()
    assert len(rows) == 1
    return rows[0]["payload"]


@pytest.mark.parametrize("name", sorted(_CORPUS))
@pytest.mark.parametrize("provider", ["claude", "codex"])
def test_the_python_record_is_the_compiled_shims_record_byte_for_byte(
    shim: Path, state_dir: Path, name: str, provider: str
) -> None:
    payload = _CORPUS[name]
    raw = payload if isinstance(payload, bytes) else payload.encode("utf-8")
    assert len(raw) > MIB, "a payload the cap would keep whole proves nothing"

    expected = _spooled_record(shim, state_dir, provider, raw)
    actual = hook_client.oversize_payload_record(raw[: MIB + 1])

    assert actual == expected


def test_a_tool_input_that_is_not_utf8_is_dropped_as_the_daemon_would_refuse_it() -> None:
    """The shim copies a kept input byte for byte, so a daemon that cannot
    decode it refuses the frame. Python has no text to send for it either."""
    raw = _compact(_post_tool_use(tool_input={"note": "ab"})).encode().replace(b'"ab"', b'"a\xffb"')
    raw += b" " * (MIB - len(raw) + 10)
    assert hook_client.oversize_payload_record(raw[: MIB + 1]) is None


def test_the_record_never_exceeds_the_shims_record_cap() -> None:
    raw = _compact(_post_tool_use(tool_input={"k": "v" * 65_000}, transcript_path="/" + "p" * 1000)).encode()
    record = hook_client.oversize_payload_record((raw + b" " * MIB)[: MIB + 1])
    assert record is not None
    assert len(record.encode("utf-8")) < 64 * 1024 + 4096
    assert json.loads(record)["tool_input"] == {"k": "v" * 65_000}
