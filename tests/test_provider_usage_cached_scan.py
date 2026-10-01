"""The quota refresh's token totals come from the scan cache, and must agree
with the scan that wrote it.

Every test here builds a real cache with ``usage_stats.scan_usage`` and reads
it back through the provider cards' cached readers. Nothing patches
``_load_cache``. Clocks are passed in as ``OBSERVED`` (the scan takes it as
``now``, the reader as ``observed_at``); nothing sleeps.

The card totals the last 30 local days. Every scan writes those days into its
cache whatever range it was asked for, so a graph scan of any length leaves
the card whole.
"""

from __future__ import annotations

import functools
import json
import os
import time
from pathlib import Path

import pytest

import jrbar.provider_usage_codex_claude as subject
from jrbar import provider_homes, usage_stats
from jrbar.state_paths import default_state_dir
from tests.test_codex_usage_lineage import _meta, _tokens, _write
from tests.test_usage_cache_bounds import _claude_line, _write_transcript

DAY = 24 * 60 * 60


@pytest.fixture(autouse=True)
def _default_homes_only(monkeypatch: pytest.MonkeyPatch) -> None:
    """The reader's default homes come from the environment; pin them."""
    monkeypatch.delenv("CLAUDE_CONFIG_DIR", raising=False)
    monkeypatch.delenv("CODEX_HOME", raising=False)
    subject._local_tokens_memo.clear()
    subject._noted_once.clear()


#: A fixed "now" (2026-08-29T10:40:00Z) so no window depends on the wall clock.
OBSERVED = 1_788_000_000.0


def _at(epoch: float) -> str:
    return time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime(epoch))


def _turn_context(model: str, epoch: float) -> dict:
    return {"type": "turn_context", "timestamp": _at(epoch), "payload": {"model": model}}


def _state_cache(home: Path) -> Path:
    return default_state_dir(home) / "usage-scan-cache.json"


def _codex_rollouts(home: Path, files: dict[str, list[dict]]) -> Path:
    root = home / ".codex" / "sessions"
    for name, rows in files.items():
        _write(root / name, rows)
        os.utime(root / name, (OBSERVED - DAY, OBSERVED - DAY))
    return root


def _scan_codex(
    home: Path, root: Path, *, since_epoch: float, now: float = OBSERVED
) -> usage_stats.UsageTotals:
    return usage_stats.scan_usage(
        home / ".claude" / "projects",
        _state_cache(home),
        codex_root=root,
        since_epoch=since_epoch,
        provider_ids=("codex",),
        now=now,
    )


def _card_tokens(document: dict | None) -> int:
    assert document is not None
    return (
        int(document["input_tokens"])
        + int(document["cached_input_tokens"])
        + int(document["output_tokens"])
    )


def test_cached_codex_scan_counts_a_forked_rollout_once(tmp_path: Path) -> None:
    inherited_at = OBSERVED - 5 * DAY
    inherited = _tokens(100, 100, _at(inherited_at))
    root = _codex_rollouts(
        tmp_path,
        {
            "parent.jsonl": [_meta("parent", timestamp=_at(inherited_at - 60)), inherited],
            "child.jsonl": [
                _meta("child", forked_from_id="parent", timestamp=_at(inherited_at + 30)),
                inherited,
                _tokens(140, 40, _at(inherited_at + 120)),
            ],
        },
    )
    scanned = _scan_codex(tmp_path, root, since_epoch=OBSERVED - 30 * DAY)
    assert scanned.codex_tokens == 140

    assert _card_tokens(subject._cached_codex_local_scan(tmp_path, OBSERVED)) == 140


def test_cached_codex_scan_counts_a_copied_rollout_once(tmp_path: Path) -> None:
    started = OBSERVED - 4 * DAY
    rows = [
        _meta("parent", timestamp=_at(started)),
        _tokens(100, 100, _at(started + 60)),
        _tokens(160, 60, _at(started + 120)),
    ]
    root = _codex_rollouts(tmp_path, {"original.jsonl": rows, "copy.jsonl": rows})
    scanned = _scan_codex(tmp_path, root, since_epoch=OBSERVED - 30 * DAY)
    assert scanned.codex_tokens == 160

    assert _card_tokens(subject._cached_codex_local_scan(tmp_path, OBSERVED)) == 160


