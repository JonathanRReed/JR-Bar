from __future__ import annotations

import ast
from datetime import datetime, timezone
from pathlib import Path
from types import SimpleNamespace

import pytest

from jrbar.collector import LiveAgentMonitor, LiveSessionMemory
from jrbar.core_projection import build_state_document
from jrbar.liveness_sweep import reap_dead_agents
from jrbar.models import AgentMode, AgentStatus, HookEvent
from jrbar.operator_state import BootIdentifier, ClockSample

STAMP = datetime(2026, 10, 13, tzinfo=timezone.utc)


def monitor_at(monkeypatch, age, event="PreToolUse", provider="codex"):
    wall = [STAMP.timestamp()]
    monkeypatch.setattr("jrbar.collector.time.time", lambda: wall[0])
    monitor = LiveAgentMonitor(clock_sampler=lambda: ClockSample(
        wall[0], wall[0] - STAMP.timestamp() + 100, BootIdentifier("test-boot")
    ))
    monitor.ingest_record(HookEvent(
        provider=provider, logged_at=STAMP, event_name=event,
        session_id="synthetic-session", tool_name="Bash",
        raw={"hook_event_name": event, "session_id": "synthetic-session",
             "tool_name": "Bash"},
    ))
    wall[0] += age
    return monitor, wall


@pytest.mark.parametrize("age", [300, 3601])
def test_live_process_keeps_quiet_work_in_both_production_projections(monkeypatch, age):
    monitor, wall = monitor_at(monkeypatch, age)
    monitor.note_live_sessions([("codex", "synthetic-session")], now=wall[0])
    snapshot = monitor.snapshot()
    assert len(snapshot.statuses) == 1
    assert snapshot.statuses[0].mode is AgentMode.TOOL_RUNNING
    assert not snapshot.statuses[0].stale
    assert snapshot.aggregate.mode is AgentMode.TOOL_RUNNING
    current = tuple(monitor.current_statuses_by_key().values())
    assert len(current) == 1
    assert current[0].mode is AgentMode.TOOL_RUNNING
    assert not current[0].stale
    wire = build_state_document(now=wall[0], generation=1, snapshot=snapshot,
        operator_state=monitor.operator_state, ask_statuses=[], unseen_completion_ids=frozenset())
    assert wire["aggregate"]["mode"] == "working"
    assert wire["aggregate"]["active"] == 1
    assert len(wire["sessions"]) == 1
    assert wire["sessions"][0]["mode"] == "tool_running"
    assert not wire["sessions"][0]["stale"]


@pytest.mark.parametrize("evidence", ["absent", "wrong-session", "expired", "future"])
@pytest.mark.parametrize("age", [300, 3601])
def test_unvouched_process_does_not_preserve_quiet_work(monkeypatch, age, evidence):
    monitor, wall = monitor_at(monkeypatch, age)
    if evidence != "absent":
        session = "other-session" if evidence == "wrong-session" else "synthetic-session"
        offset = -31 if evidence == "expired" else 1 if evidence == "future" else 0
        monitor.note_live_sessions([("codex", session)], now=wall[0] + offset)
    snapshot = monitor.snapshot()
    rows = (*snapshot.statuses, *snapshot.stale_statuses)
    assert all(row.mode is not AgentMode.TOOL_RUNNING for row in rows)
    assert not rows if age > 3600 else len(rows) == 1
    assert all(row.mode is not AgentMode.TOOL_RUNNING
               for row in monitor.current_statuses_by_key().values())


@pytest.mark.parametrize("event", ["Stop", "SessionStart"])
def test_live_terminal_does_not_keep_finished_or_idle_row_past_horizon(monkeypatch, event):
    monitor, wall = monitor_at(monkeypatch, 3601, event=event)
    monitor.note_live_sessions([("codex", "synthetic-session")], now=wall[0])
    snapshot = monitor.snapshot()
    assert not snapshot.statuses
    assert not snapshot.stale_statuses
    assert not monitor.current_statuses_by_key()


def test_shared_host_without_session_evidence_does_not_preserve_work(monkeypatch):
    monitor, _ = monitor_at(monkeypatch, 3601, provider="devin")
    monitor.note_live_sessions([])
    assert not monitor.snapshot().statuses
    assert not monitor.current_statuses_by_key()


def test_live_evidence_expires_after_previous_success(monkeypatch):
    monitor, wall = monitor_at(monkeypatch, 300)
    monitor.note_live_sessions([("codex", "synthetic-session")], now=wall[0])
    assert monitor.snapshot().statuses[0].mode is AgentMode.TOOL_RUNNING
    wall[0] += 31
    assert monitor.snapshot().statuses[0].mode is AgentMode.ENDED_UNCONFIRMED


def test_unanswered_ask_stays_visible_without_process_evidence(monkeypatch):
    monitor, _ = monitor_at(monkeypatch, 3601, event="PermissionRequest")
    snapshot = monitor.snapshot()
    assert snapshot.statuses[0].mode is AgentMode.WAITING_FOR_INPUT
    assert next(iter(monitor.current_statuses_by_key().values())).mode is AgentMode.WAITING_FOR_INPUT


