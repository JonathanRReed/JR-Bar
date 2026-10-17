"""T3 Code 0.0.46 nightlies keep live threads in ``statev2.sqlite``.

Synthetic fixtures only. The schema below mirrors the columns T3's
orchestrator-v2 projection writes (upstream ``de3439142``, #2829); the
legacy ``projection_*`` tables in that file are a frozen copy of the old
database and must never be read as live.
"""

from __future__ import annotations

import json
import os
import sqlite3
from pathlib import Path

import pytest

from jrbar import t3_compat
from jrbar.models import AgentMode
from jrbar.t3_compat import read_t3_snapshot

NOW = "2026-10-07T12:00:00Z"
EARLIER = "2026-10-07T11:00:00Z"

_V2_SCHEMA = """
CREATE TABLE projection_projects (
  project_id TEXT PRIMARY KEY, title TEXT NOT NULL, workspace_root TEXT NOT NULL,
  created_at TEXT NOT NULL, updated_at TEXT NOT NULL, deleted_at TEXT
);
CREATE TABLE orchestration_v2_projection_threads (
  thread_id TEXT PRIMARY KEY, project_id TEXT NOT NULL, title TEXT NOT NULL,
  default_provider TEXT NOT NULL, runtime_mode TEXT NOT NULL,
  interaction_mode TEXT NOT NULL, active_provider_thread_id TEXT,
  created_at TEXT NOT NULL, updated_at TEXT NOT NULL, archived_at TEXT,
  deleted_at TEXT, payload_json TEXT NOT NULL, provider_instance_id TEXT
);
CREATE TABLE orchestration_v2_projection_runs (
  run_id TEXT PRIMARY KEY, thread_id TEXT NOT NULL, ordinal INTEGER NOT NULL,
  provider TEXT NOT NULL, provider_thread_id TEXT, status TEXT NOT NULL,
  requested_at TEXT NOT NULL, completed_at TEXT, payload_json TEXT NOT NULL,
  provider_instance_id TEXT
);
CREATE TABLE orchestration_v2_projection_runtime_requests (
  runtime_request_id TEXT PRIMARY KEY, thread_id TEXT NOT NULL, node_id TEXT NOT NULL,
  provider_turn_id TEXT, kind TEXT NOT NULL, status TEXT NOT NULL,
  created_at TEXT NOT NULL, resolved_at TEXT, payload_json TEXT NOT NULL
);
CREATE TABLE orchestration_v2_projection_plans (
  plan_id TEXT PRIMARY KEY, thread_id TEXT NOT NULL, run_id TEXT, node_id TEXT NOT NULL,
  kind TEXT NOT NULL, status TEXT NOT NULL, payload_json TEXT NOT NULL
);
CREATE TABLE orchestration_v2_projection_provider_sessions (
  provider_session_id TEXT PRIMARY KEY, thread_id TEXT, provider TEXT NOT NULL,
  status TEXT NOT NULL, model TEXT, updated_at TEXT NOT NULL, payload_json TEXT NOT NULL,
  driver TEXT, provider_instance_id TEXT
);
"""

_V1_SCHEMA = """
CREATE TABLE projection_threads (
  thread_id TEXT PRIMARY KEY, project_id TEXT NOT NULL, title TEXT NOT NULL,
  model_selection_json TEXT NOT NULL, runtime_mode TEXT NOT NULL,
  interaction_mode TEXT NOT NULL, branch TEXT, worktree_path TEXT,
  latest_turn_id TEXT, created_at TEXT NOT NULL, updated_at TEXT NOT NULL,
  archived_at TEXT, settled_at TEXT, pending_approval_count INTEGER NOT NULL,
  pending_user_input_count INTEGER NOT NULL, has_actionable_proposed_plan INTEGER NOT NULL,
  deleted_at TEXT
);
CREATE TABLE projection_thread_sessions (
  thread_id TEXT PRIMARY KEY, status TEXT NOT NULL, provider_name TEXT,
  provider_instance_id TEXT, provider_thread_id TEXT, runtime_mode TEXT NOT NULL,
  active_turn_id TEXT, last_error TEXT, updated_at TEXT NOT NULL
);
"""


def _v2(base: Path, *, schema: str = _V2_SCHEMA) -> Path:
    target = base / "userdata" / "statev2.sqlite"
    target.parent.mkdir(parents=True, exist_ok=True)
    connection = sqlite3.connect(target)
    connection.executescript(schema)
    connection.execute(
        "INSERT INTO projection_projects VALUES ('project-1', 'Synthetic', '/repo/synthetic', ?, ?, NULL)",
        (EARLIER, EARLIER),
    )
    connection.commit()
    connection.close()
    return target


