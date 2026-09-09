"""One-time copy of SidePulse config, state and data into the JR-Bar locations.

Runs at status-bar start and from ``jrbar setup``. Every copy is additive:
the SidePulse trees are never modified or removed, nothing already present
under a JR-Bar location is overwritten, and the run is recorded in
``<state dir>/migrated-from-sidepulse.json`` so it happens once. Logging is
content-free: area names and counts, never file contents.

Areas (old, flattened into new):

* ``~/.config/sidepulse/agent-monitor/*`` and the files beside it in
  ``~/.config/sidepulse/`` -> ``~/.config/jrbar/``
* ``~/.local/state/sidepulse/agent-monitor/*`` and the files beside it in
  ``~/.local/state/sidepulse/`` -> ``~/.local/state/jrbar/`` (sockets and
  ``*.pid`` are skipped; they belong to a process, not to the user)
* ``~/.local/share/sidepulse/*`` -> ``~/.local/share/jrbar/`` (the
  installer's ``app-backup-*`` copies of the old SidePulse.app are skipped)
* ``~/Library/Application Support/SidePulse/*``
  -> ``~/Library/Application Support/JR-Bar/``

The LaunchAgent swap, provider hook rewrites and Keychain copy-forward are
handled by their own installers and stores; this module only moves files.
"""

from __future__ import annotations

import json
import logging
import os
import shutil
import stat
import time
from collections.abc import Callable, Iterable
from dataclasses import dataclass, field
from pathlib import Path

from ._settings_legacy import default_config_dir, legacy_config_dirs
from .sd_eject_guard_launch import default_user_data_dir
from .state_paths import default_state_dir, legacy_state_dirs

MIGRATION_MARKER_NAME = "migrated-from-sidepulse.json"
MIGRATION_DOCUMENT = "jrbar.migration"
MIGRATION_DOCUMENT_VERSION = 1
_SKIPPED_STATE_SUFFIXES = (".pid", ".sock")
_SKIPPED_DATA_PREFIXES = ("app-backup-",)

_log = logging.getLogger("jrbar.migration")


def legacy_data_dir(home: Path | None = None) -> Path:
    return default_user_data_dir(home) / "sidepulse"


def default_data_dir(home: Path | None = None) -> Path:
    return default_user_data_dir(home) / "jrbar"


def legacy_app_support_dir(home: Path | None = None) -> Path:
    base = home or Path.home()
    return base / "Library" / "Application Support" / "SidePulse"


def default_app_support_dir(home: Path | None = None) -> Path:
    base = home or Path.home()
    return base / "Library" / "Application Support" / "JR-Bar"


@dataclass(frozen=True)
class MigrationArea:
    """One old->new directory mapping."""

    name: str
    sources: tuple[Path, ...]
    destination: Path
    # Entry names (relative to a source) never copied.
    skip: Callable[[Path], bool] = lambda _path: False
    # Directory entries in a source that are themselves other sources (the
    # nested agent-monitor dir inside the sidepulse root) and must not be
    # copied as a subtree.
    exclude_names: frozenset[str] = frozenset()


@dataclass(frozen=True)
class AreaResult:
    name: str
    destination: Path
    copied: tuple[str, ...] = ()
    skipped: tuple[str, ...] = ()
    reason: str | None = None

    @property
    def performed(self) -> bool:
        return bool(self.copied)


@dataclass(frozen=True)
class MigrationReport:
    marker_path: Path
    areas: tuple[AreaResult, ...] = ()
    dry_run: bool = False
    already_migrated: bool = False
    errors: tuple[str, ...] = field(default_factory=tuple)

    @property
    def performed(self) -> bool:
        return any(area.performed for area in self.areas)

    @property
    def copied_count(self) -> int:
        return sum(len(area.copied) for area in self.areas)

    def summary_lines(self) -> list[str]:
        if self.already_migrated:
            return []
        if not self.performed and not self.errors:
            return []
        verb = "would copy" if self.dry_run else "copied"
        lines = [f"migration: {verb} {self.copied_count} SidePulse entries into the JR-Bar directories"]
        for area in self.areas:
            if area.copied:
                lines.append(f"  {area.name}: {len(area.copied)} -> {area.destination}")
        for error in self.errors:
            lines.append(f"  warning: {error}")
        return lines