def test_liveness_callback_failure_is_not_treated_as_affirmative_evidence(monkeypatch):
    monitor, _ = monitor_at(monkeypatch, 300)

    def failed(_):
        raise RuntimeError("synthetic liveness failure")

    monitor.session_is_live = failed
    with pytest.raises(RuntimeError, match="synthetic liveness failure"):
        monitor.snapshot()


@pytest.mark.parametrize("replacement", [[], [("codex", "different-session")]])
def test_publication_cannot_freshen_old_process_evidence(monkeypatch, replacement):
    now = STAMP.timestamp()
    monkeypatch.setattr("jrbar.collector.time.time", lambda: now)
    old = AgentStatus("codex", "codex:session:old", "Synthetic",
                      AgentMode.WORKING, STAMP, "PreToolUse", session_id="old")
    reads = []

    class ObservedMemory(LiveSessionMemory):
        revision = 0
        observing = False

        def __setattr__(self, name, value):
            super().__setattr__(name, value)
            if self.observing and name in {"_live_sessions_at", "_live_session_evidence"}:
                reads.append(self.session_is_live(old))

    memory = ObservedMemory()
    memory.note_live_sessions([("codex", "old")], now=now - 31)
    assert not memory.session_is_live(old)
    memory.observing = True
    memory.note_live_sessions(replacement, now=now)
    assert reads == [False]
    assert not memory.session_is_live(old)
    assert memory.revision == 2
    memory.note_live_sessions(replacement, now=now)
    assert memory.revision == 2


def test_liveness_candidates_bootstrap_old_work_without_displaying_it(monkeypatch):
    monitor, wall = monitor_at(monkeypatch, 3601)
    assert not monitor.snapshot().statuses
    assert not monitor.current_statuses_by_key()
    candidates = tuple(monitor.liveness_statuses_by_key().values())
    assert len(candidates) == 1
    assert candidates[0].mode is AgentMode.TOOL_RUNNING
    assert monitor.note_live_sessions([("codex", candidates[0].session_id)], now=wall[0])
    assert monitor.snapshot().statuses[0].mode is AgentMode.TOOL_RUNNING
    assert not monitor.note_live_sessions([("codex", candidates[0].session_id)], now=wall[0])


@pytest.mark.parametrize("offset", [-31, 1])
def test_same_pair_recovery_changes_revision_and_requests_refresh(monkeypatch, offset):
    monitor, wall = monitor_at(monkeypatch, 3601)
    pairs = [("codex", "synthetic-session")]
    monitor.note_live_sessions(pairs, now=wall[0] + offset)
    revision = monitor.revision
    assert monitor.note_live_sessions(pairs, now=wall[0])
    assert monitor.revision == revision + 1
    assert not monitor.note_live_sessions(pairs, now=wall[0])


@pytest.mark.parametrize("event", ["Stop", "SessionStart"])
def test_liveness_candidates_do_not_retain_old_idle_or_completed_rows(monkeypatch, event):
    monitor, _ = monitor_at(monkeypatch, 3601, event=event)
    assert not monitor.liveness_statuses_by_key()


def production_reap():
    # Execute the production method without importing its native UI host.
    path = Path(__file__).parents[1] / "src/jrbar/daemon_controller.py"
    tree = ast.parse(path.read_text())
    method = next(node for node in ast.walk(tree)
                  if isinstance(node, ast.FunctionDef) and node.name == "reap_dead_agent_processes")
    namespace = {"__name__": "jrbar.daemon_controller", "__package__": "jrbar",
                 "time": __import__("time"), "log_status_bar": lambda _: None,
                 "stale_after_seconds_for": lambda _: 300,
                 "expire_after_seconds_for": lambda _: 7200}
    exec(compile(ast.Module(body=[method], type_ignores=[]), str(path), "exec"), namespace)
    return namespace[method.name]


@pytest.mark.parametrize("alive", [True, False])
def test_production_reap_recovers_after_sleep_and_only_refreshes_on_change(monkeypatch, alive):
    monitor, wall = monitor_at(monkeypatch, 3601)
    seen = []

    class SyntheticSweeper:
        def classify(self, sessions):
            seen.append(tuple(sessions))
            return [], frozenset(sessions) if alive else frozenset()

    def synthetic_reap(statuses, **kwargs):
        return reap_dead_agents(statuses, **kwargs, claude_activity_loader=lambda: {})

    monkeypatch.setattr("jrbar.liveness_sweep.reap_dead_agents", synthetic_reap)
    controller = SimpleNamespace(monitor=monitor, _process_sweeper=SyntheticSweeper(),
                                 settings=None, _record_expired_asks=lambda _: None)
    reap = production_reap()
    assert reap(controller) is alive
    assert seen == [(('codex', 'synthetic-session'),)]
    assert bool(monitor.snapshot().statuses) is alive
    assert not reap(controller)
    if alive:
        wall[0] += 31
        assert reap(controller)
        assert not reap(controller)