def _thread(
    database: Path,
    thread_id: str = "thread-1",
    *,
    provider: str = "claudeAgent",
    title: str = "Synthetic task",
    updated_at: str = NOW,
    archived_at: str | None = None,
    deleted_at: str | None = None,
    relationship: str | None = None,
    options: object = (("effort", "high"),),
    active_provider_thread_id: str | None = "provider-thread-1",
    branch: str | None = "fix/synthetic",
    worktree: str | None = "/repo/synthetic/.worktrees/one",
) -> None:
    payload = {
        "id": thread_id,
        "title": title,
        "providerInstanceId": provider,
        "modelSelection": {
            "instanceId": provider,
            "model": "synthetic-model",
            "options": [{"id": key, "value": value} for key, value in options]
            if isinstance(options, tuple)
            else options,
        },
        "branch": branch,
        "worktreePath": worktree,
        "lineage": {
            "parentThreadId": None if relationship is None else "thread-parent",
            "relationshipToParent": relationship,
            "rootThreadId": None,
        },
    }
    connection = sqlite3.connect(database)
    connection.execute(
        "INSERT INTO orchestration_v2_projection_threads VALUES (?,?,?,?,?,?,?,?,?,?,?,?,?)",
        (
            thread_id, "project-1", title, provider, "full-access", "default",
            active_provider_thread_id, EARLIER, updated_at, archived_at, deleted_at,
            json.dumps(payload), provider,
        ),
    )
    connection.commit()
    connection.close()


def _run(
    database: Path,
    thread_id: str,
    ordinal: int,
    status: str,
    *,
    held: bool = False,
    requested_at: str = NOW,
    provider: str | None = None,
    provider_instance: str | None = None,
    provider_thread: str | None = None,
) -> None:
    payload = {"id": f"run-{thread_id}-{ordinal}", "status": status}
    if held:
        payload["queueHeld"] = True
    connection = sqlite3.connect(database)
    if provider is None:
        provider, default_thread = connection.execute(
            "SELECT default_provider, active_provider_thread_id "
            "FROM orchestration_v2_projection_threads WHERE thread_id = ?", (thread_id,),
        ).fetchone()
        if provider_thread is None:
            provider_thread = default_thread
    connection.execute(
        "INSERT INTO orchestration_v2_projection_runs VALUES (?,?,?,?,?,?,?,?,?,?)",
        (
            f"run-{thread_id}-{ordinal}", thread_id, ordinal, provider, provider_thread, status,
            requested_at, None, json.dumps(payload), provider_instance or provider,
        ),
    )
    connection.commit()
    connection.close()


def _request(database: Path, thread_id: str, kind: str, status: str = "pending") -> None:
    connection = sqlite3.connect(database)
    connection.execute(
        "INSERT INTO orchestration_v2_projection_runtime_requests VALUES (?,?,?,?,?,?,?,?,?)",
        (f"req-{thread_id}-{kind}-{status}", thread_id, "node-1", None, kind, status, NOW, None, "{}"),
    )
    connection.commit()
    connection.close()


def _plan(database: Path, thread_id: str, kind: str, status: str) -> None:
    connection = sqlite3.connect(database)
    connection.execute(
        "INSERT INTO orchestration_v2_projection_plans VALUES (?,?,?,?,?,?,?)",
        (f"plan-{thread_id}-{kind}-{status}", thread_id, None, "node-1", kind, status, "{}"),
    )
    connection.commit()
    connection.close()


def _only(snapshot):
    assert snapshot.compatible is True, snapshot.reason
    assert len(snapshot.threads) == 1
    return snapshot.threads[0]


def test_a_running_v2_thread_is_working_with_its_provider_and_options(tmp_path: Path) -> None:
    database = _v2(tmp_path)
    _thread(database)
    _run(database, "thread-1", 1, "running")

    thread = _only(read_t3_snapshot(base_dir=tmp_path, environment_id="local"))

    assert thread.provider == "claude"
    assert thread.provider_instance == "claudeAgent"
    assert thread.provider_thread_id == "provider-thread-1"
    assert thread.model == "synthetic-model"
    assert thread.reasoning_effort == "high"
    assert thread.branch == "fix/synthetic"
    assert thread.worktree_path == "/repo/synthetic/.worktrees/one"
    assert thread.project_title == "Synthetic"
    assert thread.deep_link == "t3code://threads/local/thread-1"
    status = thread.to_agent_status()
    assert status.mode is AgentMode.WORKING


