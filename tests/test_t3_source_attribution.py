"""Synthetic T3 source identity and graph selection receipts."""

import json
import sqlite3
from datetime import datetime, timezone
from types import SimpleNamespace

import pytest

from jrbar import t3_compat, usage_graph_worker


def test_acp_instance_name_does_not_establish_provider():
    assert t3_compat._normalize_provider("acpRegistry_devin") == "other"


def test_t3_native_history_wins_without_discarding_source_counts():
    epoch = datetime.now(timezone.utc).timestamp()
    native = [("codex", "native", "model", epoch, 10, 0, 0, 5, "native")]
    imported = [
        ("codex", "t3-known", "", epoch, 20, 0, 0, 5, "t3:1"),
        ("claude", "t3-selected", "", epoch, 30, 0, 0, 5, "t3:2"),
        ("other", "t3-unknown", "", epoch, 40, 0, 0, 5, "t3:3"),
    ]
    included, source = usage_graph_worker._select_t3_source_records(
        imported, native, ("codex", "claude"), "complete"
    )
    assert included == [imported[1]]
    assert source["tokens"] == 105
    assert source["sessions"] == 3
    assert source["included_tokens"] == 35
    assert source["included_sessions"] == 1
    assert source["provider_ids"] == ["claude", "codex"]
    assert source["attribution_status"] == "mixed"
    assert source["data_status"] == "available"


def test_missing_t3_counts_are_unavailable_not_zero():
    included, source = usage_graph_worker._select_t3_source_records([], [], ("codex",), "complete")
    assert included == []
    assert source["tokens"] is None and source["sessions"] is None
    assert source["data_status"] == "unavailable"


def test_t3_source_does_not_enable_unselected_provider():
    row = ("claude", "thread", "", 1, 10, 0, 0, 5, "t3:1")
    included, source = usage_graph_worker._select_t3_source_records([row], [], ("codex",), "partial")
    assert included == []
    assert source["tokens"] == 15 and source["included_tokens"] == 0
    assert source["provider_ids"] == ["claude"]
    assert source["data_status"] == "partial"


def test_graph_uses_actual_provider_and_t3_provenance(monkeypatch, tmp_path):
    epoch = datetime.now(timezone.utc).timestamp()
    native = [("codex", "native", "model", epoch, 10, 0, 0, 5, "native")]
    imported = [
        ("codex", "duplicate", "", epoch, 20, 0, 0, 5, "t3:1"),
        ("claude", "supplement", "", epoch, 30, 0, 0, 5, "t3:2"),
        ("other", "unknown", "", epoch, 40, 0, 0, 5, "t3:3"),
    ]
    monkeypatch.setattr(usage_graph_worker, "default_state_dir", lambda: tmp_path)
    monkeypatch.setattr(usage_graph_worker, "scan_usage_all_homes", lambda *_args, **_kwargs:
                        usage_graph_worker.usage_stats.UsageTotals(records=list(native)))
    def scan(_policy, _since, *, coverage_reporter):
        coverage_reporter("complete")
        return imported
    monkeypatch.setattr(usage_graph_worker, "scan_t3_activity_statistics", scan)
    settings = SimpleNamespace(usage_graph_days=7, usage_display_mode="tokens",
                               usage_graph_providers=("codex", "claude", "t3code"))
    policy = t3_compat.project_t3_read_only_policy(
        SimpleNamespace(t3code_enabled=True), activity_statistics_enabled=True
    )
    model, summary = usage_graph_worker._build_payload(settings, t3_policy=policy)
    series = {row["provider_id"]: row for row in model["series"]}
    assert set(series) == {"codex", "claude"}
    assert "source_id" not in series["codex"]
    assert series["claude"]["source_id"] == "t3code"
    assert model["heatmap"].aggregate.totals.tokens == 50
    assert model["source_statistics"][0]["tokens"] == 105
    assert "T3 Code source: 105 observed tokens" in summary
    document = usage_graph_worker._project_graph_document(model, summary, settings.usage_graph_providers)
    assert document["graph"]["providers"] == ["codex", "claude"]
    assert document["graph"]["source_statistics"][0]["included_tokens"] == 35


def test_partial_t3_source_is_retried_with_unchanged_database_stats(monkeypatch):
    calls = []
    monkeypatch.setattr(usage_graph_worker, "_usage_doc_cache_read", lambda: {})
    monkeypatch.setattr(usage_graph_worker, "_corpus_fingerprint", lambda *_args, **_kwargs: {})
    monkeypatch.setattr(usage_graph_worker, "_usage_doc_cache_store", lambda *_args: calls.append("cached"))
    monkeypatch.setattr(usage_graph_worker, "_build_payload", lambda *_args, **_kwargs:
                        ({"source_statistics": [{"source_id": "t3code", "data_status": "partial"}]}, ""))
    settings = SimpleNamespace(usage_graph_days=7, usage_display_mode="tokens", usage_graph_providers=("codex",))
    usage_graph_worker.usage_graph_document(settings, provider_ids=("codex",))
    assert calls == []


