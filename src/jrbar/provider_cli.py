"""What the daemon knows about each agent CLI, and how it runs one safely.

Two clicks run a provider's own command line tool: Fix sign-in
(`provider_sign_in`) and Update (`provider_update`). Both need the same
three things, so they live here once:

* a table, fixed in the daemon, of the command each CLI uses to sign in and
  to update. The client sends only a provider id; no argument, header or
  setting can put a different command in it;
* a resolver that finds the CLI the way the daemon already finds CLIs (its
  own PATH, the login shell's PATH and the usual install folders) and hands
  back one absolute path;
* a bounded runner: an argv list and never a shell, stdin closed, a hard
  timeout that kills the whole process group, and output kept only as a
  capped tail so a chatty updater cannot fill memory.

Everything here is deterministic given its inputs, so the tests run it
against fake executables in a temporary folder.
"""

from __future__ import annotations

import os
import re
import signal
import stat
import subprocess
import threading
from collections.abc import Callable, Mapping, Sequence
from dataclasses import dataclass
from pathlib import Path
from types import MappingProxyType
from typing import Final

#: Output kept from a child, and the most of it a message may quote.
OUTPUT_CAP_BYTES: Final = 4096
OUTPUT_TAIL_LINES: Final = 20
#: How long the reader thread may take to drain the pipe once the child has
#: ended: a grandchild that kept the pipe open must not hold the caller.
_READER_JOIN_SECONDS: Final = 2.0
_KILL_WAIT_SECONDS: Final = 5.0


@dataclass(frozen=True, slots=True)
class ProviderCli:
    """One agent CLI's fixed commands. ``sign_in`` and ``update`` are the
    arguments after the executable; ``None`` means the CLI has no such
    command and nothing may pretend it does."""

    provider: str
    #: How a sentence names the tool: "Claude Code", "Gemini CLI".
    label: str
    binary: str
    sign_in: tuple[str, ...] | None
    update: tuple[str, ...] | None
    #: The package the npm registry knows it by, or ``None`` (no check).
    npm_package: str | None
    #: True when the daemon notices a new sign-in by itself (a credential
    #: file or Keychain item it already watches), so the message may say so.
    watches_sign_in: bool
    #: True when the updater is known to need a terminal: it is opened
    #: there instead of being run with no input.
    update_needs_terminal: bool = False

    def sign_in_display(self) -> str | None:
        """The sign-in command as a person types it: ``grok login``."""
        if self.sign_in is None:
            return None
        return " ".join((self.binary, *self.sign_in))

    def update_display(self) -> str | None:
        if self.update is None:
            return None
        return " ".join((self.binary, *self.update))


#: Checked against each CLI's own ``--help`` (2026-10-01): ``claude auth
#: login``, ``grok login``, ``codex login`` and ``opencode providers login``
#: (``auth`` is its alias). Gemini CLI's help shows no login command, so it
#: has none here; its sign-in happens inside the interactive tool and the
#: advice says so. A CLI with ``sign_in=None`` is never opened by Fix
#: sign-in.
PROVIDER_CLIS: Final[Mapping[str, ProviderCli]] = MappingProxyType({
    "claude": ProviderCli(
        provider="claude",
        label="Claude Code",
        binary="claude",
        sign_in=("auth", "login"),
        update=("update",),
        npm_package="@anthropic-ai/claude-code",
        watches_sign_in=True,
    ),
    "codex": ProviderCli(
        provider="codex",
        label="Codex",
        binary="codex",
        sign_in=("login",),
        update=("update",),
        npm_package="@openai/codex",
        watches_sign_in=True,
    ),
    "grok": ProviderCli(
        provider="grok",
        label="Grok",
        binary="grok",
        sign_in=("login",),
        update=("update",),
        npm_package="@xai-official/grok",
        watches_sign_in=True,
    ),
    # `devin auth login` exists, but JR-Bar reads Devin's usage from a
    # browser session it imports (provider_usage_collectors.collect_devin),
    # never from the CLI's login, so opening it would not fix the card. Fix
    # sign-in imports the session or opens app.devin.ai instead
    # (provider_reconnect.reconnect_provider).
    # `devin update --help` says "Check for updates and optionally install
    # them" and offers only `--force` (re-install): there is no non-interactive
    # install. With no input it may check, exit 0 and install nothing, which
    # would read as "already up to date", so Devin's Update opens a terminal
    # on the command instead of running it blind.
    "devin": ProviderCli(
        provider="devin",
        label="Devin",
        binary="devin",
        sign_in=None,
        update=("update",),
        npm_package=None,
        watches_sign_in=False,
        update_needs_terminal=True,
    ),
    "opencode": ProviderCli(
        provider="opencode",
        label="OpenCode",
        binary="opencode",
        sign_in=("providers", "login"),
        update=("upgrade",),
        npm_package="opencode-ai",
        watches_sign_in=False,
    ),
    "gemini": ProviderCli(
        provider="gemini",
        label="Gemini CLI",
        binary="gemini",
        sign_in=None,
        update=None,
        npm_package="@google/gemini-cli",
        watches_sign_in=True,
    ),
})

