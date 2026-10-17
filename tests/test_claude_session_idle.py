"""A Claude turn the person stopped with Esc fires no hook.

Claude Code keeps ``<config home>/sessions/<pid>.json`` current with a
``status`` (``busy`` while it works, ``idle`` when it waits for the next
prompt) and ``statusUpdatedAt``. Hooks cannot report an interrupt, and a
live process beats the silence timer, so a stopped turn used to read
"Working" for as long as the terminal stayed open. The liveness sweep now
reads that status and ends the turn the way a Codex ``Interrupt`` does.
Synthetic data only.
"""

from __future__ import annotations

import json
from datetime import datetime, timedelta, timezone
from pathlib import Path

import pytest

from jrbar import process_registry as pr
from jrbar.liveness_sweep import reap_dead_agents
from jrbar.models import AgentMode, AgentStatus

SESSION = "11111111-2222-3333-4444-555555555555"
LAST_HOOK = datetime(2026, 10, 7, 12, 0, 0, tzinfo=timezone.utc)


def _session_file(home: Path, pid: int = 4101, **overrides) -> Path:
    folder = home / "sessions"
    folder.mkdir(parents=True, exist_ok=True)
    payload = {
        "pid": pid,
        "sessionId": SESSION,
        "startedAt": int((LAST_HOOK - timedelta(hours=1)).timestamp() * 1000),
        "status": "idle",
        "statusUpdatedAt": int((LAST_HOOK + timedelta(seconds=30)).timestamp() * 1000),
        "cwd": "/work/demo",
    }
    payload.update(overrides)
    path = folder / f"{pid}.json"
    path.write_text(json.dumps(payload), encoding="utf-8")
    return path


def _row(mode: AgentMode = AgentMode.WORKING, provider: str = "claude", agent_id: str | None = None):
    return AgentStatus(
        provider=provider,
        agent_id=agent_id or f"{provider}:session:{SESSION}",
        display_name="demo",
        mode=mode,
        updated_at=LAST_HOOK,
        event_name="PostToolUse",
        session_id=SESSION,
        cwd="/work/demo",
    )


def _sweeper(tmp_path: Path, home: Path, *, alive: bool = True) -> pr.ProcessSweeper:
    entry = pr.ProcessEntry(4101, 1, None, "claude")
    table = {4101: entry, 1: pr.ProcessEntry(1, 0, 0.0, "launchd")} if alive else {1: pr.ProcessEntry(1, 0, 0.0, "launchd")}
    return pr.ProcessSweeper(
        state_dir=tmp_path / "state",
        table_loader=lambda: table,
        claude_index_loader=lambda: pr.claude_session_index(home / "sessions"),
        clock=lambda: 1_790_000_000.0,
    )


def _reap(rows, sweeper, home: Path, sent: list):
    return reap_dead_agents(
        rows,
        sweeper=sweeper,
        refresh_hint_handler=None,
        process_payload=lambda provider, log, payload, **kw: sent.append((provider, json.loads(payload))),
        log_path_for=lambda provider: Path("/x"),
        claude_activity_loader=lambda: pr.claude_session_activity(home / "sessions"),
    )


def test_the_activity_reader_gives_status_and_when_it_changed(tmp_path: Path) -> None:
    _session_file(tmp_path)

    activity = pr.claude_session_activity(tmp_path / "sessions")

    assert set(activity) == {SESSION}
    assert activity[SESSION].status == "idle"
    assert activity[SESSION].changed_at == pytest.approx((LAST_HOOK + timedelta(seconds=30)).timestamp())


@pytest.mark.parametrize(
    "overrides",
    (
        {"status": 7},
        {"status": ""},
        {"status": "x" * 100},
        {"statusUpdatedAt": "yesterday"},
        {"statusUpdatedAt": True},
        {"statusUpdatedAt": float("nan")},
        {"sessionId": None},
        {"pid": 0},
    ),
)
def test_a_malformed_status_file_vouches_for_nothing(tmp_path: Path, overrides: dict) -> None:
    _session_file(tmp_path, **overrides)

    assert pr.claude_session_activity(tmp_path / "sessions") == {}


