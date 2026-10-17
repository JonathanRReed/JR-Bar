"""usage_graph_worker: the usage graph is built from the corpus and cached honestly.

The live failure this file grew out of (seen 2026-08-26): the Overview
chart showed "No activity in this range" with a degenerate axis for a
whole cold year scan. The graph is now one document the daemon answers
for, so these tests pin what goes into it: the scans, the T3 opt-in,
the settings snapshot and the persisted answer cache's keys.
"""

from __future__ import annotations

import json
import os
import sqlite3
from datetime import datetime, timedelta
from pathlib import Path
from types import SimpleNamespace

import pytest

from jrbar import usage_graph_worker
from jrbar.t3_compat import project_t3_read_only_policy


@pytest.fixture(autouse=True)
def _isolate_doc_cache(tmp_path, monkeypatch):
    """Every test gets a private persisted doc cache.

    The session-wide sandbox state dir would otherwise leak a document
    stored by one test (e.g. a refresh with a stubbed ``_build_payload``)
    into a later test whose meta key and fingerprint happen to match.
    """
    monkeypatch.setattr(
        usage_graph_worker,
        "_usage_doc_cache_path",
        lambda: tmp_path / "usage-graph-doc-cache.json",
    )


def make_target(days=7, mode="tokens", providers=("claude", "codex")):
    target = SimpleNamespace()
    target.settings = SimpleNamespace(
        usage_graph_days=days,
        usage_display_mode=mode,
        usage_graph_providers=tuple(providers),
    )
    return target


def test_scan_period_start_is_pinned_to_injected_calendar_day() -> None:
    now = datetime(2026, 8, 29, 23, 59, 59)

    assert usage_graph_worker._period_start(7, now=now) == datetime(
        2026,
        8,
        23,
    )


@pytest.mark.parametrize("filename", ["opencode.db", "usage?#% space.db"])
def test_scan_opencode_records_parses_messages(tmp_path, filename):
    db_file = tmp_path / filename
    con = sqlite3.connect(db_file)
    con.execute("CREATE TABLE message (id TEXT, session_id TEXT, time_created INT, data TEXT)")
    msg_data = {
        "tokens": {"input": 1000, "output": 200, "cache": {"read": 50, "write": 10}},
        "model": "gemini-flash"
    }
    con.execute("INSERT INTO message VALUES ('msg1', 'ses1', 1700000000000, ?)", (json.dumps(msg_data),))
    con.commit()
    con.close()

    records = usage_graph_worker._scan_opencode_records(db_file, 1690000000.0)
    assert len(records) == 1
    assert records[0][0] == "opencode"
    assert records[0][1] == "ses1"
    assert records[0][4] == 1000
    assert records[0][7] == 200


def test_activity_does_not_touch_deselected_provider_sources(monkeypatch):
    settings = make_target(mode="tokens", providers=("devin",)).settings

    def forbidden(*_args, **_kwargs):
        raise AssertionError("a deselected provider source was touched")

    monkeypatch.setattr(usage_graph_worker.usage_stats, "_provider_inventory", forbidden)
    monkeypatch.setattr(usage_graph_worker, "_scan_opencode_records", forbidden)

    model, _summary = usage_graph_worker._build_payload(settings)

    assert model["series"] == ()
    assert tuple(model["heatmap"].providers) == ("devin",)


def test_scan_t3code_records_parses_activities(tmp_path):
    db_file = tmp_path / "state.sqlite"
    con = sqlite3.connect(db_file)
    con.execute("CREATE TABLE projection_thread_activities (activity_id TEXT, thread_id TEXT, kind TEXT, created_at TEXT, payload_json TEXT)")
    act_data = {
        "usage": {"total_tokens": 3500, "input_tokens": 3000, "output_tokens": 500}
    }
    con.execute("INSERT INTO projection_thread_activities VALUES ('act1', 'th1', 'task.completed', '2026-03-20T10:00:00Z', ?)", (json.dumps(act_data),))
    con.commit()
    con.close()

    records = usage_graph_worker._scan_t3code_records(db_file, 1700000000.0)
    assert len(records) == 1
    assert records[0][0] == "other"
    assert records[0][1] == "th1"
    assert records[0][4] == 3000
    assert records[0][7] == 500


def test_t3_activity_scan_is_bounded_to_the_newest_records(tmp_path) -> None:
    db_file = tmp_path / "state.sqlite"
    connection = sqlite3.connect(db_file)
    connection.execute(
        "CREATE TABLE projection_thread_activities "
        "(activity_id TEXT, thread_id TEXT, kind TEXT, created_at TEXT, payload_json TEXT)"
    )
    payload = json.dumps(
        {"usage": {"total_tokens": 10, "input_tokens": 8, "output_tokens": 2}}
    )
    connection.executemany(
        "INSERT INTO projection_thread_activities VALUES (?, ?, ?, ?, ?)",
        (
            ("old", "thread-old", "task.completed", "2026-03-20T10:00:00Z", payload),
            ("middle", "thread-middle", "task.completed", "2026-03-20T11:00:00Z", payload),
            ("new", "thread-new", "task.completed", "2026-03-20T12:00:00Z", payload),
        ),
    )
    connection.commit()
    connection.close()

    records = usage_graph_worker._scan_t3code_records(
        db_file,
        1_700_000_000.0,
        maximum_records=2,
    )

    assert [record[1] for record in records] == ["thread-new", "thread-middle"]


def test_t3_activity_scan_rejects_oversized_sqlite_values_before_json_decode(
    tmp_path,
    monkeypatch,
) -> None:
    db_file = tmp_path / "state.sqlite"
    connection = sqlite3.connect(db_file)
    connection.execute(
        "CREATE TABLE projection_thread_activities "
        "(activity_id TEXT, thread_id TEXT, kind TEXT, created_at TEXT, payload_json TEXT)"
    )
    oversized = json.dumps(
        {
            "usage": {"total_tokens": 10},
            "padding": "x" * 262_189,
        }
    )
    connection.execute(
        "INSERT INTO projection_thread_activities VALUES (?, ?, ?, ?, ?)",
        ("large", "thread-large", "task.completed", "2026-03-20T12:00:00Z", oversized),
    )
    connection.commit()
    connection.close()
    decoded = []
    real_loads = json.loads

    def bounded_loads(value):
        decoded.append(len(value.encode("utf-8")))
        return real_loads(value)

    monkeypatch.setattr(usage_graph_worker.json, "loads", bounded_loads)

    records = usage_graph_worker._scan_t3code_records(db_file, 1_700_000_000.0)

    assert records == []
    assert decoded == []


@pytest.mark.parametrize(
    ("fixture_kind", "expected_status"),
    (("valid", "complete"), ("oversized", "partial"), ("missing", "missing")),
)
def test_t3_activity_scan_reports_coverage_status(
    tmp_path,
    fixture_kind,
    expected_status,
) -> None:
    db_file = tmp_path / "state.sqlite"
    if fixture_kind != "missing":
        connection = sqlite3.connect(db_file)
        connection.execute(
            "CREATE TABLE projection_thread_activities "
            "(activity_id TEXT, thread_id TEXT, kind TEXT, created_at TEXT, payload_json TEXT)"
        )
        payload = json.dumps(
            {
                "usage": {"total_tokens": 10},
                "padding": "x" * (262_189 if fixture_kind == "oversized" else 0),
            }
        )
        connection.execute(
            "INSERT INTO projection_thread_activities VALUES (?, ?, ?, ?, ?)",
            ("activity", "thread", "task.completed", "2026-03-20T12:00:00Z", payload),
        )
        connection.commit()
        connection.close()
    statuses = []

    usage_graph_worker._scan_t3code_records(
        db_file,
        1_700_000_000.0,
        coverage_reporter=statuses.append,
    )

    assert statuses == [expected_status]


