from __future__ import annotations

import json
import os
import socket
from pathlib import Path

import pytest

from jrbar import migration
from jrbar.migration import (
    MIGRATION_MARKER_NAME,
    MigrationArea,
    migrate_from_sidepulse,
    migration_areas,
)


def _legacy_tree(root: Path) -> dict[str, Path]:
    config_root = root / ".config" / "sidepulse"
    config_old = config_root / "agent-monitor"
    state_root = root / ".local" / "state" / "sidepulse"
    state_old = state_root / "agent-monitor"
    data_old = root / ".local" / "share" / "sidepulse"
    support_old = root / "Library" / "Application Support" / "SidePulse"
    for directory in (config_old, state_old / "processes", data_old / "sd-eject-guard", data_old / "app-backup-1", support_old):
        directory.mkdir(parents=True)
    (config_old / "settings.json").write_text('{"schema": 1}')
    (config_old / "settings.json.backup-1").write_text("backup")
    (config_root / "integrations.json").write_text("{}")
    (config_root / "provider-usage.json").write_text("{}")
    (config_root / "deck-controls.json").write_text("{}")
    (state_old / "claude.jsonl").write_text('{"event": "session_start"}\n')
    (state_old / "latest.json").write_text("{}")
    (state_old / "processes" / "1234.json").write_text("{}")
    (state_old / "processes" / "1234.pid").write_text("1234")
    (state_old / "status-bar.pid").write_text("99")
    (state_root / "provider-usage.json").write_text("{}")
    (state_root / "provider-usage-cache.json").write_text("{}")
    (data_old / "sd-eject-guard" / "guard").write_bytes(b"bin")
    (data_old / "app-backup-1" / "SidePulse.app").mkdir()
    (support_old / "capacity-history.json").write_text("[]")
    return {
        "config_old": config_old,
        "config_root": config_root,
        "state_old": state_old,
        "state_root": state_root,
        "data_old": data_old,
        "support_old": support_old,
    }


def _bind_socket(directory: Path, name: str, monkeypatch: pytest.MonkeyPatch) -> socket.socket:
    # AF_UNIX paths are capped at ~104 bytes; bind relative to the directory
    # so the deep pytest tmp_path never exceeds it.
    monkeypatch.chdir(directory)
    server = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
    server.bind(name)
    return server


def _areas(root: Path) -> tuple[MigrationArea, ...]:
    return migration_areas(root)


def test_copies_every_area_flattened_and_records_a_marker(tmp_path: Path, monkeypatch: pytest.MonkeyPatch) -> None:
    trees = _legacy_tree(tmp_path)
    sock = _bind_socket(trees["state_old"], "events.sock", monkeypatch)
    try:
        report = migrate_from_sidepulse(tmp_path, areas=_areas(tmp_path))
    finally:
        sock.close()

    assert report.performed
    config_new = tmp_path / ".config" / "jrbar"
    state_new = tmp_path / ".local" / "state" / "jrbar"
    data_new = tmp_path / ".local" / "share" / "jrbar"
    support_new = tmp_path / "Library" / "Application Support" / "JR-Bar"
    assert (config_new / "settings.json").read_text() == '{"schema": 1}'
    assert (config_new / "settings.json.backup-1").is_file()
    assert (config_new / "integrations.json").is_file()
    assert (config_new / "provider-usage.json").is_file()
    assert (config_new / "deck-controls.json").is_file()
    assert not (config_new / "agent-monitor").exists()
    assert (state_new / "claude.jsonl").read_text().startswith('{"event"')
    assert (state_new / "latest.json").is_file()
    assert (state_new / "processes" / "1234.json").is_file()
    assert not (state_new / "processes" / "1234.pid").exists()
    assert not (state_new / "status-bar.pid").exists()
    assert not (state_new / "events.sock").exists()
    assert (state_new / "provider-usage.json").is_file()
    assert (state_new / "provider-usage-cache.json").is_file()
    assert not (state_new / "agent-monitor").exists()
    assert (data_new / "sd-eject-guard" / "guard").read_bytes() == b"bin"
    assert not (data_new / "app-backup-1").exists()
    assert (support_new / "capacity-history.json").is_file()

    marker = state_new / MIGRATION_MARKER_NAME
    assert report.marker_path == marker
    document = json.loads(marker.read_text())
    assert document["schema"] == "jrbar.migration"
    assert "settings.json" in document["areas"]["config"]["copied"]
    assert "status-bar.pid" in document["areas"]["state"]["skipped"]
    assert "app-backup-1" in document["areas"]["data"]["skipped"]
    assert oct(marker.stat().st_mode & 0o777) == "0o600"

    # The SidePulse trees are copied, never moved.
    assert (trees["config_old"] / "settings.json").is_file()
    assert (trees["state_old"] / "claude.jsonl").is_file()


