"""Environment lookups that honour the pre-rename ``SIDEPULSE_*`` names.

Every JR-Bar environment variable is ``JRBAR_<NAME>``. Shell profiles, CI
secrets and LaunchAgent plists written before the rename still export
``SIDEPULSE_<NAME>``; ``env_value`` reads the new name first and falls back
to the old one for one release so those keep working unchanged.
"""

from __future__ import annotations

import os
from collections.abc import Mapping

ENV_PREFIX = "JRBAR_"
LEGACY_ENV_PREFIX = "SIDEPULSE_"


def legacy_env_name(name: str) -> str:
    """Map ``JRBAR_X`` to ``SIDEPULSE_X``."""
    if not name.startswith(ENV_PREFIX):
        raise ValueError(f"not a JR-Bar environment variable: {name!r}")
    return LEGACY_ENV_PREFIX + name[len(ENV_PREFIX):]


def env_value(
    name: str,
    default: str | None = None,
    *,
    env: Mapping[str, str] | None = None,
) -> str | None:
    """Return ``env[name]``, else ``env[SIDEPULSE_...]``, else ``default``."""
    source = os.environ if env is None else env
    value = source.get(name)
    if value is not None:
        return value
    value = source.get(legacy_env_name(name))
    if value is not None:
        return value
    return default


__all__ = ["ENV_PREFIX", "LEGACY_ENV_PREFIX", "env_value", "legacy_env_name"]