def test_t3_activity_scan_rejects_oversized_identifier_before_returning_row(
    tmp_path,
) -> None:
    db_file = tmp_path / "state.sqlite"
    connection = sqlite3.connect(db_file)
    connection.execute(
        "CREATE TABLE projection_thread_activities "
        "(activity_id TEXT, thread_id TEXT, kind TEXT, created_at TEXT, payload_json TEXT)"
    )
    connection.execute(
        "INSERT INTO projection_thread_activities VALUES (?, ?, ?, ?, ?)",
        (
            "activity",
            "x" * 262_189,
            "task.completed",
            "2026-03-20T12:00:00Z",
            json.dumps({"usage": {"total_tokens": 10}}),
        ),
    )
    connection.commit()
    connection.close()

    records = usage_graph_worker._scan_t3code_records(
        db_file,
        1_700_000_000.0,
    )

    assert records == []


def test_t3_activity_scan_sets_sqlite_allocation_limit_before_query(
    tmp_path,
    monkeypatch,
) -> None:
    db_file = tmp_path / "state.sqlite"
    connection = sqlite3.connect(db_file)
    connection.execute(
        "CREATE TABLE projection_thread_activities "
        "(activity_id TEXT, thread_id TEXT, kind TEXT, created_at TEXT, payload_json TEXT)"
    )
    connection.commit()
    connection.close()

    class LimitedConnection:
        def __init__(self, path):
            self._connection = sqlite3.connect(f"file:{path}?mode=ro", uri=True)
            self._limited = False

        def setlimit(self, category, limit):
            assert category == sqlite3.SQLITE_LIMIT_LENGTH
            assert limit == usage_graph_worker.T3_SQLITE_MAX_VALUE_BYTES
            self._limited = True
            return self._connection.setlimit(category, limit)

        def execute(self, *args, **kwargs):
            assert self._limited, "SQLite length limit must precede untrusted queries"
            return self._connection.execute(*args, **kwargs)

        def set_progress_handler(self, *args, **kwargs):
            return self._connection.set_progress_handler(*args, **kwargs)

        def close(self):
            return self._connection.close()

    monkeypatch.setattr(
        usage_graph_worker,
        "_open_read_only",
        lambda path: LimitedConnection(path),
    )

    assert usage_graph_worker._scan_t3code_records(db_file, 0.0) == []


def test_t3_activity_scan_stops_before_aggregate_payload_budget(tmp_path) -> None:
    db_file = tmp_path / "state.sqlite"
    connection = sqlite3.connect(db_file)
    connection.execute(
        "CREATE TABLE projection_thread_activities "
        "(activity_id TEXT, thread_id TEXT, kind TEXT, created_at TEXT, payload_json TEXT)"
    )
    payload = json.dumps(
        {"usage": {"total_tokens": 10}, "padding": "x" * 900}
    )
    connection.executemany(
        "INSERT INTO projection_thread_activities VALUES (?, ?, ?, ?, ?)",
        (
            ("new", "thread-new", "task.completed", "2026-03-20T12:00:00Z", payload),
            ("old", "thread-old", "task.completed", "2026-03-20T11:00:00Z", payload),
        ),
    )
    connection.commit()
    connection.close()

    records = usage_graph_worker._scan_t3code_records(
        db_file,
        1_700_000_000.0,
        maximum_payload_bytes=2_000,
        maximum_total_payload_bytes=1_100,
    )

    assert [record[1] for record in records] == ["thread-new"]


def test_t3_activity_scan_aborts_real_query_when_progress_budget_expires(
    tmp_path,
    monkeypatch,
) -> None:
    db_file = tmp_path / "state.sqlite"
    connection = sqlite3.connect(db_file)
    connection.execute(
        "CREATE TABLE projection_thread_activities "
        "(activity_id TEXT, thread_id TEXT, kind TEXT, created_at TEXT, payload_json TEXT)"
    )
    payload = json.dumps({"usage": {"total_tokens": 10}})
    connection.executemany(
        "INSERT INTO projection_thread_activities VALUES (?, ?, ?, ?, ?)",
        (
            (
                f"activity-{index}",
                f"thread-{index}",
                "task.completed",
                "2026-03-20T12:00:00Z",
                payload,
            )
            for index in range(2_000)
        ),
    )
    connection.commit()
    connection.close()
    clock_values = iter((0.0, 1.0))

    def expired_clock():
        return next(clock_values, 1.0)

    def forbidden_decode(_value):
        raise AssertionError("an expired query must not decode payloads")

    monkeypatch.setattr(usage_graph_worker.json, "loads", forbidden_decode)

    records = usage_graph_worker._scan_t3code_records(
        db_file,
        1_700_000_000.0,
        monotonic=expired_clock,
    )

    assert records == []


def test_t3_activity_scan_does_not_sum_cumulative_progress_rows(tmp_path) -> None:
    db_file = tmp_path / "state.sqlite"
    connection = sqlite3.connect(db_file)
    connection.execute(
        "CREATE TABLE projection_thread_activities "
        "(activity_id TEXT, thread_id TEXT, kind TEXT, created_at TEXT, payload_json TEXT)"
    )
    connection.executemany(
        "INSERT INTO projection_thread_activities VALUES (?, ?, ?, ?, ?)",
        (
            (
                "progress",
                "thread-1",
                "task.progress",
                "2026-03-20T10:00:00Z",
                json.dumps({"taskId": "task-1", "usage": {"total_tokens": 90}}),
            ),
            (
                "completed",
                "thread-1",
                "task.completed",
                "2026-03-20T10:01:00Z",
                json.dumps({"taskId": "task-1", "usage": {"total_tokens": 100}}),
            ),
        ),
    )
    connection.commit()
    connection.close()

    records = usage_graph_worker._scan_t3code_records(
        db_file,
        1_700_000_000.0,
    )

    assert len(records) == 1
    assert records[0][4] == 100


def test_t3_activity_statistics_do_not_resolve_a_path_without_opt_in() -> None:
    policy = project_t3_read_only_policy(
        SimpleNamespace(t3code_enabled=True, t3code_base_dir="/configured/t3")
    )
    calls = []

    def resolve_path(_base_dir):
        calls.append("path")
        raise AssertionError("T3 path must not be resolved")

    def scan(_path, _since_epoch):
        calls.append("scan")
        raise AssertionError("T3 SQLite must not be scanned")

    records = usage_graph_worker.scan_t3_activity_statistics(
        policy,
        1_700_000_000.0,
        path_resolver=resolve_path,
        scanner=scan,
    )

    assert records == []
    assert calls == []


def test_usage_graph_does_not_scan_t3_for_observability_only(
    monkeypatch,
) -> None:
    policy = project_t3_read_only_policy(
        SimpleNamespace(t3code_enabled=True, t3code_base_dir="/configured/t3")
    )
    calls = []
    monkeypatch.setattr(
        usage_graph_worker.usage_stats,
        "scan_usage",
        lambda *_args, **_kwargs: usage_graph_worker.usage_stats.UsageTotals(),
    )
    monkeypatch.setattr(usage_graph_worker, "_scan_opencode_records", lambda *_args: [])
    monkeypatch.setattr(usage_graph_worker, "_scan_antigravity_records", lambda *_args: [])

    def scan_t3(*_args, **_kwargs):
        calls.append("scan")
        return []

    monkeypatch.setattr(usage_graph_worker, "scan_t3_activity_statistics", scan_t3)

    usage_graph_worker._build_payload(make_target().settings, t3_policy=policy)

    assert calls == []


