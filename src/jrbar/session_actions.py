from __future__ import annotations

import json
import os
import re
import shlex
import threading
import time
from collections.abc import Callable
from dataclasses import dataclass
from enum import Enum
from pathlib import Path, PurePath
from typing import Final
from urllib.parse import quote, urlencode

from .models import AgentStatus
from .navigation_policy import (
    NavigationResolution,
    NavigationResolutionKind,
    navigation_target_allowed,
)
from .provider_facts import WorkKey
from .provider_feature_settings import ProviderInstanceSessionActionProjection
from .provider_instances import (
    DEFAULT_PROVIDER_INSTANCE_SOURCE_ID,
    ProviderInstanceError,
    ProviderInstanceKey,
)
from .providers import HOOK_PROVIDERS

SESSION_OPEN_APP = "app"
SESSION_OPEN_TERMINAL = "terminal"
SESSION_OPEN_VSCODE = "vscode"
SESSION_OPEN_CHOICES = (SESSION_OPEN_APP, SESSION_OPEN_TERMINAL, SESSION_OPEN_VSCODE)
SESSION_OPEN_APP_SURFACES = ("app", "ui", "transcript")
SESSION_OPEN_TERMINAL_SURFACES = ("cli", "terminal", "command line")
SESSION_OPEN_VSCODE_SURFACES = ("vscode", "vs code", "visual studio code")
SESSION_TERMINAL_OPENERS = {
    "codex": ("codex", "resume"),
    "claude": ("claude", "--resume"),
    "devin": ("devin", "--resume"),
    "grok": ("grok", "--resume"),
    "cursor": ("cursor-agent", "--resume"),
    "hermes": ("hermes", "--resume"),
}
MAX_SESSION_ID_LENGTH = 256
MAX_SESSION_CWD_LENGTH = 1_024
# Claude.app's own record of the Claude Code sessions it runs: one
# ``local_<uuid>.json`` per session under <account>/<org>/, naming the CLI
# session JR-Bar sees as ``cliSessionId``. A private format read only to
# find that one id; anything unexpected is simply no match.
CLAUDE_DESKTOP_SESSION_STORE: Final = (
    Path.home() / "Library" / "Application Support" / "Claude" / "claude-code-sessions"
)
# The id Claude.app's claude://code/continue accepts (its URL handler
# matches exactly this).
CLAUDE_DESKTOP_LOCAL_ID: Final = re.compile(r"local_[A-Za-z0-9-]{1,64}")
_CLAUDE_STORE_MAX_DEPTH: Final = 4
_CLAUDE_STORE_MAX_FILES: Final = 4_096
_CLAUDE_STORE_MAX_FILE_BYTES: Final = 1024 * 1024
# How long a "is there a vscode:// handler" answer is trusted.
_VSCODE_HANDLER_TTL_SECONDS: Final = 300.0


class ProfileSessionActionResolutionKind(str, Enum):
    """Why a provider profile did or did not override legacy session routing."""

    PROFILE_OVERRIDE = "profile_override"
    LEGACY_DEFAULT = "legacy_default"
    MISSING_IDENTITY = "missing_identity"
    INVALID_IDENTITY = "invalid_identity"
    UNKNOWN_INSTANCE = "unknown_instance"


@dataclass(frozen=True, slots=True)
class ProfileSessionActionResolution:
    """Pure exact-instance result consumed before the legacy action ladder."""

    kind: ProfileSessionActionResolutionKind
    action: str | None = None
    provider_id: str | None = None
    source_instance_id: str | None = None

    def __post_init__(self) -> None:
        has_identity = self.provider_id is not None and self.source_instance_id is not None
        if (
            type(self.kind) is not ProfileSessionActionResolutionKind
            or (self.provider_id is None) != (self.source_instance_id is None)
            or (has_identity and not all(isinstance(value, str) for value in self.identity or ()))
            or (
                self.kind is ProfileSessionActionResolutionKind.PROFILE_OVERRIDE
                and self.action not in SESSION_OPEN_CHOICES
            )
            or (
                self.kind is not ProfileSessionActionResolutionKind.PROFILE_OVERRIDE
                and self.action is not None
            )
        ):
            raise ValueError("invalid profile session action resolution")

    @property
    def identity(self) -> tuple[str, str] | None:
        if self.provider_id is None or self.source_instance_id is None:
            return None
        return self.provider_id, self.source_instance_id

    @property
    def has_override(self) -> bool:
        return self.kind is ProfileSessionActionResolutionKind.PROFILE_OVERRIDE


