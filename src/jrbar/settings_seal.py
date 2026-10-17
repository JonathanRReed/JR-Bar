"""Sealed settings: a hand edit of a setting that grants a capability changes nothing.

The daemon takes an outside edit of ``settings.json`` (docs/CORE-PROTOCOL.md,
"Protected settings"), and any process running as you can write that file. So
the settings that switch on a capability (answering an ask from ``jrbar
serve``, a webhook, cloud ingest, remote peers, a program the daemon runs, a
provider read) carry a seal: an HMAC over just those values, made with a key
a same-user process cannot read.

The key lives in a Keychain item whose access list trusts the JR-Bar app
alone. The app hands it to the daemon it starts over the same private stdin
pipe as the per-launch secret (``core_auth``); it is in no argument, no
environment variable and no file. The daemon checks the seal on every load.
When the file's protected values do not match, they are ignored and the daemon
keeps what it held; every other setting is taken from the file as ever.

Only the daemon writes a seal, on a save, from the settings it holds in
memory. Those change only through an authenticated command, so sealing what
is in memory seals only what the app asked for.
"""

from __future__ import annotations

import functools
import hashlib
import hmac
import json
import threading
import time
from collections.abc import Callable, Mapping
from dataclasses import dataclass
from enum import Enum
from pathlib import Path
from typing import Any, Final

#: The member of ``settings.json`` that holds the seal.
SEAL_FIELD: Final = "_seal"
SEAL_VERSION: Final = 1
SEAL_CONTEXT: Final = b"jrbar-settings-seal-v1\n"
KEY_BYTES: Final = 32
REJECTED_SUFFIX: Final = ".rejected"
#: The values last sealed, with their own MAC, kept beside ``settings.json`` so
#: a daemon that starts over a file it cannot vouch for still knows what it
#: sealed last, not just the defaults.
SNAPSHOT_SUFFIX: Final = ".sealed"

#: Settings whose value grants egress, consent, command execution, a hook or
#: answering capability, or a path the daemon reads or writes. A hand edit of
#: one of these is ignored (see the module doc). Keep the doc and the tests in
#: step: ``tests/test_settings_seal.py`` fails on a setting nobody sorted.
SEALED_KEYS: Final[tuple[str, ...]] = (
    # Answering and the loopback server.
    "serve_enabled",
    "serve_answer_enabled",
    # Where events leave the Mac.
    "escalation_webhook_url",
    "ntfy_enabled",
    "ntfy_topic",
    "ntfy_only_when_away",
    "webhook_events",
    "cloud_ingest_enabled",
    "remote_peers",
    # Programs the daemon runs and paths it reads.
    "usage_hooks",
    "usage_event_hook_path",
    "global_action_shortcuts",
    "cliproxy_hub",
    "provider_extra_homes",
    "claude_statusline_source",
    # Consent to a provider request leaving the Mac.
    "claude_plan_limits_enabled",
    "claude_plan_limits_consent_version",
    "provider_status_feeds_enabled",
    "provider_update_checks_enabled",
    # Power: keeps the Mac awake with the lid shut.
    "closed_lid_awake_policy",
    "closed_lid_grace_minutes",
    # The seals of the three consent files beside settings.json
    # (``companion_seal.py``): a daemon fact, not a preference.
    "companion_seals",
)

