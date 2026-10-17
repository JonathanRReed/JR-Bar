"""The eject guard carries JR-Bar's own name, and an upgrade replaces the old one."""

from __future__ import annotations

import plistlib
import subprocess
from pathlib import Path
from unittest.mock import patch

from jrbar.sd_eject_guard_launch import (
    LEGACY_SD_EJECT_GUARD_DISPLAY_NAME,
    LEGACY_SD_EJECT_GUARD_FILENAME,
    SD_EJECT_GUARD_BINARY_NAME,
    SD_EJECT_GUARD_DISPLAY_NAME,
    SD_EJECT_GUARD_FILENAME,
    SdEjectGuardPaths,
    install_sd_eject_guard,
    user_sd_eject_guard_paths,
)

VOLUME_UUID = "12345678-1234-4ABC-9DEF-1234567890AB"


def _paths(base: Path) -> SdEjectGuardPaths:
    return SdEjectGuardPaths(
        scope="user",
        plist_path=base / "LaunchAgents" / SD_EJECT_GUARD_FILENAME,
        binary_path=base / "data" / "sd-eject-guard" / SD_EJECT_GUARD_BINARY_NAME,
        stdout_path=base / "state" / "sd-eject-guard.out.log",
        stderr_path=base / "state" / "sd-eject-guard.err.log",
    )


def _fake_launchctl(calls: list[list[str]]):
    def fake_run(command, *args, **kwargs):
        calls.append([str(part) for part in command])
        if Path(command[0]).name == "clang":
            Path(command[3]).write_bytes(b"binary")
        return subprocess.CompletedProcess(command, 0)

    return fake_run


def _install(paths: SdEjectGuardPaths, source: Path, calls: list[list[str]], **kwargs):
    with (
        patch("jrbar.sd_eject_guard_launch.os.geteuid", return_value=501),
        patch("jrbar.sd_eject_guard_launch.os.getuid", return_value=501),
        patch("jrbar.sd_eject_guard_launch.subprocess.run", side_effect=_fake_launchctl(calls)),
    ):
        return install_sd_eject_guard(
            scope="user", source_path=source, user_paths=paths, system_paths=paths, **kwargs
        )


def test_the_guard_is_named_for_jr_bar_and_the_name_is_the_process_name() -> None:
    assert SD_EJECT_GUARD_DISPLAY_NAME == "JR-Bar SD Eject Guard"
    assert SD_EJECT_GUARD_BINARY_NAME == SD_EJECT_GUARD_DISPLAY_NAME
    assert "sidepulse" not in SD_EJECT_GUARD_FILENAME.lower()
    paths = user_sd_eject_guard_paths(Path("/nonexistent-home"))
    assert paths.binary_path.name == "JR-Bar SD Eject Guard"
    assert "sidepulse" not in paths.plist_path.name.lower()
    assert "sidepulse" not in paths.stdout_path.name.lower()


def test_the_c_source_and_cli_no_longer_show_the_old_name() -> None:
    root = Path(__file__).resolve().parents[1] / "src" / "jrbar"
    for relative in ("resources/sd_eject_guard.c", "cli.py", "sd_eject_guard_launch.py"):
        text = (root / relative).read_text(encoding="utf-8")
        found = text.count(LEGACY_SD_EJECT_GUARD_DISPLAY_NAME)
        # Only the one named legacy constant may carry the old words.
        assert found == (1 if relative == "sd_eject_guard_launch.py" else 0), relative


def test_an_upgrade_replaces_the_old_binary_and_the_old_plist(tmp_path: Path) -> None:
    paths = _paths(tmp_path)
    source = tmp_path / "sd_eject_guard.c"
    source.write_text("int main(void) { return 0; }\n", encoding="utf-8")
    old_binary = paths.binary_path.with_name(LEGACY_SD_EJECT_GUARD_DISPLAY_NAME)
    old_binary.parent.mkdir(parents=True)
    old_binary.write_bytes(b"old build")
    old_label_plist = paths.plist_path.with_name(LEGACY_SD_EJECT_GUARD_FILENAME)
    old_label_plist.parent.mkdir(parents=True)
    old_label_plist.write_bytes(plistlib.dumps({"Label": "io.sidepulse.sdejectguard"}))
    paths.plist_path.write_bytes(
        plistlib.dumps(
            {
                "Label": "com.jonathanreed.jrbar.sdejectguard",
                "ProgramArguments": [str(old_binary), "--volume-uuid", VOLUME_UUID],
            }
        )
    )

    calls: list[list[str]] = []
    result = _install(paths, source, calls, volume_uuid=VOLUME_UUID)

    assert not old_binary.exists()
    assert not old_label_plist.exists()
    assert paths.binary_path.exists()
    assert old_binary in result.legacy_removed
    assert old_label_plist in result.legacy_removed
    written = plistlib.loads(paths.plist_path.read_bytes())
    assert written["ProgramArguments"] == [str(paths.binary_path), "--volume-uuid", VOLUME_UUID]
    assert "SidePulse" not in paths.plist_path.read_text(errors="replace")
    # The old job is unloaded before the new one is bootstrapped.
    bootouts = [call for call in calls if call[1:2] == ["bootout"]]
    bootstraps = [call for call in calls if call[1:2] == ["bootstrap"]]
    assert bootstraps == [["/bin/launchctl", "bootstrap", "gui/501", str(paths.plist_path)]]
    assert any(str(old_label_plist) in call for call in bootouts)
    assert calls.index(bootouts[0]) < calls.index(bootstraps[0])


def test_the_migration_is_idempotent(tmp_path: Path) -> None:
    paths = _paths(tmp_path)
    source = tmp_path / "sd_eject_guard.c"
    source.write_text("int main(void) { return 0; }\n", encoding="utf-8")
    old_binary = paths.binary_path.with_name(LEGACY_SD_EJECT_GUARD_DISPLAY_NAME)
    old_binary.parent.mkdir(parents=True)
    old_binary.write_bytes(b"old build")

    first = _install(paths, source, [], volume_uuid=VOLUME_UUID)
    second = _install(paths, source, [], volume_uuid=VOLUME_UUID)

    assert first.changed and old_binary in first.legacy_removed
    assert second.legacy_removed == ()
    assert second.compiled is False
    assert paths.binary_path.exists()


def test_without_starting_a_loaded_job_is_unloaded_before_its_binary_goes(tmp_path: Path) -> None:
    paths = _paths(tmp_path)
    source = tmp_path / "sd_eject_guard.c"
    source.write_text("int main(void) { return 0; }\n", encoding="utf-8")
    old_binary = paths.binary_path.with_name(LEGACY_SD_EJECT_GUARD_DISPLAY_NAME)
    old_binary.parent.mkdir(parents=True)
    old_binary.write_bytes(b"old build")

    calls: list[list[str]] = []
    _install(paths, source, calls, volume_uuid=VOLUME_UUID, start=False)

    assert not old_binary.exists()
    assert [call for call in calls if call[1:2] == ["bootstrap"]] == []
    assert any(call[1:3] == ["bootout", "gui/501"] and str(paths.plist_path) in call for call in calls)
