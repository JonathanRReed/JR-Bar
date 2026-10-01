"""Versioned, lossless settings facade over the historical settings model.

The original model remains in :mod:`sidepulse._settings_legacy` while the
persistence boundary is hardened here. All callers continue importing
``jrbar.settings``; the facade patches the durable encoders/decoders once
and preserves the public API.
"""

from __future__ import annotations

import hashlib
import json
import threading
from collections.abc import Callable
from dataclasses import dataclass, replace
from enum import Enum
from pathlib import Path
from typing import Any

from . import _settings_legacy as _legacy
from .private_io import quarantine_private_file
from .product_identity import PRODUCT_DISPLAY_NAME

CURRENT_SETTINGS_SCHEMA_VERSION = 2
MIN_READABLE_SETTINGS_SCHEMA_VERSION = 1
MIN_WRITABLE_SETTINGS_SCHEMA_VERSION = 1
SETTINGS_SCHEMA_VERSION = CURRENT_SETTINGS_SCHEMA_VERSION
SETTINGS_DOCUMENT_MAX_BYTES = 4 * 1024 * 1024

DEVICE_SETTING_PERSISTED_FIELDS = frozenset(
    {
        "id",
        "name",
        "path",
        "led_display",
        "brightness",
        "auto_brightness_enabled",
        "red_gain",
        "green_gain",
        "blue_gain",
        "resting_glow",
        "blend_mode",
        "provider_pin",
        "signal_policy",
        "led_direction",
        "dot_travel_style",
    }
)
DND_SETTING_PERSISTED_FIELDS = frozenset(
    {
        "dnd_schedule_enabled",
        "dnd_schedule_start_minutes",
        "dnd_schedule_end_minutes",
        "dnd_schedule_mode",
        "dnd_dim_fraction",
        "dnd_override_mode",
        "dnd_override_created_epoch",
        "dnd_override_until_epoch",
        "dnd_focus_mode",
    }
)


class SettingsWriteRefusedError(RuntimeError):
    """A settings document is newer than this writer can safely preserve."""


class SettingsConcurrentWriteError(SettingsWriteRefusedError):
    """The durable settings document changed after this process loaded it."""


class SettingsFileUnreadableError(SettingsWriteRefusedError):
    """The file on disk cannot be read (a half-written save, say), so a save
    will not write over it. Unlike a newer-version or schema refusal this one
    can pass: the file may be whole a moment later."""


@dataclass(frozen=True, slots=True)
class SettingsCompatibility:
    source_version: int
    target_version: int = CURRENT_SETTINGS_SCHEMA_VERSION
    read_only: bool = False
    migrated: bool = False

    def __post_init__(self) -> None:
        if not (
            type(self.source_version) is int
            and self.source_version >= 1
            and type(self.target_version) is int
            and self.target_version >= 1
            and type(self.read_only) is bool
            and type(self.migrated) is bool
        ):
            raise ValueError("invalid settings compatibility")


@dataclass(frozen=True, slots=True)
class LoadedSettings:
    settings: Any
    compatibility: SettingsCompatibility


_STATE_LOCK = threading.RLock()
_COMPATIBILITY_BY_PATH: dict[Path, SettingsCompatibility] = {}
_SOURCE_DOCUMENT_BY_PATH: dict[Path, dict[str, object]] = {}
_SOURCE_DIGEST_BY_PATH: dict[Path, str | None] = {}

_ORIGINAL_DEVICE_TO_DICT = _legacy.DeviceDisplaySetting.to_dict
_ORIGINAL_DEVICE_SETTINGS_LOADER = _legacy._device_display_settings
_ORIGINAL_APPLY_CALIBRATION_PROFILE = (
    _legacy.AgentMonitorSettings.with_applied_calibration_profile
)
_ORIGINAL_LOAD_SETTINGS = _legacy.load_settings


def default_settings_path(home: Path | None = None) -> Path:
    return _legacy.default_settings_path(home)


def _settings_path(path: Path | None) -> Path:
    return (path or default_settings_path()).expanduser().absolute()


def _document_digest(document: dict[str, object]) -> str:
    payload = json.dumps(
        document,
        sort_keys=True,
        separators=(",", ":"),
        ensure_ascii=True,
        allow_nan=False,
    ).encode("utf-8")
    return hashlib.sha256(payload).hexdigest()