def test_usage_graph_document_forwards_the_explicit_t3_policy(monkeypatch) -> None:
    policy = project_t3_read_only_policy(
        SimpleNamespace(t3code_enabled=True, t3code_base_dir="/configured/t3"),
        activity_statistics_enabled=True,
    )
    seen = []

    def build(settings, *, t3_policy=None):
        seen.append(t3_policy)
        return _document_payload(settings)

    monkeypatch.setattr(usage_graph_worker, "_build_payload", build)

    usage_graph_worker.usage_graph_document(make_target().settings, t3_policy=policy)

    assert seen == [policy]


def test_t3_activity_opt_in_change_rebuilds_the_usage_graph_document(monkeypatch) -> None:
    settings = make_target().settings
    integration = SimpleNamespace(
        t3code_enabled=True,
        t3code_base_dir="/configured/t3",
    )
    observability_only = project_t3_read_only_policy(integration)
    with_statistics = project_t3_read_only_policy(
        integration,
        activity_statistics_enabled=True,
    )
    builds = []

    def build(settings, *, t3_policy=None):
        builds.append(t3_policy)
        return _document_payload(settings)

    monkeypatch.setattr(usage_graph_worker, "_build_payload", build)

    usage_graph_worker.usage_graph_document(settings, t3_policy=observability_only)
    usage_graph_worker.usage_graph_document(settings, t3_policy=with_statistics)
    usage_graph_worker.usage_graph_document(settings, t3_policy=with_statistics)

    assert builds == [observability_only, with_statistics]


def test_usage_graph_document_uses_one_settings_snapshot_for_key_and_payload(
    monkeypatch,
) -> None:
    """A settings update cannot split the cache key from the chart payload."""

    class FlippingSettings:
        def __init__(self):
            self._values = {
                "usage_graph_days": (7, 365),
                "usage_display_mode": ("tokens", "sessions"),
                "usage_graph_providers": (("claude", "codex"), ("grok",)),
            }

        def _next(self, name):
            current, next_value = self._values[name]
            self._values[name] = (next_value, next_value)
            return current

        @property
        def usage_graph_days(self):
            return self._next("usage_graph_days")

        @property
        def usage_display_mode(self):
            return self._next("usage_display_mode")

        @property
        def usage_graph_providers(self):
            return self._next("usage_graph_providers")

    built_settings = []

    def build(settings, *, t3_policy=None):
        built_settings.append(settings)
        return _document_payload(settings)

    monkeypatch.setattr(usage_graph_worker, "_build_payload", build)
    monkeypatch.setattr(usage_graph_worker, "_agent_histories_found", lambda: ())

    document = usage_graph_worker.usage_graph_document(FlippingSettings())

    assert built_settings[0].usage_graph_providers == ("claude", "codex")
    assert built_settings[0].usage_graph_days == 7
    assert built_settings[0].usage_display_mode == "tokens"
    assert document["graph"]["days"] == 7
    assert document["graph"]["metric"] == "tokens"


def test_cost_graph_discloses_api_equivalent_semantics(monkeypatch) -> None:
    settings = make_target(mode="cost").settings
    monkeypatch.setattr(
        usage_graph_worker.usage_stats,
        "scan_usage",
        lambda *_args, **_kwargs: usage_graph_worker.usage_stats.UsageTotals(),
    )
    monkeypatch.setattr(usage_graph_worker, "_scan_opencode_records", lambda *_args: [])
    monkeypatch.setattr(usage_graph_worker, "_scan_antigravity_records", lambda *_args: [])

    model, summary = usage_graph_worker._build_payload(settings)

    assert model["cost_semantics"] == "api_equivalent_estimate"
    assert summary is not None
    assert "API-equivalent estimate, not subscription spend" in summary


@pytest.mark.parametrize("mode", ["tokens", "cost", "sessions", "percent"])
def test_activity_selection_applies_to_chart_heatmap_and_summary(monkeypatch, tmp_path, mode):
    from jrbar import session_history, usage_percent_history
    from jrbar.private_io import atomic_private_write

    now = datetime.now()
    selected = ("devin",) if mode in ("sessions", "percent") else ("claude",)
    records = [
        ("claude", "c1", "claude-opus-4", now.timestamp(), 10, 2, 3, 4, "c1"),
        ("codex", "x1", "gpt-5", now.timestamp(), 900, 0, 0, 100, "x1"),
    ]
    monkeypatch.setattr(
        usage_graph_worker.usage_stats, "scan_usage",
        lambda *_args, **_kwargs: usage_graph_worker.usage_stats.UsageTotals(records=list(records)),
    )
    monkeypatch.setattr(
        usage_graph_worker, "_scan_opencode_records",
        lambda *_args: [("opencode", "o1", "model", now.timestamp(), 500, 0, 0, 0, "o1")],
    )
    monkeypatch.setattr(usage_graph_worker, "_scan_antigravity_records", lambda *_args: [])
    monkeypatch.setattr(session_history, "ledger_session_days", lambda *_args, **_kwargs: {
        "devin": {now.date().isoformat(): 2}, "grok": {now.date().isoformat(): 500},
    })
    history = tmp_path / "percent.jsonl"
    atomic_private_write(history, "".join(json.dumps({
        "provider_id": provider, "lane_id": "weekly", "remaining_percent": 40,
        "observed_at_epoch": now.timestamp(),
    }) + "\n" for provider in ("devin", "grok")))
    monkeypatch.setattr(usage_percent_history, "default_percent_history_path", lambda: history)

    model, summary = usage_graph_worker._build_payload(make_target(mode=mode, providers=selected).settings)

    assert tuple(series["provider_id"] for series in model["series"]) == selected
    assert tuple(model["heatmap"].providers) == selected
    assert "Codex" not in summary and "OpenCode" not in summary and "Grok" not in summary
    if mode in ("tokens", "cost"):
        assert ("Claude 19" if mode == "tokens" else "Claude estimated $") in summary
        assert "1 sessions" in summary
        assert model["heatmap"].aggregate.totals.tokens == 19
    elif mode == "sessions":
        assert "Devin 2 session-days" in summary


def test_antigravity_steps_contribute_sessions_but_not_measured_token_heatmap(monkeypatch):
    from jrbar import session_history

    now = datetime.now().timestamp()
    monkeypatch.setattr(usage_graph_worker.usage_stats, "scan_usage", lambda *_args, **_kwargs:
                        usage_graph_worker.usage_stats.UsageTotals())
    monkeypatch.setattr(usage_graph_worker, "_scan_opencode_records", lambda *_args: [])
    monkeypatch.setattr(usage_graph_worker, "_scan_antigravity_records", lambda *_args: [
        ("antigravity", "a1", "gemini", now, 0, 0, 0, 0, "a1"),
        ("antigravity", "a2", "gemini", now, 0, 0, 0, 0, "a2"),
    ])
    monkeypatch.setattr(session_history, "ledger_session_days", lambda *_args, **_kwargs: {})

    model, summary = usage_graph_worker._build_payload(
        make_target(mode="sessions", providers=("antigravity",)).settings,
    )

    assert len(model["series"]) == 1
    assert sum(model["series"][0]["values"]) == 2
    assert "Antigravity 2 session-days" in summary
    assert model["heatmap"].providers["antigravity"].data_status == "unavailable"