def resolve_profile_session_action(
    projection: ProviderInstanceSessionActionProjection,
    provider_id: object,
    source_instance_id: object,
) -> ProfileSessionActionResolution:
    """Resolve only an exact nondefault profile, never a provider fallback."""

    if type(projection) is not ProviderInstanceSessionActionProjection:
        raise TypeError("expected ProviderInstanceSessionActionProjection")
    if type(provider_id) is not str or type(source_instance_id) is not str:
        return ProfileSessionActionResolution(
            ProfileSessionActionResolutionKind.INVALID_IDENTITY
        )
    try:
        identity = ProviderInstanceKey(provider_id, source_instance_id).value
    except ProviderInstanceError:
        return ProfileSessionActionResolution(
            ProfileSessionActionResolutionKind.INVALID_IDENTITY
        )
    if identity[1] == DEFAULT_PROVIDER_INSTANCE_SOURCE_ID:
        return ProfileSessionActionResolution(
            ProfileSessionActionResolutionKind.LEGACY_DEFAULT,
            provider_id=identity[0],
            source_instance_id=identity[1],
        )
    try:
        policy = projection.provider(*identity)
    except StopIteration:
        return ProfileSessionActionResolution(
            ProfileSessionActionResolutionKind.UNKNOWN_INSTANCE,
            provider_id=identity[0],
            source_instance_id=identity[1],
        )
    return ProfileSessionActionResolution(
        ProfileSessionActionResolutionKind.PROFILE_OVERRIDE,
        action=policy.open_session_action,
        provider_id=identity[0],
        source_instance_id=identity[1],
    )


def resolve_profile_session_action_for_status(
    projection: ProviderInstanceSessionActionProjection,
    status: AgentStatus | None,
) -> ProfileSessionActionResolution:
    """Resolve from canonical work identity, failing closed to legacy behavior."""

    if type(projection) is not ProviderInstanceSessionActionProjection:
        raise TypeError("expected ProviderInstanceSessionActionProjection")
    if status is None:
        return ProfileSessionActionResolution(
            ProfileSessionActionResolutionKind.MISSING_IDENTITY
        )
    if type(status) is not AgentStatus:
        return ProfileSessionActionResolution(
            ProfileSessionActionResolutionKind.INVALID_IDENTITY
        )
    if status.work_key is None:
        return ProfileSessionActionResolution(
            ProfileSessionActionResolutionKind.MISSING_IDENTITY
        )
    if type(status.work_key) is not WorkKey:
        return ProfileSessionActionResolution(
            ProfileSessionActionResolutionKind.INVALID_IDENTITY
        )
    source_key = status.work_key.source_key
    if type(status.provider) is not str or status.provider != source_key.provider_id:
        return ProfileSessionActionResolution(
            ProfileSessionActionResolutionKind.INVALID_IDENTITY
        )
    return resolve_profile_session_action(
        projection,
        source_key.provider_id,
        source_key.source_instance_id,
    )


def _valid_session_id(value: object) -> bool:
    return (
        type(value) is str
        and 1 <= len(value) <= MAX_SESSION_ID_LENGTH
        and value.isprintable()
        and "/" not in value
        and "\\" not in value
    )


def _valid_session_cwd(value: object) -> bool:
    return (
        type(value) is str
        and 1 <= len(value) <= MAX_SESSION_CWD_LENGTH
        and value.isprintable()
        and PurePath(value).is_absolute()
    )


class ClaudeDesktopSessions:
    """``cliSessionId`` -> Claude.app's ``local_`` id, from its session store.

    Read-only. The walk is cached by the store's directory mtimes and each
    file by its own mtime and size, so an open that finds nothing new reads
    only directory entries. A store that is missing, unreadable or shaped
    differently answers ``None``, and the open falls back to bare
    ``claude://``."""

    def __init__(self, root: Path | None = None) -> None:
        self._root = root
        self._lock = threading.Lock()
        self._signature: tuple[tuple[str, int], ...] | None = None
        self._files: dict[str, tuple[tuple[int, int], str | None, str | None]] = {}
        self._by_cli: dict[str, str] = {}

    def local_id(self, cli_session_id: object) -> str | None:
        if not _valid_session_id(cli_session_id):
            return None
        try:
            with self._lock:
                self._refresh()
                return self._by_cli.get(str(cli_session_id))
        except Exception:
            return None

    def _refresh(self) -> None:
        root = self._root if self._root is not None else CLAUDE_DESKTOP_SESSION_STORE
        directories: list[tuple[str, int]] = []
        files: list[os.DirEntry[str]] = []
        pending = [(str(root), 0)]
        while pending:
            path, depth = pending.pop()
            try:
                directories.append((path, os.stat(path).st_mtime_ns))
                with os.scandir(path) as entries:
                    for entry in entries:
                        if entry.is_symlink():
                            continue
                        if entry.is_dir() and depth + 1 < _CLAUDE_STORE_MAX_DEPTH:
                            pending.append((entry.path, depth + 1))
                        elif (
                            entry.name.startswith("local_")
                            and entry.name.endswith(".json")
                            and len(files) < _CLAUDE_STORE_MAX_FILES
                            and entry.is_file()
                        ):
                            files.append(entry)
            except OSError:
                if depth == 0:
                    self._signature, self._files, self._by_cli = None, {}, {}
                    return
        signature = tuple(sorted(directories))
        if signature == self._signature:
            return
        known: dict[str, tuple[tuple[int, int], str | None, str | None]] = {}
        for entry in files:
            try:
                info = entry.stat()
            except OSError:
                continue
            stamp = (info.st_mtime_ns, info.st_size)
            cached = self._files.get(entry.path)
            known[entry.path] = cached if cached is not None and cached[0] == stamp else (stamp, *_read_claude_session(entry.path, info.st_size))
        self._signature = signature
        self._files = known
        self._by_cli = {cli: local for _stamp, cli, local in known.values() if cli is not None and local is not None}


