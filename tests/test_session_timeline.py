"""session_timeline: transcript discovery, item projection, paging."""

from __future__ import annotations

import json
from types import SimpleNamespace

from jrbar.session_timeline import (
    claude_row_items,
    find_transcript,
    paginate,
    session_timeline,
    timeline_items,
)


def _write(path, rows):
    path.parent.mkdir(parents=True, exist_ok=True)
    with path.open("w") as handle:
        for row in rows:
            handle.write(json.dumps(row) + "\n")


SID = "11111111-2222-3333-4444-555555555555"


def _claude_rows():
    return [
        {
            "type": "user",
            "uuid": "u1",
            "timestamp": "2026-09-13T10:00:00Z",
            "message": {"role": "user", "content": "fix the flake"},
        },
        {
            "type": "assistant",
            "uuid": "a1",
            "parentUuid": "u1",
            "timestamp": "2026-09-13T10:00:05Z",
            "message": {
                "role": "assistant",
                "model": "claude-x",
                "content": [
                    {"type": "text", "text": "looking"},
                    {"type": "tool_use", "id": "tu1", "name": "Bash",
                     "input": {"command": "pytest -x"}},
                ],
            },
        },
        {
            "type": "user",
            "uuid": "u2",
            "parentUuid": "a1",
            "timestamp": "2026-09-13T10:00:09Z",
            "message": {
                "role": "user",
                "content": [
                    {"type": "tool_result", "tool_use_id": "tu1",
                     "content": "1 failed", "is_error": True},
                ],
            },
        },
        {
            "type": "assistant",
            "uuid": "a2",
            "parentUuid": "u2",
            "timestamp": "2026-09-13T10:00:15Z",
            "message": {
                "role": "assistant",
                "content": [{"type": "text", "text": "found it"}],
                "stop_reason": "end_turn",
            },
        },
    ]


def test_find_transcript_prefers_cwd_project_dir(tmp_path):
    root = tmp_path / ".claude" / "projects"
    slug_dir = root / "-tmp-work"
    _write(slug_dir / f"{SID}.jsonl", _claude_rows())
    _write(root / "-other" / f"{SID}.jsonl", _claude_rows())
    found = find_transcript("claude", SID, cwd="/tmp/work", home=tmp_path)
    assert found == slug_dir / f"{SID}.jsonl"


def test_find_transcript_uuid_guard(tmp_path):
    assert find_transcript("claude", "not-a-uuid", home=tmp_path) is None
    assert find_transcript("claude", "../escape", home=tmp_path) is None


def test_claude_items_pair_tool_use_and_result(tmp_path):
    path = tmp_path / f"{SID}.jsonl"
    _write(path, _claude_rows())
    items, gaps = timeline_items("claude", path)
    assert gaps == []
    kinds = [item["kind"] for item in items]
    assert kinds == ["message", "tool_use", "message", "tool_result",
                     "message", "turn_end"]
    use = next(i for i in items if i["kind"] == "tool_use")
    result = next(i for i in items if i["kind"] == "tool_result")
    assert use["tool_use_id"] == "tu1" and use["name"] == "Bash"
    assert result["tool_use_id"] == "tu1" and result["is_error"] is True
    assert result["untrusted"] is True  # T44: tool output is not a command


def test_codex_items(tmp_path):
    path = tmp_path / "rollouts" / f"rollout-2026-09-13T10-00-00-{SID}.jsonl"
    _write(path, [
        {"type": "turn_context", "timestamp": "2026-09-13T10:00:00Z",
         "payload": {"type": "turn_context", "turn_id": "t1", "cwd": "/w"}},
        {"type": "response_item", "timestamp": "2026-09-13T10:00:01Z",
         "payload": {"type": "message", "role": "user",
                     "content": [{"type": "input_text", "text": "hi"}]}},
        {"type": "response_item", "timestamp": "2026-09-13T10:00:02Z",
         "payload": {"type": "function_call", "name": "shell",
                     "call_id": "c1", "arguments": "{}"}},
        {"type": "response_item", "timestamp": "2026-09-13T10:00:03Z",
         "payload": {"type": "function_call_output", "call_id": "c1",
                     "output": "ok"}},
    ])
    items, _ = timeline_items("codex", path)
    assert [i["kind"] for i in items] == ["message", "tool_use", "tool_result"]
    assert items[1]["tool_use_id"] == "c1" == items[2]["tool_use_id"]