@pytest.mark.parametrize("selected, partial", [("codex", True), ("claude", False)])
def test_activity_discloses_partial_selected_history(monkeypatch, selected, partial):
    stats = usage_graph_worker.usage_stats
    coverage = stats.UsageSourceCoverage(
        provider_id="codex", status=stats.UsageSourceStatus.PARTIAL,
        root_present=True, root_walked=True, files_discovered=2,
        files_read=1, cache_hits=0, malformed_lines=0, unreadable_files=0,
        skipped_symlinks=0, duplicate_physical_files=0, truncated_files=1,
    )
    monkeypatch.setattr(stats, "scan_usage", lambda *_args, **_kwargs:
                        stats.UsageTotals(source_coverage={"codex": coverage}))
    monkeypatch.setattr(usage_graph_worker, "_scan_opencode_records", lambda *_args: [])

    _model, summary = usage_graph_worker._build_payload(make_target(providers=(selected,)).settings)

    assert ("Partial local history: Codex" in summary) is partial


def test_explicit_t3_statistics_choice_is_shared_by_chart_and_heatmap(monkeypatch):
    monkeypatch.setattr(usage_graph_worker.usage_stats, "scan_usage", lambda *_args, **_kwargs:
                        usage_graph_worker.usage_stats.UsageTotals())
    monkeypatch.setattr(usage_graph_worker, "_scan_opencode_records", lambda *_args: [])
    def scan_t3(*_args, coverage_reporter=None, **_kwargs):
        coverage_reporter("complete")
        return [
            ("t3code", "t1", "model", datetime.now().timestamp(), 10, 0, 0, 5, "t1"),
        ]

    monkeypatch.setattr(usage_graph_worker, "scan_t3_activity_statistics", scan_t3)
    policy = project_t3_read_only_policy(
        SimpleNamespace(t3code_enabled=True), activity_statistics_enabled=True,
    )

    model, summary = usage_graph_worker._build_payload(make_target().settings, t3_policy=policy)

    assert model["series"] == ()
    assert "t3code" not in model["heatmap"].providers
    assert model["source_statistics"][0]["tokens"] == 15
    assert model["source_statistics"][0]["included_tokens"] == 0
    assert "T3 Code source: 15 observed tokens" in summary


@pytest.mark.parametrize("coverage_status", ("partial", "missing"))
def test_t3_incomplete_coverage_is_exposed_in_model_and_summary(
    monkeypatch,
    coverage_status,
):
    monkeypatch.setattr(
        usage_graph_worker.usage_stats,
        "scan_usage",
        lambda *_args, **_kwargs: usage_graph_worker.usage_stats.UsageTotals(),
    )
    monkeypatch.setattr(usage_graph_worker, "_scan_opencode_records", lambda *_args: [])

    def partial_scan(_policy, _since_epoch, *, coverage_reporter=None):
        coverage_reporter(coverage_status)
        return []

    monkeypatch.setattr(
        usage_graph_worker,
        "scan_t3_activity_statistics",
        partial_scan,
    )
    policy = project_t3_read_only_policy(
        SimpleNamespace(t3code_enabled=True),
        activity_statistics_enabled=True,
    )

    model, summary = usage_graph_worker._build_payload(
        make_target(providers=("codex",)).settings,
        t3_policy=policy,
    )

    assert model["partial_provider_ids"] == ()
    expected = "partial" if coverage_status == "partial" else "unavailable"
    assert model["source_statistics"][0]["data_status"] == expected
    assert model["source_statistics"][0]["tokens"] is None
    assert "T3 Code source " + expected in summary


@pytest.mark.parametrize("folder", ["normal", "usage?#% space"])
def test_scan_antigravity_records_parses_summaries(tmp_path, folder):
    tmp_path = tmp_path / folder
    import sqlite3
    agy_dir = tmp_path / "antigravity-cli"
    agy_dir.mkdir(parents=True)
    db_file = agy_dir / "conversation_summaries.db"
    con = sqlite3.connect(db_file)
    con.execute("CREATE TABLE conversation_summaries (conversation_id TEXT, step_count INT, last_modified_time TEXT)")
    con.execute("INSERT INTO conversation_summaries VALUES ('conv1', 10, '2026-09-01T12:00:00')")
    con.commit()
    con.close()

    records = usage_graph_worker._scan_antigravity_records(tmp_path, 1700000000.0)
    assert len(records) == 1
    assert records[0][0] == "antigravity"
    assert records[0][1] == "conv1"
    # Step counts establish activity, not a measured token count.
    assert sum(records[0][4:8]) == 0


# --- usage_graph_document: the socket reply ------------------------------
#
# The command's contract has two edges the chart view never saw before:
# the heatmap rides the reply as a frozen dataclass the JSON encoder
# cannot carry, and per-request overrides must validate rather than
# silently substitute a range the caller did not ask for.


def _document_heatmap():
    from datetime import date
    from types import MappingProxyType

    from jrbar.usage_heatmap import (
        HeatmapCell,
        HeatmapTotals,
        ProviderHeatmap,
        UsageHeatmap,
    )

    days = (date(2026, 9, 16), date(2026, 9, 17))
    cells = (
        HeatmapCell(
            day=days[0], tokens=100, sessions=2, intensity=1,
            color="#DDD6FE", accessibility_label="2026-09-16: 100 tokens",
        ),
        HeatmapCell(
            day=days[1], tokens=0, sessions=0, intensity=0,
            color="#E5E7EB", accessibility_label="2026-09-17: quiet",
        ),
    )
    provider = ProviderHeatmap(
        provider_id="claude", cells=cells,
        totals=HeatmapTotals(tokens=100, sessions=2),
        data_status="available",
    )
    return UsageHeatmap(
        days=days,
        providers=MappingProxyType({"claude": provider}),
        aggregate=provider,
        timezone="America/Los_Angeles",
    )


def _document_payload(settings, t3_policy=None):
    return (
        {
            "days": int(settings.usage_graph_days),
            "period_label": "Last 7 days",
            "metric": str(settings.usage_display_mode),
            "labels": ("09/16", ""),
            "series": (
                {"provider_id": "claude", "values": (100, 0)},
            ),
            "scale_max": 100.0,
            "heatmap": _document_heatmap(),
            "partial_provider_ids": (),
        },
        "Last 7 days: Claude 100 · 2 sessions",
    )


def test_usage_graph_document_serializes_for_the_socket(monkeypatch):
    monkeypatch.setattr(usage_graph_worker, "_build_payload", _document_payload)

    document = usage_graph_worker.usage_graph_document(make_target().settings)

    # The socket contract: json.dumps is the whole reply path — a stray
    # dataclass or date would degrade the document to {"repr": ...}.
    encoded = json.loads(json.dumps(document))
    graph = encoded["graph"]
    assert graph["providers"] == ["claude", "codex"]
    assert graph["series"] == [{"provider_id": "claude", "values": [100, 0]}]
    heatmap = graph["heatmap"]
    assert heatmap["days"] == ["2026-09-16", "2026-09-17"]
    assert heatmap["providers"]["claude"]["cells"][0]["day"] == "2026-09-16"
    assert heatmap["providers"]["claude"]["totals"] == {"tokens": 100, "sessions": 2}
    assert heatmap["aggregate"]["data_status"] == "available"
    assert encoded["summary"] == "Last 7 days: Claude 100 · 2 sessions"


def test_usage_graph_document_applies_per_request_overrides(monkeypatch):
    seen = {}

    def payload(settings, t3_policy=None):
        seen["days"] = settings.usage_graph_days
        seen["metric"] = settings.usage_display_mode
        seen["providers"] = settings.usage_graph_providers
        return _document_payload(settings)

    monkeypatch.setattr(usage_graph_worker, "_build_payload", payload)
    settings = make_target(days=7, mode="tokens", providers=("claude",)).settings

    document = usage_graph_worker.usage_graph_document(
        settings, days=30.0, metric="sessions", provider_ids=("codex", "t3code"),
    )

    assert seen == {"days": 30, "metric": "sessions",
                    "providers": ("codex", "t3code")}
    # The override is echoed, not the stored set.
    assert document["graph"]["providers"] == ["codex"]


