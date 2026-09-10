from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]


def test_package_installs_payload_without_mutating_external_integrations() -> None:
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


def test_package_never_touches_an_unowned_cli_path() -> None:
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


def test_supported_uninstaller_removes_only_owned_integrations() -> None:
    text = (ROOT / "scripts" / "uninstall-macos.sh").read_text()

    for command in (
        "status-bar stop",
        "agent-monitor uninstall all",
        "sdejectguard uninstall --scope user",
        "status-bar uninstall-sleep-helper",
        "sdejectguard uninstall --scope system",
    ):
        assert command in text
    # Both the current and the pre-rename CLI link are removed only when they
    # point at our executable.
    assert 'for link in "$CLI_LINK" "$LEGACY_CLI_LINK"' in text
    assert 'readlink "$link"' in text
    assert "--purge-state" in text
    assert "--keep-app" in text
    assert 'PACKAGE_ID="com.jonathanreed.jrbar"' in text
    assert 'LEGACY_PACKAGE_ID="io.sidepulse.app"' in text
    assert 'pkgutil --forget "$package_id"' in text