def test_cached_scan_ignores_records_older_than_thirty_days(tmp_path: Path) -> None:
    old = OBSERVED - 45 * DAY
    recent = OBSERVED - 2 * DAY
    root = _codex_rollouts(
        tmp_path,
        {
            "long.jsonl": [
                _meta("long", timestamp=_at(old - 60)),
                _turn_context("gpt-old-only", old - 30),
                _tokens(100, 100, _at(old)),
                _turn_context("gpt-recent", recent - 30),
                _tokens(150, 50, _at(recent)),
            ]
        },
    )
    # A cache with no floor at all: it holds both records.
    _scan_codex(tmp_path, root, since_epoch=0.0)

    document = subject._cached_codex_local_scan(tmp_path, OBSERVED)

    assert _card_tokens(document) == 50
    assert document is not None
    assert document["model_count"] == 1, "a model seen only 45 days ago was counted"


@pytest.mark.parametrize("graph_days", [7, 30, 365])
def test_a_graph_scan_of_any_range_leaves_the_codex_card_whole(
    tmp_path: Path, graph_days: int
) -> None:
    near = OBSERVED - 5 * DAY
    far = OBSERVED - 20 * DAY
    root = _codex_rollouts(
        tmp_path,
        {
            "near.jsonl": [
                _meta("near", timestamp=_at(near - 60)),
                _tokens(30, 30, _at(near)),
            ],
            "far.jsonl": [
                _meta("far", timestamp=_at(far - 60)),
                _tokens(200, 200, _at(far)),
            ],
        },
    )
    _scan_codex(tmp_path, root, since_epoch=OBSERVED - graph_days * DAY)

    # The default graph range is 7 days; the card is the last 30 whatever
    # range the scan that wrote the cache was asked for.
    assert _card_tokens(subject._cached_codex_local_scan(tmp_path, OBSERVED)) == 230
    # And scanning again must not have changed what the cache covers.
    _scan_codex(tmp_path, root, since_epoch=OBSERVED - graph_days * DAY)

    assert _card_tokens(subject._cached_codex_local_scan(tmp_path, OBSERVED)) == 230


def test_cached_and_cold_provider_scans_agree(tmp_path: Path) -> None:
    started = OBSERVED - 6 * DAY
    inherited = _tokens(100, 100, _at(started))
    root = _codex_rollouts(
        tmp_path,
        {
            "parent.jsonl": [
                _meta("parent", timestamp=_at(started - 60)),
                _turn_context("gpt-shared", started - 30),
                inherited,
            ],
            "child.jsonl": [
                _meta("child", forked_from_id="parent", timestamp=_at(started + 30)),
                _turn_context("gpt-shared", started + 40),
                inherited,
                _tokens(140, 40, _at(started + 120)),
            ],
            "stale.jsonl": [
                _meta("stale", timestamp=_at(OBSERVED - 40 * DAY)),
                _tokens(500, 500, _at(OBSERVED - 40 * DAY + 60)),
            ],
        },
    )
    # Build the cache the way the daemon's 30-day warm-up does.
    _scan_codex(tmp_path, root, since_epoch=OBSERVED - 30 * DAY)

    cached = subject._cached_codex_local_scan(tmp_path, OBSERVED)
    cold = subject._default_provider_local_scan("codex", tmp_path, OBSERVED)

    assert cached is not None and cold is not None
    for key in ("input_tokens", "cached_input_tokens", "output_tokens", "model_count"):
        assert cached[key] == cold[key], key
    assert _card_tokens(cached) == 140


# --- Claude: the reader must find the cache the scan writes -----------------


def _claude_projects(home: Path) -> Path:
    return home / ".claude" / "projects"


