"""Installs written before the JR-Bar rename are replaced, never duplicated."""

from __future__ import annotations

import json
import sys
from pathlib import Path

from jrbar import install, providers

OLD_STATE = Path(".local/state/sidepulse/agent-monitor")


def _old_command(provider: str, log: Path) -> str:
    return f"{sys.executable} -m sidepulse.hook_client --provider {provider} --log {log}"


def _nested(command: str) -> dict[str, object]:
    return {"matcher": "*", "hooks": [{"type": "command", "command": command}]}


def test_detect_log_path_never_adopts_a_pre_rename_log(tmp_path: Path) -> None:
    old_log = tmp_path / OLD_STATE / "claude.jsonl"
    settings = tmp_path / ".claude" / "settings.json"
    settings.parent.mkdir(parents=True)
    settings.write_text(json.dumps({"hooks": {"SessionStart": [_nested(_old_command("claude", old_log))]}}))

    assert providers.detect_claude_config(tmp_path).log_paths == (old_log,)
    assert providers.detect_log_path("claude", tmp_path) == providers.default_log_path("claude", tmp_path)
    assert providers.is_legacy_log_path(old_log)
    assert not providers.is_legacy_log_path(providers.default_log_path("claude", tmp_path))


def test_claude_install_replaces_every_pre_rename_entry(tmp_path: Path) -> None:
    config = tmp_path / "settings.json"
    old_log = tmp_path / OLD_STATE / "claude.jsonl"
    new_log = tmp_path / "state" / "claude.jsonl"
    config.write_text(
        json.dumps(
            {
                "hooks": {
                    "SessionStart": [
                        _nested(_old_command("claude", old_log)),
                        {"matcher": "*", "hooks": [{"type": "command", "command": "echo keep"}]},
                    ],
                    "Stop": [_nested(f"{sys.executable} -m agent_monitor.hook_entry --provider claude --log {old_log}")],
                }
            }
        )
    )

    result = install.install_claude_hooks(log_path=new_log, config_path=config, python_executable=sys.executable)

    assert result.changed
    text = config.read_text()
    data = json.loads(text)
    ours = [
        hook["command"]
        for entries in data["hooks"].values()
        for entry in entries
        for hook in entry["hooks"]
        if "--provider claude" in hook["command"]
    ]
    assert len(ours) == len(providers.CLAUDE_EVENTS)
    assert all("-m jrbar.hook_client" in command and str(new_log) in command for command in ours)
    assert "sidepulse.hook_client" not in text
    assert "agent_monitor.hook_entry" not in text
    assert str(old_log) not in text
    assert "echo keep" in text

    repeat = install.install_claude_hooks(log_path=new_log, config_path=config, python_executable=sys.executable)
    assert not repeat.changed


def test_grok_install_strips_our_hooks_from_the_pre_rename_file(tmp_path: Path) -> None:
    hooks_dir = tmp_path / ".grok" / "hooks"
    hooks_dir.mkdir(parents=True)
    config = hooks_dir / "jrbar.json"
    legacy = hooks_dir / "sidepulse.json"
    old_log = tmp_path / OLD_STATE / "grok.jsonl"
    new_log = tmp_path / "state" / "grok.jsonl"
    legacy.write_text(
        json.dumps(
            {
                "hooks": {
                    "SessionStart": [
                        _nested(_old_command("grok", old_log)),
                        {"hooks": [{"type": "command", "command": "echo foreign"}]},
                    ],
                    "Stop": [_nested(_old_command("grok", old_log))],
                }
            }
        )
    )

    result = install.install_grok_hooks(log_path=new_log, config_path=config, python_executable=sys.executable)

    assert result.changed
    assert config.is_file()
    remaining = json.loads(legacy.read_text())
    assert list(remaining["hooks"]) == ["SessionStart"]
    assert remaining["hooks"]["SessionStart"] == [{"hooks": [{"type": "command", "command": "echo foreign"}]}]
    assert "sidepulse.hook_client" not in config.read_text()


def test_grok_install_deletes_a_pre_rename_file_that_held_only_our_hooks(tmp_path: Path) -> None:
    hooks_dir = tmp_path / ".grok" / "hooks"
    hooks_dir.mkdir(parents=True)
    legacy = hooks_dir / "sidepulse.json"
    old_log = tmp_path / OLD_STATE / "grok.jsonl"
    legacy.write_text(json.dumps({"hooks": {"Stop": [_nested(_old_command("grok", old_log))]}}))

    install.install_grok_hooks(
        log_path=tmp_path / "state" / "grok.jsonl",
        config_path=hooks_dir / "jrbar.json",
        python_executable=sys.executable,
    )

    assert not legacy.exists()
    assert list(hooks_dir.glob("sidepulse.json.bak*"))


