"""Claude bills a one-hour cache write at 2x input and a five-minute one at 1.25x.

Claude Code writes ``usage.cache_creation.ephemeral_1h_input_tokens`` (a
subset of ``cache_creation_input_tokens``), and anthropic's price page lists
the two rates apart. The estimate used to charge every write at 1.25x.
Synthetic transcripts only.
"""

from __future__ import annotations

import json
from datetime import datetime
from pathlib import Path

import pytest

from jrbar import core_usage_history as history
from jrbar import usage_stats

MILLION = 1_000_000


def _line(message_id: str, usage: dict, *, model: str = "claude-sonnet-5", stamp: str = "2026-10-06T12:00:00Z") -> str:
    return json.dumps(
        {"type": "assistant", "timestamp": stamp, "message": {"id": message_id, "model": model, "usage": usage}}
    )


def _root(tmp_path: Path, *lines: str) -> Path:
    root = tmp_path / "claude"
    (root / "project").mkdir(parents=True)
    (root / "project" / "s.jsonl").write_text("\n".join(lines) + "\n", encoding="utf-8")
    return root


def _usage(created: int, one_hour: int | None, **rest) -> dict:
    usage = {
        "input_tokens": 0,
        "cache_read_input_tokens": 0,
        "cache_creation_input_tokens": created,
        "output_tokens": 0,
        **rest,
    }
    if one_hour is not None:
        usage["cache_creation"] = {
            "ephemeral_5m_input_tokens": created - one_hour,
            "ephemeral_1h_input_tokens": one_hour,
        }
    return usage


def test_a_one_hour_write_costs_twice_the_input_rate(tmp_path: Path) -> None:
    root = _root(tmp_path, _line("m1", _usage(MILLION, MILLION)))

    totals = usage_stats.scan_usage(root, None)

    # Sonnet 5 input is $2/MTok: 1M one-hour writes are $4, not $2.50.
    assert totals.estimated_cost_usd == pytest.approx(4.0)
    assert totals.cache_creation_tokens == MILLION


def test_a_five_minute_write_stays_at_one_and_a_quarter(tmp_path: Path) -> None:
    root = _root(tmp_path, _line("m1", _usage(MILLION, 0)))

    assert usage_stats.scan_usage(root, None).estimated_cost_usd == pytest.approx(2.5)


def test_a_message_without_the_breakdown_is_priced_as_five_minute(tmp_path: Path) -> None:
    root = _root(tmp_path, _line("m1", _usage(MILLION, None)))

    assert usage_stats.scan_usage(root, None).estimated_cost_usd == pytest.approx(2.5)


def test_a_mixed_message_prices_each_part_at_its_own_rate(tmp_path: Path) -> None:
    root = _root(tmp_path, _line("m1", _usage(MILLION, 400_000, input_tokens=MILLION, output_tokens=MILLION)))

    totals = usage_stats.scan_usage(root, None)

    # input 1M x $2 + 600k x $2.50 (5m) + 400k x $4 (1h) + output 1M x $10.
    assert totals.estimated_cost_usd == pytest.approx(2.0 + 1.5 + 1.6 + 10.0)
    assert totals.input_tokens == MILLION
    assert totals.cache_creation_tokens == MILLION
    assert totals.output_tokens == MILLION


def test_a_breakdown_larger_than_the_total_cannot_invent_tokens(tmp_path: Path) -> None:
    usage = _usage(1000, None)
    usage["cache_creation"] = {"ephemeral_5m_input_tokens": 0, "ephemeral_1h_input_tokens": 9_999_999}
    root = _root(tmp_path, _line("m1", usage))

    totals = usage_stats.scan_usage(root, None)

    assert totals.cache_creation_tokens == 1000


@pytest.mark.parametrize("bad", (-5, "7", None, True, float("nan")))
def test_a_malformed_breakdown_falls_back_to_five_minute(tmp_path: Path, bad) -> None:
    usage = _usage(MILLION, None)
    usage["cache_creation"] = {"ephemeral_1h_input_tokens": bad}
    root = _root(tmp_path, _line("m1", usage))

    totals = usage_stats.scan_usage(root, None)

    assert totals.cache_creation_tokens == MILLION
    assert totals.estimated_cost_usd == pytest.approx(2.5)


def test_a_replayed_message_counts_once(tmp_path: Path) -> None:
    line = _line("m1", _usage(MILLION, MILLION))
    root = _root(tmp_path, line, line)

    totals = usage_stats.scan_usage(root, None)

    assert totals.cache_creation_tokens == MILLION
    assert totals.estimated_cost_usd == pytest.approx(4.0)


