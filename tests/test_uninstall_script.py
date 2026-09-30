"""The uninstaller finds the app and the `jrbar` link where installs put them.

Installs go to ~/Applications and ~/.local/bin/jrbar, but the script used
to look only at /Applications and /usr/local/bin, so it missed both. The
dry run prints every step without sudo, which is what these tests read.
"""

from __future__ import annotations

import os
import subprocess
from dataclasses import dataclass
from pathlib import Path

import pytest

ROOT = Path(__file__).resolve().parents[1]
SCRIPT = ROOT / "scripts" / "uninstall-macos.sh"


def _fake_app(parent: Path, marker: Path | None = None) -> Path:
    app = parent / "JR-Bar.app"
    core = app / "Contents" / "Helpers" / "jrbar-core.app" / "Contents" / "MacOS" / "jrbar-core"
    core.parent.mkdir(parents=True)
    action = f"printf executed > '{marker}'" if marker is not None else "exit 0"
    core.write_text(f"#!/bin/sh\n{action}\n", encoding="utf-8")
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


def test_claude_codes_status_line_is_put_back_before_the_app_goes(tmp_path: Path) -> None:
    """The status line points at a shim inside the bundle; deleting the app
    first would leave Claude Code running a missing program."""
    home = tmp_path / "home"
    app = _fake_app(home / "Applications")

    result = _dry_run(home)

    assert result.returncode == 0, result.stderr
    out = result.stdout
    statusline = out.index("agent-monitor uninstall claude-statusline")
    assert statusline < out.index("agent-monitor uninstall all") < out.index(f"/bin/rm -rf {app}")


def test_dry_run_never_executes_the_user_writable_helper(tmp_path: Path) -> None:
    home = tmp_path / "home"
    marker = tmp_path / "helper-executed"
    _fake_app(home / "Applications", marker)

    result = _dry_run(home)

    assert result.returncode == 0, result.stderr
    assert not marker.exists()
    assert "launchctl asuser" in result.stdout
    assert "status-bar uninstall-sleep-helper" not in result.stdout
    assert "sdejectguard uninstall --scope system" not in result.stdout


def test_even_dry_run_rejects_an_app_path_outside_supported_locations(tmp_path: Path) -> None:
    home = tmp_path / "home"
    home.mkdir()
    unsafe = _fake_app(tmp_path / "other")

    result = _dry_run(home, env_extra={"JRBAR_APP_PATH": str(unsafe)})

    assert result.returncode == 2
    assert "Refusing unsafe JR-Bar application path" in result.stderr
    assert unsafe.is_dir()


@dataclass
class _RealFlow:
    result: subprocess.CompletedProcess
    helper_log: Path
    command_log: Path
    app: Path
    home: Path
    fixed_paths: dict[str, Path]
    fixed_directories: dict[str, Path]


