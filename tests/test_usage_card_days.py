"""The 30-day token card's window, and what every scan keeps for it.

The card totals today and the 29 local days before it, the same days the
graph's 30-day range draws. Every scan reads at least that far back and writes
the card's per-day totals into its cache (``daily``), whatever range its caller
asked for. These tests pin the window, the boundary, the wider read, and that a
scan nobody changed anything for does not rewrite its cache.

Small corpora here; ``test_usage_card_busy_month`` is the month-sized proof.
"""

from __future__ import annotations

import calendar
import json
import os
import time
from datetime import datetime
from pathlib import Path

import pytest

import jrbar.provider_usage_codex_claude as subject
from jrbar import usage_graph_worker, usage_stats
from jrbar.state_paths import default_state_dir
from tests import synthetic_usage_month as month
from tests.test_usage_cache_bounds import _claude_line, _write_transcript

DAY = month.DAY
#: 2026-11-05 10:00 in Chicago (16:00 UTC). The US clocks went back on
#: 2026-11-01, so the 30-day window crosses the change and a local day is not
#: always 24 hours.
NOW = float(calendar.timegm((2026, 11, 5, 16, 0, 0)))


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


def _projects(home: Path) -> Path:
    return home / ".claude" / "projects"


def _scan(home: Path, *, since: float, now: float = NOW, cache: bool = True):
    return usage_stats.scan_usage(
        _projects(home),
        _cache(home) if cache else None,
        since_epoch=since,
        provider_ids=("claude",),
        now=now,
    )


def _card(home: Path, observed_at: float = NOW) -> dict | None:
    return subject._cached_provider_local_scan("claude", home, observed_at, extra_homes=())


def _transcript(home: Path, name: str, lines: list[str], *, mtime: float | None = None) -> Path:
    path = _write_transcript(_projects(home), name, lines)
    stamp = NOW - DAY if mtime is None else mtime
    os.utime(path, (stamp, stamp))
    return path


def test_the_card_window_is_today_and_the_29_local_days_before_it() -> None:
    start = usage_stats.card_window_start(NOW)

    assert start == datetime(2026, 10, 7, 0, 0).timestamp()
    # The graph's 30-day range and the Usage window's `30d` start on the same
    # instant, so the card cannot total a different month than they draw.
    graph_start = usage_graph_worker._period_start(30, now=datetime.fromtimestamp(NOW))
    assert graph_start.timestamp() == start
    # The clocks went back on 2026-11-01, so those 29 days and 10 hours of the
    # calendar are one hour longer on the clock: a day is not always 24 hours.
    assert (NOW - start) / 3600 == pytest.approx(29 * 24 + 10 + 1)


def test_the_card_counts_from_the_first_instant_of_its_first_day(tmp_path: Path) -> None:
    start = usage_stats.card_window_start(NOW)
    _transcript(
        tmp_path,
        "boundary.jsonl",
        [
            _claude_line("s1", "just-before", start - 1),
            _claude_line("s1", "first-instant", start),
            _claude_line("s1", "today", NOW - 60),
        ],
    )

    _scan(tmp_path, since=start)
    card = _card(tmp_path)

    assert card is not None
    assert card["input_tokens"] == 20, "the first instant is in the window and the second before it is not"
    assert card["output_tokens"] == 10


def test_a_scan_reads_back_to_the_card_window_whatever_range_it_is_asked_for(
    tmp_path: Path, monkeypatch: pytest.MonkeyPatch
) -> None:
    start = usage_stats.card_window_start(NOW)
    recent = _transcript(tmp_path, "recent.jsonl", [_claude_line("s1", "r1", NOW - 2 * DAY)])
    # Last written 20 days ago: outside a 7-day graph, inside the card.
    older = _transcript(
        tmp_path, "older.jsonl", [_claude_line("s2", "o1", NOW - 20 * DAY)], mtime=NOW - 20 * DAY
    )
    # Last written 40 days ago: outside the card, so nothing in it is read.
    ancient = _transcript(
        tmp_path, "ancient.jsonl", [_claude_line("s3", "a1", NOW - 40 * DAY)], mtime=NOW - 40 * DAY
    )
    reads: list[Path] = []
    real_read = usage_stats._read_verified_prefix

    def watched(path, info, resume_offset=0):
        reads.append(path)
        return real_read(path, info, resume_offset)

    monkeypatch.setattr(usage_stats, "_read_verified_prefix", watched)
    graph = _scan(tmp_path, since=NOW - 7 * DAY)
    monkeypatch.undo()

    assert sorted(reads) == sorted([recent, older]), "the 20-day-old file must be read, the 40-day-old one not"
    assert ancient not in reads
    # The graph is given its own 7 days and nothing else...
    assert len(graph.records) == 1
    # ...and the cache still reaches back the card's 30 days.
    document = json.loads(_cache(tmp_path).read_text(encoding="utf-8"))
    assert document["daily"]["since"] == start
    card = _card(tmp_path)
    assert card is not None and card["input_tokens"] == 20