def _claude_usage_line(
    message_id: str,
    epoch: float,
    *,
    model: str = "claude-opus-4",
    cache_read: int = 0,
) -> str:
    stamp = time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime(epoch))
    return json.dumps(
        {
            "type": "assistant",
            "sessionId": "session-1",
            "timestamp": stamp,
            "message": {
                "id": message_id,
                "model": model,
                "usage": {
                    "input_tokens": 10,
                    "output_tokens": 5,
                    "cache_read_input_tokens": cache_read,
                    "cache_creation_input_tokens": 0,
                },
            },
        }
    )


def _claude_transcript(root: Path, name: str, lines: list[str]) -> Path:
    target = _write_transcript(root, name, lines)
    os.utime(target, (OBSERVED - DAY, OBSERVED - DAY))
    return target


def _scan_claude(
    home: Path, *, graph_days: int, extras: dict | None = None, now: float = OBSERVED
) -> None:
    provider_homes.scan_usage_all_homes(
        _state_cache(home),
        since_epoch=OBSERVED - graph_days * DAY,
        provider_ids=("claude",),
        env={},
        home=home,
        extras=extras or {},
        scan=functools.partial(usage_stats.scan_usage, now=now),
    )


def _claude_card(home: Path, extras: tuple[str, ...] = ()) -> dict | None:
    return subject._cached_claude_local_scan(home, OBSERVED, extra_homes=extras)


def test_claude_cached_scan_reads_what_scan_usage_wrote(tmp_path: Path) -> None:
    # One message whose usage repeats on three content-block lines, and a
    # second message from 45 days ago.
    repeated = [
        _claude_line("s1", "resumed", OBSERVED - 2 * DAY),
        _claude_line("s1", "resumed", OBSERVED - 2 * DAY),
        _claude_line("s1", "resumed", OBSERVED - 2 * DAY),
    ]
    _claude_transcript(
        _claude_projects(tmp_path),
        "session.jsonl",
        [*repeated, _claude_line("s1", "ancient", OBSERVED - 45 * DAY)],
    )
    cache = _state_cache(tmp_path)
    usage_stats.scan_usage(
        _claude_projects(tmp_path), cache, since_epoch=OBSERVED - 365 * DAY, now=OBSERVED
    )

    document = _claude_card(tmp_path)

    assert document is not None, "the reader looked for a cache the scan never writes"
    assert document["input_tokens"] == 10
    assert document["cached_input_tokens"] == 0
    assert document["output_tokens"] == 5
    assert document["model_count"] == 1


def test_claude_cached_scan_counts_a_resumed_message_once(tmp_path: Path) -> None:
    line = _claude_line("s1", "shared", OBSERVED - 3 * DAY)
    _claude_transcript(_claude_projects(tmp_path), "first.jsonl", [line])
    _claude_transcript(_claude_projects(tmp_path), "resumed.jsonl", [line])
    scanned = usage_stats.scan_usage(
        _claude_projects(tmp_path),
        _state_cache(tmp_path),
        since_epoch=OBSERVED - 30 * DAY,
        now=OBSERVED,
    )

    document = _claude_card(tmp_path)

    assert document is not None
    assert document["input_tokens"] == scanned.input_tokens == 10
    assert document["output_tokens"] == scanned.output_tokens == 5


def test_claude_card_is_whole_after_a_7_day_graph_scan(tmp_path: Path) -> None:
    _claude_transcript(
        _claude_projects(tmp_path),
        "session.jsonl",
        [
            _claude_line("s1", "recent", OBSERVED - 2 * DAY),
            _claude_line("s1", "older", OBSERVED - 20 * DAY),
        ],
    )
    _scan_claude(tmp_path, graph_days=7)

    # The default graph range is 7 days. It narrows what the graph is given,
    # not what the cache covers: the 20-day-old message is still in the card.
    document = _claude_card(tmp_path)

    assert document is not None
    assert document["input_tokens"] == 20
    assert document["output_tokens"] == 10


