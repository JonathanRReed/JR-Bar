"""Hook install, refresh, uninstall, detection and the doctor follow a moved agent home.

Claude Code and Codex let a person move their config: ``CLAUDE_CONFIG_DIR`` and
``CODEX_HOME``. The usage scans already read those (provider_homes.py), but the
hook installer, the detectors and ``hooks doctor`` only knew ``~/.claude`` and
``~/.codex``: a person on a moved home saw hooks "installed" in a folder their
agent never reads, and no event ever arrived. The default instance now resolves
the same home the scans do, and never touches a folder nobody configured.

Every test runs against temporary homes: each gets a HOME of its own, and
tests/conftest.py clears both variables for the process.
"""

from __future__ import annotations

import json
import os
from pathlib import Path

import pytest

from jrbar import provider_homes
from jrbar.hook_doctor import hook_doctor_report, render_hook_doctor
from jrbar.install import (
    install_claude_hooks,
    install_codex_hooks,
    refresh_managed_hooks,
    should_refresh_codex_hook_trust,
    uninstall_claude_hooks,
    uninstall_codex_hooks,
)
from jrbar.providers import (
    default_claude_config_path,
    default_codex_config_path,
    default_log_path,
    detect_claude_config,
    detect_codex_config,
    detect_provider_configs,
)


@pytest.fixture
def default_home(tmp_path: Path, monkeypatch: pytest.MonkeyPatch) -> Path:
    """A fresh HOME of this test's own, where ``~/.claude`` would be: the
    suite's sandbox HOME is shared by every test in the process."""
    home = tmp_path / "home"
    home.mkdir()
    monkeypatch.setenv("HOME", str(home))
    assert Path.home() == home
    return home


@pytest.fixture
def moved_homes(tmp_path: Path, monkeypatch: pytest.MonkeyPatch, default_home: Path) -> dict[str, Path]:
    claude = tmp_path / "accounts" / "claude-work"
    codex = tmp_path / "accounts" / "codex-work"
    claude.mkdir(parents=True)
    codex.mkdir(parents=True)
    monkeypatch.setenv("CLAUDE_CONFIG_DIR", str(claude))
    monkeypatch.setenv("CODEX_HOME", str(codex))
    return {"claude": claude, "codex": codex}


def _doctor_entry(provider: str) -> dict:
    report = hook_doctor_report(compatibility=lambda _names, _directory: {})
    return next(entry for entry in report["providers"] if entry["provider"] == provider)


def test_the_default_config_paths_follow_the_moved_home__and_3_more(
    moved_homes: dict[str, Path], default_home: Path, tmp_path: Path, monkeypatch: pytest.MonkeyPatch
) -> None:
    # --- scenario: the environment's home is the default instance's
    assert default_claude_config_path() == moved_homes["claude"] / "settings.json"
    assert default_codex_config_path() == moved_homes["codex"] / "config.toml"

    # --- scenario: an explicit home is a stand-in for the user's home folder; the environment is not consulted
    assert default_claude_config_path(tmp_path) == tmp_path / ".claude" / "settings.json"
    assert default_codex_config_path(tmp_path) == tmp_path / ".codex" / "config.toml"

    # --- scenario: a variable that names no folder, or a relative one, is ignored like the scans ignore it
    monkeypatch.setenv("CLAUDE_CONFIG_DIR", str(tmp_path / "nowhere"))
    monkeypatch.setenv("CODEX_HOME", "relative/codex")
    assert default_claude_config_path() == default_home / ".claude" / "settings.json"
    assert default_codex_config_path() == default_home / ".codex" / "config.toml"

    # --- scenario: nothing set is the plain default
    monkeypatch.delenv("CLAUDE_CONFIG_DIR")
    monkeypatch.delenv("CODEX_HOME")
    assert default_claude_config_path() == default_home / ".claude" / "settings.json"
    assert default_codex_config_path() == default_home / ".codex" / "config.toml"


