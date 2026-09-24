"""Where each agent keeps its local data, for every account on this Mac.

Claude Code and Codex each let a person move their data: ``CLAUDE_CONFIG_DIR``
and ``CODEX_HOME`` point the CLI somewhere other than ``~/.claude`` and
``~/.codex``, and tools such as claude-swap keep one home per account. The
usage scans used to read only the default folders, so anyone with a second
home saw totals that were missing whole accounts.

This module answers one question per provider: which folders hold that
provider's data. The answer is the environment's home first, then the
default, then the absolute paths the person listed under
``provider_extra_homes``. Two entries that resolve to the same real folder
(a symlink, a trailing slash, a relative spelling of the same place) count
once, so a symlinked duplicate never doubles a total. Folders that do not
exist are left out.

OpenCode keeps its data under the XDG data root
(``$XDG_DATA_HOME/opencode``, else ``~/.local/share/opencode``), which the
OpenCode collector and the usage graph both read from here.

T3 Code's account-home handling (#11485) and CodexBar's claude-swap fix
(#2954), both MIT, showed the shape; this is our own implementation.
"""

from __future__ import annotations

import os
from collections.abc import Iterable, Mapping
from pathlib import Path

#: Providers that accept extra homes in ``provider_extra_homes``.
EXTRA_HOME_PROVIDERS = ("claude", "codex")
#: A person rarely has more than a handful of accounts; the cap keeps a
#: typo'd settings file from turning one scan into hundreds.
MAX_EXTRA_HOMES = 8
MAX_HOME_PATH_LENGTH = 1024


def _environment(env: Mapping[str, str] | None) -> Mapping[str, str]:
    return os.environ if env is None else env


def _home(home: Path | str | None) -> Path:
    return Path.home() if home is None else Path(home)


def _absolute(value: object) -> Path | None:
    """An absolute folder path from a setting or variable, or None."""
    if not isinstance(value, str):
        return None
    text = value.strip()
    if not text or len(text) > MAX_HOME_PATH_LENGTH or "\x00" in text:
        return None
    path = Path(os.path.expanduser(text))
    return path if path.is_absolute() else None


def normalized_extra_homes(value: object) -> dict[str, tuple[str, ...]]:
    """``provider_extra_homes`` as saved: absolute paths only, per provider.

    Anything else (a relative path, a non-string, an unknown provider) is
    dropped rather than refused, so one bad entry never costs the rest.
    """
    result: dict[str, tuple[str, ...]] = {provider: () for provider in EXTRA_HOME_PROVIDERS}
    if not isinstance(value, Mapping):
        return result
    for provider in EXTRA_HOME_PROVIDERS:
        raw = value.get(provider)
        if not isinstance(raw, (list, tuple)):
            continue
        kept: list[str] = []
        for item in raw:
            path = _absolute(item)
            if path is None:
                continue
            text = str(path)
            if text not in kept:
                kept.append(text)
            if len(kept) >= MAX_EXTRA_HOMES:
                break
        result[provider] = tuple(kept)
    return result


def _dedupe_existing(candidates: Iterable[Path | None]) -> tuple[Path, ...]:
    """Existing folders in order, each real folder once."""
    seen: set[str] = set()
    kept: list[Path] = []
    for candidate in candidates:
        if candidate is None:
            continue
        try:
            if not candidate.is_dir():
                continue
            real = os.path.realpath(candidate)
        except OSError:
            continue
        if real in seen:
            continue
        seen.add(real)
        kept.append(candidate)
    return tuple(kept)


def claude_homes(
    *,
    env: Mapping[str, str] | None = None,
    home: Path | str | None = None,
    extras: Iterable[str] = (),
) -> tuple[Path, ...]:
    """Claude Code config folders: ``CLAUDE_CONFIG_DIR``, ``~/.claude``, extras."""
    environment = _environment(env)
    return _dedupe_existing(
        (
            _absolute(environment.get("CLAUDE_CONFIG_DIR")),
            _home(home) / ".claude",
            *(_absolute(item) for item in extras),
        )
    )