def _read_document(target: Path) -> tuple[dict[str, object], str]:
    """Read the settings document and its digest.

    A document that comes back is always strictly serializable: json.loads
    accepts NaN, Infinity and 1e999, but the digest refuses them, so a
    non-finite number raises ValueError here, alongside a parse error.
    """
    target.lstat()
    _legacy.ensure_private_directory(target.parent)
    value = json.loads(
        _legacy.read_private_text(
            target,
            max_bytes=SETTINGS_DOCUMENT_MAX_BYTES,
        )
    )
    if not isinstance(value, dict):
        raise ValueError("settings document must be an object")
    return value, _document_digest(value)


def _device_to_dict(self) -> dict[str, object]:
    payload = dict(_ORIGINAL_DEVICE_TO_DICT(self))
    payload["resting_glow"] = max(0.0, min(0.35, float(self.resting_glow)))
    if set(payload) != DEVICE_SETTING_PERSISTED_FIELDS:
        missing = sorted(DEVICE_SETTING_PERSISTED_FIELDS - set(payload))
        extra = sorted(set(payload) - DEVICE_SETTING_PERSISTED_FIELDS)
        raise RuntimeError(
            f"device settings schema drifted (missing={missing}, extra={extra})"
        )
    return payload


def _device_display_settings(
    value: object,
    default_display: str,
) -> tuple[object, ...]:
    devices = _ORIGINAL_DEVICE_SETTINGS_LOADER(value, default_display)
    return tuple(
        replace(
            device,
            resting_glow=max(0.0, min(0.35, float(device.resting_glow))),
        )
        for device in devices
    )


def _with_applied_calibration_profile(self, slot: str):
    updated = _ORIGINAL_APPLY_CALIBRATION_PROFILE(self, slot)
    profile = self.calibration_profiles.get(slot)
    if not isinstance(profile, dict):
        return updated
    devices = []
    for device in updated.devices:
        entry = profile.get(device.device_id)
        if isinstance(entry, dict):
            raw = entry.get("resting_glow", device.resting_glow)
            if isinstance(raw, (int, float)) and not isinstance(raw, bool):
                device = replace(
                    device,
                    resting_glow=max(0.0, min(0.35, float(raw))),
                )
        devices.append(device)
    return replace(updated, devices=tuple(devices))


def _settings_schema_version(data: dict[str, object]) -> int:
    raw = data.get("settings_schema_version", 1)
    if type(raw) is not int or raw < 1:
        raise ValueError("invalid settings schema version")
    return raw


def _migrate_settings_document(
    data: dict[str, object],
    source_version: int,
) -> dict[str, object]:
    migrated = dict(data)
    version = source_version
    while version < CURRENT_SETTINGS_SCHEMA_VERSION:
        if version == 1:
            migrated["settings_schema_version"] = 2
            version = 2
            continue
        raise ValueError("unsupported settings migration")
    return migrated


def _preserve_corrupt_settings(target: Path) -> None:
    """Set a settings file that cannot be read aside, never destroy it.

    Returning defaults means the very next save would overwrite the
    evidence, and with it the calibration profiles, studio library and
    colours. The file moves to ``settings.json.corrupt-<UTC stamp>``
    (private, the newest three kept), so a second bad file does not cost the
    first, and a second bad file is never deleted. The legacy loader calls
    this name too; it is replaced below."""
    try:
        _legacy.ensure_private_directory(target.parent)
    except OSError:
        pass
    quarantine_private_file(target, reason="it could not be read")


def _remember_document(
    target: Path,
    compatibility: SettingsCompatibility,
    document: dict[str, object],
    *,
    source_digest: str | None,
) -> None:
    with _STATE_LOCK:
        _COMPATIBILITY_BY_PATH[target] = compatibility
        _SOURCE_DOCUMENT_BY_PATH[target] = dict(document)
        _SOURCE_DIGEST_BY_PATH[target] = source_digest


def _forget_document(target: Path) -> None:
    with _STATE_LOCK:
        _COMPATIBILITY_BY_PATH.pop(target, None)
        _SOURCE_DOCUMENT_BY_PATH.pop(target, None)
        _SOURCE_DIGEST_BY_PATH.pop(target, None)


#: Told, from whichever thread is saving, when a save loses to an outside edit.
#: The daemon sets it so that every one of its save sites, not only the one
#: that happened to be writing, asks for the same deliberate recovery.
_CONFLICT_OBSERVER: Callable[[Path, SettingsWriteRefusedError], None] | None = None


