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
from types import SimpleNamespace

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
    records = history.scan_provider_records("pi", days=36_500)
    assert len(records) == 2


@pytest.mark.parametrize("provider", ["pi", "grok", "gemini", "openclaw"])
def test_the_usage_center_asks_for_their_history_and_gets_it(provider: str) -> None:
    """The history service used to answer an empty document for anything
    but Claude and Codex without ever scanning, so none of this reached a
    card."""
    scanned: list[tuple[str, int]] = []

    def scan(name: str, days: int) -> list[tuple]:
        scanned.append((name, days))
        return [(name, "s1", "claude-sonnet-5", 1_789_900_000.0, 100, 0, 0, 50, f"{name}:1")]

    # "Today" is a day after the records, so the 30-day window holds them
    # whenever the test runs.
    service = history.UsageHistoryService(scan, wall_clock=lambda: 1_789_900_000.0 + 86_400.0)
    # A bounded wait on the scan's own completion event, not the clock.
    document = service.document(provider, "30d", budget=30.0)

    assert scanned == [(provider, 30)]
    assert document["records"] == 1 and document["pending"] is False
    service.warm((provider,))
    assert provider in history.HISTORY_PROVIDERS


def test_the_default_graph_charts_pi_and_openclaw_when_their_files_exist(tmp_path: Path, monkeypatch) -> None:
    from jrbar import usage_graph_worker

    monkeypatch.setenv("PI_CODING_AGENT_DIR", str(FIXTURES / "pi"))
    monkeypatch.setenv("OPENCLAW_DIR", str(tmp_path / "no-openclaw-here"))
    assert usage_graph_worker._agent_histories_found() == ("pi",)

    seen: dict[str, tuple[str, ...]] = {}

    def build(snapshot, **_kwargs):
        seen["providers"] = tuple(snapshot.usage_graph_providers)
        return {}, None

    monkeypatch.setattr(usage_graph_worker, "_build_payload", build)
    monkeypatch.setattr(usage_graph_worker, "_corpus_fingerprint", lambda _snapshot, **_kwargs: {})
    monkeypatch.setattr(usage_graph_worker, "_usage_doc_cache_read", lambda: {})
    monkeypatch.setattr(usage_graph_worker, "_usage_doc_cache_store", lambda *_args: None)
    monkeypatch.setattr(
        usage_graph_worker, "_project_graph_document", lambda _model, _summary, providers: {"providers": providers}
    )
    settings = SimpleNamespace(usage_graph_days=30, usage_display_mode="tokens", usage_graph_providers=("claude",))

    assert usage_graph_worker.usage_graph_document(settings)["providers"] == ("claude", "pi")
    assert seen["providers"] == ("claude", "pi")
    # An explicit pick from the picker is taken as it is, and the percent
    # chart has nothing to say about them.
    assert usage_graph_worker.usage_graph_document(settings, provider_ids=["claude"])["providers"] == ("claude",)
    assert usage_graph_worker.usage_graph_document(settings, metric="percent")["providers"] == ("claude",)


def test_the_graph_cache_notices_new_gemini_chats_and_openclaw_events(tmp_path: Path) -> None:
    import sqlite3

    from jrbar import usage_graph_worker

    gemini = tmp_path / "gemini" / "tmp"
    chats = gemini / "5f1c0a" / "chats"
    chats.mkdir(parents=True)
    (chats / "session-1.json").write_text('{"messages": []}', encoding="utf-8")
    before = usage_graph_worker._local_history_fingerprint("gemini", gemini)
    (chats / "session-2.json").write_text('{"messages": []}', encoding="utf-8")
    assert usage_graph_worker._local_history_fingerprint("gemini", gemini) != before

    openclaw = tmp_path / "openclaw"
    database = openclaw / "agents" / "main" / "agent" / "openclaw-agent.sqlite"
    database.parent.mkdir(parents=True)
    with sqlite3.connect(database) as connection:
        connection.execute("CREATE TABLE transcript_events (session_id TEXT, seq INTEGER, event TEXT)")
    before = usage_graph_worker._local_history_fingerprint("openclaw", openclaw)
    assert "agents/main/agent/openclaw-agent.sqlite" in before["databases"]
    with sqlite3.connect(database) as connection:
        connection.execute("INSERT INTO transcript_events VALUES ('s1', 1, '{}')")
    assert usage_graph_worker._local_history_fingerprint("openclaw", openclaw) != before


def test_a_crowded_history_keeps_the_newest_files_not_the_first_by_name(
    tmp_path: Path, monkeypatch
) -> None:
    import os

    from jrbar import local_token_history

    # Session files are named by date, so path order is oldest first: a cap
    # applied in path order would drop exactly the current days.
    monkeypatch.setattr(local_token_history, "MAX_FILES", 3)
    for index, name in enumerate(("a", "b", "c", "d", "e")):
        path = tmp_path / f"{name}.jsonl"
        path.write_text("{}\n", encoding="utf-8")
        os.utime(path, (1_000_000 + index, 1_000_000 + index))
    # An older file outside the window is never counted against the cap.
    stale = tmp_path / "0-stale.jsonl"
    stale.write_text("{}\n", encoding="utf-8")
    os.utime(stale, (10, 10))

    kept = [path.name for path in local_token_history._files(tmp_path, "*.jsonl", 500_000.0)]

    assert kept == ["c.jsonl", "d.jsonl", "e.jsonl"]


