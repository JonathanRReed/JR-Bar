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
from datetime import datetime
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
        ("interrupted", AgentMode.ENDED_UNCONFIRMED),
        ("cancelled", AgentMode.ENDED_UNCONFIRMED),
        ("rolled_back", AgentMode.ENDED_UNCONFIRMED),
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


def test_subagents_are_retained_but_archived_and_deleted_threads_are_not_listed(tmp_path: Path) -> None:
    database = _v2(tmp_path)
    _thread(database, "thread-main")
    _thread(database, "thread-sub", relationship="subagent")
    _thread(database, "thread-archived", archived_at=NOW)
    _thread(database, "thread-deleted", deleted_at=NOW)

    snapshot = read_t3_snapshot(base_dir=tmp_path, now=lambda: datetime.fromisoformat(NOW))

    assert [thread.thread_id for thread in snapshot.threads] == ["thread-main", "thread-sub"]
    assert snapshot.threads[1].to_agent_status().is_subagent


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


def test_native_bindings_and_subagents_join_cross_provider_groups_read_only(tmp_path):
    from jrbar.agent_groups import resolve_agent_groups
    from tests.test_agent_groups import NOW as LINEAGE_NOW
    from tests.test_agent_groups import fixture

    database = _v2(tmp_path)
    data = fixture("t3")
    (database.parent / "settings.json").write_text(json.dumps(fixture("t3-providers")))
    for row in data["threads"]:
        _thread(database, row["thread_id"], provider=row["default_provider"],
                active_provider_thread_id=row["active_provider_thread_id"])
        _run(database, row["thread_id"], 1, "running",
             provider=row["default_provider"], provider_thread=row["active_provider_thread_id"])
    with sqlite3.connect(database) as connection:
        connection.execute("CREATE TABLE orchestration_v2_projection_provider_threads "
                           "(provider_thread_id TEXT, thread_id TEXT, driver TEXT, provider_instance_id TEXT, payload_json TEXT)")
        for binding in data["bindings"]:
            connection.execute("INSERT INTO orchestration_v2_projection_provider_threads VALUES (?,?,?,?,?)",
                               (binding["provider_thread_id"], binding["thread_id"], binding["driver"],
                                binding["provider_instance_id"], json.dumps(binding["payload_json"])))
        for row in data["threads"]:
            payload = row["payload_json"] if row["thread_id"] != "factory-child" else {}
            connection.execute("UPDATE orchestration_v2_projection_threads SET payload_json=? WHERE thread_id=?",
                               (json.dumps(payload), row["thread_id"]))
        connection.execute("CREATE TABLE orchestration_v2_projection_subagents "
                           "(thread_id TEXT, child_thread_id TEXT, status TEXT, payload_json TEXT)")
        connection.execute("INSERT INTO orchestration_v2_projection_subagents VALUES ('root','factory-child','running','{}')")
    before = database.read_bytes()
    from datetime import datetime, timezone
    snapshot = read_t3_snapshot(base_dir=tmp_path, now=lambda: datetime.fromtimestamp(LINEAGE_NOW, timezone.utc))
    assert snapshot.compatible
    statuses = snapshot.agent_statuses()
    assert len(statuses) == 4
    result = resolve_agent_groups(statuses, now=LINEAGE_NOW)
    assert len(result.groups) == 1
    assert result.groups[0].root_work_key == "claude:session:native-root"
    assert result.groups[0].members == tuple(sorted(s.agent_id for s in statuses))
    assert database.read_bytes() == before


def test_oversize_payload_keeps_thread_without_lineage(tmp_path):
    database = _v2(tmp_path)
    _thread(database, "good")
    _thread(database, "large")
    with sqlite3.connect(database) as connection:
        connection.execute("UPDATE orchestration_v2_projection_threads SET payload_json=? WHERE thread_id='large'",
                           (json.dumps({"padding": "x" * (129 * 1024)}),))
    snapshot = read_t3_snapshot(base_dir=tmp_path)
    assert snapshot.compatible
    assert [row.thread_id for row in snapshot.threads] == ["good", "large"]
    assert snapshot.threads[1].parent_links == ()


