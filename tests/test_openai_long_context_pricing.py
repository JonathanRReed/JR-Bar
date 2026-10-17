"""OpenAI bills a request over 272K input tokens at 2x input and 1.5x output.

The threshold is on the whole request's prompt (cached tokens included) and
reprices the whole request, not only the excess. Models without a long-context
tier (mini, nano, the Cyber models) and a person's own price override keep
their rate. Synthetic records only.
"""

from __future__ import annotations

from datetime import datetime

import pytest

from jrbar import core_usage_history as history
from jrbar import usage_stats

NOW = datetime(2026, 10, 7, 12, 0, 0)
LIMIT = 272_000


def _record(model: str, *, inp: int, cached: int = 0, out: int = 0, provider: str = "codex"):
    return (provider, "session", model, NOW.timestamp(), inp, cached, 0, out, f"d-{model}-{inp}-{cached}")


def _day_cost(record: tuple) -> float:
    buckets = usage_stats.daily_buckets([record], days=1, now=NOW)
    return buckets[NOW.date().isoformat()]["providers"]["codex"]["cost"]


@pytest.mark.parametrize(
    ("model", "expected"),
    (
        ("gpt-6.1-sol", True),
        ("gpt-6-sol", True),
        ("gpt-6-luna", True),
        ("gpt-6-astra", True),
        ("gpt-5.6-sol", True),
        ("gpt-5.6-terra", True),
        ("gpt-5.5", True),
        ("gpt-5.5-pro", True),
        ("gpt-5.4", True),
        ("gpt-5.4-pro", True),
        ("gpt-5.4-mini", False),
        ("gpt-5.4-nano", False),
        ("gpt-5.6-cyber", False),
        ("gpt-5.5-cyber", False),
        ("gpt-5.3-codex", False),
        ("gpt-5", False),
        ("claude-opus-5", False),
    ),
)
def test_only_models_with_a_published_long_context_tier_reprice(model: str, expected: bool) -> None:
    assert usage_stats.is_long_context_request("codex", model, LIMIT + 1) is expected
    assert usage_stats.is_long_context_request("codex", model, LIMIT) is False


def test_the_boundary_counts_cached_tokens_and_is_strictly_greater() -> None:
    assert usage_stats.is_long_context_request("codex", "gpt-6.1-sol", LIMIT - 200_000 + 200_001 - 1) is False
    assert usage_stats.is_long_context_request("codex", "gpt-6.1-sol", LIMIT + 1) is True


def test_a_short_request_prices_at_the_standard_rate() -> None:
    # GPT-6.1 Sol: $2 in, $0.10 cached, $10 out. 210k prompt (200k cached), 1k out.
    cost = _day_cost(_record("gpt-6.1-sol", inp=10_000, cached=200_000, out=1_000))

    assert cost == pytest.approx((10_000 * 2.0 + 200_000 * 0.10 + 1_000 * 10.0) / 1e6)


def test_a_long_request_reprices_all_of_it() -> None:
    # 272,001 prompt tokens (cached included): 2x input and cached, 1.5x output.
    cost = _day_cost(_record("gpt-6.1-sol", inp=72_001, cached=200_000, out=1_000))

    assert cost == pytest.approx(2 * (72_001 * 2.0 + 200_000 * 0.10) / 1e6 + 1.5 * 1_000 * 10.0 / 1e6)


def test_a_model_without_the_tier_keeps_its_rate_however_long_the_request() -> None:
    cost = _day_cost(_record("gpt-5.4-mini", inp=500_000, out=10_000))

    assert cost == pytest.approx((500_000 * 0.75 + 10_000 * 4.5) / 1e6)


def test_the_usage_history_reprices_a_long_record_too() -> None:
    document = history.usage_history_document(
        [_record("gpt-6.1-sol", inp=72_001, cached=200_000, out=1_000)],
        provider="codex",
        range_name="7d",
        now=NOW.timestamp(),
    )

    assert document["days"][-1]["cost_usd"] == pytest.approx(
        2 * (72_001 * 2.0 + 200_000 * 0.10) / 1e6 + 1.5 * 1_000 * 10.0 / 1e6, abs=1e-3
    )


def test_a_person_set_price_is_not_multiplied() -> None:
    from jrbar import model_pricing

    model_pricing.OVERRIDES.pin({"gpt-6.1-sol": {"input": 1.0, "output": 4.0}})
    try:
        assert usage_stats.is_long_context_request("codex", "gpt-6.1-sol", LIMIT + 1) is False
    finally:
        model_pricing.OVERRIDES.pin(None)


def test_a_session_of_many_short_requests_is_never_repriced_as_one_long_one(tmp_path) -> None:
    import json

    from jrbar import session_usage

    session_usage.reset_cache()
    sid = "99999999-8888-7777-6666-555555555555"
    path = tmp_path / ".codex" / "sessions" / "2026" / "10" / "07" / f"rollout-2026-10-07T12-00-00-{sid}.jsonl"
    path.parent.mkdir(parents=True)
    rows = [
        {"type": "turn_context", "timestamp": "2026-10-07T12:00:00Z", "payload": {"model": "gpt-6.1-sol"}},
    ]
    for index in range(4):
        total = (index + 1) * 100_000
        rows.append(
            {
                "type": "event_msg",
                "timestamp": f"2026-10-07T12:0{index + 1}:00Z",
                "payload": {
                    "type": "token_count",
                    "info": {
                        "total_token_usage": {"input_tokens": total, "cached_input_tokens": 0, "output_tokens": 0},
                        "last_token_usage": {"input_tokens": 100_000, "cached_input_tokens": 0, "output_tokens": 0},
                    },
                },
            }
        )
    path.write_text("\n".join(json.dumps(row) for row in rows) + "\n", encoding="utf-8")

    doc, gap = session_usage.session_usage("codex", sid, home=tmp_path)

    assert gap is None
    # 400k tokens in four 100k requests at $2/MTok: no request crossed 272K.
    assert doc["estimated_cost_usd"] == pytest.approx(0.8, abs=1e-4)
    session_usage.reset_cache()


def test_a_session_request_over_the_limit_is_repriced(tmp_path) -> None:
    import json

    from jrbar import session_usage

    session_usage.reset_cache()
    sid = "99999999-8888-7777-6666-555555555556"
    path = tmp_path / ".codex" / "sessions" / "2026" / "10" / "07" / f"rollout-2026-10-07T12-00-00-{sid}.jsonl"
    path.parent.mkdir(parents=True)
    rows = [
        {"type": "turn_context", "timestamp": "2026-10-07T12:00:00Z", "payload": {"model": "gpt-6.1-sol"}},
        {
            "type": "event_msg",
            "timestamp": "2026-10-07T12:01:00Z",
            "payload": {
                "type": "token_count",
                "info": {
                    "total_token_usage": {"input_tokens": 300_000, "cached_input_tokens": 0, "output_tokens": 10_000},
                    "last_token_usage": {"input_tokens": 300_000, "cached_input_tokens": 0, "output_tokens": 10_000},
                },
            },
        },
    ]
    path.write_text("\n".join(json.dumps(row) for row in rows) + "\n", encoding="utf-8")

    doc, _gap = session_usage.session_usage("codex", sid, home=tmp_path)

    assert doc["estimated_cost_usd"] == pytest.approx(2 * 300_000 * 2.0 / 1e6 + 1.5 * 10_000 * 10.0 / 1e6, abs=1e-4)
    session_usage.reset_cache()
