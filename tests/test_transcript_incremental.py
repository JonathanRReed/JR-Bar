import json
import os
import random
from datetime import datetime, timezone

import pytest

from jrbar.collector import (
    AgentMonitor,
    _transcript_metadata,
    iter_claude_transcript_file,
    iter_codex_transcript_file,
    read_recent_lines,
)
from jrbar.transcript_sessions import (
    _recent_lines,
    iter_gemini_transcript_file,
    iter_pi_transcript_file,
)
from jrbar.transcript_tail import TranscriptTail

SESSION = "00000000-0000-4000-8000-000000000001"
PARSERS = {
    "claude": iter_claude_transcript_file,
    "codex": iter_codex_transcript_file,
    "pi": iter_pi_transcript_file,
    "gemini": iter_gemini_transcript_file,
}


def header(provider):
    if provider == "pi":
        return {"type": "session", "id": SESSION, "cwd": "/synthetic", "timestamp": "bad"}
    if provider == "gemini":
        return {"sessionId": SESSION, "startTime": "bad"}
    return {}


def row(provider, rng, index):
    stamp = rng.choice([None, "bad", f"2026-10-25T12:00:{index % 60:02d}Z"])
    text = rng.choice(["synthetic", "日本語", "one\u2028two", "", "x" * 300])
    if provider == "claude":
        value = rng.choice([
            {"type": "user", "message": {"content": text}},
            {"type": "assistant", "message": {"content": [{"type": "tool_use", "name": "Read", "id": "tool"}]}},
            {"type": "user", "toolUseResult": {"is_error": True, "content": text}},
            {"type": "assistant", "message": {"stop_reason": "end_turn", "content": [{"type": "text", "text": text}]}},
            {"type": "progress", "cwd": "/synthetic/other"},
        ])
    elif provider == "codex":
        value = rng.choice([
            {"type": "turn_context", "payload": {"turn_id": str(index), "cwd": "/synthetic"}},
            {"type": "response_item", "payload": {"type": "message", "role": "user", "content": text}},
            {"type": "response_item", "payload": {"type": "reasoning"}},
            {"type": "response_item", "payload": {"type": "function_call", "name": "Read", "call_id": "tool"}},
            {"type": "response_item", "payload": {"type": "message", "role": "assistant", "content": text}},
        ])
    elif provider == "pi":
        value = {"type": "message", "message": rng.choice([
            {"role": "user", "content": text},
            {"role": "assistant", "content": [{"type": "toolCall", "name": "Read", "id": "tool"}]},
            {"role": "toolResult", "isError": True, "toolCallId": "tool"},
            {"role": "assistant", "stopReason": "stop", "content": text},
        ])}
    else:
        message = {"id": str(index), "type": rng.choice(["user", "gemini", "info"]), "content": text, "timestamp": stamp}
        value = rng.choice([message, {"$set": {"messages": [message, message]}}, {"$push": {"messages": message}}])
    value["timestamp"] = stamp
    return value


def encoded(value):
    return json.dumps(value, ensure_ascii=False).encode() + b"\n"


@pytest.mark.parametrize("provider", PARSERS)
@pytest.mark.parametrize("seed", range(8))
def test_incremental_matches_full_reader_after_every_mutation(tmp_path, monkeypatch, provider, seed):
    from jrbar import transcript_sessions
    from jrbar.models import parse_datetime

    # The existing pi/Gemini malformed-string path defaults to now. Both
    # readers must see the same instant for an exact differential comparison.
    now = datetime(2026, 10, 25, tzinfo=timezone.utc)
    monkeypatch.setattr(transcript_sessions, "parse_datetime", lambda value: parse_datetime(value, now))
    rng = random.Random(seed)
    parser = PARSERS[provider]
    path = tmp_path / f"{SESSION}.jsonl"
    initial = encoded(header(provider)) + b"".join(encoded(row(provider, rng, i)) for i in range(650))
    path.write_bytes(initial)
    monitor = AgentMonitor(sources=())
    assert monitor._cached_transcript_records(provider, path, parser) == tuple(
        _transcript_metadata(event) for event in parser(path)
    )
    pending = b""
    for index in range(100):
        operation = rng.randrange(10)
        if operation < 6:
            data = pending or encoded(row(provider, rng, index))
            cut = rng.randrange(len(data) + 1)
            with path.open("ab") as stream:
                stream.write(data[:cut])
            pending = data[cut:]
        elif operation == 6:
            with path.open("r+b") as stream:
                stream.truncate(rng.randrange(path.stat().st_size + 1))
            pending = b""
        elif operation == 7:
            # Preserve size and mtime on rotation to defeat a size/mtime cache.
            old = path.stat()
            replacement = tmp_path / "replacement"
            data = encoded(header(provider)) + encoded(row(provider, rng, index))
            replacement.write_bytes(data + b" " * max(0, old.st_size - len(data)))
            os.utime(replacement, ns=(old.st_atime_ns, old.st_mtime_ns))
            replacement.replace(path)
            pending = b""
        elif operation == 8:
            path.write_bytes(initial if index % 2 else encoded(header(provider)))
            pending = b""
        # Touches must restamp fallback rows and rebuild Claude's heartbeat.
        stamp = 1_800_000_000_000_000_000 + index * 60_000_000_000
        os.utime(path, ns=(stamp, stamp))
        expected = tuple(_transcript_metadata(event) for event in parser(path))
        assert monitor._cached_transcript_records(provider, path, parser) == expected, (seed, index, operation)


