"""The installer writes the decide lane only where it can work: Claude's and
Codex's PermissionRequest hook, run by a command that understands
``--decide``, with a timeout longer than the shim's own wait."""

from __future__ import annotations

import json
import tomllib
from pathlib import Path

import pytest

from jrbar.codex_hook_trust import trusted_hashes_for_config
from jrbar.hook_doctor import hook_doctor_report, render_hook_doctor
from jrbar.install import (
    CODEX_DECIDE_STATUS_MESSAGE,
    DECIDE_HOOK_TIMEOUT_SECONDS,
    decide_hook_command,
    decides,
    install_claude_hooks,
    install_codex_hooks,
    is_jrbar_json_hook_command,
    uninstall_claude_hooks,
    uninstall_codex_hooks,
)
from jrbar.providers import CLAUDE_EVENTS, CODEX_EVENTS


@pytest.fixture
def shim(tmp_path: Path, monkeypatch) -> Path:
    path = tmp_path / "bin" / "jrbar-hook"
    path.parent.mkdir()
    path.write_text("#!/bin/sh\nexit 0\n")
    path.chmod(0o755)
    monkeypatch.setenv("JRBAR_HOOK_EXEC", str(path))
    return path


def test_claude_permission_request_runs_the_decide_lane__and_2_more(tmp_path: Path, shim: Path) -> None:
    config = tmp_path / "settings.json"
    log = tmp_path / "state" / "claude.jsonl"
    config.write_text(json.dumps({"hooks": {"PermissionRequest": [
        {"matcher": "Bash", "hooks": [{"type": "command", "command": "someone-elses-hook"}]}
    ]}}))

    # --- scenario: only PermissionRequest decides, with the long timeout
    result = install_claude_hooks(log_path=log, config_path=config)
    assert result.changed
    hooks = json.loads(config.read_text())["hooks"]
    ours = [entry for entry in hooks["PermissionRequest"] if entry["matcher"] == "*"]
    assert ours == [{"matcher": "*", "hooks": [{
        "type": "command",
        "command": f"{shim} --provider claude --log {log} --decide",
        "timeout": DECIDE_HOOK_TIMEOUT_SECONDS,
    }]}]
    # Another tool's PermissionRequest hook is left exactly where it was.
    assert hooks["PermissionRequest"][0]["hooks"][0]["command"] == "someone-elses-hook"
    for event in CLAUDE_EVENTS:
        if event == "PermissionRequest":
            continue
        handler = hooks[event][-1]["hooks"][0]
        assert handler == {"type": "command", "command": f"{shim} --provider claude --log {log}"}

    # --- scenario: the decide entry is still ours, so a reinstall does not stack it
    assert is_jrbar_json_hook_command(ours[0]["hooks"][0]["command"], log, "claude")
    assert not install_claude_hooks(log_path=log, config_path=config).changed

    # --- scenario: uninstall removes it and keeps the other tool's
    uninstall_claude_hooks(log_path=log, config_path=config)
    hooks = json.loads(config.read_text())["hooks"]
    assert hooks == {"PermissionRequest": [
        {"matcher": "Bash", "hooks": [{"type": "command", "command": "someone-elses-hook"}]}
    ]}


def test_codex_permission_request_runs_the_decide_lane__and_1_more(tmp_path: Path, shim: Path) -> None:
    config = tmp_path / "config.toml"
    log = tmp_path / "state" / "codex.jsonl"

    # --- scenario: the entry decides, says where the answer is expected, and is trusted
    install_codex_hooks(log_path=log, config_path=config)
    text = config.read_text()
    document = tomllib.loads(text)
    handler = document["hooks"]["PermissionRequest"][0]["hooks"][0]
    assert handler == {
        "type": "command",
        "command": f"{shim} --provider codex --log {log} --decide",
        "timeout": DECIDE_HOOK_TIMEOUT_SECONDS,
        "statusMessage": CODEX_DECIDE_STATUS_MESSAGE,
    }
    for event in CODEX_EVENTS:
        if event != "PermissionRequest":
            assert "--decide" not in document["hooks"][event][0]["hooks"][0]["command"]
    hashes = trusted_hashes_for_config(text, config, is_ours=lambda command: "--provider codex" in command)
    assert any(key.endswith(":permission_request:0:0") for key in hashes)
    assert not install_codex_hooks(log_path=log, config_path=config).changed

    # --- scenario: uninstall takes the decide entry with the rest
    uninstall_codex_hooks(log_path=log, config_path=config)
    assert "--decide" not in config.read_text()
    assert "PermissionRequest" not in tomllib.loads(config.read_text()).get("hooks", {})


def test_only_commands_that_understand_decide_get_it__and_1_more(tmp_path: Path, monkeypatch) -> None:
    # --- scenario: the shim and the module client decide; frozen and legacy shapes do not
    assert decides(["/x/jrbar-hook", "--provider", "claude"])
    assert decides(["/usr/bin/python3", "-m", "jrbar.hook_client", "--provider", "claude"])
    assert not decides(["/x/jrbar-core", "agent-monitor", "hook-client", "--provider", "claude"])
    assert not decides(["python3", "/x/hook_entry.py", "--provider", "claude"])
    assert not decides([])

    # --- scenario: with no shim the module client decides
    monkeypatch.setenv("JRBAR_HOOK_EXEC", "")
    command = decide_hook_command("claude", tmp_path / "claude.jsonl", "/usr/bin/python3")
    assert command.endswith("-m jrbar.hook_client --provider claude --log " + str(tmp_path / "claude.jsonl") + " --decide")


def test_doctor_says_whether_the_decide_lane_is_installed(tmp_path: Path, shim: Path) -> None:
    home = tmp_path / "home"
    (home / ".claude").mkdir(parents=True)
    log = tmp_path / "state" / "claude.jsonl"
    install_claude_hooks(log_path=log, config_path=home / ".claude" / "settings.json")
    report = hook_doctor_report(home)
    providers = {entry["provider"]: entry for entry in report["providers"]}
    assert providers["claude"]["decide"] == "installed"
    assert providers["codex"]["decide"] == "not_installed"
    assert "decide" not in providers["gemini"]
    assert "decide=installed" in render_hook_doctor(report)
