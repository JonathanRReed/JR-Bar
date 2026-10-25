"""Credential locations shared by collectors and credential-change watches."""

from __future__ import annotations

import os
from pathlib import Path


def _override(key: str, default: Path) -> Path:
    value = os.environ.get(key, "").strip()
    path = Path(value).expanduser() if value else default
    return path if path.is_absolute() else default


def grok_auth_path(home: Path) -> Path:
    return _override("GROK_HOME", home / ".grok") / "auth.json"


def gemini_auth_path(home: Path) -> Path:
    # GEMINI_CLI_HOME replaces the user home, not the .gemini directory.
    return _override("GEMINI_CLI_HOME", home) / ".gemini" / "oauth_creds.json"


def kimi_code_home(home: Path) -> Path:
    return _override("KIMI_CODE_HOME", home / ".kimi-code")


def kilo_auth_path(home: Path) -> Path:
    return _override("XDG_DATA_HOME", home / ".local" / "share") / "kilo" / "auth.json"