@pytest.mark.parametrize("legacy", [False, True])
def test_incremental_byte_window_matches_full_reader(tmp_path, legacy):
    path = tmp_path / "tail"
    maximum = 256 * 1024 * 8 + 64 * 1024 if legacy else 8 * 1024 * 1024
    tail = TranscriptTail(maximum)
    full = _recent_lines if legacy else read_recent_lines
    # Cross the byte cap, long-line filter, chunk edges, CRLF, UTF-8 and
    # splitlines separators, including an unfinished final JSON record.
    path.write_bytes(b"x" * (maximum + 100) + b"\n" + encoded({"type": "old"}))
    for data in [b"\r", b"\n", b"z" * 262145 + b"\n", b"\xff\n", "日本語\u2028end".encode(), b"\n"]:
        with path.open("ab") as stream:
            stream.write(data)
        tail.update(path)
        assert tail.lines(500, legacy=legacy) == full(path, 500)


def test_append_reuses_rows_and_reparses_partial_utf8(tmp_path, monkeypatch):
    path = tmp_path / f"{SESSION}.jsonl"
    parser = iter_claude_transcript_file
    path.write_bytes(b"".join(encoded({"type": "user", "timestamp": "2026-10-25T12:00:00Z", "message": {"content": text}})
                             for text in ("first", "second")))
    monitor = AgentMonitor(sources=())
    second = monitor._cached_transcript_records("claude", path, parser)[1]
    original = json.loads
    decoded = []

    def loads(data, *args, **kwargs):
        decoded.append(data)
        return original(data, *args, **kwargs)

    monkeypatch.setattr(json, "loads", loads)
    data = encoded({"type": "user", "timestamp": "2026-10-25T12:00:01Z", "message": {"content": "日本語"}})
    cut = data.index("日".encode()) + 1
    with path.open("ab") as stream:
        stream.write(data[:cut])
    monitor._cached_transcript_records("claude", path, parser)
    with path.open("ab") as stream:
        stream.write(data[cut:])
    actual = monitor._cached_transcript_records("claude", path, parser)
    # The first row sees a new mtime fallback on each scan. The second row
    # keeps its incoming stamp and must never be decoded or rebuilt again.
    assert len(decoded) == 4
    assert actual[1] is second
    assert actual[2].message == "日本語"


def test_rotation_changes_the_scan_signature_even_with_same_size_and_mtime(tmp_path):
    from jrbar.collector import CLAUDE_TRANSCRIPT_PROVIDER, SourceSpec

    path = tmp_path / f"{SESSION}.jsonl"
    path.write_bytes(encoded({"type": "user", "message": {"content": "first"}}))
    monitor = AgentMonitor(sources=(SourceSpec(CLAUDE_TRANSCRIPT_PROVIDER, tmp_path),))
    signature = monitor.input_signature()
    previous = path.stat()
    replacement = tmp_path / "replacement"
    replacement.write_bytes(path.read_bytes().replace(b"first", b"other"))
    os.utime(replacement, ns=(previous.st_atime_ns, previous.st_mtime_ns))
    replacement.replace(path)
    assert monitor.input_signature() != signature
    assert next(monitor.iter_records()).message == "other"


def test_growing_tail_reads_only_the_append_and_end_guard(tmp_path, monkeypatch):
    from pathlib import Path

    path = tmp_path / "tail"
    path.write_bytes(b"old\n" * 100_000)
    tail = TranscriptTail(8 * 1024 * 1024)
    tail.update(path)
    tail.lines(500)
    with path.open("ab") as stream:
        stream.write(b"new\n")
    original = Path.open
    reads = []

    class Reader:
        def __init__(self, handle):
            self.handle = handle

        def __enter__(self):
            return self

        def __exit__(self, *args):
            self.handle.close()

        def __getattr__(self, name):
            return getattr(self.handle, name)

        def read(self, size):
            reads.append(size)
            return self.handle.read(size)

    monkeypatch.setattr(Path, "open", lambda self, *args, **kwargs: Reader(original(self, *args, **kwargs)))
    tail.update(path)
    assert tail.lines(500) == ["old"] * 499 + ["new"]
    assert sum(reads) == 256 + len(b"new\n")
