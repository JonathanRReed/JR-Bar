"""Provider updates: the CLI's own updater on a click, and an opt-in "update available".

T3 Code shows each agent CLI's version with an "Update now" button that runs the
provider's own updater. This is the same for JR-Bar:

* ``update`` runs the CLI's own updater (``grok update``, ``codex update``, ...)
  on a worker thread and returns at once. The command comes from the table in
  ``provider_cli`` and the client sends only a provider id, so nothing the app
  or a setting says can put a different command there, and nothing here runs an
  updater on its own: only a click starts one.
* The result lives in the state document (``state.provider_updates``), where a
  running update is one phase and never a stream of progress.
* ``check`` asks the npm registry whether a newer version exists, and only while
  ``provider_update_checks_enabled`` is on. Off, there is no request and no
  thread. The Update button never needs it.

Every outside effect (finding the CLI, running it, the registry, the terminal,
the clock, starting a thread) is handed in, so a test drives the whole thing
with fake executables and no waiting.
"""

from __future__ import annotations

import json
import shlex
import threading
import time
from collections.abc import Callable, Mapping
from dataclasses import dataclass, replace
from pathlib import Path
from typing import Any, Final
from urllib.error import HTTPError, URLError
from urllib.request import HTTPRedirectHandler, HTTPSHandler, Request, build_opener

from .product_identity import PRODUCT_DISPLAY_NAME
from .provider_cli import (
    GEMINI_UPDATE_ADVICE,
    PROVIDER_CLIS,
    ProviderCli,
    RunResult,
    installed_version,
    resolve_cli,
    run_bounded,
    search_environment,
    tail_lines,
)

PHASES: Final = ("idle", "running", "updated", "unchanged", "failed", "needs_terminal")

UPDATE_TIMEOUT_SECONDS: Final = 600.0
#: At most this many updaters run at once, one per provider.
MAX_CONCURRENT_UPDATES: Final = 2
#: "Update available" is asked at most this often by the daemon's own tick,
#: and at most this often when the Agents page asks for a fresh look.
CHECK_INTERVAL_SECONDS: Final = 6 * 60 * 60.0
FORCED_CHECK_MIN_INTERVAL_SECONDS: Final = 60.0
REGISTRY_TIMEOUT_SECONDS: Final = 5.0
REGISTRY_MAX_BYTES: Final = 256 * 1024
REGISTRY_USER_AGENT: Final = f"{PRODUCT_DISPLAY_NAME}/update-check"
MESSAGE_LIMIT: Final = 240

#: What an updater prints when it wanted a terminal and found none (stdin is
#: closed). Looked for only after a run that failed.
_NEEDS_TERMINAL_MARKERS: Final = (
    "[y/n]",
    "(y/n)",
    "[y/n/",
    "(yes/no)",
    "press enter",
    "not a tty",
    "not a terminal",
    "no tty",
    "stdin is not",
    "interactive terminal",
    "requires a terminal",
    "in a terminal",
    "inappropriate ioctl",
    "raw mode is not supported",
)


@dataclass(frozen=True, slots=True)
class UpdateRecord:
    """What one provider's updater last did (``state.provider_updates``)."""

    phase: str = "idle"
    from_version: str | None = None
    to_version: str | None = None
    #: A newer version the registry offers; set only by an enabled check.
    latest_version: str | None = None
    message: str = ""
    finished_at: float | None = None


# --- versions ------------------------------------------------------------------


def _numbers(version: str | None) -> tuple[int, ...] | None:
    from .hook_compatibility import parse_version

    parsed = parse_version(version) if version else None
    return None if parsed is None else tuple(parsed) + (0,) * (4 - len(parsed))


def is_newer(candidate: str | None, installed: str | None) -> bool:
    """Whether ``candidate`` is a later dotted version than ``installed``."""
    later, current = _numbers(candidate), _numbers(installed)
    return later is not None and current is not None and later > current


# --- the npm registry ---------------------------------------------------------------


class _NoRedirects(HTTPRedirectHandler):
    def redirect_request(self, req, fp, code, msg, headers, newurl):
        return None


