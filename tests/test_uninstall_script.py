"""The uninstaller finds the app and the `jrbar` link where installs put them.

Installs go to ~/Applications and ~/.local/bin/jrbar, but the script used
to look only at /Applications and /usr/local/bin, so it missed both. The
dry run prints every step without sudo, which is what these tests read.
"""

from __future__ import annotations

import os
import subprocess
from pathlib import Path

import pytest

ROOT = Path(__file__).resolve().parents[1]
SCRIPT = ROOT / "scripts" / "uninstall-macos.sh"


def _fake_app(parent: Path) -> Path:
    app = parent / "JR-Bar.app"
    core = app / "Contents" / "Helpers" / "jrbar-core.app" / "Contents" / "MacOS" / "jrbar-core"
    core.parent.mkdir(parents=True)
    core.write_text("#!/bin/sh\nexit 0\n", encoding="utf-8")
    core.chmod(0o755)
    (app / "Contents" / "MacOS").mkdir(parents=True)
    return app


def _dry_run(home: Path, *extra: str, env_extra: dict[str, str] | None = None) -> subprocess.CompletedProcess:
    env = {
        "PATH": "/usr/bin:/bin:/usr/sbin:/sbin",
        "HOME": str(home),
        "JRBAR_HOME": str(home),
        "JRBAR_USER": os.environ.get("USER") or "nobody",
        "JRBAR_RECEIPT_DIR": str(home / "receipts"),
        **(env_extra or {}),
    }
    return subprocess.run(
        ["/bin/bash", str(SCRIPT), "--dry-run", *extra],
        env=env,
        capture_output=True,
        text=True,
        timeout=30,
        check=False,
    )


def test_the_script_parses() -> None:
    result = subprocess.run(["/bin/bash", "-n", str(SCRIPT)], capture_output=True, text=True, timeout=30)
    assert result.returncode == 0, result.stderr


def test_a_real_run_still_insists_on_sudo(tmp_path: Path) -> None:
    if os.geteuid() == 0:
        pytest.skip("running as root")
    env = {"PATH": "/usr/bin:/bin", "JRBAR_HOME": str(tmp_path), "JRBAR_USER": "nobody"}
    result = subprocess.run(
        ["/bin/bash", str(SCRIPT)], env=env, capture_output=True, text=True, timeout=30, check=False
    )
    assert result.returncode == 2
    assert "sudo" in result.stderr


def test_dry_run_finds_the_home_install_and_removes_only_jrbar_links(tmp_path: Path) -> None:
    home = tmp_path / "home"
    app = _fake_app(home / "Applications")
    bin_dir = home / ".local" / "bin"
    bin_dir.mkdir(parents=True)
    ours = bin_dir / "jrbar"
    ours.symlink_to(app / "Contents" / "Helpers" / "jrbar-core.app" / "Contents" / "MacOS" / "jrbar-core")

    result = _dry_run(home)

    assert result.returncode == 0, result.stderr
    out = result.stdout
    assert f"JR-Bar.app: {app}" in out
    assert f"would run: /bin/rm -f {ours}" in out
    assert f"would run: /bin/rm -rf {app}" in out
    assert "agent-monitor uninstall all" in out
    assert "Dry run: nothing was removed" in out
    # Nothing was actually touched.
    assert ours.is_symlink() and app.is_dir()


def test_dry_run_leaves_someone_elses_jrbar_alone(tmp_path: Path) -> None:
    home = tmp_path / "home"
    _fake_app(home / "Applications")
    bin_dir = home / ".local" / "bin"
    bin_dir.mkdir(parents=True)
    other = bin_dir / "jrbar"
    other.symlink_to("/opt/homebrew/bin/something-else")

    result = _dry_run(home)

    assert result.returncode == 0, result.stderr
    assert f"Left existing {other} unchanged because JR-Bar does not own it." in result.stdout
    assert f"/bin/rm -f {other}" not in result.stdout


def test_a_link_into_a_moved_or_dev_bundle_counts_as_ours(tmp_path: Path) -> None:
    home = tmp_path / "home"
    _fake_app(home / "Applications")
    link = tmp_path / "jrbar"
    link.symlink_to("/Volumes/Old/JR-Bar-dev.app/Contents/Helpers/jrbar-core.app/Contents/MacOS/jrbar-core")

    result = _dry_run(home, env_extra={"JRBAR_CLI_LINK": str(link)})

    assert result.returncode == 0, result.stderr
    assert f"would run: /bin/rm -f {link}" in result.stdout


def test_keep_app_and_purge_state(tmp_path: Path) -> None:
    home = tmp_path / "home"
    app = _fake_app(home / "Applications")

    result = _dry_run(home, "--keep-app", "--purge-state")

    assert result.returncode == 0, result.stderr
    assert f"/bin/rm -rf {app}" not in result.stdout
    assert f"{home}/.local/state/jrbar" in result.stdout


def test_without_a_home_install_it_falls_back_to_applications(tmp_path: Path) -> None:
    home = tmp_path / "home"
    home.mkdir()

    result = _dry_run(home)

    assert result.returncode == 0, result.stderr
    assert "JR-Bar.app: /Applications/JR-Bar.app" in result.stdout
