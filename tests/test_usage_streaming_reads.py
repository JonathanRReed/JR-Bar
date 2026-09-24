"""Transcripts are streamed a line at a time, never loaded whole.

A cold Codex scan read each rollout into bytes, joined the chunks, decoded
the lot and split it into lines, all held at once: 2.6 GB at the peak of a
30-day scan, and the allocator never handed the memory back, so the
daemon's footprint only climbed. The reader now streams the checked
descriptor, decodes only the lines that carry a marker, and never holds an
over-cap line whole. These tests pin it to the old whole-file results.
"""

from __future__ import annotations

import json
import os
import tracemalloc
from pathlib import Path

import pytest

from jrbar import usage_stats

SECRET = b"\x07" * 32


def _whole_file_lines(path: Path, info: os.stat_result, resume_offset: int = 0) -> tuple[list[str], int]:
    """The reader as it was: every snapshot byte, decoded, then split."""
    with path.open("rb") as handle:
        handle.seek(resume_offset)
        payload = handle.read(info.st_size - resume_offset)
    cut = payload.rfind(b"\n")
    if cut < 0:
        return [], resume_offset
    payload = payload[: cut + 1]
    return payload.decode("utf-8", errors="replace").splitlines(keepends=True), resume_offset + len(payload)


def _whole_file_claude(path: Path, info: os.stat_result, resume_offset: int = 0) -> usage_stats._ParseResult:
    lines, parsed_size = _whole_file_lines(path, info, resume_offset)
    session_id = f"claude:{info.st_dev}:{info.st_ino}"
    records, malformed = [], 0
    for line in lines:
        if usage_stats.USAGE_MARKER not in line:
            continue
        record = usage_stats._record_from_line(line, session_id, SECRET)
        if record is None:
            malformed += 1
        else:
            records.append(record)
    return usage_stats._ParseResult(records, malformed, True, (), True, parsed_size)


def _whole_file_codex(path: Path, info: os.stat_result, resume_offset: int = 0) -> usage_stats._ParseResult:
    lines, parsed_size = _whole_file_lines(path, info, resume_offset)
    records, windows, malformed, _eof, _legacy = usage_stats._scan_codex_lines(
        lines, fallback_session_id=f"codex:{info.st_dev}:{info.st_ino}", dedupe_secret=SECRET,
    )
    return usage_stats._ParseResult(records, malformed, True, windows, True, parsed_size)


def _claude_row(message_id: str, tokens: int, *, text: str = "") -> dict:
    return {
        "type": "assistant",
        "timestamp": "2026-09-20T12:00:00Z",
        "message": {
            "id": message_id,
            "model": "claude-fable-5",
            "content": [{"type": "text", "text": text}],
            "usage": {
                "input_tokens": tokens,
                "cache_read_input_tokens": tokens // 2,
                "cache_creation_input_tokens": 3,
                "output_tokens": tokens // 4,
            },
        },
    }


def _codex_token_row(total: int, when: str, *, used: float | None = None) -> dict:
    payload: dict = {
        "type": "token_count",
        "info": {
            "total_token_usage": {
                "input_tokens": total,
                "cached_input_tokens": total // 3,
                "cache_write_input_tokens": 0,
                "output_tokens": total // 5,
            },
            "last_token_usage": {
                "input_tokens": 50,
                "cached_input_tokens": 10,
                "cache_write_input_tokens": 0,
                "output_tokens": 7,
            },
        },
    }
    if used is not None:
        payload["rate_limits"] = {"primary": {"used_percent": used, "window_minutes": 300}}
    return {"timestamp": when, "type": "event_msg", "payload": payload}


