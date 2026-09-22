"""The jrbar-rates-v3 price table (usage_stats.py MODEL_PRICING /
GPT_MODEL_PRICING / GEMINI_MODEL_PRICING + CACHE_READ_RATE_OVERRIDES),
pinned row by row so a marker reorder or a rate typo fails loudly.
Rates checked 2026-09-20; do not relax a pin without re-checking the
provider's pricing page."""

from __future__ import annotations

import dataclasses
import json
from datetime import datetime
from pathlib import Path

import pytest

from jrbar import core_usage_history as history
from jrbar import usage_stats

NOW = datetime(2026, 9, 20, 12, 0, 0)


def _record(provider: str, model: str, when: datetime, *, inp=1000, cached=500, create=200, out=300, dedupe="d"):
    return (provider, "session", model, when.timestamp(), inp, cached, create, out, dedupe)


@pytest.mark.parametrize(
    ("provider", "model", "input_rate", "output_rate", "cache_read"),
    (
        # Anthropic: Fable 5.1 reads cache at 0.025x ($0.25), every other
        # Claude model at 0.1x of its own input rate.
        ("claude", "claude-fable-5-1-20260901", 10.0, 50.0, 0.25),
        ("claude", "claude-fable-5", 10.0, 50.0, 1.0),
        ("claude", "claude-opus-5", 5.0, 25.0, 0.5),
        ("claude", "claude-opus-4-7", 5.0, 25.0, 0.5),
        ("claude", "claude-opus-4-1", 15.0, 75.0, 1.5),
        ("claude", "claude-opus-4-20250514", 15.0, 75.0, 1.5),
        ("claude", "claude-sonnet-5", 2.0, 10.0, 0.2),
        ("claude", "claude-sonnet-4-6", 3.0, 15.0, 0.3),
        ("claude", "claude-haiku-4-5", 1.0, 5.0, 0.1),
        ("claude", "claude-3-5-haiku", 0.8, 4.0, 0.08),
        # OpenAI: cache reads at 0.1x input.
        ("codex", "gpt-6-astra", 10.0, 50.0, 1.0),
        ("codex", "gpt-5.6-sol", 4.0, 20.0, 0.4),
        ("codex", "gpt-5.4-mini", 0.75, 4.5, 0.075),
        # Gemini.
        ("gemini", "gemini-3.1-pro-preview", 2.0, 12.0, 0.2),
        ("gemini", "gemini-3.8-flash", 0.75, 3.75, 0.075),
        ("gemini", "gemini-3-flash-preview", 0.5, 3.0, 0.05),
        ("gemini", "gemini-3.1-flash-lite", 0.25, 1.5, 0.025),
    ),
)
def test_table_row_prices_exactly(provider, model, input_rate, output_rate, cache_read) -> None:
    quote = history.price_quote(provider, model)
    assert quote is not None
    assert quote.source == history.QUOTE_TABLE
    assert quote.estimated is False
    assert quote.input_per_mtok == input_rate
    assert quote.output_per_mtok == output_rate
    assert quote.cache_read_per_mtok == pytest.approx(cache_read)
    payload = quote.to_dict()
    # A record priced from its own row is a list price, not an approximation.
    assert payload["approximate"] is False
    assert payload["table_version"] == usage_stats.PRICING_TABLE_VERSION
    assert payload["as_of"] == usage_stats.PRICING_TABLE_AS_OF


def test_codex_record_with_a_named_model_prices_from_the_table() -> None:
    """A codex transcript that names its model (``gpt-6-astra``) prices
    from that row directly -- source ``table``, not the configured
    default and not the reference stand-in."""
    document = history.usage_history_document(
        [_record("codex", "gpt-6-astra", NOW, inp=100_000, cached=10_000, create=0, out=10_000, dedupe="k")],
        provider="codex",
        range_name="7d",
        now=NOW.timestamp(),
        codex_default_model="gpt-5.6-sol",
    )
    pricing = document["pricing"]
    assert pricing["model"] == "gpt-6-astra"
    assert pricing["source"] == "table"
    assert pricing["estimated"] is False and pricing["approximate"] is False
    assert pricing["input_per_mtok"] == 10.0 and pricing["output_per_mtok"] == 50.0
    assert pricing["cache_read_per_mtok"] == pytest.approx(1.0)
    expected = (100_000 * 10.0 + 10_000 * 1.0 + 10_000 * 50.0) / 1e6
    assert document["days"][-1]["cost_usd"] == pytest.approx(expected, abs=1e-4)
    assert document["estimated"] is False