def test_usage_graph_document_defaults_to_stored_settings(monkeypatch):
    seen = {}

    def payload(settings, t3_policy=None):
        seen["days"] = settings.usage_graph_days
        seen["metric"] = settings.usage_display_mode
        return _document_payload(settings)

    monkeypatch.setattr(usage_graph_worker, "_build_payload", payload)
    usage_graph_worker.usage_graph_document(
        make_target(days=90, mode="cost").settings,
    )
    assert seen == {"days": 90, "metric": "cost"}


def test_usage_graph_document_rejects_invalid_overrides(monkeypatch):
    monkeypatch.setattr(usage_graph_worker, "_build_payload", _document_payload)
    settings = make_target().settings

    with pytest.raises(ValueError, match="7, 30, 90, 365"):
        usage_graph_worker.usage_graph_document(settings, days=14)
    with pytest.raises(ValueError, match="tokens, cost"):
        usage_graph_worker.usage_graph_document(settings, metric="flops")
    with pytest.raises(ValueError, match="nonempty"):
        usage_graph_worker.usage_graph_document(settings, provider_ids=())
    with pytest.raises(ValueError, match="nonempty"):
        usage_graph_worker.usage_graph_document(
            make_target(providers=()).settings,
        )


def test_usage_graph_document_rejects_wrong_typed_overrides(monkeypatch):
    """A string ``days`` or a scalar ``providers`` is an invalid request,
    not a reason to silently substitute the stored settings -- the same
    contract ``invalid_args`` makes of wrong values."""
    monkeypatch.setattr(usage_graph_worker, "_build_payload", _document_payload)
    settings = make_target().settings

    with pytest.raises(ValueError, match="7, 30, 90, 365"):
        usage_graph_worker.usage_graph_document(settings, days="30")
    with pytest.raises(ValueError, match="7, 30, 90, 365"):
        usage_graph_worker.usage_graph_document(settings, days=30.5)
    with pytest.raises(ValueError, match="7, 30, 90, 365"):
        usage_graph_worker.usage_graph_document(settings, days=True)
    with pytest.raises(ValueError, match="tokens, cost"):
        usage_graph_worker.usage_graph_document(settings, metric=42)
    with pytest.raises(ValueError, match="nonempty"):
        usage_graph_worker.usage_graph_document(settings, provider_ids="claude")
    with pytest.raises(ValueError, match="nonempty"):
        usage_graph_worker.usage_graph_document(
            settings, provider_ids=("claude", 42))
    # And the honest types still pass: an integral float day and a
    # provider list ride through untouched.
    document = usage_graph_worker.usage_graph_document(
        settings, days=30.0, provider_ids=["claude", "codex"])
    assert document["graph"]["providers"] == ["claude", "codex"]


def test_usage_graph_document_keeps_partial_and_cost_disclosures(monkeypatch):
    def payload(settings, t3_policy=None):
        model, summary = _document_payload(settings)
        model["partial_provider_ids"] = ("t3code",)
        model["cost_semantics"] = "api_equivalent_estimate"
        return model, summary + " · Partial local history: T3 Code"

    monkeypatch.setattr(usage_graph_worker, "_build_payload", payload)
    document = usage_graph_worker.usage_graph_document(
        make_target(mode="cost").settings,
    )
    graph = document["graph"]
    assert graph["partial_provider_ids"] == ["t3code"]
    assert graph["cost_semantics"] == "api_equivalent_estimate"
    assert "Partial local history" in document["summary"]


# --- usage_graph_document: the persisted answer cache --------------------
#
# A cached reply must be the same document a fresh scan would produce --
# the fingerprint covers every input file set, the meta key covers the
# resolved request, the day, and the timezone. Any change to any of them
# pays the scan again.


def _fresh_cache(monkeypatch, tmp_path):
    """Point the doc cache at a per-test file under the sandbox."""
    monkeypatch.setattr(
        usage_graph_worker,
        "_usage_doc_cache_path",
        lambda: tmp_path / "usage-graph-doc-cache.json",
    )


def test_usage_graph_document_serves_an_unchanged_corpus_from_cache(
    monkeypatch, tmp_path
):
    _fresh_cache(monkeypatch, tmp_path)
    calls = []

    def payload(settings, t3_policy=None):
        calls.append(1)
        return _document_payload(settings)

    monkeypatch.setattr(usage_graph_worker, "_build_payload", payload)
    settings = make_target().settings

    first = usage_graph_worker.usage_graph_document(settings)
    second = usage_graph_worker.usage_graph_document(settings)

    assert calls == [1]
    assert second == first
    # The stored document is what the socket would have sent: the same
    # JSON projection, not the pre-projection model with dataclasses in.
    json.loads(json.dumps(second))


def test_usage_graph_document_rescans_when_the_corpus_changes(
    monkeypatch, tmp_path
):
    _fresh_cache(monkeypatch, tmp_path)
    calls = []
    fingerprints = [{"claude": {"files": 1}}, {"claude": {"files": 2}}]

    def payload(settings, t3_policy=None):
        calls.append(1)
        return _document_payload(settings)

    monkeypatch.setattr(usage_graph_worker, "_build_payload", payload)
    monkeypatch.setattr(
        usage_graph_worker,
        "_corpus_fingerprint",
        lambda *args, **kwargs: fingerprints.pop(0),
    )
    settings = make_target().settings

    usage_graph_worker.usage_graph_document(settings)
    second = usage_graph_worker.usage_graph_document(settings)

    assert len(calls) == 2
    assert second["graph"]["metric"] == "tokens"


def test_usage_graph_document_rescans_when_the_request_changes(
    monkeypatch, tmp_path
):
    _fresh_cache(monkeypatch, tmp_path)
    calls = []
    monkeypatch.setattr(
        usage_graph_worker,
        "_build_payload",
        lambda settings, t3_policy=None: (calls.append(1) or _document_payload(settings)),
    )
    settings = make_target().settings

    usage_graph_worker.usage_graph_document(settings)
    usage_graph_worker.usage_graph_document(settings, days=30)

    assert len(calls) == 2


def test_usage_graph_document_survives_a_corrupt_cache(monkeypatch, tmp_path):
    cache_file = tmp_path / "usage-graph-doc-cache.json"
    cache_file.write_text("{not json")
    _fresh_cache(monkeypatch, tmp_path)
    calls = []
    monkeypatch.setattr(
        usage_graph_worker,
        "_build_payload",
        lambda settings, t3_policy=None: (calls.append(1) or _document_payload(settings)),
    )

    document = usage_graph_worker.usage_graph_document(make_target().settings)

    assert calls == [1]
    assert document["graph"]["days"] == 7
    # The corrupt file was replaced by a readable one.
    json.loads(cache_file.read_text())


def test_tree_fingerprint_tracks_append_delete_and_replacement(tmp_path):
    root = tmp_path / "projects"
    root.mkdir()
    transcript = root / "a.jsonl"
    transcript.write_text('{"one":1}\n')

    first = usage_graph_worker._tree_fingerprint(root)
    assert first["files"] == 1

    transcript.write_text('{"one":1}\n{"two":2}\n')
    grown = usage_graph_worker._tree_fingerprint(root)
    assert grown != first
    assert grown["bytes"] > first["bytes"]

    transcript.unlink()
    gone = usage_graph_worker._tree_fingerprint(root)
    assert gone["files"] == 0
    assert gone != grown

    assert usage_graph_worker._tree_fingerprint(tmp_path / "absent")["missing"]
    assert usage_graph_worker._file_fingerprint(tmp_path / "absent.jsonl")["missing"]


