from __future__ import annotations

import os
import plistlib
import subprocess
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
SCRIPT = ROOT / "scripts" / "install-agents.sh"


def _write_executable(path: Path, body: str = "exit 0") -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(f"#!/bin/sh\n{body}\n", encoding="utf-8")
    path.chmod(0o755)


def _app(path: Path, marker: str) -> Path:
    _write_executable(path / "Contents" / "MacOS" / "JR-Bar")
    _write_executable(path / "Contents" / "Helpers" / "jrbar-core.app" / "Contents" / "MacOS" / "jrbar-core")
    _write_executable(path / "Contents" / "Helpers" / "jrbar-hook")
    (path / "Contents" / "Info.plist").write_bytes(
        plistlib.dumps(
            {
                "CFBundleIdentifier": "com.jonathanreed.jrbar",
                "CFBundleShortVersionString": "0.9.11",
                "JRBarCommit": marker,
            }
        )
    )
    (path / "marker").write_text(marker, encoding="utf-8")
    return path


def _tool(path: Path, body: str) -> None:
    _write_executable(path, body)


def _environment(
    tmp_path: Path,
    *,
    ditto_body: str,
    codesign_body: str = "exit 0",
) -> tuple[dict[str, str], Path, Path]:
    home = tmp_path / "home"
    agents = home / "Library" / "LaunchAgents"
    agents.mkdir(parents=True)
    app = _app(home / "Applications" / "JR-Bar.app", "old")
    for label in ("com.jonathanreed.jrbar.core", "com.jonathanreed.jrbar.ui"):
        (agents / f"{label}.plist").write_text(label, encoding="utf-8")

    bin_dir = tmp_path / "bin"
    marker = tmp_path / "side-effect"
    _tool(bin_dir / "launchctl", f"printf launchctl > '{marker}'\nexit 1")
    _tool(bin_dir / "codesign", codesign_body)
    _tool(bin_dir / "ditto", ditto_body)
    _tool(bin_dir / "open", "exit 0")
    _tool(bin_dir / "pgrep", "exit 1")
    _tool(bin_dir / "kill", "exit 0")
    _tool(bin_dir / "sleep", "exit 0")
    _tool(bin_dir / "seq", "exit 0")
    _tool(bin_dir / "ps", "exit 0")
    _tool(bin_dir / "git", "/usr/bin/git \"$@\"")
    _tool(bin_dir / "osascript", "exit 0")

    env = os.environ.copy()
    env.update(
        {
            "HOME": str(home),
            "PATH": f"{bin_dir}:/usr/bin:/bin:/usr/sbin:/sbin",
            "PGREP_TOOL": str(bin_dir / "pgrep"),
            "PS_TOOL": str(bin_dir / "ps"),
            "KILL_TOOL": str(bin_dir / "kill"),
            "STOP_SLEEP_TOOL": str(bin_dir / "sleep"),
            "RECOVERY_OPEN_TOOL": str(bin_dir / "open"),
            "LSREGISTER_TOOL": str(tmp_path / "missing-lsregister"),
            "XDG_STATE_HOME": str(home / ".local" / "state"),
        }
    )
    return env, app, marker


def test_unsupported_source_is_rejected_before_stopping_or_moving_the_install(tmp_path: Path) -> None:
    env, app, marker = _environment(tmp_path, ditto_body="exit 99")
    source = tmp_path / "candidate.txt"
    source.write_text("not an app", encoding="utf-8")
    launcher = Path(env["HOME"]) / "Library" / "LaunchAgents" / "com.jonathanreed.jrbar.ui.plist"

    result = subprocess.run(
        ["/bin/zsh", str(SCRIPT), "--pkg", str(source)],
        cwd=ROOT,
        env=env,
        capture_output=True,
        text=True,
        timeout=30,
        check=False,
    )

    assert result.returncode == 2
    assert "SOURCE must be a .pkg or a JR-Bar.app" in result.stderr
    assert (app / "marker").read_text(encoding="utf-8") == "old"
    assert launcher.is_file()
    assert not marker.exists(), "validation must finish before launchctl is called"


