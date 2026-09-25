"""Which agent CLI versions JR-Bar's hooks were verified against.

``resources/provider_hook_compatibility.json`` records, per provider, the
CLI binary and version ranges with a status, the shape T3 Code uses for
its harness compatibility (MIT, reimplemented): ``supported``,
``graceful``, ``unsupported``, ``broken`` or ``unknown``. The seed holds
only what ``scripts/verify_providers_live.py`` actually ran; a version
outside every range is ``unknown``, and one newer than the last verified
is a neutral note ("newer than verified"), never a warning, because a new
CLI release usually keeps its hooks.

``jrbar hooks doctor`` reads each CLI's version and adds it, with its
compatibility, to every provider's row. A node CLI (Pi, Gemini CLI) is read
from its own ``package.json`` without running it; anything else answers
``--version`` in two seconds at most. Answers, and failed reads for a day,
are cached by the binary's real path and modification time.
"""

from __future__ import annotations

import json
import os
import re
import shutil
import subprocess
import time
from collections.abc import Callable, Iterable
from concurrent.futures import ThreadPoolExecutor
from dataclasses import dataclass
from importlib import resources
from pathlib import Path
from typing import Any

STATUSES = ("supported", "graceful", "unsupported", "broken", "unknown")
VERSION_TIMEOUT_SECONDS = 2.0
_VERSION = re.compile(r"(\d+)\.(\d+)(?:\.(\d+))?(?:\.(\d+))?")
_COMPARATOR = re.compile(r"(>=|<=|>|<|=)?\s*v?(\d+(?:\.\d+){0,3})")
_CACHE_NAME = "provider-cli-versions.json"
#: A binary whose version could not be read is asked again after a day, or
#: at once when it changes (a new modification time).
FAILED_READ_RETRY_SECONDS = 86_400.0
_PACKAGE_JSON_MAX_BYTES = 256 * 1024
#: Where agent CLIs live on a Mac besides the daemon's own PATH (a login
#: item's PATH is short).
_EXTRA_BIN_DIRS = (
    "~/.local/bin",
    "/opt/homebrew/bin",
    "/usr/local/bin",
    "~/.bun/bin",
    "~/.npm-global/bin",
    "~/.cargo/bin",
)


def parse_version(text: object) -> tuple[int, ...] | None:
    """The first dotted version in ``text``: "2.1.280 (Claude Code)",
    "codex-cli 0.153.4", "v0.73.1" -> a tuple of up to four numbers."""
    if not isinstance(text, str):
        return None
    match = _VERSION.search(text)
    if match is None:
        return None
    return tuple(int(part) for part in match.groups() if part is not None)


def _padded(version: tuple[int, ...]) -> tuple[int, ...]:
    return tuple(version) + (0,) * (4 - len(version))


def range_matches(expression: str, version: tuple[int, ...]) -> bool:
    """``">=2.1.111 <2.1.280"`` style: every comparator must hold; ``||``
    separates alternatives. A malformed range matches nothing."""
    for alternative in expression.split("||"):
        comparators = _COMPARATOR.findall(alternative)
        leftover = _COMPARATOR.sub("", alternative).strip()
        if not comparators or leftover:
            continue
        target = _padded(version)
        held = True
        for operator, raw in comparators:
            bound = _padded(tuple(int(part) for part in raw.split(".")))
            if operator in ("", "="):
                held = target == bound
            elif operator == ">=":
                held = target >= bound
            elif operator == "<=":
                held = target <= bound
            elif operator == ">":
                held = target > bound
            else:
                held = target < bound
            if not held:
                break
        if held:
            return True
    return False


@dataclass(frozen=True, slots=True)
class CompatibilityRecord:
    provider: str
    binary: str | None
    recommended: str | None
    ranges: tuple[tuple[str, str], ...]


@dataclass(frozen=True, slots=True)
class Compatibility:
    status: str
    note: str | None
    verified: str | None

    def to_dict(self) -> dict[str, Any]:
        return {"status": self.status, "note": self.note, "verified": self.verified}


def load_compatibility_manifest(text: str | None = None) -> dict[str, CompatibilityRecord]:
    """Records by provider from the packaged manifest (or ``text``)."""
    if text is None:
        text = resources.files("jrbar.resources").joinpath("provider_hook_compatibility.json").read_text(
            encoding="utf-8"
        )
    document = json.loads(text)
    if not isinstance(document, dict) or document.get("schemaVersion") != 1:
        raise ValueError("unsupported provider hook compatibility manifest")
    records: dict[str, CompatibilityRecord] = {}
    for item in document.get("providers") or []:
        if not isinstance(item, dict) or not isinstance(item.get("provider"), str):
            raise ValueError("invalid provider hook compatibility entry")
        ranges = []
        for entry in item.get("ranges") or []:
            status = entry.get("status") if isinstance(entry, dict) else None
            expression = entry.get("range") if isinstance(entry, dict) else None
            if status not in STATUSES or not isinstance(expression, str):
                raise ValueError(f"invalid range for {item['provider']}")
            ranges.append((expression, status))
        binary = item.get("binary")
        recommended = item.get("recommended")
        records[item["provider"]] = CompatibilityRecord(
            item["provider"],
            binary if isinstance(binary, str) and binary else None,
            recommended if isinstance(recommended, str) and recommended else None,
            tuple(ranges),
        )
    return records


