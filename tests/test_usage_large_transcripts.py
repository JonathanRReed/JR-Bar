"""A transcript of any size is streamed, never skipped, and read once.

On the owner's Mac three Claude transcripts and 151 Codex rollouts were over
the old 64 MiB file cap and were left out of every total, and a fifth of
Codex's ``compacted`` lines were over the old 1 MiB line cap. These tests pin
the replacement: bounded memory however large the file or the line, a saved
byte offset and scanner state so a grown file is read from where it stopped,
a time budget that stops on a line boundary, and honest coverage throughout.
Every file is synthetic and written under ``tmp_path``; the multi-hundred-MiB
cases run on a generator-backed fake reader or a sparse file.
"""

from __future__ import annotations

import itertools
import json
import os
import tracemalloc
from pathlib import Path

import pytest

from jrbar import usage_stats
from jrbar.usage_stats import ScanBudget, UsageSourceStatus

SECRET = b"\x2a" * 32
NOW = 1_790_000_000.0
DAY = 86_400.0


# --------------------------------------------------------------------------
# Synthetic transcripts
# --------------------------------------------------------------------------


def _stamp(epoch: float) -> str:
    import time

    return time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime(epoch))


def _claude_row(message_id: str, *, epoch: float = NOW - DAY, tokens: int = 10, text: str = "") -> dict:
    return {
        "type": "assistant",
        "timestamp": _stamp(epoch),
        "message": {
            "id": message_id,
            "model": "claude-sonnet-5",
            "content": [{"type": "text", "text": text}],
            "usage": {
                "input_tokens": tokens,
                "cache_read_input_tokens": 1,
                "cache_creation_input_tokens": 2,
                "output_tokens": 3,
            },
        },
    }


def _dump(row: dict) -> bytes:
    return json.dumps(row).encode()


def _token_row(total: int, last: int, when: float, *, limits: float | None = None) -> dict:
    payload: dict = {
        "type": "token_count",
        "info": {
            "total_token_usage": {
                "input_tokens": total, "cached_input_tokens": 0,
                "cache_write_input_tokens": 0, "output_tokens": total // 10,
            },
            "last_token_usage": {
                "input_tokens": last, "cached_input_tokens": 0,
                "cache_write_input_tokens": 0, "output_tokens": last // 10,
            },
        },
    }
    if limits is not None:
        payload["rate_limits"] = {"primary": {"used_percent": limits, "window_minutes": 300}}
    return {"type": "event_msg", "timestamp": _stamp(when), "payload": payload}


def _usage_record(response_id: str, when: float, *, inp: int) -> dict:
    return {
        "type": "token_usage_record",
        "timestamp": _stamp(when),
        "payload": {"response_id": response_id, "usage": {"input_tokens": inp, "output_tokens": 1}},
    }


def _compacted(response_id: str, when: float, *, filler: int = 0) -> dict:
    payload: dict = {"compaction_response_id": response_id}
    if filler:
        payload = {"replacement_history": "h" * filler, **payload}
    return {"type": "compacted", "timestamp": _stamp(when), "payload": payload}


def _codex_lines(*, fork: bool = False) -> list[bytes]:
    """A rollout that exercises every piece of state a resume must carry."""
    base = NOW - DAY
    lines: list[bytes] = []
    meta: dict = {"id": "thread-child" if fork else "thread-one", "timestamp": _stamp(base)}
    if fork:
        meta["forked_from_id"] = "thread-parent"
        meta["parent_thread_id"] = "thread-root"
    lines.append(_dump({"type": "session_meta", "timestamp": _stamp(base), "payload": meta}))
    lines.append(_dump({"type": "turn_context", "timestamp": _stamp(base), "payload": {"model": "gpt-6-astra"}}))
    total = 0
    for step in range(1, 25):
        when = base + step * 60
        total += 100 + step
        lines.append(_dump({"type": "response_item", "timestamp": _stamp(when), "payload": {"text": "résumé 🙂" * step}}))
        lines.append(_dump(_token_row(total, 100 + step, when, limits=step / 2)))
        if step == 5:
            # A compaction whose usage record comes first, its marker later.
            lines.append(_dump(_usage_record("resp-a", when + 1, inp=900)))
        if step == 7:
            lines.append(_dump(_compacted("resp-a", when + 2)))
        if step == 9:
            # The marker first this time, the record after it.
            lines.append(_dump(_compacted("resp-b", when + 1)))
        if step == 10:
            lines.append(_dump(_usage_record("resp-b", when + 2, inp=700)))
        if step == 12:
            lines.append(_dump({"type": "turn_context", "timestamp": _stamp(when), "payload": {"model": "gpt-6-nova"}}))
        if step == 14:
            lines.append(b'{"type":"event_msg","payload":{"type":"token_count"}, broken')
            lines.append(b'{"type":"event_msg","note":"\xff\xfe","payload":{"type":"token_count","info":{}}}')
            lines.append(_dump(_token_row(total, 100 + step, when + 5)) + b"\r")
        if step == 18:
            lines.append(_dump(_usage_record("resp-c", when + 1, inp=500)))
    return lines


def _claude_lines() -> list[bytes]:
    lines: list[bytes] = []
    for number in range(30):
        lines.append(_dump({"type": "user", "message": {"content": "naïve café " * 8}}))
        lines.append(_dump(_claude_row(f"msg-{number % 25}", tokens=10 + number, text="日本語🙂" * number)))
    lines.append(b'{"type":"assistant","message":{"usage": broken')
    lines.append(_dump(_claude_row("msg-crlf", tokens=77)) + b"\r")
    return lines


def _write(path: Path, lines: list[bytes], *, partial: bytes = b"") -> os.stat_result:
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_bytes(b"\n".join(lines) + b"\n" + partial)
    return os.stat(path)