def test_failed_copy_restores_the_previous_app_and_launch_agents(tmp_path: Path) -> None:
    env, app, _ = _environment(tmp_path, ditto_body="exit 73")
    source = _app(tmp_path / "JR-Bar.app", "new")
    agents = Path(env["HOME"]) / "Library" / "LaunchAgents"

    result = subprocess.run(
        ["/bin/zsh", str(SCRIPT), "--pkg", str(source)],
        cwd=ROOT,
        env=env,
        capture_output=True,
        text=True,
        timeout=30,
        check=False,
    )

    assert result.returncode == 73
    assert "restoring the previous JR-Bar app and launch agents" in result.stderr
    assert (app / "marker").read_text(encoding="utf-8") == "old"
    assert (agents / "com.jonathanreed.jrbar.core.plist").is_file()
    assert (agents / "com.jonathanreed.jrbar.ui.plist").is_file()


def test_verified_copy_commits_the_new_app_and_parks_development_agents(tmp_path: Path) -> None:
    env, app, _ = _environment(tmp_path, ditto_body='/bin/cp -R "$1" "$2"')
    source = _app(tmp_path / "JR-Bar.app", "new")
    home = Path(env["HOME"])

    result = subprocess.run(
        ["/bin/zsh", str(SCRIPT), "--pkg", str(source)],
        cwd=ROOT,
        env=env,
        capture_output=True,
        text=True,
        timeout=30,
        check=False,
    )

    assert result.returncode == 0, result.stderr
    assert (app / "marker").read_text(encoding="utf-8") == "new"
    for label in ("com.jonathanreed.jrbar.core", "com.jonathanreed.jrbar.ui"):
        assert not (home / "Library" / "LaunchAgents" / f"{label}.plist").exists()
        assert (home / ".local" / "state" / "jrbar" / f"{label}.plist.disabled").is_file()


def test_failed_installed_signature_restores_the_previous_app_and_agents(tmp_path: Path) -> None:
    calls = tmp_path / "codesign-calls"
    codesign = f"""
count=0
[ ! -f '{calls}' ] || count="$(cat '{calls}')"
count=$((count + 1))
printf '%s' "$count" > '{calls}'
[ "$count" -eq 1 ]
"""
    env, app, _ = _environment(
        tmp_path,
        ditto_body='/bin/cp -R "$1" "$2"',
        codesign_body=codesign,
    )
    source = _app(tmp_path / "JR-Bar.app", "new")
    agents = Path(env["HOME"]) / "Library" / "LaunchAgents"

    result = subprocess.run(
        ["/bin/zsh", str(SCRIPT), "--pkg", str(source)],
        cwd=ROOT,
        env=env,
        capture_output=True,
        text=True,
        timeout=30,
        check=False,
    )

    assert result.returncode != 0
    assert "restoring the previous JR-Bar app and launch agents" in result.stderr
    assert (app / "marker").read_text(encoding="utf-8") == "old"
    assert (agents / "com.jonathanreed.jrbar.core.plist").is_file()
    assert (agents / "com.jonathanreed.jrbar.ui.plist").is_file()