#: Said when someone asks Gemini CLI to update: it has no updater of its own.
GEMINI_UPDATE_ADVICE: Final = (
    "Gemini CLI has no updater of its own: update it the way you installed it "
    "(for example `brew upgrade gemini-cli` or `npm install -g @google/gemini-cli`)."
)


# ---------------------------------------------------------------------------
# Finding the executable

#: The two Homebrew prefixes the installed-agent inventory also trusts
#: (``installed_agent_inventory.default_inventory_roots``). Homebrew makes its
#: ``bin`` directories group-writable by the ``admin`` group, so a directory
#: under one of these, owned by root or the person, may be group-writable and
#: nowhere else may. World-writable is never allowed anywhere.
GROUP_WRITABLE_ROOTS: Final[tuple[str, ...]] = ("/opt/homebrew", "/usr/local")


def search_environment(
    environ: Mapping[str, str] | None = None,
    *,
    login_dirs: Sequence[Path | str] | None = None,
) -> dict[str, str]:
    """The owner's environment with the login shell's PATH folders added.

    Under launchd the daemon's own PATH is short, and the CLIs a person
    installed live in folders only their login shell adds. The login-shell
    answer is the last good one the daemon's probe fetched: this never
    waits on a shell. Every ``JRBAR_*`` variable is dropped: a child CLI has
    no business with this daemon's own settings, and one of them is a bearer
    token. Relative and empty PATH entries are dropped too (an empty entry
    means "the current folder"), so a child never finds a tool by looking in
    whatever folder it happens to run in."""
    if login_dirs is None:
        from .installed_agent_inventory import login_shell_path_dirs

        login_dirs = login_shell_path_dirs()
    env = {
        key: value
        for key, value in (os.environ if environ is None else environ).items()
        if not key.startswith("JRBAR_")
    }
    parts: list[str] = []
    for part in [*env.get("PATH", "").split(os.pathsep), *(str(directory) for directory in login_dirs)]:
        if part and os.path.isabs(part) and part.isprintable() and part not in parts:
            parts.append(part)
    env["PATH"] = os.pathsep.join(parts)
    return env


def _directory_is_safe(path: str, uid: int, group_roots: Sequence[str]) -> bool:
    """A real directory owned by root or the person that nobody else can write
    into: never world-writable, group-writable only under a Homebrew prefix,
    no setuid, setgid or sticky bits (the inventory's own rule)."""
    try:
        info = os.lstat(path)
    except OSError:
        return False
    if not stat.S_ISDIR(info.st_mode) or info.st_uid not in (0, uid):
        return False
    mode = stat.S_IMODE(info.st_mode)
    if mode & 0o7002:
        return False
    if mode & 0o020:
        return any(path == root or path.startswith(root + os.sep) for root in group_roots)
    return True