def test_subagent_threads_do_not_consume_the_main_thread_window(tmp_path, monkeypatch):
    monkeypatch.setattr(t3_compat, "T3_MAX_THREADS", 2)
    database = _v2(tmp_path)
    for key in ("worker-a", "worker-b", "worker-c"):
        _thread(database, key, relationship="subagent")
    _thread(database, "root-a", updated_at=EARLIER)
    _thread(database, "root-b", updated_at=EARLIER)
    snapshot = read_t3_snapshot(base_dir=tmp_path, now=lambda: datetime.fromisoformat(NOW))
    assert {"root-a", "root-b"} <= {row.thread_id for row in snapshot.threads}
    assert snapshot.truncated


def test_incremental_reader_joins_only_changed_or_live_threads(tmp_path, monkeypatch):
    database = _v2(tmp_path)
    for key in ('idle', 'changed', 'live'):
        _thread(database, key)
    _run(database, 'live', 1, 'running')
    cache = t3_compat._V2ReadCache()
    token = t3_compat._v2_read_cache.set(cache)
    statements = []
    original = t3_compat._open_read_only

    def connect(*args, **kwargs):
        connection = original(*args, **kwargs)
        connection.set_trace_callback(statements.append)
        return connection

    monkeypatch.setattr(t3_compat, '_open_read_only', connect)
    try:
        first = read_t3_snapshot(base_dir=tmp_path, now=lambda: datetime.fromisoformat(NOW))
        assert len(first.threads) == 3
        with sqlite3.connect(database) as connection:
            connection.execute("UPDATE orchestration_v2_projection_threads SET title='Changed', updated_at='2026-10-07T12:01:00Z' WHERE thread_id='changed'")
            connection.execute("UPDATE orchestration_v2_projection_runs SET status='completed' WHERE thread_id='live'")
        statements.clear()
        second = read_t3_snapshot(base_dir=tmp_path, now=lambda: datetime.fromisoformat(NOW))
        by_id = {row.thread_id: row for row in second.threads}
        assert by_id['changed'].thread_title == 'Changed'
        assert by_id['live'].to_agent_status().mode is AgentMode.COMPLETED
        assert by_id['idle'] == next(row for row in first.threads if row.thread_id == 'idle')
        joins = [sql for sql in statements if 'WITH candidate_threads' in sql]
        assert len(joins) == 1
        assert "IN ('changed','live')" in joins[0]
        assert cache.watermark == datetime.fromisoformat('2026-10-07T12:01:00Z')
        statements.clear()
        read_t3_snapshot(base_dir=tmp_path, now=lambda: datetime.fromisoformat(NOW))
        assert not any('WITH candidate_threads' in sql for sql in statements)
        with sqlite3.connect(database) as connection:
            connection.execute("UPDATE orchestration_v2_projection_threads SET archived_at=?, updated_at='2026-10-07T12:02:00Z' WHERE thread_id='changed'", (NOW,))
        assert 'changed' not in {row.thread_id for row in read_t3_snapshot(base_dir=tmp_path).threads}
    finally:
        t3_compat._v2_read_cache.reset(token)


def test_old_finished_workers_are_omitted_but_old_active_workers_stay(tmp_path):
    database = _v2(tmp_path)
    for key in ('old-finished', 'old-live', 'recent'):
        _thread(database, key, relationship='subagent', updated_at='2026-10-07T11:55:00Z' if key == 'recent' else '2026-10-01T00:00:00Z')
    _run(database, 'old-live', 1, 'running')
    snapshot = read_t3_snapshot(base_dir=tmp_path, now=lambda: datetime.fromisoformat(NOW))
    assert {row.thread_id for row in snapshot.threads} == {'recent', 'old-live'}
    assert all('old-finished' not in link.child for row in snapshot.agent_statuses() for link in row.parent_links)


