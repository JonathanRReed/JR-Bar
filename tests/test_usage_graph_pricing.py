"""The graph prices a record by the model it ran, not by the agent that wrote it.

Pi, OpenClaw, OpenCode and the Gemini CLI run models from several makers. The
cost graph used to price every record that was not Codex's with Anthropic's
table, so a GPT or Gemini model showed no cost and nothing said so.
"""

from __future__ import annotations

from datetime import datetime, timedelta

import pytest

from jrbar import usage_graph_worker, usage_stats
from jrbar.usage_stats import daily_buckets, usage_graph_model

NOW = datetime(2026, 9, 24, 12, 0, 0)
YESTERDAY = (NOW - timedelta(days=1)).timestamp()
DAY = (NOW - timedelta(days=1)).date().isoformat()

# input, cached input, cache write, output. A 170K prompt: under OpenAI's
# 272K long-context line, so these tests price the table rows themselves.
TOKENS = (100_000, 50_000, 20_000, 10_000)


def _record(provider: str, model: str, *, tokens=TOKENS, dedupe: str | None = None) -> tuple:
    return (provider, f"{provider}-session", model, YESTERDAY, *tokens, dedupe or f"{provider}:{model}")


def _cost(provider: str, model: str, **kwargs) -> float:
    buckets = daily_buckets([_record(provider, model)], days=7, now=NOW, **kwargs)
    return buckets[DAY]["providers"][provider]["cost"]


def _expected(rates, model: str, *, write_multiplier: float) -> float:
    input_rate, output_rate = rates
    inp, cached, create, out = TOKENS
    return (
        inp * input_rate
        + cached * input_rate * usage_stats.cache_read_rate_for_model(model)
        + create * input_rate * write_multiplier
        + out * output_rate
    ) / 1_000_000.0


def test_an_agent_running_a_gpt_model_is_priced_from_the_openai_table() -> None:
    model = "gpt-5.6-sol"
    rates = usage_stats._gpt_pricing_for_model(model)
    assert rates is not None

    for provider in ("pi", "openclaw", "opencode"):
        # OpenAI bills a cache write at the plain input rate.
        assert _cost(provider, model) == pytest.approx(_expected(rates, model, write_multiplier=1.0))


def test_the_gemini_cli_and_agents_running_gemini_are_priced_from_the_gemini_table() -> None:
    model = "gemini-3.1-pro"
    rates = usage_stats._gemini_pricing_for_model(model)
    assert rates is not None

    for provider in ("gemini", "pi", "opencode"):
        assert _cost(provider, model) == pytest.approx(_expected(rates, model, write_multiplier=1.0))


def test_claude_models_keep_the_anthropic_table_whoever_ran_them() -> None:
    model = "claude-sonnet-4-5"
    rates = usage_stats._pricing_for_model(model)
    assert rates is not None
    expected = _expected(
        rates,
        model,
        write_multiplier=usage_stats.cache_write_rate_for_model(model),
    )

    for provider in ("claude", "opencode", "pi"):
        assert _cost(provider, model) == pytest.approx(expected)
    # And the Claude-only total the old graph kept is still Claude's own.
    buckets = daily_buckets(
        [_record("claude", model), _record("opencode", model)],
        days=7,
        now=NOW,
    )
    assert buckets[DAY]["claude_cost"] == pytest.approx(expected)


def test_codex_keeps_the_openai_table() -> None:
    model = "gpt-5.4"
    rates = usage_stats._gpt_pricing_for_model(model)
    assert _cost("codex", model) == pytest.approx(_expected(rates, model, write_multiplier=1.0))


def test_a_model_with_no_price_costs_nothing_and_is_named() -> None:
    unpriced: dict[str, int] = {}
    records = [
        _record("grok", "grok-4", dedupe="a"),
        _record("opencode", "qwen3-coder", tokens=(10, 0, 0, 5), dedupe="b"),
        # No tokens, no disclosure: a step count is activity, not usage.
        _record("antigravity", "gemini", tokens=(0, 0, 0, 0), dedupe="c"),
        _record("claude", "sonnet", dedupe="d"),
    ]

    buckets = daily_buckets(records, days=7, now=NOW, unpriced=unpriced)

    assert buckets[DAY]["providers"]["grok"]["cost"] == 0.0
    assert buckets[DAY]["providers"]["opencode"]["cost"] == 0.0
    assert unpriced == {"grok-4": sum(TOKENS), "qwen3-coder": 15}


