from __future__ import annotations

import json
from pathlib import Path

from jrbar.hook_doctor import classify_command, registered_commands, render_hook_doctor


def test_classify_every_command_shape() -> None:
    assert classify_command([]) == "none"
    assert classify_command(["/opt/jrbar/hook/build/jrbar-hook", "--provider", "claude"]) == "shim"
    assert classify_command(["/venv/bin/python", "-m", "jrbar.hook_client", "--provider", "claude"]) == "python"
    assert classify_command(["/venv/bin/python", "/site/sidepulse/hook_entry.py", "--provider", "claude"]) == "legacy"
    assert classify_command(["/usr/bin/other-tool", "--provider", "claude"]) == "foreign"


def test_registered_commands_are_found_in_json_and_toml(tmp_path: Path) -> None:
    claude = tmp_path / "settings.json"
    claude.write_text(
        json.dumps(
            {
                "hooks": {
                    "Stop": [
                        {"matcher": "*", "hooks": [{"type": "command", "command": "/venv/bin/python -m jrbar.hook_client --provider claude --log /tmp/claude.jsonl"}]}
                    ],
                    "PreToolUse": [
                        {"matcher": "*", "hooks": [{"type": "command", "command": "/venv/bin/python -m jrbar.hook_client --provider claude --log /tmp/claude.jsonl"}]}
                    ],
                }
            }
        )
    )
    found = registered_commands(claude, "claude")
    assert found == [["/venv/bin/python", "-m", "jrbar.hook_client", "--provider", "claude", "--log", "/tmp/claude.jsonl"]]
    assert registered_commands(claude, "codex") == []

    codex = tmp_path / "config.toml"
    codex.write_text('[[hooks.Stop]]\ncommand = "/opt/jrbar-hook --provider codex --log /tmp/codex.jsonl"\n')
    assert classify_command(registered_commands(codex, "codex")[0]) == "shim"
    assert registered_commands(tmp_path / "missing.json", "claude") == []


def test_render_is_content_free_and_lists_providers() -> None:
    report = {
        "state_dir": "/state",
        "shim": None,
        "ingress_socket": {"path": "/state/hook-ingress.sock", "answers": False},
        "core_socket": {"path": "/state/core.sock", "answers": True},
        "pending": [{"file": "claude.pending.jsonl", "lines": 3}],
        "providers": [
            {"provider": "claude", "installed": True, "registered": ["python"], "registered_commands": ["python -m jrbar.hook_client --provider claude"], "would_install": "shim"},
            {"provider": "pi", "installed": False, "registered": ["none"], "registered_commands": [], "would_install": "shim"},
        ],
    }
    text = render_hook_doctor(report)
    assert "claude.pending.jsonl: 3 line(s)" in text
    assert "core socket: /state/core.sock (answering)" in text
    assert "claude       installed      runs=python   next install=shim" in text
    assert "pi           not installed  runs=none     next install=shim" in text
    assert "python -m jrbar.hook_client --provider claude" in text
