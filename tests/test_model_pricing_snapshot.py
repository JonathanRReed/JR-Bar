"""The pricing snapshot and the person's pricing overrides.

The estimates price from a packaged snapshot (written by hand with
scripts/update_model_pricing.py) and fall back to the hand-kept table; an
override always wins; a model neither knows stays unpriced, never $0; and
nothing fetches a price at runtime.
"""

from __future__ import annotations

import importlib.util
import json
from pathlib import Path

import pytest

from jrbar import core_usage_history as history
from jrbar import model_pricing, usage_stats

ROOT = Path(__file__).resolve().parents[1]


@pytest.fixture(autouse=True)
def _no_overrides():
    model_pricing.OVERRIDES.pin({})
    yield
    model_pricing.OVERRIDES.pin(None)


def test_the_snapshot_loads_and_matches_the_hand_table() -> None:
    snapshot = model_pricing.load_snapshot()

    assert usage_stats.PRICING_SNAPSHOT_LOADED is True
    assert snapshot["anthropic"] == usage_stats.HAND_MODEL_PRICING
    assert snapshot["openai"] == usage_stats.HAND_GPT_MODEL_PRICING
    assert snapshot["gemini"] == usage_stats.HAND_GEMINI_MODEL_PRICING
    assert snapshot["cache_read_overrides"] == usage_stats.HAND_CACHE_READ_RATE_OVERRIDES
    assert usage_stats.MODEL_PRICING == snapshot["anthropic"]


def test_a_broken_snapshot_is_refused_and_the_hand_table_stands() -> None:
    assert model_pricing.load_snapshot("not json") is None
    assert model_pricing.load_snapshot(json.dumps({"schemaVersion": 2})) is None
    bad_row = {"schemaVersion": 1, "anthropic": [["opus", -1, 5]], "openai": [["gpt", 1, 1]], "gemini": [["pro", 1, 1]]}
    assert model_pricing.load_snapshot(json.dumps(bad_row)) is None


def test_an_override_wins_and_the_rest_keeps_the_table() -> None:
    before = history.price_quote("claude", "opus")
    model_pricing.OVERRIDES.pin({"opus": {"input": 1.0, "output": 2.0, "cache_read": 0.05, "cache_write": 1.5}})

    quote = history.price_quote("claude", "opus")

    assert (quote.input_per_mtok, quote.output_per_mtok) == (1.0, 2.0)
    assert quote.cache_read_per_mtok == pytest.approx(0.05)
    assert usage_stats.cache_write_rate_for_model("opus") == pytest.approx(1.5)
    cost = history.record_cost("claude", "opus", 1_000_000, 0, 1_000_000, 1_000_000)
    assert cost == pytest.approx(1.0 + 1.5 + 2.0)
    assert history.price_quote("claude", "sonnet-5").input_per_mtok == 2.0
    assert before.input_per_mtok == 5.0


def test_the_longest_key_wins_and_keys_match_inside_the_name() -> None:
    model_pricing.OVERRIDES.pin({"gpt": {"input": 9.0, "output": 9.0}, "gpt-5.6-sol": {"input": 3.0, "output": 15.0}})

    assert usage_stats._gpt_pricing_for_model("gpt-5.6-sol-2026") == (3.0, 15.0)
    assert usage_stats._gpt_pricing_for_model("gpt-6-astra") == (9.0, 9.0)


def test_an_unknown_model_stays_unpriced() -> None:
    model_pricing.OVERRIDES.pin({"opus": {"input": 1.0, "output": 2.0}})

    assert usage_stats._pricing_for_model("brand-new-model") is None
    assert history.price_quote("pi", "brand-new-model") is None


def test_the_setting_round_trips_and_drops_bad_rows(tmp_path: Path) -> None:
    from jrbar.settings import load_settings

    target = tmp_path / "settings.json"
    target.write_text(
        json.dumps(
            {
                "pricing_overrides": {
                    "My-Model": {"input": 1, "output": 2, "cache_read": "cheap"},
                    "no-output": {"input": 1},
                    "": {"input": 1, "output": 1},
                    "absurd": {"input": 1e9, "output": 1},
                }
            }
        )
    )

    settings = load_settings(target)

    assert settings.pricing_overrides == {"my-model": {"input": 1.0, "output": 2.0}}
    assert settings.to_dict()["pricing_overrides"] == {"my-model": {"input": 1.0, "output": 2.0}}


def _script():
    spec = importlib.util.spec_from_file_location("update_model_pricing", ROOT / "scripts" / "update_model_pricing.py")
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


def test_the_script_writes_what_ships_and_reads_litellm(tmp_path: Path) -> None:
    script = _script()
    shipped = (ROOT / "src" / "jrbar" / "resources" / "model_pricing.json").read_text()
    output = tmp_path / "pricing.json"

    assert script.main(["--from-table", "--output", str(output)]) == 0
    assert output.read_text() == shipped, "the shipped snapshot is the hand table, regenerated"

    litellm = tmp_path / "litellm.json"
    litellm.write_text(
        json.dumps(
            {
                "claude-sonnet-5-20260901": {"input_cost_per_token": 2.5e-06, "output_cost_per_token": 1.2e-05},
                "anthropic/claude-sonnet-5": {"input_cost_per_token": 2.5e-06, "output_cost_per_token": 1.2e-05},
                "gpt-5.4-mini": {"input_cost_per_token": 7.5e-07, "output_cost_per_token": 4.5e-06},
                "claude-opus-4-1": {"input_cost_per_token": 1.5e-05, "output_cost_per_token": 7.5e-05},
                "claude-opus-4-1-dated": {"input_cost_per_token": 1.6e-05, "output_cost_per_token": 7.5e-05},
            }
        )
    )
    updated = tmp_path / "updated.json"
    assert script.main(["--litellm", str(litellm), "--output", str(updated)]) == 0
    document = json.loads(updated.read_text())
    rows = {row[0]: row[1:] for row in document["anthropic"]}
    assert rows["sonnet-5"] == [2.5, 12.0], "LiteLLM agreed with itself, so its rate is taken"
    assert rows["opus-4"] == [15.0, 75.0], "LiteLLM disagreed with itself, so ours stays"
    assert model_pricing.load_snapshot(updated.read_text()) is not None


def test_nothing_fetches_a_price_at_runtime() -> None:
    source = (ROOT / "src" / "jrbar" / "model_pricing.py").read_text()
    for word in ("urllib", "http.client", "requests", "socket"):
        assert word not in source