def _as_it_was(path: Path, size: int) -> os.stat_result:
    """The file's stat as it stood when it was ``size`` bytes long: the scan
    reads a frozen snapshot, so this is the file before its later lines came."""
    info = os.stat(path)
    return os.stat_result(
        (
            info.st_mode, info.st_ino, info.st_dev, info.st_nlink, info.st_uid, info.st_gid,
            size, int(info.st_atime), int(info.st_mtime), int(info.st_ctime),
        ),
        {
            "st_atime": info.st_atime, "st_mtime": info.st_mtime, "st_ctime": info.st_ctime,
            "st_atime_ns": info.st_atime_ns, "st_mtime_ns": info.st_mtime_ns,
            "st_ctime_ns": info.st_ctime_ns,
        },
    )


def _parse_whole(path: Path, provider: str, size: int | None = None) -> usage_stats._ParseResult:
    info = os.stat(path) if size is None else _as_it_was(path, size)
    parser = usage_stats._parse_codex_file if provider == "codex" else usage_stats._parse_file
    return parser(path, info, SECRET)


def _parse_tail(path: Path, provider: str, earlier: usage_stats._ParseResult, **options) -> usage_stats._ParseResult:
    info = os.stat(path)
    return usage_stats._parse_file_tail(
        path, info, earlier.parsed_size, provider, SECRET,
        prefix_check=earlier.prefix_check,
        codex_state=earlier.resume_state if provider == "codex" else None,
        **options,
    )


# --------------------------------------------------------------------------
# Reading in two halves counts what reading whole counts
# --------------------------------------------------------------------------


@pytest.mark.parametrize(
    ("provider", "lines"),
    [
        ("claude", _claude_lines()),
        ("codex", _codex_lines()),
        ("codex", _codex_lines(fork=True)),
    ],
    ids=["claude", "codex", "codex-fork"],
)
def test_reading_in_two_halves_equals_reading_whole_at_every_line(
    tmp_path: Path, provider: str, lines: list[bytes],
) -> None:
    path = tmp_path / "transcript.jsonl"
    _write(path, lines)
    whole = _parse_whole(path, provider)
    assert whole.read_ok and whole.records and whole.malformed_lines >= 1

    for cut in range(1, len(lines)):
        first = _parse_whole(path, provider, len(b"\n".join(lines[:cut])) + 1)
        second = _parse_tail(path, provider, first)

        assert first.read_ok and second.read_ok, cut
        assert first.records + second.records == whole.records, f"cut after line {cut}"
        assert first.malformed_lines + second.malformed_lines == whole.malformed_lines, cut
        assert second.parsed_size == whole.parsed_size, cut
        assert (second.rate_limit_windows or first.rate_limit_windows) == whole.rate_limit_windows, cut
        assert second.resume_state == whole.resume_state, cut
        assert second.prefix_check == whole.prefix_check, cut


def test_a_compaction_waiting_for_its_marker_survives_the_cut(tmp_path: Path) -> None:
    """The record is on one side of the cut and its marker on the other."""
    path = tmp_path / "rollout.jsonl"
    when = NOW - DAY
    lines = [
        _dump({"type": "session_meta", "timestamp": _stamp(when), "payload": {"id": "t"}}),
        _dump(_token_row(100, 100, when + 1)),
        _dump(_usage_record("resp-x", when + 2, inp=4000)),
        _dump(_compacted("resp-x", when + 3)),
        _dump(_token_row(300, 100, when + 4)),
    ]
    _write(path, lines[:3])
    first = _parse_whole(path, "codex")
    assert first.resume_state["pending"], "the usage record is held until its marker"
    _write(path, lines)
    second = _parse_tail(path, "codex", first)
    ids = [record[8] for record in first.records + second.records]

    assert sum(1 for key in ids if key.startswith("codex-response:")) == 1
    assert _parse_whole(path, "codex").records == first.records + second.records


def test_a_forked_rollouts_inherited_events_stay_inherited_after_a_cut(tmp_path: Path) -> None:
    """The fork boundary lives in ``session_meta``; events after a cut still need it."""
    path = tmp_path / "rollout.jsonl"
    boundary = NOW - DAY
    lines = [
        _dump({"type": "session_meta", "timestamp": _stamp(boundary), "payload": {
            "id": "child", "forked_from_id": "parent", "timestamp": _stamp(boundary)}}),
        _dump(_token_row(100, 100, boundary - 120)),
        _dump(_token_row(200, 100, boundary - 60)),
        _dump(_token_row(300, 100, boundary + 60)),
    ]
    _write(path, lines[:2])
    first = _parse_whole(path, "codex")
    _write(path, lines)
    second = _parse_tail(path, "codex", first)

    kinds = [record[8].split(":")[1] for record in first.records + second.records]
    assert kinds == ["inherited", "inherited", "own"]


def test_a_damaged_saved_state_makes_the_tail_decline_not_guess(tmp_path: Path) -> None:
    path = tmp_path / "rollout.jsonl"
    _write(path, _codex_lines()[:10])
    first = _parse_whole(path, "codex")
    broken = {**first.resume_state, "totals": [1, 2, 3]}
    _write(path, _codex_lines())

    tail = usage_stats._parse_file_tail(
        path, os.stat(path), first.parsed_size, "codex", SECRET,
        prefix_check=first.prefix_check, codex_state=broken,
    )

    assert tail.read_ok is False, "the caller then reads the rollout from the start"
    assert usage_stats._restore_codex_state(first.resume_state) is not None
    assert usage_stats._restore_codex_state({**first.resume_state, "v": 99}) is None
    assert usage_stats._restore_codex_state("nonsense") is None