def test_failed_empty_read_retries_then_keeps_success_with_unchanged_fingerprint(monkeypatch):
    cache = {"entries": {}}
    outcomes = iter([([], "failed"), ([("other", "thread", "", 1, 10, 0, 0, 5, "turn")], "complete")])
    def payload(*_args, **_kwargs):
        records, coverage = next(outcomes)
        _included, source = usage_graph_worker._select_t3_source_records(records, [], ("codex",), coverage)
        return {"source_statistics": [source]}, ""
    monkeypatch.setattr(usage_graph_worker, "_usage_doc_cache_read", lambda: cache)
    monkeypatch.setattr(usage_graph_worker, "_usage_doc_cache_store", lambda key, fingerprint, document:
                        cache["entries"].update({key: {"fingerprint": fingerprint, "document": document}}))
    monkeypatch.setattr(usage_graph_worker, "_corpus_fingerprint", lambda *_args, **_kwargs: {})
    monkeypatch.setattr(usage_graph_worker, "_build_payload", payload)
    settings = SimpleNamespace(usage_graph_days=7, usage_display_mode="tokens", usage_graph_providers=("codex",))
    first = usage_graph_worker.usage_graph_document(settings, provider_ids=("codex",))
    assert first["graph"]["source_statistics"][0]["data_status"] == "partial"
    second = usage_graph_worker.usage_graph_document(settings, provider_ids=("codex",))
    assert second["graph"]["source_statistics"][0]["tokens"] == 15
    assert usage_graph_worker.usage_graph_document(settings, provider_ids=("codex",)) == second


def test_source_sessions_count_t3_threads_once_across_drivers():
    records = [
        ("codex", "same-thread", "", 1, 10, 0, 0, 5, "turn-1"),
        ("claude", "same-thread", "", 2, 20, 0, 0, 5, "turn-2"),
    ]
    _included, source = usage_graph_worker._select_t3_source_records(records, [], ("codex", "claude"), "complete")
    assert source["sessions"] == 1
    assert source["included_sessions"] == 1


@pytest.mark.parametrize("incomplete", ["turn", "cap", "mixed"])
def test_stable_partial_t3_read_is_cached_until_wal_changes(tmp_path, monkeypatch, incomplete):
    from jrbar import local_token_history
    base = tmp_path / "t3"
    database = base / "userdata" / "statev2.sqlite"
    database.parent.mkdir(parents=True)
    writer = sqlite3.connect(database)
    try:
        writer.execute("PRAGMA journal_mode=WAL")
        writer.execute("PRAGMA wal_autocheckpoint=0")
        writer.execute("CREATE TABLE orchestration_v2_projection_provider_turns "
                       "(provider_turn_id TEXT, thread_id TEXT, completed_at TEXT, payload_json TEXT)")
        def insert(turn):
            usage = {"inputTokens": 10, "outputTokens": 5, "usageStatus": "partial" if incomplete == "turn" else "complete"}
            payload = {"nativeTurnRef": {"driver": "codex"}, "turnTokenUsage": usage}
            writer.execute("INSERT INTO orchestration_v2_projection_provider_turns VALUES (?,?,?,?)",
                           (turn, "thread", datetime.now(timezone.utc).isoformat(), json.dumps(payload)))
            writer.commit()
        insert("turn-1")
        insert("turn-2")
        writer.execute("PRAGMA wal_checkpoint(TRUNCATE)")
        monkeypatch.setattr(usage_graph_worker, "default_state_dir", lambda: tmp_path / "jrbar")
        monkeypatch.setattr(usage_graph_worker, "home_scan_roots", lambda *_args: {})
        monkeypatch.setattr(local_token_history, "roots", lambda **_kwargs: {})
        monkeypatch.setattr(usage_graph_worker, "scan_usage_all_homes", lambda *_args, **_kwargs:
                            usage_graph_worker.usage_stats.UsageTotals())
        if incomplete in {"cap", "mixed"}:
            def scan(_policy, since, *, coverage_reporter):
                records = usage_graph_worker._scan_t3code_v2_records(
                    database, since, maximum_records=1, coverage_reporter=coverage_reporter
                )
                if incomplete == "mixed":
                    coverage_reporter("partial")
                    coverage_reporter("stable_partial")
                return records
            monkeypatch.setattr(usage_graph_worker, "scan_t3_activity_statistics", scan)
        original_build = usage_graph_worker._build_payload
        builds = []
        def build(*args, **kwargs):
            builds.append(1)
            return original_build(*args, **kwargs)
        monkeypatch.setattr(usage_graph_worker, "_build_payload", build)
        policy = t3_compat.project_t3_read_only_policy(
            SimpleNamespace(t3code_enabled=True, t3code_base_dir=str(base)), activity_statistics_enabled=True
        )
        settings = SimpleNamespace(usage_graph_days=7, usage_display_mode="tokens", usage_graph_providers=("codex",))
        first = usage_graph_worker.usage_graph_document(settings, provider_ids=("codex",), t3_policy=policy)
        second = usage_graph_worker.usage_graph_document(settings, provider_ids=("codex",), t3_policy=policy)
        assert first == second
        assert builds == ([1, 1] if incomplete == "mixed" else [1])
        assert second["graph"]["source_statistics"][0]["data_status"] == "partial"
        assert second["graph"]["partial_provider_ids"] == ["codex"]
        assert "_cache_retry_required" not in second["graph"]
        main_fingerprint = usage_graph_worker._file_fingerprint(database)
        insert("turn-3")
        assert usage_graph_worker._file_fingerprint(database) == main_fingerprint
        usage_graph_worker.usage_graph_document(settings, provider_ids=("codex",), t3_policy=policy)
        assert builds == ([1, 1, 1] if incomplete == "mixed" else [1, 1])
    finally:
        writer.close()