# --- Sessions: days before a hook ledger starts are gaps, not zeros ---------


def _stub_scans(monkeypatch):
    stats = usage_graph_worker.usage_stats
    monkeypatch.setattr(stats, "scan_usage", lambda *_args, **_kwargs: stats.UsageTotals())
    monkeypatch.setattr(usage_graph_worker, "_scan_opencode_records", lambda *_args: [])
    monkeypatch.setattr(usage_graph_worker, "_scan_antigravity_records", lambda *_args: [])
    monkeypatch.setattr(
        "jrbar.local_token_history.scan_local_records", lambda *_args, **_kwargs: []
    )


def test_only_cost_graph_payload_contains_exact_pricing_coverage(monkeypatch):
    _stub_scans(monkeypatch)
    monkeypatch.setattr(usage_graph_worker, "scan_usage_all_homes",
                        lambda *_args, **_kwargs: usage_graph_worker.usage_stats.UsageTotals())
    epoch = datetime.now().timestamp()
    monkeypatch.setattr(usage_graph_worker, "_scan_opencode_records", lambda *_args: [
        ("opencode", "mixed", "gpt-5.6-sol", epoch, 10, 2, 3, 4, "priced"),
        ("opencode", "mixed", "future-model", epoch, 5, 6, 7, 8, "unpriced"),
    ])
    target = make_target(mode="cost", providers=("opencode",))
    model, summary = usage_graph_worker._build_payload(target.settings)
    assert model["cost_coverage"] == {
        "observed_records": 2, "priced_records": 1, "unpriced_records": 1,
        "unpriced_sessions": 1,
        "token_categories": {"input": 5, "cached_input": 6, "cache_creation": 7, "output": 8},
    }
    assert model["cost_semantics"] == "api_equivalent_estimate"
    assert "No price for future-model" in summary
    percent_model = {key: value for key, value in model.items()
                     if key not in {"cost_coverage", "cost_semantics"}}
    monkeypatch.setattr(usage_graph_worker.usage_percent_history, "shared_percent_graph_model",
                        lambda **_kwargs: percent_model)
    for mode in ("tokens", "sessions", "percent"):
        target.settings.usage_display_mode = mode
        model, _ = usage_graph_worker._build_payload(target.settings)
        assert "cost_coverage" not in model


def test_unpriced_t3_note_explains_missing_per_turn_model():
    note = usage_graph_worker._unpriced_note({"t3code": 42, "future-model": 10})
    assert "No price for" in note
    assert "T3 Code's saved usage has no per-turn model" in note
    assert "tokens counted, cost left out" in note


@pytest.mark.parametrize("known_free", [False, True])
def test_cost_series_pricing_signal_and_summary_distinguish_unknown_from_free(monkeypatch, known_free):
    _stub_scans(monkeypatch)
    stats = usage_graph_worker.usage_stats
    monkeypatch.setattr(usage_graph_worker, "scan_usage_all_homes", lambda *_args, **_kwargs: stats.UsageTotals())
    if known_free:
        monkeypatch.setattr(stats, "rates_for_record", lambda *_args: stats.RecordRates(0, 0, 1))
    epoch = datetime.now().timestamp()
    monkeypatch.setattr(usage_graph_worker, "_scan_opencode_records", lambda *_args: [
        ("opencode", "session", "future-model", epoch, 1, 2, 3, 4, "record"),
    ])
    model, summary = usage_graph_worker._build_payload(make_target(mode="cost", providers=("opencode",)).settings)
    document = usage_graph_worker._project_graph_document(model, summary, ("opencode",))
    assert document["graph"]["series"][0]["has_priced_usage"] is known_free
    if known_free:
        assert "estimated $0.00" in summary
        assert "Unpriced" not in summary
    else:
        assert "Unpriced" in summary
        assert "$0" not in summary


def _write_ledger(state_dir, provider_id, offsets_and_work):
    """A synthetic ledger: (days ago, work id) for each session_start."""
    now = datetime.now()
    rows = []
    for days_ago, work_id in offsets_and_work:
        moment = (now - timedelta(days=days_ago)).replace(hour=12, minute=0, second=0)
        rows.append(
            {
                "provider_id": provider_id,
                "event_name": "session_start",
                "provider_work_id": work_id,
                "occurred_at_epoch": moment.timestamp(),
            }
        )
    (state_dir / f"{provider_id}.jsonl").write_text(
        "".join(json.dumps(row) + "\n" for row in rows), encoding="utf-8"
    )


def _sessions_payload(monkeypatch, tmp_path, ledger_provider, providers=None):
    _stub_scans(monkeypatch)
    monkeypatch.setattr(usage_graph_worker, "default_state_dir", lambda: tmp_path)
    return usage_graph_worker._build_payload(
        make_target(
            mode="sessions", providers=providers or (ledger_provider,)
        ).settings
    )


def test_sessions_before_a_ledger_starts_are_gap_days(monkeypatch, tmp_path):
    _write_ledger(tmp_path, "devin", [(3, "a"), (1, "b"), (1, "c")])

    model, summary = _sessions_payload(monkeypatch, tmp_path, "devin")

    values = model["series"][0]["values"]
    assert values[:3] == (-1.0, -1.0, -1.0)
    assert values[3:] == (1, 0, 2, 0)
    # The figure counts session-days that were counted, never the gaps.
    assert "Devin 3 session-days" in summary
    assert model["partial_provider_ids"] == ()


def test_a_ledger_that_reaches_back_past_the_window_makes_no_gaps(monkeypatch, tmp_path):
    _write_ledger(tmp_path, "devin", [(40, "old"), (2, "a")])

    model, summary = _sessions_payload(monkeypatch, tmp_path, "devin")

    assert all(value >= 0 for value in model["series"][0]["values"])
    assert "Devin 1 session-days" in summary


def test_providers_with_their_own_history_get_no_ledger_gaps(monkeypatch, tmp_path):
    # Grok reads its own session files, so where its hook log starts says
    # nothing about what its history covers.
    _write_ledger(tmp_path, "grok", [(1, "a")])

    model, _summary = _sessions_payload(monkeypatch, tmp_path, "grok")

    assert all(value >= 0 for value in model["series"][0]["values"])
    assert model["partial_provider_ids"] == ()


def test_claude_and_codex_sessions_are_left_to_their_transcripts(monkeypatch, tmp_path):
    _write_ledger(tmp_path, "claude", [(1, "a")])
    _write_ledger(tmp_path, "codex", [(1, "b")])

    model, _summary = _sessions_payload(
        monkeypatch, tmp_path, "claude", providers=("claude", "codex")
    )

    assert model["series"] == ()
    assert model["partial_provider_ids"] == ()


def test_a_sessions_rebuild_reads_each_hook_ledger_once(monkeypatch, tmp_path):
    reads: list[str] = []
    real_read_text = Path.read_text

    def counting(self, *args, **kwargs):
        if self.suffix == ".jsonl":
            reads.append(self.name)
        return real_read_text(self, *args, **kwargs)

    _write_ledger(tmp_path, "devin", [(3, "a"), (1, "b"), (1, "c")])
    monkeypatch.setattr(Path, "read_text", counting)

    model, summary = _sessions_payload(monkeypatch, tmp_path, "devin")

    # Both answers (the daily counts and where the ledger starts) come from
    # one read, and the graph is what it was.
    assert reads == ["devin.jsonl"]
    assert model["series"][0]["values"][3:] == (1, 0, 2, 0)
    assert "Devin 3 session-days" in summary