@pytest.mark.parametrize(
    ("run_status", "expected"),
    (
        ("preparing", AgentMode.WORKING),
        ("starting", AgentMode.WORKING),
        ("waiting", AgentMode.WORKING),
        ("completed", AgentMode.COMPLETED),
        ("failed", AgentMode.BLOCKED_ERROR),
        ("interrupted", AgentMode.UNKNOWN),
        ("cancelled", AgentMode.IDLE_READY),
        ("rolled_back", AgentMode.IDLE_READY),
    ),
)
def test_v2_run_status_maps_to_the_same_modes_as_v1_turn_state(
    tmp_path: Path, run_status: str, expected: AgentMode
) -> None:
    database = _v2(tmp_path)
    _thread(database)
    _run(database, "thread-1", 1, run_status)

    assert _only(read_t3_snapshot(base_dir=tmp_path)).to_agent_status().mode is expected


def test_a_thread_with_no_run_is_idle(tmp_path: Path) -> None:
    database = _v2(tmp_path)
    _thread(database)

    assert _only(read_t3_snapshot(base_dir=tmp_path)).to_agent_status().mode is AgentMode.IDLE_READY


def test_a_held_queued_run_is_not_work(tmp_path: Path) -> None:
    database = _v2(tmp_path)
    _thread(database)
    _run(database, "thread-1", 1, "completed")
    _run(database, "thread-1", 2, "queued", held=True)

    assert _only(read_t3_snapshot(base_dir=tmp_path)).to_agent_status().mode is AgentMode.COMPLETED


def test_a_newer_active_run_beats_an_older_failed_one(tmp_path: Path) -> None:
    database = _v2(tmp_path)
    _thread(database)
    _run(database, "thread-1", 1, "failed")
    _run(database, "thread-1", 2, "running")

    assert _only(read_t3_snapshot(base_dir=tmp_path)).to_agent_status().mode is AgentMode.WORKING


@pytest.mark.parametrize(
    ("kind", "message", "event"),
    (
        ("command", "Approval needed in T3 Code", "PermissionRequest"),
        ("file-change", "Approval needed in T3 Code", "PermissionRequest"),
        ("permission", "Approval needed in T3 Code", "PermissionRequest"),
        ("user_input", "Input needed in T3 Code", "Notification"),
    ),
)
def test_a_pending_runtime_request_needs_the_person(
    tmp_path: Path, kind: str, message: str, event: str
) -> None:
    database = _v2(tmp_path)
    _thread(database)
    _run(database, "thread-1", 1, "waiting")
    _request(database, "thread-1", kind)

    thread = _only(read_t3_snapshot(base_dir=tmp_path))
    status = thread.to_agent_status()

    assert thread.needs_user is True
    assert status.mode is AgentMode.WAITING_FOR_INPUT
    assert status.message == message
    assert status.event_name == event


def test_a_resolved_request_does_not_need_anyone(tmp_path: Path) -> None:
    database = _v2(tmp_path)
    _thread(database)
    _run(database, "thread-1", 1, "running")
    _request(database, "thread-1", "command", status="resolved")

    assert _only(read_t3_snapshot(base_dir=tmp_path)).needs_user is False


def test_only_an_active_proposed_plan_is_actionable(tmp_path: Path) -> None:
    database = _v2(tmp_path)
    _thread(database, "thread-1")
    _thread(database, "thread-2", updated_at=EARLIER)
    _thread(database, "thread-3", updated_at="2026-10-07T10:00:00Z")
    _plan(database, "thread-1", "proposed_plan", "active")
    _plan(database, "thread-2", "proposed_plan", "superseded")
    _plan(database, "thread-3", "todo_list", "active")

    snapshot = read_t3_snapshot(base_dir=tmp_path)
    by_id = {thread.thread_id: thread for thread in snapshot.threads}

    assert by_id["thread-1"].has_actionable_plan is True
    assert by_id["thread-2"].has_actionable_plan is False
    assert by_id["thread-3"].has_actionable_plan is False


def test_subagent_archived_and_deleted_threads_are_not_listed(tmp_path: Path) -> None:
    database = _v2(tmp_path)
    _thread(database, "thread-main")
    _thread(database, "thread-sub", relationship="subagent")
    _thread(database, "thread-archived", archived_at=NOW)
    _thread(database, "thread-deleted", deleted_at=NOW)

    snapshot = read_t3_snapshot(base_dir=tmp_path)

    assert [thread.thread_id for thread in snapshot.threads] == ["thread-main"]


