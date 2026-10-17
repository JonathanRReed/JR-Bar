"""Codex compaction requests that the cumulative token counter never adds.

A remote compaction is a model request of its own. Codex records its usage in
a top-level ``token_usage_record`` (keyed by ``response_id``) and marks it with
a ``compacted`` item naming the same id, but the thread's cumulative
``token_count`` does not advance for it. A local compaction does advance the
counter, so counting its record too would count it twice. The rule follows
ccusage's reading of Codex's source (MIT, studied 2026-10-07); the code and
every fixture here are written fresh with synthetic numbers.
"""

from __future__ import annotations

import json
from pathlib import Path

import pytest

from jrbar import usage_stats
from tests.test_codex_usage_lineage import _meta, _scan, _tokens, _write

SECRET = b"s" * 32
T0 = "2026-10-06T10:00:00Z"


def _record(response_id: str, timestamp: str, *, inp: int, cached: int = 0, out: int = 0, total: dict | None = None) -> dict:
    payload = {
        "response_id": response_id,
        "usage": {"input_tokens": inp, "cached_input_tokens": cached, "output_tokens": out},
    }
    if total is not None:
        payload["thread_token_usage"] = total
    return {"type": "token_usage_record", "timestamp": timestamp, "payload": payload}


def _compacted(response_id: str, timestamp: str = T0) -> dict:
    return {"type": "compacted", "timestamp": timestamp, "payload": {"compaction_response_id": response_id}}


def _context(model: str = "gpt-6.1-sol") -> dict:
    return {"type": "turn_context", "timestamp": T0, "payload": {"model": model}}


def _lines(rows: list[dict]) -> list[str]:
    return [json.dumps(row) + "\n" for row in rows]


def _scan_lines(rows: list[dict]):
    records, _windows, malformed, _eof, _legacy = usage_stats._scan_codex_lines(
        _lines(rows), fallback_session_id="codex:1:1", dedupe_secret=SECRET
    )
    return records, malformed


def _canonical(records) -> list[tuple[int, int, int, int]]:
    return [record[4:8] for record in records]


def test_a_remote_compaction_that_the_counter_never_added_is_counted() -> None:
    records, _ = _scan_lines(
        [
            _context(),
            _tokens(100, 100, "2026-10-06T10:00:01Z", output_total=10, output_last=10),
            _record("resp-compact", "2026-10-06T10:00:02Z", inp=300, cached=200, out=30),
            _compacted("resp-compact", "2026-10-06T10:00:03Z"),
            _tokens(250, 150, "2026-10-06T10:01:00Z", output_total=20, output_last=10),
        ]
    )

    assert sum(record[4] + record[5] + record[6] for record in records) == 100 + 300 + 150
    assert sum(record[7] for record in records) == 10 + 30 + 10
    compaction = next(record for record in records if record[8].startswith("codex-response:"))
    assert compaction[2] == "gpt-6.1-sol"
    assert _canonical([compaction]) == [(100, 200, 0, 30)]


def test_the_marker_may_come_before_the_record() -> None:
    records, _ = _scan_lines(
        [
            _context(),
            _compacted("resp-compact"),
            _record("resp-compact", "2026-10-06T10:00:02Z", inp=300, cached=0, out=30),
        ]
    )

    assert _canonical(records) == [(300, 0, 0, 30)]


def test_an_ordinary_response_record_is_not_a_compaction() -> None:
    # Every response writes a token_usage_record; only the compacted ones are extra.
    records, _ = _scan_lines(
        [
            _context(),
            _record("resp-normal", "2026-10-06T10:00:01Z", inp=100, out=10),
            _tokens(100, 100, "2026-10-06T10:00:01Z", output_total=10, output_last=10),
        ]
    )

    assert _canonical(records) == [(100, 0, 0, 10)]


def test_a_local_compaction_the_counter_already_added_is_not_counted_twice() -> None:
    records, _ = _scan_lines(
        [
            _context(),
            _record("resp-local", "2026-10-06T10:00:01Z", inp=300, cached=100, out=30,
                    total={"input_tokens": 300, "cached_input_tokens": 100, "output_tokens": 30}),
            # The counter advances by exactly that request between the record and the marker.
            _tokens(300, 300, "2026-10-06T10:00:02Z", cached_total=100, cached_last=100,
                    output_total=30, output_last=30),
            _compacted("resp-local", "2026-10-06T10:00:03Z"),
        ]
    )

    assert _canonical(records) == [(200, 100, 0, 30)]


