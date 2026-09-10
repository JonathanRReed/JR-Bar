"""Pi provider: the managed extension file, managed-file safety, canonical
events through the shim payload, and the session-log transcript fallback."""

from __future__ import annotations

import json
from datetime import datetime, timezone
from pathlib import Path

import pytest

from jrbar.install import install_pi_extension, uninstall_pi_extension
from jrbar.models import AgentMode
from jrbar.providers import (
    KNOWN_EVENTS,
    PI_EVENTS,
    PI_EXTENSION_MARKER,
    PI_NATIVE_EVENT_NAMES,
    detect_pi_config,
    managed_pi_extension_command,
    parse_log_line,
)
from jrbar.transcript_sessions import PI_TRANSCRIPT_PROVIDER, iter_pi_transcript_file, pi_session_header


def test_install_detect_round_trip(tmp_path: Path) -> None:
    config = tmp_path / ".pi" / "agent" / "extensions" / "jrbar.ts"
    log = tmp_path / "pi.jsonl"

    result = install_pi_extension(log_path=log, config_path=config)

    assert result.changed
    text = config.read_text()
    assert text.startswith(f"// {PI_EXTENSION_MARKER}")
    assert "{{" not in text and "}}" not in text
    for native in PI_NATIVE_EVENT_NAMES:
        assert f'pi.on("{native}"' in text
    assert 'import { spawn } from "node:child_process";' in text
    command = managed_pi_extension_command(text)
    assert command is not None and command[-3:-1] == ["pi", "--log"] and command[-1] == str(log)

    detected = detect_pi_config(tmp_path)
    assert detected.exists and detected.hooks_enabled
    assert detected.hook_events == tuple(sorted(PI_EVENTS))
    assert detected.log_paths == (log,)

    second = install_pi_extension(log_path=log, config_path=config)
    assert not second.changed


def test_install_refuses_an_unmanaged_extension(tmp_path: Path) -> None:
    config = tmp_path / ".pi" / "agent" / "extensions" / "jrbar.ts"
    config.parent.mkdir(parents=True)
    config.write_text("export default function () {}\n")

    with pytest.raises(ValueError, match="unmanaged"):
        install_pi_extension(log_path=tmp_path / "pi.jsonl", config_path=config)
    assert config.read_text() == "export default function () {}\n"
    assert not detect_pi_config(tmp_path).hooks_enabled

    removal = uninstall_pi_extension(log_path=tmp_path / "pi.jsonl", config_path=config)
    assert not removal.changed and config.exists()


def test_uninstall_removes_only_the_managed_file(tmp_path: Path) -> None:
    config = tmp_path / ".pi" / "agent" / "extensions" / "jrbar.ts"
    install_pi_extension(log_path=tmp_path / "pi.jsonl", config_path=config)

    result = uninstall_pi_extension(log_path=tmp_path / "pi.jsonl", config_path=config)

    assert result.changed and not config.exists()
    assert not detect_pi_config(tmp_path).exists


def test_the_extension_speaks_canonical_events_the_collector_understands() -> None:
    from jrbar.collector import mode_for_event

    assert set(PI_NATIVE_EVENT_NAMES.values()) <= set(KNOWN_EVENTS)
    assert set(PI_NATIVE_EVENT_NAMES.values()) == set(PI_EVENTS)
    line = json.dumps(
        {
            "hook_event_name": "PreToolUse",
            "session_id": "0b7a6c1e-1111-4222-8333-444455556666",
            "cwd": "/Users/j/Downloads/JR-Bar",
            "transcript_path": "/Users/j/.pi/agent/sessions/--Users-j-Downloads-JR-Bar--/x.jsonl",
            "tool_name": "bash",
            "source": "pi",
            "timestamp": "2026-09-10T12:00:00Z",
        }
    )
    record = parse_log_line("pi", line)
    assert record is not None
    assert record.provider == "pi" and record.event_name == "PreToolUse" and record.tool_name == "bash"
    assert record.cwd == "/Users/j/Downloads/JR-Bar"
    assert mode_for_event(record) is AgentMode.TOOL_RUNNING
    ended = parse_log_line("pi", json.dumps({"hook_event_name": "SessionEnd", "session_id": "s", "timestamp": "2026-09-10T12:00:01Z"}))
    assert ended is not None and ended.event_name == "SessionEnd"