def test_install_stops_only_the_pid_running_the_verified_installed_path(tmp_path: Path) -> None:
    env, app, _ = _environment(tmp_path, ditto_body='/bin/cp -R "$1" "$2"')
    source = _app(tmp_path / "JR-Bar.app", "new")
    bin_dir = Path(env["PATH"].split(":", 1)[0])
    killed = tmp_path / "killed"
    observations = tmp_path / "pid-101-observations"
    _tool(bin_dir / "pgrep", "printf '101\\n102\\n'")
    _tool(
        bin_dir / "ps",
        f"""
if [ "$2" = 101 ]; then
    count=0
    [ ! -f '{observations}' ] || count="$(cat '{observations}')"
    count=$((count + 1))
    printf '%s' "$count" > '{observations}'
    [ "$count" -gt 3 ] || printf '%s\\n' '{app}/Contents/MacOS/JR-Bar'
else
    printf '%s\\n' '/tmp/another/JR-Bar'
fi
""",
    )
    _tool(bin_dir / "kill", f"printf '%s\\n' \"$*\" >> '{killed}'")

    result = subprocess.run(
        ["/bin/zsh", str(SCRIPT), "--pkg", str(source)],
        cwd=ROOT,
        env=env,
        capture_output=True,
        text=True,
        timeout=30,
        check=False,
    )

    assert result.returncode == 0, result.stderr
    assert killed.read_text(encoding="utf-8").splitlines() == ["-TERM 101"]
    assert int(observations.read_text(encoding="utf-8")) >= 4


def test_failed_term_preserves_the_original_app_and_agent_files_before_move(tmp_path: Path) -> None:
    copied = tmp_path / "ditto-called"
    env, app, _ = _environment(tmp_path, ditto_body=f"printf called > '{copied}'")
    source = _app(tmp_path / "JR-Bar.app", "new")
    bin_dir = Path(env["PATH"].split(":", 1)[0])
    _tool(bin_dir / "pgrep", "printf '101\\n'")
    _tool(bin_dir / "ps", f"printf '%s\\n' '{app}/Contents/MacOS/JR-Bar'")
    _tool(bin_dir / "kill", "exit 79")
    agents = Path(env["HOME"]) / "Library" / "LaunchAgents"

    result = subprocess.run(
        ["/bin/zsh", str(SCRIPT), "--pkg", str(source)],
        cwd=ROOT,
        env=env,
        capture_output=True,
        text=True,
        timeout=30,
        check=False,
    )

    assert result.returncode != 0
    assert "could not be stopped; the installed app was not moved" in result.stderr
    assert (app / "marker").read_text(encoding="utf-8") == "old"
    assert not copied.exists()
    assert (agents / "com.jonathanreed.jrbar.core.plist").is_file()
    assert (agents / "com.jonathanreed.jrbar.ui.plist").is_file()


def test_process_that_does_not_exit_preserves_original_bytes_and_agents(tmp_path: Path) -> None:
    copied = tmp_path / "ditto-called"
    env, app, _ = _environment(tmp_path, ditto_body=f"printf called > '{copied}'")
    source = _app(tmp_path / "JR-Bar.app", "new")
    bin_dir = Path(env["PATH"].split(":", 1)[0])
    killed = tmp_path / "killed"
    _tool(bin_dir / "pgrep", "printf '101\\n102\\n'")
    _tool(
        bin_dir / "ps",
        f"""
if [ "$2" = 101 ]; then
    printf '%s\\n' '{app}/Contents/MacOS/JR-Bar'
else
    printf '%s\\n' '/tmp/foreign/JR-Bar'
fi
""",
    )
    _tool(bin_dir / "kill", f"printf '%s\\n' \"$*\" >> '{killed}'")
    agents = Path(env["HOME"]) / "Library" / "LaunchAgents"

    result = subprocess.run(
        ["/bin/zsh", str(SCRIPT), "--pkg", str(source)],
        cwd=ROOT,
        env=env,
        capture_output=True,
        text=True,
        timeout=30,
        check=False,
    )

    assert result.returncode != 0
    assert "did not exit; the installed app was not moved" in result.stderr
    assert killed.read_text(encoding="utf-8").splitlines() == ["-TERM 101"]
    assert (app / "marker").read_text(encoding="utf-8") == "old"
    assert not copied.exists()
    assert (agents / "com.jonathanreed.jrbar.core.plist").is_file()
    assert (agents / "com.jonathanreed.jrbar.ui.plist").is_file()