def _is_socket(path: Path) -> bool:
    try:
        return stat.S_ISSOCK(path.lstat().st_mode)
    except OSError:
        return False


def _skip_state_entry(path: Path) -> bool:
    return path.name.endswith(_SKIPPED_STATE_SUFFIXES) or _is_socket(path)


def _skip_data_entry(path: Path) -> bool:
    return path.name.startswith(_SKIPPED_DATA_PREFIXES)


def migration_areas(
    home: Path | None = None,
    *,
    config_dir: Path | None = None,
    state_dir: Path | None = None,
    data_dir: Path | None = None,
    app_support_dir: Path | None = None,
    legacy_config: tuple[Path, ...] | None = None,
    legacy_state: tuple[Path, ...] | None = None,
    legacy_data: Path | None = None,
    legacy_app_support: Path | None = None,
) -> tuple[MigrationArea, ...]:
    """The four areas with defaults resolved from ``home`` and the XDG env."""
    old_config = legacy_config if legacy_config is not None else legacy_config_dirs(home)
    old_state = legacy_state if legacy_state is not None else legacy_state_dirs(home)
    return (
        MigrationArea(
            "config",
            old_config,
            config_dir or default_config_dir(home),
            exclude_names=frozenset({"agent-monitor"}),
        ),
        MigrationArea(
            "state",
            old_state,
            state_dir or default_state_dir(home),
            skip=_skip_state_entry,
            exclude_names=frozenset({"agent-monitor"}),
        ),
        MigrationArea(
            "data",
            (legacy_data if legacy_data is not None else legacy_data_dir(home),),
            data_dir or default_data_dir(home),
            skip=_skip_data_entry,
        ),
        MigrationArea(
            "app-support",
            (legacy_app_support if legacy_app_support is not None else legacy_app_support_dir(home),),
            app_support_dir or default_app_support_dir(home),
        ),
    )


def _iter_entries(source: Path, area: MigrationArea) -> Iterable[Path]:
    try:
        entries = sorted(source.iterdir())
    except (FileNotFoundError, NotADirectoryError):
        return ()
    except OSError:
        return ()
    return tuple(entry for entry in entries if entry.name not in area.exclude_names)


def _ignore_process_files(directory: str, names: list[str]) -> set[str]:
    ignored: set[str] = set()
    for name in names:
        path = Path(directory) / name
        if name.endswith(_SKIPPED_STATE_SUFFIXES) or _is_socket(path) or path.is_symlink():
            ignored.add(name)
    return ignored


def _copy_entry(entry: Path, target: Path) -> None:
    if entry.is_dir():
        shutil.copytree(entry, target, symlinks=False, ignore=_ignore_process_files, copy_function=shutil.copy2)
    else:
        shutil.copy2(entry, target, follow_symlinks=False)


def _migrate_area(area: MigrationArea, *, dry_run: bool) -> AreaResult:
    if area.name == "config" and (area.destination / "settings.json").exists():
        return AreaResult(area.name, area.destination, reason="settings.json already present")
    if not any(source.is_dir() for source in area.sources):
        return AreaResult(area.name, area.destination, reason="nothing to migrate")

    copied: list[str] = []
    skipped: list[str] = []
    destination_ready = dry_run
    for source in area.sources:
        for entry in _iter_entries(source, area):
            relative = entry.name
            if entry.is_symlink() or area.skip(entry):
                skipped.append(relative)
                continue
            target = area.destination / relative
            if target.exists() or target.is_symlink():
                skipped.append(relative)
                continue
            if dry_run:
                copied.append(relative)
                continue
            if not destination_ready:
                area.destination.mkdir(parents=True, exist_ok=True, mode=0o700)
                destination_ready = True
            _copy_entry(entry, target)
            copied.append(relative)
    return AreaResult(area.name, area.destination, tuple(copied), tuple(skipped))