def test_kiro_install_removes_the_managed_pre_rename_agent_file_only(tmp_path: Path) -> None:
    agents = tmp_path / ".kiro" / "agents"
    agents.mkdir(parents=True)
    legacy = agents / "sidepulse.json"
    legacy.write_text(json.dumps({"name": "sidepulse", "description": providers.KIRO_MANAGED_DESCRIPTION, "hooks": {}}))

    detected_before = providers.detect_kiro_config(tmp_path)
    assert detected_before.config_path == legacy

    result = install.install_kiro_hooks(
        log_path=tmp_path / "state" / "kiro.jsonl",
        config_path=agents / "jrbar.json",
        python_executable=sys.executable,
    )

    assert result.changed
    assert json.loads((agents / "jrbar.json").read_text())["name"] == "jrbar"
    assert not legacy.exists()

    foreign = agents / "sidepulse.json"
    foreign.write_text(json.dumps({"name": "sidepulse", "description": "someone else's agent"}))
    install.install_kiro_hooks(
        log_path=tmp_path / "state" / "kiro.jsonl",
        config_path=agents / "jrbar.json",
        python_executable=sys.executable,
    )
    assert foreign.is_file()


def test_opencode_install_removes_the_pre_rename_plugin_when_it_is_ours(tmp_path: Path) -> None:
    plugins = tmp_path / ".config" / "opencode" / "plugins"
    plugins.mkdir(parents=True)
    legacy = plugins / "sidepulse.js"
    new_log = tmp_path / "state" / "opencode.jsonl"
    legacy.write_text(install.opencode_plugin_source(tmp_path / OLD_STATE / "opencode.jsonl", python_executable=sys.executable))

    result = install.install_opencode_plugin(new_log, plugin_path=plugins / "jrbar.js", python_executable=sys.executable)

    assert result.changed
    assert (plugins / "jrbar.js").is_file()
    assert not legacy.exists()

    legacy.write_text("export default { event: () => {} };\n")
    install.install_opencode_plugin(new_log, plugin_path=plugins / "jrbar.js", python_executable=sys.executable)
    assert legacy.is_file()


def test_openclaw_install_replaces_the_pre_rename_entry_and_handler_dir(tmp_path: Path) -> None:
    root = tmp_path / ".openclaw"
    config = root / "openclaw.json"
    legacy_dir = root / "hooks" / "sidepulse-status"
    legacy_dir.mkdir(parents=True)
    (legacy_dir / "handler.ts").write_text("// Managed by SidePulse -- sidepulse-openclaw-handler-v2\nexport default {};\n")
    (legacy_dir / "HOOK.md").write_text("---\nname: sidepulse-status\n---\nManaged\nby SidePulse\n")
    config.write_text(
        json.dumps(
            {
                "hooks": {
                    "internal": {
                        "enabled": True,
                        "entries": {"sidepulse-status": {"enabled": True}, "other-tool": {"enabled": True}},
                    }
                }
            }
        )
    )

    result = install.install_openclaw_hooks(
        log_path=tmp_path / "state" / "openclaw.jsonl", config_path=config, python_executable=sys.executable
    )

    assert result.changed
    entries = json.loads(config.read_text())["hooks"]["internal"]["entries"]
    assert entries == {"other-tool": {"enabled": True}, "jrbar-status": {"enabled": True}}
    assert (root / "hooks" / "jrbar-status" / "handler.ts").is_file()
    assert not legacy_dir.exists()


def test_openclaw_install_leaves_a_foreign_hook_with_the_old_name_alone(tmp_path: Path) -> None:
    root = tmp_path / ".openclaw"
    config = root / "openclaw.json"
    foreign_dir = root / "hooks" / "sidepulse-status"
    foreign_dir.mkdir(parents=True)
    (foreign_dir / "handler.ts").write_text("export default { somebodyElse: true };\n")
    config.write_text(json.dumps({"hooks": {"internal": {"enabled": True, "entries": {"sidepulse-status": {"enabled": True}}}}}))

    install.install_openclaw_hooks(
        log_path=tmp_path / "state" / "openclaw.jsonl", config_path=config, python_executable=sys.executable
    )

    entries = json.loads(config.read_text())["hooks"]["internal"]["entries"]
    assert entries["sidepulse-status"] == {"enabled": True}
    assert entries["jrbar-status"] == {"enabled": True}
    assert (foreign_dir / "handler.ts").read_text().startswith("export default { somebodyElse")


def test_antigravity_install_replaces_our_pre_rename_named_hook_only(tmp_path: Path) -> None:
    config = tmp_path / ".gemini" / "config" / "hooks.json"
    config.parent.mkdir(parents=True)
    old_log = tmp_path / OLD_STATE / "antigravity.jsonl"
    config.write_text(
        json.dumps(
            {
                "sidepulse-status": {"PreInvocation": [{"command": _old_command("antigravity", old_log)}]},
                "team-linter": {"PostToolUse": [{"command": "./lint.sh"}]},
            }
        )
    )
    assert providers.detect_antigravity_config(tmp_path).log_paths == (old_log,)

    result = install.install_antigravity_hooks(
        log_path=tmp_path / "state" / "antigravity.jsonl", config_path=config, python_executable=sys.executable
    )

    assert result.changed
    data = json.loads(config.read_text())
    assert set(data) == {"jrbar-status", "team-linter"}

    config.write_text(json.dumps({"sidepulse-status": {"PreInvocation": [{"command": "echo foreign"}]}}))
    install.install_antigravity_hooks(
        log_path=tmp_path / "state" / "antigravity.jsonl", config_path=config, python_executable=sys.executable
    )
    data = json.loads(config.read_text())
    assert set(data) == {"jrbar-status", "sidepulse-status"}