def test_a_local_compaction_matched_by_its_cumulative_total_is_not_counted_twice() -> None:
    records, _ = _scan_lines(
        [
            _context(),
            _tokens(50, 50, "2026-10-06T10:00:00Z"),
            # Different last-usage figures, but the cumulative total equals the record's.
            _record("resp-local", "2026-10-06T10:00:01Z", inp=350, out=0,
                    total={"input_tokens": 400, "cached_input_tokens": 0, "output_tokens": 0}),
            _tokens(400, 350, "2026-10-06T10:00:02Z"),
            _compacted("resp-local", "2026-10-06T10:00:03Z"),
        ]
    )

    assert sum(record[4] + record[5] + record[6] for record in records) == 400


def test_a_compaction_never_moves_the_counter_baseline() -> None:
    records, _ = _scan_lines(
        [
            _context(),
            _tokens(100, 100, "2026-10-06T10:00:01Z"),
            _record("resp-compact", "2026-10-06T10:00:02Z", inp=500),
            _compacted("resp-compact"),
            # The counter went 100 -> 160: 60 new tokens, not 160 - 600.
            _tokens(160, 60, "2026-10-06T10:01:00Z"),
        ]
    )

    ordinary = [record for record in records if not record[8].startswith("codex-response:")]
    assert [record[4] for record in ordinary] == [100, 60]


def test_a_marker_without_a_record_or_a_record_without_a_marker_adds_nothing() -> None:
    records, _ = _scan_lines(
        [
            _context(),
            _compacted("resp-orphan"),
            _record("resp-other", "2026-10-06T10:00:02Z", inp=999),
        ]
    )

    assert records == []


@pytest.mark.parametrize(
    "payload",
    (
        {"response_id": "", "usage": {"input_tokens": 5}},
        {"response_id": 7, "usage": {"input_tokens": 5}},
        {"response_id": "r", "usage": {"input_tokens": -5}},
        {"response_id": "r", "usage": {"input_tokens": 0, "output_tokens": 0}},
        {"response_id": "r", "usage": "many"},
        {"response_id": "r"},
        "not a mapping",
    ),
)
def test_a_malformed_record_is_ignored(payload) -> None:
    records, _ = _scan_lines(
        [
            _context(),
            {"type": "token_usage_record", "timestamp": T0, "payload": payload},
            _compacted("r"),
        ]
    )

    assert records == []


def test_a_copied_compaction_in_a_fork_is_counted_once(tmp_path: Path) -> None:
    root = tmp_path / "codex"
    parent_rows = [
        _meta("parent", timestamp="2026-10-06T10:00:00Z"),
        _context(),
        _tokens(100, 100, "2026-10-06T10:00:01Z"),
        _record("resp-compact", "2026-10-06T10:00:02Z", inp=300, out=30),
        _compacted("resp-compact", "2026-10-06T10:00:03Z"),
    ]
    child_rows = [
        _meta("child", forked_from_id="parent", timestamp="2026-10-06T10:05:00Z"),
        _context(),
        # The fork replays the parent's history, compaction included.
        _tokens(100, 100, "2026-10-06T10:00:01Z"),
        _record("resp-compact", "2026-10-06T10:00:02Z", inp=300, out=30),
        _compacted("resp-compact", "2026-10-06T10:00:03Z"),
        _tokens(160, 60, "2026-10-06T10:06:00Z"),
    ]
    _write(root / "sessions" / "2026" / "10" / "06" / "rollout-2026-10-06T10-00-00-parent.jsonl", parent_rows)
    _write(root / "sessions" / "2026" / "10" / "06" / "rollout-2026-10-06T10-05-00-child.jsonl", child_rows)

    totals = _scan(tmp_path, root)

    # 100 (parent) + 330 (the compaction, once) + 60 (the child's own work).
    assert totals.codex_tokens == 100 + 330 + 60


def test_a_compaction_is_found_when_a_scan_resumes_in_a_grown_file(tmp_path: Path) -> None:
    root = tmp_path / "codex"
    cache = tmp_path / "state" / "usage-scan-cache.json"
    path = root / "sessions" / "2026" / "10" / "06" / "rollout-2026-10-06T10-00-00-solo.jsonl"
    rows = [
        _meta("solo", timestamp="2026-10-06T10:00:00Z"),
        _context(),
        _tokens(100, 100, "2026-10-06T10:00:01Z"),
    ]
    _write(path, rows)
    assert _scan(tmp_path, root, cache).codex_tokens == 100

    with path.open("a") as handle:
        handle.write("".join(_lines([
            _record("resp-compact", "2026-10-06T10:00:02Z", inp=300, out=30),
            _compacted("resp-compact", "2026-10-06T10:00:03Z"),
            _tokens(160, 60, "2026-10-06T10:01:00Z"),
        ])))

    assert _scan(tmp_path, root, cache).codex_tokens == 100 + 330 + 60


