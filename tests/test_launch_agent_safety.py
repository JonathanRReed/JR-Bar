"""The retired menu-bar LaunchAgent is only ever unloaded and removed.

An older ``jrbar setup`` installed ``com.jonathanreed.jrbar.app`` with
KeepAlive, and launchd respawned a Python UI that refused to run beside the
daemon every ten seconds. Startup and the hidden ``status-bar stop`` clean it
up; nothing installs it any more.
"""

import subprocess
from pathlib import Path

from jrbar import cli, migration, status_bar_launch


def _launch_agents(home: Path) -> Path:
    agents = home / "Library" / "LaunchAgents"
    agents.mkdir(parents=True)
    return agents


def _record_launchctl(monkeypatch) -> list:
    calls = []

    def run(argv, **kwargs):
        calls.append((argv, kwargs))
        return subprocess.CompletedProcess(argv, 0)

    monkeypatch.setattr(status_bar_launch.subprocess, "run", run)
    monkeypatch.setattr(
        status_bar_launch._legacy,
        "trusted_system_tool",
        lambda _name: Path("/bin/launchctl"),
    )
    return calls


def test_retired_plists_are_booted_out_and_unlinked__and_2_more(tmp_path, monkeypatch) -> None:
    # --- scenario: retired_plists_are_booted_out_and_unlinked
    agents = _launch_agents(tmp_path)
    current = agents / "com.jonathanreed.jrbar.app.plist"
    legacy = agents / "com.sidepulse.agentstatus.plist"
    current.write_bytes(b"old ui")
    legacy.write_bytes(b"older ui")
    # The Swift app's own agents from scripts/install-agents.sh are not
    # retired and must survive.
    kept = agents / "com.jonathanreed.jrbar.core.plist"
    kept.write_bytes(b"daemon")
    calls = _record_launchctl(monkeypatch)

    removed = status_bar_launch.remove_retired_launch_agents(tmp_path)

    assert set(removed) == {current, legacy}
    assert not current.exists() and not legacy.exists()
    assert kept.read_bytes() == b"daemon"
    assert [call[0][1] for call in calls] == ["bootout", "bootout"]
    assert {call[0][3] for call in calls} == {str(current), str(legacy)}

    # --- scenario: every_launchctl_call_is_bounded_and_detached_from_stdin
    assert all(
        call[1]["timeout"] == status_bar_launch.LAUNCHCTL_TIMEOUT_SECONDS
        for call in calls
    )
    assert all(call[1]["stdin"] is subprocess.DEVNULL for call in calls)

    # --- scenario: nothing_installed_means_no_launchctl_at_all
    calls.clear()
    assert status_bar_launch.remove_retired_launch_agents(tmp_path) == ()
    assert calls == []


def test_a_hung_launchctl_still_unlinks_the_plist__and_1_more(tmp_path, monkeypatch) -> None:
    # --- scenario: a_hung_launchctl_still_unlinks_the_plist
    agents = _launch_agents(tmp_path)
    plist = agents / "io.sidepulse.agentstatus.plist"
    plist.write_bytes(b"old")

    def hang(argv, **_kwargs):
        raise subprocess.TimeoutExpired(argv, 15)

    monkeypatch.setattr(status_bar_launch.subprocess, "run", hang)

    assert status_bar_launch.remove_retired_launch_agents(tmp_path) == (plist,)
    assert not plist.exists()

    # --- scenario: a_directory_under_a_retired_name_is_not_ours_to_delete
    directory = agents / "com.jonathanreed.jrbar.app.plist"
    directory.mkdir()
    calls = _record_launchctl(monkeypatch)

    assert status_bar_launch.remove_retired_launch_agents(tmp_path) == ()
    assert directory.is_dir()
    assert calls == []


def test_setup_and_stop_never_install_a_launch_agent__and_2_more(tmp_path, monkeypatch, capsys) -> None:
    # --- scenario: setup_has_no_status_bar_step
    parser = cli.build_jrbar_parser()
    assert "--no-status-bar" not in parser._subparsers._group_actions[0].choices["setup"].format_help()
    assert not hasattr(status_bar_launch, "install_launch_agent")
    assert not hasattr(status_bar_launch, "build_launch_agent_plist")

    # --- scenario: the_hidden_stop_only_removes_the_retired_plists
    agents = _launch_agents(tmp_path)
    plist = agents / "com.jonathanreed.jrbar.app.plist"
    plist.write_bytes(b"old ui")
    _record_launchctl(monkeypatch)
    monkeypatch.setenv("HOME", str(tmp_path))

    assert cli.jrbar_main(["status-bar", "stop"]) == 0
    assert not plist.exists()
    assert "removed the retired LaunchAgent" in capsys.readouterr().out
    help_text = parser._subparsers._group_actions[0].choices["status-bar"].format_help()
    assert "stop" not in help_text.split("positional arguments:")[0]
    assert "install-sleep-helper" in help_text

    # --- scenario: startup_migration_unloads_the_retired_agent
    plist.write_bytes(b"old ui again")
    monkeypatch.setattr(migration, "migrate_from_sidepulse", lambda: migration.MigrationReport(tmp_path / "m"))

    migration.run_startup_migration()

    assert not plist.exists()