def test_a_failing_first_event_lookup_leaves_counts_intact_and_adds_no_gaps(
    monkeypatch, tmp_path
):
    from jrbar import session_history

    _write_ledger(tmp_path, "devin", [(1, "a")])

    def broken(*_args, **_kwargs):
        raise OSError("state dir unreadable")

    monkeypatch.setattr(session_history, "ledger_first_event_epochs", broken)

    model, summary = _sessions_payload(monkeypatch, tmp_path, "devin")

    assert model["series"][0]["values"] == (0, 0, 0, 0, 0, 1, 0)
    assert "Devin 1 session-days" in summary


def test_the_document_cache_is_keyed_to_the_gap_days_and_pricing_semantics():
    # Documents cached before gap days existed are zero-filled, and cost
    # documents cached before records were priced by their model's maker
    # leave GPT and Gemini models at no cost; the version is part of the
    # cache key, so they are rebuilt rather than served. The current
    # version also rebuilds cost documents missing pricing coverage and
    # graphs missing carried percent readings or URI-escaped sources.
    assert usage_graph_worker._USAGE_DOC_CACHE_VERSION == 12
    snapshot = usage_graph_worker._settings_snapshot(
        make_target(mode="sessions", providers=("devin",)).settings
    )
    assert usage_graph_worker._usage_doc_cache_meta(snapshot, None)["v"] == 12


def _v2_turns_database(path: Path, turns: list[tuple]) -> Path:
    connection = sqlite3.connect(path)
    connection.execute(
        "CREATE TABLE orchestration_v2_projection_provider_turns ("
        "provider_turn_id TEXT PRIMARY KEY, thread_id TEXT NOT NULL, provider_thread_id TEXT NOT NULL,"
        " node_id TEXT NOT NULL, run_attempt_id TEXT, ordinal INTEGER NOT NULL, status TEXT NOT NULL,"
        " started_at TEXT, completed_at TEXT, payload_json TEXT NOT NULL)"
    )
    connection.executemany(
        "INSERT INTO orchestration_v2_projection_provider_turns VALUES (?,?,?,?,?,?,?,?,?,?)",
        turns,
    )
    connection.commit()
    connection.close()
    return path


def _v2_turn(turn_id: str, thread_id: str, completed_at: str | None, usage: dict | None, ordinal: int = 1):
    payload = {"id": turn_id}
    if usage is not None:
        payload["turnTokenUsage"] = usage
    return (
        turn_id, thread_id, "pt-1", "node", None, ordinal, "completed",
        None, completed_at, json.dumps(payload),
    )


def test_t3_v2_turn_usage_becomes_activity_records(tmp_path) -> None:
    usage = {
        "usageScope": "main_agent", "usageStatus": "complete", "hasSubagents": False,
        "inputTokens": 1000, "cachedInputTokens": 600, "cacheCreationTokens": 100,
        "outputTokens": 250, "reasoningTokens": 50,
    }
    database = _v2_turns_database(
        tmp_path / "statev2.sqlite",
        [
            _v2_turn("turn-1", "thread-1", "2026-10-06T10:00:00Z", usage),
            _v2_turn("turn-2", "thread-1", "2026-10-06T11:00:00Z", None, ordinal=2),
            _v2_turn("turn-3", "thread-2", None, usage),
        ],
    )

    statuses: list[str] = []
    records = usage_graph_worker._scan_t3code_v2_records(
        database, 1_700_000_000.0, coverage_reporter=statuses.append
    )

    assert statuses == ["complete"]
    assert len(records) == 1
    provider, session, model, _epoch, uncached, cached, written, output, dedupe = records[0]
    assert (provider, session, model) == ("other", "thread-1", "")
    # T3's input already includes cache reads and writes; the record splits it.
    assert (uncached, cached, written, output) == (300, 600, 100, 250)
    assert uncached + cached + written == 1000
    assert dedupe == "t3code:turn:turn-1"


def test_t3_v2_partial_usage_with_only_an_output_count_is_still_counted(tmp_path) -> None:
    database = _v2_turns_database(
        tmp_path / "statev2.sqlite",
        [
            _v2_turn(
                "turn-1", "thread-1", "2026-10-06T10:00:00Z",
                {"usageScope": "main_agent", "usageStatus": "partial", "hasSubagents": True,
                 "outputTokens": 40},
            ),
            _v2_turn(
                "turn-2", "thread-1", "2026-10-06T10:05:00Z",
                {"usageScope": "main_agent", "usageStatus": "unavailable", "hasSubagents": False},
                ordinal=2,
            ),
        ],
    )

    records = usage_graph_worker._scan_t3code_v2_records(database, 1_700_000_000.0)

    assert [(record[4], record[7]) for record in records] == [(0, 40)]


def test_t3_v2_scan_is_bounded_to_the_newest_turns(tmp_path) -> None:
    usage = {"usageScope": "main_agent", "usageStatus": "complete", "hasSubagents": False,
             "inputTokens": 10, "outputTokens": 2}
    database = _v2_turns_database(
        tmp_path / "statev2.sqlite",
        [
            _v2_turn("old", "thread-old", "2026-10-06T08:00:00Z", usage, ordinal=1),
            _v2_turn("middle", "thread-middle", "2026-10-06T09:00:00Z", usage, ordinal=2),
            _v2_turn("new", "thread-new", "2026-10-06T10:00:00Z", usage, ordinal=3),
        ],
    )
    statuses: list[str] = []

    records = usage_graph_worker._scan_t3code_v2_records(
        database, 1_700_000_000.0, maximum_records=2, coverage_reporter=statuses.append
    )

    assert [record[1] for record in records] == ["thread-new", "thread-middle"]
    assert statuses == ["stable_partial"]


def test_t3_v2_scan_respects_the_window(tmp_path) -> None:
    usage = {"usageScope": "main_agent", "usageStatus": "complete", "hasSubagents": False,
             "inputTokens": 10, "outputTokens": 2}
    database = _v2_turns_database(
        tmp_path / "statev2.sqlite",
        [_v2_turn("old", "thread-old", "2020-01-01T00:00:00Z", usage)],
    )

    assert usage_graph_worker._scan_t3code_v2_records(database, 1_700_000_000.0) == []


def test_activity_statistics_read_turns_when_the_live_database_is_v2(tmp_path) -> None:
    usage = {"usageScope": "main_agent", "usageStatus": "complete", "hasSubagents": False,
             "inputTokens": 10, "outputTokens": 2}
    base = tmp_path / "t3"
    (base / "userdata").mkdir(parents=True)
    _v2_turns_database(
        base / "userdata" / "statev2.sqlite",
        [_v2_turn("turn-1", "thread-1", "2026-10-06T10:00:00Z", usage)],
    )
    policy = project_t3_read_only_policy(
        SimpleNamespace(
            t3code_enabled=True,
            t3code_activity_statistics_enabled=True,
            t3code_base_dir=str(base),
        )
    )

    records = usage_graph_worker.scan_t3_activity_statistics(policy, 1_700_000_000.0)

    assert [record[1] for record in records] == ["thread-1"]


def test_a_missing_v2_turn_table_is_reported_not_guessed(tmp_path) -> None:
    database = tmp_path / "statev2.sqlite"
    sqlite3.connect(database).close()
    statuses: list[str] = []

    records = usage_graph_worker._scan_t3code_v2_records(
        database, 1_700_000_000.0, coverage_reporter=statuses.append
    )

    assert records == []
    assert statuses == ["failed"]


def _reading_totals(*, pending: int, malformed: int = 0):
    from jrbar import usage_stats

    totals = usage_stats.UsageTotals()
    totals.source_coverage["codex"] = usage_stats.UsageSourceCoverage(
        provider_id="codex",
        status=usage_stats.UsageSourceStatus.PARTIAL if pending or malformed else usage_stats.UsageSourceStatus.OK,
        root_present=True, root_walked=True, files_discovered=12, files_read=4, cache_hits=0,
        malformed_lines=malformed, unreadable_files=0, skipped_symlinks=0, duplicate_physical_files=0,
        pending_files=pending,
    )
    return totals


