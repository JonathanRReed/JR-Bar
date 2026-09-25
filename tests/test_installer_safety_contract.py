from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]


def test_package_installs_payload_without_mutating_external_integrations__and_2_more() -> None:
    # --- scenario: package_installs_payload_without_mutating_external_integrations
    text = (ROOT / "packaging" / "scripts" / "postinstall").read_text()

    # The package owns its payload only: the app installs hooks and the
    # login item itself on launch, so the postinstall touches nothing else.
    assert "setup --sd-eject-guard-scope user" not in text
    assert "status-bar install-sleep-helper" not in text
    assert "agent-monitor" not in text
    assert "sdejectguard" not in text
    assert "launchctl" not in text
    assert "Library/LaunchAgents" not in text
    assert "/var/db" not in text
    assert "no LaunchAgents, no /usr/local links, no hooks, no receipts" in text

    # --- scenario: package_never_touches_an_unowned_cli_path
    text = (ROOT / "packaging" / "scripts" / "postinstall").read_text()

    # No /usr/local link at all any more; the bundled binary is called by path.
    assert "CLI_LINK" not in text
    assert "ln -s" not in text
    assert 'INSTALL_LOCATION="${2:-/Applications}"' in text
    for helper in (
        "JR-Bar.app/Contents/MacOS/JR-Bar",
        "JR-Bar.app/Contents/Helpers/jrbar-core.app/Contents/MacOS/jrbar-core",
        "JR-Bar.app/Contents/Helpers/jrbar-hook",
    ):
        assert helper in text

    # --- scenario: supported_uninstaller_removes_only_owned_integrations
    text = (ROOT / "scripts" / "uninstall-macos.sh").read_text()

    for command in (
        "agent-monitor uninstall all",
        "sdejectguard uninstall --scope user",
        "status-bar uninstall-sleep-helper",
        "sdejectguard uninstall --scope system",
    ):
        assert f'"$CORE_BINARY" {command}' in text
    # Contents/MacOS/JR-Bar is the Swift app and takes no arguments; every
    # command runs on the bundled daemon.
    assert 'CORE_BINARY="$APP_PATH/Contents/Helpers/jrbar-core.app/Contents/MacOS/jrbar-core"' in text
    assert '"$APP_BINARY" status-bar' not in text
    assert '"$APP_BINARY" agent-monitor' not in text
    # The retired menu bar's LaunchAgent is booted out and unlinked directly.
    assert "status-bar stop" not in text
    assert "com.jonathanreed.jrbar.app io.sidepulse.agentstatus com.sidepulse.agentstatus" in text
    assert '/bin/launchctl bootout "gui/$TARGET_UID" "$plist"' in text
    # The user's ~/.local/bin link, the older /usr/local/bin one and the
    # pre-rename name are each removed only when they point into a JR-Bar
    # bundle (tests/test_uninstall_script.py runs it).
    assert '"$TARGET_HOME/.local/bin/jrbar /usr/local/bin/jrbar"' in text
    assert 'for link in $CLI_LINKS /usr/local/bin/sidepulse' in text
    assert 'points_into_jrbar "$link"' in text
    assert '*/JR-Bar.app/Contents/*|*/JR-Bar-dev.app/Contents/*' in text
    assert "--purge-state" in text
    assert "--keep-app" in text
    assert 'PACKAGE_ID="com.jonathanreed.jrbar"' in text
    assert 'LEGACY_PACKAGE_ID="io.sidepulse.app"' in text
    assert 'pkgutil --forget "$package_id"' in text

