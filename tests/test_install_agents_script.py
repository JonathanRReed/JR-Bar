from __future__ import annotations

import os
import plistlib
import shutil
import subprocess
from pathlib import Path

import pytest

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


@pytest.mark.parametrize("previous", ["notRegistered", "requiresApproval", "enabled", "unknown"])
def test_packaged_upgrade_does_not_change_login_choice(tmp_path: Path, previous: str) -> None:
    env, app, _ = _environment(tmp_path, ditto_body='/bin/cp -R "$1" "$2"')
    source = _app(tmp_path / "JR-Bar.app", "new")
    state = tmp_path / "login-state"
    state.write_text(previous, encoding="utf-8")
    requests = tmp_path / "login-requests"
    env["JRBAR_LOGIN_TEST_STATE"] = str(state)
    env["JRBAR_LOGIN_TEST_REQUESTS"] = str(requests)
    _write_executable(source / "Contents/MacOS/JR-Bar", r'''
case "${JRBAR_LOGIN_ITEM:-}" in
    on)
        printf 'on\n' >> "$JRBAR_LOGIN_TEST_REQUESTS"
        printf enabled > "$JRBAR_LOGIN_TEST_STATE"
        printf 'login item: enabled\n'
        ;;
    status) cat "$JRBAR_LOGIN_TEST_STATE" ;;
    *) exit 0 ;;
esac
''')
    result = subprocess.run(
        ["/bin/zsh", str(SCRIPT), "--pkg", str(source)], cwd=ROOT,
        env=env, capture_output=True, text=True, timeout=30, check=False,
    )
    assert result.returncode == 0, result.stderr
    assert (app / "marker").read_text(encoding="utf-8") == "new"
    assert state.read_text(encoding="utf-8") == previous
    assert not requests.exists(), "the app's first-run owner decides whether to register"


def _dev_handoff(tmp_path: Path, *, ditto_body: str = '/bin/cp -R "$1" "$2"',
                 codesign_body: str = "exit 0") -> tuple[dict[str, str], Path, Path, Path, Path]:
    env, app, _ = _environment(tmp_path, ditto_body=ditto_body, codesign_body=codesign_body)
    shutil.rmtree(app / "Contents/Helpers/jrbar-core.app")
    plist = Path(env["HOME"]) / "Library/LaunchAgents/com.jonathanreed.jrbar.ui.plist"
    plist.write_bytes(plistlib.dumps({
        "Label": "com.jonathanreed.jrbar.ui",
        "ProgramArguments": [str(app / "Contents/MacOS/JR-Bar")],
        "RunAtLoad": True,
    }))
    bin_dir = Path(env["PATH"].split(":", 1)[0])
    _tool(bin_dir / "launchctl", '''
if [ "$1" = print-disabled ]; then
    printf 'disabled services = {\\n}\\n'
    exit 0
fi
exit 1
''')
    source = _app(tmp_path / "JR-Bar.app", "new")
    requests = tmp_path / "login-requests"
    env["JRBAR_LOGIN_TEST_REQUESTS"] = str(requests)
    _write_executable(source / "Contents/MacOS/JR-Bar", r'''
[ -z "${JRBAR_LOGIN_ITEM:-}" ] || printf '%s\n' "$JRBAR_LOGIN_ITEM" >> "$JRBAR_LOGIN_TEST_REQUESTS"
exit 0
''')
    return env, app, source, plist, requests


def _install(env: dict[str, str], source: Path) -> subprocess.CompletedProcess[str]:
    return subprocess.run(
        ["/bin/zsh", str(SCRIPT), "--pkg", str(source)], cwd=ROOT,
        env=env, capture_output=True, text=True, timeout=30, check=False,
    )


def test_owned_dev_startup_transfers_once_even_when_job_is_unloaded(tmp_path: Path) -> None:
    env, app, source, plist, requests = _dev_handoff(tmp_path)
    # launchctl print and bootout both fail, so this is configured but unloaded.
    result = _install(env, source)
    assert result.returncode == 0, result.stderr
    assert requests.read_text().splitlines() == ["on"]
    assert not plist.exists()
    assert (app / "marker").read_text() == "new"
    result = _install(env, source)
    assert result.returncode == 0, result.stderr
    assert requests.read_text().splitlines() == ["on"]