def set_write_conflict_observer(
    observer: Callable[[Path, SettingsWriteRefusedError], None] | None,
) -> None:
    """Register (or with None, remove) the one process-wide conflict listener.

    It is called while the settings lock is held, so it must only record that
    a conflict happened and return."""
    global _CONFLICT_OBSERVER
    _CONFLICT_OBSERVER = observer


def settings_file_path(path: Path | None = None) -> Path:
    """The absolute settings path a save or load with ``path`` would use."""
    return _settings_path(path)


def _lost_to_an_outside_edit(target: Path, message: str) -> SettingsConcurrentWriteError:
    error = SettingsConcurrentWriteError(message)
    observer = _CONFLICT_OBSERVER
    if observer is not None:
        try:
            observer(target, error)
        except Exception:
            pass
    return error


# Entry-keyed collections the runtime serializes COMPLETELY: their entries
# are user data (a provider's animation, a session's colour, a profile),
# not schema fields, so a key absent from the encoded document is a
# DELETION the user made -- resurrecting it from the source document made
# removing any entry impossible ("Automatic" never stuck). Unknown-field
# preservation continues everywhere else.
_OWNED_COLLECTION_PATHS = frozenset(
    {
        "colors.mode_colors",
        "colors.agent_colors",
        "colors.session_colors",
        "colors.fade_floor",
        "colors.fade_ceiling",
        "colors.mode_animation",
        "colors.provider_animation",
        "colors.provider_animation_parameters",
        "colors.speed_overrides",
        "signal_styles",
        "calibration_profiles",
        "focus_profile_rules",
        "focus_signal_policy",
        "focus_dim_rules",
        "session_open_preferences",
        "global_action_shortcuts",
    }
)


def _merge_unknown_fields(
    source: object,
    encoded: object,
    *,
    key: str = "",
    path: str = "",
) -> object:
    if path in _OWNED_COLLECTION_PATHS:
        return encoded
    if isinstance(source, dict) and isinstance(encoded, dict):
        merged = {
            source_key: source_value
            for source_key, source_value in source.items()
            if source_key not in encoded
        }
        for encoded_key, encoded_value in encoded.items():
            merged[encoded_key] = _merge_unknown_fields(
                source.get(encoded_key),
                encoded_value,
                key=encoded_key,
                path=f"{path}.{encoded_key}" if path else encoded_key,
            )
        return merged
    if key == "devices" and isinstance(source, list) and isinstance(encoded, list):
        source_by_id = {
            item.get("id"): item
            for item in source
            if isinstance(item, dict) and isinstance(item.get("id"), str)
        }
        return [
            _merge_unknown_fields(
                source_by_id.get(item.get("id")) if isinstance(item, dict) else None,
                item,
                # A prefix no owned path starts with: a device-entry field
                # must never alias a top-level owned collection name.
                path="devices[]",
            )
            for item in encoded
        ]
    return encoded


def load_settings_document(
    path: Path | None = None,
    *,
    track: bool = True,
) -> LoadedSettings:
    """Read the settings file.

    A tracked load (the default) is a deliberate reload: it records what the
    file held, and ``save_settings`` later refuses to write over a file that
    changed since. ``track=False`` is a plain read for code that only wants
    one field (a statusline check, a price table): it leaves that record
    exactly as it was, on every branch, so an incidental read can never
    stand in for the daemon having seen an outside edit."""
    target = _settings_path(path)

    def remember(*args, **kwargs) -> None:
        if track:
            _remember_document(*args, **kwargs)

    def forget(target_path: Path) -> None:
        if track:
            _forget_document(target_path)

    try:
        data, source_digest = _read_document(target)
    except FileNotFoundError:
        compatibility = SettingsCompatibility(CURRENT_SETTINGS_SCHEMA_VERSION)
        remember(target, compatibility, {}, source_digest=None)
        return LoadedSettings(_legacy.AgentMonitorSettings(), compatibility)
    except OSError:
        compatibility = SettingsCompatibility(CURRENT_SETTINGS_SCHEMA_VERSION)
        forget(target)
        return LoadedSettings(_legacy.AgentMonitorSettings(), compatibility)
    except Exception:
        _legacy._preserve_corrupt_settings(target)
        compatibility = SettingsCompatibility(CURRENT_SETTINGS_SCHEMA_VERSION)
        forget(target)
        return LoadedSettings(_legacy.AgentMonitorSettings(), compatibility)

    try:
        source_version = _settings_schema_version(data)
    except ValueError:
        _legacy._preserve_corrupt_settings(target)
        compatibility = SettingsCompatibility(CURRENT_SETTINGS_SCHEMA_VERSION)
        forget(target)
        return LoadedSettings(_legacy.AgentMonitorSettings(), compatibility)

    if source_version > CURRENT_SETTINGS_SCHEMA_VERSION:
        compatibility = SettingsCompatibility(
            source_version,
            read_only=True,
            migrated=False,
        )
        settings = _ORIGINAL_LOAD_SETTINGS(target)
        remember(
            target,
            compatibility,
            data,
            source_digest=source_digest,
        )
        return LoadedSettings(settings, compatibility)

    if source_version < MIN_READABLE_SETTINGS_SCHEMA_VERSION:
        _legacy._preserve_corrupt_settings(target)
        compatibility = SettingsCompatibility(CURRENT_SETTINGS_SCHEMA_VERSION)
        forget(target)
        return LoadedSettings(_legacy.AgentMonitorSettings(), compatibility)

    try:
        migrated = _migrate_settings_document(data, source_version)
    except ValueError:
        compatibility = SettingsCompatibility(source_version, read_only=True)
        remember(
            target,
            compatibility,
            data,
            source_digest=source_digest,
        )
        return LoadedSettings(_legacy.AgentMonitorSettings(), compatibility)

    compatibility = SettingsCompatibility(
        source_version,
        read_only=False,
        migrated=source_version != CURRENT_SETTINGS_SCHEMA_VERSION,
    )
    settings = _ORIGINAL_LOAD_SETTINGS(target)
    remember(
        target,
        compatibility,
        migrated,
        source_digest=source_digest,
    )
    return LoadedSettings(settings, compatibility)


