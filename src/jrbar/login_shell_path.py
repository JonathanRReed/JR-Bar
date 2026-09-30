"""The PATH the person's login shell sees, asked for off the run loop.

Under Finder or launchd the daemon's own PATH is the minimal default, and
the CLIs a person installed through npm, bun, cargo or a version manager
live in directories only their login shell adds. One
``$SHELL -lic 'printf %s "$PATH"'`` finds them, but a login shell reads the
person's rc files: right after a login it can take longer than a state
build can wait. So the answer is fetched by a thread of its own, and every
reader takes the last good answer without waiting.

* ``snapshot()`` never blocks. It is the last good answer, or ``()`` when
  there is none yet.
* ``resolved()`` says whether the daemon has finished looking: a good
  answer exists, or the probe is turned off. Until then a CLI missing from
  the literal install locations is *unknown*, never *not installed*.
* A failed probe (a timeout, a nonzero exit, empty output) is never kept as
  the answer. It only schedules the next try: 15 s, then 60 s, then every
  5 minutes.

``JRBAR_NO_SHELL_PATH=1`` turns the probe off. The test sandbox is off too
unless a test hands in its own runner, so a suite never runs the
developer's login shell.

This module spawns the shell. ``installed_agent_inventory`` stays a
read-only lstat boundary and only asks for the snapshot.
"""

from __future__ import annotations

import os
import subprocess
import threading
import time
from collections.abc import Callable
from pathlib import Path
from typing import Final

#: How long one probe may take. A cold login shell can need several
#: seconds; the probe has a thread of its own, so waiting costs nothing.
LOGIN_SHELL_PATH_TIMEOUT_SECONDS: Final = 10.0
#: Waits after the first, second and every later failed probe.
LOGIN_SHELL_RETRY_SECONDS: Final = (15.0, 60.0, 300.0)

#: Only these variables cross into the login shell's environment: the
#: probe must not inherit a launchd session's leftovers or leak ours.
_LOGIN_SHELL_PATH_ENV_KEYS: Final = ("HOME", "USER", "SHELL", "TERM")


def shell_probe_opted_out() -> bool:
    """``JRBAR_NO_SHELL_PATH=1``: never run the login shell."""
    return os.environ.get("JRBAR_NO_SHELL_PATH") == "1"


def _in_test_sandbox() -> bool:
    return os.environ.get("JRBAR_TESTING") == "1" or "PYTEST_CURRENT_TEST" in os.environ


def probe_login_shell_path(runner: Callable[..., object]) -> tuple[Path, ...] | None:
    """Ask the login shell for its PATH with ``runner`` (a ``subprocess.run``
    stand-in). ``None`` on any failure: an exception, a timeout, a nonzero
    exit, output that is not text, or an empty PATH."""
    env = {key: os.environ[key] for key in _LOGIN_SHELL_PATH_ENV_KEYS if key in os.environ}
    try:
        completed = runner(
            [os.environ.get("SHELL") or "/bin/zsh", "-lic", 'printf %s "$PATH"'],
            stdin=subprocess.DEVNULL,
            stdout=subprocess.PIPE,
            stderr=subprocess.DEVNULL,
            env=env,
            timeout=LOGIN_SHELL_PATH_TIMEOUT_SECONDS,
            text=True,
        )
    except Exception:
        return None
    if getattr(completed, "returncode", 1) != 0:
        return None
    output = getattr(completed, "stdout", "")
    if type(output) is not str:
        return None
    # A login-interactive shell can decorate stdout around the payload;
    # the PATH print is the last thing it emits.
    lines = output.splitlines()
    path_text = lines[-1].strip() if lines else ""
    directories = tuple(Path(entry) for entry in path_text.split(os.pathsep) if entry)
    return directories or None


def _start_daemon_thread(target: Callable[[], None]) -> None:
    threading.Thread(target=target, name="JRBarLoginShellPath", daemon=True).start()


class LoginShellPathProbe:
    """One login-shell PATH lookup on a thread of its own, retried on a
    backoff until it answers. Every dependency is handed in so a test runs
    it with no shell, no thread and no clock."""

    def __init__(
        self,
        *,
        runner: Callable[..., object] | None = None,
        clock: Callable[[], float] = time.monotonic,
        start: Callable[[Callable[[], None]], None] = _start_daemon_thread,
    ) -> None:
        self._runner = runner
        self._clock = clock
        self._start = start
        self._lock = threading.Lock()
        self._answer: tuple[Path, ...] | None = None
        self._failures = 0
        self._failed_at: float | None = None
        self._running = False

    def _off(self) -> bool:
        if shell_probe_opted_out():
            return True
        # Only an injected runner may run under the test sandbox.
        return self._runner is None and _in_test_sandbox()

    def snapshot(self) -> tuple[Path, ...]:
        """The last good answer, or ``()``. Never waits."""
        answer = self._answer
        return answer if answer is not None else ()

    def resolved(self) -> bool:
        """True when the answer is in, or the probe is turned off."""
        return self._off() or self._answer is not None

    def ensure_started(self, on_done: Callable[[], None] | None = None) -> bool:
        """Start the lookup unless one is running, an answer is in, or the
        last failure is younger than its backoff. Returns at once; True
        when it started a thread. ``on_done`` runs on that thread after the
        first good answer, and never after a failure."""
        if self._off():
            return False
        with self._lock:
            if self._answer is not None or self._running:
                return False
            if self._failed_at is not None:
                wait = LOGIN_SHELL_RETRY_SECONDS[min(self._failures, len(LOGIN_SHELL_RETRY_SECONDS)) - 1]
                if self._clock() - self._failed_at < wait:
                    return False
            self._running = True
        try:
            self._start(lambda: self._run(on_done))
        except Exception:
            with self._lock:
                self._running = False
            return False
        return True

    def _run(self, on_done: Callable[[], None] | None) -> None:
        try:
            answer = probe_login_shell_path(self._runner or subprocess.run)
        except Exception:
            answer = None
        with self._lock:
            self._running = False
            if answer:
                self._answer = answer
                self._failures = 0
                self._failed_at = None
            else:
                self._failures += 1
                self._failed_at = self._clock()
        if answer and on_done is not None:
            try:
                on_done()
            except Exception:
                pass


_default_probe: LoginShellPathProbe | None = None
_default_probe_lock = threading.Lock()


def default_login_shell_probe() -> LoginShellPathProbe:
    """The daemon's shared probe."""
    global _default_probe
    with _default_probe_lock:
        if _default_probe is None:
            _default_probe = LoginShellPathProbe()
        return _default_probe


def set_default_login_shell_probe(probe: LoginShellPathProbe | None) -> LoginShellPathProbe | None:
    """Replace the shared probe (``None`` builds a fresh one on next use)
    and return the one it replaced. For tests."""
    global _default_probe
    with _default_probe_lock:
        previous, _default_probe = _default_probe, probe
        return previous


__all__ = [
    "LOGIN_SHELL_PATH_TIMEOUT_SECONDS",
    "LOGIN_SHELL_RETRY_SECONDS",
    "LoginShellPathProbe",
    "default_login_shell_probe",
    "probe_login_shell_path",
    "set_default_login_shell_probe",
    "shell_probe_opted_out",
]
