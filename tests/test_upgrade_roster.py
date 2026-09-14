"""W02 upgrade regressions: the roster is independent of panel visibility.

``state.sessions`` is a view — ``filter_visible_sessions`` ages finished
mains out after twenty minutes, quiet live rows after ten, and drops a
worker whose parent left the list. ``list_roster`` must answer what the
daemon actually *knows*: the same projected rows, unfiltered, with the
panel's verdict attached as a fact (``visibility``) instead of a removal,
plus the separated ``axes`` (outcome/review/freshness) spec §14.2 keeps
apart. Workers keep their parent links; provider-namespaced ids never
merge by title.
"""

from __future__ import annotations

import json
import os
import time
from datetime import datetime, timedelta, timezone
from pathlib import Path
from types import SimpleNamespace

import pytest

from jrbar import core_runtime
from jrbar.activity_model import RECORD_SCHEMA_VERSION, session_axes
from jrbar.agent_roster import (
    ROSTER_MAX_LIMIT,
    build_roster_document,
    roster_rows,
    scope_rows,
)
from jrbar.completion_visibility import (
    COMPLETED_VISIBLE_SECONDS,
    acknowledged_epoch_by_session,
    filter_visible_sessions,
)
from jrbar.core_projection import project_session_rows
from jrbar.models import AgentMode, AgentStatus
from jrbar.provider_facts import SourceKey, WorkIdentifier, WorkKey

NOW = 1_800_000_000.0
NOW_DT = datetime.fromtimestamp(NOW, tz=timezone.utc)


def _status(
    agent_id: str,
    *,
    provider: str = "codex",
    mode: AgentMode = AgentMode.WORKING,
    event_name: str = "UserPromptSubmit",
    minutes_ago: float = 1.0,
    stale: bool = False,
    session_id: str | None = None,
    work_id: str | None = None,
    now: float = NOW,
) -> AgentStatus:
    source = SourceKey(provider, "hooks", "local", "agent_events")
    collected_at = datetime.fromtimestamp(now, tz=timezone.utc)
    return AgentStatus(
        provider=provider,
        agent_id=agent_id,
        display_name=agent_id.rsplit(":", 1)[-1],
        mode=mode,
        updated_at=collected_at - timedelta(minutes=minutes_ago),
        event_name=event_name,
        session_id=session_id if session_id is not None else agent_id.rsplit(":", 1)[-1],
        stale=stale,
        work_key=WorkKey(source, WorkIdentifier(work_id or agent_id.replace(":", "."))),
    )


def _snapshot(*statuses: AgentStatus, stale: tuple[AgentStatus, ...] = ()) -> SimpleNamespace:
    return SimpleNamespace(
        statuses=tuple(statuses),
        stale_statuses=stale,
        collected_at=NOW_DT,
    )


def _project(snapshot, *, ask_statuses=()):
    return project_session_rows(snapshot, ask_statuses=ask_statuses)


def _roster(snapshot, *, ask_statuses=(), acknowledged_at_by_id=None, now=NOW):
    projected, ask_ids = _project(snapshot, ask_statuses=ask_statuses)
    return roster_rows(
        projected,
        ask_ids=ask_ids,
        acknowledged_at_by_id=acknowledged_at_by_id or {},
        now=now,
    )


def test_roster_keeps_what_the_panel_ages_out():
    """A completed main past the twenty-minute window leaves
    ``state.sessions``; the roster still lists it, marked ``hidden``."""
    old_done = _status(
        "codex:session:old",
        mode=AgentMode.COMPLETED,
        event_name="Stop",
        minutes_ago=(COMPLETED_VISIBLE_SECONDS / 60) + 5,
        stale=True,
    )
    live = _status("codex:session:live", minutes_ago=0.5)
    snapshot = _snapshot(live, stale=(old_done,))

    projected, ask_ids = _project(snapshot)
    visible, hidden_count, _ = filter_visible_sessions(projected, now=NOW, pinned_ids=ask_ids)
    assert {row["id"] for row in visible} == {"codex:session:live"}
    assert hidden_count == 1

    rows = _roster(snapshot)
    by_id = {row["id"]: row for row in rows}
    assert set(by_id) == {"codex:session:live", "codex:session:old"}
    assert by_id["codex:session:old"]["visibility"] == "hidden"
    assert by_id["codex:session:old"]["lifecycle"] == "completed"
    assert by_id["codex:session:live"]["visibility"] == "live"


