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


def _home_cache_path(cache_path: Path | None, root: Path) -> Path | None:
    """A separate scan cache per extra home, so homes never evict each other."""
    if cache_path is None:
        return None
    import hashlib

    digest = hashlib.sha256(os.path.realpath(root).encode("utf-8")).hexdigest()[:12]
    return cache_path.with_name(f"{cache_path.name}.home-{digest}")


def scan_usage_all_homes(
    cache_path: Path | None,
    *,
    since_epoch: float,
    provider_ids: tuple[str, ...] | None,
    env: Mapping[str, str] | None = None,
    home: Path | str | None = None,
    extras: Mapping[str, Iterable[str]] | None = None,
    scan=None,
):
    """``usage_stats.scan_usage`` over every Claude and Codex home.

    The primary homes (the environment's, else ``~/.claude`` and
    ``~/.codex``) are scanned exactly as before; each extra home is
    scanned on its own cache and its records are added. A home that is the
    same real folder as another is scanned once. The Codex quota evidence
    stays the primary account's: another home's rate limits belong to a
    different account and must not stand in for this one's.
    """
    from . import usage_stats

    run = usage_stats.scan_usage if scan is None else scan
    primary = run(
        primary_claude_projects(env=env, home=home),
        cache_path,
        since_epoch=since_epoch,
        codex_root=primary_codex_sessions(env=env, home=home),
        provider_ids=provider_ids,
    )
    configured = configured_extra_homes() if extras is None else normalized_extra_homes(extras)
    parts = [primary]
    missing = _home(home) / ".jrbar-no-such-home"
    for provider_id in EXTRA_HOME_PROVIDERS:
        if provider_ids is not None and provider_id not in provider_ids:
            continue
        for root in extra_scan_roots(
            provider_id, env=env, home=home, extras=configured.get(provider_id, ())
        ):
            part_cache = _home_cache_path(cache_path, root)
            if provider_id == "claude":
                part = run(root, part_cache, since_epoch=since_epoch, provider_ids=("claude",))
            else:
                part = run(missing, part_cache, since_epoch=since_epoch, codex_root=root, provider_ids=("codex",))
            parts.append(part)
    if len(parts) == 1:
        return primary
    merged = usage_stats._merge_usage_totals(tuple(parts))
    merged.codex_rate_limit_evidence = primary.codex_rate_limit_evidence
    merged.codex_rate_limit_observed_at = primary.codex_rate_limit_observed_at
    return merged


def home_scan_roots(
    provider_ids: Iterable[str],
    *,
    env: Mapping[str, str] | None = None,
    home: Path | str | None = None,
    extras: Mapping[str, Iterable[str]] | None = None,
) -> dict[str, tuple[Path, ...]]:
    """Every transcript folder a scan reads, per provider, primary first:
    what the usage graph's cache fingerprint has to cover."""
    configured = configured_extra_homes() if extras is None else normalized_extra_homes(extras)
    roots: dict[str, tuple[Path, ...]] = {}
    for provider_id in provider_ids:
        if provider_id == "claude":
            primary = primary_claude_projects(env=env, home=home)
        elif provider_id == "codex":
            primary = primary_codex_sessions(env=env, home=home)
        else:
            continue
        roots[provider_id] = (
            primary,
            *extra_scan_roots(provider_id, env=env, home=home, extras=configured.get(provider_id, ())),
        )
    return roots


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
    "home_scan_roots",
    "normalized_extra_homes",
    "opencode_data_root",
    "primary_claude_projects",
    "primary_codex_sessions",
    "scan_usage_all_homes",
]
