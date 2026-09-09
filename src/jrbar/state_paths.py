"""Stdlib-only compatibility paths shared by hook clients and the app."""

from __future__ import annotations

import os
from pathlib import Path


def _state_home(home: Path | None) -> Path:
    if home is None:
        xdg_state_home = os.environ.get("XDG_STATE_HOME")
        if xdg_state_home:
            return Path(xdg_state_home).expanduser()
    base = home or Path.home()
    return base / ".local" / "state"


def default_state_dir(home: Path | None = None) -> Path:
    """``$XDG_STATE_HOME/jrbar`` (default ``~/.local/state/jrbar``), flat."""
    return _state_home(home) / "jrbar"


def legacy_state_dirs(home: Path | None = None) -> tuple[Path, ...]:
    """State directories used before the JR-Bar rename, most specific first.

    Nothing is written here any more; ``jrbar.migration`` copies their
    contents into :func:`default_state_dir` once.
    """
    root = _state_home(home) / "sidepulse"
    return (root / "agent-monitor", root)


def candidate_state_dirs(home: Path | None = None) -> tuple[Path, ...]:
    if home is not None:
        return (default_state_dir(home).expanduser(),)

    candidates = (
        default_state_dir().expanduser(),
        default_state_dir(Path.home()).expanduser(),
    )
    return tuple(dict.fromkeys(candidates))


__all__ = ["candidate_state_dirs", "default_state_dir", "legacy_state_dirs"]
