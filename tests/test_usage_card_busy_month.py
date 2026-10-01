"""The Claude and Codex token cards on a busy month.

On a busy Mac a month of transcripts does not fit the scan cache's 8 MiB (the
owner measured Claude at about 275,000 usage lines in 30 days against a cache
that held about 74,000 records), and a 7-day graph scan used to narrow the
cache below 30 days. The cards then showed nothing (Claude) or about ten days
(Codex).

These tests generate a synthetic month of that size (``synthetic_usage_month``:
seeded, invented ids, a temporary home), run it through the real scan, and
check the card against an expectation the generator worked out on its own:

1. the 30-day card equals that expectation exactly;
2. the cache file stays under its bound, though the month does not fit it;
3. an incremental scan after appending changes the card by exactly the new
   records, and reads only the appended bytes;
4. a duplicate of an old record in a new file is ignored;
5. a 7-day graph scan leaves the 30-day coverage intact;
6. an old-version cache, a corrupt cache and a corrupt file index all rebuild;
7. the scan times are reported, and the card's own read never scans.

Clocks are arguments: the scan takes ``now``, the card ``observed_at``.
"""

from __future__ import annotations

import json
import os
import sqlite3
import time
from pathlib import Path

import pytest

import jrbar.provider_usage_codex_claude as subject
from jrbar import usage_file_index, usage_stats
from jrbar.state_paths import default_state_dir
from tests import synthetic_usage_month as month

NOW = 1_790_000_000
DAY = month.DAY


def _start() -> float:
    """The card's window start, taken under the test's own calendar."""
    return month.card_window_start(NOW)


@pytest.fixture(autouse=True)
def _chicago_calendar():
    """A calendar that is not UTC, so "a local day" is not a coincidence.

    A private patch, not the test's ``monkeypatch``: a test that calls
    ``monkeypatch.undo()`` must not put the calendar back."""
    patch = pytest.MonkeyPatch()
    patch.setenv("TZ", "America/Chicago")
    time.tzset()
    subject._local_tokens_memo.clear()
    try:
        yield
    finally:
        patch.undo()
        time.tzset()


def _cache(home: Path) -> Path:
    return default_state_dir(home) / "usage-scan-cache.json"


def _scan_claude(home: Path, *, since: float, now: float = NOW) -> usage_stats.UsageTotals:
    return usage_stats.scan_usage(
        home / ".claude" / "projects",
        _cache(home),
        since_epoch=since,
        provider_ids=("claude",),
        now=now,
    )


def _scan_codex(home: Path, *, since: float, now: float = NOW) -> usage_stats.UsageTotals:
    return usage_stats.scan_usage(
        home / ".claude" / "projects",
        _cache(home),
        codex_root=home / ".codex" / "sessions",
        since_epoch=since,
        provider_ids=("codex",),
        now=now,
    )


def _claude_card(home: Path) -> dict | None:
    return subject._cached_provider_local_scan("claude", home, NOW, extra_homes=())


def _codex_card(home: Path) -> dict | None:
    return subject._cached_provider_local_scan("codex", home, NOW, extra_homes=())


def _timed(label: str, action, report: list[str]):
    started = time.perf_counter()
    result = action()
    report.append(f"{label} {time.perf_counter() - started:.2f} s")
    return result


def _claude_cost(window: dict) -> tuple[float, float]:
    """The month's estimated cost and cache savings, one model name at a time
    from the generator's own sums and the price tables."""
    cost = savings = 0.0
    for model, (_records, inp, cached, creation, out) in window["by_model"].items():
        rate_in, rate_out = usage_stats._pricing_for_model(model)
        read = usage_stats.cache_read_rate_for_model(model)
        write = usage_stats.cache_write_rate_for_model(model)
        cost += (inp * rate_in + cached * rate_in * read + creation * rate_in * write + out * rate_out) / 1e6
        savings += cached * rate_in * (1.0 - read) / 1e6
    return cost, savings


def _assert_claude_card(card: dict | None, truth: month.ClaudeTruth, *, label: str) -> dict:
    assert card is not None, f"{label}: the Claude card showed nothing"
    window = truth.window(_start())
    assert card["input_tokens"] == window["input"], label
    assert card["cached_input_tokens"] == window["cached"], label
    assert card["output_tokens"] == window["output"], label
    assert card["model_count"] == window["models"], label
    cost, savings = _claude_cost(window)
    assert card["estimated_cost_usd"] == pytest.approx(cost, rel=1e-9), label
    assert card["cache_savings_usd"] == pytest.approx(savings, rel=1e-9), label
    return card