def test_the_one_hour_part_is_not_a_second_model_or_a_second_session(tmp_path: Path) -> None:
    root = _root(tmp_path, _line("m1", _usage(MILLION, MILLION)))

    totals = usage_stats.scan_usage(root, None)

    assert len(totals.sessions) == 1
    assert {usage_stats.base_model_key(record[2]) for record in totals.records} == {"sonnet-5"}


def test_the_thirty_day_card_prices_the_split_the_same_way(tmp_path: Path) -> None:
    now = datetime.now().timestamp()
    stamp = datetime.fromtimestamp(now - 3600).astimezone().strftime("%Y-%m-%dT%H:%M:%S%z")
    root = _root(tmp_path, _line("m1", _usage(MILLION, MILLION), stamp=stamp))
    cache_path = tmp_path / "state" / "usage-scan-cache.json"

    scanned = usage_stats.scan_usage(root, cache_path, now=now)
    card = usage_stats.cache_card_days(usage_stats._load_cache(cache_path), "claude")

    assert card is not None
    totals = usage_stats.card_totals(card, usage_stats.card_window_start(now), "claude")
    assert scanned.estimated_cost_usd == pytest.approx(4.0)
    assert totals.estimated_cost_usd == pytest.approx(4.0)
    assert totals.cache_creation_tokens == MILLION
    assert totals.models == frozenset({"sonnet-5"})


def test_the_usage_history_prices_the_one_hour_record_at_two_times(tmp_path: Path) -> None:
    sonnet = usage_stats._record_model_key("claude-sonnet-5")
    one_hour = sonnet + usage_stats.ONE_HOUR_WRITE_SUFFIX

    five = history.record_cost("claude", sonnet, 0, 0, MILLION, 0)
    hour = history.record_cost("claude", one_hour, 0, 0, MILLION, 0)

    assert five == pytest.approx(2.5)
    assert hour == pytest.approx(4.0)


def test_a_person_set_cache_write_price_wins_for_both_parts() -> None:
    from jrbar import model_pricing

    model_pricing.OVERRIDES.pin({"sonnet-5": {"input": 2.0, "output": 10.0, "cache_write": 3.0}})
    try:
        assert usage_stats.cache_write_rate_for_model("sonnet-5") == pytest.approx(1.5)
        assert usage_stats.cache_write_rate_for_model("sonnet-5" + usage_stats.ONE_HOUR_WRITE_SUFFIX) == pytest.approx(1.5)
    finally:
        model_pricing.OVERRIDES.pin(None)


def test_opus_5_5_one_hour_write_is_eight_dollars(tmp_path: Path) -> None:
    root = _root(tmp_path, _line("m1", _usage(MILLION, MILLION), model="claude-opus-5-5"))

    # Anthropic lists $8/MTok for an Opus 5.5 one-hour write ($4 input x 2).
    assert usage_stats.scan_usage(root, None).estimated_cost_usd == pytest.approx(8.0)


def test_the_usage_history_shows_one_model_and_one_record_for_a_split_message() -> None:
    sonnet = usage_stats._record_model_key("claude-sonnet-5")
    stamp = datetime(2026, 10, 6, 12, 0, 0).timestamp()
    records = [
        ("claude", "s", sonnet, stamp, 0, 0, 400_000, 0, "message:abc"),
        ("claude", "s", sonnet + usage_stats.ONE_HOUR_WRITE_SUFFIX, stamp, 0, 0, 600_000, 0, "message:abc|1h"),
    ]

    document = history.usage_history_document(
        records, provider="claude", range_name="7d", now=datetime(2026, 10, 7, 12, 0, 0).timestamp()
    )

    assert document["records"] == 1
    assert [row["model"] for row in document["models"]] == [sonnet]
    assert document["models"][0]["records"] == 1
    assert document["models"][0]["tokens"] == 1_000_000
    assert document["models"][0]["priced"] is True
    assert document["models"][0]["cost_usd"] == pytest.approx(0.4 * 2.5 + 0.6 * 4.0, abs=1e-3)
    assert document["unpriced_models"] == []


def test_an_unpriced_model_is_listed_once_even_when_it_split() -> None:
    stamp = datetime(2026, 10, 6, 12, 0, 0).timestamp()
    records = [
        ("pi", "s", "mystery-model", stamp, 0, 0, 400, 0, "pi:abc"),
        ("pi", "s", "mystery-model" + usage_stats.ONE_HOUR_WRITE_SUFFIX, stamp, 0, 0, 600, 0, "pi:abc|1h"),
    ]

    document = history.usage_history_document(
        records, provider="pi", range_name="7d", now=datetime(2026, 10, 7, 12, 0, 0).timestamp()
    )

    assert document["unpriced_models"] == ["mystery-model"]
    assert document["unpriced_records"] == 1
