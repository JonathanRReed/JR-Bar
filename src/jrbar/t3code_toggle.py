"""The T3 Code switch behind Settings > Agents, as data.

`jrbar-integrations enable|disable t3code` for the app: whether T3 Code's
database is on this Mac, whether JR-Bar reads it, and one write of
``integrations.json`` through the hardened integration-settings facade.
Reading T3 stays read-only and local; this only flips the opt-in.
"""

from __future__ import annotations

from pathlib import Path
from typing import Any

from .integration_settings import (
    IntegrationSettingsError,
    IntegrationSettingsWriteRefusedError,
    load_integration_settings,
    save_integration_settings,
)
from .t3_compat import t3_database_path


class T3CodeToggleRefused(RuntimeError):
    """integrations.json could not take the change; the message says why."""


def t3code_integration(
    enabled: bool | None = None,
    *,
    path: Path | None = None,
) -> tuple[dict[str, Any], Any]:
    """The T3 row's document, after setting ``enabled`` when given.

    Returns ``(document, settings)``: the settings are what the daemon's
    T3 runtime reconciles against right away, so the change does not wait
    for the next refresh tick. A newer build's settings file, a malformed
    one, or a failed write refuses rather than replacing it.
    """
    if enabled is not None and type(enabled) is not bool:
        raise TypeError("enabled must be a bool or None")
    loaded = load_integration_settings(path)
    settings = loaded.settings
    if enabled is not None and settings.t3code_enabled is not enabled:
        candidate = settings.with_enabled("t3code", enabled)
        try:
            save_integration_settings(candidate, path, loaded=loaded)
        except (IntegrationSettingsError, IntegrationSettingsWriteRefusedError, OSError) as exc:
            raise T3CodeToggleRefused(str(exc) or exc.__class__.__name__) from exc
        loaded = load_integration_settings(path)
        settings = loaded.settings
    database = t3_database_path(settings.t3code_base_dir)
    return (
        {
            "present": database.is_file(),
            "database": str(database),
            "enabled": settings.t3code_enabled is True,
            "activity_statistics": settings.t3code_activity_statistics_enabled is True,
            "read_only": loaded.compatibility.read_only,
        },
        settings,
    )


def t3code_observation(service: object) -> dict[str, Any] | None:
    """What the running T3 reader last saw -- null while it is off."""
    observe = getattr(service, "observation", None)
    if not callable(observe):
        return None
    observation = observe()
    snapshot = getattr(observation, "snapshot", None)
    compatible = snapshot is not None and getattr(snapshot, "compatible", False) is True
    return {
        "available": compatible,
        "threads": len(snapshot.threads) if compatible else 0,
        "active": snapshot.active_count if compatible else 0,
        "needs_user": snapshot.needs_user_count if compatible else 0,
        "reason": getattr(observation, "reason", None)
        or (getattr(snapshot, "reason", None) if snapshot is not None else None),
        "in_flight": getattr(observation, "in_flight", False) is True,
    }
