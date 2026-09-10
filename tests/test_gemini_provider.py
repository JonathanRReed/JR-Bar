"""Gemini CLI provider: hooks in ~/.gemini/settings.json, the `{}` stdout
contract, ToolPermission as an ask, and the chat-log transcript fallback."""

from __future__ import annotations

import json
import subprocess
import sys
from pathlib import Path

import pytest

from jrbar.install import install_gemini_hooks, uninstall_gemini_hooks
from jrbar.models import AgentMode
from jrbar.providers import (
    GEMINI_EVENTS,
    GEMINI_HOOK_NAME,
    canonical_event_name,
    detect_gemini_config,
    parse_log_line,
)
from jrbar.transcript_sessions import GEMINI_TRANSCRIPT_PROVIDER, iter_gemini_transcript_file


def test_install_detect_round_trip_preserves_other_settings(tmp_path: Path) -> None:
    config = tmp_path / ".gemini" / "settings.json"
    config.parent.mkdir(parents=True)
    config.write_text(json.dumps({"security": {"auth": {"selectedType": "oauth-personal"}}, "hooks": {"BeforeTool": [{"matcher": "*", "hooks": [{"name": "mine", "type": "command", "command": "echo '{}'", "timeout": 1000}]}]}}, indent=2) + "\n")
    antigravity = tmp_path / ".gemini" / "config" / "hooks.json"
    antigravity.parent.mkdir()
    antigravity.write_text('{"jrbar-status": {"enabled": true}}\n')
    log = tmp_path / "gemini.jsonl"

    result = install_gemini_hooks(log_path=log, config_path=config)

    assert result.changed
    data = json.loads(config.read_text())
    assert data["security"] == {"security": {"auth": {"selectedType": "oauth-personal"}}}["security"]
    assert set(data["hooks"]) == set(GEMINI_EVENTS)
    entry = data["hooks"]["BeforeTool"]
    assert entry[0]["hooks"][0]["name"] == "mine"
    ours = entry[-1]
    assert ours["matcher"] == "*"
    assert ours["hooks"][0]["name"] == GEMINI_HOOK_NAME and ours["hooks"][0]["type"] == "command"
    assert ours["hooks"][0]["timeout"] == 5000
    assert "--provider gemini" in ours["hooks"][0]["command"] and str(log) in ours["hooks"][0]["command"]
    assert antigravity.read_text() == '{"jrbar-status": {"enabled": true}}\n'

    detected = detect_gemini_config(tmp_path)
    assert detected.exists and detected.hooks_enabled
    assert detected.hook_events == ("Notification", "PostToolUse", "PreToolUse", "SessionEnd", "SessionStart", "Stop", "UserPromptSubmit")
    assert detected.log_paths == (log,)

    assert not install_gemini_hooks(log_path=log, config_path=config).changed

    removal = uninstall_gemini_hooks(log_path=log, config_path=config)
    assert removal.changed
    data = json.loads(config.read_text())
    assert data["hooks"] == {"BeforeTool": [{"matcher": "*", "hooks": [{"name": "mine", "type": "command", "command": "echo '{}'", "timeout": 1000}]}]}
    assert not detect_gemini_config(tmp_path).hooks_enabled


def test_native_names_canonicalise_and_tool_permission_is_an_ask() -> None:
    from jrbar.collector import mode_for_event

    assert canonical_event_name("BeforeAgent") == "UserPromptSubmit"
    assert canonical_event_name("BeforeTool") == "PreToolUse"
    assert canonical_event_name("AfterTool") == "PostToolUse"
    assert canonical_event_name("AfterAgent") == "Stop"
    stamp = "2026-09-10T12:00:00Z"
    ask = parse_log_line("gemini", json.dumps({"hook_event_name": "Notification", "notification_type": "ToolPermission", "session_id": "s", "cwd": "/x", "timestamp": stamp, "transcript_path": "/x/chats/session-1.jsonl"}))
    assert ask is not None and ask.event_name == "PermissionRequest"
    assert mode_for_event(ask) is AgentMode.WAITING_FOR_INPUT
    info = parse_log_line("gemini", json.dumps({"hook_event_name": "Notification", "notification_type": "Other", "session_id": "s", "timestamp": stamp}))
    assert info is not None and info.event_name == "Notification"
    prompt = parse_log_line("gemini", json.dumps({"hook_event_name": "BeforeAgent", "prompt": "reply ok", "session_id": "s", "timestamp": stamp}))
    assert prompt is not None and prompt.event_name == "UserPromptSubmit" and mode_for_event(prompt) is AgentMode.WORKING
    done = parse_log_line("gemini", json.dumps({"hook_event_name": "AfterAgent", "prompt_response": "ok", "session_id": "s", "timestamp": stamp}))
    assert done is not None and done.event_name == "Stop"