@pytest.mark.parametrize("invalid", [
    "no_plist", "malformed", "symlink", "wrong_label", "extra_argument",
    "wrong_argument", "arguments_string", "run_false", "run_string", "run_integer",
    "wrong_bundle", "missing_app", "missing_binary", "packaged_app", "dangling_helper", "run_missing",
])
def test_unowned_or_inactive_layout_does_not_transfer_startup(tmp_path: Path, invalid: str) -> None:
    env, app, source, plist, requests = _dev_handoff(tmp_path)
    data = plistlib.loads(plist.read_bytes())
    if invalid == "no_plist":
        plist.unlink()
    elif invalid == "malformed":
        plist.write_text("not a plist")
    elif invalid == "symlink":
        target = tmp_path / "foreign.plist"
        plist.rename(target)
        plist.symlink_to(target)
    elif invalid == "wrong_bundle":
        info = app / "Contents/Info.plist"
        info.write_bytes(plistlib.dumps({"CFBundleIdentifier": "example.other"}))
    elif invalid == "missing_app":
        shutil.rmtree(app)
    elif invalid == "missing_binary":
        (app / "Contents/MacOS/JR-Bar").unlink()
    elif invalid == "dangling_helper":
        (app / "Contents/Helpers/jrbar-core.app").symlink_to(tmp_path / "missing-helper")
    elif invalid == "run_missing":
        data.pop("RunAtLoad")
        plist.write_bytes(plistlib.dumps(data))
    elif invalid == "packaged_app":
        _write_executable(app / "Contents/Helpers/jrbar-core.app/Contents/MacOS/jrbar-core")
    else:
        if invalid == "wrong_label":
            data["Label"] = "example.other"
        elif invalid == "extra_argument":
            data["ProgramArguments"].append("--other")
        elif invalid == "wrong_argument":
            data["ProgramArguments"] = ["/tmp/foreign/JR-Bar"]
        elif invalid == "arguments_string":
            data["ProgramArguments"] = str(app / "Contents/MacOS/JR-Bar")
        else:
            data["RunAtLoad"] = {"run_false": False, "run_string": "true", "run_integer": 1}[invalid]
        plist.write_bytes(plistlib.dumps(data))
    result = _install(env, source)
    assert result.returncode == 0, result.stderr
    assert not requests.exists()


@pytest.mark.parametrize("output,code,transfer", [
    ('disabled services = {\n    "com.jonathanreed.jrbar.ui" => true\n}\n', 0, False),
    ('disabled services = {\n    "com.jonathanreed.jrbar.ui" => false\n}\n', 0, True),
    ('disabled services = {\n    "example.other" => true\n}\n', 0, True),
    ('disabled services = {\n    "com.jonathanreed.jrbar.ui" => unknown\n}\n', 0, False),
    ('disabled services = {\n', 0, False),
    ('unrecognized output\n', 0, False),
    ('disabled services = {\n}\n', 1, False),
])
def test_disabled_job_and_unreadable_disable_state_are_respected(
    tmp_path: Path, output: str, code: int, transfer: bool,
) -> None:
    env, _, source, _, requests = _dev_handoff(tmp_path)
    bin_dir = Path(env["PATH"].split(":", 1)[0])
    _tool(bin_dir / "launchctl", f"""
if [ "$1" = print-disabled ]; then
    cat <<'DISABLED_STATE'
{output.rstrip()}
DISABLED_STATE
    exit {code}
fi
exit 1
""")
    result = _install(env, source)
    assert result.returncode == 0, result.stderr
    assert requests.exists() is transfer
    if transfer:
        assert requests.read_text().splitlines() == ["on"]


def test_fresh_install_leaves_registration_to_the_app(tmp_path: Path) -> None:
    env, app, source, plist, requests = _dev_handoff(tmp_path)
    shutil.rmtree(app)
    plist.unlink()
    result = _install(env, source)
    assert result.returncode == 0, result.stderr
    assert not requests.exists()


@pytest.mark.parametrize("failure", ["copy", "installed_signature"])
def test_failed_dev_handoff_preserves_old_install_without_requesting_login(
    tmp_path: Path, failure: str,
) -> None:
    calls = tmp_path / "signature-calls"
    signature = f"""
count=0
[ ! -f '{calls}' ] || count="$(cat '{calls}')"
count=$((count + 1))
printf '%s' "$count" > '{calls}'
[ "$count" -eq 1 ]
"""
    env, app, source, plist, requests = _dev_handoff(
        tmp_path, ditto_body="exit 73" if failure == "copy" else '/bin/cp -R "$1" "$2"',
        codesign_body=signature if failure == "installed_signature" else "exit 0",
    )
    original = plist.read_bytes()
    result = _install(env, source)
    assert result.returncode != 0
    assert "restoring the previous JR-Bar app and launch agents" in result.stderr
    assert (app / "marker").read_text() == "old"
    assert plist.read_bytes() == original
    assert not requests.exists()