@pytest.mark.parametrize(
    ("raw", "expected"),
    (
        ("claudeAgent", "claude"),
        ("codex", "codex"),
        ("opencode", "opencode"),
        ("grok", "grok"),
        ("antigravity", "antigravity"),
        ("acpRegistry_devin", "other"),
        ("acpRegistry_somethingnew", "other"),
        ("gemini", "other"),
    ),
)
def test_provider_drivers_map_to_the_provider_they_run(tmp_path: Path, raw: str, expected: str) -> None:
    database = _v2(tmp_path)
    _thread(database, provider=raw)

    assert _only(read_t3_snapshot(base_dir=tmp_path)).provider == expected


@pytest.mark.parametrize("driver, expected", [("codex", "codex"), ("acpRegistry", "other")])
def test_current_native_binding_uses_driver_not_custom_instance(tmp_path, driver, expected):
    database = _v2(tmp_path)
    _thread(database, provider="claudeAgent")
    _run(database, "thread-1", 1, "running", provider="acpRegistry_devin",
         provider_instance="acpRegistry_devin", provider_thread="bound-thread")
    connection = sqlite3.connect(database)
    connection.execute(
        "CREATE TABLE orchestration_v2_projection_provider_threads "
        "(provider_thread_id TEXT PRIMARY KEY, driver TEXT, provider_instance_id TEXT, payload_json TEXT)"
    )
    connection.execute(
        "INSERT INTO orchestration_v2_projection_provider_threads VALUES (?,?,?,?)",
        ("bound-thread", driver, "acpRegistry_devin", json.dumps({"driver": driver})),
    )
    connection.execute(
        "UPDATE orchestration_v2_projection_runs SET payload_json=?",
        (json.dumps({"modelSelection": {"instanceId": "acpRegistry_devin", "model": "requested-model"}}),),
    )
    connection.commit()
    connection.close()
    thread = _only(read_t3_snapshot(base_dir=tmp_path))
    assert thread.provider == expected
    assert thread.provider_instance == "acpRegistry_devin"
    assert thread.provider_thread_id == "bound-thread"
    assert thread.model == "requested-model"
    assert thread.updated_at.isoformat() == "2026-10-07T12:00:00+00:00"


def test_the_frozen_legacy_tables_inside_the_v2_file_are_not_live(tmp_path: Path) -> None:
    database = _v2(tmp_path, schema=_V2_SCHEMA + _V1_SCHEMA)
    connection = sqlite3.connect(database)
    connection.execute(
        "INSERT INTO projection_threads VALUES ('stale-thread','project-1','Stale','{}','full-access',"
        "'default',NULL,NULL,NULL,?,?,NULL,NULL,1,0,1,NULL)",
        (EARLIER, EARLIER),
    )
    connection.commit()
    connection.close()
    _thread(database, "thread-live")

    assert [thread.thread_id for thread in read_t3_snapshot(base_dir=tmp_path).threads] == ["thread-live"]


def test_a_v2_file_missing_a_required_column_fails_closed(tmp_path: Path) -> None:
    schema = _V2_SCHEMA.replace("active_provider_thread_id TEXT,", "")
    database = _v2(tmp_path, schema=schema)
    del database

    snapshot = read_t3_snapshot(base_dir=tmp_path)

    assert snapshot.compatible is False
    assert snapshot.reason == t3_compat.T3_REASON_UNSUPPORTED
    assert snapshot.threads == ()


def test_the_v2_projection_database_is_opened_query_only(tmp_path: Path) -> None:
    database = _v2(tmp_path)
    connection = t3_compat._open_read_only(database)
    try:
        with pytest.raises(sqlite3.OperationalError):
            connection.execute("DELETE FROM orchestration_v2_projection_threads")
    finally:
        connection.close()


# -- Which file is live -----------------------------------------------------