def test_an_entry_with_no_saved_state_resumes_from_its_last_event_not_a_compaction(tmp_path: Path) -> None:
    """Entries written before scanner state was saved derive it from their
    records, and a compaction request's record is not a token event."""
    path = tmp_path / "rollout.jsonl"
    when = NOW - DAY
    lines = [
        _dump({"type": "session_meta", "timestamp": _stamp(when), "payload": {"id": "t"}}),
        _dump(_token_row(100, 100, when + 1)),
        _dump(_usage_record("resp-x", when + 2, inp=4000)),
        _dump(_compacted("resp-x", when + 3)),
        _dump(_token_row(300, 200, when + 4)),
    ]
    _write(path, lines)
    first = _parse_whole(path, "codex", len(b"\n".join(lines[:4])) + 1)
    assert first.records[-1][8].startswith("codex-response:")
    whole = _parse_whole(path, "codex")

    session, totals, parent, root, model = usage_stats._codex_derived_resume(first.records)
    tail = usage_stats._parse_file_tail(
        path, os.stat(path), first.parsed_size, "codex", SECRET, session, totals, parent, root, model,
    )

    assert tail.read_ok
    assert first.records + tail.records == whole.records


def test_a_rewritten_prefix_is_caught_by_the_checksum(tmp_path: Path) -> None:
    path = tmp_path / "session.jsonl"
    old = [_dump(_claude_row(f"old-{n}", tokens=5)) for n in range(40)]
    _write(path, old)
    first = _parse_whole(path, "claude")
    assert first.prefix_check is not None and first.prefix_check[0] == usage_stats.USAGE_PREFIX_CHECK_BYTES

    # Same inode, longer than before, but the part already read is different.
    new = [_dump(_claude_row(f"new-{n}", tokens=9)) for n in range(80)]
    _write(path, new)
    tail = _parse_tail(path, "claude", first)

    assert tail.read_ok is False


def test_a_resume_with_no_saved_checksum_still_works(tmp_path: Path) -> None:
    """Entries written before checksums existed keep resuming."""
    path = tmp_path / "session.jsonl"
    lines = [_dump(_claude_row(f"m-{n}")) for n in range(10)]
    _write(path, lines[:6])
    first = _parse_whole(path, "claude")
    _write(path, lines)
    tail = usage_stats._parse_file_tail(path, os.stat(path), first.parsed_size, "claude", SECRET)

    assert tail.read_ok and len(tail.records) == 4


# --------------------------------------------------------------------------
# The last line, CRLF, bytes that are not UTF-8
# --------------------------------------------------------------------------


def test_a_last_line_without_a_newline_counts_only_when_it_is_a_whole_record(tmp_path: Path) -> None:
    path = tmp_path / "session.jsonl"
    complete = _dump(_claude_row("tail-ok", tokens=40))
    path.write_bytes(_dump(_claude_row("first", tokens=1)) + b"\n" + complete)
    first = _parse_whole(path, "claude")
    assert [record[4] for record in first.records] == [1, 40]
    assert first.parsed_size == path.stat().st_size

    # The writer then ends the line and adds another: the newline is an empty
    # line to the next read, and nothing is counted twice.
    with path.open("ab") as handle:
        handle.write(b"\n" + _dump(_claude_row("next", tokens=2)) + b"\n")
    second = _parse_tail(path, "claude", first)
    assert [record[4] for record in second.records] == [2]

    half = _dump(_claude_row("half", tokens=99))
    path.write_bytes(b"")
    path.write_bytes(_dump(_claude_row("a", tokens=1)) + b"\n" + half[:-7])
    held = _parse_whole(path, "claude")
    assert [record[4] for record in held.records] == [1], "a line half written is left alone"
    assert held.parsed_size == len(_dump(_claude_row("a", tokens=1))) + 1
    with path.open("ab") as handle:
        handle.write(half[-7:] + b"\n")
    finished = _parse_tail(path, "claude", held)
    assert [record[4] for record in finished.records] == [99]


def test_crlf_and_invalid_utf8_follow_the_streaming_rules(tmp_path: Path) -> None:
    path = tmp_path / "session.jsonl"
    good = _dump(_claude_row("crlf", tokens=5))
    bad_inside_string = _dump(_claude_row("inside", tokens=6)).replace(b'"text": ""', b'"text": "\xff\xfe"')
    bad_outside = b'{"type":"assistant", \xff "message": {"usage": 1}}'
    path.write_bytes(good + b"\r\n" + bad_inside_string + b"\n" + bad_outside + b"\n")

    result = _parse_whole(path, "claude")

    assert [record[4] for record in result.records] == [5, 6]
    assert result.malformed_lines == 1


# --------------------------------------------------------------------------
# Long lines
# --------------------------------------------------------------------------


def test_a_marker_line_between_one_and_sixteen_mib_is_parsed(tmp_path: Path) -> None:
    path = tmp_path / "session.jsonl"
    big = usage_stats.USAGE_STUB_LINE_BYTES * 3
    _write(path, [_dump(_claude_row("big", tokens=8, text="t" * big)), _dump(_claude_row("after", tokens=9))])

    result = _parse_whole(path, "claude")

    assert [record[4] for record in result.records] == [8, 9]
    assert result.malformed_lines == 0


def test_a_compaction_over_a_mib_is_stubbed_and_counts_once(tmp_path: Path) -> None:
    path = tmp_path / "rollout.jsonl"
    when = NOW - DAY
    stub = usage_stats.USAGE_STUB_LINE_BYTES
    lines = [
        _dump({"type": "session_meta", "timestamp": _stamp(when), "payload": {"id": "t"}}),
        _dump(_token_row(100, 100, when + 1)),
        _dump(_usage_record("resp-big", when + 2, inp=5000)),
        _dump(_compacted("resp-big", when + 3, filler=stub * 4)),   # in [1 MiB, 16 MiB]
        _dump(_compacted("resp-huge", when + 4, filler=usage_stats.USAGE_RECORD_MAX_BYTES + 4096)),  # past the cap
        _dump(_token_row(200, 100, when + 5)),
    ]
    _write(path, lines)

    result = _parse_whole(path, "codex")

    assert result.malformed_lines == 0
    assert sum(record[4] for record in result.records) == 100 + 5000 + 100