def test_a_wider_read_does_not_change_what_a_narrow_scan_returns(tmp_path: Path) -> None:
    _transcript(
        tmp_path,
        "mixed.jsonl",
        [
            _claude_line("s1", "week", NOW - 3 * DAY),
            _claude_line("s1", "fortnight", NOW - 14 * DAY),
            _claude_line("s1", "month", NOW - 27 * DAY),
        ],
    )

    cached = _scan(tmp_path, since=NOW - 7 * DAY)
    again = _scan(tmp_path, since=NOW - 7 * DAY)
    uncached = _scan(tmp_path, since=NOW - 7 * DAY, cache=False)

    assert sorted(record[3] for record in cached.records) == [NOW - 3 * DAY]
    # (The dedupe key is an HMAC under each cache's own secret, so it is left
    # out of the comparison; everything else a record says must be the same.)
    assert cached.records == again.records
    assert [r[:8] for r in cached.records] == [r[:8] for r in uncached.records]
    assert (cached.input_tokens, cached.output_tokens) == (uncached.input_tokens, uncached.output_tokens)


def test_the_card_and_the_graphs_30_day_buckets_total_the_same_tokens(tmp_path: Path) -> None:
    start = usage_stats.card_window_start(NOW)
    lines = [
        _claude_line("s1", f"m{index}", start + index * 41_000 + 7)
        for index in range(60)
    ]
    _transcript(tmp_path, "month.jsonl", lines)
    scanned = _scan(tmp_path, since=start)

    buckets = usage_stats.daily_buckets(
        scanned.records, days=30, now=datetime.fromtimestamp(NOW)
    )
    graph_tokens = sum(
        bucket["providers"].get("claude", {}).get("tokens", 0) for bucket in buckets.values()
    )
    document = json.loads(_cache(tmp_path).read_text(encoding="utf-8"))
    card_days = usage_stats.cache_card_days(document, "claude")
    assert card_days is not None
    card_tokens = sum(
        input_tokens + cached + creation + output
        for rows in card_days.days.values()
        for (_records, input_tokens, cached, creation, output) in rows.values()
    )

    assert graph_tokens == card_tokens == 60 * 15
    assert sum(1 for rows in card_days.days.values() if rows) > 20, "the days must spread across the month"


def test_a_scan_nobody_changed_anything_for_does_not_rewrite_the_cache(tmp_path: Path) -> None:
    _transcript(tmp_path, "session.jsonl", [_claude_line("s1", "m1", NOW - DAY)])
    start = usage_stats.card_window_start(NOW)
    _scan(tmp_path, since=start)
    before = _cache(tmp_path).stat().st_mtime_ns

    # Later the same day: a different moment, the same local days.
    _scan(tmp_path, since=start, now=NOW + 3 * 3600)
    _scan(tmp_path, since=NOW - 7 * DAY, now=NOW + 3 * 3600)

    assert _cache(tmp_path).stat().st_mtime_ns == before


def test_the_cache_version_changed_so_an_older_cache_is_not_read(tmp_path: Path) -> None:
    _transcript(tmp_path, "session.jsonl", [_claude_line("s1", "m1", NOW - DAY)])
    _scan(tmp_path, since=usage_stats.card_window_start(NOW))
    document = json.loads(_cache(tmp_path).read_text(encoding="utf-8"))
    assert document["version"] == usage_stats.CACHE_VERSION == 8
    document["version"] = 7
    _cache(tmp_path).write_text(json.dumps(document), encoding="utf-8")
    subject._local_tokens_memo.clear()

    assert _card(tmp_path) is None
    assert usage_stats._load_cache(_cache(tmp_path)) == {}


def test_reading_a_day_later_slides_the_window_over_the_same_cache(tmp_path: Path) -> None:
    # Reading a day later than the scan: the window slides one day, the day
    # that fell off the front is not counted, and the cache is still whole.
    start = usage_stats.card_window_start(NOW)
    _transcript(
        tmp_path,
        "session.jsonl",
        [
            _claude_line("s1", "first-day", start + 3600),
            _claude_line("s1", "second-day", start + DAY + 3600),
            _claude_line("s1", "today", NOW - 60),
        ],
    )
    _scan(tmp_path, since=start)

    today = _card(tmp_path)
    tomorrow = _card(tmp_path, NOW + DAY)

    assert today is not None and today["input_tokens"] == 30
    assert tomorrow is not None and tomorrow["input_tokens"] == 20, "the first day is no longer in the window"


