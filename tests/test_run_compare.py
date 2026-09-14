"""compare_sessions: side-by-side runs on retained facts only (S7.4)."""

from __future__ import annotations

import json
from types import SimpleNamespace

import pytest

from jrbar.core_runtime import CommandError, _cmd_compare_sessions
from jrbar.run_compare import compare_runs

SID_A = "aaaaaaaa-1111-2222-3333-444444444444"
SID_B = "bbbbbbbb-1111-2222-3333-444444444444"


def _write(path, rows):
    path.parent.mkdir(parents=True, exist_ok=True)
    with path.open("w") as handle:
        for row in rows:
            handle.write(json.dumps(row) + "\n")


def _claude_rows(tag="run"):
    return [
        {"type": "user", "uuid": "u1", "timestamp": "2026-09-13T10:00:00Z",
         "message": {"role": "user", "content": f"do {tag}"}},
        {"type": "assistant", "uuid": "a1", "parentUuid": "u1",
         "timestamp": "2026-09-13T10:00:05Z",
         "message": {"role": "assistant", "content": [
             {"type": "tool_use", "id": "tu1", "name": "Bash",
              "input": {"command": "pytest"}}]}},
        {"type": "user", "uuid": "u2", "parentUuid": "a1",
         "timestamp": "2026-09-13T10:00:09Z",
         "message": {"role": "user", "content": [
             {"type": "tool_result", "tool_use_id": "tu1",
              "content": "1 failed", "is_error": True}]}},
        {"type": "assistant", "uuid": "a2", "parentUuid": "u2",
         "timestamp": "2026-09-13T10:00:15Z",
         "message": {"role": "assistant",
                     "content": [{"type": "text", "text": "fixed"}],
                     "stop_reason": "end_turn"}},
    ]


def _status(agent_id, provider="claude", session_id=None, cwd="/tmp/work"):
    return SimpleNamespace(
        agent_id=agent_id, provider=provider,
        session_id=session_id, cwd=cwd, stale=False,
    )


def _ledger_entry(subject_id, kind):
    return SimpleNamespace(
        subject_id=subject_id,
        kind=SimpleNamespace(value=kind),
        occurred_at_epoch=1_800_000_000.0,
    )


def test_compare_aggregates_transcripts(tmp_path, monkeypatch):
    monkeypatch.setattr("pathlib.Path.home", lambda: tmp_path)
    for sid in (SID_A, SID_B):
        _write(
            tmp_path / ".claude" / "projects" / "-tmp-work" / f"{sid}.jsonl",
            _claude_rows(sid[:4]),
        )
    doc = compare_runs(
        row_a={"id": "a", "provider": "claude", "cwd": "/tmp/work",
               "label": "A", "axes": {"outcome": "succeeded"}},
        row_b={"id": "b", "provider": "claude", "cwd": "/tmp/work",
               "label": "B", "axes": {"outcome": "failed"}},
        status_a=_status("a", session_id=SID_A),
        status_b=_status("b", session_id=SID_B),
        ledger_entries=[_ledger_entry("a", "asked"),
                        _ledger_entry("a", "completed")],
        id_a="a", id_b="b",
    )
    assert doc["t"] == "compare_runs"
    a, b = doc["a"], doc["b"]
    assert a["activity"]["counts"]["tool_uses"] == 1
    assert a["activity"]["counts"]["tool_failures"] == 1
    assert a["activity"]["counts"]["retried_tools"] == 1
    assert a["activity"]["tools"] == {"Bash": 1}
    assert a["activity"]["span"]["duration_s"] == 15.0
    assert a["interruptions"] == {"asked": 1, "blocked": 0, "completed": 1}
    assert b["interruptions"] == {"asked": 0, "blocked": 0, "completed": 0}
    assert doc["shared"]["provider"] is True
    assert doc["shared"]["workspace"] is True
    assert doc["shared"]["model"] is None  # not tracked — never equal
    assert "not_a_controlled_benchmark" in doc["warnings"]
    assert "artifacts_not_tracked" in doc["gaps"]


def test_compare_missing_transcript_names_the_gap(tmp_path, monkeypatch):
    monkeypatch.setattr("pathlib.Path.home", lambda: tmp_path)
    doc = compare_runs(
        row_a={"id": "a", "provider": "claude", "cwd": "/x", "label": "A"},
        row_b={"id": "b", "provider": "grok", "cwd": "/y", "label": "B"},
        status_a=_status("a", session_id=SID_A, cwd="/x"),
        status_b=_status("b", provider="grok", session_id=None, cwd="/y"),
        ledger_entries=[], id_a="a", id_b="b",
    )
    assert doc["a"]["activity"] is None
    assert "transcript_not_found" in doc["a"]["gaps"]
    assert "unsupported_provider" in doc["b"]["gaps"]
    assert "different_providers" in doc["warnings"]
    assert "different_workspaces" in doc["warnings"]


def test_command_not_found_for_unknown_id():
    controller = SimpleNamespace(
        last_snapshot=SimpleNamespace(statuses=[], stale_statuses=[]),
    )
    with pytest.raises(CommandError) as error:
        _cmd_compare_sessions(controller, {"a": "x", "b": "y"})
    assert error.value.code == "not_found"


def test_command_rejects_same_session():
    controller = SimpleNamespace(last_snapshot=None)
    with pytest.raises(CommandError) as error:
        _cmd_compare_sessions(controller, {"a": "x", "b": "x"})
    assert error.value.code == "invalid_value"


def test_command_end_to_end(tmp_path, monkeypatch):
    monkeypatch.setattr("pathlib.Path.home", lambda: tmp_path)
    _write(
        tmp_path / ".claude" / "projects" / "-tmp-work" / f"{SID_A}.jsonl",
        _claude_rows(),
    )
    status = _status("claude:1", session_id=SID_A)
    other = _status("codex:2", provider="codex", session_id=SID_B)
    controller = SimpleNamespace(
        last_snapshot=SimpleNamespace(
            statuses=[status, other], stale_statuses=[]),
        _core_state_generation=1,
        current_operator_state=None,
        _core_extras={},
        answer_handler_registry=None,
        ensure_activity_ledger=lambda: SimpleNamespace(
            entries=[], last_seen_epoch=0.0),
        _core_ask_statuses=lambda: (),
        _core_snoozed_untils=lambda statuses: {},
        _answer_contracts_by_source=None,
        _core_acknowledged_keys=lambda: frozenset(),
        _core_extras_for=lambda status: None,
    )
    doc = _cmd_compare_sessions(controller, {"a": "claude:1", "b": "codex:2"})
    assert doc["a"]["activity"]["counts"]["tool_uses"] == 1
    assert "unsupported_provider" not in doc["b"]["gaps"] or \
        doc["b"]["activity"] is None