def fetch_latest_version(
    package: str,
    *,
    timeout: float = REGISTRY_TIMEOUT_SECONDS,
    max_bytes: int = REGISTRY_MAX_BYTES,
) -> str | None:
    """The package's ``latest`` version from registry.npmjs.org, or ``None``.

    One plain GET: https only, no cookies, no credentials, no redirects, a plain
    User-Agent, a short timeout, a capped body. Nothing about this Mac is in it.
    Any failure is ``None``: an unreachable registry is silence, not an alarm."""
    url = f"https://registry.npmjs.org/{package}/latest"
    request = Request(
        url,
        headers={"Accept": "application/json", "User-Agent": REGISTRY_USER_AGENT},
        method="GET",
    )
    opener = build_opener(_NoRedirects(), HTTPSHandler())
    try:
        with opener.open(request, timeout=timeout) as response:
            body = response.read(max_bytes + 1)
            status = int(getattr(response, "status", 200))
    except (HTTPError, URLError, OSError, TimeoutError, ValueError):
        return None
    if status < 200 or status >= 300 or len(body) > max_bytes:
        return None
    try:
        document = json.loads(body.decode("utf-8"))
    except (UnicodeDecodeError, ValueError):
        return None
    if not isinstance(document, dict) or document.get("name") != package:
        return None
    version = document.get("version")
    return _dotted(version) if isinstance(version, str) else None


def _dotted(version: str) -> str | None:
    from .hook_compatibility import parse_version

    parsed = parse_version(version)
    return ".".join(str(part) for part in parsed) if parsed else None


def _start_thread(target: Callable[[], None], name: str) -> None:
    threading.Thread(target=target, name=name, daemon=True).start()


def _one_line(text: str) -> str:
    collapsed = " ".join(text.split())
    if len(collapsed) <= MESSAGE_LIMIT:
        return collapsed
    return collapsed[: MESSAGE_LIMIT - 1].rstrip() + "…"


# --- the coordinator ---------------------------------------------------------------------


