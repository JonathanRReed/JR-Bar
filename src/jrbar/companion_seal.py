"""Sealed consent files: a hand edit of a consent file grants nothing.

``settings.json`` is sealed (``settings_seal.py``). Three more files hold a
person's consent for something the daemon then does, and any process running
as you can write them just the same:

- ``provider-usage.json``: which provider's usage read is on (the consent
  version, source and time per provider);
- ``browser-consent.json``: which browser profiles, sites and cookie or
  storage fields JR-Bar may read for a provider;
- ``integrations.json``: the optional integrations, and the folder and device
  they read.

They are sealed by one mechanism. For each file the daemon computes an HMAC
(the settings seal's Keychain key) over just the consent in it, and keeps that
value in the sealed setting ``companion_seals`` of ``settings.json``, so the
only way to change it is the way a protected setting changes. A copy of the
sealed consent is kept beside each file as ``<file>.sealed``.

Every read of a file in the daemon goes through ``guard``. If the consent in
the file does not hash to the sealed value:

- one that only takes something away (a switch turned off, a site dropped) is
  accepted and sealed, since the person withdrew it;
- anything that grants more is not used. The file is put back from the sealed
  copy (or to nothing granted, if there is none), what was found is kept as
  ``<file>.rejected``, and the settings banner says it was ignored, with the
  same Keep the change and Discard buttons a protected setting has.

Only the daemon seals a file: its own saves call ``record``. A process that
has no key (the ``jrbar`` command line, a test) guards and records nothing, so
it reads and writes as it always did, and the daemon treats what it wrote as
any other outside edit. The first time the daemon sees a file it has no seal
for, it adopts what is there.
"""

from __future__ import annotations

import json
import re
import threading
import time
from collections.abc import Callable, Mapping
from dataclasses import dataclass
from pathlib import Path
from typing import Any, Final

from .settings_seal import SealState, SettingsSeal, _canonical

SNAPSHOT_SUFFIX: Final = ".sealed"
REJECTED_SUFFIX: Final = ".rejected"
CONTEXT: Final = b"jrbar-companion-seal-v1\n"
_HEX: Final = re.compile(r"[0-9a-f]{64}\Z")

PROVIDER_USAGE: Final = "provider_usage"
BROWSER_CONSENT: Final = "browser_consent"
INTEGRATIONS: Final = "integrations"

_DEFAULT_ROW: Final = "default"
_SEP: Final = "\x1f"


def normalize_companion_seals(raw: object) -> dict[str, str]:
    """``companion_seals``: only known file names, only 64-hex digests."""
    if not isinstance(raw, Mapping):
        return {}
    return {
        name: value
        for name in (PROVIDER_USAGE, BROWSER_CONSENT, INTEGRATIONS)
        if isinstance(value := raw.get(name), str) and _HEX.fullmatch(value)
    }


# -- what each file's consent is ------------------------------------------


def _usage_rows(document: Mapping[str, Any]) -> dict[str, list[Any]]:
    rows: dict[str, list[Any]] = {}
    providers = document.get("providers")
    if not isinstance(providers, list):
        return rows
    for row in providers:
        if not isinstance(row, dict) or not isinstance(row.get("provider_id"), str):
            continue
        version = row.get("usage_consent_version", 0)
        if type(version) is not int or version <= 0:
            continue
        instance = row.get("source_instance_id", _DEFAULT_ROW)
        if not isinstance(instance, str):
            continue
        rows[f"{row['provider_id']}{_SEP}{instance}"] = [
            version,
            row.get("usage_consent_source"),
            row.get("usage_consented_at"),
        ]
    return rows


def _usage_project(document: Mapping[str, Any]) -> dict[str, Any]:
    return {"rows": _usage_rows(document)}


def _usage_merge(document: dict[str, Any], projection: Mapping[str, Any]) -> dict[str, Any]:
    wanted = dict(projection.get("rows", {}))
    providers = document.get("providers")
    providers = [row for row in providers if isinstance(row, dict)] if isinstance(providers, list) else []
    for row in providers:
        provider = row.get("provider_id")
        instance = row.get("source_instance_id", _DEFAULT_ROW)
        held = wanted.pop(f"{provider}{_SEP}{instance}", None)
        row["usage_consent_version"], row["usage_consent_source"], row["usage_consented_at"] = (
            held if held is not None else [0, None, None]
        )
    for identity, held in wanted.items():
        provider, instance = identity.split(_SEP, 1)
        providers.append(
            {
                "provider_id": provider,
                "source_instance_id": instance,
                "usage_consent_version": held[0],
                "usage_consent_source": held[1],
                "usage_consented_at": held[2],
            }
        )
    document["providers"] = providers
    return document


