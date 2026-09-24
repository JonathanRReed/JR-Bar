"""Terminal launch plans, and the cleanup of the retired menu-bar LaunchAgent.

The PyObjC menu bar that ran under ``com.jonathanreed.jrbar.app`` is
retired: the Swift app is the UI and supervises the daemon it carries.
Nothing here installs a LaunchAgent any more. An install from before that
may still hold the plist (``KeepAlive`` respawned a Python process that
refused to run beside the daemon every ten seconds, forever), so the
daemon's startup migration and the hidden ``jrbar status-bar stop`` boot
it out and unlink it, together with the pre-rename SidePulse plists.
"""

from __future__ import annotations

import os
import stat
import subprocess
from pathlib import Path

from . import _status_bar_launch_legacy as _legacy

LAUNCHCTL_TIMEOUT_SECONDS = 15.0

LAUNCH_AGENT_LABEL = "com.jonathanreed.jrbar.app"
# Labels the status bar shipped under before the JR-Bar rename.
LEGACY_LAUNCH_AGENT_LABELS = ("io.sidepulse.agentstatus", "com.sidepulse.agentstatus")
RETIRED_LAUNCH_AGENT_LABELS = (LAUNCH_AGENT_LABEL, *LEGACY_LAUNCH_AGENT_LABELS)

for _name in dir(_legacy):
    if _name.startswith("__") or _name in globals():
        continue
    globals()[_name] = getattr(_legacy, _name)


def launch_domain() -> str:
    return f"gui/{os.getuid()}"


def retired_launch_agent_paths(home: Path | None = None) -> tuple[Path, ...]:
    base = home or Path.home()
    return tuple(
        base / "Library" / "LaunchAgents" / f"{label}.plist"
        for label in RETIRED_LAUNCH_AGENT_LABELS
    )


def bootout_launch_agent(plist_path: Path) -> None:
    """Best effort: a job that is not loaded is already where we want it."""
    try:
        subprocess.run(
            [
                str(_legacy.trusted_system_tool("launchctl")),
                "bootout",
                launch_domain(),
                str(plist_path),
            ],
            stdin=subprocess.DEVNULL,
            stdout=subprocess.DEVNULL,
            stderr=subprocess.DEVNULL,
            timeout=LAUNCHCTL_TIMEOUT_SECONDS,
            check=False,
        )
    except (OSError, subprocess.TimeoutExpired):
        return


def remove_retired_launch_agents(home: Path | None = None) -> tuple[Path, ...]:
    """Boot out and unlink every retired menu-bar plist still installed.

    Only a regular file or a symlink is removed; anything else under one
    of these names is not ours to delete. Returns the paths removed.
    """
    removed: list[Path] = []
    for path in retired_launch_agent_paths(home):
        try:
            info = path.lstat()
        except OSError:
            continue
        if not (stat.S_ISREG(info.st_mode) or stat.S_ISLNK(info.st_mode)):
            continue
        bootout_launch_agent(path)
        try:
            path.unlink(missing_ok=True)
        except OSError:
            continue
        removed.append(path)
    return tuple(removed)


__all__ = tuple(sorted(name for name in globals() if not name.startswith("_")))