def test_a_line_over_the_hard_cap_is_one_unparseable_record(tmp_path: Path, monkeypatch: pytest.MonkeyPatch) -> None:
    monkeypatch.setattr(usage_stats, "USAGE_RECORD_MAX_BYTES", 512 * 1024)
    path = tmp_path / "session.jsonl"
    _write(path, [
        _dump(_claude_row("a", tokens=1)),
        _dump(_claude_row("too-big", tokens=500, text="z" * (700 * 1024))),
        _dump(_claude_row("b", tokens=2)),
    ])

    result = _parse_whole(path, "claude")

    assert [record[4] for record in result.records] == [1, 2]
    assert result.malformed_lines == 1
    assert result.parsed_size == path.stat().st_size


class _GeneratedFile:
    """A transcript that exists only as a stream of lines: hundreds of MiB
    "on disk" that never touch it. ``readline(limit)`` hands back at most
    ``limit`` bytes, as a real file does, and ``close`` is recorded."""

    FILLER = b'{"type":"user","message":{"content":"' + b"w" * 4000 + b'"}}\n'

    def __init__(self, plan: list[tuple[str, int]]) -> None:
        # plan: ("filler", count) | ("usage", id) | ("giant", bytes) | ("giant-usage", bytes)
        self._plan = list(plan)
        self._line_left = 0
        self._line_head = b""
        self._filler_left = 0
        self.closed = False
        self.size = sum(self._size_of(kind, value) for kind, value in plan)

    @classmethod
    def _size_of(cls, kind: str, value: int) -> int:
        if kind == "filler":
            return len(cls.FILLER) * value
        if kind == "usage":
            return len(cls._usage_line(value))
        return value

    @staticmethod
    def _usage_line(number: int) -> bytes:
        return _dump(_claude_row(f"gen-{number}", tokens=number)) + b"\n"

    def _begin_next(self) -> bool:
        while self._plan:
            kind, value = self._plan.pop(0)
            if kind == "filler":
                self._filler_left = value
                return True
            if kind == "usage":
                self._line_head = self._usage_line(value)
                self._line_left = len(self._line_head)
                return True
            marker = b'{"type":"assistant","usage":"' if kind == "giant-usage" else b'{"type":"user","blob":"'
            self._line_head = marker
            self._line_left = value
            self._giant_total = value
            return True
        return False

    def readline(self, limit: int) -> bytes:
        if self._filler_left:
            self._filler_left -= 1
            return self.FILLER[:limit] if limit < len(self.FILLER) else self.FILLER
        if not self._line_left:
            if not self._begin_next():
                return b""
            if self._filler_left:
                return self.readline(limit)
        take = min(limit, self._line_left)
        head = self._line_head[:take]
        self._line_head = self._line_head[take:]
        piece = head + b"x" * (take - len(head))
        self._line_left -= take
        if self._line_left == 0:
            piece = piece[:-1] + b"\n"
        return piece

    def close(self) -> None:
        self.closed = True


def test_hundreds_of_mib_stream_in_flat_memory() -> None:
    cap = usage_stats.USAGE_RECORD_MAX_BYTES
    plan: list[tuple[str, int]] = []
    for block in range(6):
        plan += [("filler", 12_000), ("usage", block + 1), ("giant", cap * 2 + 12345)]
    plan += [("giant-usage", cap + 5000), ("usage", 100), ("filler", 5_000)]
    generated = _GeneratedFile(plan)
    assert generated.size > 400 * 1024 * 1024, "this stands in for a file of hundreds of MiB"

    snapshot = usage_stats._VerifiedPrefix(generated, 0, generated.size)
    tracemalloc.start()
    try:
        result = usage_stats._scan_claude_lines(snapshot, "claude:1:1", SECRET)
        _current, peak = tracemalloc.get_traced_memory()
    finally:
        tracemalloc.stop()

    assert result.read_ok and result.parsed_size == generated.size
    assert [record[4] for record in result.records] == [1, 2, 3, 4, 5, 6, 100]
    assert result.malformed_lines == 1, "the one over-cap line that carries a marker"
    assert generated.closed
    assert peak < 4 * cap, f"{generated.size >> 20} MiB peaked at {peak / 2**20:.1f} MiB"


def test_a_sparse_file_past_the_old_cap_is_read_and_counts(tmp_path: Path) -> None:
    root = tmp_path / "claude"
    path = root / "proj" / "huge.jsonl"
    path.parent.mkdir(parents=True)
    with path.open("wb") as handle:
        handle.write(_dump(_claude_row("head", tokens=11)) + b"\n")
        handle.seek(70 * 1024 * 1024)
        handle.write(b"\n" + _dump(_claude_row("tail", tokens=22)) + b"\n")
    assert path.stat().st_size > 64 * 1024 * 1024
    os.utime(path, (NOW - DAY, NOW - DAY))

    totals = usage_stats.scan_usage(root, tmp_path / "cache.json", provider_ids=("claude",), now=NOW)

    coverage = totals.source_coverage["claude"]
    assert totals.input_tokens == 11 + 22
    assert coverage.oversized_files == 0
    assert coverage.status is UsageSourceStatus.OK
    assert usage_stats.USAGE_FILE_SANITY_BYTES == 8 * 1024**3


def test_only_a_pathological_file_is_skipped_and_it_is_said(tmp_path: Path) -> None:
    root = tmp_path / "claude"
    big = root / "proj" / "big.jsonl"
    big.parent.mkdir(parents=True)
    big.write_bytes(b"\n".join(_dump(_claude_row(f"m{n}")) for n in range(5)) + b"\n")
    small = root / "proj" / "small.jsonl"
    small.write_bytes(_dump(_claude_row("s", tokens=7)) + b"\n")

    inventory = usage_stats._provider_inventory("claude", root, max_file_bytes=big.stat().st_size - 1)
    totals = usage_stats.scan_usage(root, inventory=inventory, provider_ids=("claude",))

    coverage = totals.source_coverage["claude"]
    assert coverage.oversized_files == 1
    assert coverage.status is UsageSourceStatus.PARTIAL
    assert totals.input_tokens == 7


# --------------------------------------------------------------------------
# The time budget
# --------------------------------------------------------------------------


