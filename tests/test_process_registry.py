from __future__ import annotations

import json
import os
import time
from dataclasses import replace
from pathlib import Path

from jrbar import process_registry as pr


def _table(*rows):
    return {pid: pr.ProcessEntry(pid, ppid, started, command) for pid, ppid, started, command in rows}


def test_list_processes_parses_lstart_and_comm_with_spaces():
    class Completed:
        returncode = 0
        stdout = (
            "  9170  9169 Wed Sep  9 18:34:49 2026 /Users/x/Library/Application Support/Claude/claude.app/Contents/MacOS/claude\n"
            "  1234     1 Wed Sep  9 18:00:00 2026 /opt/homebrew/bin/codex\n"
            "garbage line\n"
        )

    table = pr.list_processes(runner=lambda *a, **k: Completed())
    assert table[9170].basename == "claude"
    assert table[9170].ppid == 9169
    assert table[9170].started_at_epoch == time.mktime(time.strptime("Wed Sep  9 18:34:49 2026", "%a %b %d %H:%M:%S %Y"))
    assert table[1234].basename == "codex"
    assert len(table) == 2


def test_discover_agent_process_walks_past_shells_to_provider_binary():
    table = _table(
        (500, 400, 10.0, "/usr/bin/python3"),
        (400, 300, 10.0, "/bin/sh"),
        (300, 200, 5.0, "/opt/homebrew/bin/codex"),
        (200, 1, 1.0, "/Applications/Ghostty.app/Contents/MacOS/ghostty"),
    )
    entry = pr.discover_agent_process("codex", start_pid=500, table=table)
    assert entry is not None and entry.pid == 300


def test_discover_agent_process_falls_back_to_first_non_shell_ancestor():
    table = _table(
        (500, 400, 10.0, "/bin/zsh"),
        (400, 300, 10.0, "/usr/local/bin/mystery-agent"),
        (300, 1, 5.0, "/Applications/Ghostty.app/Contents/MacOS/ghostty"),
    )
    entry = pr.discover_agent_process("hermes", start_pid=500, table=table)
    assert entry is not None and entry.pid == 400


def test_record_roundtrip_and_liveness(tmp_path: Path):
    entry = pr.ProcessEntry(300, 1, 5.0, "/opt/homebrew/bin/codex")
    record = pr.record_agent_process("codex", "thread-1", entry, cwd="/work", state_dir=tmp_path, now=100.0)
    loaded = pr.load_record("codex", "thread-1", state_dir=tmp_path)
    assert loaded == record
    assert loaded.cwd == "/work" and loaded.ended_at_epoch is None

    alive_table = _table((300, 1, 5.0, "/opt/homebrew/bin/codex"))
    assert pr.process_is_live(record, alive_table) == (True, "alive")
    assert pr.process_is_live(record, {}) == (False, "process_exited")
    reused = _table((300, 1, 5000.0, "/bin/ls"))
    assert pr.process_is_live(record, reused) == (False, "pid_reused")


def test_note_hook_payload_registers_once_and_marks_session_end(tmp_path: Path):
    # The walk starts at the hook process' parent, so seed the table there.
    table = _table(
        (os.getppid(), 41, 10.0, "/bin/sh"),
        (41, 1, 3.0, "/opt/homebrew/bin/codex"),
    )
    calls = []

    def loader():
        calls.append(1)
        return table

    start = json.dumps({"hook_event_name": "SessionStart", "session_id": "s1", "cwd": "/w"})
    pr.note_hook_payload("codex", start, state_dir=tmp_path, table_loader=loader)
    record = pr.load_record("codex", "s1", state_dir=tmp_path)
    assert record is not None and record.pid == 41 and record.cwd == "/w"
    assert len(calls) == 1

    # Already registered: no process table read.
    pr.note_hook_payload("codex", json.dumps({"hook_event_name": "PreToolUse", "session_id": "s1"}), state_dir=tmp_path, table_loader=loader)
    assert len(calls) == 1

    pr.note_hook_payload("codex", json.dumps({"hook_event_name": "SessionEnd", "session_id": "s1"}), state_dir=tmp_path, table_loader=loader)
    ended = pr.load_record("codex", "s1", state_dir=tmp_path)
    assert ended.ended_at_epoch is not None and ended.end_reason == "hook"
    assert len(calls) == 1


