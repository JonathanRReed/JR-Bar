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
    # Both transcripts were read and neither run edited a file: the
    # inventory is known and empty, so the gap is gone.
    assert a["artifacts"] == {"files": [], "total": 0, "truncated": False}
    assert "artifacts_not_tracked" not in doc["gaps"]
    assert "model_not_tracked" in doc["gaps"]


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
    assert doc["a"]["artifacts"] is None
    assert "artifacts_not_tracked" in doc["gaps"]


def test_files_touched_reads_claude_edit_tools(tmp_path, monkeypatch):
    monkeypatch.setattr("pathlib.Path.home", lambda: tmp_path)
    rows = _claude_rows()
    rows.append({"type": "assistant", "uuid": "a3", "timestamp": "2026-09-13T10:01:00Z",
                 "message": {"role": "assistant", "content": [
                     {"type": "tool_use", "id": "t2", "name": "Edit",
                      "input": {"file_path": "/tmp/work/src/app.py", "old_string": "a", "new_string": "b"}},
                     {"type": "tool_use", "id": "t3", "name": "MultiEdit",
                      "input": {"file_path": "/tmp/work/src/app.py", "edits": [{}, {}, {}]}},
                     {"type": "tool_use", "id": "t4", "name": "Write",
                      "input": {"file_path": str(tmp_path / "notes.md"), "content": "x"}},
                     {"type": "tool_use", "id": "t5", "name": "Read",
                      "input": {"file_path": "/tmp/work/README.md"}},
                     {"type": "tool_use", "id": "t6", "name": "NotebookEdit",
                      "input": {"notebook_path": "/elsewhere/n.ipynb"}},
                 ]}})
    # A session id of its own: transcript lookups are cached per id.
    sid = "cccccccc-1111-2222-3333-444444444444"
    _write(tmp_path / ".claude" / "projects" / "-tmp-work" / f"{sid}.jsonl", rows)
    doc = compare_runs(
        row_a={"id": "a", "provider": "claude", "cwd": "/tmp/work", "label": "A"},
        row_b={"id": "b", "provider": "claude", "cwd": "/tmp/work", "label": "B"},
        status_a=_status("a", session_id=sid),
        status_b=_status("b", session_id="dddddddd-1111-2222-3333-444444444444"),
        ledger_entries=[], id_a="a", id_b="b",
    )
    assert doc["a"]["artifacts"] == {
        "files": [
            {"path": "src/app.py", "edits": 4},
            {"path": "/elsewhere/n.ipynb", "edits": 1},
            {"path": "~/notes.md", "edits": 1},
        ],
        "total": 3,
        "truncated": False,
    }
    # Side b's transcript is missing: its inventory is unknown, not empty.
    assert doc["b"]["artifacts"] is None
    assert "artifacts_not_tracked" in doc["gaps"]


def test_files_touched_reads_codex_patch_headers(tmp_path):
    from jrbar.run_compare import files_touched

    patch = "*** Begin Patch\n*** Update File: src/a.rs\n@@\n-x\n+y\n*** Add File: docs/new.md\n+hi\n*** End Patch"
    rows = [
        {"type": "response_item", "payload": {"type": "function_call", "name": "apply_patch",
                                              "arguments": json.dumps({"input": patch})}},
        {"type": "response_item", "payload": {"type": "custom_tool_call", "name": "apply_patch",
                                              "input": "*** Begin Patch\n*** Update File: /w/src/a.rs\n*** End Patch"}},
        {"type": "response_item", "payload": {"type": "function_call", "name": "shell",
                                              "arguments": json.dumps({"command": ["bash", "-lc", "apply_patch <<'EOF'\n*** Delete File: old.txt\n*** End Patch\nEOF"]})}},
        {"type": "response_item", "payload": {"type": "message", "role": "assistant",
                                              "content": [{"type": "output_text", "text": "*** Update File: not-a-call.txt"}]}},
    ]
    path = tmp_path / "rollout.jsonl"
    _write(path, rows)
    result = files_touched("codex", path, "/w")
    assert result == {
        "files": [
            {"path": "src/a.rs", "edits": 2},
            {"path": "docs/new.md", "edits": 1},
            {"path": "old.txt", "edits": 1},
        ],
        "total": 3,
        "truncated": False,
    }
    assert files_touched("grok", path, "/w") is None


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
