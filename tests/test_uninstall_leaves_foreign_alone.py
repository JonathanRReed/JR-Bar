"""Uninstalling hooks that were never installed touches nothing.

`agent-monitor uninstall all` (and Settings > Providers > Remove Hooks) used to read every
agent's config with the installer's tightening on, so on a Mac with no JR-Bar hooks it still
created `~/.cursor`, `~/.hermes`, `~/.gemini` and the rest, and tightened folders and
files the agents own to 0700/0600.
"""

from __future__ import annotations

import os
import stat
from pathlib import Path

import pytest

from jrbar.install import uninstall_provider_hooks
from jrbar.providers import HOOK_PROVIDERS


@pytest.fixture
def home(tmp_path: Path, monkeypatch: pytest.MonkeyPatch) -> Path:
    place = tmp_path / "home"
    place.mkdir(mode=0o700)
    monkeypatch.setenv("HOME", str(place))
    monkeypatch.setenv("XDG_STATE_HOME", str(tmp_path / "state"))
    monkeypatch.delenv("CLAUDE_CONFIG_DIR", raising=False)
    monkeypatch.delenv("CODEX_HOME", raising=False)
    monkeypatch.delenv("XDG_CONFIG_HOME", raising=False)
    return place


def _uninstall_everything(tmp_path: Path) -> None:
    for provider in HOOK_PROVIDERS:
        uninstall_provider_hooks(
            provider, log_path=None, dry_run=False, state_dir=tmp_path / "state"
        )


def test_uninstalling_on_a_clean_mac_creates_no_agent_folders(home: Path, tmp_path: Path) -> None:
    _uninstall_everything(tmp_path)
    assert sorted(entry.name for entry in home.iterdir()) == []


def test_uninstalling_leaves_foreign_configs_byte_identical_and_their_modes(
    home: Path, tmp_path: Path
) -> None:
    claude = home / ".claude" / "settings.json"
    codex = home / ".codex" / "config.toml"
    gemini = home / ".gemini" / "settings.json"
    texts = {
        claude: '{"theme": "dark", "hooks": {"PreToolUse": [{"matcher": "*", "hooks": [{"type": "command", "command": "/opt/other/lint"}]}]}}\n',
        codex: '# my codex settings\nmodel = "x"\n',
        gemini: '{"theme": "light"}\n',
    }
    for path, text in texts.items():
        path.parent.mkdir(mode=0o755)
        path.write_text(text)
        path.chmod(0o644)
    before = {path: path.stat().st_mtime_ns for path in texts}

    _uninstall_everything(tmp_path)

    for path, text in texts.items():
        assert path.read_text() == text
        assert stat.S_IMODE(path.stat().st_mode) == 0o644, path
        assert stat.S_IMODE(path.parent.stat().st_mode) == 0o755, path.parent
        assert path.stat().st_mtime_ns == before[path]
        assert [p.name for p in path.parent.iterdir()] == [path.name], "no backup for a no-op"
    assert len(os.listdir(home)) == 3