def _verified_versions(record: CompatibilityRecord) -> list[tuple[int, ...]]:
    found = []
    for expression, status in record.ranges:
        if status != "supported":
            continue
        for _operator, raw in _COMPARATOR.findall(expression):
            found.append(tuple(int(part) for part in raw.split(".")))
    if record.recommended and parse_version(record.recommended):
        found.append(parse_version(record.recommended))
    return found


def classify(record: CompatibilityRecord | None, version_text: str | None) -> Compatibility:
    """The status of one installed version, with a note in words."""
    verified = record.recommended if record is not None else None
    if record is None or not record.ranges:
        return Compatibility("unknown", "no verified version on record", verified)
    version = parse_version(version_text)
    if version is None:
        return Compatibility("unknown", "version not read", verified)
    for expression, status in record.ranges:
        if range_matches(expression, version):
            note = {
                "supported": "verified",
                "graceful": "works with limits",
                "unsupported": "older than JR-Bar supports",
                "broken": "known not to work",
                "unknown": None,
            }[status]
            return Compatibility(status, note, verified)
    known = _verified_versions(record)
    if known and _padded(version) > max(_padded(item) for item in known):
        return Compatibility("unknown", f"newer than verified ({verified})", verified)
    if known and _padded(version) < min(_padded(item) for item in known):
        return Compatibility("unknown", f"older than verified ({verified})", verified)
    return Compatibility("unknown", "not a verified version", verified)


# --- reading the installed version ----------------------------------------


def _search_path(env: dict[str, str] | None = None) -> str:
    environment = os.environ if env is None else env
    parts = [part for part in environment.get("PATH", "").split(os.pathsep) if part]
    for extra in _EXTRA_BIN_DIRS:
        expanded = os.path.expanduser(extra)
        if expanded not in parts:
            parts.append(expanded)
    return os.pathsep.join(parts)


def locate_binary(binary: str, env: dict[str, str] | None = None) -> str | None:
    return shutil.which(binary, path=_search_path(env))


def _default_runner(argv: list[str]) -> str | None:
    try:
        completed = subprocess.run(
            argv,
            capture_output=True,
            text=True,
            timeout=VERSION_TIMEOUT_SECONDS,
            stdin=subprocess.DEVNULL,
            check=False,
        )
    except (OSError, subprocess.TimeoutExpired, ValueError):
        return None
    output = (completed.stdout or completed.stderr or "").strip()
    return output.splitlines()[0][:200] if output else None


def node_package_version(real: str) -> str | None:
    """A node CLI's version from its own ``package.json``, without running it.

    ``pi --version`` with no terminal prints nothing and never exits, and
    ``gemini --version`` can take seconds on a busy Mac. When the binary's
    real path sits inside ``node_modules/<package>/`` (or
    ``node_modules/@scope/<package>/``) and that package's ``bin`` names
    this very file, the package's ``version`` is the CLI's version.
    """
    parts = Path(real).parts
    if "node_modules" not in parts:
        return None
    index = len(parts) - 1 - parts[::-1].index("node_modules")
    rest = parts[index + 1:]
    depth = 2 if rest and rest[0].startswith("@") else 1
    if len(rest) <= depth:
        return None
    package_dir = Path(*parts[: index + 1 + depth])
    manifest = package_dir / "package.json"
    try:
        if manifest.stat().st_size > _PACKAGE_JSON_MAX_BYTES:
            return None
        data = json.loads(manifest.read_text(encoding="utf-8"))
    except (OSError, UnicodeError, ValueError):
        return None
    if not isinstance(data, dict):
        return None
    bins = data.get("bin")
    targets = list(bins.values()) if isinstance(bins, dict) else [bins]
    relative = Path(*rest[depth:]).as_posix()
    if not any(isinstance(item, str) and os.path.normpath(item) == relative for item in targets):
        return None
    version = data.get("version")
    return version if isinstance(version, str) and parse_version(version) else None