def test_openclaw_detection_sees_a_pre_rename_install(tmp_path: Path) -> None:
    root = tmp_path / ".openclaw"
    legacy_dir = root / "hooks" / "sidepulse-status"
    legacy_dir.mkdir(parents=True)
    (root / "openclaw.json").write_text(
        json.dumps({"hooks": {"internal": {"enabled": True, "entries": {"sidepulse-status": {"enabled": True}}}}})
    )
    (legacy_dir / "handler.ts").write_text("// Managed by SidePulse -- sidepulse-openclaw-handler-v2\n")

    detected = providers.detect_openclaw_config(tmp_path)

    # The entry is found under the old name; the handler is read from the
    # old directory (its body is judged by the managed-source check).
    assert detected.exists


def test_a_pre_rename_opencode_plugin_is_recognised_and_replaced(tmp_path: Path) -> None:
    plugins = tmp_path / ".config" / "opencode" / "plugins"
    plugins.mkdir(parents=True)
    old_log = tmp_path / OLD_STATE / "opencode.jsonl"
    arguments = [sys.executable, "-m", "sidepulse.hook_client", "--provider", "opencode", "--log", str(old_log)]
    legacy_source = providers.legacy_opencode_plugin_source_for_arguments(arguments)
    assert legacy_source.startswith("// sidepulse-opencode-plugin-v1\nconst SIDEPULSE_HOOK_ARGS = Object.freeze(")
    assert "export default SidePulsePlugin;" in legacy_source
    assert "JRBAR" not in legacy_source and "JRBar" not in legacy_source
    (plugins / "sidepulse.js").write_text(legacy_source)

    detected = providers.detect_opencode_plugin(tmp_path)
    assert detected.exists and detected.hooks_enabled
    assert detected.config_path == plugins / "sidepulse.js"
    assert detected.log_paths == (old_log,)
    assert providers.detect_log_path("opencode", tmp_path) == providers.default_log_path("opencode", tmp_path)

    install.install_opencode_plugin(
        tmp_path / "state" / "opencode.jsonl", plugin_path=plugins / "jrbar.js", python_executable=sys.executable
    )

    assert not (plugins / "sidepulse.js").exists()
    assert providers.detect_opencode_plugin(tmp_path).config_path == plugins / "jrbar.js"


def test_a_pre_rename_openclaw_handler_is_recognised_as_ours(tmp_path: Path) -> None:
    old_log = tmp_path / OLD_STATE / "openclaw.jsonl"
    arguments = [sys.executable, "-m", "sidepulse.hook_client", "--provider", "openclaw", "--log", str(old_log)]
    legacy_source = providers.legacy_openclaw_handler_source_for_arguments(arguments)
    assert legacy_source.startswith("// Managed by SidePulse -- sidepulse-openclaw-handler-v2\nconst SIDEPULSE_HOOK_ARGS")
    assert "JRBAR" not in legacy_source

    assert providers.managed_openclaw_handler_log_path(legacy_source) == old_log
    assert providers.managed_openclaw_handler_log_path(legacy_source + "// tampered\n") is None

    root = tmp_path / ".openclaw"
    legacy_dir = root / "hooks" / "sidepulse-status"
    legacy_dir.mkdir(parents=True)
    (legacy_dir / "handler.ts").write_text(legacy_source)
    (root / "openclaw.json").write_text(
        json.dumps({"hooks": {"internal": {"enabled": True, "entries": {"sidepulse-status": {"enabled": True}}}}})
    )
    detected = providers.detect_openclaw_config(tmp_path)
    assert detected.hooks_enabled
    assert detected.log_paths == (old_log,)


def test_an_older_generation_pre_rename_plugin_is_still_removed(tmp_path: Path) -> None:
    """Removal must not depend on the body matching the last pre-rename template."""
    plugins = tmp_path / ".config" / "opencode" / "plugins"
    plugins.mkdir(parents=True)
    old_log = tmp_path / OLD_STATE / "opencode.jsonl"
    arguments = [sys.executable, "-m", "sidepulse.hook_entry", "--provider", "opencode", "--log", str(old_log)]
    legacy_source = providers.legacy_opencode_plugin_source_for_arguments(arguments)
    older_body = legacy_source.replace("async function forwardOne", "function forward") + "// older generation\n"
    assert providers.managed_opencode_plugin_log_path(older_body) is None
    assert providers.legacy_opencode_plugin_is_ours(older_body)
    (plugins / "sidepulse.js").write_text(older_body)

    foreign = older_body.replace(sys.executable, "/usr/bin/env", 1)
    assert not providers.legacy_opencode_plugin_is_ours(foreign)

    install.install_opencode_plugin(
        tmp_path / "state" / "opencode.jsonl", plugin_path=plugins / "jrbar.js", python_executable=sys.executable
    )

    assert not (plugins / "sidepulse.js").exists()