def _assert_codex_card(card: dict | None, truth: month.CodexTruth, *, label: str) -> dict:
    assert card is not None, f"{label}: the Codex card showed nothing"
    window = truth.window(_start())
    assert card["input_tokens"] == window["input"], label
    assert card["cached_input_tokens"] == window["cached"], label
    assert card["output_tokens"] == window["output"], label
    assert card["model_count"] == window["models"], label
    return card


def _file_index_path(cache: Path) -> Path:
    return cache.with_suffix(".files.sqlite3")


def _assert_inside_the_bound(cache: Path) -> int:
    size = cache.stat().st_size
    assert size <= usage_stats.USAGE_CACHE_MAX_BYTES, f"{cache.name} is {size} bytes"
    index = _file_index_path(cache)
    if index.exists():
        assert index.stat().st_size <= usage_file_index.MAX_DATABASE_BYTES
    return size


def test_a_busy_claude_month_is_totalled_whole_and_stays_whole(
    tmp_path: Path,
    monkeypatch: pytest.MonkeyPatch,
    capsys: pytest.CaptureFixture[str],
) -> None:
    report: list[str] = []
    truth = month.build_claude_month(tmp_path, now=NOW)
    assert truth.raw_lines >= 300_000, "the month must be a busy one"
    window = truth.window(_start())
    # The premise: this month's records do not fit the cache's entry budget.
    assert (
        window["messages"] * usage_stats._CACHE_BYTES_PER_RECORD > usage_stats.USAGE_CACHE_MAX_BYTES
    ), "the month fits the cache; it proves nothing"
    cache = _cache(tmp_path)

    # --- (1) the 30-day card equals the expectation exactly, and the scan agrees
    scanned = _timed("claude cold 30-day scan", lambda: _scan_claude(tmp_path, since=_start()), report)
    assert scanned.input_tokens == window["input"]
    assert scanned.output_tokens == window["output"]
    assert len(scanned.records) == window["messages"]
    card = _assert_claude_card(_claude_card(tmp_path), truth, label="after the 30-day scan")

    # --- (2) the cache file stays inside its bound, though the month does not fit it
    size = _assert_inside_the_bound(cache)
    document = json.loads(cache.read_text(encoding="utf-8"))
    kept = sum(len(entry["records"]) for entry in document["files"].values())
    assert 0 < kept < window["messages"], "the entries were meant to overflow; the card must not need them"
    assert "complete_since" not in document

    # --- (5) a 7-day graph scan leaves the 30-day coverage intact
    narrow = _timed(
        "claude 7-day graph scan", lambda: _scan_claude(tmp_path, since=NOW - 7 * DAY), report
    )
    assert len(narrow.records) == truth.window(NOW - 7 * DAY)["messages"], (
        "the graph is given its own 7 days, no more and no fewer"
    )
    assert _claude_card(tmp_path) == card, "a 7-day graph scan narrowed the card"
    _assert_inside_the_bound(cache)
    # and the other way round: a 365-day graph scan changes nothing either
    _scan_claude(tmp_path, since=NOW - 365 * DAY)
    assert _claude_card(tmp_path) == card

    # --- (3) an incremental scan changes the total by exactly the new records
    reads: list[tuple[Path, int, int]] = []
    real_read = usage_stats._read_verified_prefix

    def watched(path, info, resume_offset=0):
        reads.append((path, resume_offset, info.st_size))
        return real_read(path, info, resume_offset)

    monkeypatch.setattr(usage_stats, "_read_verified_prefix", watched)
    grown = [
        truth.files[3], truth.files[17], truth.files[40],
    ]
    before_sizes = {}
    for index, path in enumerate(grown):
        before_sizes[path] = month.append_claude_messages(
            path, truth, count=700, start_epoch=NOW - 5000 - 1000 * index,
            prefix=f"grown-{index}", seed=100 + index,
        )
    fresh = tmp_path / ".claude" / "projects" / "project-00" / "fresh-session.jsonl"
    fresh.parent.mkdir(parents=True, exist_ok=True)
    fresh.write_text("", encoding="utf-8")
    month.append_claude_messages(
        fresh, truth, count=900, start_epoch=NOW - 2000, prefix="fresh", seed=200,
        session="claude-fresh",
    )
    truth.files.append(fresh)
    moved = _timed("claude incremental scan (3 files grew, 1 new)", lambda: _scan_claude(tmp_path, since=_start()), report)
    after_append = _assert_claude_card(_claude_card(tmp_path), truth, label="after appending")
    assert after_append["input_tokens"] > card["input_tokens"]
    grown_input = sum(
        truth.messages[mid][2]
        for mid in truth.messages
        if mid.startswith(("grown-", "fresh-"))
    )
    assert after_append["input_tokens"] - card["input_tokens"] == grown_input, (
        "the total moved by something other than the new records"
    )
    assert len(moved.records) == window["messages"] + 3 * 700 + 900
    expected_reads = sorted(
        [(path, before_sizes[path], path.stat().st_size) for path in grown]
        + [(fresh, 0, fresh.stat().st_size)]
    )
    assert sorted(reads) == expected_reads, "an unchanged file was read again, or a tail read from the start"
    monkeypatch.undo()
    subject._local_tokens_memo.clear()

    # --- (4) a duplicate of an old record in a new file is ignored
    old_ids = sorted(
        mid for mid, row in truth.messages.items() if NOW - 25 * DAY <= row[0] <= NOW - 15 * DAY
    )[:600]
    assert len(old_ids) == 600
    copy_lines = []
    session_name = "claude-resumed-copy"
    for mid in old_ids:
        epoch, model, *counts = truth.messages[mid]
        copy_lines.append(month._claude_line(session_name, mid, epoch, model, tuple(counts)))
    brand_new = month._claude_line(session_name, "after-the-copy-0", NOW - 90, month.CLAUDE_MODELS[1], (11, 22, 33, 44))
    truth.add("after-the-copy-0", NOW - 90, month.CLAUDE_MODELS[1], (11, 22, 33, 44))
    duplicate_file = tmp_path / ".claude" / "projects" / "project-01" / "resumed-copy.jsonl"
    duplicate_file.write_text("".join([*copy_lines, copy_lines[0], brand_new]), encoding="utf-8")
    os.utime(duplicate_file, (NOW - 60, NOW - 60))
    _scan_claude(tmp_path, since=_start())
    duplicated = _assert_claude_card(_claude_card(tmp_path), truth, label="after a copy of old records")
    assert duplicated["input_tokens"] - after_append["input_tokens"] == 11
    assert duplicated["output_tokens"] - after_append["output_tokens"] == 44
    assert duplicated["cached_input_tokens"] - after_append["cached_input_tokens"] == 22

    # --- an unchanged scan is warm and changes nothing
    warm = _timed("claude warm scan (nothing changed)", lambda: _scan_claude(tmp_path, since=_start()), report)
    assert warm.source_coverage["claude"].files_read == 0
    assert _claude_card(tmp_path) == duplicated

    # --- (7) the card's own read never scans, and is quick
    def refuse(*_args, **_kwargs):
        raise AssertionError("the card read scanned the transcripts")

    monkeypatch.setattr(usage_stats, "_provider_inventory", refuse)
    monkeypatch.setattr(usage_stats, "_scan_inventory_usage", refuse)
    monkeypatch.setattr(usage_stats, "_read_verified_prefix", refuse)
    subject._local_tokens_memo.clear()
    started = time.perf_counter()
    quick = subject._default_claude_local_scan(tmp_path, NOW)
    card_read = time.perf_counter() - started
    report.append(f"claude card read (cache load + sum) {card_read * 1000:.0f} ms")
    assert quick == duplicated
    assert card_read < 2.0, "the card read is no longer quick"
    monkeypatch.undo()

    # --- (6) an old-version cache and a corrupt one are rebuilt, never trusted
    document = json.loads(cache.read_text(encoding="utf-8"))
    document["version"] = usage_stats.CACHE_VERSION - 1
    cache.write_text(json.dumps(document), encoding="utf-8")
    subject._local_tokens_memo.clear()
    assert _claude_card(tmp_path) is None, "an old-version cache was trusted"
    _scan_claude(tmp_path, since=_start())
    assert json.loads(cache.read_text(encoding="utf-8"))["version"] == usage_stats.CACHE_VERSION
    assert _claude_card(tmp_path) == duplicated

    cache.write_bytes(b"\x00not json at all \xff")
    subject._local_tokens_memo.clear()
    assert _claude_card(tmp_path) is None, "a corrupt cache was trusted"
    _scan_claude(tmp_path, since=_start())
    assert _claude_card(tmp_path) == duplicated

    # The file index of an older version is cleared and every file read again.
    index = _file_index_path(cache)
    connection = sqlite3.connect(index)
    try:
        connection.execute("UPDATE metadata SET cache_version = ?", (usage_stats.CACHE_VERSION - 1,))
        connection.commit()
    finally:
        connection.close()
    rebuilt = _timed("claude rebuild after an old-version index", lambda: _scan_claude(tmp_path, since=_start()), report)
    assert rebuilt.source_coverage["claude"].files_read > 0, "an old-version index was trusted"
    assert _claude_card(tmp_path) == duplicated

    # With no usable index at all the scan reads what the entries do not hold,
    # and the card is still exactly the same.
    index.write_bytes(b"this is not a database" * 100)
    cache.write_bytes(b"{}")
    no_index = _timed("claude rebuild with a corrupt index and cache", lambda: _scan_claude(tmp_path, since=_start()), report)
    assert no_index.source_coverage["claude"].files_read > 0
    assert _claude_card(tmp_path) == duplicated
    _assert_inside_the_bound(cache)

    with capsys.disabled():
        print(
            f"\nclaude month: {truth.raw_lines} usage lines, {len(truth.messages)} distinct messages "
            f"({window['messages']} in the 30 days), cache {size} bytes, cache entries kept {kept}; "
            + "; ".join(report)
        )