def _executable_is_trusted(candidate: str, uid: int, group_roots: Sequence[str]) -> bool:
    """Whether ``candidate`` (a PATH entry joined to the CLI's name) may be run.

    What is judged: the directory that holds the entry, and, after following
    every symlink (npm, Homebrew and the CLIs' own installers all link their
    commands), the file it points at and the directory that holds that file.
    The link itself is never judged, only where it lands. The file must be a
    regular, executable file owned by root or the person, writable by no one
    else, with no setuid or setgid bit; both directories pass
    ``_directory_is_safe``."""
    if not candidate.isprintable():
        return False
    try:
        real = os.path.realpath(candidate)
        entry_directory = os.path.realpath(os.path.dirname(candidate))
        info = os.lstat(real)
    except OSError:
        return False
    if not real.isprintable():
        return False
    mode = stat.S_IMODE(info.st_mode)
    if not stat.S_ISREG(info.st_mode) or info.st_uid not in (0, uid):
        return False
    if mode & 0o6022 or not mode & 0o111 or not os.access(real, os.X_OK):
        return False
    roots = tuple(os.path.realpath(root) for root in group_roots)
    return _directory_is_safe(entry_directory, uid, roots) and _directory_is_safe(
        os.path.dirname(real), uid, roots
    )


def resolve_cli(
    binary: str,
    *,
    environ: Mapping[str, str] | None = None,
    login_dirs: Sequence[Path | str] | None = None,
    group_writable_roots: Sequence[str] = GROUP_WRITABLE_ROOTS,
) -> str | None:
    """The CLI's absolute path, or ``None`` when it is not on this Mac or is
    not safe to run.

    Looks in the person's PATH, the login shell's PATH and the usual install
    folders (``hook_compatibility``), in that order, ignoring relative entries.
    A match that fails ``_executable_is_trusted`` is skipped, as if it were
    not there. Because this daemon runs the result on a click (an updater,
    ``claude -p``, a typed terminal command), it holds the same line as the
    installed-agent inventory: owned by root or the person, writable by
    nobody else."""
    from .hook_compatibility import _search_path

    if not binary or os.sep in binary or not binary.isprintable():
        return None
    uid = os.getuid()
    search = _search_path(search_environment(environ, login_dirs=login_dirs))
    seen: set[str] = set()
    for directory in search.split(os.pathsep):
        if not directory or not os.path.isabs(directory) or directory in seen:
            continue
        seen.add(directory)
        candidate = os.path.join(directory, binary)
        if _executable_is_trusted(candidate, uid, group_writable_roots):
            return os.path.abspath(candidate)
    return None


# ---------------------------------------------------------------------------
# Running it


@dataclass(frozen=True, slots=True)
class RunResult:
    """What one bounded run did. ``returncode`` is ``None`` when the child
    never started or was killed for taking too long; ``output`` is the last
    ``OUTPUT_CAP_BYTES`` of its stdout and stderr and must be treated as
    private: it is for a tail of a sentence, never for a log."""

    returncode: int | None
    output: str
    timed_out: bool = False
    #: Set when the child could not be started at all.
    error: str | None = None


def _kill_group(process: subprocess.Popen) -> None:
    """End the child and everything it started. The child leads its own
    session, so its process group id is its pid."""
    try:
        os.killpg(process.pid, signal.SIGKILL)
    except (ProcessLookupError, PermissionError):
        try:
            process.kill()
        except OSError:
            pass
    except OSError:
        pass


def run_bounded(
    argv: Sequence[str],
    *,
    cwd: str | os.PathLike[str] | None,
    env: Mapping[str, str],
    timeout_seconds: float,
    output_cap: int = OUTPUT_CAP_BYTES,
    popen: Callable[..., subprocess.Popen] = subprocess.Popen,
) -> RunResult:
    """Run ``argv`` (a list, never a shell) with stdin closed and a hard
    timeout. Past the timeout the whole process group is killed. Output is
    drained as it arrives and only its last ``output_cap`` bytes are kept."""
    command = [str(part) for part in argv]
    try:
        process = popen(
            command,
            cwd=None if cwd is None else str(cwd),
            env=dict(env),
            stdin=subprocess.DEVNULL,
            stdout=subprocess.PIPE,
            stderr=subprocess.STDOUT,
            start_new_session=True,
            close_fds=True,
        )
    except (OSError, ValueError, subprocess.SubprocessError):
        return RunResult(None, "", False, "spawn_failed")
    tail = bytearray()
    stream = process.stdout

    def drain() -> None:
        if stream is None:
            return
        try:
            while True:
                chunk = os.read(stream.fileno(), 65536)
                if not chunk:
                    return
                tail.extend(chunk)
                overflow = len(tail) - output_cap
                if overflow > 0:
                    del tail[:overflow]
        except (OSError, ValueError):
            return

    reader = threading.Thread(target=drain, name="JRBarProviderCliOutput", daemon=True)
    reader.start()
    timed_out = False
    try:
        process.wait(timeout=max(0.1, float(timeout_seconds)))
    except subprocess.TimeoutExpired:
        timed_out = True
        _kill_group(process)
        try:
            process.wait(timeout=_KILL_WAIT_SECONDS)
        except subprocess.TimeoutExpired:
            pass
    reader.join(timeout=_READER_JOIN_SECONDS)
    if stream is not None:
        try:
            stream.close()
        except (OSError, ValueError):
            pass
    return RunResult(
        None if timed_out else process.returncode,
        bytes(tail).decode("utf-8", errors="replace"),
        timed_out,
    )