def _read_claude_session(path: str, size: int) -> tuple[str | None, str | None]:
    """``(cliSessionId, sessionId)`` from one store file, or ``(None, None)``."""
    if size > _CLAUDE_STORE_MAX_FILE_BYTES:
        return None, None
    try:
        with open(path, "rb") as handle:
            document = json.loads(handle.read(_CLAUDE_STORE_MAX_FILE_BYTES + 1))
    except (OSError, ValueError):
        return None, None
    if not isinstance(document, dict):
        return None, None
    cli = document.get("cliSessionId")
    local = document.get("sessionId")
    if not _valid_session_id(cli) or type(local) is not str or not CLAUDE_DESKTOP_LOCAL_ID.fullmatch(local):
        return None, None
    return cli, local


_CLAUDE_DESKTOP_SESSIONS: Final = ClaudeDesktopSessions()


def claude_desktop_link(status: AgentStatus, sessions: ClaudeDesktopSessions | None = None) -> str | None:
    """``claude://code/continue?session=local_…`` for a session Claude.app
    runs, which lands on that session; bare ``claude://`` only brings the
    app forward on whichever one it showed last. ``None`` for a session the
    app's store does not know, or a row whose origin says it is not the
    app's (a CLI in a terminal, an editor panel): that store is only read
    for rows it can hold."""
    origin = normalized_origin(status.origin)
    if origin and not any(surface in origin.split() for surface in ("app", "ui")):
        return None
    local_id = (sessions or _CLAUDE_DESKTOP_SESSIONS).local_id(status.session_id)
    return None if local_id is None else f"claude://code/continue?session={local_id}"


def session_deep_link(status: AgentStatus) -> str | None:
    provider = status.provider.lower()
    session_id = status.session_id

    if provider == "codex" and _valid_session_id(session_id):
        return f"codex://threads/{quote(session_id, safe='')}"
    if provider == "claude":
        return claude_desktop_link(status) or "claude://"
    return None


def session_vscode_link(status: AgentStatus) -> str | None:
    if status.provider.lower() != "claude" or not _valid_session_id(status.session_id):
        return None
    return "vscode://anthropic.claude-code/open?" + urlencode(
        {"session": status.session_id},
        quote_via=quote,
    )


def session_resume_command(status: AgentStatus) -> str | None:
    if not _valid_session_id(status.session_id) or not _valid_session_cwd(status.cwd):
        return None

    provider = status.provider.lower()
    opener = SESSION_TERMINAL_OPENERS.get(provider)
    if opener is None:
        return None
    cwd = shlex.quote(status.cwd)
    session_id = shlex.quote(status.session_id)
    executable, resume_argument = opener
    return f"cd {cwd} && {executable} {resume_argument} {session_id}"


def session_resume_parts(status: AgentStatus) -> tuple[str, str] | None:
    """``(cwd, command)`` for resuming an ended CLI session in a terminal
    that is already in ``cwd`` -- ``session_resume_command`` without its
    ``cd``, for a terminal tab opened in the session's own directory."""
    return session_resume_parts_for(status.provider, status.session_id, status.cwd)


def session_resume_parts_for(provider: object, session_id: object, cwd: object) -> tuple[str, str] | None:
    """``session_resume_parts`` for a session known only by its provider,
    id and directory -- a History row whose session has left the list."""
    if type(provider) is not str or not _valid_session_id(session_id) or not _valid_session_cwd(cwd):
        return None
    opener = SESSION_TERMINAL_OPENERS.get(provider.lower())
    if opener is None:
        return None
    executable, resume_argument = opener
    return str(cwd), f"{executable} {resume_argument} {shlex.quote(str(session_id))}"


def new_session_parts(provider: object, cwd: object) -> tuple[str, str] | None:
    """``(cwd, command)`` for starting a new session of that agent in
    ``cwd``: the same CLI ``--resume`` runs, with no session id. Only the
    agents JR-Bar knows how to resume, only an absolute directory."""
    if type(provider) is not str or not _valid_session_cwd(cwd):
        return None
    opener = SESSION_TERMINAL_OPENERS.get(provider.lower())
    if opener is None:
        return None
    return str(cwd), opener[0]