def test_a_message_late_on_the_first_day_leaves_with_that_day_not_the_next_one(
    tmp_path: Path,
) -> None:
    # 23:30 on the window's first local day is already the next day in UTC.
    # A day keyed on the UTC date would keep this message in the card for a
    # day after its local day left the window.
    start = usage_stats.card_window_start(NOW)
    _transcript(
        tmp_path,
        "session.jsonl",
        [
            _claude_line("s1", "late-first-day", start + 23.5 * 3600),
            _claude_line("s1", "today", NOW - 60),
        ],
    )
    _scan(tmp_path, since=start)

    today = _card(tmp_path)
    tomorrow = _card(tmp_path, NOW + DAY)

    assert today is not None and today["input_tokens"] == 20
    assert tomorrow is not None and tomorrow["input_tokens"] == 10


def test_a_codex_card_with_no_per_day_totals_keeps_its_windows_and_counts_nothing(
    tmp_path: Path,
) -> None:
    # The cache is readable but holds no card days (an overflow left them
    # out): Codex keeps its quota evidence and counts no days it cannot vouch
    # for, and Claude shows nothing at all.
    from tests.test_codex_usage_lineage import _meta, _tokens, _write
    from tests.test_provider_usage_cached_scan import _at

    started = NOW - 3 * DAY
    event = _tokens(100, 100, _at(started + 60))
    event["payload"]["rate_limits"] = {
        "primary": {"used_percent": 40.0, "window_minutes": 300, "resets_at": started + 3600}
    }
    root = tmp_path / ".codex" / "sessions"
    _write(root / "limits.jsonl", [_meta("limits", timestamp=_at(started)), event])
    os.utime(root / "limits.jsonl", (NOW - 3600, NOW - 3600))
    usage_stats.scan_usage(
        tmp_path / ".claude" / "projects", _cache(tmp_path), codex_root=root,
        since_epoch=usage_stats.card_window_start(NOW), provider_ids=("codex",), now=NOW,
    )
    source_key = next(
        row.source_key
        for row in usage_stats.negotiated_provider_sources()
        if row.source_key.provider_id == "codex" and row.source_key.capability_id == "transcript_usage"
    )
    path = usage_stats.provider_cache_path(_cache(tmp_path), source_key)
    document = json.loads(path.read_text(encoding="utf-8"))
    del document["daily"]
    path.write_text(json.dumps(document), encoding="utf-8")
    subject._local_tokens_memo.clear()

    card = subject._cached_provider_local_scan("codex", tmp_path, NOW, extra_homes=())

    assert card is not None
    assert card["input_tokens"] == 0 and card["model_count"] == 0
    assert len(card["windows"]) == 1 and card["windows"][0]["used_percent"] == 40.0


def test_a_folder_that_cannot_be_walked_leaves_the_last_good_month_alone(tmp_path: Path) -> None:
    start = usage_stats.card_window_start(NOW)
    _transcript(
        tmp_path,
        "session.jsonl",
        [_claude_line("s1", "a", NOW - 3 * DAY), _claude_line("s1", "b", NOW - 2 * DAY)],
    )
    _scan(tmp_path, since=start)
    good = _card(tmp_path)
    assert good is not None and good["input_tokens"] == 20

    # The transcripts folder is gone for a moment (an unmounted home, a
    # folder that would not open). The scan sees nothing, and says nothing
    # about the month: the card keeps its last good reading.
    moved = tmp_path / ".claude" / "moved-away"
    _projects(tmp_path).rename(moved)
    _scan(tmp_path, since=start)
    assert _card(tmp_path) == good

    # It comes back with one more message; the next scan counts it.
    moved.rename(_projects(tmp_path))
    transcript = next(_projects(tmp_path).rglob("session.jsonl"))
    with transcript.open("a", encoding="utf-8") as handle:
        handle.write(_claude_line("s1", "c", NOW - 60) + "\n")
    os.utime(transcript, (NOW - 30, NOW - 30))
    _scan(tmp_path, since=start)
    card = _card(tmp_path)
    assert card is not None and card["input_tokens"] == 30


def test_a_folder_that_cannot_be_opened_does_not_shrink_the_month(tmp_path: Path) -> None:
    start = usage_stats.card_window_start(NOW)
    _transcript(tmp_path, "one.jsonl", [_claude_line("s1", "a", NOW - 3 * DAY)])
    other = _projects(tmp_path) / "locked-project"
    other.mkdir(parents=True)
    locked = other / "two.jsonl"
    locked.write_text(_claude_line("s2", "b", NOW - 2 * DAY) + "\n", encoding="utf-8")
    os.utime(locked, (NOW - DAY, NOW - DAY))
    _scan(tmp_path, since=start)
    good = _card(tmp_path)
    assert good is not None and good["input_tokens"] == 20

    other.chmod(0o000)
    try:
        scanned = _scan(tmp_path, since=start)
        # The graph is given what the walk could read, and says it is partial...
        assert scanned.source_coverage["claude"].status is usage_stats.UsageSourceStatus.PARTIAL
        assert len(scanned.records) == 1
        # ...but the card does not total a month that leaves a folder out.
        assert _card(tmp_path) == good
    finally:
        other.chmod(0o700)
