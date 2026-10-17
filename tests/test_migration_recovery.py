from __future__ import annotations

import argparse
from pathlib import Path

import pytest

from jrbar import migration
from jrbar.migration import MigrationArea, MigrationReport, migrate_from_sidepulse


def _area(root: Path, name: str = "state") -> MigrationArea:
    source = root / f"old-{name}"
    source.mkdir()
    return MigrationArea(name, (source,), root / f"new-{name}")


@pytest.mark.parametrize("nested", [False, True], ids=["file", "directory"])
def test_failed_copy_leaves_no_partial_file_and_retry_recovers(
    tmp_path: Path, monkeypatch: pytest.MonkeyPatch, nested: bool,
) -> None:
    area = _area(tmp_path)
    source = area.sources[0] / "history" if nested else area.sources[0]
    source.mkdir(exist_ok=True)
    (source / "a-before.txt").write_bytes(b"before")
    (source / "payload.txt").write_bytes(b"complete synthetic payload")
    (source / "z-after.txt").write_bytes(b"after")
    destination = area.destination / "history" if nested else area.destination
    original_copy = migration.shutil.copy2

    def broken_copy(source_path, target_path, **kwargs):
        if Path(source_path).name == "payload.txt":
            Path(target_path).write_bytes(b"partial")
            raise OSError("synthetic copy interruption")
        return original_copy(source_path, target_path, **kwargs)

    with monkeypatch.context() as patch:
        patch.setattr(migration.shutil, "copy2", broken_copy)
        failed = migrate_from_sidepulse(tmp_path, areas=(area,))

    assert failed.errors
    assert not failed.marker_path.exists()
    assert not (destination / "payload.txt").exists()
    assert not list(area.destination.rglob(".jrbar-migrate-*"))
    recovered = migrate_from_sidepulse(tmp_path, areas=(area,))
    assert not recovered.errors
    assert recovered.marker_path.is_file()
    for name in ("a-before.txt", "payload.txt", "z-after.txt"):
        assert (destination / name).read_bytes() == (source / name).read_bytes()
    assert (source / "payload.txt").read_bytes() == b"complete synthetic payload"


def test_unreadable_source_is_reported_and_does_not_seal_other_success(
    tmp_path: Path, monkeypatch: pytest.MonkeyPatch, caplog: pytest.LogCaptureFixture,
) -> None:
    state, support = _area(tmp_path), _area(tmp_path, "app-support")
    (state.sources[0] / "history.json").write_text("synthetic history")
    (support.sources[0] / "ready.json").write_text("synthetic support")
    original_iterdir = Path.iterdir

    def unreadable(path):
        if path == state.sources[0]:
            raise PermissionError("synthetic-private-detail")
        return original_iterdir(path)

    with monkeypatch.context() as patch:
        patch.setattr(Path, "iterdir", unreadable)
        failed = migrate_from_sidepulse(tmp_path, areas=(state, support))

    assert failed.errors == ("state: PermissionError",)
    assert not failed.marker_path.exists()
    assert (support.destination / "ready.json").read_text() == "synthetic support"
    assert "synthetic-private-detail" not in caplog.text
    recovered = migrate_from_sidepulse(tmp_path, areas=(state, support))
    assert not recovered.errors
    assert (state.destination / "history.json").read_text() == "synthetic history"
    assert recovered.marker_path.is_file()


def test_config_retry_is_not_blocked_by_its_own_early_settings_copy(
    tmp_path: Path, monkeypatch: pytest.MonkeyPatch,
) -> None:
    state = _area(tmp_path)
    first, second = tmp_path / "old-specific", tmp_path / "old-root"
    first.mkdir()
    second.mkdir()
    (first / "settings.json").write_text('{"synthetic": true}')
    (second / "later.json").write_text("synthetic later config")
    config = MigrationArea("config", (first, second), tmp_path / "new-config")
    original_copy = migration.shutil.copy2

    def broken_copy(source_path, target_path, **kwargs):
        if Path(source_path).name == "later.json":
            raise OSError("synthetic copy interruption")
        return original_copy(source_path, target_path, **kwargs)

    with monkeypatch.context() as patch:
        patch.setattr(migration.shutil, "copy2", broken_copy)
        failed = migrate_from_sidepulse(tmp_path, areas=(config, state))

    assert failed.errors
    assert not (config.destination / "settings.json").exists()
    recovered = migrate_from_sidepulse(tmp_path, areas=(config, state))
    assert not recovered.errors
    assert (config.destination / "settings.json").read_text() == '{"synthetic": true}'
    assert (config.destination / "later.json").read_text() == "synthetic later config"
    assert (first / "settings.json").read_text() == '{"synthetic": true}'