def test_second_run_is_a_no_op(tmp_path: Path) -> None:
    _legacy_tree(tmp_path)
    first = migrate_from_sidepulse(tmp_path, areas=_areas(tmp_path))
    state_new = tmp_path / ".local" / "state" / "jrbar"
    (state_new / "claude.jsonl").write_text("changed after migration\n")

    second = migrate_from_sidepulse(tmp_path, areas=_areas(tmp_path))

    assert first.performed
    assert second.already_migrated
    assert not second.performed
    assert second.summary_lines() == []
    assert (state_new / "claude.jsonl").read_text() == "changed after migration\n"


def test_config_is_left_alone_when_jr_bar_settings_already_exist(tmp_path: Path) -> None:
    _legacy_tree(tmp_path)
    config_new = tmp_path / ".config" / "jrbar"
    config_new.mkdir(parents=True)
    (config_new / "settings.json").write_text('{"mine": true}')

    report = migrate_from_sidepulse(tmp_path, areas=_areas(tmp_path))

    config_area = next(area for area in report.areas if area.name == "config")
    assert config_area.reason == "settings.json already present"
    assert config_area.copied == ()
    assert (config_new / "settings.json").read_text() == '{"mine": true}'
    assert not (config_new / "integrations.json").exists()
    # Other areas still migrate.
    assert (tmp_path / ".local" / "state" / "jrbar" / "claude.jsonl").is_file()


def test_existing_jr_bar_files_are_never_overwritten(tmp_path: Path) -> None:
    _legacy_tree(tmp_path)
    state_new = tmp_path / ".local" / "state" / "jrbar"
    state_new.mkdir(parents=True)
    (state_new / "claude.jsonl").write_text("keep me\n")

    report = migrate_from_sidepulse(tmp_path, areas=_areas(tmp_path))

    state_area = next(area for area in report.areas if area.name == "state")
    assert "claude.jsonl" in state_area.skipped
    assert (state_new / "claude.jsonl").read_text() == "keep me\n"
    assert (state_new / "latest.json").is_file()


def test_fresh_machine_does_nothing_and_writes_no_marker(tmp_path: Path) -> None:
    report = migrate_from_sidepulse(tmp_path, areas=_areas(tmp_path))

    assert not report.performed
    assert not report.already_migrated
    assert report.summary_lines() == []
    assert not report.marker_path.exists()
    assert not (tmp_path / ".config" / "jrbar").exists()
    assert not (tmp_path / ".local" / "state" / "jrbar").exists()


def test_dry_run_reports_without_copying(tmp_path: Path) -> None:
    _legacy_tree(tmp_path)

    report = migrate_from_sidepulse(tmp_path, dry_run=True, areas=_areas(tmp_path))

    assert report.performed
    assert report.dry_run
    assert report.summary_lines()[0].startswith("migration: would copy")
    assert not (tmp_path / ".config" / "jrbar").exists()
    assert not (tmp_path / ".local" / "state" / "jrbar").exists()
    assert not report.marker_path.exists()


def test_symlinked_legacy_entries_are_skipped(tmp_path: Path) -> None:
    trees = _legacy_tree(tmp_path)
    outside = tmp_path / "outside.json"
    outside.write_text("secret")
    (trees["state_old"] / "linked.json").symlink_to(outside)

    migrate_from_sidepulse(tmp_path, areas=_areas(tmp_path))

    assert not (tmp_path / ".local" / "state" / "jrbar" / "linked.json").exists()


def test_area_failure_is_recorded_and_other_areas_continue(tmp_path: Path, monkeypatch: pytest.MonkeyPatch) -> None:
    _legacy_tree(tmp_path)
    original = migration._copy_entry

    def failing_copy(entry: Path, target: Path) -> None:
        if entry.name == "capacity-history.json":
            raise PermissionError("no")
        original(entry, target)

    monkeypatch.setattr(migration, "_copy_entry", failing_copy)

    report = migrate_from_sidepulse(tmp_path, areas=_areas(tmp_path))

    assert report.errors == ("app-support: PermissionError",)
    assert (tmp_path / ".local" / "state" / "jrbar" / "claude.jsonl").is_file()
    # No marker while an area failed, so the next run retries it.
    assert not report.marker_path.exists()