def _usage_grants(old: Mapping[str, Any], new: Mapping[str, Any]) -> bool:
    before = old.get("rows", {})
    return any(
        identity not in before or held[0] > before[identity][0] for identity, held in new.get("rows", {}).items()
    )


_BROWSER_KEYS: Final = (
    "provider_id",
    "source_instance_id",
    "browser",
    "profile",
    "domains",
    "fields",
    "background_repair",
    "granted_at",
)


def _browser_project(document: Mapping[str, Any]) -> list[dict[str, Any]]:
    rows = document.get("consents")
    if not isinstance(rows, list):
        return []
    kept = [{key: row.get(key) for key in _BROWSER_KEYS if key in row} for row in rows[:256] if isinstance(row, dict)]
    return sorted(kept, key=_canonical)


def _browser_merge(document: dict[str, Any], projection: list[dict[str, Any]]) -> dict[str, Any]:
    document["consents"] = [dict(row) for row in projection]
    return document


def _browser_identity(row: Mapping[str, Any]) -> tuple[Any, ...]:
    return (
        row.get("provider_id"),
        row.get("source_instance_id", _DEFAULT_ROW),
        row.get("browser"),
        row.get("profile"),
    )


def _browser_grants(old: list[dict[str, Any]], new: list[dict[str, Any]]) -> bool:
    before = {_browser_identity(row): row for row in old}
    for row in new:
        held = before.get(_browser_identity(row))
        if held is None:
            return True
        for key in ("domains", "fields"):
            if not isinstance(row.get(key), list) or not isinstance(held.get(key), list):
                return True
            if set(map(str, row[key])) - set(map(str, held[key])):
                return True
        if row.get("background_repair") is True and held.get("background_repair") is not True:
            return True
    return False


_INTEGRATION_FLAGS: Final = (
    "t3code_enabled",
    "t3code_activity_statistics_enabled",
    "creator_micro_enabled",
)
_INTEGRATION_TEXTS: Final = ("t3code_base_dir", "t3code_environment_id", "creator_micro_device_serial")


def _integrations_project(document: Mapping[str, Any]) -> dict[str, Any]:
    projection: dict[str, Any] = {key: document.get(key) is True for key in _INTEGRATION_FLAGS}
    for key in _INTEGRATION_TEXTS:
        value = document.get(key)
        projection[key] = value if isinstance(value, str) and value else None
    return projection


def _integrations_merge(document: dict[str, Any], projection: Mapping[str, Any]) -> dict[str, Any]:
    document.update(projection)
    return document


def _integrations_grants(old: Mapping[str, Any], new: Mapping[str, Any]) -> bool:
    if any(new.get(key) is True and old.get(key) is not True for key in _INTEGRATION_FLAGS):
        return True
    return any(new.get(key) is not None and new.get(key) != old.get(key) for key in _INTEGRATION_TEXTS)


@dataclass(frozen=True, slots=True)
class CompanionSpec:
    name: str
    #: How the settings banner names it.
    label: str
    project: Callable[[Mapping[str, Any]], Any]
    merge: Callable[[dict[str, Any], Any], dict[str, Any]]
    #: True when ``new`` consents to something ``old`` did not.
    grants: Callable[[Any, Any], bool]
    #: Nothing consented.
    empty: Callable[[], Any]


SPECS: Final[dict[str, CompanionSpec]] = {
    PROVIDER_USAGE: CompanionSpec(
        PROVIDER_USAGE,
        "provider_usage_consent",
        _usage_project,
        _usage_merge,
        _usage_grants,
        lambda: {"rows": {}},
    ),
    BROWSER_CONSENT: CompanionSpec(
        BROWSER_CONSENT,
        "browser_consent",
        _browser_project,
        _browser_merge,
        _browser_grants,
        list,
    ),
    INTEGRATIONS: CompanionSpec(
        INTEGRATIONS,
        "integrations",
        _integrations_project,
        _integrations_merge,
        _integrations_grants,
        lambda: _integrations_project({}),
    ),
}


# -- the seals ---------------------------------------------------------------