def _legacy(base: Path) -> Path:
    target = base / "userdata" / "state.sqlite"
    target.parent.mkdir(parents=True, exist_ok=True)
    connection = sqlite3.connect(target)
    connection.executescript(
        """
        CREATE TABLE projection_projects (
          project_id TEXT PRIMARY KEY, title TEXT NOT NULL, workspace_root TEXT NOT NULL,
          created_at TEXT NOT NULL, updated_at TEXT NOT NULL, deleted_at TEXT);
        """
        + _V1_SCHEMA
    )
    connection.execute(
        "INSERT INTO projection_projects VALUES ('project-1','Legacy','/repo/legacy',?,?,NULL)",
        (EARLIER, EARLIER),
    )
    connection.execute(
        "INSERT INTO projection_threads VALUES ('legacy-thread','project-1','Legacy task',"
        "'{}','full-access','default',NULL,NULL,NULL,?,?,NULL,NULL,0,0,0,NULL)",
        (EARLIER, EARLIER),
    )
    connection.execute(
        "INSERT INTO projection_thread_sessions VALUES ('legacy-thread','running','codex','codex',"
        "'native-1','full-access',NULL,NULL,?)",
        (EARLIER,),
    )
    connection.commit()
    connection.close()
    return target


def _age(path: Path, seconds_ago: float) -> None:
    stamp = 1_790_000_000.0 - seconds_ago
    os.utime(path, (stamp, stamp))


def test_v2_wins_when_it_is_the_fresher_database(tmp_path: Path) -> None:
    legacy = _legacy(tmp_path)
    live = _v2(tmp_path)
    _thread(live, "thread-live")
    _age(legacy, 1000)
    _age(live, 1)

    snapshot = read_t3_snapshot(base_dir=tmp_path)

    assert snapshot.database_path == live
    assert [thread.thread_id for thread in snapshot.threads] == ["thread-live"]
    assert t3_compat.t3_database_path(tmp_path) == live


def test_the_legacy_database_wins_when_a_stable_install_is_the_fresher_one(tmp_path: Path) -> None:
    legacy = _legacy(tmp_path)
    live = _v2(tmp_path)
    _thread(live, "thread-v2")
    _age(live, 1000)
    _age(legacy, 1)

    snapshot = read_t3_snapshot(base_dir=tmp_path)

    assert snapshot.database_path == legacy
    assert [thread.thread_id for thread in snapshot.threads] == ["legacy-thread"]
    assert t3_compat.t3_database_path(tmp_path) == legacy


def test_a_write_ahead_log_counts_as_the_databases_last_activity(tmp_path: Path) -> None:
    legacy = _legacy(tmp_path)
    live = _v2(tmp_path)
    _thread(live, "thread-v2")
    wal = live.with_name(live.name + "-wal")
    wal.write_bytes(b"")
    _age(live, 1000)
    _age(wal, 1)
    _age(legacy, 100)

    assert t3_compat.t3_database_path(tmp_path) == live


def test_only_a_legacy_database_still_reads_as_before(tmp_path: Path) -> None:
    legacy = _legacy(tmp_path)

    snapshot = read_t3_snapshot(base_dir=tmp_path)

    assert snapshot.database_path == legacy
    assert [thread.thread_id for thread in snapshot.threads] == ["legacy-thread"]


def test_only_a_v2_database_is_found(tmp_path: Path) -> None:
    live = _v2(tmp_path)

    assert t3_compat.t3_database_path(tmp_path) == live


def test_a_v2_file_that_has_not_been_migrated_falls_back_to_the_legacy_file(tmp_path: Path) -> None:
    legacy = _legacy(tmp_path)
    empty = tmp_path / "userdata" / "statev2.sqlite"
    sqlite3.connect(empty).close()
    _age(legacy, 1000)
    _age(empty, 1)

    snapshot = read_t3_snapshot(base_dir=tmp_path)

    assert snapshot.database_path == legacy
    assert [thread.thread_id for thread in snapshot.threads] == ["legacy-thread"]


def test_neither_file_is_still_a_missing_database(tmp_path: Path) -> None:
    with pytest.raises(FileNotFoundError):
        read_t3_snapshot(base_dir=tmp_path)


# -- Smaller reader fixes found in the same review ---------------------------


def test_the_t3_home_variable_t3_itself_reads_sets_the_base_directory(monkeypatch, tmp_path: Path) -> None:
    monkeypatch.delenv("T3_HOME", raising=False)
    monkeypatch.setenv("T3CODE_HOME", str(tmp_path / "custom"))

    assert t3_compat.default_t3_base_dir() == tmp_path / "custom"


def test_the_older_t3_home_variable_still_works_when_the_new_one_is_unset(monkeypatch, tmp_path: Path) -> None:
    monkeypatch.delenv("T3CODE_HOME", raising=False)
    monkeypatch.setenv("T3_HOME", str(tmp_path / "older"))

    assert t3_compat.default_t3_base_dir() == tmp_path / "older"