def test_an_oversized_or_unreadable_file_is_skipped(tmp_path: Path) -> None:
    path = _session_file(tmp_path)
    path.write_text(path.read_text() + " " * (pr.MAX_RECORD_BYTES + 1), encoding="utf-8")
    (tmp_path / "sessions" / "broken.json").write_text("{", encoding="utf-8")

    assert pr.claude_session_activity(tmp_path / "sessions") == {}


def test_an_idle_session_still_marked_working_ends_its_turn(tmp_path: Path) -> None:
    _session_file(tmp_path)
    sent: list = []

    result = _reap([_row()], _sweeper(tmp_path, tmp_path), tmp_path, sent)

    assert result.idled_sessions == 1
    assert result.ended_sessions == ()
    assert len(sent) == 1
    provider, payload = sent[0]
    assert provider == "claude"
    assert payload["hook_event_name"] == "Interrupt"
    assert payload["session_id"] == SESSION
    assert payload["jrbar_synthetic"] is True
    assert payload["reason"] == "jrbar_claude_session_idle"
    assert payload["occurred_at_epoch"] == pytest.approx((LAST_HOOK + timedelta(seconds=30)).timestamp())


@pytest.mark.parametrize("mode", (AgentMode.TOOL_RUNNING, AgentMode.LONG_TASK_PROGRESS))
def test_tool_running_rows_end_too(tmp_path: Path, mode: AgentMode) -> None:
    _session_file(tmp_path)
    sent: list = []

    _reap([_row(mode)], _sweeper(tmp_path, tmp_path), tmp_path, sent)

    assert [payload["hook_event_name"] for _p, payload in sent] == ["Interrupt"]


@pytest.mark.parametrize(
    "mode",
    (
        AgentMode.WAITING_FOR_INPUT,
        AgentMode.IDLE_READY,
        AgentMode.COMPLETED,
        AgentMode.BLOCKED_ERROR,
        AgentMode.ENDED_UNCONFIRMED,
    ),
)
def test_only_working_rows_are_touched(tmp_path: Path, mode: AgentMode) -> None:
    _session_file(tmp_path)
    sent: list = []

    result = _reap([_row(mode)], _sweeper(tmp_path, tmp_path), tmp_path, sent)

    assert sent == [] and result.idled_sessions == 0


def test_a_busy_session_is_left_working(tmp_path: Path) -> None:
    _session_file(tmp_path, status="busy")
    sent: list = []

    assert _reap([_row()], _sweeper(tmp_path, tmp_path), tmp_path, sent).idled_sessions == 0
    assert sent == []


def test_an_idle_stamp_older_than_the_last_hook_is_not_the_end_of_this_turn(tmp_path: Path) -> None:
    # The person already sent a new prompt: the hook is newer than the idle stamp.
    _session_file(tmp_path, statusUpdatedAt=int((LAST_HOOK - timedelta(seconds=30)).timestamp() * 1000))
    sent: list = []

    assert _reap([_row()], _sweeper(tmp_path, tmp_path), tmp_path, sent).idled_sessions == 0
    assert sent == []


def test_an_idle_stamp_within_the_grace_of_the_last_hook_waits(tmp_path: Path) -> None:
    _session_file(tmp_path, statusUpdatedAt=int((LAST_HOOK + timedelta(seconds=1)).timestamp() * 1000))
    sent: list = []

    assert _reap([_row()], _sweeper(tmp_path, tmp_path), tmp_path, sent).idled_sessions == 0


