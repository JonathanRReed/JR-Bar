"""A busy month that does not fit the scan cache's entries is still totalled whole.

The scan cache is capped (8 MiB, and a file-count bound). When a busy month
does not fit, whole per-file entries are left out. The 30-day token cards do
not read those entries: every scan writes the card's own per-day totals
(``daily``) from the whole canonical stream it saw, a few dozen bytes a day
however many records the month held. So a size drop costs the next scan a
re-read of a file at worst, and costs the card nothing.

What stays honest is the one thing that can still go wrong: if even those
per-day totals cannot be held (too many distinct models, or past their own
byte bound), the cache carries none and the card says nothing rather than
total what it could not hold.

Every scan here is a real ``scan_usage`` over synthetic transcripts and a fixed
"now"; the size bound is made small by pricing a record high, not by a big file.
"""

from __future__ import annotations

import functools
import json
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


def test_a_size_drop_leaves_the_claude_card_whole(
    tmp_path: Path, monkeypatch: pytest.MonkeyPatch
) -> None:
    _two_claude_transcripts(tmp_path)
    monkeypatch.setattr(usage_stats, "_CACHE_BYTES_PER_RECORD", TIGHT_RECORD_COST)

    _scan_claude(tmp_path, graph_days=30)

    document = _claude_cache_document(tmp_path)
    assert len(document["files"]) == 1, "the fixture must leave one entry out"
    assert "complete_since" not in document, "nothing reads a completeness floor any more"
    # The entry that did not fit held 20-day-old messages. The card has them.
    card = _claude_card(tmp_path)
    assert card is not None
    assert card["input_tokens"] == 160
    assert card["output_tokens"] == 80


def test_a_size_drop_leaves_the_codex_card_whole(
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

    # Eight turns in the entry that was kept and eight in the one that was not.
    assert _card_tokens(card) == 160


def test_a_file_count_drop_leaves_the_claude_card_whole(tmp_path: Path) -> None:
    _two_claude_transcripts(tmp_path)

    usage_stats.scan_usage(
        _claude_projects(tmp_path),
        _state_cache(tmp_path),
        since_epoch=OBSERVED - 30 * DAY,
        cache_max_files=1,
        now=OBSERVED,
    )

    document = _claude_cache_document(tmp_path)
    assert len(document["files"]) == 1
    card = _claude_card(tmp_path)
    assert card is not None and card["input_tokens"] == 160


def test_dropped_entries_with_nothing_inside_the_window_cost_the_card_nothing(
    tmp_path: Path, monkeypatch: pytest.MonkeyPatch
) -> None:
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

    card = _claude_card(tmp_path)
    assert card is not None and card["input_tokens"] == 80


@pytest.mark.parametrize(
    "damage",
    ["missing", "since-text", "negative-count", "wrong-provider", "days-not-a-map", "bad-day"],
)
def test_a_card_section_that_cannot_be_trusted_is_never_summed(
    tmp_path: Path, damage: str
) -> None:
    _two_claude_transcripts(tmp_path)
    _scan_claude(tmp_path, graph_days=30)
    assert _claude_card(tmp_path) is not None
    path = _state_cache(tmp_path)
    document = json.loads(path.read_text(encoding="utf-8"))
    daily = document["daily"]
    first_day = next(iter(daily["days"]))
    first_model = next(iter(daily["days"][first_day]))
    if damage == "missing":
        del document["daily"]
    elif damage == "since-text":
        daily["since"] = "soon"
    elif damage == "negative-count":
        daily["days"][first_day][first_model][1] = -5
    elif damage == "wrong-provider":
        daily["provider"] = "codex"
    elif damage == "days-not-a-map":
        daily["days"] = [1, 2, 3]
    else:
        daily["days"]["yesterday"] = daily["days"].pop(first_day)
    path.write_text(json.dumps(document), encoding="utf-8")
    subject._local_tokens_memo.clear()

    assert _claude_card(tmp_path) is None
    assert usage_stats.cache_card_days(usage_stats._load_cache(path), "claude") is None

    # The next scan writes a fresh one and the card is whole again.
    _scan_claude(tmp_path, graph_days=30)
    card = _claude_card(tmp_path)
    assert card is not None and card["input_tokens"] == 160


def test_one_home_that_overflowed_still_gives_the_whole_claude_total(
    tmp_path: Path, monkeypatch: pytest.MonkeyPatch
) -> None:
    # The primary home overflows its own cache; the extra home (a cache file
    # of its own) does not. Every home's card days are whole either way.
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
        scan=functools.partial(usage_stats.scan_usage, now=OBSERVED),
    )

    card = _claude_card(tmp_path, extras=(str(extra),))

    assert card is not None
    assert card["input_tokens"] == 160 + 10
    assert card["output_tokens"] == 80 + 5


def test_card_days_that_do_not_fit_their_own_bound_leave_the_claude_card_empty(
    tmp_path: Path, monkeypatch: pytest.MonkeyPatch
) -> None:
    _two_claude_transcripts(tmp_path)
    monkeypatch.setattr(usage_stats, "USAGE_CARD_MAX_BYTES", 20)

    _scan_claude(tmp_path, graph_days=30)

    # The cache itself is fine and the entries are kept; it just carries no
    # totals the card could trust, and the card says nothing.
    document = _claude_cache_document(tmp_path)
    assert len(document["files"]) == 2
    assert "daily" not in document
    assert _claude_card(tmp_path) is None

    monkeypatch.undo()
    _scan_claude(tmp_path, graph_days=30)
    card = _claude_card(tmp_path)
    assert card is not None and card["input_tokens"] == 160


def test_more_distinct_models_than_the_bound_leave_the_claude_card_empty(
    tmp_path: Path, monkeypatch: pytest.MonkeyPatch
) -> None:
    _claude_transcript(
        _claude_projects(tmp_path),
        "two-models.jsonl",
        [
            _claude_line("s1", "m1", OBSERVED - 2 * DAY).replace("claude-opus-4", "claude-opus-4-5"),
            _claude_line("s1", "m2", OBSERVED - 2 * DAY).replace("claude-opus-4", "claude-haiku-4-5"),
        ],
    )
    monkeypatch.setattr(usage_stats, "USAGE_CARD_MAX_MODELS", 1)

    _scan_claude(tmp_path, graph_days=30)

    assert "daily" not in _claude_cache_document(tmp_path)
    assert _claude_card(tmp_path) is None