def test_claude_cached_scan_refuses_a_cache_that_was_not_scanned_far_enough_back(
    tmp_path: Path,
) -> None:
    _claude_transcript(
        _claude_projects(tmp_path),
        "session.jsonl",
        [
            _claude_line("s1", "recent", OBSERVED - 2 * DAY),
            _claude_line("s1", "older", OBSERVED - 20 * DAY),
        ],
    )
    # Written by a scan five days after the moment the card is read for: its
    # days start after that card's window does, so they are not whole for it.
    _scan_claude(tmp_path, graph_days=30, now=OBSERVED + 5 * DAY)

    assert _claude_card(tmp_path) is None

    _scan_claude(tmp_path, graph_days=30)
    document = _claude_card(tmp_path)

    assert document is not None
    assert document["input_tokens"] == 20
    assert document["output_tokens"] == 10


def test_claude_cached_scan_adds_each_extra_home_once(tmp_path: Path) -> None:
    _claude_transcript(
        _claude_projects(tmp_path),
        "primary.jsonl",
        [_claude_line("primary", "p1", OBSERVED - 2 * DAY)],
    )
    extra = tmp_path / "work-claude"
    _claude_transcript(
        extra / "projects",
        "work.jsonl",
        [
            _claude_line("work", "w1", OBSERVED - 3 * DAY),
            _claude_line("work", "w2", OBSERVED - 4 * DAY),
        ],
    )
    link = tmp_path / "primary-link"
    link.symlink_to(tmp_path / ".claude")
    _scan_claude(tmp_path, graph_days=30, extras={"claude": [str(extra)]})

    # The extra home twice and a symlink to the primary one are each still
    # one home.
    document = _claude_card(tmp_path, extras=(str(extra), str(extra), str(link)))

    assert document is not None
    assert document["input_tokens"] == 30
    assert document["output_tokens"] == 15


def test_claude_cached_scan_withholds_the_total_until_an_extra_home_is_scanned(
    tmp_path: Path,
) -> None:
    _claude_transcript(
        _claude_projects(tmp_path),
        "primary.jsonl",
        [_claude_line("primary", "p1", OBSERVED - 2 * DAY)],
    )
    extra = tmp_path / "work-claude"
    _claude_transcript(
        extra / "projects", "work.jsonl", [_claude_line("work", "w1", OBSERVED - 3 * DAY)]
    )
    _scan_claude(tmp_path, graph_days=30)

    # The extra home was added after the last graph scan: its days are not in
    # any cache yet, so the card shows nothing rather than half a total.
    assert _claude_card(tmp_path, extras=(str(extra),)) is None


def test_claude_cached_scan_cost_only_when_every_record_is_priced(tmp_path: Path) -> None:
    _claude_transcript(
        _claude_projects(tmp_path),
        "priced.jsonl",
        [_claude_usage_line("m1", OBSERVED - 2 * DAY, cache_read=40)],
    )
    _scan_claude(tmp_path, graph_days=30)

    priced = _claude_card(tmp_path)

    assert priced is not None
    assert priced["input_tokens"] == 10
    assert priced["cached_input_tokens"] == 40
    assert isinstance(priced["estimated_cost_usd"], float)
    assert priced["estimated_cost_usd"] > 0
    assert isinstance(priced["cache_savings_usd"], float)
    assert priced["cache_savings_usd"] > 0

    # One record on a model with no price makes the total a floor: tokens
    # still show, the dollar figure does not.
    _claude_transcript(
        _claude_projects(tmp_path),
        "priced.jsonl",
        [
            _claude_usage_line("m1", OBSERVED - 2 * DAY, cache_read=40),
            _claude_usage_line("m2", OBSERVED - 3 * DAY, model="no-such-model-x"),
        ],
    )
    _scan_claude(tmp_path, graph_days=30)

    partial = _claude_card(tmp_path)

    assert partial is not None
    assert partial["input_tokens"] == 20
    assert partial["estimated_cost_usd"] is None
    assert partial["cache_savings_usd"] is None