def load_settings(path: Path | None = None, *, track: bool = True):
    return load_settings_document(path, track=track).settings


def settings_from_mapping(data: object):
    """What ``load_settings`` returns for a settings file holding ``data``,
    without writing or reading one: the same size limit, schema gates and
    field validation. ``data`` is JSON-shaped (the caller round-trips it
    through ``json`` first), so it matches what a file would hold."""
    if not isinstance(data, dict):
        return _legacy.AgentMonitorSettings()
    try:
        size = len(json.dumps(data).encode("utf-8"))
        source_version = _settings_schema_version(data)
    except (TypeError, ValueError):
        return _legacy.AgentMonitorSettings()
    if size > SETTINGS_DOCUMENT_MAX_BYTES:
        return _legacy.AgentMonitorSettings()
    if source_version > CURRENT_SETTINGS_SCHEMA_VERSION:
        return _legacy.settings_from_data(data)
    if source_version < MIN_READABLE_SETTINGS_SCHEMA_VERSION:
        return _legacy.AgentMonitorSettings()
    try:
        _migrate_settings_document(data, source_version)
    except ValueError:
        return _legacy.AgentMonitorSettings()
    return _legacy.settings_from_data(data)


class OutsideEditOutcome(str, Enum):
    #: The file parsed and validated and differs from memory: it is now the settings.
    ADOPTED = "adopted"
    #: The file parsed and holds what memory holds: nothing to take.
    UNCHANGED = "unchanged"
    #: The file is gone: memory stays and the file should be written again.
    MISSING = "missing"
    #: The file did not parse or validate and has stopped changing: it was set
    #: aside, memory stays.
    INVALID = "invalid"
    #: The file did not parse, but it may be an editor's save still in
    #: progress. Nothing was moved; look again (see ``unsettled``).
    UNSETTLED = "unsettled"


@dataclass(frozen=True, slots=True)
class OutsideEditAdoption:
    outcome: OutsideEditOutcome
    #: What the caller should hold now.
    settings: Any
    #: The kept copy of the memory that was replaced (outcome ADOPTED).
    backup: Path | None = None
    #: A backup was wanted and could not be written.
    backup_failed: bool = False
    #: (size, mtime_ns) of the file at this look (outcome UNSETTLED): pass it
    #: back as ``unsettled`` on the next look.
    signature: tuple[int, int] | None = None


REPLACED_BACKUP_SUFFIX = ".replaced"


def _replaced_backup(target: Path, previous) -> Path | None:
    """Keep the memory an outside edit replaced as ``settings.json.replaced``.

    One backup, private mode, the latest replacement; a copy somebody can
    move back over the file by hand."""
    encoded = previous.to_dict()
    encoded["settings_schema_version"] = CURRENT_SETTINGS_SCHEMA_VERSION
    payload = json.dumps(encoded, indent=2, sort_keys=True, allow_nan=False) + "\n"
    backup = target.with_name(target.name + REPLACED_BACKUP_SUFFIX)
    return _legacy.atomic_private_write(backup, payload, full_sync=True)