def _codex_rollout() -> bytes:
    rows: list[bytes] = [
        json.dumps({
            "timestamp": "2026-09-20T11:59:00Z", "type": "session_meta",
            "payload": {"id": "session-one", "timestamp": "2026-09-20T11:59:00Z"},
        }).encode(),
        json.dumps({"type": "turn_context", "payload": {"model": "gpt-6-astra"}}).encode(),
    ]
    for minute in range(40):
        when = f"2026-09-20T12:{minute:02d}:00Z"
        rows.append(json.dumps({
            "timestamp": when, "type": "response_item",
            "payload": {"type": "message", "content": "résumé — 検索 " * 40 + "🙂" * minute},
        }, ensure_ascii=False).encode())
        rows.append(json.dumps(_codex_token_row(1000 * (minute + 1), when, used=minute / 2)).encode())
    rows.append(b'{"type":"event_msg","payload":{"type":"token_count"}, broken')
    rows.append(b'{"type":"event_msg","note":"\xff\xfe bad bytes","payload":{"type":"token_count","info":{}}}')
    rows.append(json.dumps({"type": "turn_context", "payload": {"model": "gpt-6-nova"}}).encode() + b"\r")
    rows.append(json.dumps(_codex_token_row(90_000, "2026-09-20T13:00:00Z", used=40.5)).encode())
    # The snapshot ends inside this line: it is left for the next read.
    return b"\n".join(rows) + b"\n" + json.dumps(_codex_token_row(95_000, "2026-09-20T13:01:00Z")).encode()[:40]


def _claude_transcript() -> bytes:
    rows: list[bytes] = []
    for number in range(60):
        rows.append(json.dumps({"type": "user", "message": {"content": "naïve café " * 30}}, ensure_ascii=False).encode())
        rows.append(json.dumps(_claude_row(f"msg_{number}", 100 + number, text="日本語 🙂" * number), ensure_ascii=False).encode())
    rows.append(b'{"type":"assistant","message":{"usage": broken')
    rows.append(b'{"type":"assistant","timestamp":"2026-09-20T12:00:00Z","message":{"id":"m\xff","model":"x",'
                b'"usage":{"input_tokens":1,"output_tokens":1}}}')
    rows.append(json.dumps(_claude_row("msg_crlf", 5)).encode() + b"\r")
    return b"\n".join(rows) + b"\n" + json.dumps(_claude_row("msg_partial", 9)).encode()[:30]


def _assert_same(streamed: usage_stats._ParseResult, whole: usage_stats._ParseResult) -> None:
    assert streamed.read_ok is whole.read_ok is True
    assert streamed.records == whole.records
    assert streamed.malformed_lines == whole.malformed_lines
    assert streamed.rate_limit_windows == whole.rate_limit_windows
    assert streamed.parsed_size == whole.parsed_size