def test_claude_cached_scan_reuses_result_while_cache_is_unchanged(
    tmp_path: Path, monkeypatch: pytest.MonkeyPatch
) -> None:
    _claude_transcript(
        _claude_projects(tmp_path),
        "session.jsonl",
        [_claude_line("s1", "m1", OBSERVED - 2 * DAY)],
    )
    _scan_claude(tmp_path, graph_days=30)
    loads: list[Path] = []
    real_load = usage_stats._load_cache

    def counting_load(cache_path, source_key=None):
        loads.append(cache_path)
        return real_load(cache_path, source_key)

    monkeypatch.setattr(usage_stats, "_load_cache", counting_load)

    first = _claude_card(tmp_path)
    second = _claude_card(tmp_path)

    assert first is not None and first == second
    assert len(loads) == 1

    _claude_transcript(
        _claude_projects(tmp_path),
        "session.jsonl",
        [
            _claude_line("s1", "m1", OBSERVED - 2 * DAY),
            _claude_line("s1", "m2", OBSERVED - 3 * DAY),
        ],
    )
    _scan_claude(tmp_path, graph_days=30)  # the scan loads the cache too
    loads.clear()
    third = _claude_card(tmp_path)

    assert len(loads) == 1, "a rewritten cache was not reloaded"
    assert third is not None and third["input_tokens"] == 20


def test_claude_quota_path_never_walks_the_transcripts(
    tmp_path: Path, monkeypatch: pytest.MonkeyPatch
) -> None:
    _claude_transcript(
        _claude_projects(tmp_path),
        "session.jsonl",
        [_claude_line("s1", "m1", OBSERVED - 2 * DAY)],
    )
    _scan_claude(tmp_path, graph_days=30)

    def refuse(*_args, **_kwargs):
        raise AssertionError("the quota path walked the transcripts")

    monkeypatch.setattr(usage_stats, "_provider_inventory", refuse)
    monkeypatch.setattr(subject, "_default_provider_local_scan", refuse)

    document = subject._default_claude_local_scan(tmp_path, OBSERVED)

    assert document is not None and document["input_tokens"] == 10


def test_cached_codex_scan_keeps_its_quota_windows_and_their_age(tmp_path: Path) -> None:
    started = OBSERVED - 2 * DAY
    event = _tokens(100, 100, _at(started + 60))
    event["payload"]["rate_limits"] = {
        "primary": {
            "used_percent": 40.0,
            "window_minutes": 300,
            "resets_at": started + 3600,
        }
    }
    root = _codex_rollouts(
        tmp_path, {"limits.jsonl": [_meta("limits", timestamp=_at(started)), event]}
    )
    rollout = root / "limits.jsonl"
    os.utime(rollout, (OBSERVED - 3600, OBSERVED - 3600))
    _scan_codex(tmp_path, root, since_epoch=OBSERVED - 30 * DAY)

    document = subject._cached_codex_local_scan(tmp_path, OBSERVED)

    assert document is not None
    assert document["windows_observed_at"] == OBSERVED - 3600
    windows = document["windows"]
    assert isinstance(windows, list) and len(windows) == 1
    assert windows[0]["label"] == "primary"
    assert windows[0]["used_percent"] == 40.0
    assert _card_tokens(document) == 100


def test_cached_codex_scan_adds_an_extra_home_but_keeps_the_primary_quota(
    tmp_path: Path,
) -> None:
    started = OBSERVED - 3 * DAY
    primary_root = _codex_rollouts(
        tmp_path,
        {
            "primary.jsonl": [
                _meta("primary", timestamp=_at(started)),
                _tokens(100, 100, _at(started + 60)),
            ]
        },
    )
    extra_home = tmp_path / "second-codex"
    _write(
        extra_home / "sessions" / "second.jsonl",
        [
            _meta("second", timestamp=_at(started)),
            _tokens(70, 70, _at(started + 60)),
        ],
    )
    os.utime(extra_home / "sessions" / "second.jsonl", (OBSERVED - DAY, OBSERVED - DAY))
    _scan_codex(tmp_path, primary_root, since_epoch=OBSERVED - 30 * DAY)
    provider_homes.scan_usage_all_homes(
        _state_cache(tmp_path),
        since_epoch=OBSERVED - 30 * DAY,
        provider_ids=("codex",),
        env={},
        home=tmp_path,
        extras={"codex": [str(extra_home)]},
        scan=functools.partial(usage_stats.scan_usage, now=OBSERVED),
    )

    alone = subject._cached_provider_local_scan(
        "codex", tmp_path, OBSERVED, extra_homes=()
    )
    both = subject._cached_provider_local_scan(
        "codex", tmp_path, OBSERVED, extra_homes=(str(extra_home),)
    )

    assert _card_tokens(alone) == 100
    assert _card_tokens(both) == 170