def test_live_subagents_and_their_parents_take_priority_over_history(tmp_path, monkeypatch):
    monkeypatch.setattr(t3_compat, 'T3_MAX_THREADS', 2)
    database = _v2(tmp_path)
    for key in ('recent-a', 'recent-b', 'recent-c'):
        _thread(database, key)
        _thread(database, 'worker-' + key, relationship='subagent')
    old = '2026-10-01T00:00:00Z'
    _thread(database, 'old-root', updated_at=old)
    _thread(database, 'old-worker', updated_at=old, relationship='subagent')
    _run(database, 'old-worker', 1, 'running')
    with sqlite3.connect(database) as connection:
        connection.execute('CREATE TABLE orchestration_v2_projection_subagents '
                           '(thread_id TEXT, child_thread_id TEXT, status TEXT, payload_json TEXT)')
        connection.execute("INSERT INTO orchestration_v2_projection_subagents VALUES ('old-root', 'old-worker', 'running', '{}')")
    result = read_t3_snapshot(base_dir=tmp_path, now=lambda: datetime.fromisoformat(NOW))
    assert {'old-root', 'old-worker'} <= {row.thread_id for row in result.threads}
    assert result.truncated


def test_registry_changes_refresh_cached_native_identity_without_thread_writes(tmp_path):
    database = _v2(tmp_path)
    _thread(database, provider='custom', active_provider_thread_id='binding')
    with sqlite3.connect(database) as connection:
        connection.execute('CREATE TABLE orchestration_v2_projection_provider_threads '
                           '(provider_thread_id TEXT, thread_id TEXT, driver TEXT, provider_instance_id TEXT, payload_json TEXT)')
        connection.execute('INSERT INTO orchestration_v2_projection_provider_threads VALUES (?,?,?,?,?)',
                           ('binding', 'thread-1', 'acpRegistry', 'custom', json.dumps({
                               'nativeThreadRef': {'driver': 'acpRegistry', 'nativeId': 'native-root'}})))
    cache = t3_compat._V2ReadCache()
    token = t3_compat._v2_read_cache.set(cache)
    try:
        assert read_t3_snapshot(base_dir=tmp_path).threads[0].provider == 'other'
        (database.parent / 'settings.json').write_text(json.dumps({'providerInstances': {
            'custom': {'driver': 'acpRegistry', 'enabled': True, 'config': {'agentId': 'factory-droid'}}}}))
        refreshed = read_t3_snapshot(base_dir=tmp_path)
        assert refreshed.threads[0].provider == 'factory'
        assert refreshed.agent_statuses()[0].agent_id == 'factory:session:native-root'
    finally:
        t3_compat._v2_read_cache.reset(token)


def test_project_edits_and_deletion_invalidate_cached_threads(tmp_path):
    database = _v2(tmp_path)
    _thread(database)
    cache = t3_compat._V2ReadCache()
    token = t3_compat._v2_read_cache.set(cache)
    try:
        assert read_t3_snapshot(base_dir=tmp_path).threads[0].project_title == 'Synthetic'
        with sqlite3.connect(database) as connection:
            connection.execute("UPDATE projection_projects SET title='Renamed', workspace_root='/repo/renamed', updated_at='2026-10-07T12:02:00Z'")
        edited = read_t3_snapshot(base_dir=tmp_path).threads[0]
        assert edited.project_title == 'Renamed'
        assert edited.workspace_root == '/repo/renamed'
        with sqlite3.connect(database) as connection:
            connection.execute('UPDATE projection_projects SET deleted_at=?', (NOW,))
        assert read_t3_snapshot(base_dir=tmp_path).threads == ()
    finally:
        t3_compat._v2_read_cache.reset(token)