def test_claude_install_detect_doctor_refresh_and_uninstall_follow_claude_config_dir(
    moved_homes: dict[str, Path], default_home: Path, tmp_path: Path
) -> None:
    config = moved_homes["claude"] / "settings.json"
    default_config = default_home / ".claude" / "settings.json"
    # A default home that is somebody else's: it must come through untouched.
    default_config.parent.mkdir(parents=True, exist_ok=True)
    foreign = json.dumps({"hooks": {"SessionStart": [{"hooks": [{"type": "command", "command": "other-tool"}]}]}})
    default_config.write_text(foreign)
    log = tmp_path / "state" / "claude.jsonl"

    installed = install_claude_hooks(log_path=log)
    assert installed.config_path == config
    assert installed.changed and config.exists()

    detected = detect_claude_config()
    assert detected.config_path == config and detected.managed
    assert next(item for item in detect_provider_configs() if item.provider == "claude").config_path == config

    entry = _doctor_entry("claude")
    assert entry["config_path"] == str(config)
    assert entry["installed"] is True
    assert entry["config_home"] == "environment"
    report = hook_doctor_report(compatibility=lambda _names, _directory: {})
    assert f"config {config} (the home your environment names)" in render_hook_doctor(report)

    # Refresh finds the managed hooks where they are, and rewrites them there.
    results = refresh_managed_hooks(state_dir=tmp_path / "state")
    refreshed = results["claude"]
    assert not isinstance(refreshed, Exception), refreshed
    assert refreshed.config_path == config

    removed = uninstall_claude_hooks(log_path=log)
    assert removed.config_path == config and removed.changed
    assert not detect_claude_config().managed

    assert default_config.read_text() == foreign, "a home nobody configured was touched"


def test_codex_install_detect_doctor_refresh_and_uninstall_follow_codex_home(
    moved_homes: dict[str, Path], default_home: Path, tmp_path: Path
) -> None:
    config = moved_homes["codex"] / "config.toml"
    default_config = default_home / ".codex" / "config.toml"
    default_config.parent.mkdir(parents=True, exist_ok=True)
    foreign = '[features]\nhooks = true\n\n[[hooks.SessionStart]]\ncommand = "other-tool"\n'
    default_config.write_text(foreign)
    log = tmp_path / "state" / "codex.jsonl"

    installed = install_codex_hooks(log_path=log)
    assert installed.config_path == config
    assert installed.changed and config.exists()
    # The default instance gets the trust handshake, wherever its config is.
    assert installed.codex_trust is not None and installed.codex_trust.value != "not_attempted"

    detected = detect_codex_config()
    assert detected.config_path == config and detected.managed

    entry = _doctor_entry("codex")
    assert entry["config_path"] == str(config)
    assert entry["installed"] is True
    assert entry["config_home"] == "environment"

    results = refresh_managed_hooks(state_dir=tmp_path / "state")
    refreshed = results["codex"]
    assert not isinstance(refreshed, Exception), refreshed
    assert refreshed.config_path == config

    removed = uninstall_codex_hooks(log_path=log)
    assert removed.config_path == config and removed.changed
    assert not detect_codex_config().managed

    assert default_config.read_text() == foreign, "a home nobody configured was touched"


def test_trust_is_refreshed_for_the_default_instances_config_and_only_that(
    moved_homes: dict[str, Path], default_home: Path
) -> None:
    moved = moved_homes["codex"] / "config.toml"
    plain = default_home / ".codex" / "config.toml"
    assert should_refresh_codex_hook_trust(moved, None) is True
    # The plain default is no longer the default instance's while a moved home is set.
    assert should_refresh_codex_hook_trust(plain, plain) is False


def test_without_a_moved_home_everything_stays_on_the_plain_default(default_home: Path, tmp_path: Path) -> None:
    log = tmp_path / "state" / "claude.jsonl"
    installed = install_claude_hooks(log_path=log)
    assert installed.config_path == default_home / ".claude" / "settings.json"
    assert _doctor_entry("claude")["config_home"] == "default"
    assert _doctor_entry("claude")["config_path"] == str(installed.config_path)
    uninstall_claude_hooks(log_path=log)


def test_the_scans_and_the_installer_resolve_the_same_home(
    moved_homes: dict[str, Path], default_home: Path
) -> None:
    """One resolution for both: the folder the usage scan reads transcripts
    from is the folder the installer writes hooks to."""
    assert provider_homes.primary_claude_projects().parent == moved_homes["claude"]
    assert provider_homes.primary_codex_sessions().parent == moved_homes["codex"]
    assert default_claude_config_path().parent == provider_homes.primary_claude_home()
    assert default_codex_config_path().parent == provider_homes.primary_codex_home()
    assert os.environ["CLAUDE_CONFIG_DIR"] == str(provider_homes.primary_claude_home())
    assert default_log_path("claude").parent != moved_homes["claude"], "the state dir is not an agent home"