def test_hook_client_prints_the_empty_verdict_for_gemini(tmp_path: Path) -> None:
    completed = subprocess.run(
        [sys.executable, "-m", "jrbar.hook_client", "--provider", "gemini", "--log", str(tmp_path / "gemini.jsonl")],
        input="{}", capture_output=True, text=True, timeout=30,
        env={"PATH": "/usr/bin:/bin", "JRBAR_STATE_DIR": str(tmp_path / "state"), "XDG_STATE_HOME": str(tmp_path / "xdg"), "HOME": str(tmp_path)},
        check=False,
    )
    assert completed.stdout.strip() == "{}"
    shim = Path(__file__).resolve().parents[1] / "hook" / "build" / "jrbar-hook"
    if shim.exists():
        for arguments in (["--provider", "gemini"], ["--provider", "pi", "--emit-empty-json"]):
            out = subprocess.run([str(shim), *arguments], input="{}", capture_output=True, text=True, timeout=10, env={"JRBAR_STATE_DIR": str(tmp_path / "state")}, check=False)
            assert out.stdout.strip() == "{}"
        quiet = subprocess.run([str(shim), "--provider", "pi"], input="{}", capture_output=True, text=True, timeout=10, env={"JRBAR_STATE_DIR": str(tmp_path / "state")}, check=False)
        assert quiet.stdout == ""


def test_gemini_chat_log_is_read_as_a_transcript(tmp_path: Path) -> None:
    root = tmp_path / ".gemini" / "tmp" / "downloads" / "chats"
    root.mkdir(parents=True)
    path = root / "session-2026-09-10T12-00-e355ddc8.jsonl"
    rows = [
        {"sessionId": "e355ddc8-ee8e-402b-9833-c19dfeab43bc", "projectHash": "abc", "startTime": "2026-09-10T12:00:00.000Z", "lastUpdated": "2026-09-10T12:00:00.000Z", "kind": "main"},
        {"$set": {"messages": [{"id": "m1", "timestamp": "2026-09-10T12:00:00.500Z", "type": "user", "content": [{"text": "<session_context>\nsetup\n</session_context>"}]}], "lastUpdated": "2026-09-10T12:00:00.500Z"}},
        {"id": "m2", "timestamp": "2026-09-10T12:00:01.000Z", "type": "info", "content": "Skill command renamed"},
        {"$set": {"lastUpdated": "2026-09-10T12:00:01.000Z"}},
        {"id": "m3", "timestamp": "2026-09-10T12:00:02.000Z", "type": "user", "content": [{"text": "reply ok"}]},
        {"id": "m4", "timestamp": "2026-09-10T12:00:03.000Z", "type": "gemini", "content": "", "toolCalls": [{"id": "t1", "name": "run_shell_command", "args": {}}]},
        {"id": "m5", "timestamp": "2026-09-10T12:00:04.000Z", "type": "gemini", "content": "ok"},
    ]
    path.write_text("\n".join(json.dumps(row) for row in rows) + "\n")

    events = list(iter_gemini_transcript_file(path))
    assert [event.event_name for event in events] == ["UserPromptSubmit", "PreToolUse", "Stop"]
    assert all(event.provider == "gemini" and event.session_id == "e355ddc8-ee8e-402b-9833-c19dfeab43bc" for event in events)
    assert all(event.raw["source"] == GEMINI_TRANSCRIPT_PROVIDER for event in events)
    assert events[0].message == "reply ok" and events[1].tool_name == "run_shell_command" and events[2].message == "ok"
    assert list(iter_gemini_transcript_file(tmp_path / "missing.jsonl")) == []


@pytest.mark.parametrize("provider", ["pi", "gemini"])
def test_ingress_accepts_the_new_providers(provider: str) -> None:
    from jrbar.hook_ingress_protocol import _HOOK_PROVIDERS

    assert provider in _HOOK_PROVIDERS