def test_a_record_outside_the_window_is_not_disclosed() -> None:
    unpriced: dict[str, int] = {}
    old = ("grok", "s", "grok-4", (NOW - timedelta(days=40)).timestamp(), 5, 0, 0, 5, "old")

    daily_buckets([old], days=7, now=NOW, unpriced=unpriced)

    assert unpriced == {}


def test_the_graph_model_passes_the_disclosure_through() -> None:
    unpriced: dict[str, int] = {}

    usage_graph_model(
        [_record("grok", "grok-4")],
        days=7,
        metric="cost",
        provider_ids=("grok",),
        now=NOW,
        unpriced=unpriced,
    )

    assert unpriced == {"grok-4": sum(TOKENS)}


def test_cost_coverage_counts_only_selected_in_range_deduplicated_positive_records():
    def record(provider, model, tokens, key, *, epoch=YESTERDAY):
        return (provider, "shared-session", model, epoch, *tokens, key)

    missing = record("opencode", "future-model", (1, 2, 3, 4), "missing-2")
    records = [
        record("opencode", "gpt-5.6-sol", (1, 2, 3, 4), "priced"),
        record("opencode", "future-model", (10, 20, 30, 40), "missing-1"),
        missing, missing,
        record("grok", "future-model", (5, 6, 7, 8), "missing-3"),
        record("opencode", "future-model", (0, 0, 0, 0), "zero-unpriced"),
        record("opencode", "gpt-5.6-sol", (0, 0, 0, 0), "zero-priced"),
        record("opencode", "future-model", (99, 99, 99, 99), "old",
               epoch=(NOW - timedelta(days=40)).timestamp()),
        record("claude", "future-model", (99, 99, 99, 99), "not-selected"),
    ]
    coverage = {}
    unpriced = {}
    usage_graph_model(records, days=7, metric="cost", provider_ids=("opencode", "grok"),
                      now=NOW, unpriced=unpriced, cost_coverage=coverage)
    assert coverage == {
        "observed_records": 4, "priced_records": 1, "unpriced_records": 3,
        "unpriced_sessions": 2,
        "token_categories": {"input": 16, "cached_input": 28, "cache_creation": 40, "output": 52},
    }
    assert coverage["priced_records"] + coverage["unpriced_records"] == coverage["observed_records"]
    assert unpriced == {"future-model": 136}


def test_cached_only_unpriced_record_is_counted_without_inventing_a_price():
    coverage = {}
    buckets = daily_buckets([_record("opencode", "future-model", tokens=(0, 9, 7, 0))],
                            days=7, now=NOW, cost_coverage=coverage)
    assert coverage == {
        "observed_records": 1, "priced_records": 0, "unpriced_records": 1,
        "unpriced_sessions": 1,
        "token_categories": {"input": 0, "cached_input": 9, "cache_creation": 7, "output": 0},
    }
    assert buckets[DAY]["providers"]["opencode"]["cost"] == 0


def test_empty_cost_coverage_has_zero_counts_and_all_categories():
    coverage = {}
    daily_buckets([], days=7, now=NOW, cost_coverage=coverage)
    assert coverage == {
        "observed_records": 0, "priced_records": 0, "unpriced_records": 0,
        "unpriced_sessions": 0,
        "token_categories": {"input": 0, "cached_input": 0, "cache_creation": 0, "output": 0},
    }


def test_deselected_provider_cannot_consume_a_selected_records_dedupe_key():
    coverage = {}
    usage_graph_model([
        _record("claude", "future-model", dedupe="shared"),
        _record("opencode", "future-model", tokens=(1, 2, 3, 4), dedupe="shared"),
    ], days=7, metric="cost", provider_ids=("opencode",), now=NOW, cost_coverage=coverage)
    assert coverage["observed_records"] == coverage["unpriced_records"] == 1
    assert coverage["token_categories"] == {"input": 1, "cached_input": 2, "cache_creation": 3, "output": 4}


def test_unknown_only_cost_day_is_a_gap_while_empty_days_stay_zero():
    model = usage_graph_model([_record("t3code", "t3code", tokens=(5, 0, 0, 4))],
        days=7, metric="cost", provider_ids=("t3code",), now=NOW)
    values = model["series"][0]["values"]
    assert values[-2] == -1.0
    assert all(value == 0 for index, value in enumerate(values) if index != len(values) - 2)
    assert model["scale_max"] > 0
    assert model["series"][0]["has_priced_usage"] is False


