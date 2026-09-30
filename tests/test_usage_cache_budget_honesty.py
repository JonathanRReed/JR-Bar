"""A cache that had to drop entries for its size budget does not vouch for them.

The scan cache is capped (8 MiB, and a file-count bound). When a busy month does
not fit, whole per-file entries are left out. The token cards sum the entries
that were kept, so they would present that partial sum as the last 30 days.
The cache now records how far back it is whole (``complete_since``: just after
the newest record among the dropped entries), and the cards read that as the
floor: Claude shows nothing, Codex counts only the days that are whole.

Every scan here is a real ``scan_usage`` over synthetic transcripts and a fixed
"now"; the size bound is made small by pricing a record high, not by a big file.
"""

from __future__ import annotations

import json
import math
import os
from pathlib import Path

import pytest

import jrbar.provider_usage_codex_claude as subject
from jrbar import provider_homes, usage_stats
from tests.test_codex_usage_lineage import _meta, _tokens, _write
from tests.test_provider_usage_cached_scan import (
    DAY,
    OBSERVED,
    _at,
    _card_tokens,
    _claude_card,
    _claude_projects,
    _claude_transcript,
    _codex_rollouts,
    _scan_claude,
    _scan_codex,
    _state_cache,
)
from tests.test_usage_cache_bounds import _claude_line

#: Priced this high, one file of eight records takes 5.6 MB of the 8 MiB
#: budget, so a second such file cannot fit.
TIGHT_RECORD_COST = 700_000


@pytest.fixture(autouse=True)
def _default_homes_only(monkeypatch: pytest.MonkeyPatch) -> None:
    monkeypatch.delenv("CLAUDE_CONFIG_DIR", raising=False)
    monkeypatch.delenv("CODEX_HOME", raising=False)
    subject._local_tokens_memo.clear()


def _claude_cache_document(home: Path) -> dict:
    return json.loads(_state_cache(home).read_text(encoding="utf-8"))


def _two_claude_transcripts(home: Path) -> None:
    """A newer file (kept first) and an older one that will not fit beside it."""
    newer = _claude_transcript(
        _claude_projects(home),
        "newer.jsonl",
        [_claude_line("s1", f"new-{index}", OBSERVED - 2 * DAY) for index in range(8)],
    )
    older = _claude_transcript(
        _claude_projects(home),
        "older.jsonl",
        [_claude_line("s2", f"old-{index}", OBSERVED - 20 * DAY) for index in range(8)],
    )
    os.utime(newer, (OBSERVED - DAY, OBSERVED - DAY))
    os.utime(older, (OBSERVED - 3 * DAY, OBSERVED - 3 * DAY))


def test_a_size_drop_makes_the_claude_card_show_nothing_until_a_scan_fits(
    tmp_path: Path, monkeypatch: pytest.MonkeyPatch
) -> None:
    _two_claude_transcripts(tmp_path)
    real_cost = usage_stats._CACHE_BYTES_PER_RECORD
    monkeypatch.setattr(usage_stats, "_CACHE_BYTES_PER_RECORD", TIGHT_RECORD_COST)

    _scan_claude(tmp_path, graph_days=30)

    document = _claude_cache_document(tmp_path)
    assert len(document["files"]) == 1, "the fixture must leave one entry out"
    # The cache holds the newer file's records only, yet every entry it kept
    # was trimmed to a floor 33 days back. The card must not read that as
    # thirty whole days.
    complete_since = document["complete_since"]
    assert OBSERVED - 20 * DAY < complete_since < OBSERVED - 2 * DAY
    assert _claude_card(tmp_path) is None

    # Given room, the next scan keeps both files and the card fills in whole.
    monkeypatch.setattr(usage_stats, "_CACHE_BYTES_PER_RECORD", real_cost)
    _scan_claude(tmp_path, graph_days=30)

    assert "complete_since" not in _claude_cache_document(tmp_path)
    card = _claude_card(tmp_path)
    assert card is not None
    assert card["input_tokens"] == 160
    assert card["output_tokens"] == 80