@pytest.mark.parametrize('mutation', [
    "DELETE FROM orchestration_v2_projection_threads WHERE thread_id='removed'",
    "UPDATE orchestration_v2_projection_threads SET archived_at='2026-10-07T12:01:00Z' WHERE thread_id='removed'",
    "UPDATE orchestration_v2_projection_threads SET deleted_at='2026-10-07T12:01:00Z' WHERE thread_id='removed'",
])
def test_periodic_reconciliation_drops_threads_without_timestamp_bumps(tmp_path, mutation):
    database = _v2(tmp_path)
    _thread(database, 'retained')
    _thread(database, 'removed')
    clock = [datetime.fromisoformat(NOW)]
    cache = t3_compat._V2ReadCache()
    token = t3_compat._v2_read_cache.set(cache)
    try:
        assert len(read_t3_snapshot(base_dir=tmp_path, now=lambda: clock[0]).threads) == 2
        with sqlite3.connect(database) as connection:
            connection.execute(mutation)
        clock[0] = datetime.fromisoformat('2026-10-07T12:03:00Z')
        snapshot = read_t3_snapshot(base_dir=tmp_path, now=lambda: clock[0])
        assert [thread.thread_id for thread in snapshot.threads] == ['retained']
        assert set(cache.rows) == set(cache.payloads) == set(cache.views) == set(cache.final_views) == {'retained'}
    finally:
        t3_compat._v2_read_cache.reset(token)


def test_incremental_watermark_handles_z_and_utc_offset_formats(tmp_path):
    database = _v2(tmp_path)
    _thread(database, 'same-second', updated_at='2026-10-07T12:00:00Z')
    cache = t3_compat._V2ReadCache()
    token = t3_compat._v2_read_cache.set(cache)
    try:
        read_t3_snapshot(base_dir=tmp_path)
        with sqlite3.connect(database) as connection:
            connection.execute("UPDATE orchestration_v2_projection_threads SET title='Newer fraction', "
                               "updated_at='2026-10-07T12:00:00.500+00:00' WHERE thread_id='same-second'")
        assert read_t3_snapshot(base_dir=tmp_path).threads[0].thread_title == 'Newer fraction'
    finally:
        t3_compat._v2_read_cache.reset(token)


def test_worker_cutoff_and_order_compare_instants_not_iso_spelling(tmp_path, monkeypatch):
    monkeypatch.setattr(t3_compat, 'T3_MAX_THREADS', 2)
    database = _v2(tmp_path)
    _thread(database, 'at-cutoff', relationship='subagent', updated_at='2026-10-07T11:50:00+00:00')
    _thread(database, 'after-cutoff', relationship='subagent', updated_at='2026-10-07T11:50:00.500Z')
    _thread(database, 'older-root', updated_at='2026-10-07T11:59:00Z')
    _thread(database, 'fractional-root', updated_at='2026-10-07T11:59:00.500+00:00')
    _thread(database, 'newest-root', updated_at='2026-10-07T11:59:01+00:00')
    snapshot = read_t3_snapshot(base_dir=tmp_path, now=lambda: datetime.fromisoformat(NOW))
    assert [row.thread_id for row in snapshot.threads] == [
        'newest-root', 'fractional-root', 'after-cutoff', 'at-cutoff',
    ]


