"""List prices checked on 2026-11-14 against the providers' public pages.

Claude Fable 5.2 and Mythos 5.2 are $8/$40 with cache reads at $0.20, Sonnet
5.5 reads cache at $0.10, Haiku 5.5 is $0.10/$0.50 up to a 100,000-token
prompt and five times that over it, and GPT-6.1 Terra is $1/$5 with cached
input at $0.05. A model that only looks like a newer one keeps its own price.
Synthetic records only.
"""

from __future__ import annotations

from datetime import datetime

import pytest

from jrbar import core_usage_history as history
from jrbar import usage_stats

NOW = datetime(2026, 11, 14, 12, 0, 0)


@pytest.mark.parametrize(
    ("provider", "model", "input_rate", "output_rate", "cache_read"),
    (
        ("claude", "claude-fable-5-2", 8.0, 40.0, 0.20),
        ("claude", "claude-fable-5.2", 8.0, 40.0, 0.20),
        ("claude", "claude-fable-5-2-20261101", 8.0, 40.0, 0.20),
        ("claude", "claude-mythos-5-2", 8.0, 40.0, 0.20),
        ("claude", "claude-fable-5-1", 10.0, 50.0, 0.25),
        ("claude", "claude-fable-5", 10.0, 50.0, 1.0),
        # A dated Fable 5, not Fable 5.2: the date begins with a 2.
        ("claude", "claude-fable-5-20260115", 10.0, 50.0, 1.0),
        ("claude", "claude-opus-5-5", 4.0, 20.0, 0.20),
        ("claude", "claude-opus-5", 5.0, 25.0, 0.50),
        ("claude", "claude-opus-4-20250514", 15.0, 75.0, 1.50),
        ("claude", "claude-opus-4-5-20251101", 5.0, 25.0, 0.50),
        ("claude", "claude-sonnet-5-5", 2.0, 10.0, 0.10),
        ("claude", "claude-sonnet-5.5", 2.0, 10.0, 0.10),
        ("claude", "claude-sonnet-5", 2.0, 10.0, 0.20),
        ("claude", "claude-haiku-5-5", 0.10, 0.50, 0.01),
        ("claude", "claude-haiku-5.5", 0.10, 0.50, 0.01),
        ("claude", "claude-haiku-4-5-20251001", 1.0, 5.0, 0.10),
        ("claude", "claude-3-5-haiku-20241022", 0.80, 4.0, 0.08),
        ("codex", "gpt-6.1-terra", 1.0, 5.0, 0.05),
        ("codex", "gpt-6.1-sol", 2.0, 10.0, 0.10),
        ("codex", "gpt-6-sol", 2.0, 10.0, 0.20),
        ("codex", "gpt-6-astra", 10.0, 50.0, 1.0),
        ("codex", "gpt-6-luna", 0.10, 0.50, 0.01),
        ("codex", "gpt-5.6-terra", 2.0, 12.0, 0.20),
    ),
)
def test_each_model_quotes_its_published_rates(provider, model, input_rate, output_rate, cache_read) -> None:
    quote = history.price_quote(provider, model)
    assert quote is not None
    assert quote.input_per_mtok == pytest.approx(input_rate)
    assert quote.output_per_mtok == pytest.approx(output_rate)
    assert quote.cache_read_per_mtok == pytest.approx(cache_read)


@pytest.mark.parametrize(
    ("marker", "model", "expected"),
    (
        ("fable-5-2", "claude-fable-5-2", True),
        ("fable-5-2", "claude-fable-5-2-20261101", True),
        ("fable-5-2", "claude-fable-5-2|1h", True),
        ("fable-5-2", "claude-fable-5-20260115", False),
        ("fable-5-2", "claude-fable-5-25", False),
        ("opus-4", "claude-opus-4-1-20250805", True),
        ("opus-4", "claude-opus-4.1", True),
        ("gpt-5", "gpt-5.2-codex", True),
        ("gpt-5", "gpt-50", False),
        ("3-5-haiku", "claude-3-5-haiku-20241022", True),
        ("haiku", "claude-haiku-5-5", True),
    ),
)
def test_a_marker_ending_in_a_digit_ends_the_number_it_names(marker, model, expected) -> None:
    assert usage_stats.price_marker_matches(marker, model) is expected


def test_haiku_5_5_reprices_a_whole_request_over_a_100k_prompt() -> None:
    assert usage_stats.is_long_context_request("claude", "claude-haiku-5-5", 100_000) is False
    assert usage_stats.is_long_context_request("claude", "claude-haiku-5-5", 100_001) is True
    assert usage_stats.is_long_context_request("claude", "claude-haiku-4-5", 500_000) is False
    assert usage_stats.long_context_multipliers("claude-haiku-5-5") == (5.0, 5.0)
    assert usage_stats.long_context_multipliers("gpt-6.1-sol") == (2.0, 1.5)

    quote = history.price_quote("claude", "claude-haiku-5-5")
    # 100,000 prompt tokens and a million out: $0.01 + $0.50.
    assert history.quote_cost("claude", quote, 100_000, 0, 0, 1_000_000) == pytest.approx(0.51)
    # Over the line: $0.50 input, $0.05 cache reads, $2.50 output per million.
    assert history.quote_cost(
        "claude", quote, 1_000_000, 1_000_000, 0, 1_000_000, long_context=True
    ) == pytest.approx(3.05)


def test_a_days_cost_uses_the_tier_each_request_fell_in() -> None:
    def record(prompt: int, name: str):
        return ("claude", "session", "claude-haiku-5-5", NOW.timestamp(), prompt, 0, 0, 100_000, name)

    def cost(*records) -> float:
        buckets = usage_stats.daily_buckets(list(records), days=1, now=NOW)
        return buckets[NOW.date().isoformat()]["providers"]["claude"]["cost"]

    small = cost(record(100_000, "d-small"))
    large = cost(record(100_001, "d-large"))
    assert small == pytest.approx(100_000 * 0.10 / 1e6 + 100_000 * 0.50 / 1e6)
    assert large == pytest.approx(100_001 * 0.50 / 1e6 + 100_000 * 2.50 / 1e6)
    assert cost(record(100_000, "d-small"), record(100_001, "d-large")) == pytest.approx(small + large)


def test_the_shipped_snapshot_is_the_hand_table() -> None:
    """The app prices from the snapshot; the hand table is its source."""
    assert usage_stats.PRICING_SNAPSHOT_LOADED
    assert usage_stats.MODEL_PRICING == usage_stats.HAND_MODEL_PRICING
    assert usage_stats.GPT_MODEL_PRICING == usage_stats.HAND_GPT_MODEL_PRICING
    assert usage_stats.GEMINI_MODEL_PRICING == usage_stats.HAND_GEMINI_MODEL_PRICING
    assert usage_stats.CACHE_READ_RATE_OVERRIDES == usage_stats.HAND_CACHE_READ_RATE_OVERRIDES