def _stub_sources(monkeypatch, totals, seen=None):
    def scan(*_args, **kwargs):
        if seen is not None:
            seen.update(kwargs)
        return totals

    monkeypatch.setattr(usage_graph_worker, "scan_usage_all_homes", scan)
    monkeypatch.setattr(usage_graph_worker, "_scan_opencode_records", lambda *_args: [])
    monkeypatch.setattr(usage_graph_worker, "_scan_antigravity_records", lambda *_args: [])


def test_a_pass_that_is_still_reading_says_so_and_is_bounded(monkeypatch) -> None:
    seen: dict = {}
    _stub_sources(monkeypatch, _reading_totals(pending=8), seen)

    model, summary = usage_graph_worker._build_payload(make_target(providers=("codex",)).settings)

    assert model["reading_files"] == 8
    assert summary.endswith("Still reading 8 files")
    assert "Partial local history" not in summary, "unread work alone is not damage"
    assert isinstance(seen["budget"], usage_graph_worker.usage_stats.ScanBudget)


def test_still_reading_beside_a_real_gap_keeps_both_notes(monkeypatch) -> None:
    _stub_sources(monkeypatch, _reading_totals(pending=1, malformed=2))

    _model, summary = usage_graph_worker._build_payload(make_target(providers=("codex",)).settings)

    assert "Partial local history: Codex" in summary and summary.endswith("Still reading 1 file")


def test_a_finished_scan_adds_no_reading_note(monkeypatch) -> None:
    _stub_sources(monkeypatch, _reading_totals(pending=0))

    model, summary = usage_graph_worker._build_payload(make_target(providers=("codex",)).settings)

    assert model["reading_files"] == 0
    assert "Still reading" not in summary and "Partial" not in summary


def test_a_reply_that_is_still_reading_is_not_remembered(monkeypatch) -> None:
    settings = make_target(providers=("codex",)).settings
    builds = []
    reading = {"files": 3}

    def build(settings, *, t3_policy=None):
        builds.append(1)
        model, summary = _document_payload(settings)
        return {**model, "reading_files": reading["files"]}, summary

    monkeypatch.setattr(usage_graph_worker, "_build_payload", build)
    monkeypatch.setattr(usage_graph_worker, "_agent_histories_found", lambda: ())

    first = usage_graph_worker.usage_graph_document(settings)
    usage_graph_worker.usage_graph_document(settings)
    assert len(builds) == 2, "an unfinished answer is asked for again"
    assert first["graph"]["reading_files"] == 3

    reading["files"] = 0
    usage_graph_worker.usage_graph_document(settings)
    usage_graph_worker.usage_graph_document(settings)
    assert len(builds) == 3, "a finished one is remembered"


def test_graph_cache_notices_same_size_edits_below_the_newest_file_mtime(monkeypatch, tmp_path):
    root = tmp_path / "corpus"
    root.mkdir()
    older = root / "older.jsonl"
    newest = root / "newest.jsonl"
    older.write_text('{"tokens":10}\n')
    newest.write_text('{"tokens":20}\n')
    os.utime(older, ns=(1_000_000_000, 1_000_000_000))
    os.utime(newest, ns=(9_000_000_000, 9_000_000_000))
    before = usage_graph_worker._tree_fingerprint(root)
    builds = []

    def build(settings, *, t3_policy=None):
        builds.append(1)
        return _document_payload(settings)

    monkeypatch.setattr(usage_graph_worker, "_build_payload", build)
    monkeypatch.setattr(usage_graph_worker, "_agent_histories_found", lambda: ())
    monkeypatch.setattr(usage_graph_worker, "_corpus_fingerprint", lambda *_a, **_k: usage_graph_worker._tree_fingerprint(root))
    settings = make_target(providers=("codex",)).settings
    usage_graph_worker.usage_graph_document(settings)
    usage_graph_worker.usage_graph_document(settings)
    assert len(builds) == 1

    older.write_text('{"tokens":99}\n')
    os.utime(older, ns=(2_000_000_000, 2_000_000_000))
    after = usage_graph_worker._tree_fingerprint(root)
    for key in ("files", "bytes", "newest_ns", "inos"):
        assert before[key] == after[key]
    assert before["stat_digest"] != after["stat_digest"]
    usage_graph_worker.usage_graph_document(settings)
    usage_graph_worker.usage_graph_document(settings)
    assert len(builds) == 2


@pytest.mark.parametrize("provider", ["codex", "t3code"])
def test_failed_or_partial_source_document_retries_without_corpus_stat_changes(monkeypatch, provider):
    settings = make_target(providers=(provider,)).settings
    builds = []
    failing = [True]

    def build(settings, *, t3_policy=None):
        builds.append(1)
        model, summary = _document_payload(settings)
        model["partial_provider_ids"] = (provider,) if failing[0] else ()
        model["reading_files"] = 0
        return model, summary

    monkeypatch.setattr(usage_graph_worker, "_build_payload", build)
    monkeypatch.setattr(usage_graph_worker, "_corpus_fingerprint", lambda *_a, **_k: {"unchanged": True})
    monkeypatch.setattr(usage_graph_worker, "_agent_histories_found", lambda: ())
    first = usage_graph_worker.usage_graph_document(settings)
    usage_graph_worker.usage_graph_document(settings)
    assert len(builds) == 2
    assert first["graph"]["partial_provider_ids"] == [provider]
    failing[0] = False
    usage_graph_worker.usage_graph_document(settings)
    usage_graph_worker.usage_graph_document(settings)
    assert len(builds) == 3, "a recovered complete answer can be cached"


@pytest.mark.parametrize("failure", ["walk_failed", "unreadable", "malformed"])
def test_graph_marks_read_failures_for_retry_but_keeps_stable_malformed_gap_policy(monkeypatch, failure):
    from dataclasses import replace

    totals = _reading_totals(pending=0, malformed=2 if failure == "malformed" else 0)
    coverage = totals.source_coverage["codex"]
    if failure == "walk_failed":
        coverage = replace(coverage, status=usage_graph_worker.usage_stats.UsageSourceStatus.FAILED,
                           root_walked=False, files_discovered=0, files_read=0)
    elif failure == "unreadable":
        coverage = replace(coverage, status=usage_graph_worker.usage_stats.UsageSourceStatus.PARTIAL,
                           unreadable_files=1)
    totals.source_coverage["codex"] = coverage
    _stub_sources(monkeypatch, totals)
    model, summary = usage_graph_worker._build_payload(make_target(providers=("codex",)).settings)
    assert model["partial_provider_ids"] == (() if failure == "malformed" else ("codex",))
    assert "Partial local history: Codex" in summary


def test_native_partial_transcripts_retry_with_unchanged_fingerprint(monkeypatch):
    _stub_sources(monkeypatch, _reading_totals(pending=0, malformed=2))
    monkeypatch.setattr(usage_graph_worker, "_corpus_fingerprint", lambda *_args, **_kwargs: {})
    original_build = usage_graph_worker._build_payload
    builds = []
    def build(*args, **kwargs):
        builds.append(1)
        return original_build(*args, **kwargs)
    monkeypatch.setattr(usage_graph_worker, "_build_payload", build)
    settings = make_target(providers=("codex",)).settings
    usage_graph_worker.usage_graph_document(settings, provider_ids=("codex",))
    usage_graph_worker.usage_graph_document(settings, provider_ids=("codex",))
    assert builds == [1, 1]