def _real_flow(tmp_path: Path, *, fail_on: tuple[str, ...] = ()) -> _RealFlow:
    """Run the script for real against stand-in tools, all inside tmp_path.

    ``fail_on`` lists helper command lines (as the fake core sees "$*") for
    which the fake core exits 1.
    """
    home = tmp_path / "fixture-home"
    helper_log = tmp_path / "helper.log"
    app = _fake_app(home / "Applications")
    core = app / "Contents" / "Helpers" / "jrbar-core.app" / "Contents" / "MacOS" / "jrbar-core"
    arms = "|".join(f'"{line}"' for line in fail_on)
    failure = (
        f'case "$*" in {arms}) echo "fake core: refusing a config" >&2; exit 1 ;; esac\n'
        if fail_on
        else ""
    )
    core.write_text(
        f"#!/bin/sh\nprintf '%s:%s\\n' \"${{FAKE_EFFECTIVE_USER:-unset}}\" \"$*\" >> '{helper_log}'\n{failure}",
        encoding="utf-8",
    )
    core.chmod(0o755)

    system_root = tmp_path / "system"
    fixed_paths = {
        "/etc/sudoers.d/jrbar-disablesleep": system_root / "etc/sudoers.d/jrbar-disablesleep",
        "/etc/sudoers.d/sidepulse-disablesleep": system_root / "etc/sudoers.d/sidepulse-disablesleep",
        "/Library/LaunchDaemons/com.jonathanreed.jrbar.sdejectguard.plist": system_root
        / "Library/LaunchDaemons/com.jonathanreed.jrbar.sdejectguard.plist",
        "/Library/LaunchDaemons/io.sidepulse.sdejectguard.plist": system_root
        / "Library/LaunchDaemons/io.sidepulse.sdejectguard.plist",
        "/Library/Application Support/JR-Bar/sd-eject-guard/SidePulse Pro Eject Prevention": system_root
        / "Library/Application Support/JR-Bar/sd-eject-guard/SidePulse Pro Eject Prevention",
        "/Library/Application Support/JR-Bar/sd-eject-guard/sd_eject_guard": system_root
        / "Library/Application Support/JR-Bar/sd-eject-guard/sd_eject_guard",
        "/Library/Application Support/SidePulse/sd-eject-guard/SidePulse Pro Eject Prevention": system_root
        / "Library/Application Support/SidePulse/sd-eject-guard/SidePulse Pro Eject Prevention",
        "/Library/Application Support/SidePulse/sd-eject-guard/sd_eject_guard": system_root
        / "Library/Application Support/SidePulse/sd-eject-guard/sd_eject_guard",
        "/var/db/jrbar": system_root / "var/db/jrbar",
        "/var/db/sidepulse": system_root / "var/db/sidepulse",
    }
    fixed_directories = {
        "/Library/Application Support/JR-Bar/sd-eject-guard": system_root
        / "Library/Application Support/JR-Bar/sd-eject-guard",
        "/Library/Application Support/SidePulse/sd-eject-guard": system_root
        / "Library/Application Support/SidePulse/sd-eject-guard",
    }
    for path in fixed_paths.values():
        path.parent.mkdir(parents=True, exist_ok=True)
        if path.suffix or path.name in {"jrbar-disablesleep", "sidepulse-disablesleep"}:
            path.write_text("owned", encoding="utf-8")
        else:
            path.mkdir(exist_ok=True)

    bin_dir = tmp_path / "bin"
    command_log = tmp_path / "commands.log"

    def tool(name: str, body: str) -> Path:
        path = bin_dir / name
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_text(f"#!/bin/sh\n{body}\n", encoding="utf-8")
        path.chmod(0o755)
        return path

    fake_id = tool(
        "id",
        'if [ "$1" = -u ] && [ "$#" -eq 1 ]; then echo 0; else echo 501; fi',
    )
    fake_dscl = tool("dscl", f"printf '%s\\n' 'NFSHomeDirectory: {home}'")
    fake_rm = tool("rm", f"printf 'rm %s\\n' \"$*\" >> '{command_log}'")
    fake_rmdir = tool("rmdir", f"printf 'rmdir %s\\n' \"$*\" >> '{command_log}'")
    fake_pkgutil = tool("pkgutil", "exit 1")
    fake_sudo = tool(
        "sudo",
        """
selected_user=missing
while [ "$#" -gt 0 ]; do
    case "$1" in
        -H) shift ;;
        -u) selected_user="$2"; shift 2 ;;
        *) break ;;
    esac
done
FAKE_EFFECTIVE_USER="$selected_user" exec "$@"
""",
    )
    fake_launchctl = tool(
        "launchctl",
        f"""
if [ "$1" = asuser ]; then
    shift 2
    exec "$@"
fi
printf 'launchctl %s\\n' "$*" >> '{command_log}'
exit 0
""",
    )

    copied = tmp_path / "uninstall-macos.sh"
    text = SCRIPT.read_text(encoding="utf-8")
    replacements = {
        "/usr/bin/id": str(fake_id),
        "/usr/bin/dscl": str(fake_dscl),
        "/bin/launchctl": str(fake_launchctl),
        "/usr/bin/sudo": str(fake_sudo),
        "/bin/rm": str(fake_rm),
        "/bin/rmdir": str(fake_rmdir),
        "/usr/sbin/pkgutil": str(fake_pkgutil),
    }
    tool_placeholders: dict[str, str] = {}
    for index, source in enumerate(sorted(replacements, key=len, reverse=True)):
        placeholder = f"__JRBAR_TEST_TOOL_{index}__"
        text = text.replace(source, placeholder)
        tool_placeholders[placeholder] = replacements[source]
    for placeholder, target in tool_placeholders.items():
        text = text.replace(placeholder, target)
    path_replacements = {**fixed_paths, **fixed_directories}
    placeholders: dict[str, str] = {}
    for index, source in enumerate(sorted(path_replacements, key=len, reverse=True)):
        placeholder = f"__JRBAR_TEST_PATH_{index}__"
        text = text.replace(source, placeholder)
        placeholders[placeholder] = str(path_replacements[source])
    for placeholder, target in placeholders.items():
        text = text.replace(placeholder, target)
    copied.write_text(text, encoding="utf-8")
    copied.chmod(0o755)

    env = {
        "PATH": "/usr/bin:/bin:/usr/sbin:/sbin",
        "HOME": str(tmp_path / "unused-root-home"),
        "JRBAR_USER": "fixture",
        "FAKE_EFFECTIVE_USER": "root",
    }
    result = subprocess.run(
        ["/bin/bash", str(copied)],
        env=env,
        capture_output=True,
        text=True,
        timeout=30,
        check=False,
    )

    return _RealFlow(
        result=result,
        helper_log=helper_log,
        command_log=command_log,
        app=app,
        home=home,
        fixed_paths=fixed_paths,
        fixed_directories=fixed_directories,
    )


