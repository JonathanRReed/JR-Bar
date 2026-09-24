"""Local token history for Pi, Grok, Gemini CLI and OpenClaw.

Golden totals over the shaped fixtures in tests/fixtures/local_usage/, and
the rules that keep them honest: a subagent's debug copy, a repeated Grok
event and a migrated OpenClaw JSONL copy each count once, and none of
these agents' records ever joins the Claude or Codex totals.
"""

from __future__ import annotations

import json
import shutil
import sqlite3
from pathlib import Path

import pytest

from jrbar import core_usage_history as history
from jrbar.local_token_history import (
    roots,
    scan_gemini_records,
    scan_grok_records,
    scan_local_records,
    scan_openclaw_records,
    scan_pi_records,
)

FIXTURES = Path(__file__).parent / "fixtures" / "local_usage"


def _sums(records: list[tuple]) -> tuple[int, int, int, int]:
    return (
        sum(record[4] for record in records),
        sum(record[5] for record in records),
        sum(record[6] for record in records),
        sum(record[7] for record in records),
    )


def test_pi_counts_assistant_usage_and_skips_subagent_copies() -> None:
    records = scan_pi_records(FIXTURES / "pi" / "sessions", 0.0)

    assert [record[2] for record in records] == ["claude-sonnet-5", "gpt-5.6-sol"]
    assert _sums(records) == (2000, 5000, 200, 400)
    assert {record[0] for record in records} == {"pi"}, "Pi's records stay Pi's, whatever model ran them"


def test_grok_counts_completed_turns_once_with_cache_taken_out_of_input() -> None:
    records = scan_grok_records(FIXTURES / "grok" / "sessions", 0.0)
    unique = {record[8]: record for record in records}

    assert len(unique) == 2
    first = unique["grok:evt-1:grok-4.5-build"]
    assert first[4:] == (600, 400, 0, 200, "grok:evt-1:grok-4.5-build")
    second = unique["grok:evt-2:grok"]
    assert second[3] == pytest.approx(1789900100.5)
    assert second[4:8] == (200, 0, 100, 30)


def test_gemini_takes_cached_tokens_out_of_an_inclusive_input() -> None:
    records = scan_gemini_records(FIXTURES / "gemini" / "tmp", 0.0)

    assert [(record[2], record[4], record[5], record[7]) for record in records] == [
        ("gemini-3.1-pro-preview", 500, 1500, 200),
        ("gemini-3-flash-preview", 500, 0, 40),
    ]


def _openclaw_tree(tmp_path: Path) -> Path:
    root = tmp_path / "openclaw"
    shutil.copytree(FIXTURES / "openclaw", root)
    database = root / "agents" / "main" / "agent" / "openclaw-agent.sqlite"
    database.parent.mkdir(parents=True)
    with sqlite3.connect(database) as connection:
        connection.execute(
            "CREATE TABLE transcript_events (session_id TEXT NOT NULL, seq INTEGER NOT NULL,"
            " event_json TEXT NOT NULL, created_at INTEGER NOT NULL, PRIMARY KEY (session_id, seq))"
        )
        events = [
            # The same event the JSONL holds: the database copy wins.
            {"type": "message", "id": "oc-1", "timestamp": "2026-09-20T09:00:00.000Z",
             "message": {"role": "assistant", "modelId": "claude-opus-5",
                         "usage": {"input": 700, "output": 90, "cacheRead": 100, "cacheWrite": 0}}},
            {"type": "message", "id": "oc-3", "timestamp": "2026-09-20T09:10:00.000Z",
             "message": {"role": "assistant", "modelId": "claude-opus-5",
                         "usage": {"input": 50, "output": 5}}},
            {"type": "message", "id": "oc-4", "message": {"role": "user", "content": "(never read)"}},
        ]
        for seq, event in enumerate(events):
            connection.execute(
                "INSERT INTO transcript_events VALUES (?, ?, ?, ?)", ("main", seq, json.dumps(event), 0)
            )
    return root


def test_openclaw_reads_the_agent_database_and_its_jsonl_once(tmp_path: Path) -> None:
    records = scan_openclaw_records(_openclaw_tree(tmp_path), 0.0)

    assert sorted(record[8] for record in records) == ["openclaw:oc-1", "openclaw:oc-2", "openclaw:oc-3"]
    assert _sums(records) == (1050, 100, 0, 115)


def test_the_combined_scan_follows_the_environment_and_counts_each_source_once(tmp_path: Path) -> None:
    env = {
        "PI_CODING_AGENT_DIR": str(FIXTURES / "pi"),
        "GROK_HOME": str(FIXTURES / "grok"),
        "GEMINI_DATA_DIR": str(FIXTURES / "gemini"),
        "OPENCLAW_DIR": str(_openclaw_tree(tmp_path)),
    }
    assert roots(env=env)["pi"] == FIXTURES / "pi" / "sessions"

    records = scan_local_records(["pi", "grok", "gemini", "openclaw", "claude"], 0.0, env=env)

    by_provider: dict[str, int] = {}
    for record in records:
        by_provider[record[0]] = by_provider.get(record[0], 0) + 1
    assert by_provider == {"pi": 2, "grok": 2, "gemini": 2, "openclaw": 3}
    assert len({record[8] for record in records}) == len(records)
    # Nothing here is ever a Claude or Codex record.
    assert not any(record[0] in ("claude", "codex") for record in records)
    # A window that starts after everything finds nothing.
    assert scan_local_records(["pi", "grok", "gemini"], 1_900_000_000.0, env=env) == []


def test_a_missing_home_is_just_empty(tmp_path: Path) -> None:
    assert scan_local_records(["pi", "grok", "gemini", "openclaw"], 0.0, env={}, home=tmp_path) == []


def test_pi_and_openclaw_records_are_priced_by_the_model_that_ran_them() -> None:
    assert history.price_quote("pi", "claude-sonnet-5").input_per_mtok == 2.0
    assert history.price_quote("pi", "gpt-5.6-sol").input_per_mtok == 4.0
    assert history.price_quote("openclaw", "gemini-3-flash-preview").input_per_mtok == 0.5
    assert history.price_quote("grok", "grok-4.5-build") is None, "no Grok table: unpriced, never $0"


def test_the_usage_center_history_reads_them(monkeypatch) -> None:
    monkeypatch.setenv("PI_CODING_AGENT_DIR", str(FIXTURES / "pi"))
    records = history.scan_provider_records("pi", days=3650)
    assert len(records) == 2