def test_default_areas_honour_xdg_and_home(tmp_path: Path, monkeypatch: pytest.MonkeyPatch) -> None:
    monkeypatch.setenv("XDG_CONFIG_HOME", str(tmp_path / "xc"))
    monkeypatch.setenv("XDG_STATE_HOME", str(tmp_path / "xs"))
    monkeypatch.setenv("XDG_DATA_HOME", str(tmp_path / "xd"))

    by_env = {area.name: area for area in migration_areas()}
    assert by_env["config"].destination == tmp_path / "xc" / "jrbar"
    assert by_env["config"].sources == (tmp_path / "xc" / "sidepulse" / "agent-monitor", tmp_path / "xc" / "sidepulse")
    assert by_env["state"].destination == tmp_path / "xs" / "jrbar"
    assert by_env["state"].sources == (tmp_path / "xs" / "sidepulse" / "agent-monitor", tmp_path / "xs" / "sidepulse")
    assert by_env["data"].destination == tmp_path / "xd" / "jrbar"

    by_home = {area.name: area for area in migration_areas(tmp_path / "home")}
    assert by_home["config"].destination == tmp_path / "home" / ".config" / "jrbar"
    assert by_home["state"].destination == tmp_path / "home" / ".local" / "state" / "jrbar"
    assert by_home["app-support"].destination == tmp_path / "home" / "Library" / "Application Support" / "JR-Bar"
    assert os.environ["XDG_STATE_HOME"] == str(tmp_path / "xs")


def test_status_bar_entry_migrates_before_the_host_main(monkeypatch: pytest.MonkeyPatch) -> None:
    from jrbar import provider_usage_status_bar

    order: list[str] = []

    def fake_migrate(*args: object, **kwargs: object) -> migration.MigrationReport:
        order.append("migrate")
        return migration.MigrationReport(Path("/dev/null"), already_migrated=True)

    monkeypatch.setattr(migration, "migrate_from_sidepulse", fake_migrate)
    monkeypatch.setattr(provider_usage_status_bar._host, "main", lambda: order.append("host") or 0, raising=False)

    assert provider_usage_status_bar.main() == 0
    assert order == ["migrate", "host"]


def test_status_bar_entry_survives_a_migration_failure(monkeypatch: pytest.MonkeyPatch) -> None:
    from jrbar import provider_usage_status_bar

    def broken(*args: object, **kwargs: object) -> migration.MigrationReport:
        raise RuntimeError("disk on fire")

    monkeypatch.setattr(migration, "migrate_from_sidepulse", broken)
    monkeypatch.setattr(provider_usage_status_bar._host, "main", lambda: 7, raising=False)

    assert provider_usage_status_bar.main() == 7


def test_cli_setup_runs_the_migration_first(monkeypatch: pytest.MonkeyPatch, capsys: pytest.CaptureFixture[str]) -> None:
    import argparse

    from jrbar import cli

    calls: list[dict[str, object]] = []

    def fake_migrate(*args: object, **kwargs: object) -> migration.MigrationReport:
        calls.append(dict(kwargs))
        return migration.MigrationReport(
            Path("/dev/null"),
            (migration.AreaResult("config", Path("/new/config"), ("settings.json",)),),
            dry_run=True,
        )

    monkeypatch.setattr(migration, "migrate_from_sidepulse", fake_migrate)
    monkeypatch.setattr(cli, "install_hook_results", lambda args: [])
    monkeypatch.setattr(cli, "print_install_results", lambda results, dry_run: None)
    args = argparse.Namespace(
        dry_run=True,
        no_status_bar=True,
        no_sd_eject_guard=True,
        sd_eject_guard=False,
        sd_eject_guard_scope="auto",
        sd_eject_guard_volume_uuid=None,
    )

    assert cli.cmd_jrbar_setup(args) == 0
    assert calls == [{"dry_run": True}]
    out = capsys.readouterr().out
    assert "migration: would copy 1 SidePulse entries" in out
    assert "config: 1 -> /new/config" in out