class _Clock:
    def __init__(self) -> None:
        self.now = 0.0

    def __call__(self) -> float:
        return self.now


def test_a_budget_stops_on_a_line_boundary_and_the_next_pass_carries_on(
    tmp_path: Path, monkeypatch: pytest.MonkeyPatch,
) -> None:
    monkeypatch.setattr(usage_stats, "_BUDGET_CHECK_WEIGHT", 6)
    for provider, lines in (("claude", _claude_lines() * 3), ("codex", _codex_lines())):
        path = tmp_path / f"{provider}.jsonl"
        _write(path, lines)
        whole = _parse_whole(path, provider)

        class Ticking(_Clock):
            def __call__(self) -> float:
                self.now += 1.0  # every look at the clock costs a second
                return self.now

        passes: list[usage_stats._ParseResult] = []
        earlier = None
        while True:
            budget = ScanBudget(3.0, Ticking())
            info = os.stat(path)
            if earlier is None:
                parser = usage_stats._parse_codex_file if provider == "codex" else usage_stats._parse_file
                current = parser(path, info, SECRET, budget)
            else:
                current = usage_stats._parse_file_tail(
                    path, info, earlier.parsed_size, provider, SECRET, budget=budget,
                    prefix_check=earlier.prefix_check,
                    codex_state=earlier.resume_state if provider == "codex" else None,
                )
            assert current.read_ok
            passes.append(current)
            if not current.stopped_early:
                break
            assert current.parsed_size > (earlier.parsed_size if earlier else 0), "every pass makes progress"
            assert path.read_bytes()[current.parsed_size - 1:current.parsed_size] == b"\n", "stops on a line boundary"
            earlier = current

        assert len(passes) > 2, provider
        assert [record for part in passes for record in part.records] == whole.records, provider
        assert sum(part.malformed_lines for part in passes) == whole.malformed_lines, provider
        assert passes[-1].parsed_size == whole.parsed_size


def _shape(records) -> list[tuple]:
    """Records without the per-cache secret's hashes: what was counted."""
    return [record[2:8] for record in records]


def _timed_reads(monkeypatch: pytest.MonkeyPatch, clock: _Clock, order: list[str] | None = None) -> None:
    """Every read of a file (whole or tail) costs one second on ``clock``."""
    real_whole, real_tail = usage_stats._parse_file, usage_stats._parse_file_tail

    def whole(path, info, secret, *rest):
        if order is not None:
            order.append(Path(path).name)
        clock.now += 1.0
        return real_whole(path, info, secret, *rest)

    def tail(path, info, *rest, **options):
        if order is not None:
            order.append(Path(path).name)
        clock.now += 1.0
        return real_tail(path, info, *rest, **options)

    monkeypatch.setattr(usage_stats, "_parse_file", whole)
    monkeypatch.setattr(usage_stats, "_parse_file_tail", tail)


def _claude_root(tmp_path: Path, count: int) -> tuple[Path, list[Path]]:
    root = tmp_path / "claude"
    paths = []
    for number in range(count):
        path = root / "proj" / f"s{number}.jsonl"
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_bytes(b"\n".join(_dump(_claude_row(f"f{number}-{n}", tokens=1)) for n in range(20)) + b"\n")
        stamp = NOW - (count - number) * 3600
        os.utime(path, (stamp, stamp))
        paths.append(path)
    return root, paths


def test_a_cold_scan_over_many_files_finishes_over_passes_newest_first(
    tmp_path: Path, monkeypatch: pytest.MonkeyPatch,
) -> None:
    root, paths = _claude_root(tmp_path, 6)
    cache = tmp_path / "cache.json"
    clock = _Clock()
    order: list[str] = []
    _timed_reads(monkeypatch, clock, order)
    reading: list[int] = []
    for _pass in range(10):
        totals = usage_stats.scan_usage(
            root, cache, provider_ids=("claude",), now=NOW, budget=ScanBudget(2.5, clock),
        )
        coverage = totals.source_coverage["claude"]
        reading.append(coverage.pending_files)
        if coverage.status is UsageSourceStatus.OK:
            break
        assert coverage.status is UsageSourceStatus.PARTIAL

    assert reading == [3, 0], "three files a pass: the second pass finishes"
    assert order[:3] == ["s5.jsonl", "s4.jsonl", "s3.jsonl"], "the newest files first"
    assert totals.input_tokens == 6 * 20
    assert totals.source_coverage["claude"].pending_files == 0
    # A finished cache needs no more reading at all.
    order.clear()
    again = usage_stats.scan_usage(root, cache, provider_ids=("claude",), now=NOW, budget=ScanBudget(0.0, clock))
    assert order == [] and again.input_tokens == totals.input_tokens


def test_a_partial_pass_never_shrinks_the_month_the_card_reads(tmp_path: Path, monkeypatch: pytest.MonkeyPatch) -> None:
    root, paths = _claude_root(tmp_path, 4)
    cache = tmp_path / "cache.json"
    clock = _Clock()
    _timed_reads(monkeypatch, clock)
    source_key = next(
        row.source_key for row in usage_stats.negotiated_provider_sources()
        if row.source_key.provider_id == "claude" and row.source_key.capability_id == "transcript_usage"
    )

    def card() -> dict | None:
        loaded = usage_stats._load_cache(cache, source_key)
        return loaded.get("daily") if loaded else None

    first = usage_stats.scan_usage(root, cache, provider_ids=("claude",), now=NOW, budget=ScanBudget(1.5, clock))
    assert first.source_coverage["claude"].pending_files == 2
    assert card() is None, "the card says nothing until a pass has read the whole window"

    usage_stats.scan_usage(root, cache, provider_ids=("claude",), now=NOW, budget=ScanBudget(5.0, clock))
    complete = card()
    assert complete is not None

    # New activity arrives; a pass that has to stop early keeps the last whole month.
    with paths[0].open("ab") as handle:
        handle.write(_dump(_claude_row("late", tokens=1)) + b"\n")
    for number in range(3):
        extra = paths[0].parent / f"fresh{number}.jsonl"
        extra.write_bytes(_dump(_claude_row(f"fresh{number}", tokens=1)) + b"\n")
        os.utime(extra, (NOW - 60 - number, NOW - 60 - number))
    partial = usage_stats.scan_usage(root, cache, provider_ids=("claude",), now=NOW, budget=ScanBudget(0.5, clock))
    assert partial.source_coverage["claude"].pending_files >= 1
    assert card() == complete