def test_a_size_drop_limits_the_codex_card_to_the_days_that_are_whole(
    tmp_path: Path, monkeypatch: pytest.MonkeyPatch
) -> None:
    long_ago = OBSERVED - 25 * DAY
    lately = OBSERVED - 2 * DAY
    middle = OBSERVED - 20 * DAY
    kept_events = [
        *[_tokens(10 * (index + 1), 10, _at(long_ago + 60 * index)) for index in range(4)],
        *[_tokens(10 * (index + 5), 10, _at(lately + 60 * index)) for index in range(4)],
    ]
    dropped_events = [
        _tokens(10 * (index + 1), 10, _at(middle + 60 * index)) for index in range(8)
    ]
    root = tmp_path / ".codex" / "sessions"
    _write(root / "kept.jsonl", [_meta("kept", timestamp=_at(long_ago - 60)), *kept_events])
    _write(root / "dropped.jsonl", [_meta("dropped", timestamp=_at(middle - 60)), *dropped_events])
    os.utime(root / "kept.jsonl", (OBSERVED - DAY, OBSERVED - DAY))
    os.utime(root / "dropped.jsonl", (OBSERVED - 3 * DAY, OBSERVED - 3 * DAY))
    monkeypatch.setattr(usage_stats, "_CACHE_BYTES_PER_RECORD", TIGHT_RECORD_COST)

    _scan_codex(tmp_path, root, since_epoch=OBSERVED - 30 * DAY)
    card = subject._cached_provider_local_scan("codex", tmp_path, OBSERVED, extra_homes=())

    # The entry that did not fit had turns 20 days ago, so the cache is whole
    # only for the days after them: the four recent turns, not the four from
    # 25 days ago that happen to sit in a kept entry.
    assert _card_tokens(card) == 40


def test_a_file_count_drop_makes_the_claude_card_show_nothing(tmp_path: Path) -> None:
    _two_claude_transcripts(tmp_path)

    usage_stats.scan_usage(
        _claude_projects(tmp_path),
        _state_cache(tmp_path),
        since_epoch=OBSERVED - 30 * DAY,
        cache_max_files=1,
    )

    document = _claude_cache_document(tmp_path)
    assert len(document["files"]) == 1
    assert document["complete_since"] > OBSERVED - 20 * DAY
    assert _claude_card(tmp_path) is None


def test_a_cache_that_dropped_nothing_records_no_completeness_floor(tmp_path: Path) -> None:
    _two_claude_transcripts(tmp_path)

    _scan_claude(tmp_path, graph_days=30)

    document = _claude_cache_document(tmp_path)
    assert len(document["files"]) == 2
    assert "complete_since" not in document
    assert _claude_card(tmp_path) is not None


def test_dropped_entries_with_nothing_inside_the_window_cost_no_coverage(
    tmp_path: Path, monkeypatch: pytest.MonkeyPatch
) -> None:
    # The dropped file's records are all older than the retention floor, so
    # nothing the window could ask for is missing.
    newer = _claude_transcript(
        _claude_projects(tmp_path),
        "newer.jsonl",
        [_claude_line("s1", f"new-{index}", OBSERVED - 2 * DAY) for index in range(8)],
    )
    ancient = _claude_transcript(
        _claude_projects(tmp_path),
        "ancient.jsonl",
        [_claude_line("s2", f"ancient-{index}", OBSERVED - 90 * DAY) for index in range(8)],
    )
    os.utime(newer, (OBSERVED - DAY, OBSERVED - DAY))
    os.utime(ancient, (OBSERVED - 3 * DAY, OBSERVED - 3 * DAY))
    monkeypatch.setattr(usage_stats, "_CACHE_BYTES_PER_RECORD", TIGHT_RECORD_COST)

    _scan_claude(tmp_path, graph_days=30)

    assert "complete_since" not in _claude_cache_document(tmp_path)
    card = _claude_card(tmp_path)
    assert card is not None and card["input_tokens"] == 80


def test_an_unreadable_completeness_floor_is_never_trusted(tmp_path: Path) -> None:
    _two_claude_transcripts(tmp_path)
    _scan_claude(tmp_path, graph_days=30)
    assert _claude_card(tmp_path) is not None
    path = _state_cache(tmp_path)
    document = json.loads(path.read_text(encoding="utf-8"))
    document["complete_since"] = "soon"
    path.write_text(json.dumps(document), encoding="utf-8")
    subject._local_tokens_memo.clear()

    assert _claude_card(tmp_path) is None
    loaded = usage_stats._load_cache(path)
    reading = usage_stats.cache_provider_records(loaded, "claude")
    assert reading is not None and math.isinf(reading[1])


def test_one_home_that_overflowed_holds_the_whole_claude_total_back(
    tmp_path: Path, monkeypatch: pytest.MonkeyPatch
) -> None:
    # The primary home overflows its own cache; the extra home (a cache file
    # of its own) does not. The card needs every home whole, so the primary
    # home's drop holds the total back.
    _two_claude_transcripts(tmp_path)
    extra = tmp_path / "work-claude"
    _claude_transcript(
        extra / "projects",
        "work.jsonl",
        [_claude_line("w", "w1", OBSERVED - 3 * DAY)],
    )
    monkeypatch.setattr(usage_stats, "_CACHE_BYTES_PER_RECORD", TIGHT_RECORD_COST)
    provider_homes.scan_usage_all_homes(
        _state_cache(tmp_path),
        since_epoch=OBSERVED - 30 * DAY,
        provider_ids=("claude",),
        env={},
        home=tmp_path,
        extras={"claude": [str(extra)]},
    )

    assert _claude_card(tmp_path, extras=(str(extra),)) is None