def _huge_compacted(response_id: str, timestamp: str = T0, *, size: int = usage_stats.USAGE_STUB_LINE_BYTES + 200_000) -> dict:
    """A compacted item as Codex writes it: the replaced history first (megabytes),
    then the response id and the item's own usage record at the end of the line."""
    return {
        "timestamp": timestamp,
        "ordinal": 7,
        "type": "compacted",
        "payload": {
            "message": "",
            "replacement_history": "x" * size,
            "window_number": 3,
            "compaction_response_id": response_id,
            "latest_token_usage_record": {"response_id": response_id},
        },
    }


def _scan_codex_file(tmp_path: Path, rows: list[dict]):
    root = tmp_path / "codex"
    _write(root / "sessions" / "2026" / "10" / "06" / "rollout-2026-10-06T10-00-00-solo.jsonl", rows)
    return _scan(tmp_path, root)


def test_an_over_cap_compacted_line_still_names_its_compaction(tmp_path: Path) -> None:
    totals = _scan_codex_file(
        tmp_path,
        [
            _meta("solo", timestamp=T0),
            _context(),
            _tokens(100, 100, "2026-10-06T10:00:01Z"),
            _record("resp-compact", "2026-10-06T10:00:02Z", inp=300, out=30),
            _huge_compacted("resp-compact", "2026-10-06T10:00:03Z"),
            _tokens(160, 60, "2026-10-06T10:01:00Z"),
        ],
    )

    assert totals.codex_tokens == 100 + 330 + 60
    coverage = totals.source_coverage["codex"]
    assert coverage.malformed_lines == 0
    assert coverage.status is usage_stats.UsageSourceStatus.OK


def test_an_over_cap_compacted_line_never_makes_coverage_partial(tmp_path: Path) -> None:
    # The same line with no usage record beside it: nothing to count, nothing to report.
    totals = _scan_codex_file(
        tmp_path,
        [
            _meta("solo", timestamp=T0),
            _context(),
            _tokens(100, 100, "2026-10-06T10:00:01Z"),
            _huge_compacted("resp-orphan"),
        ],
    )

    assert totals.codex_tokens == 100
    assert totals.source_coverage["codex"].malformed_lines == 0


def test_an_over_cap_line_that_only_mentions_compaction_in_its_text_is_skipped_quietly(tmp_path: Path) -> None:
    noisy = {
        "timestamp": T0,
        "type": "response_item",
        "payload": {"type": "function_call_output", "output": '"compacted" ' + "y" * (usage_stats.USAGE_STUB_LINE_BYTES + 10)},
    }
    totals = _scan_codex_file(tmp_path, [_meta("solo", timestamp=T0), _context(), noisy, _tokens(100, 100, "2026-10-06T10:00:01Z")])

    assert totals.codex_tokens == 100
    assert totals.source_coverage["codex"].malformed_lines == 0


def test_an_over_cap_token_count_line_is_still_reported_as_malformed(
    tmp_path: Path, monkeypatch: pytest.MonkeyPatch,
) -> None:
    monkeypatch.setattr(usage_stats, "USAGE_RECORD_MAX_BYTES", 256 * 1024)
    huge = _tokens(100, 100, "2026-10-06T10:00:01Z")
    huge["payload"]["pad"] = "z" * (usage_stats.USAGE_RECORD_MAX_BYTES + 10)
    totals = _scan_codex_file(tmp_path, [_meta("solo", timestamp=T0), _context(), huge])

    assert totals.source_coverage["codex"].malformed_lines == 1


def test_a_compaction_marked_by_an_over_cap_line_in_a_fork_counts_once(tmp_path: Path) -> None:
    root = tmp_path / "codex"
    rows = [
        _context(),
        _tokens(100, 100, "2026-10-06T10:00:01Z"),
        _record("resp-compact", "2026-10-06T10:00:02Z", inp=300, out=30),
        _huge_compacted("resp-compact", "2026-10-06T10:00:03Z"),
    ]
    _write(root / "sessions" / "2026" / "10" / "06" / "rollout-2026-10-06T10-00-00-parent.jsonl", [_meta("parent", timestamp=T0), *rows])
    _write(
        root / "sessions" / "2026" / "10" / "06" / "rollout-2026-10-06T10-05-00-child.jsonl",
        [_meta("child", forked_from_id="parent", timestamp="2026-10-06T10:05:00Z"), *rows, _tokens(160, 60, "2026-10-06T10:06:00Z")],
    )

    assert _scan(tmp_path, root).codex_tokens == 100 + 330 + 60