# --------------------------------------------------------------------------
# Incremental scans through the cache
# --------------------------------------------------------------------------


def test_a_rewritten_file_is_read_again_not_continued(tmp_path: Path) -> None:
    root = tmp_path / "claude"
    path = root / "proj" / "session.jsonl"
    path.parent.mkdir(parents=True)
    cache = tmp_path / "cache.json"
    old = b"\n".join(_dump(_claude_row(f"old-{n}", tokens=1)) for n in range(30)) + b"\n"
    path.write_bytes(old)
    os.utime(path, (NOW - 2 * DAY, NOW - 2 * DAY))
    assert usage_stats.scan_usage(root, cache, provider_ids=("claude",), now=NOW).input_tokens == 30

    # In place (same inode), longer than before, different bytes throughout.
    new = b"\n".join(_dump(_claude_row(f"new-{n}", tokens=2)) for n in range(60)) + b"\n"
    with path.open("r+b") as handle:
        handle.write(new)
    os.utime(path, (NOW - DAY, NOW - DAY))
    assert path.stat().st_size > len(old)

    rescanned = usage_stats.scan_usage(root, cache, provider_ids=("claude",), now=NOW)
    fresh = usage_stats.scan_usage(root, None, provider_ids=("claude",), now=NOW)

    assert rescanned.input_tokens == fresh.input_tokens == 120
    assert _shape(rescanned.records) == _shape(fresh.records)


def test_a_shrunk_and_regrown_file_is_not_continued_from_the_old_offset(tmp_path: Path) -> None:
    root = tmp_path / "claude"
    path = root / "proj" / "session.jsonl"
    path.parent.mkdir(parents=True)
    cache = tmp_path / "cache.json"
    path.write_bytes(b"\n".join(_dump(_claude_row(f"a-{n}", tokens=1)) for n in range(40)) + b"\n")
    os.utime(path, (NOW - 3 * DAY, NOW - 3 * DAY))
    usage_stats.scan_usage(root, cache, provider_ids=("claude",), now=NOW)

    path.write_bytes(b"\n".join(_dump(_claude_row(f"b-{n}", tokens=5)) for n in range(10)) + b"\n")
    shrunk = usage_stats.scan_usage(root, cache, provider_ids=("claude",), now=NOW)
    assert shrunk.input_tokens == 50

    with path.open("ab") as handle:
        handle.write(b"\n".join(_dump(_claude_row(f"c-{n}", tokens=5)) for n in range(100)) + b"\n")
    os.utime(path, (NOW - DAY, NOW - DAY))
    regrown = usage_stats.scan_usage(root, cache, provider_ids=("claude",), now=NOW)

    assert regrown.input_tokens == 50 + 500


@pytest.mark.parametrize("provider", ["claude", "codex"])
def test_an_appended_file_is_read_from_its_saved_offset_only(
    tmp_path: Path, monkeypatch: pytest.MonkeyPatch, provider: str,
) -> None:
    if provider == "claude":
        lines, extra_lines = _claude_lines()[:40], _claude_lines()[40:]
    else:
        lines, extra_lines = _codex_lines()[:30], _codex_lines()[30:]
    root = tmp_path / provider
    path = root / "proj" / "session.jsonl"
    cache = tmp_path / "cache.json"
    _write(path, lines)
    os.utime(path, (NOW - 3600, NOW - 3600))
    scan = lambda: usage_stats.scan_usage(  # noqa: E731
        *((root,) if provider == "claude" else (tmp_path / "empty",)),
        cache,
        **({} if provider == "claude" else {"codex_root": root}),
        provider_ids=(provider,), now=NOW,
    )
    (tmp_path / "empty").mkdir()
    scan()
    reads: list[int] = []
    real = usage_stats._read_verified_prefix

    def watched(path_, info, resume_offset=0, **options):
        reads.append(resume_offset)
        return real(path_, info, resume_offset, **options)

    monkeypatch.setattr(usage_stats, "_read_verified_prefix", watched)

    reads.clear()
    scan()
    assert reads == [], "an unchanged file costs a stat, not a read"

    _write(path, lines + extra_lines)
    os.utime(path, (NOW - 60, NOW - 60))
    grown = scan()
    assert len(reads) == 1 and reads[0] > 0, "only the appended part is read"

    monkeypatch.undo()
    fresh_cache = tmp_path / "fresh.json"
    whole = usage_stats.scan_usage(
        *((root,) if provider == "claude" else (tmp_path / "empty",)),
        fresh_cache,
        **({} if provider == "claude" else {"codex_root": root}),
        provider_ids=(provider,), now=NOW,
    )
    assert _shape(grown.records) == _shape(whole.records)
    assert grown.source_coverage[provider].malformed_lines == whole.source_coverage[provider].malformed_lines


def test_an_unchanged_file_ending_mid_line_is_not_read_again(tmp_path: Path, monkeypatch: pytest.MonkeyPatch) -> None:
    root = tmp_path / "claude"
    path = root / "proj" / "session.jsonl"
    cache = tmp_path / "cache.json"
    _write(path, [_dump(_claude_row("a", tokens=3))], partial=b'{"type":"assistant","mess')
    os.utime(path, (NOW - 600, NOW - 600))
    first = usage_stats.scan_usage(root, cache, provider_ids=("claude",), now=NOW)
    assert first.input_tokens == 3

    reads: list[Path] = []
    real = usage_stats._read_verified_prefix

    def watched(path_, info, resume_offset=0, **options):
        reads.append(path_)
        return real(path_, info, resume_offset, **options)

    monkeypatch.setattr(usage_stats, "_read_verified_prefix", watched)
    again = usage_stats.scan_usage(root, cache, provider_ids=("claude",), now=NOW)

    assert reads == []
    assert again.input_tokens == 3
    assert again.source_coverage["claude"].status is UsageSourceStatus.OK