def test_pi_session_log_is_read_as_a_transcript(tmp_path: Path) -> None:
    root = tmp_path / ".pi" / "agent" / "sessions" / "--Users-j-Downloads-JR-Bar--"
    root.mkdir(parents=True)
    path = root / "2026-09-10T12-00-00_0b7a6c1e-1111-4222-8333-444455556666.jsonl"
    rows = [
        {"type": "session", "version": 3, "id": "0b7a6c1e-1111-4222-8333-444455556666", "timestamp": "2026-09-10T12:00:00.000Z", "cwd": "/Users/j/Downloads/JR-Bar"},
        {"type": "message", "id": "a1", "parentId": None, "timestamp": "2026-09-10T12:00:01.000Z", "message": {"role": "user", "content": "reply ok", "timestamp": 1789041601000}},
        {"type": "message", "id": "a2", "parentId": "a1", "timestamp": "2026-09-10T12:00:02.000Z", "message": {"role": "assistant", "content": [{"type": "toolCall", "id": "call_1", "name": "bash", "arguments": {}}], "stopReason": "toolUse"}},
        {"type": "message", "id": "a3", "parentId": "a2", "timestamp": "2026-09-10T12:00:03.000Z", "message": {"role": "toolResult", "toolCallId": "call_1", "toolName": "bash", "content": [{"type": "text", "text": "ok"}], "isError": False}},
        {"type": "model_change", "id": "a4", "parentId": "a3", "timestamp": "2026-09-10T12:00:03.500Z", "provider": "google", "modelId": "x"},
        {"type": "message", "id": "a5", "parentId": "a4", "timestamp": "2026-09-10T12:00:04.000Z", "message": {"role": "assistant", "content": [{"type": "text", "text": "ok"}], "stopReason": "stop"}},
    ]
    path.write_text("\n".join(json.dumps(row) for row in rows) + "\n")

    assert pi_session_header(path)["cwd"] == "/Users/j/Downloads/JR-Bar"
    events = list(iter_pi_transcript_file(path))
    assert [event.event_name for event in events] == ["UserPromptSubmit", "PreToolUse", "PostToolUse", "Stop"]
    assert all(event.provider == "pi" and event.raw["source"] == PI_TRANSCRIPT_PROVIDER for event in events)
    assert all(event.session_id == "0b7a6c1e-1111-4222-8333-444455556666" and event.cwd == "/Users/j/Downloads/JR-Bar" for event in events)
    assert events[1].tool_name == "bash" and events[0].message == "reply ok"
    assert events[3].logged_at == datetime(2026, 9, 10, 12, 0, 4, tzinfo=timezone.utc)
    # Not a pi session: nothing.
    other = root / "notes.jsonl"
    other.write_text('{"hello": 1}\n')
    assert list(iter_pi_transcript_file(other)) == []


def test_transcript_switch_adds_the_pi_source(tmp_path: Path) -> None:
    from jrbar._collector_legacy import default_sources
    from jrbar._settings_legacy import AgentMonitorSettings

    off = default_sources(AgentMonitorSettings())
    assert all(source.provider != PI_TRANSCRIPT_PROVIDER for source in off)
    on = default_sources(AgentMonitorSettings().with_transcript_provider("pi", True))
    assert any(source.provider == PI_TRANSCRIPT_PROVIDER and source.path.name == "sessions" for source in on)
    assert AgentMonitorSettings().with_transcript_provider("pi", True).to_dict()["transcript_monitoring"]["pi"] is True
