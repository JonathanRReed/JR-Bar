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


def test_registered_commands_read_folded_yaml_and_embedded_argv(tmp_path: Path) -> None:
    hermes = tmp_path / "config.yaml"
    hermes.write_text(
        "hooks:\n  pre_tool_call:\n  - command: /opt/jrbar/bin/jrbar-hook --provider \n      hermes --log /tmp/hermes.jsonl\n"
        "  post_tool_call:\n  - command: /opt/jrbar/bin/jrbar-hook --provider \n      hermes --log /tmp/hermes.jsonl\n"
    )
    assert registered_commands(hermes, "hermes") == [["/opt/jrbar/bin/jrbar-hook", "--provider", "hermes", "--log", "/tmp/hermes.jsonl"]]
    handler = tmp_path / "handler.ts"
    handler.write_text(
        '// jrbar-openclaw-handler-v2\nconst JRBAR_HOOK_ARGS = Object.freeze(["/opt/jrbar/bin/jrbar-hook","--provider","openclaw","--log","/tmp/openclaw.jsonl"]);\n'
    )
    found = registered_commands(handler, "openclaw")
    assert found == [["/opt/jrbar/bin/jrbar-hook", "--provider", "openclaw", "--log", "/tmp/openclaw.jsonl"]]
    assert classify_command(found[0]) == "shim"
    assert registered_commands(handler, "opencode") == []


def test_registered_commands_unwrap_the_antigravity_envelope_and_skip_fallbacks(tmp_path: Path) -> None:
    hooks = tmp_path / "hooks.json"
    hooks.write_text(json.dumps({"jrbar-status": {"Stop": [{"type": "command", "command": "payload=\"$(cat)\"; printf '{\"hook_event_name\":\"Stop\",\"antigravity\":%s}' \"${payload:-null}\" | /opt/jrbar/bin/jrbar-hook --provider antigravity --log /tmp/antigravity.jsonl >/dev/null 2>&1; printf '{}'", "timeout": 10}]}}))
    found = registered_commands(hooks, "antigravity")
    assert found == [["/opt/jrbar/bin/jrbar-hook", "--provider", "antigravity", "--log", "/tmp/antigravity.jsonl"]]
    assert classify_command(found[0]) == "shim"
    extension = tmp_path / "jrbar.ts"
    extension.write_text('const HOOK_COMMAND = ["/opt/jrbar/bin/jrbar-hook", "--provider", "pi", "--log", "/tmp/pi.jsonl"];\nconst FALLBACK_COMMAND = ["/venv/bin/python", "-m", "jrbar.hook_client", "--provider", "pi", "--log", "/tmp/pi.jsonl"];\n')
    assert [classify_command(parts) for parts in registered_commands(extension, "pi")] == ["shim"]


def test_registered_commands_unfold_hermes_long_path_scalars(tmp_path: Path) -> None:
    """Hermes folds a plain scalar wherever the line got long: after the
    bundled shim path and after ``--log``, not only after ``--provider``."""
    hermes = tmp_path / "config.yaml"
    shim = "/Users/someone/Applications/JR-Bar.app/Contents/Helpers/jrbar-hook"
    hermes.write_text(
        "hooks:\n"
        "  on_session_start:\n"
        f"  - command: \n      {shim} \n      --provider hermes --log \n      /Users/someone/.local/state/jrbar/hermes.jsonl\n"
        "    timeout: 10\n"
        f"  pre_tool_call:\n  - command: \n      {shim} \n      --provider hermes --log \n      /Users/someone/.local/state/jrbar/hermes.jsonl\n"
        "    timeout: 10\n"
    )
    found = registered_commands(hermes, "hermes")
    assert found == [[shim, "--provider", "hermes", "--log", "/Users/someone/.local/state/jrbar/hermes.jsonl"]]
    assert classify_command(found[0]) == "shim"


def test_hook_shim_path_finds_the_bundled_shim_when_frozen(tmp_path: Path, monkeypatch) -> None:
    from jrbar import install

    app = tmp_path / "JR-Bar.app" / "Contents"
    core = app / "Helpers" / "jrbar-core.app" / "Contents" / "MacOS" / "jrbar-core"
    core.parent.mkdir(parents=True)
    core.write_text("")
    shim = app / "Helpers" / "jrbar-hook"
    shim.write_text("#!/bin/sh\n")
    shim.chmod(0o755)
    monkeypatch.delenv("JRBAR_HOOK_EXEC", raising=False)
    monkeypatch.setenv("JRBAR_INSTALL_PREFIX", str(tmp_path / "nowhere"))
    monkeypatch.setattr(install.sys, "frozen", True, raising=False)
    monkeypatch.setattr(install.sys, "executable", str(core))
    assert install.hook_shim_path() == shim.resolve()
    assert install.hook_command_arguments("hermes", tmp_path / "hermes.jsonl")[0] == str(shim.resolve())