def test_complete_means_complete_after_the_first_full_pass(tmp_path: Path) -> None:
    root, _paths = _claude_root(tmp_path, 3)
    totals = usage_stats.scan_usage(root, tmp_path / "cache.json", provider_ids=("claude",), now=NOW)

    coverage = totals.source_coverage["claude"]
    assert coverage.status is UsageSourceStatus.OK
    assert (coverage.pending_files, coverage.oversized_files, coverage.malformed_lines) == (0, 0, 0)


def _coverage(**fields) -> usage_stats.UsageSourceCoverage:
    base = {
        "provider_id": "codex", "status": UsageSourceStatus.OK, "root_present": True, "root_walked": True,
        "files_discovered": 40, "files_read": 40, "cache_hits": 0, "malformed_lines": 0,
        "unreadable_files": 0, "skipped_symlinks": 0, "duplicate_physical_files": 0,
    }
    return usage_stats.UsageSourceCoverage(**{**base, **fields})


def test_the_sources_line_says_still_reading_until_it_is_done() -> None:
    from jrbar.usage_view import source_text_for_coverage

    reading = _coverage(status=UsageSourceStatus.PARTIAL, pending_files=12)
    assert source_text_for_coverage(reading) == "Local transcripts · 40 files · still reading 12"
    assert source_text_for_coverage(_coverage()) == "Local transcripts · 40 files"
    skipped = _coverage(status=UsageSourceStatus.PARTIAL, malformed_lines=3)
    assert source_text_for_coverage(skipped) == "Local transcripts · 40 files · partial"


def test_another_home_still_being_read_keeps_the_provider_partial() -> None:
    primary, extra = usage_stats.UsageTotals(), usage_stats.UsageTotals()
    primary.source_coverage["codex"] = _coverage(status=UsageSourceStatus.PARTIAL, pending_files=5)
    extra.source_coverage["codex"] = _coverage(files_discovered=3)

    merged = usage_stats._merge_usage_totals((primary, extra)).source_coverage["codex"]

    assert merged.pending_files == 5 and merged.status is UsageSourceStatus.PARTIAL
    assert merged.files_discovered == 43, "both homes contribute to provider coverage"
    both = usage_stats._merge_usage_totals((extra, extra)).source_coverage["codex"]
    assert both.status is UsageSourceStatus.OK


def test_a_scan_with_no_budget_runs_to_the_end_as_before(tmp_path: Path) -> None:
    root, _paths = _claude_root(tmp_path, 5)

    totals = usage_stats.scan_usage(root, None, provider_ids=("claude",), now=NOW)

    assert totals.input_tokens == 100
    assert totals.source_coverage["claude"].pending_files == 0


def test_scans_of_one_cache_file_take_turns(tmp_path: Path) -> None:
    first = usage_stats._cache_scan_lock(tmp_path / "a.json")
    assert usage_stats._cache_scan_lock(tmp_path / "a.json") is first
    assert usage_stats._cache_scan_lock(tmp_path / "b.json") is not first
    with usage_stats._cache_scan_lock(None):
        pass  # a scan with no cache has nothing to protect
    assert first.acquire(blocking=False)
    try:
        assert not usage_stats._cache_scan_lock(tmp_path / "a.json").acquire(blocking=False)
    finally:
        first.release()


def test_a_session_that_grows_between_passes_does_not_starve_the_rest(
    tmp_path: Path, monkeypatch: pytest.MonkeyPatch,
) -> None:
    root, paths = _claude_root(tmp_path, 7)
    cache = tmp_path / "cache.json"
    clock = _Clock()
    order: list[str] = []
    _timed_reads(monkeypatch, clock, order)
    live = paths[-1]
    # The live file is already known; the other six have never been read.
    usage_stats.scan_usage(
        root, cache, provider_ids=("claude",), now=NOW,
        budget=ScanBudget(0.5, clock),
    )
    unread = []
    for _round in range(8):
        with live.open("ab") as handle:
            handle.write(_dump(_claude_row(f"live-{_round}", tokens=1)) + b"\n")
        order.clear()
        totals = usage_stats.scan_usage(
            root, cache, provider_ids=("claude",), now=NOW, budget=ScanBudget(0.5, clock),
        )
        unread.append(totals.source_coverage["claude"].pending_files)
        assert live.name in order[:2], "the live file keeps up"
        assert any(name != live.name for name in order), "and never uses the whole pass"
        if totals.source_coverage["claude"].status is UsageSourceStatus.OK:
            break
    assert unread[-1] == 0
    assert all(later <= earlier for earlier, later in itertools.pairwise(unread))
    assert totals.input_tokens == 7 * 20 + len(unread)


def test_a_row_that_only_mentions_usage_is_not_damage(tmp_path: Path) -> None:
    """Attachments and tool results carry a ``usage`` key of their own; a
    complete history must not read as partial for them."""
    path = tmp_path / "session.jsonl"
    _write(path, [
        _dump({"type": "attachment", "attachment": {"usage": {"total": 3}}}),
        _dump({"type": "user", "toolUseResult": {"usage": {"input_tokens": 9}}}),
        _dump({"type": "assistant", "message": {"id": "no-usage-here", "content": "usage"}, "usage": 1}),
        _dump(_claude_row("real", tokens=4)),
        _dump({"usage": "a row with no kind"}),
        _dump({**_claude_row("no-time"), "timestamp": "not a time"}),
    ])

    result = _parse_whole(path, "claude")

    assert [record[4] for record in result.records] == [4]
    assert result.malformed_lines == 2, "the row of no kind and the assistant row with no readable time"