class CompanionSeals:
    """The daemon's seals for the consent files beside ``settings.json``."""

    def __init__(
        self,
        seal: SettingsSeal,
        paths: Mapping[str, Path],
        ledger_source: Callable[[], Mapping[str, str] | None],
        *,
        log: Callable[[str], None] | None = None,
        clock: Callable[[], float] = time.time,
    ) -> None:
        self._seal = seal
        self._paths = {name: Path(path).expanduser().absolute() for name, path in paths.items()}
        self._ledger_source = ledger_source
        self._log = log or (lambda _line: None)
        self._clock = clock
        self._lock = threading.RLock()
        #: Seals made since the settings last took the ledger in.
        self._pending: dict[str, str] = {}
        #: What each ignored change tried to set, for Keep the change.
        self._candidates: dict[str, Any] = {}
        self._signatures: dict[str, tuple[int, int] | None] = {}

    @property
    def labels(self) -> dict[str, str]:
        return {spec.label: name for name, spec in SPECS.items()}

    def _enforcing(self) -> bool:
        return self._seal.state is SealState.SEALED and self._ledger_source() is not None

    def _digest(self, name: str, projection: Any) -> str | None:
        message = CONTEXT + name.encode("ascii") + b"\n" + _canonical(projection).encode("ascii")
        return self._seal.sign(message)

    def ledger(self) -> dict[str, str]:
        """The seals now: the ones in the settings, then the newer ones."""
        with self._lock:
            return {**(self._ledger_source() or {}), **self._pending}

    def settled(self, ledger: Mapping[str, str]) -> None:
        """The settings hold ``ledger`` now."""
        with self._lock:
            for name, digest in ledger.items():
                if self._pending.get(name) == digest:
                    del self._pending[name]

    def _path_for(self, name: str) -> Path | None:
        return self._paths.get(name)

    def applies_to(self, name: str, target: Path) -> bool:
        path = self._path_for(name)
        try:
            return path is not None and Path(target).expanduser().absolute() == path
        except (OSError, ValueError):
            return False

    # -- reading ---------------------------------------------------------------

    def guard(self, name: str, target: Path, document: dict[str, Any]) -> dict[str, Any]:
        """``document`` as the daemon may use it."""
        spec = SPECS[name]
        if not self.applies_to(name, target) or not self._enforcing():
            return document
        with self._lock:
            projection = spec.project(document)
            digest = self._digest(name, projection)
            if digest is None:
                return document
            sealed = self.ledger().get(name)
            if sealed is None:
                # No seal yet (the first start after an upgrade): adopt what is here.
                self._seal_projection(name, projection, digest)
                return document
            if digest == sealed:
                return document
            before = self._read_snapshot(name, sealed)
            if before is None:
                before = spec.empty()
            if not spec.grants(before, projection):
                self._log(f"core: {self._paths[name].name} consent was withdrawn outside JR-Bar; accepted")
                self._seal_projection(name, projection, digest)
                return document
            repaired = spec.merge(json.loads(json.dumps(document)), before)
            self._log(f"core: {self._paths[name].name} changed outside JR-Bar; ignored")
            self._write_rejected(name, document)
            self._write_repaired(name, repaired)
            self._candidates[spec.label] = (name, projection)
            self._seal.note_external(spec.label, {"companion": name})
            return repaired

    def inspect_all(self) -> None:
        """The once-a-second look: read each file whose size or time changed."""
        if not self._enforcing():
            return
        from .private_io import read_private_text

        for name, path in self._paths.items():
            try:
                info = path.stat()
                signature: tuple[int, int] | None = (info.st_mtime_ns, info.st_size)
            except OSError:
                signature = None
            if self._signatures.get(name, ()) == signature:
                continue
            self._signatures[name] = signature
            if signature is None:
                continue
            try:
                document = json.loads(read_private_text(path, max_bytes=4 * 1024 * 1024))
            except (OSError, ValueError):
                continue
            if isinstance(document, dict):
                self.guard(name, path, document)

    # -- writing ---------------------------------------------------------------

    def record(self, name: str, target: Path, document: Mapping[str, Any]) -> None:
        """The daemon wrote ``document`` as ``target``: seal it."""
        if not self.applies_to(name, target) or self._seal.state is SealState.UNAVAILABLE:
            return
        with self._lock:
            projection = SPECS[name].project(document)
            digest = self._digest(name, projection)
            if digest is not None:
                self._seal_projection(name, projection, digest)

    def adopt_all(self) -> None:
        """Seal each file as it is now (the settings are being sealed, or reset)."""
        from .private_io import read_private_text

        with self._lock:
            self._candidates.clear()
            for name, path in self._paths.items():
                try:
                    document = json.loads(read_private_text(path, max_bytes=4 * 1024 * 1024))
                except (OSError, ValueError):
                    document = None
                self.record(name, path, document if isinstance(document, dict) else {})

    def keep(self, label: str) -> None:
        """A person said yes to an ignored change: take it and seal it."""
        with self._lock:
            held = self._candidates.pop(label, None)
            if held is None:
                return
            name, projection = held
            spec = SPECS[name]
            digest = self._digest(name, projection)
            path = self._paths[name]
            if digest is None:
                return
            from .private_io import read_private_text

            try:
                document = json.loads(read_private_text(path, max_bytes=4 * 1024 * 1024))
            except (OSError, ValueError):
                document = {}
            merged = spec.merge(document if isinstance(document, dict) else {}, projection)
            self._write_json(path, merged)
            self._seal_projection(name, projection, digest)

    # -- the files -------------------------------------------------------------

    def _seal_projection(self, name: str, projection: Any, digest: str) -> None:
        self._pending[name] = digest
        self._write_snapshot(name, projection, digest)

    def _snapshot_path(self, name: str) -> Path:
        path = self._paths[name]
        return path.with_name(path.name + SNAPSHOT_SUFFIX)

    def _write_snapshot(self, name: str, projection: Any, digest: str) -> None:
        self._write_json(self._snapshot_path(name), {"v": 1, "name": name, "projection": projection, "mac": digest})

    def _read_snapshot(self, name: str, sealed: str) -> Any:
        """The sealed consent, if the copy still hashes to the sealed value."""
        from .private_io import read_private_text

        try:
            record = json.loads(read_private_text(self._snapshot_path(name), max_bytes=4 * 1024 * 1024))
        except (OSError, ValueError):
            return None
        if not isinstance(record, dict) or "projection" not in record:
            return None
        projection = record["projection"]
        if self._digest(name, projection) != sealed:
            return None
        return projection

    def _write_rejected(self, name: str, document: Mapping[str, Any]) -> None:
        path = self._paths[name]
        self._write_json(path.with_name(path.name + REJECTED_SUFFIX), document)

    def _write_repaired(self, name: str, document: Mapping[str, Any]) -> None:
        self._write_json(self._paths[name], document)

    def _write_json(self, path: Path, document: Mapping[str, Any]) -> None:
        from .private_io import atomic_private_write

        try:
            atomic_private_write(
                path,
                json.dumps(document, ensure_ascii=False, separators=(",", ":"), sort_keys=True),
                full_sync=False,
            )
        except (OSError, TypeError, ValueError):
            self._log(f"core: could not write {path.name}")