#: Settings that need the app to change them (they are not display
#: preferences) but grant nothing worth sealing: they read local files or
#: switch local behaviour, and none sends, runs or answers. Each group says
#: why. A setting that is in neither list, nor ``OPEN_SETTING_ROOTS`` in
#: ``core_auth``, fails the drift test until somebody decides which it is.
UNSEALED_PRIVILEGED: Final[Mapping[str, str]] = {
    **dict.fromkeys(
        (
            "agent_keep_awake_enabled",
            "keep_display_awake",
            "keep_awake_on_battery",
            "keep_awake_yield_low_power_mode",
        ),
        "a power preference while a session runs; it cannot keep the Mac awake with the lid shut",
    ),
    **dict.fromkeys(
        (
            "transcript_monitoring",
            "capacity_history_enabled",
            "capacity_history_retention_days",
            "operator_history_retention_days",
            "statusline_text_enabled",
            "pricing_overrides",
            "usage_graph_providers",
            "codex_percent_enabled",
        ),
        "reads or keeps local files only; nothing leaves the Mac and nothing runs",
    ),
    **dict.fromkeys(
        (
            "calendar_alerts_enabled",
            "calendar_lead_minutes",
            "reminder_alerts_enabled",
            "focus_sync_enabled",
            "completion_notification_enabled",
            "notification_policy_version",
            "battery_monitoring",
            "quota_alerts_enabled",
            "quota_alert_thresholds",
            "subagent_asks_alert",
            "silent_session_banner_enabled",
            "alert_burst",
            "completion_sweep_enabled",
            "ask_stale_after_hours",
            "ask_expire_after_days",
        ),
        "decides when JR-Bar alerts you on this Mac; the system still asks before it reads Calendar",
    ),
    **dict.fromkeys(
        (
            "escalation_tier",
            "escalation_tier_by_provider",
            "escalation_ramp_seconds",
            "escalation_menu_bar_seconds",
            "escalation_final_seconds",
            "call_quiet_mode",
            "meeting_quiet_mode",
            "away_quiet_mode",
            "dnd_dim_fraction",
            "dnd_focus_mode",
            "dnd_override_created_epoch",
            "dnd_override_mode",
            "dnd_override_until_epoch",
            "dnd_schedule_enabled",
            "dnd_schedule_end_minutes",
            "dnd_schedule_mode",
            "dnd_schedule_start_minutes",
            "focus_dim_rules",
            "focus_profile_rules",
            "focus_signal_policy",
            "signal_styles",
        ),
        "how loud or quiet JR-Bar is on this Mac; it grants no capability",
    ),
    **dict.fromkeys(
        (
            "active_scene_pack",
            "ambient_cues_disabled",
            "calibration_profiles",
            "dismissed_tips",
            "dot_extend_side",
            "dot_extend_style",
            "dot_role",
            "dot_role_include_completions",
            "devices",
            "devices_linked",
            "lid_closed_active_animation",
            "lid_closed_animation",
            "lid_open_active_animation",
            "lid_open_animation",
            "link_screen_bar_to_hardware",
            "linked_dot_clock_correction",
            "linked_dot_phase_trim_ms",
            "linked_dot_scale",
            "linked_follow_brightness",
            "linked_sync_tolerance_ms",
            "menu_bar_label_enabled",
            "milestone_odometer_enabled",
            "milestone_odometer_steps",
            "rainstick_idle_enabled",
            "rainstick_night_enabled",
            "screen_bar_follow_alcove",
            "screen_bar_hidden_apps",
            "session_open_preferences",
            "setup_screen_completed",
            "studio_library",
            "studio_program",
            "virtual_status_device_enabled",
            "virtual_status_device_wraps_menu_bar",
            "settings_schema_version",
            "idle_auto_off_enabled",
            "idle_auto_off_after_minutes",
        ),
        "a look, a layout or a remembered device; a device path must sit under /Volumes, "
        "and every LED write re-checks the path",
    ),
}

#: A key the document does not hold, told apart from a key holding ``None``.
_ABSENT: Final = object()


class SealState(str, Enum):
    #: The settings carry a seal this daemon checks.
    SEALED = "sealed"
    #: There is a key, but nothing is sealed under it yet: the daemon behaves as
    #: it did before sealing existed, until the app sends ``adopt_seal``.
    NOT_SEALED = "not_sealed"
    #: No key (a daemon the app did not start, or the Keychain said no).
    UNAVAILABLE = "unavailable"


@dataclass(frozen=True, slots=True)
class SealNotice:
    """A protected setting changed outside JR-Bar and was ignored."""

    keys: tuple[str, ...]
    at: float
    #: The ignored values are still held, so "Keep the change" can apply them.
    can_keep: bool

    def to_dict(self) -> dict[str, Any]:
        return {"keys": list(self.keys), "at": self.at, "can_keep": self.can_keep}


def _canonical(value: object) -> str:
    return json.dumps(
        value, sort_keys=True, separators=(",", ":"), ensure_ascii=True, allow_nan=False
    )


def _canonical_or_absent(value: object) -> str:
    return "absent" if value is _ABSENT else _canonical(value)


def seal_mac(key: bytes, document: Mapping[str, Any], covered: tuple[str, ...]) -> str:
    """The MAC over ``covered`` names and the values ``document`` holds for them."""
    names = sorted(set(covered))
    present = {name: document[name] for name in names if name in document}
    message = SEAL_CONTEXT + _canonical({"keys": names, "values": present}).encode("ascii")
    return hmac.new(key, message, hashlib.sha256).hexdigest()


def sealed_values(document: Mapping[str, Any]) -> dict[str, Any]:
    """The sealed keys a document holds (an absent key stays absent)."""
    return {name: document[name] for name in SEALED_KEYS if name in document}


