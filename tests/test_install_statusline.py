"""Installing the Claude statusLine never clobbers someone else's.

All of this runs against a Claude settings file in a temporary folder; the
real ~/.claude is never touched.
"""

from __future__ import annotations

import json
import shlex
from pathlib import Path

import pytest

from jrbar.claude_statusline_source import (
    StatusLineInstallError,
    install_statusline,
    is_ours,
    uninstall_statusline,
)


@pytest.fixture
def places(tmp_path: Path) -> tuple[Path, Path, Path]:
    settings = tmp_path / "claude" / "settings.json"
    settings.parent.mkdir()
    state = tmp_path / "state"
    state.mkdir()
    shim = tmp_path / "JR-Bar.app" / "Contents" / "Helpers" / "jrbar-hook"
    shim.parent.mkdir(parents=True)
    shim.write_text("#!/bin/sh\n")
    return settings, state, shim


def _read(path: Path) -> dict:
    return json.loads(path.read_text())


def test_a_fresh_install_adds_ours_and_uninstall_removes_it(places) -> None:
    settings, state, shim = places
    settings.write_text(json.dumps({"hooks": {"Stop": []}, "theme": "dark"}))

    result = install_statusline(shim=shim, settings_path=settings, state_dir=state)

    data = _read(settings)
    assert result["changed"] and not result["wrapped"]
    assert is_ours(data["statusLine"])
    assert shlex.split(data["statusLine"]["command"]) == [str(shim), "--statusline"]
    assert data["theme"] == "dark" and data["hooks"] == {"Stop": []}
    # Installing again changes nothing.
    assert install_statusline(shim=shim, settings_path=settings, state_dir=state)["changed"] is False

    undone = uninstall_statusline(settings_path=settings, state_dir=state)

    assert undone == {"changed": True, "restored": False, "settings": str(settings)}
    assert "statusLine" not in _read(settings)
    assert _read(settings)["theme"] == "dark"


def test_an_existing_statusline_is_never_clobbered(places) -> None:
    settings, state, shim = places
    theirs = {"type": "command", "command": "bun x ccusage statusline", "padding": 1}
    settings.write_text(json.dumps({"statusLine": theirs}))
    before = settings.read_text()

    with pytest.raises(StatusLineInstallError, match="--wrap"):
        install_statusline(shim=shim, settings_path=settings, state_dir=state)

    assert settings.read_text() == before


def test_wrap_then_unwrap_restores_it_exactly(places) -> None:
    settings, state, shim = places
    theirs = {"type": "command", "command": "bash ~/.claude/my status.sh", "padding": 1, "refreshInterval": 5}
    settings.write_text(json.dumps({"statusLine": theirs, "model": "opus"}))

    result = install_statusline(shim=shim, settings_path=settings, state_dir=state, wrap=True)

    wrapped = _read(settings)["statusLine"]
    assert result["wrapped"]
    assert shlex.split(wrapped["command"]) == [str(shim), "--statusline", "--then", "bash ~/.claude/my status.sh"]
    assert wrapped["padding"] == 1 and wrapped["refreshInterval"] == 5

    undone = uninstall_statusline(settings_path=settings, state_dir=state)

    assert undone["restored"] is True
    assert _read(settings) == {"statusLine": theirs, "model": "opus"}


def test_unwrap_works_even_without_the_backup(places) -> None:
    settings, state, shim = places
    theirs = {"type": "command", "command": "echo hi"}
    settings.write_text(json.dumps({"statusLine": theirs}))
    install_statusline(shim=shim, settings_path=settings, state_dir=state, wrap=True)
    (state / "claude-statusline-backup.json").unlink()

    uninstall_statusline(settings_path=settings, state_dir=state)

    assert _read(settings)["statusLine"]["command"] == "echo hi"


def test_uninstall_leaves_someone_elses_statusline_alone(places) -> None:
    settings, state, _shim = places
    theirs = {"type": "command", "command": "starship prompt"}
    settings.write_text(json.dumps({"statusLine": theirs}))

    result = uninstall_statusline(settings_path=settings, state_dir=state)

    assert result["changed"] is False
    assert _read(settings)["statusLine"] == theirs


def test_a_missing_settings_file_is_created_and_a_dry_run_writes_nothing(places) -> None:
    settings, state, shim = places

    dry = install_statusline(shim=shim, settings_path=settings, state_dir=state, dry_run=True)
    assert dry["changed"] and not settings.exists()

    install_statusline(shim=shim, settings_path=settings, state_dir=state)
    assert is_ours(_read(settings)["statusLine"])


def test_the_cli_routes_install_and_refuses_without_wrap(places, monkeypatch, capsys) -> None:
    from jrbar import claude_statusline_source
    from jrbar.cli_entry import jrbar_main

    settings, _state, shim = places
    settings.write_text(json.dumps({"statusLine": {"type": "command", "command": "echo mine"}}))
    monkeypatch.setattr("jrbar.install.hook_shim_path", lambda: shim)
    flips: list[bool] = []
    monkeypatch.setattr(claude_statusline_source, "_set_source_setting", flips.append)

    code = jrbar_main(["agent-monitor", "install", "claude-statusline", "--settings", str(settings)])
    assert code == 1
    assert "--wrap" in capsys.readouterr().err
    assert flips == []

    code = jrbar_main(["agent-monitor", "install", "claude-statusline", "--wrap", "--settings", str(settings)])
    assert code == 0
    assert flips == [True]
    code = jrbar_main(["agent-monitor", "uninstall", "claude-statusline", "--settings", str(settings)])
    assert code == 0
    assert flips == [True, False]
    assert _read(settings)["statusLine"]["command"] == "echo mine"