def test_worker_under_a_hidden_parent_is_still_rostered():
    """The panel drops an orphan worker row; the roster keeps it, parent
    link intact — children can outlive a parent turn (spec §14.2/T14)."""
    parent = _status(
        "codex:session:parent",
        mode=AgentMode.COMPLETED,
        event_name="Stop",
        minutes_ago=(COMPLETED_VISIBLE_SECONDS / 60) + 5,
        stale=True,
        session_id="parent",
    )
    worker = _status(
        "codex:agent:worker1",
        mode=AgentMode.WORKING,
        minutes_ago=0.5,
        session_id="parent",
        work_id="worker1",
    )
    snapshot = _snapshot(worker, stale=(parent,))
    assert worker.is_subagent and worker.parent_agent_id == "codex:session:parent"

    projected, ask_ids = _project(snapshot)
    # The panel drops the orphan: its own verdict is live, but the filter
    # hides a worker whose parent left the list.
    visible, hidden_count, _ = filter_visible_sessions(projected, now=NOW, pinned_ids=ask_ids)
    assert visible == []
    assert hidden_count == 1

    rows = _roster(snapshot)
    by_id = {row["id"]: row for row in rows}
    assert set(by_id) == {"codex:agent:worker1", "codex:session:parent"}
    assert by_id["codex:agent:worker1"]["kind"] == "worker"
    assert by_id["codex:agent:worker1"]["parent"] == "codex:session:parent"
    # The roster reports each row's own verdict — the orphan rule is a
    # panel behaviour, so the worker still reads ``live`` here.
    assert by_id["codex:agent:worker1"]["visibility"] == "live"
    assert by_id["codex:session:parent"]["visibility"] == "hidden"


def test_axes_stay_separate_through_the_wire_shape():
    """T35: lifecycle ended + outcome unreported + review unreviewed must
    all be true of one row at once — nothing folds them together."""
    ended = _status(
        "codex:session:ended",
        mode=AgentMode.ENDED_UNCONFIRMED,
        event_name="PreCompact",
        minutes_ago=2,
    )
    failed = _status(
        "devin:session:bad", provider="devin", mode=AgentMode.BLOCKED_ERROR, event_name="PostToolUseFailure"
    )
    done = _status(
        "claude:session:clean",
        provider="claude",
        mode=AgentMode.COMPLETED,
        event_name="Stop",
        minutes_ago=1,
    )
    working = _status("codex:session:busy", mode=AgentMode.TOOL_RUNNING)
    quiet_stale = _status(
        "codex:session:quiet", mode=AgentMode.WORKING, minutes_ago=3, stale=True
    )
    rows = _roster(_snapshot(ended, failed, done, working, stale=(quiet_stale,)))
    by_id = {row["id"]: row for row in rows}

    assert by_id["codex:session:ended"]["axes"] == {
        "outcome": "unreported",
        "review": "unreviewed",
        "freshness": "live",
    }
    assert by_id["devin:session:bad"]["axes"]["outcome"] == "failed"
    assert by_id["devin:session:bad"]["axes"]["review"] == "unreviewed"
    assert by_id["claude:session:clean"]["axes"]["outcome"] == "succeeded"
    assert by_id["codex:session:busy"]["axes"] == {
        "outcome": "none",
        "review": "pending",
        "freshness": "live",
    }
    assert by_id["codex:session:quiet"]["axes"]["freshness"] == "delayed"


def test_axes_unknowns_stay_unknown():
    axes = session_axes(lifecycle="active", stale=False, updated_at=None, acknowledged=False)
    assert axes["freshness"] == "unknown"
    axes = session_axes(lifecycle="mystery", stale=False, updated_at=NOW, acknowledged=False)
    assert axes["outcome"] == "unknown"


def test_acknowledgement_moves_review_not_visibility():
    """Cleared = reviewed — the roster still lists the session (panel
    aging is a view), and ``review`` flips without touching lifecycle."""
    done = _status(
        "codex:session:cleared",
        mode=AgentMode.COMPLETED,
        event_name="Stop",
        minutes_ago=2,
    )
    snapshot = _snapshot(done)
    projected, _ = _project(snapshot)
    updated_at = projected[0]["updated_at"]
    key = SimpleNamespace(agent_id="codex:session:cleared", completed_at_epoch=updated_at + 1)
    ack = acknowledged_epoch_by_session((key,))
    rows = _roster(snapshot, acknowledged_at_by_id=ack)
    (row,) = rows
    assert row["axes"]["review"] == "reviewed"
    assert row["lifecycle"] == "completed"
    assert row["visibility"] == "hidden"