def test_a_real_session_end_upgrades_a_record_the_sweep_already_closed(tmp_path: Path):
    """`end_reason` is what the app reads to tell a provider's own end from
    the liveness sweep's synthetic one. A one-shot CLI exits the instant it
    finishes, so the sweep can close the record first -- a real `SessionEnd`
    arriving afterwards still has to win, or the run never earns Done."""

    table = _table(
        (os.getppid(), 41, 10.0, "/bin/sh"),
        (41, 1, 3.0, "/opt/homebrew/bin/codex"),
    )
    start = json.dumps({"hook_event_name": "SessionStart", "session_id": "s9", "cwd": "/w"})
    pr.note_hook_payload("codex", start, state_dir=tmp_path, table_loader=lambda: table)
    record = pr.load_record("codex", "s9", state_dir=tmp_path)
    swept = replace(record, ended_at_epoch=1000.0, end_reason="process_exited")
    pr.write_record(swept, state_dir=tmp_path)

    pr.note_hook_payload(
        "codex",
        json.dumps({"hook_event_name": "SessionEnd", "session_id": "s9"}),
        state_dir=tmp_path,
        table_loader=lambda: table,
    )
    ended = pr.load_record("codex", "s9", state_dir=tmp_path)
    assert ended.end_reason == "hook"
    # The end time it already had is the truthful one; only the reason moves.
    assert ended.ended_at_epoch == 1000.0


def test_note_hook_payload_ignores_garbage(tmp_path: Path):
    pr.note_hook_payload("codex", "not json", state_dir=tmp_path, table_loader=lambda: {})
    pr.note_hook_payload("codex", json.dumps({"hook_event_name": "SessionStart"}), state_dir=tmp_path, table_loader=lambda: {})
    assert not list(pr.registry_dir(tmp_path).glob("**/*.json"))


def test_claude_session_index_reads_pid_files(tmp_path: Path):
    (tmp_path / "9170.json").write_text(json.dumps({"pid": 9170, "sessionId": "abc", "startedAt": 1788978889983, "entrypoint": "claude-desktop"}))
    (tmp_path / "bad.json").write_text("{")
    index = pr.claude_session_index(tmp_path)
    assert index["abc"].pid == 9170
    assert abs(index["abc"].started_at_epoch - 1788978889.983) < 0.01


def test_sweeper_ends_dead_and_keeps_alive(tmp_path: Path):
    alive = pr.ProcessEntry(300, 1, 5.0, "/opt/homebrew/bin/codex")
    dead = pr.ProcessEntry(301, 1, 6.0, "/opt/homebrew/bin/codex")
    pr.record_agent_process("codex", "alive", alive, state_dir=tmp_path)
    pr.record_agent_process("codex", "dead", dead, state_dir=tmp_path)
    table = _table((300, 1, 5.0, "/opt/homebrew/bin/codex"))
    clock = [1000.0]
    sweeper = pr.ProcessSweeper(state_dir=tmp_path, table_loader=lambda: table, claude_index_loader=dict, clock=lambda: clock[0])

    result = sweeper.sweep([("codex", "alive"), ("codex", "dead"), ("codex", "unknown")])
    assert [d.record.session_id for d in result] == ["dead"]
    assert result[0].reason == "process_exited"
    assert pr.load_record("codex", "dead", state_dir=tmp_path).ended_at_epoch == 1000.0

    # A second sweep does not report the same death twice.
    clock[0] += 10
    assert sweeper.sweep([("codex", "dead")]) == []


def test_sweeper_uses_claude_index_for_unregistered_sessions(tmp_path: Path):
    index = {"claude-sess": pr.ProcessEntry(777, 0, 5.0, "claude")}
    sweeper = pr.ProcessSweeper(state_dir=tmp_path, table_loader=lambda: _table((1, 0, 0.0, "/sbin/launchd")), claude_index_loader=lambda: index, clock=lambda: 50.0)
    result = sweeper.sweep([("claude", "claude-sess")])
    assert len(result) == 1 and result[0].record.pid == 777


def test_sweeper_declares_nothing_dead_without_a_process_table(tmp_path: Path):
    pr.record_agent_process("codex", "s", pr.ProcessEntry(9, 1, 1.0, "codex"), state_dir=tmp_path)
    sweeper = pr.ProcessSweeper(state_dir=tmp_path, table_loader=dict, claude_index_loader=dict)
    assert sweeper.sweep([("codex", "s")]) == []


def test_prune_registry_removes_old_records(tmp_path: Path):
    record = pr.record_agent_process("codex", "old", pr.ProcessEntry(9, 1, 1.0, "codex"), state_dir=tmp_path)
    path = pr.record_path("codex", "old", tmp_path)
    old = time.time() - 30 * 86400
    os.utime(path, (old, old))
    assert pr.prune_registry(state_dir=tmp_path) == 1
    assert pr.load_record(record.provider, record.session_id, state_dir=tmp_path) is None