def _pi_session(tmp_path: Path, usage: dict, model: str = "claude-sonnet-5") -> Path:
    root = tmp_path / "pi" / "sessions"
    root.mkdir(parents=True)
    line = {
        "type": "message",
        "id": "pi-1",
        "message": {
            "role": "assistant",
            "model": model,
            "timestamp": "2026-10-06T12:00:00.000Z",
            "usage": usage,
        },
    }
    (root / "session.jsonl").write_text(json.dumps(line) + "\n", encoding="utf-8")
    return root


@pytest.mark.parametrize(
    "split",
    (
        {"cacheWrite1h": 600},
        {"cache_write_1h": 600},
        {"cttl": {"ephemeral1h": 600}},
        {"cttl": {"ephemeral_1h": 600}},
    ),
)
def test_pi_one_hour_cache_writes_are_a_subset_priced_at_the_one_hour_rate(tmp_path: Path, split: dict) -> None:
    from jrbar import usage_stats

    root = _pi_session(tmp_path, {"input": 100, "output": 10, "cacheRead": 0, "cacheWrite": 1000, **split})

    records = scan_pi_records(root, 0.0)

    # One message: the same tokens in total, 600 of the 1000 writes on the 1h row.
    assert _sums(records) == (100, 0, 1000, 10)
    assert sorted((usage_stats.base_model_key(r[2]), r[2].endswith(usage_stats.ONE_HOUR_WRITE_SUFFIX), r[6]) for r in records) == [
        ("claude-sonnet-5", False, 400),
        ("claude-sonnet-5", True, 600),
    ]
    assert len({record[8] for record in records}) == 2


def test_pi_without_a_one_hour_figure_stays_a_single_record(tmp_path: Path) -> None:
    root = _pi_session(tmp_path, {"input": 100, "output": 10, "cacheRead": 0, "cacheWrite": 1000})

    assert len(scan_pi_records(root, 0.0)) == 1


@pytest.mark.parametrize("bad", (-3, "x", None, True, 5000))
def test_a_bad_pi_one_hour_figure_cannot_exceed_the_writes(tmp_path: Path, bad) -> None:
    root = _pi_session(tmp_path, {"input": 1, "output": 1, "cacheRead": 0, "cacheWrite": 1000, "cacheWrite1h": bad})

    assert _sums(scan_pi_records(root, 0.0))[2] == 1000


def test_a_line_over_the_cap_is_skipped_alone_and_never_held(tmp_path: Path, monkeypatch: pytest.MonkeyPatch) -> None:
    from jrbar import local_token_history as subject

    monkeypatch.setattr(subject, "MAX_LINE_BYTES", 4096)
    path = tmp_path / "session.jsonl"
    good = json.dumps({"type": "message", "n": 1}).encode()
    huge = b'{"type":"message","pad":"' + b"p" * (3 * 1024 * 1024) + b'"}'
    path.write_bytes(good + b"\n" + huge + b"\n" + good.replace(b"1", b"2") + b"\n" + huge)

    assert [row["n"] for row in subject._json_lines(path)] == [1, 2]


def test_a_streamed_session_file_past_64_mib_is_read_but_a_whole_document_is_not(tmp_path: Path) -> None:
    from jrbar import local_token_history as subject

    big = tmp_path / "updates.jsonl"
    with big.open("wb") as handle:
        handle.truncate(65 * 1024 * 1024)
    chat = tmp_path / "chat.json"
    with chat.open("wb") as handle:
        handle.truncate(65 * 1024 * 1024)

    assert list(subject._files(tmp_path, "*.jsonl", 0, subject.MAX_STREAMED_FILE_BYTES)) == [big]
    assert list(subject._files(tmp_path, "*.json", 0)) == []


@pytest.mark.parametrize("bad", [float("nan"), float("inf"), float("-inf")])
def test_nonfinite_counts_do_not_abort_the_history_scan(tmp_path: Path, bad: float) -> None:
    root = tmp_path / "sessions"
    root.mkdir()
    rows = [
        {"type": "message", "id": "bad-time", "message": {"role": "assistant", "timestamp": bad,
            "model": "fixture-model", "usage": {"input": 100}}},
        {"type": "message", "id": "bad-count", "message": {"role": "assistant", "timestamp": 1800000000,
            "model": "fixture-model", "usage": {"input": bad, "output": 20, "cacheWrite": 30, "cacheWrite1h": bad}}},
        {"type": "message", "id": "valid", "message": {"role": "assistant", "timestamp": 1800000001,
            "model": "fixture-model", "usage": {"input": 100, "output": 10}}},
    ]
    (root / "session.jsonl").write_text("\n".join(json.dumps(row) for row in rows) + "\n")
    records = scan_pi_records(root, 0)
    assert len(records) == 2
    assert _sums(records) == (100, 0, 30, 30)
    assert all(record[3] in (1800000000, 1800000001) for record in records)