def test_marker_failure_is_reported_and_retried_without_replacing_current_data(
    tmp_path: Path, monkeypatch: pytest.MonkeyPatch,
) -> None:
    area = _area(tmp_path)
    (area.sources[0] / "history.json").write_text("legacy synthetic history")

    def fail_marker(*_args):
        raise PermissionError("synthetic marker failure")

    with monkeypatch.context() as patch:
        patch.setattr(migration, "_write_marker", fail_marker)
        failed = migrate_from_sidepulse(tmp_path, areas=(area,))

    assert failed.errors == ("marker: PermissionError",)
    assert not failed.marker_path.exists()
    (area.destination / "history.json").write_text("current synthetic history")
    recovered = migrate_from_sidepulse(tmp_path, areas=(area,))
    assert not recovered.errors
    assert not recovered.performed
    assert recovered.marker_path.is_file()
    assert (area.destination / "history.json").read_text() == "current synthetic history"
    assert migrate_from_sidepulse(tmp_path, areas=(area,)).already_migrated


def test_existing_directory_gains_missing_files_without_replacing_current_files(tmp_path: Path) -> None:
    area = _area(tmp_path)
    old, new = area.sources[0] / "history", area.destination / "history"
    old.mkdir()
    new.mkdir(parents=True)
    (old / "shared.json").write_text("legacy shared")
    (old / "missing.json").write_text("legacy missing")
    (new / "shared.json").write_text("current shared")
    (new / "current.json").write_text("current only")
    report = migrate_from_sidepulse(tmp_path, areas=(area,))
    assert not report.errors
    assert (new / "missing.json").read_text() == "legacy missing"
    assert (new / "shared.json").read_text() == "current shared"
    assert (new / "current.json").read_text() == "current only"
    assert (old / "shared.json").read_text() == "legacy shared"


def test_a_target_created_during_copy_is_not_overwritten(tmp_path: Path, monkeypatch: pytest.MonkeyPatch) -> None:
    area = _area(tmp_path)
    (area.sources[0] / "history.json").write_text("legacy history")
    public = area.destination / "history.json"
    original_copy = migration.shutil.copy2

    def create_current_then_copy(source_path, target_path, **kwargs):
        public.write_text("current history")
        return original_copy(source_path, target_path, **kwargs)

    monkeypatch.setattr(migration.shutil, "copy2", create_current_then_copy)
    report = migrate_from_sidepulse(tmp_path, areas=(area,))
    assert not report.errors
    assert public.read_text() == "current history"
    assert (area.sources[0] / "history.json").read_text() == "legacy history"


def test_setup_reports_incomplete_migration_after_continuing_hooks(
    tmp_path: Path, monkeypatch: pytest.MonkeyPatch,
) -> None:
    from jrbar import cli

    calls = []
    monkeypatch.setattr(migration, "migrate_from_sidepulse", lambda **_kwargs: MigrationReport(
        tmp_path / "marker", errors=("state: PermissionError",)))
    monkeypatch.setattr(cli, "install_hook_results", lambda _args, failures: calls.append("hooks") or [])
    monkeypatch.setattr(cli, "print_install_results", lambda *_args, **_kwargs: None)
    monkeypatch.setattr(cli, "install_exit_code", lambda *_args: 0)
    args = argparse.Namespace(dry_run=False, no_sd_eject_guard=True, sd_eject_guard=False)
    result = cli.cmd_jrbar_setup(args)
    assert calls == ["hooks"]
    assert result == 1