def test_similar_native_ids_across_providers_never_merge():
    """T14: provider-namespaced agent ids are the roster's identity —
    two accounts reporting work id ``run-7`` stay two records."""
    codex = _status("codex:session:run-7", work_id="run-7", session_id="run-7")
    claude = _status(
        "claude:session:run-7", provider="claude", work_id="run-7", session_id="run-7"
    )
    rows = _roster(_snapshot(codex, claude))
    assert {row["id"] for row in rows} == {"codex:session:run-7", "claude:session:run-7"}
    assert {row["provider"] for row in rows} == {"codex", "claude"}


def test_attention_scope_and_pins():
    asking = _status(
        "codex:session:asking",
        mode=AgentMode.WAITING_FOR_INPUT,
        event_name="PermissionRequest",
    )
    other = _status("codex:session:other", minutes_ago=0.5)
    snapshot = _snapshot(asking, other)
    rows = _roster(snapshot, ask_statuses=(asking,))
    doc = build_roster_document(rows, now=NOW, scope="attention")
    assert [row["id"] for row in doc["sessions"]] == ["codex:session:asking"]
    assert doc["counts"]["attention"] == 1
    assert doc["counts"]["total"] == 2
    by_id = {row["id"]: row for row in rows}
    assert by_id["codex:session:asking"]["pinned"] is True
    assert by_id["codex:session:other"]["pinned"] is False
    assert by_id["codex:session:asking"]["ask"] is not None


def test_scopes_and_filters():
    parent = _status(
        "codex:session:parent", mode=AgentMode.WORKING, session_id="parent", work_id="parent"
    )
    worker = _status(
        "codex:agent:w1",
        mode=AgentMode.WORKING,
        session_id="parent",
        work_id="w1",
    )
    done = _status(
        "claude:session:fin",
        provider="claude",
        mode=AgentMode.COMPLETED,
        event_name="Stop",
        minutes_ago=1,
    )
    rows = _roster(_snapshot(parent, worker, done))

    workers = scope_rows(rows, scope="workers")
    assert [row["id"] for row in workers] == ["codex:agent:w1"]
    children = scope_rows(rows, scope="all", parent="codex:session:parent")
    assert [row["id"] for row in children] == ["codex:agent:w1"]
    finished = scope_rows(rows, scope="finished")
    assert [row["id"] for row in finished] == ["claude:session:fin"]
    claude_only = scope_rows(rows, scope="all", provider="claude")
    assert [row["id"] for row in claude_only] == ["claude:session:fin"]
    since = scope_rows(rows, scope="all", since=NOW - 90)
    assert {row["id"] for row in since} == {
        "codex:session:parent",
        "codex:agent:w1",
        "claude:session:fin",
    }
    # All three rows are a minute old: nothing is newer than ``now``.
    since_newer = scope_rows(rows, scope="all", since=NOW)
    assert since_newer == []


def test_limit_bounds_and_document_shape():
    statuses = tuple(
        _status(f"codex:session:s{i}", work_id=f"s{i}", session_id=f"s{i}")
        for i in range(5)
    )
    rows = _roster(_snapshot(*statuses))
    doc = build_roster_document(rows, now=NOW, scope="all", limit=3)
    assert len(doc["sessions"]) == 3
    assert doc["counts"]["total"] == 5 and doc["counts"]["listed"] == 3
    assert doc["t"] == "roster" and doc["schema"] == RECORD_SCHEMA_VERSION
    assert doc["coverage"]["history"] == "list_history"
    # The cap is real, not a suggestion.
    many = scope_rows(rows, scope="all", limit=ROSTER_MAX_LIMIT * 4)
    assert len(many) == 5
    for row in doc["sessions"]:
        assert row["schema"] == RECORD_SCHEMA_VERSION
        for field in ("id", "provider", "kind", "mode", "lifecycle", "axes", "visibility", "pinned"):
            assert field in row, field
        assert set(row["axes"]) == {"outcome", "review", "freshness"}