def test_unknown_day_next_to_a_known_day_does_not_draw_zero_dollars():
    known = _record("opencode", "gpt-5.6-sol", dedupe="known")
    unknown = ("opencode", "other", "future-model", NOW.timestamp(), 5, 0, 0, 4, "unknown")
    model = usage_graph_model([known, unknown], days=7, metric="cost", provider_ids=("opencode",), now=NOW)
    assert model["series"][0]["values"][-2] > 0
    assert model["series"][0]["values"][-1] == -1.0


def test_explicitly_priced_free_usage_is_zero_not_an_unknown_gap(monkeypatch):
    monkeypatch.setattr(usage_stats, "rates_for_record", lambda *_args: usage_stats.RecordRates(0, 0, 1))
    coverage = {}
    model = usage_graph_model([_record("opencode", "free-model")], days=7, metric="cost",
                             provider_ids=("opencode",), now=NOW, cost_coverage=coverage)
    assert model["series"][0]["values"] == (0,) * 7
    assert coverage["observed_records"] == coverage["priced_records"] == 1
    assert coverage["unpriced_records"] == 0
    assert model["series"][0]["has_priced_usage"] is True


def test_mixed_cost_day_keeps_known_subtotal_and_missing_price_counts():
    known = _record("opencode", "gpt-5.6-sol", dedupe="known")
    missing = _record("opencode", "future-model", dedupe="missing")
    coverage = {}
    model = usage_graph_model([missing, known], days=7, metric="cost", provider_ids=("opencode",),
                             now=NOW, cost_coverage=coverage)
    assert model["series"][0]["values"][-2] == _cost("opencode", "gpt-5.6-sol")
    assert coverage["observed_records"] == 2
    assert coverage["priced_records"] == coverage["unpriced_records"] == 1
    assert model["series"][0]["has_priced_usage"] is True


def test_unpriced_gap_evidence_respects_selected_providers_and_range():
    old = ("opencode", "old", "future-model", (NOW - timedelta(days=40)).timestamp(), 1, 0, 0, 0, "old")
    zero = _record("opencode", "future-model", tokens=(0, 0, 0, 0), dedupe="zero")
    hidden = _record("t3code", "t3code", dedupe="hidden")
    model = usage_graph_model([old, zero, hidden], days=7, metric="cost", provider_ids=("opencode",), now=NOW)
    assert model["series"] == ()


@pytest.mark.parametrize("metric", ["tokens", "sessions"])
def test_unpriced_records_keep_token_and_session_graphs(metric):
    model = usage_graph_model([_record("t3code", "t3code", tokens=(5, 0, 0, 4))],
        days=7, metric=metric, provider_ids=("t3code",), now=NOW)
    assert model["series"][0]["values"][-2] == (9 if metric == "tokens" else 1)
    assert -1 not in model["series"][0]["values"]
    assert "has_priced_usage" not in model["series"][0]


def test_the_cost_summary_names_the_models_it_could_not_price(monkeypatch) -> None:
    from types import SimpleNamespace

    settings = SimpleNamespace(
        usage_graph_days=7,
        usage_display_mode="cost",
        usage_graph_providers=("opencode",),
    )
    monkeypatch.setattr(
        usage_graph_worker.usage_stats,
        "scan_usage",
        lambda *_args, **_kwargs: usage_stats.UsageTotals(),
    )
    monkeypatch.setattr(usage_graph_worker, "scan_usage_all_homes", lambda *_a, **_k: usage_stats.UsageTotals())
    monkeypatch.setattr(
        usage_graph_worker,
        "_scan_opencode_records",
        lambda *_args: [
            ("opencode", "s1", "qwen3-coder", datetime.now().timestamp(), 100, 0, 0, 50, "x1"),
            ("opencode", "s2", "gpt-5.6-sol", datetime.now().timestamp(), 100, 0, 0, 50, "x2"),
        ],
    )
    monkeypatch.setattr(usage_graph_worker, "_scan_antigravity_records", lambda *_args: [])

    _model, summary = usage_graph_worker._build_payload(settings)

    assert "No price for qwen3-coder" in summary
    assert "gpt-5.6-sol" not in summary

    # Tokens mode draws no dollars, so it has nothing to disclose.
    settings.usage_display_mode = "tokens"
    _model, summary = usage_graph_worker._build_payload(settings)
    assert "No price for" not in summary