def test_claude_cached_scan_remembers_a_refusal_while_the_cache_is_unchanged(
    tmp_path: Path, monkeypatch: pytest.MonkeyPatch
) -> None:
    _claude_transcript(
        _claude_projects(tmp_path),
        "session.jsonl",
        [
            _claude_line("s1", "recent", OBSERVED - 2 * DAY),
            _claude_line("s1", "older", OBSERVED - 20 * DAY),
        ],
    )
    # A cache whose days start after the card's window does: the card refuses.
    _scan_claude(tmp_path, graph_days=30, now=OBSERVED + 5 * DAY)
    loads: list[Path] = []
    decodes: list[int] = []
    real_load = usage_stats._load_cache
    real_card_days = usage_stats.cache_card_days

    def counting_load(cache_path, source_key=None):
        if cache_path.exists():  # a cache file that was never written costs one lstat
            loads.append(cache_path)
        return real_load(cache_path, source_key)

    def counting_card_days(*args, **kwargs):
        decodes.append(1)
        return real_card_days(*args, **kwargs)

    monkeypatch.setattr(usage_stats, "_load_cache", counting_load)
    monkeypatch.setattr(usage_stats, "cache_card_days", counting_card_days)

    assert _claude_card(tmp_path) is None
    loaded_once, decoded_once = len(loads), len(decodes)
    assert loaded_once >= 1 and decoded_once >= 1, "the first refusal does the work"

    # Every later quota refresh answers from what it already worked out.
    assert _claude_card(tmp_path) is None
    assert _claude_card(tmp_path) is None
    assert len(loads) == loaded_once, "a remembered refusal reloaded the cache"
    assert len(decodes) == decoded_once, "a remembered refusal read the cache's days again"

    # A wider scan rewrites the cache: the refusal must not outlive it.
    _scan_claude(tmp_path, graph_days=30)
    document = _claude_card(tmp_path)

    assert document is not None
    assert document["input_tokens"] == 20


def _extra_homes_cannot_be_listed(monkeypatch: pytest.MonkeyPatch) -> None:
    def broken(*_args, **_kwargs):
        raise RuntimeError("the extra homes could not be resolved")

    monkeypatch.setattr(provider_homes, "extra_scan_roots", broken)


def test_claude_cached_scan_withholds_the_total_when_extra_homes_cannot_be_listed(
    tmp_path: Path, monkeypatch: pytest.MonkeyPatch, capsys: pytest.CaptureFixture[str]
) -> None:
    _claude_transcript(
        _claude_projects(tmp_path),
        "primary.jsonl",
        [_claude_line("primary", "p1", OBSERVED - 2 * DAY)],
    )
    _scan_claude(tmp_path, graph_days=30)
    assert _claude_card(tmp_path) is not None, "the fixture must start with a real total"
    capsys.readouterr()

    _extra_homes_cannot_be_listed(monkeypatch)

    # The primary home alone is half a total: the card shows nothing, and the
    # daemon's log says why, once however many refreshes ask.
    assert _claude_card(tmp_path) is None
    assert _claude_card(tmp_path) is None
    lines = [line for line in capsys.readouterr().err.splitlines() if line.strip()]
    assert len(lines) == 1, lines
    assert "claude" in lines[0]
    assert str(tmp_path) not in lines[0], "the log line named a personal path"

    monkeypatch.undo()
    recovered = _claude_card(tmp_path)

    assert recovered is not None and recovered["input_tokens"] == 10


