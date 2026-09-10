"""``usage_history`` bucketing (core_usage_history.py)."""

from __future__ import annotations

from datetime import datetime, timedelta

import pytest

from jrbar import core_usage_history as history
from jrbar import usage_stats

NOW = datetime(2026, 9, 9, 21, 30, 0)


def _record(provider: str, model: str, when: datetime, *, inp=1000, cached=500, create=200, out=300, dedupe="d"):
    return (provider, "session", model, when.timestamp(), inp, cached, create, out, dedupe)


def test_days_and_hours_cover_the_range_and_dedupe_records() -> None:
    hour_ago = NOW - timedelta(hours=1)
    records = [
        _record("claude", "fable", hour_ago, dedupe="a"),
        _record("claude", "fable", hour_ago, dedupe="a"),  # duplicate
        _record("claude", "sonnet", NOW - timedelta(days=2), inp=10, cached=0, create=0, out=5, dedupe="b"),
        _record("claude", "fable", NOW - timedelta(days=40), dedupe="old"),
        _record("codex", "gpt-5.6-sol", hour_ago, dedupe="c"),
        ("broken",),
    ]
    document = history.usage_history_document(records, provider="claude", range_name="7d", now=NOW.timestamp())
    assert document["provider"] == "claude" and document["range"] == "7d"
    assert [row["date"] for row in document["days"]] == [
        (NOW - timedelta(days=offset)).date().isoformat() for offset in range(6, -1, -1)
    ]
    assert len(document["hours"]) == history.HOURS_SHOWN
    assert document["hours"][-1]["hour"] == NOW.strftime("%Y-%m-%dT%H:00")
    today = document["days"][-1]
    assert (today["tokens_in"], today["tokens_out"], today["cache_read"]) == (1200, 300, 500)
    expected = (1000 * 10.0 + 500 * 1.0 + 200 * 12.5 + 300 * 50.0) / 1_000_000
    assert today["cost_usd"] == pytest.approx(expected, abs=1e-4)
    two_days = document["days"][-3]
    assert two_days["tokens_in"] == 10 and two_days["cost_usd"] == pytest.approx((10 * 3.0 + 5 * 15.0) / 1e6, abs=1e-4)
    last_hour = next(row for row in document["hours"] if row["hour"] == hour_ago.strftime("%Y-%m-%dT%H:00"))
    assert last_hour["tokens_in"] == 1200 and last_hour["at"] == hour_ago.replace(minute=0, second=0).timestamp()
    assert document["records"] == 2
    assert document["pricing"] == {
        "input_per_mtok": 10.0,
        "output_per_mtok": 50.0,
        "cache_read_per_mtok": 1.0,
        "as_of": usage_stats.PRICING_TABLE_AS_OF,
        "approximate": True,
        "currency": "USD",
        "model": "fable",
    }


def test_codex_costs_bill_cache_writes_at_the_input_rate() -> None:
    document = history.usage_history_document(
        [_record("codex", "gpt-5.6-sol", NOW, inp=100, cached=100, create=100, out=100, dedupe="x")],
        provider="codex", range_name="30d", now=NOW.timestamp(), account={"plan": "Plus"}, state="ready",
    )
    assert len(document["days"]) == 30
    assert document["days"][-1]["cost_usd"] == pytest.approx((100 * 4.0 + 100 * 0.4 + 100 * 4.0 + 100 * 20.0) / 1e6, abs=1e-4)
    assert document["account"] == {"plan": "Plus"} and document["state"] == "ready"
    assert document["pricing"]["cache_read_per_mtok"] == pytest.approx(0.4)


def test_unknown_models_and_ranges() -> None:
    document = history.usage_history_document(
        [_record("claude", "unknown", NOW, dedupe="u")], provider="claude", range_name="90d", now=NOW.timestamp()
    )
    assert document["days"][-1]["cost_usd"] == 0.0 and document["pricing"] is None
    with pytest.raises(ValueError):
        history.usage_history_document([], provider="claude", range_name="2d")
    assert history.range_days("365d") == 365 and history.range_days(7) is None
    assert history.scan_provider_records("grok", days=7) == []