def test_paginate_walks_backwards():
    items = [{"seq": i, "at": i} for i in range(10)]
    page1 = paginate(items, limit=4, before=None)
    assert [i["seq"] for i in page1["events"]] == [6, 7, 8, 9]
    assert page1["has_more"] is True and page1["next_before"] == 6
    page2 = paginate(items, limit=4, before=page1["next_before"])
    assert [i["seq"] for i in page2["events"]] == [2, 3, 4, 5]
    page3 = paginate(items, limit=4, before=page2["next_before"])
    assert [i["seq"] for i in page3["events"]] == [0, 1]
    assert page3["has_more"] is False


def test_session_timeline_missing_transcript(tmp_path):
    doc = session_timeline("claude", SID, home=tmp_path)
    assert doc["events"] == [] and "transcript_not_found" in doc["gaps"]


def test_session_timeline_unsupported_provider(tmp_path):
    doc = session_timeline("grok", SID, home=tmp_path)
    assert "unsupported_provider" in doc["gaps"]


def test_secret_run_redacted_in_text(tmp_path):
    path = tmp_path / f"{SID}.jsonl"
    rows = _claude_rows()
    rows[0]["message"]["content"] = "token " + "A" * 40
    _write(path, rows)
    items, _ = timeline_items("claude", path)
    assert items[0]["text"] == "token [redacted]"


def test_occurrence_time_not_ingestion(tmp_path):
    path = tmp_path / f"{SID}.jsonl"
    _write(path, _claude_rows())
    items, _ = timeline_items("claude", path)
    assert all(i["recorded_at"] is None for i in items)
    assert all(i["at"] is not None for i in items)


def test_command_resolves_roster_id(tmp_path, monkeypatch):
    from jrbar.core_runtime import _cmd_session_timeline

    _write(
        tmp_path / ".claude" / "projects" / "-tmp-work" / f"{SID}.jsonl",
        _claude_rows(),
    )
    monkeypatch.setattr("pathlib.Path.home", lambda: tmp_path)
    status = SimpleNamespace(
        agent_id="claude:1", provider="claude",
        session_id=SID, cwd="/tmp/work",
    )
    controller = SimpleNamespace(
        last_snapshot=SimpleNamespace(statuses=[status], stale_statuses=[]),
    )
    reply = _cmd_session_timeline(controller, {"id": "claude:1"})
    assert reply["total"] == 6
    assert reply["session"] == "claude:1"
    assert reply["source"]["provider"] == "claude"


def test_command_direct_session_lookup(tmp_path, monkeypatch):
    from jrbar.core_runtime import _cmd_session_timeline

    _write(
        tmp_path / ".codex" / "sessions" / "2026" / "09" / f"r-{SID}.jsonl",
        [{"type": "response_item", "timestamp": "2026-09-13T10:00:01Z",
          "payload": {"type": "message", "role": "user",
                      "content": [{"type": "input_text", "text": "hi"}]}}],
    )
    monkeypatch.setattr("pathlib.Path.home", lambda: tmp_path)
    controller = SimpleNamespace(last_snapshot=None)
    reply = _cmd_session_timeline(
        controller, {"session": SID, "provider": "codex"}
    )
    assert reply["total"] == 1
    assert reply["events"][0]["role"] == "user"


def test_command_unknown_id_raises(tmp_path):
    import pytest

    from jrbar.core_runtime import CommandError, _cmd_session_timeline

    controller = SimpleNamespace(
        last_snapshot=SimpleNamespace(statuses=[], stale_statuses=[]),
    )
    with pytest.raises(CommandError) as error:
        _cmd_session_timeline(controller, {"id": "ghost"})
    assert error.value.code == "not_found"


def test_item_cap_names_the_gap(tmp_path, monkeypatch):
    monkeypatch.setattr("jrbar.session_timeline.TIMELINE_MAX_ITEMS", 3)
    path = tmp_path / f"{SID}.jsonl"
    _write(path, _claude_rows())
    items, gaps = timeline_items("claude", path)
    assert len(items) == 3
    assert any(g.startswith("timeline_item_cap") for g in gaps)


def test_claude_row_items_skips_meta_and_notifications():
    meta = {"type": "user", "isMeta": True, "message": {"content": "x"}}
    items, _ = claude_row_items(meta, seq=0, fallback_at=None)
    assert items == []
