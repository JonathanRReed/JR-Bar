"""Terminal launch plans, and the cleanup of the retired menu-bar LaunchAgent.

A session's resume command opens in a reviewed terminal: Terminal, iTerm2 or
Ghostty, resolved to exact arguments without a shell.

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
import plistlib
import stat
import subprocess
from collections.abc import Callable, Sequence
from dataclasses import dataclass
from enum import Enum
from pathlib import Path

from .product_identity import PRODUCT_DISPLAY_NAME
from .trusted_tools import trusted_system_tool

TERMINAL_BUNDLE_IDENTIFIER = "com.apple.Terminal"
ITERM_BUNDLE_IDENTIFIER = "com.googlecode.iterm2"
GHOSTTY_BUNDLE_IDENTIFIER = "com.mitchellh.ghostty"
REVIEWED_TERMINAL_BUNDLE_IDENTIFIERS = (
    TERMINAL_BUNDLE_IDENTIFIER,
    ITERM_BUNDLE_IDENTIFIER,
    GHOSTTY_BUNDLE_IDENTIFIER,
)
GHOSTTY_APPLICATION_PATHS = (Path("/Applications/Ghostty.app"),)
APPLE_EVENTS_USAGE_DESCRIPTION = (
    f"{PRODUCT_DISPLAY_NAME} uses Automation only to open a reviewed resume command in "
    "Terminal or iTerm2 when you choose Open."
)
UNSUPPORTED_TERMINAL_FALLBACK_COPY = (
    f"{PRODUCT_DISPLAY_NAME} does not support this terminal yet, so it opened Terminal."
)
UNAVAILABLE_GHOSTTY_FALLBACK_COPY = (
    f"{PRODUCT_DISPLAY_NAME} could not verify Ghostty, so it opened Terminal."
)

LAUNCHCTL_TIMEOUT_SECONDS = 15.0

LAUNCH_AGENT_LABEL = "com.jonathanreed.jrbar.app"
# Labels the status bar shipped under before the JR-Bar rename.
LEGACY_LAUNCH_AGENT_LABELS = ("io.sidepulse.agentstatus", "com.sidepulse.agentstatus")
RETIRED_LAUNCH_AGENT_LABELS = (LAUNCH_AGENT_LABEL, *LEGACY_LAUNCH_AGENT_LABELS)


class TerminalLaunchKind(str, Enum):
    APPLE_EVENTS = "apple-events"
    EXECUTABLE = "executable"


@dataclass(frozen=True, slots=True)
class TerminalLaunchPlan:
    requested_bundle_identifier: str | None
    selected_bundle_identifier: str
    kind: TerminalLaunchKind
    executable_path: Path | None = None
    fallback_copy: str | None = None

    def __post_init__(self) -> None:
        requested_valid = self.requested_bundle_identifier is None or (
            type(self.requested_bundle_identifier) is str
            and 1 <= len(self.requested_bundle_identifier) <= 255
            and self.requested_bundle_identifier.isprintable()
        )
        if not requested_valid or type(self.selected_bundle_identifier) is not str:
            raise ValueError("invalid terminal launch identity")
        if self.kind is TerminalLaunchKind.APPLE_EVENTS:
            if not (
                self.selected_bundle_identifier
                in {TERMINAL_BUNDLE_IDENTIFIER, ITERM_BUNDLE_IDENTIFIER}
                and self.executable_path is None
            ):
                raise ValueError("invalid Apple Events terminal launch plan")
        elif self.kind is TerminalLaunchKind.EXECUTABLE:
            if not (
                self.selected_bundle_identifier == GHOSTTY_BUNDLE_IDENTIFIER
                and isinstance(self.executable_path, Path)
                and self.executable_path.is_absolute()
            ):
                raise ValueError("invalid executable terminal launch plan")
        else:
            raise ValueError("invalid terminal launch kind")
        if self.fallback_copy is not None and self.fallback_copy not in {
            UNSUPPORTED_TERMINAL_FALLBACK_COPY,
            UNAVAILABLE_GHOSTTY_FALLBACK_COPY,
        }:
            raise ValueError("invalid terminal fallback copy")


def terminal_navigation_requires_apple_events(
    bundle_identifiers: Sequence[str] = REVIEWED_TERMINAL_BUNDLE_IDENTIFIERS,
    *,
    fallback_to_terminal: bool = True,
) -> bool:
    """Return whether an enabled reviewed terminal action sends Apple Events."""
    reviewed = frozenset(bundle_identifiers)
    return fallback_to_terminal or bool(
        reviewed & {TERMINAL_BUNDLE_IDENTIFIER, ITERM_BUNDLE_IDENTIFIER}
    )


def _safe_real_directory(path: Path) -> bool:
    try:
        metadata = path.lstat()
    except OSError:
        return False
    return stat.S_ISDIR(metadata.st_mode) and not stat.S_ISLNK(metadata.st_mode)


def _safe_real_file(path: Path, *, executable: bool = False) -> bool:
    try:
        metadata = path.lstat()
    except OSError:
        return False
    if (
        not stat.S_ISREG(metadata.st_mode)
        or stat.S_ISLNK(metadata.st_mode)
        or metadata.st_nlink != 1
    ):
        return False
    return not executable or bool(metadata.st_mode & 0o111)


def _validated_ghostty_executable(
    bundle: Path,
    *,
    command_runner: Callable[..., subprocess.CompletedProcess] | None = None,
) -> Path | None:
    """Resolve one reviewed Ghostty bundle without PATH or user-directory search."""
    candidate_bundle = Path(bundle)
    if not candidate_bundle.is_absolute() or candidate_bundle.name != "Ghostty.app":
        return None
    contents = candidate_bundle / "Contents"
    macos = contents / "MacOS"
    info_path = contents / "Info.plist"
    executable = macos / "ghostty"
    if not all(
        _safe_real_directory(path)
        for path in (candidate_bundle, contents, macos)
    ) or not (
        _safe_real_file(info_path)
        and _safe_real_file(executable, executable=True)
    ):
        return None
    try:
        info = plistlib.loads(info_path.read_bytes())
    except (OSError, ValueError, plistlib.InvalidFileException):
        return None
    if not isinstance(info, dict) or not (
        info.get("CFBundleIdentifier") == GHOSTTY_BUNDLE_IDENTIFIER
        and info.get("CFBundleExecutable") == "ghostty"
    ):
        return None
    try:
        resolved_bundle = candidate_bundle.resolve(strict=True)
        resolved_executable = executable.resolve(strict=True)
    except OSError:
        return None
    if resolved_executable != resolved_bundle / "Contents" / "MacOS" / "ghostty":
        return None
    run_command = command_runner or subprocess.run
    try:
        verified = run_command(
            [
                str(trusted_system_tool("codesign")),
                "--verify",
                "--deep",
                "--strict",
                str(candidate_bundle),
            ],
            capture_output=True,
            text=True,
            timeout=30,
        )
    except (OSError, subprocess.TimeoutExpired):
        return None
    return executable if verified.returncode == 0 else None


def resolve_ghostty_executable() -> Path | None:
    """Resolve Ghostty only from reviewed system-wide application locations."""
    for bundle in GHOSTTY_APPLICATION_PATHS:
        executable = _validated_ghostty_executable(bundle)
        if executable is not None:
            return executable
    return None


def resolve_terminal_launch(bundle_identifier: str | None) -> TerminalLaunchPlan:
    """Resolve one deterministic terminal action or a product-owned fallback."""
    requested = bundle_identifier if type(bundle_identifier) is str else None
    if requested == TERMINAL_BUNDLE_IDENTIFIER:
        return TerminalLaunchPlan(
            requested,
            TERMINAL_BUNDLE_IDENTIFIER,
            TerminalLaunchKind.APPLE_EVENTS,
        )
    if requested == ITERM_BUNDLE_IDENTIFIER:
        return TerminalLaunchPlan(
            requested,
            ITERM_BUNDLE_IDENTIFIER,
            TerminalLaunchKind.APPLE_EVENTS,
        )
    if requested == GHOSTTY_BUNDLE_IDENTIFIER:
        executable = resolve_ghostty_executable()
        if executable is not None:
            return TerminalLaunchPlan(
                requested,
                GHOSTTY_BUNDLE_IDENTIFIER,
                TerminalLaunchKind.EXECUTABLE,
                executable_path=Path(executable),
            )
        return TerminalLaunchPlan(
            requested,
            TERMINAL_BUNDLE_IDENTIFIER,
            TerminalLaunchKind.APPLE_EVENTS,
            fallback_copy=UNAVAILABLE_GHOSTTY_FALLBACK_COPY,
        )
    return TerminalLaunchPlan(
        requested,
        TERMINAL_BUNDLE_IDENTIFIER,
        TerminalLaunchKind.APPLE_EVENTS,
        fallback_copy=UNSUPPORTED_TERMINAL_FALLBACK_COPY,
    )


def _applescript_quote(value: str) -> str:
    return '"' + value.replace("\\", "\\\\").replace('"', '\\"') + '"'


def terminal_launch_arguments(
    plan: TerminalLaunchPlan,
    command: str,
) -> tuple[str, ...]:
    """Build exact argv for a reviewed terminal plan without invoking a shell."""
    if type(plan) is not TerminalLaunchPlan:
        raise ValueError("invalid terminal launch plan")
    if not (
        type(command) is str
        and 1 <= len(command) <= 8_192
        and command.isprintable()
    ):
        raise ValueError("invalid terminal command")
    if plan.kind is TerminalLaunchKind.EXECUTABLE:
        if plan.executable_path is None:
            raise ValueError("executable terminal launch is missing its path")
        return (
            str(plan.executable_path),
            "+new-window",
            "-e",
            "/bin/zsh",
            "-lc",
            command,
        )
    if plan.selected_bundle_identifier == TERMINAL_BUNDLE_IDENTIFIER:
        script = "\n".join(
            (
                f'tell application id "{TERMINAL_BUNDLE_IDENTIFIER}"',
                "  activate",
                f"  do script {_applescript_quote(command)}",
                "end tell",
            )
        )
    elif plan.selected_bundle_identifier == ITERM_BUNDLE_IDENTIFIER:
        script = "\n".join(
            (
                f'tell application id "{ITERM_BUNDLE_IDENTIFIER}"',
                "  activate",
                f"  create window with default profile command {_applescript_quote(command)}",
                "end tell",
            )
        )
    else:
        raise ValueError("unreviewed Apple Events terminal target")
    return (str(trusted_system_tool("osascript")), "-e", script)


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
                str(trusted_system_tool("launchctl")),
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