def _file_signature(target: Path) -> tuple[int, int] | None:
    """(size, mtime_ns) of the settings file, or None when there is none."""
    try:
        info = target.lstat()
    except OSError:
        return None
    return (info.st_size, info.st_mtime_ns)


def adopt_outside_edit(
    previous,
    path: Path | None = None,
    *,
    unsettled: tuple[int, int] | None = None,
    signature_of: Callable[[Path], tuple[int, int] | None] = _file_signature,
) -> OutsideEditAdoption:
    """Take the settings file as it stands after somebody else changed it.

    ``previous`` is what the caller holds. A file that parses and validates
    wins over stale memory: the caller's copy is kept as
    ``settings.json.replaced`` and the file is read as a deliberate reload, so
    the next save is judged against what was just taken. A missing file keeps
    memory. A read that fails for a reason that may pass (an ``OSError``)
    raises, so the caller can try again.

    A file that does not parse or validate is never adopted, but it is not set
    aside on the first look either: an editor that saves in place leaves a
    half-written file for a moment, and moving it would send the editor's last
    write into the moved file. The first look returns ``UNSETTLED`` with the
    file's ``(size, mtime_ns)``; the caller passes it back as ``unsettled`` on
    its next look, and only a file that has not changed in between is set aside
    (see ``_preserve_corrupt_settings``). ``signature_of`` is the stat reader,
    injected so a test needs no sleep."""
    target = _settings_path(path)

    def invalid() -> OutsideEditAdoption:
        signature = signature_of(target)
        if signature is None:
            return missing()
        if signature != unsettled:
            return OutsideEditAdoption(
                OutsideEditOutcome.UNSETTLED, previous, signature=signature
            )
        _legacy._preserve_corrupt_settings(target)
        if target.exists():
            # Could not be moved: leave the guard unarmed so a save refuses
            # rather than overwrites.
            _forget_document(target)
        else:
            _remember_document(
                target,
                SettingsCompatibility(CURRENT_SETTINGS_SCHEMA_VERSION),
                {},
                source_digest=None,
            )
        return OutsideEditAdoption(OutsideEditOutcome.INVALID, previous)

    def missing() -> OutsideEditAdoption:
        _remember_document(
            target,
            SettingsCompatibility(CURRENT_SETTINGS_SCHEMA_VERSION),
            {},
            source_digest=None,
        )
        return OutsideEditAdoption(OutsideEditOutcome.MISSING, previous)

    try:
        data, digest = _read_document(target)
        source_version = _settings_schema_version(data)
    except FileNotFoundError:
        return missing()
    except OSError as error:
        if "exceeds maximum size" not in str(error):
            raise
        return invalid()
    except Exception:
        return invalid()

    if source_version > CURRENT_SETTINGS_SCHEMA_VERSION:
        compatibility = SettingsCompatibility(source_version, read_only=True)
        document = data
    else:
        try:
            document = _migrate_settings_document(data, source_version)
        except ValueError:
            return invalid()
        compatibility = SettingsCompatibility(
            source_version,
            migrated=source_version != CURRENT_SETTINGS_SCHEMA_VERSION,
        )
    adopted = settings_from_mapping(data)
    # Judged against exactly the bytes just read, so a later outside edit is
    # still caught by the next save.
    _remember_document(target, compatibility, document, source_digest=digest)
    if previous is not None and previous.to_dict() == adopted.to_dict():
        return OutsideEditAdoption(OutsideEditOutcome.UNCHANGED, previous)
    backup = None
    backup_failed = False
    if previous is not None:
        try:
            backup = _replaced_backup(target, previous)
        except (OSError, TypeError, ValueError):
            backup_failed = True
    return OutsideEditAdoption(
        OutsideEditOutcome.ADOPTED, adopted, backup, backup_failed
    )