def _write_marker(marker: Path, report_areas: tuple[AreaResult, ...]) -> None:
    document = {
        "schema": MIGRATION_DOCUMENT,
        "version": MIGRATION_DOCUMENT_VERSION,
        "migrated_at": time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime()),
        "areas": {
            area.name: {
                "destination": str(area.destination),
                "copied": list(area.copied),
                "skipped": list(area.skipped),
                **({"reason": area.reason} if area.reason else {}),
            }
            for area in report_areas
        },
    }
    marker.parent.mkdir(parents=True, exist_ok=True, mode=0o700)
    tmp = marker.with_name(f".{marker.name}.{os.getpid()}.tmp")
    tmp.write_text(json.dumps(document, indent=2, sort_keys=True) + "\n", encoding="utf-8")
    os.chmod(tmp, 0o600)
    os.replace(tmp, marker)


def migrate_from_sidepulse(
    home: Path | None = None,
    *,
    dry_run: bool = False,
    areas: tuple[MigrationArea, ...] | None = None,
    marker_path: Path | None = None,
    logger: logging.Logger | None = None,
) -> MigrationReport:
    """Copy SidePulse-era files into the JR-Bar directories, once.

    Idempotent: the marker file short-circuits every later call, and a call
    that finds the marker missing still never overwrites a JR-Bar file. A
    failure inside one area is recorded and the others still run; the
    marker is written only when something was copied, so a fresh machine
    keeps a clean state directory.
    """
    log = logger or _log
    resolved_areas = areas if areas is not None else migration_areas(home)
    state_destination = next(area.destination for area in resolved_areas if area.name == "state")
    marker = marker_path or state_destination / MIGRATION_MARKER_NAME
    if marker.exists():
        return MigrationReport(marker, dry_run=dry_run, already_migrated=True)

    results: list[AreaResult] = []
    errors: list[str] = []
    for area in resolved_areas:
        try:
            result = _migrate_area(area, dry_run=dry_run)
        except OSError as exc:
            errors.append(f"{area.name}: {type(exc).__name__}")
            log.warning("migration: %s failed (%s)", area.name, type(exc).__name__)
            result = AreaResult(area.name, area.destination, reason=type(exc).__name__)
        results.append(result)
        if result.copied:
            log.info(
                "migration: %s %s %d entries (%d skipped)",
                area.name,
                "would copy" if dry_run else "copied",
                len(result.copied),
                len(result.skipped),
            )

    report = MigrationReport(marker, tuple(results), dry_run=dry_run, errors=tuple(errors))
    if report.performed and not dry_run and not errors:
        try:
            _write_marker(marker, report.areas)
        except OSError as exc:
            log.warning("migration: marker not written (%s)", type(exc).__name__)
    return report


def run_startup_migration() -> MigrationReport | None:
    """Bring a SidePulse install's files forward before anything reads them.

    Called by the one retained foreground main. Never blocks startup: a
    failure is logged content-free, the app starts with whatever is present,
    and the next start retries.
    """
    try:
        report = migrate_from_sidepulse()
    except Exception as exc:  # pragma: no cover - defensive startup guard
        _log.warning("migration: skipped at startup (%s)", type(exc).__name__)
        return None
    for line in report.summary_lines():
        print(line, flush=True)
    return report


__all__ = [
    "MIGRATION_MARKER_NAME",
    "AreaResult",
    "MigrationArea",
    "MigrationReport",
    "default_app_support_dir",
    "default_data_dir",
    "legacy_app_support_dir",
    "legacy_data_dir",
    "migrate_from_sidepulse",
    "migration_areas",
    "run_startup_migration",
]
