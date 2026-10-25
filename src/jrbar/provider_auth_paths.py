"""Credential locations shared by collectors and credential-change watches."""

from __future__ import annotations

import os
from pathlib import Path


def _override(key: str, default: Path) -> Path:
    value = os.environ.get(key, "").strip()
    path = Path(value).expanduser() if value else default
    return path if path.is_absolute() else default


def _existing_or_default(override: Path, default: Path) -> Path:
    # launchd may carry a stale override while the CLI uses its normal home.
    # An existing override remains authoritative, even when unreadable.
    return default if not (override.exists() or override.is_symlink()) and default.exists() else override


def grok_auth_path(home: Path) -> Path:
    return _existing_or_default(_override("GROK_HOME", home / ".grok") / "auth.json",
                                home / ".grok" / "auth.json")


def gemini_auth_path(home: Path) -> Path:
    # GEMINI_CLI_HOME replaces the user home, not the .gemini directory.
    return _existing_or_default(_override("GEMINI_CLI_HOME", home) / ".gemini" / "oauth_creds.json",
                                home / ".gemini" / "oauth_creds.json")


def kimi_code_home(home: Path) -> Path:
    override = _override("KIMI_CODE_HOME", home / ".kimi-code")
    credential = Path("credentials/kimi-code.json")
    selected = _existing_or_default(override / credential, home / ".kimi-code" / credential)
    return selected.parent.parent


def kilo_auth_path(home: Path) -> Path:
    return _existing_or_default(_override("XDG_DATA_HOME", home / ".local" / "share") / "kilo" / "auth.json",
                                home / ".local" / "share" / "kilo" / "auth.json")