def test_config_only_marker_failure_is_retried(tmp_path: Path, monkeypatch: pytest.MonkeyPatch) -> None:
    state, config = _area(tmp_path), _area(tmp_path, "config")
    (config.sources[0] / "settings.json").write_text('{"synthetic": true}')

    def fail_marker(*_args):
        raise PermissionError("synthetic marker failure")

    with monkeypatch.context() as patch:
        patch.setattr(migration, "_write_marker", fail_marker)
        failed = migrate_from_sidepulse(tmp_path, areas=(config, state))
    assert failed.errors == ("marker: PermissionError",)
    assert (config.destination / "settings.json").is_file()
    recovered = migrate_from_sidepulse(tmp_path, areas=(config, state))
    assert not recovered.errors
    assert not recovered.performed
    assert recovered.marker_path.is_file()


@pytest.mark.parametrize("placement", ["root", "parent", "nested"])
def test_destination_symlinks_never_receive_legacy_files(tmp_path: Path, placement: str) -> None:
    area = _area(tmp_path)
    old = area.sources[0] / "history"
    old.mkdir()
    (old / "missing.json").write_text("legacy history")
    outside = tmp_path / "outside"
    outside.mkdir()
    if placement == "root":
        area.destination.symlink_to(outside, target_is_directory=True)
    elif placement == "parent":
        parent = tmp_path / "linked-parent"
        parent.symlink_to(outside, target_is_directory=True)
        area = MigrationArea("state", area.sources, parent / "jrbar")
    else:
        area.destination.mkdir()
        (area.destination / "history").symlink_to(outside, target_is_directory=True)
    report = migrate_from_sidepulse(tmp_path, areas=(area,), marker_path=tmp_path / "marker.json")
    assert list(outside.iterdir()) == []
    assert (old / "missing.json").read_text() == "legacy history"
    assert bool(report.errors) == (placement != "nested")


def test_dry_run_of_directory_merge_matches_copy_without_writing(tmp_path: Path) -> None:
    area = _area(tmp_path)
    old, new = area.sources[0] / "history", area.destination / "history"
    old.mkdir()
    new.mkdir(parents=True)
    (old / "missing.json").write_text("legacy missing")
    (old / "shared.json").write_text("legacy shared")
    (new / "shared.json").write_text("current shared")
    before = {p.relative_to(tmp_path): p.read_bytes() for p in tmp_path.rglob("*") if p.is_file()}
    preview = migrate_from_sidepulse(tmp_path, areas=(area,), dry_run=True)
    after = {p.relative_to(tmp_path): p.read_bytes() for p in tmp_path.rglob("*") if p.is_file()}
    assert preview.performed
    assert before == after
    assert not preview.marker_path.exists()
    actual = migrate_from_sidepulse(tmp_path, areas=(area,))
    assert actual.areas[0].copied == preview.areas[0].copied == ("history",)
    assert (new / "missing.json").read_text() == "legacy missing"
    assert (new / "shared.json").read_text() == "current shared"


def test_config_sources_keep_first_settings_and_merge_disjoint_children(tmp_path: Path) -> None:
    state, config = _area(tmp_path), _area(tmp_path, "config")
    second = tmp_path / "old-root"
    second.mkdir()
    config = MigrationArea("config", (*config.sources, second), config.destination)
    for index, source in enumerate(config.sources):
        (source / "settings.json").write_text(f"settings-{index}")
        directory = source / "nested"
        directory.mkdir()
        (directory / f"file-{index}").write_text(f"data-{index}")
    report = migrate_from_sidepulse(tmp_path, areas=(config, state))
    assert not report.errors
    assert (config.destination / "settings.json").read_text() == "settings-0"
    for index in range(2):
        assert (config.destination / "nested" / f"file-{index}").read_text() == f"data-{index}"


def test_current_settings_without_legacy_files_do_not_create_marker(tmp_path: Path) -> None:
    state, config = _area(tmp_path), _area(tmp_path, "config")
    config.destination.mkdir()
    (config.destination / "settings.json").write_text("current settings")
    report = migrate_from_sidepulse(tmp_path, areas=(config, state))
    assert not report.errors
    assert not report.performed
    assert not report.marker_path.exists()