# ---------------------------------------------------------------------------
# Words that are safe to say

_ANSI: Final = re.compile(r"\x1b\[[0-?]*[ -/]*[@-~]|\x1b\][^\x07\x1b]*(?:\x07|\x1b\\)")
#: Things that look like a credential: a vendor prefix, a bearer header, a
#: ``key=value`` pair whose key names a secret, or any long unbroken run.
_TOKEN_PATTERNS: Final = (
    re.compile(r"(?i)\bbearer\s+\S+"),
    re.compile(r"(?i)\bauthorization\s*[:=]\s*\S+"),
    re.compile(r"(?i)\b[\w.-]*(?:token|secret|password|passwd|api[_-]?key|apikey|credential)[\w.-]*\s*[:=]\s*\S+"),
    re.compile(r"\b(?:sk|pk|rk|xai|ghp|gho|ghs|github_pat|glpat|ya29|eyJ)[A-Za-z0-9_\-.]{8,}"),
    re.compile(r"[A-Za-z0-9_\-+=]{32,}"),
)


def scrub(text: str) -> str:
    """``text`` with terminal escapes and anything that looks like a token
    taken out."""
    cleaned = _ANSI.sub("", text).replace("\r", "\n")
    for pattern in _TOKEN_PATTERNS:
        cleaned = pattern.sub("[removed]", cleaned)
    return cleaned


def tail_lines(text: str, *, lines: int = OUTPUT_TAIL_LINES, cap: int = OUTPUT_CAP_BYTES) -> list[str]:
    """The last ``lines`` non-empty lines of ``text`` after ``scrub``,
    within ``cap`` bytes."""
    kept = [line.strip() for line in scrub(text).splitlines() if line.strip()][-lines:]
    while kept and sum(len(line.encode("utf-8")) + 1 for line in kept) > cap:
        kept.pop(0)
    return kept


# ---------------------------------------------------------------------------
# Versions


def installed_version(
    executable: str,
    *,
    cwd: str | os.PathLike[str],
    env: Mapping[str, str],
    run: Callable[..., RunResult] = run_bounded,
    timeout_seconds: float = 15.0,
) -> str | None:
    """The CLI's own version as dotted numbers (``2.1.285``), or ``None``.

    A node CLI is read from its ``package.json`` without running it; any
    other answers ``--version``. Not cached: an update just changed it."""
    from .hook_compatibility import node_package_version, parse_version

    try:
        packaged = node_package_version(os.path.realpath(executable))
    except OSError:
        packaged = None
    parsed = parse_version(packaged) if packaged is not None else None
    if parsed is None:
        result = run(
            [executable, "--version"],
            cwd=cwd,
            env=env,
            timeout_seconds=timeout_seconds,
            output_cap=1024,
        )
        parsed = parse_version(result.output) if result.returncode == 0 else None
    return ".".join(str(part) for part in parsed) if parsed else None


__all__ = [
    "GEMINI_UPDATE_ADVICE",
    "GROUP_WRITABLE_ROOTS",
    "OUTPUT_CAP_BYTES",
    "OUTPUT_TAIL_LINES",
    "PROVIDER_CLIS",
    "ProviderCli",
    "RunResult",
    "installed_version",
    "resolve_cli",
    "run_bounded",
    "scrub",
    "search_environment",
    "tail_lines",
]