def test_a_busy_codex_month_is_totalled_whole_and_stays_whole(
    tmp_path: Path,
    monkeypatch: pytest.MonkeyPatch,
    capsys: pytest.CaptureFixture[str],
) -> None:
    report: list[str] = []
    truth = month.build_codex_month(tmp_path, now=NOW)
    window = truth.window(_start())
    assert truth.raw_events >= 100_000, "the month must be a busy one"
    cache = _cache(tmp_path)
    codex_cache = usage_stats.provider_cache_path(
        cache,
        next(
            row.source_key
            for row in usage_stats.negotiated_provider_sources()
            if row.source_key.provider_id == "codex"
            and row.source_key.capability_id == "transcript_usage"
        ),
    )

    # --- (1)
    scanned = _timed("codex cold 30-day scan", lambda: _scan_codex(tmp_path, since=_start()), report)
    assert scanned.codex_tokens == (
        window["input"] + window["cached"] + window["write"] + window["output"]
    )
    card = _assert_codex_card(_codex_card(tmp_path), truth, label="after the 30-day scan")

    # --- (2)
    size = _assert_inside_the_bound(codex_cache)
    document = json.loads(codex_cache.read_text(encoding="utf-8"))
    kept = sum(len(entry["records"]) for entry in document["files"].values())
    assert 0 < kept < window["events"], "the entries were meant to overflow"
    assert "complete_since" not in document

    # --- (5)
    _timed("codex 7-day graph scan", lambda: _scan_codex(tmp_path, since=NOW - 7 * DAY), report)
    assert _codex_card(tmp_path) == card, "a 7-day graph scan narrowed the card"
    _assert_inside_the_bound(codex_cache)

    # --- (3) a rollout grows and a new one starts
    reads: list[tuple[Path, int, int]] = []
    real_read = usage_stats._read_verified_prefix

    def watched(path, info, resume_offset=0):
        reads.append((path, resume_offset, info.st_size))
        return real_read(path, info, resume_offset)

    monkeypatch.setattr(usage_stats, "_read_verified_prefix", watched)
    grown_session = next(
        name for name in sorted(truth.rollouts) if truth.rollouts[name][-1][0] < NOW - 6 * 3600
    )
    grown_path = truth.paths[grown_session]
    last_total = truth.rollouts[grown_session][-1][1]
    grown_epoch = truth.rollouts[grown_session][-1][0]
    before_size, _totals = month.append_codex_events(
        grown_path, truth, session=grown_session, first_total=last_total, count=800,
        start_epoch=grown_epoch + 10, seed=7, model=truth.models[grown_session],
    )
    brand_new = tmp_path / ".codex" / "sessions" / "2026" / "rollout-brand-new.jsonl"
    brand_new.parent.mkdir(parents=True, exist_ok=True)
    brand_new.write_text(
        month._codex_meta("codex-brand-new", NOW - 8000)
        + month._codex_context(month.CODEX_MODELS[0], NOW - 7990),
        encoding="utf-8",
    )
    month.append_codex_events(
        brand_new, truth, session="codex-brand-new", first_total=(0, 0, 0, 0), count=500,
        start_epoch=NOW - 7000, seed=8, model=month.CODEX_MODELS[0],
    )
    _timed("codex incremental scan (1 rollout grew, 1 new)", lambda: _scan_codex(tmp_path, since=_start()), report)
    after_append = _assert_codex_card(_codex_card(tmp_path), truth, label="after appending")
    appended_input = sum(
        row[2]
        for key, row in truth.events.items()
        if key[0] == "codex-brand-new" or (key[0] == grown_session and row[0] > grown_epoch)
    )
    assert after_append["input_tokens"] - card["input_tokens"] == appended_input
    assert sorted(reads) == sorted(
        [(grown_path, before_size, grown_path.stat().st_size), (brand_new, 0, brand_new.stat().st_size)]
    ), "an unchanged rollout was read again, or a tail read from the start"
    monkeypatch.undo()
    subject._local_tokens_memo.clear()

    # --- (4) a whole copy and a fork of old rollouts add nothing of their own
    old_session = next(
        name for name in sorted(truth.rollouts)
        if truth.rollouts[name][len(truth.rollouts[name]) // 2][0] < NOW - 20 * DAY
        and truth.rollouts[name][-1][0] > NOW - 24 * DAY
        and name != grown_session
    )
    month.write_codex_copy(tmp_path / ".codex" / "sessions" / "copies" / "another-copy.jsonl", truth, old_session)
    events = truth.rollouts[old_session]
    copied = len(events) // 2
    month.write_codex_fork(
        tmp_path / ".codex" / "sessions" / "2026" / "rollout-late-fork.jsonl",
        truth, old_session, "codex-late-fork", copied=copied, own=40,
        start_epoch=events[copied - 1][0] + 3600, seed=9,
    )
    _scan_codex(tmp_path, since=_start())
    forked = _assert_codex_card(_codex_card(tmp_path), truth, label="after a copy and a fork")
    own = sum(
        row[2] for key, row in truth.events.items() if key[0] == "codex-late-fork" and row[0] >= _start()
    )
    assert forked["input_tokens"] - after_append["input_tokens"] == own

    # --- warm, and the card read never scans
    warm = _timed("codex warm scan (nothing changed)", lambda: _scan_codex(tmp_path, since=_start()), report)
    assert warm.source_coverage["codex"].files_read == 0
    assert _codex_card(tmp_path) == forked

    def refuse(*_args, **_kwargs):
        raise AssertionError("the card read scanned the transcripts")

    monkeypatch.setattr(usage_stats, "_provider_inventory", refuse)
    monkeypatch.setattr(usage_stats, "_scan_inventory_usage", refuse)
    monkeypatch.setattr(usage_stats, "_read_verified_prefix", refuse)
    subject._local_tokens_memo.clear()
    started = time.perf_counter()
    quick = subject._default_codex_local_scan(tmp_path, NOW)
    card_read = time.perf_counter() - started
    report.append(f"codex card read (cache load + sum) {card_read * 1000:.0f} ms")
    assert quick is not None
    for name in ("input_tokens", "cached_input_tokens", "output_tokens", "model_count"):
        assert quick[name] == forked[name]
    assert card_read < 2.0
    monkeypatch.undo()

    # --- (6)
    document = json.loads(codex_cache.read_text(encoding="utf-8"))
    document["version"] = usage_stats.CACHE_VERSION - 1
    codex_cache.write_text(json.dumps(document), encoding="utf-8")
    subject._local_tokens_memo.clear()
    assert _codex_card(tmp_path) is None, "an old-version cache was trusted"
    _scan_codex(tmp_path, since=_start())
    assert json.loads(codex_cache.read_text(encoding="utf-8"))["version"] == usage_stats.CACHE_VERSION
    assert _codex_card(tmp_path) == forked

    codex_cache.write_bytes(b"\x00not json at all \xff")
    subject._local_tokens_memo.clear()
    assert _codex_card(tmp_path) is None, "a corrupt cache was trusted"
    _scan_codex(tmp_path, since=_start())
    assert _codex_card(tmp_path) == forked

    index = codex_cache.with_suffix(".files.sqlite3")
    index.write_bytes(b"this is not a database" * 100)
    codex_cache.write_bytes(b"{}")
    rebuilt = _timed("codex rebuild with a corrupt index and cache", lambda: _scan_codex(tmp_path, since=_start()), report)
    assert rebuilt.source_coverage["codex"].files_read > 0
    assert _codex_card(tmp_path) == forked
    _assert_inside_the_bound(codex_cache)

    with capsys.disabled():
        print(
            f"\ncodex month: {truth.raw_events} token events, {len(truth.events)} own "
            f"({window['events']} in the 30 days), cache {size} bytes, cache entries kept {kept}; "
            + "; ".join(report)
        )