@pytest.mark.parametrize(
    ("options", "expected"),
    (
        ([{"id": "effort", "value": "high"}], "high"),
        ([{"id": "thought_level", "value": "medium"}], "medium"),
        ([{"id": "variant", "value": "fast"}, {"id": "reasoningEffort", "value": "low"}], "low"),
        ({"reasoningEffort": "xhigh"}, "xhigh"),
        ([{"id": "fastMode", "value": True}], None),
        ([], None),
    ),
)
def test_reasoning_effort_reads_the_array_shape_t3_writes(options, expected) -> None:
    raw = json.dumps({"instanceId": "x", "model": "m", "options": options})

    assert t3_compat._parse_model_selection(raw)[2] == expected


@pytest.mark.parametrize("provider, expected", [("codex", "codex"), ("acpRegistry_new", "other")])
def test_active_run_provider_overrides_thread_default(tmp_path: Path, provider: str, expected: str) -> None:
    database = _v2(tmp_path)
    _thread(database, provider="claudeAgent")
    _run(database, "thread-1", 1, "running", provider=provider,
         provider_instance=provider + "-work", provider_thread="active-provider-session")
    thread = _only(read_t3_snapshot(base_dir=tmp_path))
    assert thread.provider == expected
    assert thread.provider_instance == provider + "-work"
    assert thread.provider_thread_id == "active-provider-session"
    assert thread.model is None and thread.reasoning_effort is None


def test_an_active_unbound_run_does_not_borrow_the_previous_provider_session(tmp_path: Path) -> None:
    database = _v2(tmp_path)
    _thread(database, provider="claudeAgent", active_provider_thread_id="old-claude-session")
    _run(database, "thread-1", 1, "running", provider="codex")
    thread = _only(read_t3_snapshot(base_dir=tmp_path))
    assert thread.provider == "codex" and thread.provider_thread_id is None


def test_completed_run_does_not_override_the_next_run_default(tmp_path: Path) -> None:
    database = _v2(tmp_path)
    _thread(database, provider="claudeAgent")
    _run(database, "thread-1", 1, "completed", provider="codex")
    thread = _only(read_t3_snapshot(base_dir=tmp_path))
    assert thread.provider == "claude"
    assert thread.provider_instance == "claudeAgent"
    assert thread.model == "synthetic-model"


def test_old_run_schema_without_optional_identity_columns_keeps_default_mapping(tmp_path: Path) -> None:
    database = _v2(tmp_path)
    _thread(database)
    _run(database, "thread-1", 1, "running")
    with sqlite3.connect(database) as connection:
        for column in ("provider", "provider_instance_id", "provider_thread_id"):
            connection.execute(f"ALTER TABLE orchestration_v2_projection_runs DROP COLUMN {column}")
    thread = _only(read_t3_snapshot(base_dir=tmp_path))
    assert thread.provider == "claude" and thread.provider_thread_id == "provider-thread-1"


@pytest.mark.parametrize("kind", ["dynamic_tool_call", "auth_refresh"])
def test_internal_runtime_requests_do_not_need_a_person(tmp_path: Path, kind: str) -> None:
    database = _v2(tmp_path)
    _thread(database)
    _run(database, "thread-1", 1, "running")
    _request(database, "thread-1", kind)
    thread = _only(read_t3_snapshot(base_dir=tmp_path))
    assert thread.pending_approval_count == 0
    assert thread.to_agent_status().mode is AgentMode.WORKING


@pytest.mark.parametrize("age", [300, 3700])
def test_rereading_old_running_row_does_not_prove_owner_liveness(tmp_path: Path, age: int) -> None:
    from datetime import datetime, timedelta, timezone

    from jrbar.collector import LiveAgentMonitor
    from jrbar.operator_state import BootIdentifier, ClockSample

    now = datetime(2026, 10, 7, 12, tzinfo=timezone.utc)
    old = (now - timedelta(seconds=age)).isoformat()
    database = _v2(tmp_path)
    _thread(database, updated_at=old)
    _run(database, "thread-1", 1, "running", requested_at=old)
    snapshot = read_t3_snapshot(base_dir=tmp_path, now=lambda: now)
    monitor = LiveAgentMonitor(
        clock_sampler=lambda: ClockSample(now.timestamp(), 1, BootIdentifier("boot:test")),
    )
    rows = snapshot.agent_statuses()
    assert rows[0].mode is AgentMode.WORKING
    assert rows[0].updated_at.isoformat() == old
    monitor.replace_external_statuses("t3code", rows)
    assert not any(
        row.mode is AgentMode.WORKING and not row.stale
        for row in monitor.snapshot().statuses
    )