def provider_session_opener_providers() -> tuple[str, ...]:
    return HOOK_PROVIDERS


def default_session_open_action(status: AgentStatus) -> str:
    for action in preferred_session_open_actions(status):
        if session_open_target(status, action):
            return action
    return SESSION_OPEN_TERMINAL


def preferred_session_open_actions(status: AgentStatus) -> tuple[str, ...]:
    origin = normalized_origin(status.origin)
    if origin:
        if any(surface in origin for surface in SESSION_OPEN_VSCODE_SURFACES):
            return (SESSION_OPEN_VSCODE, SESSION_OPEN_APP, SESSION_OPEN_TERMINAL)
        if any(surface in origin for surface in SESSION_OPEN_TERMINAL_SURFACES):
            return (SESSION_OPEN_TERMINAL, SESSION_OPEN_APP, SESSION_OPEN_VSCODE)
        if any(surface in origin for surface in SESSION_OPEN_APP_SURFACES):
            return (SESSION_OPEN_APP, SESSION_OPEN_VSCODE, SESSION_OPEN_TERMINAL)
        if "cursor" in origin or "windsurf" in origin:
            return (SESSION_OPEN_APP, SESSION_OPEN_TERMINAL, SESSION_OPEN_VSCODE)

    if status.provider.lower() == "claude":
        # VS Code first only where something opens vscode:// links: on a
        # Mac without it, Automatic sent every Claude session to a link
        # that went nowhere.
        if vscode_link_handled():
            return (SESSION_OPEN_VSCODE, SESSION_OPEN_APP, SESSION_OPEN_TERMINAL)
        return (SESSION_OPEN_APP, SESSION_OPEN_TERMINAL)
    return (SESSION_OPEN_APP, SESSION_OPEN_TERMINAL, SESSION_OPEN_VSCODE)


_vscode_handler_cache: tuple[float, bool] | None = None


def vscode_link_handled(*, monotonic: Callable[[], float] = time.monotonic) -> bool:
    """Whether LaunchServices has an app for ``vscode://`` links, asked at
    most every five minutes; False when it cannot be asked."""
    global _vscode_handler_cache
    now = monotonic()
    cached = _vscode_handler_cache
    if cached is not None and now - cached[0] < _VSCODE_HANDLER_TTL_SECONDS:
        return cached[1]
    try:
        from AppKit import NSWorkspace
        from Foundation import NSURL

        handled = (
            NSWorkspace.sharedWorkspace().URLForApplicationToOpenURL_(NSURL.URLWithString_("vscode://"))
            is not None
        )
    except Exception:
        handled = False
    _vscode_handler_cache = (now, handled)
    return handled


def normalized_origin(origin: str | None) -> str:
    return " ".join(str(origin or "").strip().lower().replace("-", " ").split())


def session_open_target(status: AgentStatus, action: str) -> tuple[str, str] | None:
    if action == SESSION_OPEN_APP:
        url = session_deep_link(status)
        return ("url", url) if url else None
    if action == SESSION_OPEN_VSCODE:
        url = session_vscode_link(status)
        return ("url", url) if url else None
    if action == SESSION_OPEN_TERMINAL:
        command = session_resume_command(status)
        return ("terminal", command) if command else None
    return None


def available_session_open_actions(status: AgentStatus) -> tuple[str, ...]:
    return tuple(action for action in SESSION_OPEN_CHOICES if session_open_target(status, action))


def session_open_action_label(status: AgentStatus, action: str) -> str:
    provider = status.provider.lower()
    if action == SESSION_OPEN_APP:
        if provider == "codex":
            return "Open in Codex"
        if provider == "claude":
            return "Open Claude App"
        return "Open App"
    if action == SESSION_OPEN_VSCODE:
        return "Open in VS Code"
    if action == SESSION_OPEN_TERMINAL:
        return "Resume in Terminal"
    return action


def activate_navigation_resolution(
    resolution: NavigationResolution,
    *,
    open_url: Callable[[str], None],
    open_terminal_command: Callable[[str], None],
) -> bool:
    """Activate only a ready resolution whose target still passes its allowlist."""
    if not (
        type(resolution) is NavigationResolution
        and resolution.kind is NavigationResolutionKind.READY
        and resolution.target_kind is not None
        and resolution.target_value is not None
        and navigation_target_allowed(
            resolution.work_key,
            resolution.target_kind,
            resolution.target_value,
        )
    ):
        return False
    if resolution.target_kind == "url":
        open_url(resolution.target_value)
        return True
    if resolution.target_kind == "terminal":
        open_terminal_command(resolution.target_value)
        return True
    return False
