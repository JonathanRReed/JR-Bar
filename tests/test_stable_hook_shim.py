"""Provider hooks run a launcher under the home directory, not a path inside
the app bundle, so trashing or moving the app never fails an agent's tool
call."""

from __future__ import annotations

import json
import os
import subprocess
from pathlib import Path

import pytest

from jrbar.install import (
    hook_command_arguments,
    install_claude_hooks,
    remove_stable_hook_shim,
    stable_hook_shim,
    uninstall_claude_hooks,
)


def _bundle_shim(root: Path, record: Path) -> Path:
    shim = root / "JR-Bar.app" / "Contents" / "Helpers" / "jrbar-hook"
    shim.parent.mkdir(parents=True)
    shim.write_text(f'#!/bin/sh\nprintf "%s\\n" "$*" >> "{record}"\n', encoding="utf-8")
    shim.chmod(0o755)
    return shim


@pytest.fixture
def home(tmp_path: Path, monkeypatch: pytest.MonkeyPatch) -> Path:
    home = tmp_path / "home"
    home.mkdir()
    monkeypatch.setenv("HOME", str(home))
    return home


def test_a_bundled_shim_is_reached_through_a_launcher_under_the_home(
    tmp_path: Path, home: Path, monkeypatch: pytest.MonkeyPatch
) -> None:
    record = tmp_path / "ran"
    shim = _bundle_shim(tmp_path / "apps", record)
    monkeypatch.setenv("JRBAR_HOOK_EXEC", str(shim))

    arguments = hook_command_arguments("claude", home / "claude.jsonl")

    launcher = home / ".local" / "share" / "jrbar" / "hook" / "jrbar-hook"
    assert arguments[0] == str(launcher)
    assert launcher.stat().st_mode & 0o777 == 0o755
    subprocess.run([str(launcher), "--provider", "claude"], check=True, timeout=30)
    assert record.read_text().strip() == "--provider claude"


def test_the_launcher_exits_zero_once_the_bundle_is_gone(
    tmp_path: Path, home: Path, monkeypatch: pytest.MonkeyPatch
) -> None:
    record = tmp_path / "ran"
    shim = _bundle_shim(tmp_path / "apps", record)
    monkeypatch.setenv("JRBAR_HOOK_EXEC", str(shim))
    launcher = stable_hook_shim()
    assert launcher is not None and launcher != shim

    shim.unlink()
    result = subprocess.run([str(launcher), "--provider", "claude"], timeout=30, capture_output=True)

    assert result.returncode == 0
    assert result.stdout == b"" and not record.exists()


def test_a_shim_outside_a_bundle_is_used_as_it_is(
    tmp_path: Path, home: Path, monkeypatch: pytest.MonkeyPatch
) -> None:
    dev = tmp_path / "prefix" / "bin" / "jrbar-hook"
    dev.parent.mkdir(parents=True)
    dev.write_text("#!/bin/sh\n", encoding="utf-8")
    dev.chmod(0o755)
    monkeypatch.setenv("JRBAR_HOOK_EXEC", str(dev))

    assert stable_hook_shim() == dev
    assert hook_command_arguments("claude", home / "c.jsonl")[0] == str(dev)
    assert not (home / ".local" / "share" / "jrbar" / "hook").exists()


def test_a_moved_app_rewrites_the_launcher_and_an_unchanged_one_is_left_alone(
    tmp_path: Path, home: Path, monkeypatch: pytest.MonkeyPatch
) -> None:
    record = tmp_path / "ran"
    first = _bundle_shim(tmp_path / "one", record)
    monkeypatch.setenv("JRBAR_HOOK_EXEC", str(first))
    launcher = stable_hook_shim()
    assert launcher is not None
    stamp = launcher.stat().st_mtime_ns
    assert stable_hook_shim() == launcher
    assert launcher.stat().st_mtime_ns == stamp

    second = _bundle_shim(tmp_path / "two", record)
    monkeypatch.setenv("JRBAR_HOOK_EXEC", str(second))
    assert stable_hook_shim() == launcher
    assert str(second) in launcher.read_text()
    assert str(first) not in launcher.read_text()


def test_an_old_install_that_names_the_bundle_is_migrated_and_stays_idempotent(
    tmp_path: Path, home: Path, monkeypatch: pytest.MonkeyPatch
) -> None:
    record = tmp_path / "ran"
    shim = _bundle_shim(tmp_path / "apps", record)
    monkeypatch.setenv("JRBAR_HOOK_EXEC", str(shim))
    config = home / ".claude" / "settings.json"
    config.parent.mkdir(parents=True)
    log = home / "claude.jsonl"
    config.write_text(
        json.dumps(
            {
                "hooks": {
                    "SessionStart": [
                        {"hooks": [{"type": "command", "command": f"{shim} --provider claude --log {log}"}]},
                        {"hooks": [{"type": "command", "command": "/usr/bin/true"}]},
                    ]
                }
            }
        ),
        encoding="utf-8",
    )

    first = install_claude_hooks(log_path=log, config_path=config)
    assert first.changed
    launcher = str(home / ".local" / "share" / "jrbar" / "hook" / "jrbar-hook")
    text = config.read_text()
    assert launcher in text
    assert f"{shim} " not in text
    assert "/usr/bin/true" in text
    commands = [
        hook["command"]
        for group in json.loads(text)["hooks"]["SessionStart"]
        for hook in group["hooks"]
    ]
    assert sum(1 for command in commands if "jrbar-hook" in command) == 1

    again = install_claude_hooks(log_path=log, config_path=config)
    assert not again.changed

    removed = uninstall_claude_hooks(log_path=log, config_path=config)
    assert removed.changed
    after = config.read_text()
    assert "jrbar-hook" not in after and "/usr/bin/true" in after


def test_removing_the_launcher_is_a_no_op_when_it_is_not_there(home: Path) -> None:
    assert remove_stable_hook_shim() is False


def test_the_launcher_is_removed_on_request(
    tmp_path: Path, home: Path, monkeypatch: pytest.MonkeyPatch
) -> None:
    shim = _bundle_shim(tmp_path / "apps", tmp_path / "ran")
    monkeypatch.setenv("JRBAR_HOOK_EXEC", str(shim))
    launcher = stable_hook_shim()
    assert launcher is not None and launcher.exists()

    assert remove_stable_hook_shim() is True
    assert not launcher.exists()
    assert os.path.isdir(home / ".local" / "share" / "jrbar")