def test_a_session_whose_process_is_gone_takes_the_dead_path_not_the_idle_one(tmp_path: Path) -> None:
    _session_file(tmp_path)
    sent: list = []

    result = _reap([_row()], _sweeper(tmp_path, tmp_path, alive=False), tmp_path, sent)

    assert result.idled_sessions == 0
    assert [payload["hook_event_name"] for _p, payload in sent] != ["Interrupt"]


def test_other_providers_and_subagent_rows_are_not_interrupted(tmp_path: Path) -> None:
    _session_file(tmp_path)
    sent: list = []
    rows = [
        _row(provider="codex", agent_id=f"codex:session:{SESSION}"),
        _row(agent_id=f"claude:agent:{SESSION}:worker-1"),
    ]

    result = _reap(rows, _sweeper(tmp_path, tmp_path), tmp_path, sent)

    assert result.idled_sessions == 0
    assert [payload["hook_event_name"] for _p, payload in sent if _p == "claude"] == []


def test_a_failing_send_is_counted_not_raised(tmp_path: Path) -> None:
    _session_file(tmp_path)

    def boom(*_a, **_k):
        raise RuntimeError("disk wedged")

    result = reap_dead_agents(
        [_row()],
        sweeper=_sweeper(tmp_path, tmp_path),
        refresh_hint_handler=None,
        process_payload=boom,
        log_path_for=lambda provider: Path("/x"),
        claude_activity_loader=lambda: pr.claude_session_activity(tmp_path / "sessions"),
    )

    assert result.idled_sessions == 0
    assert result.failed_sends == 1


def test_a_broken_activity_loader_changes_nothing(tmp_path: Path) -> None:
    sent: list = []

    def broken():
        raise OSError("no folder")

    result = reap_dead_agents(
        [_row()],
        sweeper=_sweeper(tmp_path, tmp_path),
        refresh_hint_handler=None,
        process_payload=lambda *a, **k: sent.append(a),
        log_path_for=lambda provider: Path("/x"),
        claude_activity_loader=broken,
    )

    assert result.idled_sessions == 0 and sent == []


def test_the_synthetic_interrupt_reduces_to_an_idle_claude_session_through_the_real_hook_path(
    tmp_path: Path,
) -> None:
    from jrbar.collector import LiveAgentMonitor
    from jrbar.hook import HookProcessingOutcome, process_hook_payload

    log = tmp_path / "claude.jsonl"
    monitor = LiveAgentMonitor()
    now = datetime.now(timezone.utc)

    def feed(payload: dict, ago: float) -> None:
        stamp = (now - timedelta(seconds=ago)).strftime("%Y-%m-%dT%H:%M:%S.%fZ")
        outcome = process_hook_payload(
            "claude",
            log,
            json.dumps(payload),
            logged_at=stamp,
            refresh_hint_handler=lambda hint: monitor.reconcile_refresh_hint(hint, log_path=log),
        )
        assert outcome is HookProcessingOutcome.WRITTEN, payload["hook_event_name"]

    feed({"hook_event_name": "SessionStart", "session_id": SESSION, "cwd": "/work/demo", "source": "startup"}, 60)
    feed({"hook_event_name": "UserPromptSubmit", "session_id": SESSION, "cwd": "/work/demo", "prompt": "go"}, 50)
    feed({"hook_event_name": "PreToolUse", "session_id": SESSION, "cwd": "/work/demo", "tool_name": "Bash"}, 40)
    row = next(status for status in monitor.snapshot().statuses if status.session_id == SESSION)
    assert row.mode in (AgentMode.WORKING, AgentMode.TOOL_RUNNING)

    feed(
        {
            "hook_event_name": "Interrupt",
            "session_id": SESSION,
            "cwd": "/work/demo",
            "reason": "jrbar_claude_session_idle",
            "jrbar_synthetic": True,
            "occurred_at_epoch": (now - timedelta(seconds=10)).timestamp(),
        },
        10,
    )

    row = next(status for status in monitor.snapshot().statuses if status.session_id == SESSION)
    assert row.mode is AgentMode.IDLE_READY