def test_table_version_and_as_of_reach_the_coverage_metrics_and_document(tmp_path: Path) -> None:
    """Both stamps round-trip: ``PricingCoverageMetrics`` on the scan and
    the ``pricing`` block of the ``usage_history`` document."""
    root = tmp_path / "claude"
    (root / "project").mkdir(parents=True)
    (root / "project" / "s.jsonl").write_text(
        json.dumps(
            {
                "type": "assistant",
                "timestamp": "2026-09-19T12:00:00Z",
                "message": {
                    "id": "m1",
                    "model": "claude-sonnet-5",
                    "usage": {"input_tokens": 7, "cache_read_input_tokens": 0,
                              "cache_creation_input_tokens": 0, "output_tokens": 3},
                },
            }
        )
        + "\n"
    )
    totals = usage_stats.scan_usage(root, None)
    metrics = totals.pricing_coverage
    assert metrics.table_version == usage_stats.PRICING_TABLE_VERSION == "jrbar-rates-v3"
    assert metrics.table_as_of == usage_stats.PRICING_TABLE_AS_OF == "2026-09-20"

    document = history.usage_history_document(
        [_record("claude", "claude-sonnet-5", NOW, dedupe="v")],
        provider="claude",
        range_name="7d",
        now=NOW.timestamp(),
    )
    assert document["pricing"]["table_version"] == "jrbar-rates-v3"
    assert document["pricing"]["as_of"] == "2026-09-20"


def test_usage_cache_written_under_an_older_table_goes_cold(tmp_path: Path) -> None:
    """A scan cache stamped for another pricing semantics version is
    refused: the next scan reparses and rewrites under the current
    table (A5 -- table_version changes invalidate the usage cache)."""
    root = tmp_path / "claude"
    (root / "project").mkdir(parents=True)
    (root / "project" / "s.jsonl").write_text(
        json.dumps(
            {
                "type": "assistant",
                "timestamp": "2026-09-19T12:00:00Z",
                "message": {
                    "id": "m1",
                    "model": "claude-sonnet-5",
                    "usage": {"input_tokens": 7, "cache_read_input_tokens": 0,
                              "cache_creation_input_tokens": 0, "output_tokens": 3},
                },
            }
        )
        + "\n"
    )
    cache = tmp_path / "state" / "usage-scan-cache.json"
    totals = usage_stats.scan_usage(root, cache)
    assert totals.input_tokens == 7 and cache.exists()

    payload = json.loads(cache.read_text())
    assert payload["pricing_semantics_version"] == "jrbar-rates-v3"
    assert usage_stats._load_cache(cache)  # warm: the fresh cache loads

    # A cache written under the previous table (no stamp, or an old one)
    # is refused rather than recosted under new semantics.
    for stale in ("jrbar-rates-v2", None):
        tampered = dict(payload)
        if stale is None:
            tampered.pop("pricing_semantics_version", None)
        else:
            tampered["pricing_semantics_version"] = stale
        cache.write_text(json.dumps(tampered))
        assert usage_stats._load_cache(cache) == {}
        rescan = usage_stats.scan_usage(root, cache)
        assert rescan.input_tokens == 7
        rewritten = json.loads(cache.read_text())
        assert rewritten["pricing_semantics_version"] == "jrbar-rates-v3"

    # The result-level guard agrees: a priced result stamped for an
    # older table cannot validate, so callers must rescan.
    from jrbar.provider_contracts import CapabilityIdentifier
    from jrbar.providers import negotiated_provider_sources

    source = next(
        row
        for row in negotiated_provider_sources()
        if row.source_key.provider_id == "claude"
        and row.declared_capability_id == CapabilityIdentifier("transcript_usage")
        and row.observation_invocation_allowed
    )
    result, _ = usage_stats._scan_provider_usage_with_totals(source, root, None, since_epoch=0.0)
    assert result.pricing_as_of == "2026-09-20"
    with pytest.raises(ValueError):
        dataclasses.replace(result, pricing_as_of="2026-08-26")


def test_fable_5_1_records_bill_their_own_cache_rate(tmp_path: Path) -> None:
    """The override is not dead code: a fable-5-1 transcript reads cache
    at 0.025x, not the flat 0.1x the shared ``fable`` marker would pay."""
    root = tmp_path / "claude"
    (root / "project").mkdir(parents=True)
    (root / "project" / "s.jsonl").write_text(
        json.dumps(
            {
                "type": "assistant",
                "timestamp": "2026-09-19T12:00:00Z",
                "message": {
                    "id": "m1",
                    "model": "claude-fable-5-1-20260901",
                    "usage": {"input_tokens": 1_000_000, "cache_read_input_tokens": 1_000_000,
                              "cache_creation_input_tokens": 0, "output_tokens": 0},
                },
            }
        )
        + "\n"
    )
    totals = usage_stats.scan_usage(root, None)
    # 1M input at $10 + 1M cache reads at $0.25.
    assert totals.estimated_cost_usd == pytest.approx(10.25)
    # Savings: the cached MTok would have cost $10, paid $0.25.
    assert totals.estimated_cache_savings_usd == pytest.approx(9.75)