# -- the process-wide seals --------------------------------------------------

_INSTALLED: CompanionSeals | None = None


def install_companion_seals(seals: CompanionSeals | None) -> None:
    """Install (or with None, remove) this process's seals. Without them
    every guard and record below does nothing."""
    global _INSTALLED
    _INSTALLED = seals


def installed_companion_seals() -> CompanionSeals | None:
    return _INSTALLED


def guard_companion(name: str, target: Path, document: dict[str, Any]) -> dict[str, Any]:
    seals = _INSTALLED
    if seals is None:
        return document
    try:
        return seals.guard(name, target, document)
    except Exception:
        # A seal that cannot be checked must not become a way in: nothing consented.
        import logging

        logging.getLogger(__name__).warning("companion seal check failed; consent ignored", exc_info=True)
        spec = SPECS[name]
        if not seals.applies_to(name, target):
            return document
        return spec.merge(json.loads(json.dumps(document)), spec.empty())


def record_companion(name: str, target: Path, document: Mapping[str, Any]) -> None:
    seals = _INSTALLED
    if seals is not None:
        try:
            seals.record(name, target, document)
        except Exception:
            import logging

            logging.getLogger(__name__).warning("companion seal record failed", exc_info=True)


__all__ = [
    "BROWSER_CONSENT",
    "INTEGRATIONS",
    "PROVIDER_USAGE",
    "SPECS",
    "CompanionSeals",
    "guard_companion",
    "install_companion_seals",
    "installed_companion_seals",
    "normalize_companion_seals",
    "record_companion",
]