def codex_homes(
    *,
    env: Mapping[str, str] | None = None,
    home: Path | str | None = None,
    extras: Iterable[str] = (),
) -> tuple[Path, ...]:
    """Codex home folders: ``CODEX_HOME``, ``~/.codex``, extras."""
    environment = _environment(env)
    return _dedupe_existing(
        (
            _absolute(environment.get("CODEX_HOME")),
            _home(home) / ".codex",
            *(_absolute(item) for item in extras),
        )
    )


def claude_project_roots(**kwargs) -> tuple[Path, ...]:
    """Each Claude home's ``projects`` folder that exists, once per real folder."""
    return _dedupe_existing(root / "projects" for root in claude_homes(**kwargs))


def codex_session_roots(**kwargs) -> tuple[Path, ...]:
    """Each Codex home's ``sessions`` folder that exists, once per real folder."""
    return _dedupe_existing(root / "sessions" for root in codex_homes(**kwargs))


def primary_claude_projects(
    *, env: Mapping[str, str] | None = None, home: Path | str | None = None
) -> Path:
    """The folder the default scan reads: the environment's home, else ``~/.claude``.

    Unlike the lists above this always returns a path, so a scan of a Mac
    with no Claude data still has somewhere to look and finds nothing.
    """
    configured = _absolute(_environment(env).get("CLAUDE_CONFIG_DIR"))
    base = configured if configured is not None and configured.is_dir() else _home(home) / ".claude"
    return base / "projects"


def primary_codex_sessions(
    *, env: Mapping[str, str] | None = None, home: Path | str | None = None
) -> Path:
    """The folder the default scan reads: ``CODEX_HOME``, else ``~/.codex``."""
    configured = _absolute(_environment(env).get("CODEX_HOME"))
    base = configured if configured is not None and configured.is_dir() else _home(home) / ".codex"
    return base / "sessions"


def extra_scan_roots(
    provider_id: str,
    *,
    env: Mapping[str, str] | None = None,
    home: Path | str | None = None,
    extras: Iterable[str] = (),
) -> tuple[Path, ...]:
    """Transcript folders beyond the primary one, each real folder once.

    The primary folder is scanned by the existing single-root scan; these
    are the second and later accounts. A folder that resolves to the
    primary one is not repeated.
    """
    if provider_id == "claude":
        primary = primary_claude_projects(env=env, home=home)
        roots = claude_project_roots(env=env, home=home, extras=extras)
    elif provider_id == "codex":
        primary = primary_codex_sessions(env=env, home=home)
        roots = codex_session_roots(env=env, home=home, extras=extras)
    else:
        return ()
    try:
        primary_real = os.path.realpath(primary)
    except OSError:
        primary_real = str(primary)
    return tuple(root for root in roots if os.path.realpath(root) != primary_real)


def configured_extra_homes(settings: object = None) -> dict[str, tuple[str, ...]]:
    """``provider_extra_homes`` from the saved settings, empty when unreadable."""
    if settings is None:
        try:
            from .settings import load_settings

            settings = load_settings()
        except Exception:
            return normalized_extra_homes(None)
    return normalized_extra_homes(getattr(settings, "provider_extra_homes", None))


def opencode_data_root(
    *, env: Mapping[str, str] | None = None, home: Path | str | None = None
) -> Path:
    """OpenCode's data folder: ``$XDG_DATA_HOME/opencode``, else ``~/.local/share/opencode``.

    A relative ``XDG_DATA_HOME`` is ignored, as the XDG spec says.
    """
    configured = _absolute(_environment(env).get("XDG_DATA_HOME"))
    base = configured if configured is not None else _home(home) / ".local" / "share"
    return base / "opencode"


__all__ = [
    "EXTRA_HOME_PROVIDERS",
    "MAX_EXTRA_HOMES",
    "claude_homes",
    "claude_project_roots",
    "codex_homes",
    "codex_session_roots",
    "configured_extra_homes",
    "extra_scan_roots",
    "normalized_extra_homes",
    "opencode_data_root",
    "primary_claude_projects",
    "primary_codex_sessions",
]
