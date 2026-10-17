"""A pass over many records reads the price tables once per model.

A month of transcripts is a hundred thousand records and a handful of models.
Looking the rates up per record cost more than reading the files, so each pass
asks once per model and the answer is the same number it always was.
"""

from __future__ import annotations

from datetime import datetime, timedelta

import pytest

from jrbar import core_usage_history as history
from jrbar import model_pricing, usage_stats

NOW = datetime(2026, 9, 9, 21, 30, 0)


def _records(count: int, *, provider: str = "claude") -> list[tuple]:
    models = ("fable", "sonnet", "mystery-model")
    return [
        (
            provider,
            f"session-{index % 7}",
            models[index % len(models)],
            (NOW - timedelta(hours=index % 40)).timestamp(),
            100 + index,
            50,
            20,
            10 + index,
            f"dedupe-{index}",
        )
        for index in range(count)
    ]


@pytest.fixture
def override_lookups(monkeypatch: pytest.MonkeyPatch) -> list[str]:
    calls: list[str] = []
    real = model_pricing.override_for

    def counting(model: str):
        calls.append(model)
        return real(model)

    monkeypatch.setattr(model_pricing, "override_for", counting)
    return calls


def _lookups_for(count: int, run, calls: list[str]) -> int:
    calls.clear()
    run(_records(count))
    return len(calls)


def test_the_scan_totals_read_the_tables_once_per_model(override_lookups: list[str]) -> None:
    def run(records: list[tuple]) -> None:
        usage_stats._totals_from_window(records)

    few = _lookups_for(30, run, override_lookups)
    many = _lookups_for(3000, run, override_lookups)

    assert few == many
    assert many <= 3 * 4


def test_the_history_document_reads_the_tables_once_per_model(override_lookups: list[str]) -> None:
    def run(records: list[tuple]) -> None:
        history.usage_history_document(records, provider="claude", range_name="7d", now=NOW.timestamp())

    few = _lookups_for(30, run, override_lookups)
    many = _lookups_for(3000, run, override_lookups)

    assert few == many


def test_the_daily_buckets_read_the_tables_once_per_model(override_lookups: list[str]) -> None:
    def run(records: list[tuple]) -> None:
        usage_stats.daily_buckets(records, days=7, now=NOW)

    few = _lookups_for(30, run, override_lookups)
    many = _lookups_for(3000, run, override_lookups)

    assert few == many


def test_the_money_is_what_pricing_each_record_alone_gives() -> None:
    records = _records(120)
    totals = usage_stats._totals_from_window(records)

    expected_cost = 0.0
    expected_savings = 0.0
    priced = 0
    for _provider, _session, model, _epoch, inp, cached, create, out, _dedupe in records:
        amounts = usage_stats._model_amounts(model, inp, cached, create, out)
        if amounts is None:
            continue
        priced += 1
        expected_cost += amounts[0]
        expected_savings += amounts[1]

    assert totals.pricing_coverage.priced_records == priced
    assert totals.estimated_cost_usd == expected_cost
    assert totals.estimated_cache_savings_usd == expected_savings


def test_a_quote_priced_with_a_known_write_rate_costs_the_same() -> None:
    quote = history.price_quote("claude", "sonnet")
    assert quote is not None
    write_rate = history.quote_write_rate("claude", quote)

    assert history.quote_cost("claude", quote, 1000, 500, 200, 300, write_rate=write_rate) == history.quote_cost(
        "claude", quote, 1000, 500, 200, 300
    )