@pytest.mark.parametrize("provider", ["claude", "codex"])
def test_lines_that_span_many_read_chunks_parse_the_same(
    tmp_path: Path, monkeypatch: pytest.MonkeyPatch, provider: str,
) -> None:
    path = tmp_path / "transcript.jsonl"
    _write(path, _claude_lines() if provider == "claude" else _codex_lines())
    expected = _parse_whole(path, provider)

    monkeypatch.setattr(usage_stats, "_READ_BUFFER_BYTES", 16)
    chunked = _parse_whole(path, provider)

    assert chunked.records == expected.records
    assert chunked.malformed_lines == expected.malformed_lines
    assert chunked.parsed_size == expected.parsed_size
    assert chunked.resume_state == expected.resume_state


def test_a_token_count_with_null_info_only_carries_rate_limits(tmp_path: Path) -> None:
    path = tmp_path / "rollout.jsonl"
    when = NOW - DAY
    limits_only = {
        "type": "event_msg", "timestamp": _stamp(when + 2),
        "payload": {"type": "token_count", "info": None,
                    "rate_limits": {"primary": {"used_percent": 61.0, "window_minutes": 300}}},
    }
    lines = [
        _dump({"type": "session_meta", "timestamp": _stamp(when), "payload": {"id": "t"}}),
        _dump(_token_row(100, 100, when + 1)),
        _dump(limits_only),
        _dump({**limits_only, "payload": {"type": "token_count", "info": "oops"}}),
    ]
    _write(path, lines)

    result = _parse_whole(path, "codex")

    assert [record[4] for record in result.records] == [100]
    assert result.malformed_lines == 1, "only the info that is neither a count nor null"
    assert result.rate_limit_windows and result.rate_limit_windows[0]["used_percent"] == 61.0


def test_a_cached_damaged_count_from_older_rules_is_read_again(
    tmp_path: Path, monkeypatch: pytest.MonkeyPatch,
) -> None:
    assert usage_stats._malformed_count_is_stale({"malformed_lines": 2})
    assert not usage_stats._malformed_count_is_stale({"malformed_lines": 2, "sem": usage_stats._MALFORMED_SEMANTICS})
    assert not usage_stats._malformed_count_is_stale({"malformed_lines": 0})

    root = tmp_path / "claude"
    path = root / "proj" / "session.jsonl"
    cache = tmp_path / "cache.json"
    _write(path, [_dump({"type": "attachment", "attachment": {"usage": {}}}), _dump(_claude_row("m", tokens=6))])
    os.utime(path, (NOW - 600, NOW - 600))
    assert usage_stats.scan_usage(root, cache, provider_ids=("claude",), now=NOW).source_coverage["claude"].malformed_lines == 0

    # What an older version wrote: it counted the attachment as damaged.
    document = json.loads(cache.read_text())
    for entry in document["files"].values():
        entry["malformed_lines"] = 1
        entry.pop("sem", None)
    cache.write_text(json.dumps(document))
    cache.with_suffix(".files.sqlite3").unlink()
    reads: list[Path] = []
    real = usage_stats._read_verified_prefix

    def watched(path_, info, resume_offset=0, **options):
        reads.append(path_)
        return real(path_, info, resume_offset, **options)

    monkeypatch.setattr(usage_stats, "_read_verified_prefix", watched)

    again = usage_stats.scan_usage(root, cache, provider_ids=("claude",), now=NOW)

    assert reads == [path], "the file is read once more"
    assert again.source_coverage["claude"].malformed_lines == 0
    assert again.source_coverage["claude"].status is UsageSourceStatus.OK
    assert again.input_tokens == 6


def test_a_long_rollout_of_unmarked_usage_records_keeps_a_small_resumable_state(tmp_path: Path) -> None:
    """Nearly every Codex response writes a ``token_usage_record`` and almost
    none is ever named by a compaction; holding them all grew the saved state
    past what could be kept, and the rollout was then read from the start on
    every pass."""
    path = tmp_path / "rollout.jsonl"
    when = NOW - DAY
    count = usage_stats._CODEX_RECENT_IDS_LIMIT * 2 + 100
    lines = [_dump({"type": "session_meta", "timestamp": _stamp(when), "payload": {"id": "long"}})]
    for step in range(count):
        lines.append(_dump(_usage_record(f"resp-{step}", when + step, inp=3)))
        lines.append(_dump(_token_row(100 * (step + 1), 100, when + step)))
    lines.append(_dump(_compacted("resp-0", when + count)))  # too old to be matched any more
    lines.append(_dump(_compacted(f"resp-{count - 1}", when + count + 1)))  # recent: matched
    _write(path, lines)
    whole = _parse_whole(path, "codex")

    assert len(whole.resume_state["pending"]) == usage_stats._CODEX_RECENT_IDS_LIMIT - 1
    assert len(whole.resume_state["emitted"]) <= usage_stats._CODEX_RECENT_IDS_LIMIT
    assert len(json.dumps(whole.resume_state)) < 600_000
    cut = len(lines) // 2
    first = _parse_whole(path, "codex", len(b"\n".join(lines[:cut])) + 1)
    second = _parse_tail(path, "codex", first)
    assert first.records + second.records == whole.records
    assert second.resume_state == whole.resume_state


def test_a_file_that_grew_after_the_inventory_still_vouches_for_its_cached_part(tmp_path: Path) -> None:
    path = tmp_path / "session.jsonl"
    _write(path, [_dump(_claude_row("a"))])
    frozen = os.stat(path)
    assert usage_stats._physical_file_unchanged(path, frozen)

    with path.open("ab") as handle:  # a live session appends between inventory and check
        handle.write(_dump(_claude_row("b")) + b"\n")
    assert usage_stats._physical_file_unchanged(path, frozen), "growth is read next pass, not damage"

    path.write_bytes(b"\n")  # shrunk: not the file the cache describes
    assert not usage_stats._physical_file_unchanged(path, frozen)
    path.unlink()
    assert not usage_stats._physical_file_unchanged(path, frozen)