def test_t3_wal_commit_invalidates_cached_empty_source(tmp_path, monkeypatch):
    from jrbar import local_token_history
    base = tmp_path / "t3"
    database = base / "userdata" / "statev2.sqlite"
    database.parent.mkdir(parents=True)
    writer = sqlite3.connect(database)
    try:
        writer.execute("PRAGMA journal_mode=WAL")
        writer.execute("PRAGMA wal_autocheckpoint=0")
        writer.execute("CREATE TABLE orchestration_v2_projection_provider_turns "
                       "(provider_turn_id TEXT, thread_id TEXT, completed_at TEXT, payload_json TEXT)")
        writer.commit()
        writer.execute("PRAGMA wal_checkpoint(TRUNCATE)")
        monkeypatch.setattr(usage_graph_worker, "default_state_dir", lambda: tmp_path / "jrbar")
        monkeypatch.setattr(usage_graph_worker, "home_scan_roots", lambda *_args: {})
        monkeypatch.setattr(local_token_history, "roots", lambda **_kwargs: {})
        monkeypatch.setattr(usage_graph_worker, "scan_usage_all_homes", lambda *_args, **_kwargs:
                            usage_graph_worker.usage_stats.UsageTotals())
        policy = t3_compat.project_t3_read_only_policy(
            SimpleNamespace(t3code_enabled=True, t3code_base_dir=str(base)), activity_statistics_enabled=True
        )
        settings = SimpleNamespace(usage_graph_days=7, usage_display_mode="tokens", usage_graph_providers=("codex",))
        first = usage_graph_worker.usage_graph_document(settings, provider_ids=("codex",), t3_policy=policy)
        assert first["graph"]["source_statistics"][0]["tokens"] is None
        unchanged_database = usage_graph_worker._file_fingerprint(database)
        payload = {"nativeTurnRef": {"driver": "codex"}, "turnTokenUsage": {"inputTokens": 10, "outputTokens": 5}}
        writer.execute("INSERT INTO orchestration_v2_projection_provider_turns VALUES (?,?,?,?)",
                       ("turn", "thread", datetime.now(timezone.utc).isoformat(), json.dumps(payload)))
        writer.commit()
        assert usage_graph_worker._file_fingerprint(database) == unchanged_database
        second = usage_graph_worker.usage_graph_document(settings, provider_ids=("codex",), t3_policy=policy)
        assert second["graph"]["source_statistics"][0]["tokens"] == 15
    finally:
        writer.close()


def test_historical_native_driver_does_not_borrow_requested_model(tmp_path):
    database = tmp_path / "statev2.sqlite"
    connection = sqlite3.connect(database)
    connection.execute(
        "CREATE TABLE orchestration_v2_projection_provider_turns "
        "(provider_turn_id TEXT, thread_id TEXT, completed_at TEXT, payload_json TEXT)"
    )
    payload = {
        "nativeTurnRef": {"driver": "claudeAgent", "nativeId": "native-turn", "strength": "strong"},
        "modelSelection": {"instanceId": "codex", "model": "gpt-requested"},
        "turnTokenUsage": {"inputTokens": 10, "outputTokens": 5},
    }
    connection.execute(
        "INSERT INTO orchestration_v2_projection_provider_turns VALUES (?,?,?,?)",
        ("turn", "thread", "2026-10-13T10:00:00Z", json.dumps(payload)),
    )
    connection.commit()
    connection.close()
    records = usage_graph_worker._scan_t3code_v2_records(database, 0)
    assert records[0][0] == "claude"
    assert records[0][2] == ""
    assert usage_graph_worker.usage_stats.rates_for_record(records[0][0], records[0][2]) is None