class ProviderUpdates:
    """The daemon's updater and update-check state. One lives for the daemon's
    life; ``update`` and ``check`` return at once and the work runs on threads
    of their own."""

    def __init__(
        self,
        *,
        checks_enabled: Callable[[], bool] = lambda: False,
        locate: Callable[[str], str | None] = resolve_cli,
        run: Callable[..., RunResult] = run_bounded,
        open_terminal: Callable[..., dict[str, Any]] | None = None,
        fetch_latest: Callable[[str], str | None] = fetch_latest_version,
        clock: Callable[[], float] = time.time,
        monotonic: Callable[[], float] = time.monotonic,
        start: Callable[[Callable[[], None], str], None] = _start_thread,
        on_change: Callable[[], None] | None = None,
        environ: Callable[[], Mapping[str, str]] | None = None,
        home: Callable[[], Path] = Path.home,
        log: Callable[[str], None] | None = None,
    ) -> None:
        self._checks_enabled = checks_enabled
        self._locate = locate
        self._run = run
        self._open_terminal = open_terminal
        self._fetch_latest = fetch_latest
        self._clock = clock
        self._monotonic = monotonic
        self._start = start
        self._on_change = on_change
        self._environ = environ
        self._home = home
        self._log = log or (lambda _line: None)
        self._lock = threading.Lock()
        self._records: dict[str, UpdateRecord] = {}
        self._running: set[str] = set()
        self._check_running = False
        self._last_check_at: float | None = None

    # -- the state document ---------------------------------------------------------

    def document(self) -> dict[str, dict[str, Any]]:
        """``state.provider_updates``: an entry for every provider that has
        something to say. ``latest_version`` is shown only while update checks
        are on, so turning them off takes "available" off the screen at once."""
        visible = self._checks_enabled() is True
        with self._lock:
            records = dict(self._records)
        document: dict[str, dict[str, Any]] = {}
        for provider, record in records.items():
            latest = record.latest_version if visible else None
            if record.phase == "idle" and latest is None:
                continue
            document[provider] = {
                "phase": record.phase,
                "from_version": record.from_version,
                "to_version": record.to_version,
                "latest_version": latest,
                "message": record.message,
                "finished_at": record.finished_at,
            }
        return document

    def _publish(self) -> None:
        if self._on_change is not None:
            try:
                self._on_change()
            except Exception:
                pass

    def _set(self, provider: str, **changes: Any) -> None:
        with self._lock:
            self._records[provider] = replace(self._records.get(provider, UpdateRecord()), **changes)

    # -- the click ---------------------------------------------------------------------

    def update(self, provider: str) -> dict[str, Any]:
        """``provider_update``: start the provider's own updater, or say why not."""
        cli = PROVIDER_CLIS.get(provider)
        if cli is None or cli.update is None:
            message = GEMINI_UPDATE_ADVICE if provider == "gemini" else (
                f"{PRODUCT_DISPLAY_NAME} has no updater to run for {provider}: update it the way "
                "you installed it."
            )
            return self._refusal(provider, "no_updater", message)
        executable = self._locate(cli.binary)
        if executable is None:
            return self._refusal(
                provider,
                "not_installed",
                f"{cli.label} is not installed on this Mac (no `{cli.binary}` command was found).",
            )
        with self._lock:
            if provider in self._running:
                return self._refusal(provider, "busy", f"An update for {cli.label} is already running.")
            if len(self._running) >= MAX_CONCURRENT_UPDATES:
                return self._refusal(
                    provider, "busy", "Two updates are already running. Try again when one finishes."
                )
            self._running.add(provider)
            previous = self._records.get(provider, UpdateRecord())
            self._records[provider] = replace(
                previous,
                phase="running",
                from_version=None,
                to_version=None,
                message=f"Updating {cli.label}…",
                finished_at=None,
            )
        self._publish()
        try:
            self._start(lambda: self._worker(provider, cli, executable), f"JRBarProviderUpdate-{provider}")
        except Exception:
            self._finish(provider, "failed", None, None, f"{PRODUCT_DISPLAY_NAME} could not start the updater.")
            return self._refusal(provider, "busy", f"{PRODUCT_DISPLAY_NAME} could not start the updater.")
        return {
            "provider": provider,
            "started": True,
            "reason": None,
            "message": f"Updating {cli.label}…",
        }

    @staticmethod
    def _refusal(provider: str, reason: str, message: str) -> dict[str, Any]:
        return {"provider": provider, "started": False, "reason": reason, "message": message}

    # -- the worker --------------------------------------------------------------------------

    def _worker(self, provider: str, cli: ProviderCli, executable: str) -> None:
        try:
            phase, before, after, message = self._perform(cli, executable)
        except Exception:
            phase, before, after = "failed", None, None
            message = f"{cli.label}'s updater stopped unexpectedly."
        self._log(f"core: provider update {provider} {phase}")
        self._finish(provider, phase, before, after, message)

    def _finish(
        self,
        provider: str,
        phase: str,
        before: str | None,
        after: str | None,
        message: str,
    ) -> None:
        with self._lock:
            self._running.discard(provider)
            record = self._records.get(provider, UpdateRecord())
            latest = record.latest_version
            if after is not None and latest is not None and not is_newer(latest, after):
                latest = None
            self._records[provider] = replace(
                record,
                phase=phase,
                from_version=before,
                to_version=after,
                latest_version=latest,
                message=_one_line(message),
                finished_at=float(self._clock()),
            )
        self._publish()

    def _perform(self, cli: ProviderCli, executable: str) -> tuple[str, str | None, str | None, str]:
        home = self._home()
        env = search_environment(self._environ() if self._environ is not None else None)
        before = installed_version(executable, cwd=home, env=env, run=self._run)
        if cli.update_needs_terminal:
            return self._needs_terminal(cli, executable, before)
        result = self._run(
            [executable, *(cli.update or ())],
            cwd=home,
            env=env,
            timeout_seconds=UPDATE_TIMEOUT_SECONDS,
            output_cap=4096,
        )
        if result.error is not None:
            return "failed", before, None, f"{PRODUCT_DISPLAY_NAME} could not start {cli.label}'s updater."
        if result.timed_out:
            return (
                "failed",
                before,
                None,
                f"{cli.label}'s updater did not finish within 10 minutes and was stopped.",
            )
        lines = tail_lines(result.output)
        if result.returncode != 0:
            lowered = "\n".join(lines).lower()
            if any(marker in lowered for marker in _NEEDS_TERMINAL_MARKERS):
                return self._needs_terminal(cli, executable, before)
            detail = " / ".join(lines[-2:])
            code = result.returncode
            sentence = f"{cli.label}'s updater failed (exit {code})"
            return "failed", before, None, f"{sentence}: {detail}" if detail else f"{sentence}."
        after = installed_version(executable, cwd=home, env=env, run=self._run)
        if before is not None and after is not None:
            if before == after:
                return "unchanged", before, after, f"Already up to date ({after})"
            return "updated", before, after, f"Updated {before} to {after}"
        if after is not None:
            return "updated", before, after, f"Updated to {after}"
        return (
            "unchanged",
            before,
            after,
            f"{cli.label}'s updater finished, but its version could not be read to confirm a change.",
        )

    def _needs_terminal(
        self,
        cli: ProviderCli,
        executable: str,
        before: str | None,
    ) -> tuple[str, str | None, str | None, str]:
        display = cli.update_display() or cli.binary
        typed = " ".join(shlex.quote(part) for part in (executable, *(cli.update or ())))
        opener = self._open_terminal
        if opener is None:
            from .answer_surfaces import run_command_in_terminal

            opener = run_command_in_terminal
        try:
            opened = opener(str(self._home()), typed)
        except Exception:
            return (
                "failed",
                before,
                None,
                f"{cli.label}'s updater needs a terminal and none could be opened. Run `{display}` yourself.",
            )
        app = str(opened.get("app") or "your terminal")
        return (
            "needs_terminal",
            before,
            None,
            f"{cli.label}'s updater needs a terminal: opened {app} on `{display}`. Finish the update there.",
        )

    # -- "update available": opt in, off by default -----------------------------------------------

    def check(self, *, forced: bool = False) -> dict[str, Any]:
        """Ask the registry about newer versions: ``{enabled, started}``. With
        update checks off this does nothing at all: no request, no thread."""
        if self._checks_enabled() is not True:
            return {"enabled": False, "started": False}
        interval = FORCED_CHECK_MIN_INTERVAL_SECONDS if forced else CHECK_INTERVAL_SECONDS
        now = self._monotonic()
        with self._lock:
            last = self._last_check_at
            if self._check_running or (last is not None and 0 <= now - last < interval):
                return {"enabled": True, "started": False}
            self._check_running = True
            self._last_check_at = now
        try:
            self._start(self._check_worker, "JRBarProviderUpdateCheck")
        except Exception:
            with self._lock:
                self._check_running = False
            return {"enabled": True, "started": False}
        return {"enabled": True, "started": True}

    def tick(self) -> None:
        """The daemon's own cadence: a look every 6 hours, while checks are on.
        Free while they are off."""
        if self._checks_enabled() is not True:
            # Turning checks back on is the person's act: look at once.
            self._last_check_at = None
            return
        self.check(forced=False)

    def _check_worker(self) -> None:
        found: dict[str, str | None] = {}
        try:
            home = self._home()
            env = search_environment(self._environ() if self._environ is not None else None)
            for provider, cli in PROVIDER_CLIS.items():
                if cli.npm_package is None:
                    continue
                executable = self._locate(cli.binary)
                if executable is None:
                    continue
                installed = installed_version(executable, cwd=home, env=env, run=self._run)
                # Turned off while this ran: ask nothing more.
                if self._checks_enabled() is not True:
                    break
                latest = self._fetch_latest(cli.npm_package)
                if latest is None:
                    continue
                found[provider] = latest if is_newer(latest, installed) else None
        except Exception:
            pass
        finally:
            changed = False
            with self._lock:
                self._check_running = False
                for provider, latest in found.items():
                    record = self._records.get(provider, UpdateRecord())
                    if record.latest_version != latest:
                        self._records[provider] = replace(record, latest_version=latest)
                        changed = True
            if changed:
                self._publish()


__all__ = [
    "CHECK_INTERVAL_SECONDS",
    "FORCED_CHECK_MIN_INTERVAL_SECONDS",
    "MAX_CONCURRENT_UPDATES",
    "PHASES",
    "UPDATE_TIMEOUT_SECONDS",
    "ProviderUpdates",
    "UpdateRecord",
    "fetch_latest_version",
    "is_newer",
]