def test_list_roster_command_round_trips():
    """The socket command projects the same rows the pure path does —
    this exercises the runtime wiring, extras cache included."""
    # The command reads the real clock, so this fixture's clock is real.
    now = time.time()
    asking = _status(
        "codex:session:asking",
        mode=AgentMode.WAITING_FOR_INPUT,
        event_name="PermissionRequest",
        now=now,
    )
    done = _status(
        "codex:session:old",
        mode=AgentMode.COMPLETED,
        event_name="Stop",
        minutes_ago=(COMPLETED_VISIBLE_SECONDS / 60) + 5,
        stale=True,
        now=now,
    )
    controller = SimpleNamespace(
        last_snapshot=_snapshot(asking, stale=(done,)),
        current_operator_state=None,
        _answer_contracts_by_source=None,
        answer_handler_registry=None,
        _core_state_generation=9,
        _core_extras={},
        _core_ask_statuses=lambda: (asking,),
        _core_snoozed_untils=lambda statuses: {},
        _core_acknowledged_keys=lambda: frozenset(),
        _core_extras_for=lambda status: None,
    )
    doc = core_runtime._cmd_list_roster(controller, {"scope": "all"})
    assert doc["t"] == "roster" and doc["generation"] == 9
    assert doc["counts"]["total"] == 2 and doc["counts"]["attention"] == 1
    by_id = {row["id"]: row for row in doc["sessions"]}
    assert by_id["codex:session:asking"]["pinned"] is True
    assert by_id["codex:session:old"]["visibility"] == "hidden"

    attention = core_runtime._cmd_list_roster(controller, {"scope": "attention"})
    assert [row["id"] for row in attention["sessions"]] == ["codex:session:asking"]

    with pytest.raises(core_runtime.CommandError) as error:
        core_runtime._cmd_list_roster(controller, {"scope": "everything"})
    assert error.value.code == "invalid_value"


def test_empty_snapshot_is_an_empty_honest_roster():
    controller = SimpleNamespace(
        last_snapshot=None,
        current_operator_state=None,
        _answer_contracts_by_source=None,
        answer_handler_registry=None,
        _core_state_generation=0,
        _core_extras={},
        _core_ask_statuses=lambda: (),
        _core_snoozed_untils=lambda statuses: {},
        _core_acknowledged_keys=lambda: frozenset(),
        _core_extras_for=lambda status: None,
    )
    doc = core_runtime._cmd_list_roster(controller, {})
    assert doc["sessions"] == [] and doc["counts"]["total"] == 0
    assert doc["coverage"]["source"] == "collector_snapshot"


SWIFT_ROSTER_FIXTURE = (
    Path(__file__).resolve().parent.parent
    / "app" / "Tests" / "JRBarCoreTests" / "Fixtures" / "python-roster.json"
)


def _carried_by(fixture: object, document: object, path: str = "$") -> list[str]:
    """Directional parity, as in ``test_core_projection``: every key the
    Swift fixture names must still arrive with the same shape and value;
    fields the daemon adds later are ignored."""
    if isinstance(fixture, dict):
        if not isinstance(document, dict):
            return [f"{path}: fixture has an object, document has {type(document).__name__}"]
        mismatches = []
        for key, value in fixture.items():
            if key not in document:
                mismatches.append(f"{path}.{key}: missing from the roster document")
            else:
                mismatches += _carried_by(value, document[key], f"{path}.{key}")
        return mismatches
    if isinstance(fixture, list):
        if not isinstance(document, list) or len(fixture) != len(document):
            return [f"{path}: fixture has {len(fixture)} rows, document has "
                    f"{len(document) if isinstance(document, list) else type(document).__name__}"]
        mismatches = []
        for index, (want, got) in enumerate(zip(fixture, document)):
            mismatches += _carried_by(want, got, f"{path}[{index}]")
        return mismatches
    return [] if fixture == document else [f"{path}: {fixture!r} != {document!r}"]


def test_swift_roster_fixture_matches_the_document() -> None:
    """The Swift Overview decodes a roster document generated here — the
    fields the app reads (id, axes, visibility, pinned, counts, coverage)
    must exist with these exact shapes."""
    asking = _status(
        "codex:session:asking",
        mode=AgentMode.WAITING_FOR_INPUT,
        event_name="PermissionRequest",
    )
    worker = _status(
        "claude:agent:w1", provider="claude", session_id="run-9", work_id="w1"
    )
    aged = _status(
        "gemini:session:old",
        provider="gemini",
        mode=AgentMode.COMPLETED,
        event_name="Stop",
        minutes_ago=(COMPLETED_VISIBLE_SECONDS / 60) + 5,
        stale=True,
    )
    snapshot = _snapshot(asking, worker, stale=(aged,))
    rows = _roster(snapshot, ask_statuses=(asking,))
    document = build_roster_document(rows, now=NOW, scope="all")
    encoded = json.dumps(document, indent=1, sort_keys=True) + "\n"
    if os.environ.get("JRBAR_UPDATE_FIXTURES") == "1":
        SWIFT_ROSTER_FIXTURE.write_text(encoded, encoding="utf-8")
    assert SWIFT_ROSTER_FIXTURE.exists(), (
        "run with JRBAR_UPDATE_FIXTURES=1 to write the Swift fixture"
    )
    mismatches = _carried_by(
        json.loads(SWIFT_ROSTER_FIXTURE.read_text(encoding="utf-8")),
        json.loads(encoded),
    )
    assert mismatches == [], "\n".join(mismatches)