def save_settings(
    settings,
    path: Path | None = None,
    *,
    compatibility: SettingsCompatibility | None = None,
) -> Path:
    target = _settings_path(path)
    with _STATE_LOCK:
        tracked = target in _COMPATIBILITY_BY_PATH
        remembered_compatibility = _COMPATIBILITY_BY_PATH.get(target)
        source_document = dict(_SOURCE_DOCUMENT_BY_PATH.get(target, {}))
        expected_digest = _SOURCE_DIGEST_BY_PATH.get(target)
        if tracked:
            try:
                _, current_digest = _read_document(target)
            except FileNotFoundError:
                current_digest = None
            except ValueError as error:
                # The file was readable when it was loaded, so one that can no
                # longer be parsed changed underneath us.
                raise _lost_to_an_outside_edit(
                    target,
                    "settings changed after they were loaded and can no "
                    "longer be read; reload before saving",
                ) from error
            if current_digest != expected_digest:
                raise _lost_to_an_outside_edit(
                    target,
                    "settings changed after they were loaded; reload before saving",
                )
        elif target.exists():
            try:
                current_document, _ = _read_document(target)
            except ValueError as error:
                # Never overwrite a file that cannot be read.
                raise SettingsFileUnreadableError(
                    "settings file is unreadable; load it before saving"
                ) from error
            current_version = _settings_schema_version(current_document)
            if current_version > CURRENT_SETTINGS_SCHEMA_VERSION:
                raise SettingsWriteRefusedError(
                    f"settings were written by a newer {PRODUCT_DISPLAY_NAME} version"
                )
            source_document = current_document

        effective = compatibility or remembered_compatibility
        if effective is not None and effective.read_only:
            raise SettingsWriteRefusedError(
                f"settings were written by a newer {PRODUCT_DISPLAY_NAME} version"
            )
        if effective is not None and (
            effective.source_version < MIN_WRITABLE_SETTINGS_SCHEMA_VERSION
        ):
            raise SettingsWriteRefusedError("settings schema is not writable")

        encoded = settings.to_dict()
        if not DND_SETTING_PERSISTED_FIELDS.issubset(encoded):
            missing = sorted(DND_SETTING_PERSISTED_FIELDS - set(encoded))
            raise SettingsWriteRefusedError(
                f"settings encoder omitted DND fields: {missing}"
            )
        encoded["settings_schema_version"] = CURRENT_SETTINGS_SCHEMA_VERSION
        document = _merge_unknown_fields(source_document, encoded)
        if not isinstance(document, dict):
            raise SettingsWriteRefusedError("settings encoder returned invalid data")
        payload = json.dumps(
            document,
            indent=2,
            sort_keys=True,
            allow_nan=False,
        ) + "\n"
        # settings.json is small, rewritten rarely, and a person's work: flush to the drive.
        written = _legacy.atomic_private_write(target, payload, full_sync=True)
        current = SettingsCompatibility(CURRENT_SETTINGS_SCHEMA_VERSION)
        _remember_document(
            target,
            current,
            document,
            source_digest=_document_digest(document),
        )
        return written


_legacy.CURRENT_SETTINGS_SCHEMA_VERSION = CURRENT_SETTINGS_SCHEMA_VERSION
_legacy.MIN_READABLE_SETTINGS_SCHEMA_VERSION = MIN_READABLE_SETTINGS_SCHEMA_VERSION
_legacy.MIN_WRITABLE_SETTINGS_SCHEMA_VERSION = MIN_WRITABLE_SETTINGS_SCHEMA_VERSION
_legacy.SETTINGS_SCHEMA_VERSION = CURRENT_SETTINGS_SCHEMA_VERSION
_legacy.DEVICE_SETTING_PERSISTED_FIELDS = DEVICE_SETTING_PERSISTED_FIELDS
_legacy.DeviceDisplaySetting.to_dict = _device_to_dict
_legacy._device_display_settings = _device_display_settings
_legacy.AgentMonitorSettings.with_applied_calibration_profile = (
    _with_applied_calibration_profile
)
_legacy.SettingsCompatibility = SettingsCompatibility
_legacy.LoadedSettings = LoadedSettings
_legacy.SettingsWriteRefusedError = SettingsWriteRefusedError
_legacy.SettingsConcurrentWriteError = SettingsConcurrentWriteError
_legacy.SettingsFileUnreadableError = SettingsFileUnreadableError
_legacy._preserve_corrupt_settings = _preserve_corrupt_settings
_legacy.load_settings_document = load_settings_document
_legacy.load_settings = load_settings
_legacy.save_settings = save_settings

for _name in dir(_legacy):
    if _name.startswith("__") or _name in globals():
        continue
    globals()[_name] = getattr(_legacy, _name)

__all__ = tuple(
    sorted(
        {
            name
            for name in globals()
            if not name.startswith("_") and name not in {"Any", "Path"}
        }
    )
)
