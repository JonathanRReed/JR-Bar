"""The quota refresh's token totals come from the scan cache, and must agree
with the scan that wrote it.

Every test here builds a real cache with ``usage_stats.scan_usage`` and reads
it back through the provider cards' cached readers. Nothing patches
``_load_cache``. Clocks are passed in as ``OBSERVED``; nothing sleeps.
"""

from __future__ import annotations

import json
import os
import time
from pathlib import Path

import pytest

import jrbar.provider_usage_codex_claude as subject
from jrbar import usage_stats
from jrbar.state_paths import default_state_dir
from tests.test_codex_usage_lineage import _meta, _tokens, _write

DAY = 24 * 60 * 60
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


def _scan_codex(home: Path, root: Path, *, since_epoch: float) -> usage_stats.UsageTotals:
    return usage_stats.scan_usage(
        home / ".claude" / "projects",
        _state_cache(home),
        codex_root=root,
        since_epoch=since_epoch,
        provider_ids=("codex",),
    )


def _card_tokens(document: dict | None) -> int:
    assert document is not None
    return (
        int(document["input_tokens"])
        + int(document["cached_input_tokens"])
        + int(document["output_tokens"])
    )


def _cache_floor(home: Path, provider_id: str) -> float:
    source = next(
        row
        for row in usage_stats.negotiated_provider_sources()
        if row.source_key.provider_id == provider_id
        and row.source_key.capability_id == "transcript_usage"
    )
    path = usage_stats._secondary_provider_cache_path(_state_cache(home), source.source_key)
    payload = json.loads(path.read_text(encoding="utf-8"))
    return max(float(entry["since"]) for entry in payload["files"].values())


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
def test_cached_scan_never_reports_more_than_the_cache_covers(
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

    start = max(OBSERVED - 30 * DAY, _cache_floor(tmp_path, "codex"))
    expected = _scan_codex(tmp_path, root, since_epoch=start).codex_tokens
    if graph_days == 7:
        # The default graph range keeps about ten days: the card counts only
        # what that cache still holds and never claims thirty days of it.
        assert expected == 30
    else:
        assert expected == 230
    # Reading back must not have changed what the cache covers.
    _scan_codex(tmp_path, root, since_epoch=OBSERVED - graph_days * DAY)

    assert _card_tokens(subject._cached_codex_local_scan(tmp_path, OBSERVED)) == expected


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
