"""Wheel verification subprocesses use temporary user state."""

from __future__ import annotations

import os
import subprocess
from pathlib import Path

from scripts import verify_clean_install


def test_run_replaces_home_and_provider_overrides(monkeypatch, tmp_path):
    inherited = {
        "HOME": "/synthetic/caller/home",
        "XDG_CONFIG_HOME": "/synthetic/caller/config",
        "XDG_STATE_HOME": "/synthetic/caller/state",
        "XDG_CACHE_HOME": "/synthetic/caller/cache",
        "XDG_DATA_HOME": "/synthetic/caller/data",
        "CODEX_HOME": "/synthetic/caller/codex",
        "CLAUDE_CONFIG_DIR": "/synthetic/caller/claude",
        "PYTHONPATH": "/synthetic/caller/source",
    }
    for name, value in inherited.items():
        monkeypatch.setenv(name, value)
    calls = []

    def capture(arguments, **kwargs):
        calls.append((arguments, kwargs))
        return subprocess.CompletedProcess(arguments, 0, "", "")

    monkeypatch.setattr(verify_clean_install.subprocess, "run", capture)
    home = tmp_path / "home"
    verify_clean_install.run("fixture-python", "-m", "jrbar.hook_client", home=home, cwd=tmp_path)
    arguments, options = calls[0]
    assert arguments == ["fixture-python", "-m", "jrbar.hook_client"]
    environment = options["env"]
    assert environment["HOME"] == str(home)
    for name in ("XDG_CONFIG_HOME", "XDG_STATE_HOME", "XDG_CACHE_HOME", "XDG_DATA_HOME"):
        assert Path(environment[name]).is_relative_to(home)
    assert "CODEX_HOME" not in environment
    assert "CLAUDE_CONFIG_DIR" not in environment
    assert environment["PYTHONPATH"] == ""
    assert options["cwd"] == tmp_path
    assert options["timeout"] == 900
    assert all(os.environ[name] == value for name, value in inherited.items())


def test_main_isolates_every_subprocess(monkeypatch, tmp_path):
    wheel = tmp_path / "jrbar-fixture.whl"
    wheel.touch()
    monkeypatch.setattr(verify_clean_install, "wheel_path", lambda: wheel)
    monkeypatch.setattr(verify_clean_install.platform, "system", lambda: "Darwin")
    calls = []

    def capture(arguments, **kwargs):
        calls.append((arguments, kwargs))
        if arguments[1:3] == ["-m", "venv"]:
            bin_dir = Path(arguments[3]) / "bin"
            bin_dir.mkdir(parents=True)
            for name in ("python", "jrbar", "jrbar-integrations"):
                path = bin_dir / name
                path.write_text("fixture")
                path.chmod(0o755)
        return subprocess.CompletedProcess(arguments, 0, "", "")

    monkeypatch.setattr(verify_clean_install.subprocess, "run", capture)
    assert verify_clean_install.main() == 0
    assert len(calls) == 10
    homes = {options["env"]["HOME"] for _, options in calls}
    assert len(homes) == 1
    home = Path(homes.pop())
    assert home.name == "home"
    assert home.parent.name.startswith("jrbar-clean-install-")
    assert all(options["cwd"] == home.parent for _, options in calls)
    assert any(arguments[1:] == ["-m", "jrbar.hook_client"] for arguments, _ in calls)
    assert any(arguments[1:] == ["-m", "jrbar.hook_entry"] for arguments, _ in calls)