def test_codex_cached_scan_keeps_the_primary_home_when_extra_homes_cannot_be_listed(
    tmp_path: Path, monkeypatch: pytest.MonkeyPatch, capsys: pytest.CaptureFixture[str]
) -> None:
    started = OBSERVED - 3 * DAY
    root = _codex_rollouts(
        tmp_path,
        {
            "primary.jsonl": [
                _meta("primary", timestamp=_at(started)),
                _tokens(100, 100, _at(started + 60)),
            ]
        },
    )
    _scan_codex(tmp_path, root, since_epoch=OBSERVED - 30 * DAY)
    _extra_homes_cannot_be_listed(monkeypatch)

    first = subject._cached_provider_local_scan("codex", tmp_path, OBSERVED)
    second = subject._cached_provider_local_scan("codex", tmp_path, OBSERVED)

    # Codex documents "the primary home plus whatever the cache covers".
    assert _card_tokens(first) == 100
    assert first == second
    lines = [line for line in capsys.readouterr().err.splitlines() if line.strip()]
    assert len(lines) == 1, lines
    assert "codex" in lines[0]


# --- Codex: one start for every home ----------------------------------------


def _codex_source_key():
    return next(
        row.source_key
        for row in usage_stats.negotiated_provider_sources()
        if row.source_key.provider_id == "codex"
        and row.source_key.capability_id == "transcript_usage"
    )


def _codex_days_start_at(cache_path: Path) -> float:
    source_key = _codex_source_key()
    loaded = usage_stats._load_cache(cache_path, source_key)
    card = usage_stats.cache_card_days(loaded, "codex")
    assert card is not None, "the fixture must leave a readable cache"
    return card.since


@pytest.mark.parametrize("narrower_home", ["primary", "extra"])
def test_cached_codex_scan_counts_from_the_latest_start_across_homes(
    tmp_path: Path, narrower_home: str
) -> None:
    near = OBSERVED - 5 * DAY
    far = OBSERVED - 28 * DAY
    primary_root = _codex_rollouts(
        tmp_path,
        {
            "primary-near.jsonl": [
                _meta("primary-near", timestamp=_at(near - 60)),
                _tokens(30, 30, _at(near)),
            ],
            "primary-far.jsonl": [
                _meta("primary-far", timestamp=_at(far - 60)),
                _tokens(200, 200, _at(far)),
            ],
        },
    )
    extra_home = tmp_path / "second-codex"
    for name, session, total, moment in (
        ("extra-near.jsonl", "extra-near", 70, near),
        ("extra-far.jsonl", "extra-far", 500, far),
    ):
        rollout = extra_home / "sessions" / name
        _write(rollout, [_meta(session, timestamp=_at(moment - 60)), _tokens(total, total, _at(moment))])
        os.utime(rollout, (OBSERVED - DAY, OBSERVED - DAY))
    [extra_root] = provider_homes.extra_scan_roots(
        "codex", env={}, home=tmp_path, extras=[str(extra_home)]
    )
    # One home was last scanned ten days after the moment the card is read
    # for, so its days start 19 days back and do not hold the 28-day-old turn;
    # the other home's days start 29 days back and do.
    late = OBSERVED + 10 * DAY
    _scan_codex(
        tmp_path, primary_root, since_epoch=OBSERVED - 30 * DAY,
        now=late if narrower_home == "primary" else OBSERVED,
    )
    usage_stats.scan_usage(
        tmp_path / ".jrbar-no-such-home",
        provider_homes._home_cache_path(_state_cache(tmp_path), extra_root),
        codex_root=extra_root,
        since_epoch=OBSERVED - 30 * DAY,
        provider_ids=("codex",),
        now=late if narrower_home == "extra" else OBSERVED,
    )
    source_key = _codex_source_key()
    primary_start = _codex_days_start_at(
        usage_stats.provider_cache_path(_state_cache(tmp_path), source_key)
    )
    extra_start = _codex_days_start_at(
        usage_stats.provider_cache_path(
            provider_homes._home_cache_path(_state_cache(tmp_path), extra_root), source_key
        )
    )
    wide, narrow = sorted((primary_start, extra_start))
    assert wide <= far < narrow < near, "the homes must disagree about 30 days"

    card = subject._cached_provider_local_scan(
        "codex", tmp_path, OBSERVED, extra_homes=(str(extra_home),)
    )

    # Only the later start is vouched for by every home: the wide home's
    # 28-day-old turn is not counted, or one home would be counted for more
    # days than the other.
    assert _card_tokens(card) == 30 + 70