@functools.cache
def _default_values() -> str:
    from .settings import AgentMonitorSettings

    return json.dumps(sealed_values(AgentMonitorSettings().to_dict()))


def _defaults() -> dict[str, Any]:
    """The sealed keys' default values (built once; a fresh dict each call)."""
    return json.loads(_default_values())


def _record_of(document: Mapping[str, Any]) -> Mapping[str, Any] | None:
    record = document.get(SEAL_FIELD)
    return record if isinstance(record, Mapping) else None


def _covered_of(record: Mapping[str, Any]) -> tuple[str, ...] | None:
    keys = record.get("keys")
    if not isinstance(keys, list) or not all(isinstance(name, str) for name in keys):
        return None
    return tuple(name for name in keys if name in SEALED_KEYS)


class SettingsSeal:
    """The daemon's side of the seal for one settings file."""

    def __init__(
        self,
        key: bytes | None,
        *,
        path: Path,
        previously_sealed: bool = False,
        log: Callable[[str], None] | None = None,
        clock: Callable[[], float] = time.time,
    ) -> None:
        if key is not None and (not isinstance(key, bytes) or len(key) != KEY_BYTES):
            raise ValueError("the seal key is 32 bytes")
        self._key = key
        self._path = Path(path).expanduser().absolute()
        self._log = log or (lambda _line: None)
        self._clock = clock
        self._lock = threading.RLock()
        if key is None:
            self._state = SealState.UNAVAILABLE
        elif previously_sealed:
            self._state = SealState.SEALED
        else:
            self._state = SealState.NOT_SEALED
        #: The protected values this daemon trusts, or None before it has seen
        #: a sealed file (then the defaults stand in).
        self._trusted: dict[str, Any] | None = None
        #: What the last foreign edit tried to set, for "Keep the change".
        self._candidate: dict[str, Any] = {}
        self._notice: tuple[tuple[str, ...], float] | None = None
        self._noticed: str | None = None
        self._snapshot_tried = False
        self._restored_notice = False
        self._needs_rewrite = False
        self._said_not_sealed = False
        #: Bumped whenever what the app is shown changes.
        self.revision = 0

    # -- facts -------------------------------------------------------------

    @property
    def path(self) -> Path:
        return self._path

    @property
    def state(self) -> SealState:
        with self._lock:
            return self._state

    @property
    def active(self) -> bool:
        with self._lock:
            return self._state is SealState.SEALED

    def notice(self) -> SealNotice | None:
        with self._lock:
            if self._notice is None:
                return None
            keys, at = self._notice
            return SealNotice(keys=keys, at=at, can_keep=bool(self._candidate))

    def sign(self, message: bytes) -> str | None:
        """HMAC-SHA256 of ``message`` under the seal key; None without a key.
        The companion files' seals (``companion_seal.py``) use the same key."""
        if self._key is None:
            return None
        return hmac.new(self._key, message, hashlib.sha256).hexdigest()

    def note_external(self, label: str, candidate: Any) -> None:
        """A file beside settings.json (a consent file) was changed outside
        JR-Bar and put back. It joins the same notice a protected setting would
        raise; ``candidate`` is what "Keep the change" would apply."""
        with self._lock:
            keys = tuple(sorted({*(self._notice[0] if self._notice else ()), label}))
            self._candidate[label] = candidate
            self._notice = (keys, self._clock())
            self.revision += 1

    def needs_rewrite(self) -> bool:
        """The file holds a foreign value: the next save should replace it."""
        with self._lock:
            return self._needs_rewrite

    def document(self) -> dict[str, Any]:
        """``settings.settings_seal`` in the ``settings`` frame."""
        with self._lock:
            notice = self.notice()
            return {
                "state": self._state.value,
                "changed": notice.to_dict() if notice is not None else None,
            }

    # -- reading a file ----------------------------------------------------

    def applies_to(self, target: Path) -> bool:
        try:
            return Path(target).expanduser().absolute() == self._path
        except (OSError, ValueError):
            return False

    def view(self, document: dict[str, Any], target: Path) -> dict[str, Any]:
        """``document`` as the daemon may use it: protected values the seal
        does not vouch for are replaced by the ones it holds."""
        if self._key is None or not self.applies_to(target):
            return document
        with self._lock:
            return self._view_locked(document)

    def inspect(self, document: dict[str, Any]) -> None:
        """Run the check for its effect alone (the once-a-second look)."""
        if self._key is None:
            return
        with self._lock:
            self._view_locked(document)

    def _view_locked(self, document: dict[str, Any]) -> dict[str, Any]:
        assert self._key is not None
        record = _record_of(document)
        covered = _covered_of(record) if record is not None else None
        valid = False
        if record is not None and covered is not None:
            claimed = record.get("mac")
            expected = seal_mac(self._key, document, covered)
            valid = isinstance(claimed, str) and hmac.compare_digest(
                expected.encode("ascii"), claimed.encode("utf-8", "replace")
            )
        if self._state is SealState.NOT_SEALED:
            if not valid:
                if not self._said_not_sealed:
                    self._said_not_sealed = True
                    self._log("core: settings not sealed yet; protected settings are taken from the file")
                return document
            # A seal this key made: an earlier run sealed the settings and the
            # app could not record it. Trust it from here on.
            self._state = SealState.SEALED
            self.revision += 1
        verified = set(covered) if valid and covered is not None else set()
        base = self._base_locked()
        accepted: dict[str, Any] = {}
        foreign: dict[str, Any] = {}
        for name in SEALED_KEYS:
            raw = document.get(name, _ABSENT)
            if name in verified:
                accepted[name] = raw
            elif _canonical_or_absent(raw) != _canonical_or_absent(base.get(name, _ABSENT)):
                foreign[name] = raw
        if valid:
            held = dict(base)
            for name, raw in accepted.items():
                if raw is _ABSENT:
                    held.pop(name, None)
                else:
                    held[name] = raw
            self._trusted = held
            base = held
            self._restore_notice(record)
        if foreign:
            self._note_foreign(document, foreign)
        else:
            # A seal that does not check out is replaced on the next save,
            # even when the values it should cover are the ones we hold.
            self._needs_rewrite = not valid
        if not foreign and valid:
            return document
        view = dict(document)
        for name in SEALED_KEYS:
            if name in accepted:
                continue
            if name in base:
                view[name] = base[name]
            else:
                view.pop(name, None)
        return view

    def _base_locked(self) -> dict[str, Any]:
        """What stands in for a protected value the file cannot vouch for: the
        values this run trusts, else the last sealed snapshot, else the defaults."""
        if self._trusted is None and not self._snapshot_tried:
            self._snapshot_tried = True
            self._trusted = self._read_snapshot()
        return self._trusted if self._trusted is not None else _defaults()

    def _snapshot_path(self) -> Path:
        return self._path.with_name(self._path.name + SNAPSHOT_SUFFIX)

    def _write_snapshot(self, held: Mapping[str, Any]) -> None:
        from .private_io import atomic_private_write

        assert self._key is not None
        names = sorted(SEALED_KEYS)
        record = {
            "v": SEAL_VERSION,
            "keys": names,
            "values": dict(held),
            "mac": seal_mac(self._key, held, tuple(names)),
        }
        try:
            atomic_private_write(
                self._snapshot_path(),
                json.dumps(record, indent=2, sort_keys=True, allow_nan=False) + "\n",
            )
        except (OSError, TypeError, ValueError):
            self._log("core: could not keep the sealed settings snapshot")

    def _read_snapshot(self) -> dict[str, Any] | None:
        """The last sealed values, if the snapshot still checks out."""
        from .private_io import read_private_text

        assert self._key is not None
        try:
            record = json.loads(read_private_text(self._snapshot_path(), max_bytes=1024 * 1024))
        except (OSError, ValueError):
            return None
        if not isinstance(record, dict) or not isinstance(record.get("values"), dict):
            return None
        covered = _covered_of(record)
        claimed = record.get("mac")
        if covered is None or not isinstance(claimed, str):
            return None
        expected = seal_mac(self._key, record["values"], covered)
        if not hmac.compare_digest(expected.encode("ascii"), claimed.encode("utf-8", "replace")):
            return None
        values = _defaults()
        for name in covered:
            if name in record["values"]:
                values[name] = record["values"][name]
            else:
                values.pop(name, None)
        return values

    def _restore_notice(self, record: Mapping[str, Any] | None) -> None:
        """A notice a former run saved in the seal: shown again after a restart."""
        if self._restored_notice or self._notice is not None or record is None:
            return
        self._restored_notice = True
        saved = record.get("notice")
        if not isinstance(saved, Mapping):
            return
        keys = saved.get("keys")
        at = saved.get("at")
        if not isinstance(keys, list) or isinstance(at, bool) or not isinstance(at, (int, float)):
            return
        names = tuple(sorted(name for name in keys if name in SEALED_KEYS))
        if not names:
            return
        self._notice = (names, float(at))
        rejected = self._read_rejected()
        self._candidate = {name: rejected[name] for name in names if name in rejected}
        self.revision += 1

    def _note_foreign(self, document: Mapping[str, Any], foreign: Mapping[str, Any]) -> None:
        digest = hashlib.sha256(
            _canonical({name: _canonical_or_absent(value) for name, value in foreign.items()}).encode("ascii")
        ).hexdigest()
        self._needs_rewrite = True
        if digest == self._noticed:
            return
        self._noticed = digest
        self._log("core: settings.json changed a protected setting outside JR-Bar; ignored")
        keys = tuple(sorted(set(foreign) | set(self._notice[0] if self._notice else ())))
        self._candidate.update({name: value for name, value in foreign.items() if value is not _ABSENT})
        self._notice = (keys, self._clock())
        self.revision += 1
        self._write_rejected(document)

    def _rejected_path(self) -> Path:
        return self._path.with_name(self._path.name + REJECTED_SUFFIX)

    def _write_rejected(self, document: Mapping[str, Any]) -> None:
        from .private_io import atomic_private_write

        try:
            atomic_private_write(
                self._rejected_path(),
                json.dumps(document, indent=2, sort_keys=True, allow_nan=False) + "\n",
                full_sync=False,
            )
        except (OSError, TypeError, ValueError):
            self._log("core: could not keep the ignored settings.json as settings.json.rejected")

    def _read_rejected(self) -> dict[str, Any]:
        from .private_io import read_private_text

        try:
            data = json.loads(read_private_text(self._rejected_path(), max_bytes=4 * 1024 * 1024))
        except (OSError, ValueError):
            return {}
        return sealed_values(data) if isinstance(data, dict) else {}

    # -- writing a file ----------------------------------------------------

    def stamp(self, document: dict[str, Any], encoded: Mapping[str, Any]) -> None:
        """Seal the document about to be written. ``encoded`` is what the
        settings the daemon holds encode to; the protected values written are
        exactly those, so nothing a foreign edit left in the file is blessed."""
        if self._key is None:
            return
        with self._lock:
            if self._state is not SealState.SEALED:
                return
            held: dict[str, Any] = {}
            for name in SEALED_KEYS:
                if name in encoded:
                    document[name] = encoded[name]
                    held[name] = encoded[name]
                else:
                    document.pop(name, None)
            record: dict[str, Any] = {
                "v": SEAL_VERSION,
                "keys": sorted(SEALED_KEYS),
                "mac": seal_mac(self._key, document, SEALED_KEYS),
            }
            if self._notice is not None:
                record["notice"] = {"keys": list(self._notice[0]), "at": self._notice[1]}
            document[SEAL_FIELD] = record
            self._trusted = held
            self._needs_rewrite = False
            self._write_snapshot(held)

    # -- the app's commands ------------------------------------------------

    def begin_adopt(self, encoded: Mapping[str, Any]) -> tuple[Any, ...]:
        """Seal what the daemon holds now. Returns what ``restore`` needs if the
        write that must follow fails."""
        if self._key is None:
            raise SealUnavailableError
        with self._lock:
            before = (
                self._state,
                self._trusted,
                dict(self._candidate),
                self._notice,
                self._noticed,
                self._needs_rewrite,
            )
            self._state = SealState.SEALED
            self._trusted = sealed_values(encoded)
            self._candidate = {}
            self._notice = None
            self._needs_rewrite = False
            self.revision += 1
            return before

    def restore(self, before: tuple[Any, ...]) -> None:
        with self._lock:
            (
                self._state,
                self._trusted,
                self._candidate,
                self._notice,
                self._noticed,
                self._needs_rewrite,
            ) = before
            self.revision += 1

    def candidate(self) -> dict[str, Any]:
        """The ignored values "Keep the change" would apply."""
        with self._lock:
            if self._notice is None:
                return {}
            return {name: self._candidate[name] for name in self._notice[0] if name in self._candidate}


class SealUnavailableError(RuntimeError):
    """The daemon has no seal key."""


__all__ = [
    "KEY_BYTES",
    "REJECTED_SUFFIX",
    "SEALED_KEYS",
    "SEAL_FIELD",
    "UNSEALED_PRIVILEGED",
    "SealNotice",
    "SealState",
    "SealUnavailableError",
    "SettingsSeal",
    "seal_mac",
    "sealed_values",
]