class VersionCache:
    """Version answers keyed by the binary's real path and mtime, saved
    under the state directory so a second doctor run is instant. A failed
    read is kept too, so opening the Agents settings again doesn't start a
    slow CLI again; it is retried after a day or when the binary changes."""

    def __init__(self, path: Path | None) -> None:
        self.path = path
        self._entries: dict[str, dict[str, Any]] = {}
        if path is not None:
            try:
                raw = json.loads(path.read_text(encoding="utf-8"))
                if isinstance(raw, dict):
                    self._entries = {key: value for key, value in raw.items() if isinstance(value, dict)}
            except (OSError, ValueError):
                self._entries = {}

    def get(self, real: str, mtime: float) -> str | None:
        entry = self._entries.get(real)
        if entry and entry.get("mtime") == mtime and isinstance(entry.get("version"), str):
            return entry["version"]
        return None

    def lookup(self, real: str, mtime: float, now: float) -> tuple[bool, str | None]:
        """``(True, version)`` for a cached answer, ``(True, None)`` for a
        recent failed read, ``(False, None)`` when the binary must be read."""
        entry = self._entries.get(real)
        if not entry or entry.get("mtime") != mtime:
            return False, None
        if isinstance(entry.get("version"), str):
            return True, entry["version"]
        failed_at = entry.get("failed_at")
        if isinstance(failed_at, (int, float)) and 0 <= now - failed_at < FAILED_READ_RETRY_SECONDS:
            return True, None
        return False, None

    def put(self, real: str, mtime: float, version: str) -> None:
        self._entries[real] = {"mtime": mtime, "version": version}

    def put_failure(self, real: str, mtime: float, now: float) -> None:
        self._entries[real] = {"mtime": mtime, "version": None, "failed_at": now}

    def save(self) -> None:
        if self.path is None:
            return
        try:
            from .private_io import atomic_private_write

            atomic_private_write(self.path, json.dumps(self._entries, sort_keys=True))
        except Exception:
            pass


def installed_versions(
    binaries: dict[str, str],
    *,
    cache: VersionCache | None = None,
    runner: Callable[[list[str]], str | None] = _default_runner,
    locate: Callable[[str], str | None] = locate_binary,
    package_version: Callable[[str], str | None] = node_package_version,
    clock: Callable[[], float] = time.time,
) -> dict[str, dict[str, Any]]:
    """provider -> ``{"path", "version"}`` for each binary found on this
    Mac (``version`` None when nothing usable could be read)."""
    found: dict[str, tuple[str, str, float]] = {}
    for provider, binary in binaries.items():
        path = locate(binary)
        if path is None:
            continue
        try:
            real = os.path.realpath(path)
            mtime = os.stat(real).st_mtime
        except OSError:
            continue
        found[provider] = (path, real, mtime)
    now = clock()
    results: dict[str, dict[str, Any]] = {}
    pending: list[str] = []
    changed = False
    for provider, (path, real, mtime) in found.items():
        hit, cached = cache.lookup(real, mtime, now) if cache is not None else (False, None)
        if hit:
            results[provider] = {"path": path, "version": cached}
            continue
        packaged = package_version(real)
        if packaged is not None:
            results[provider] = {"path": path, "version": packaged}
            if cache is not None:
                cache.put(real, mtime, packaged)
                changed = True
            continue
        pending.append(provider)
    if pending:
        with ThreadPoolExecutor(max_workers=min(8, len(pending))) as pool:
            answers = dict(zip(pending, pool.map(lambda item: runner([found[item][0], "--version"]), pending)))
        for provider in pending:
            path, real, mtime = found[provider]
            answer = answers.get(provider)
            version = answer if answer and parse_version(answer) else None
            if cache is not None:
                if version is not None:
                    cache.put(real, mtime, version)
                else:
                    cache.put_failure(real, mtime, now)
                changed = True
            results[provider] = {"path": path, "version": version}
    if changed and cache is not None:
        cache.save()
    return results


def compatibility_rows(
    providers: Iterable[str],
    *,
    state_dir: Path | None = None,
    runner: Callable[[list[str]], str | None] = _default_runner,
    locate: Callable[[str], str | None] = locate_binary,
    manifest: dict[str, CompatibilityRecord] | None = None,
) -> dict[str, dict[str, Any]]:
    """provider -> ``{"version", "compatibility"}`` for the doctor."""
    records = load_compatibility_manifest() if manifest is None else manifest
    wanted = list(providers)
    binaries = {
        provider: records[provider].binary
        for provider in wanted
        if provider in records and records[provider].binary
    }
    cache = VersionCache(None if state_dir is None else state_dir / _CACHE_NAME)
    versions = installed_versions(binaries, cache=cache, runner=runner, locate=locate)
    rows: dict[str, dict[str, Any]] = {}
    for provider in wanted:
        seen = versions.get(provider)
        version_text = seen["version"] if seen else None
        version = parse_version(version_text)
        compatibility = classify(records.get(provider), version_text)
        if seen is None:
            compatibility = Compatibility("unknown", "CLI not found on this Mac", compatibility.verified)
        rows[provider] = {
            "version": ".".join(str(part) for part in version) if version else None,
            "compatibility": compatibility.to_dict(),
        }
    return rows


__all__ = [
    "STATUSES",
    "Compatibility",
    "CompatibilityRecord",
    "VersionCache",
    "classify",
    "compatibility_rows",
    "installed_versions",
    "load_compatibility_manifest",
    "locate_binary",
    "node_package_version",
    "parse_version",
    "range_matches",
]