def test_real_flow_never_runs_the_user_writable_helper_for_root_cleanup(tmp_path: Path) -> None:
    flow = _real_flow(tmp_path)
    result = flow.result
    helper_log = flow.helper_log
    command_log = flow.command_log
    fixed_paths = flow.fixed_paths
    fixed_directories = flow.fixed_directories

    assert result.returncode == 0, result.stderr
    helper_calls = helper_log.read_text(encoding="utf-8").splitlines()
    assert helper_calls == [
        "fixture:agent-monitor uninstall claude-statusline",
        "fixture:agent-monitor uninstall all",
        "fixture:sdejectguard uninstall --scope user",
    ]
    assert all(not call.startswith("root:") for call in helper_calls)
    commands = command_log.read_text(encoding="utf-8")
    for target in fixed_paths.values():
        assert str(target) in commands
    for target in fixed_directories.values():
        assert f"rmdir {target}" in commands
    assert "status-bar uninstall-sleep-helper" not in commands
    assert "sdejectguard uninstall --scope system" not in commands


def _command_log_text(flow: _RealFlow) -> str:
    return flow.command_log.read_text(encoding="utf-8") if flow.command_log.exists() else ""


def _assert_the_app_was_kept(flow: _RealFlow, *, step: str) -> None:
    result = flow.result
    assert result.returncode == 1, result.stderr
    assert step in result.stderr
    assert "JR-Bar.app was kept" in result.stderr
    commands = _command_log_text(flow)
    assert f"rm -rf {flow.app}" not in commands
    assert ".local/state/jrbar" not in commands
    assert "Library/Application Support/JR-Bar" not in commands
    # Nothing past the hook steps ran: no system cleanup, no link removal.
    for target in flow.fixed_paths.values():
        assert str(target) not in commands
    for target in flow.fixed_directories.values():
        assert f"rmdir {target}" not in commands
    assert flow.app.is_dir()
    assert "JR-Bar integrations removed" not in result.stdout


def test_failed_hook_uninstall_keeps_the_app_and_exits_nonzero(tmp_path: Path) -> None:
    """A config JR-Bar could not clean still points into the app. Deleting
    the app would leave that hook running a program that is gone."""
    flow = _real_flow(tmp_path, fail_on=("agent-monitor uninstall all",))

    _assert_the_app_was_kept(flow, step="agent-monitor uninstall all")
    # The other hook steps still ran, so everything removable is removed.
    assert flow.helper_log.read_text(encoding="utf-8").splitlines() == [
        "fixture:agent-monitor uninstall claude-statusline",
        "fixture:agent-monitor uninstall all",
        "fixture:sdejectguard uninstall --scope user",
    ]
    assert "run this script again" in flow.result.stderr


def test_failed_statusline_restore_keeps_the_app(tmp_path: Path) -> None:
    """A symlinked ~/.claude/settings.json makes the status-line restore
    fail first. The hooks step still runs, and the app stays."""
    flow = _real_flow(tmp_path, fail_on=("agent-monitor uninstall claude-statusline",))

    _assert_the_app_was_kept(flow, step="agent-monitor uninstall claude-statusline")
    assert flow.helper_log.read_text(encoding="utf-8").splitlines() == [
        "fixture:agent-monitor uninstall claude-statusline",
        "fixture:agent-monitor uninstall all",
        "fixture:sdejectguard uninstall --scope user",
    ]


def test_a_failed_user_guard_removal_keeps_the_app(tmp_path: Path) -> None:
    flow = _real_flow(tmp_path, fail_on=("sdejectguard uninstall --scope user",))

    _assert_the_app_was_kept(flow, step="sdejectguard uninstall --scope user")


def test_every_failed_hook_step_is_named(tmp_path: Path) -> None:
    flow = _real_flow(
        tmp_path,
        fail_on=("agent-monitor uninstall claude-statusline", "agent-monitor uninstall all"),
    )

    _assert_the_app_was_kept(flow, step="agent-monitor uninstall claude-statusline")
    assert "agent-monitor uninstall all" in flow.result.stderr
    assert "sdejectguard" not in flow.result.stderr


def test_a_dry_run_reads_the_same_when_hook_steps_would_fail(tmp_path: Path) -> None:
    """The guard changes nothing in a dry run: every step is still printed
    and the exit is 0, because a dry run runs no helper."""
    home = tmp_path / "home"
    _fake_app(home / "Applications")

    result = _dry_run(home)

    assert result.returncode == 0, result.stderr
    assert "was kept" not in result.stderr
    assert "Dry run: nothing was removed" in result.stdout