@pytest.mark.parametrize('outcome,result,expected', [
    ('failed', 'Selected model is at capacity. Please try a different model.', AgentMode.ENDED_UNCONFIRMED),
    ('failed', 'Transport error: connection closed', AgentMode.ENDED_UNCONFIRMED),
    ('failed', 'Task assertion failed', AgentMode.BLOCKED_ERROR),
    ('cancelled', None, AgentMode.ENDED_UNCONFIRMED),
    ('interrupted', None, AgentMode.ENDED_UNCONFIRMED),
])
def test_delegated_worker_without_native_binding_keeps_its_explicit_parent(tmp_path, outcome, result, expected):
    from jrbar.agent_groups import resolve_agent_groups
    database = _v2(tmp_path)
    _thread(database, 'thread-parent', active_provider_thread_id='parent-binding')
    _run(database, 'thread-parent', 1, 'running')
    _thread(database, 'child', provider='codex', relationship='subagent', active_provider_thread_id='child-binding')
    _run(database, 'child', 1, outcome)
    with sqlite3.connect(database) as connection:
        connection.execute('CREATE TABLE orchestration_v2_projection_provider_threads '
                           '(provider_thread_id TEXT, thread_id TEXT, driver TEXT, status TEXT, payload_json TEXT)')
        connection.execute('INSERT INTO orchestration_v2_projection_provider_threads VALUES (?,?,?,?,?)',
                           ('parent-binding', 'thread-parent', 'claudeAgent', 'active',
                            json.dumps({'nativeThreadRef': {'driver': 'claudeAgent', 'nativeId': 'native-parent'}})))
        connection.execute('INSERT INTO orchestration_v2_projection_provider_threads VALUES (?,?,?,?,?)',
                           ('child-binding', 'child', 'codex', 'not_loaded', '{}'))
        connection.execute('CREATE TABLE orchestration_v2_projection_subagents '
                           '(thread_id TEXT, child_thread_id TEXT, status TEXT, payload_json TEXT)')
        connection.execute('INSERT INTO orchestration_v2_projection_subagents VALUES (?,?,?,?)',
                           ('thread-parent', 'child', outcome, json.dumps({'result': result})))
    before = database.read_bytes()
    now = datetime.fromisoformat(NOW)
    observed = read_t3_snapshot(base_dir=tmp_path, now=lambda: now)
    assert observed.compatible
    statuses = observed.agent_statuses()
    worker = next(status for status in statuses if status.is_subagent)
    assert worker.parent_agent_id == 'claude:session:native-parent'
    assert worker.mode is expected
    groups = resolve_agent_groups(statuses, now=now.timestamp())
    assert not groups.unlinked_workers
    assert len(groups.groups) == 1
    assert database.read_bytes() == before
    _run(database, 'child', 2, 'completed')
    resumed = read_t3_snapshot(base_dir=tmp_path, now=lambda: now)
    assert next(thread for thread in resumed.threads if thread.thread_id == 'child').to_agent_status().mode is AgentMode.COMPLETED


def test_settled_native_children_keep_lineage_after_the_activity_window(tmp_path):
    from jrbar.agent_groups import resolve_agent_groups
    database = _v2(tmp_path)
    _thread(database, 'root', active_provider_thread_id='parent-binding')
    _run(database, 'root', 1, 'running')
    _thread(database, 'old-child', provider='codex', updated_at=EARLIER, active_provider_thread_id='child-binding')
    _run(database, 'old-child', 1, 'interrupted')
    with sqlite3.connect(database) as connection:
        connection.execute('CREATE TABLE orchestration_v2_projection_provider_threads '
                           '(provider_thread_id TEXT, thread_id TEXT, driver TEXT, status TEXT, payload_json TEXT)')
        for tid, handle, driver, native in [('root', 'parent-binding', 'claudeAgent', 'native-root'),
                                            ('old-child', 'child-binding', 'codex', 'native-child')]:
            connection.execute('INSERT INTO orchestration_v2_projection_provider_threads VALUES (?,?,?,?,?)',
                               (handle, tid, driver, 'idle', json.dumps({'nativeThreadRef': {'driver': driver, 'nativeId': native}})))
        connection.execute('CREATE TABLE orchestration_v2_projection_subagents '
                           '(thread_id TEXT, child_thread_id TEXT, provider_thread_id TEXT, status TEXT, updated_at TEXT, payload_json TEXT)')
        connection.execute('INSERT INTO orchestration_v2_projection_subagents VALUES (?,?,?,?,?,?)',
                           ('root', 'old-child', 'child-binding', 'interrupted', EARLIER, '{}'))
    now = datetime.fromisoformat(NOW)
    observed = read_t3_snapshot(base_dir=tmp_path, now=lambda: now)
    assert observed.compatible
    assert [thread.thread_id for thread in observed.threads] == ['root']
    assert len(observed.native_workers) == 1
    assert observed.native_workers[0].event_name == 'LineageObserved'
    groups = resolve_agent_groups(observed.agent_statuses(), now=now.timestamp())
    assert groups.groups[0].members == ('claude:session:native-root', 'codex:session:native-child')
    assert not groups.unlinked_workers
