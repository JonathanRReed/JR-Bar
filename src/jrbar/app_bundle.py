"""JR-Bar.app identity helpers.

The production bundle is the self-contained PyInstaller app built by
packaging/build_macos_pkg.sh. This module keeps only the two facts other
code needs about it: where the installed bundle lives, and whether the
current process is running from inside one. (macOS TCC attributes
permissions to the process's real executable, so "are we the bundle?"
decides which path the Privacy walkthroughs point at.)

The mutable development-wrapper builder that used to live here was
deleted 2026-08-26: nothing called build_app_bundle -- not the app, not
the CLI, not a script -- and the packaging pipeline owns Info.plist,
signing, and the Apple-Events usage description now.
"""

from __future__ import annotations

import sys
from pathlib import Path

APP_BUNDLE_NAME = "JR-Bar.app"
APP_BUNDLE_IDENTIFIER = "com.jonathanreed.jrbar"
APP_EXECUTABLE_NAME = "JR-Bar"


def containing_app_bundle(executable: str | Path | None = None) -> Path | None:
    """Return the outer JR-Bar bundle containing an executable, if any."""
    path = Path(executable if executable is not None else (sys.executable or ""))
    for candidate in path.parents:
        if candidate.name != APP_BUNDLE_NAME:
            continue
        try:
            relative = path.relative_to(candidate)
        except ValueError:
            continue
        if relative.parts[:1] == ("Contents",) and (candidate / "Contents").is_dir():
            return candidate
    return None


def running_inside_bundle() -> bool:
    return containing_app_bundle() is not None