def test_streamed_parses_match_the_whole_file_reader(tmp_path: Path, monkeypatch: pytest.MonkeyPatch) -> None:
    codex = tmp_path / "rollout.jsonl"
    codex.write_bytes(_codex_rollout())
    claude = tmp_path / "session.jsonl"
    claude.write_bytes(_claude_transcript())
    # Over-cap lines, with and without a marker, both ways round.
    monkeypatch.setattr(usage_stats, "USAGE_RECORD_MAX_BYTES", 4096)
    with codex.open("r+b") as handle:
        body = handle.read()
        big = json.dumps(_codex_token_row(7, "2026-09-20T12:30:00Z")).encode()[:-1] + b',"pad":"' + b"x" * 9000 + b'"}'
        handle.seek(0)
        handle.write(big + b"\n" + b'{"pad":"' + b"y" * 9000 + b'"}\n' + body)
    with claude.open("r+b") as handle:
        body = handle.read()
        big = json.dumps(_claude_row("msg_big", 1, text="z" * 9000)).encode()
        handle.seek(0)
        handle.write(big + b"\n" + b'{"pad":"' + b"y" * 9000 + b'"}\n' + body)

    codex_info, claude_info = os.stat(codex), os.stat(claude)
    streamed = usage_stats._parse_codex_file(codex, codex_info, SECRET)
    whole = _whole_file_codex(codex, codex_info)
    _assert_same(streamed, whole)
    assert len(streamed.records) > 30 and streamed.malformed_lines == 3
    assert streamed.parsed_size < codex_info.st_size

    streamed = usage_stats._parse_file(claude, claude_info, SECRET)
    whole = _whole_file_claude(claude, claude_info)
    _assert_same(streamed, whole)
    assert len(streamed.records) == 62 and streamed.malformed_lines == 2
    assert streamed.parsed_size < claude_info.st_size

    # The incremental tail resumes from a line boundary part way in.
    for path, info, whole_parse in ((codex, codex_info, _whole_file_codex), (claude, claude_info, _whole_file_claude)):
        offset = path.read_bytes().index(b"\n", info.st_size // 2) + 1
        provider = "codex" if path == codex else "claude"
        tail = usage_stats._parse_file_tail(path, info, offset, provider, SECRET)
        _assert_same(tail, whole_parse(path, info, offset))


def test_a_raw_line_separator_no_longer_splits_its_record(tmp_path: Path) -> None:
    """str.splitlines() also breaks on U+2028, U+0085 and friends, which JSON
    leaves raw inside strings: such a record was cut in two and lost."""
    claude = tmp_path / "session.jsonl"
    claude.write_text(
        json.dumps(_claude_row("msg_sep", 40, text="one\u2028two\x85three"), ensure_ascii=False) + "\n",
        encoding="utf-8",
    )
    info = os.stat(claude)
    assert _whole_file_claude(claude, info).records == [], "the old reader kept this record"
    streamed = usage_stats._parse_file(claude, info, SECRET)
    assert streamed.malformed_lines == 0
    assert [record[4] for record in streamed.records] == [40]

    codex = tmp_path / "rollout.jsonl"
    row = _codex_token_row(500, "2026-09-20T12:00:00Z")
    row["payload"]["note"] = "a\u2029b"
    codex.write_text(json.dumps(row, ensure_ascii=False) + "\n", encoding="utf-8")
    info = os.stat(codex)
    assert _whole_file_codex(codex, info).records == [], "the old reader kept this record"
    streamed = usage_stats._parse_codex_file(codex, info, SECRET)
    assert streamed.malformed_lines == 0 and len(streamed.records) == 1


def test_a_file_growing_mid_read_is_parsed_to_its_snapshot(tmp_path: Path) -> None:
    transcript = tmp_path / "session.jsonl"
    first, second = (json.dumps(_claude_row(name, 10)) + "\n" for name in ("msg_a", "msg_b"))
    unfinished = json.dumps(_claude_row("msg_c", 999))
    transcript.write_text(first + second + unfinished[:25], encoding="utf-8")
    frozen = os.stat(transcript)

    snapshot = usage_stats._read_verified_prefix(transcript, frozen)
    assert snapshot is not None
    lines = snapshot.lines(usage_stats._CLAUDE_MARKERS)
    assert next(lines) == first
    # The writer finishes the line and adds another while the read runs.
    with transcript.open("a", encoding="utf-8") as handle:
        handle.write(unfinished[25:] + "\n" + json.dumps(_claude_row("msg_d", 999)) + "\n")
    assert list(lines) == [second]
    assert snapshot.read_ok
    assert snapshot.parsed_size == len((first + second).encode())

    # The next scan resumes exactly where this one stopped.
    grown = os.stat(transcript)
    tail = usage_stats._parse_file_tail(transcript, grown, snapshot.parsed_size, "claude", SECRET)
    assert [record[4] for record in tail.records] == [999, 999]
    assert tail.parsed_size == grown.st_size


def test_a_line_over_a_megabyte_is_counted_but_never_held_whole(tmp_path: Path) -> None:
    cap = usage_stats.USAGE_RECORD_MAX_BYTES
    transcript = tmp_path / "session.jsonl"
    with transcript.open("wb") as handle:
        handle.write(json.dumps(_claude_row("msg_huge", 1, text="h" * (12 * cap))).encode() + b"\n")
        handle.write(b'{"type":"user","blob":"' + b"u" * (3 * cap) + b'"}\n')
        handle.write(json.dumps(_claude_row("msg_after", 21)).encode() + b"\n")
    info = os.stat(transcript)

    tracemalloc.start()
    try:
        result = usage_stats._parse_file(transcript, info, SECRET)
        _current, peak = tracemalloc.get_traced_memory()
    finally:
        tracemalloc.stop()

    assert result.read_ok
    assert result.malformed_lines == 1, "only the over-cap line with a marker is malformed"
    assert [record[4] for record in result.records] == [21]
    assert result.parsed_size == info.st_size
    assert peak < 4 * cap, f"a 12 MiB line peaked at {peak / cap:.1f} MiB"


@pytest.mark.parametrize("offset", [-3, -1, 0, 5])
def test_a_marker_straddling_two_pieces_of_an_over_cap_line_is_seen(
    tmp_path: Path, monkeypatch: pytest.MonkeyPatch, offset: int,
) -> None:
    monkeypatch.setattr(usage_stats, "USAGE_RECORD_MAX_BYTES", 1024)
    monkeypatch.setattr(usage_stats, "_READ_BUFFER_BYTES", 64)
    marker = usage_stats.CODEX_MARKER.encode()
    # The head read is cap + 1 bytes; pieces then follow every 64 bytes.
    at = 1025 + 64 * 3 + offset
    line = b"x" * at + marker + b"y" * 700 + b"\n"
    rollout = tmp_path / "rollout.jsonl"
    rollout.write_bytes(line + json.dumps(_codex_token_row(30, "2026-09-20T12:00:00Z")).encode() + b"\n")

    result = usage_stats._parse_codex_file(rollout, os.stat(rollout), SECRET)

    assert result.malformed_lines == 1
    assert len(result.records) == 1
    assert result.parsed_size == rollout.stat().st_size


def test_a_big_transcript_streams_in_bounded_memory_and_closes_its_file(tmp_path: Path) -> None:
    rollout = tmp_path / "rollout.jsonl"
    filler = json.dumps({"type": "response_item", "payload": {"content": "w" * 4000}}).encode() + b"\n"
    with rollout.open("wb") as handle:
        for minute in range(4000):
            handle.write(filler)
            if minute % 400 == 0:
                handle.write(json.dumps(_codex_token_row(minute + 1, "2026-09-20T12:00:00Z")).encode() + b"\n")
    info = os.stat(rollout)
    assert info.st_size > 15 * 1024 * 1024
    open_before = len(os.listdir("/dev/fd"))

    tracemalloc.start()
    try:
        result = usage_stats._parse_codex_file(rollout, info, SECRET)
        _current, peak = tracemalloc.get_traced_memory()
    finally:
        tracemalloc.stop()

    assert result.read_ok and len(result.records) == 10
    assert result.parsed_size == info.st_size
    assert peak < 2 * 1024 * 1024, f"a 16 MB rollout peaked at {peak / 1e6:.1f} MB"
    assert len(os.listdir("/dev/fd")) == open_before, "the transcript was left open"


class _FailingHandle:
    def __init__(self, lines: list[bytes]) -> None:
        self._lines = lines
        self.closed = False

    def readline(self, _limit: int) -> bytes:
        if not self._lines:
            raise OSError("device went away")
        return self._lines.pop(0)

    def close(self) -> None:
        self.closed = True


def test_a_read_that_fails_part_way_is_unreadable_not_short(tmp_path: Path, monkeypatch: pytest.MonkeyPatch) -> None:
    transcript = tmp_path / "session.jsonl"
    row = json.dumps(_claude_row("msg_a", 10)).encode() + b"\n"
    transcript.write_bytes(row * 3)
    handle = _FailingHandle([row])
    monkeypatch.setattr(
        usage_stats, "_read_verified_prefix",
        lambda path, info, resume_offset=0: usage_stats._VerifiedPrefix(handle, resume_offset, info.st_size),
    )

    result = usage_stats._parse_file(transcript, os.stat(transcript), SECRET)

    assert result.read_ok is False
    assert result.records == []
    assert handle.closed
