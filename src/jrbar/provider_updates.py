"""Provider updates on a click, and an opt-in "update available".

T3 Code shows each agent CLI's version with an "Update now" button that runs the
provider's own updater. This is the same for JR-Bar:

* ``update`` runs the CLI's own updater or its proven global installation manager
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
import logging
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
    ProviderUpdateCommand,
    RunResult,
    installed_version,
    resolve_cli,
    resolve_update_command,
    run_bounded,
    search_environment,
    tail_lines,
)

_log = logging.getLogger(__name__)

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
    "(yes/no)",
    "press enter",
    "not a tty",
    "not a terminal",
    "stdin is not a",
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
    updatable: bool | None = None
    update_advice: str | None = None
    up_to_date_version: str | None = None


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
        self._running_managers: dict[str, tuple[str, str]] = {}
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
            current = record.up_to_date_version if visible else None
            if record.phase == "idle" and latest is None and current is None and record.updatable is None:
                continue
            document[provider] = {
                "phase": record.phase,
                "from_version": record.from_version,
                "to_version": record.to_version,
                "latest_version": latest,
                "up_to_date_version": current,
                "message": record.message,
                "finished_at": record.finished_at,
                "updatable": record.updatable,
                "update_advice": record.update_advice,
            }
        return document

    def _installation(self, cli: ProviderCli) -> tuple[str | None, ProviderUpdateCommand | None, str | None, str | None]:
        executable = self._locate(cli.binary)
        if executable is None:
            return None, None, "not_installed", (
                f"{cli.label} is not installed on this Mac (no `{cli.binary}` command was found)."
            )
        command = resolve_update_command(cli, executable)
        if command is None:
            message = GEMINI_UPDATE_ADVICE if cli.provider == "gemini" else (
                f"{cli.label}'s installation is not a known global npm or Homebrew install. "
                "Update it with the manager you used to install it."
            )
            return executable, None, "no_updater", message
        return executable, command, None, None

    def _set_capability(self, provider: str, updatable: bool | None, advice: str | None) -> bool:
        with self._lock:
            previous = self._records.get(provider, UpdateRecord())
            record = replace(previous, updatable=updatable, update_advice=advice)
            if record == previous:
                return False
            self._records[provider] = record
        return True

    def refresh_capabilities(self) -> None:
        """Assess local installation paths during the existing doctor refresh."""
        changed = False
        for provider, cli in PROVIDER_CLIS.items():
            try:
                _, command, _, advice = self._installation(cli)
                updatable = command is not None
            except Exception:
                updatable, advice = None, None
            changed = self._set_capability(provider, updatable, advice) or changed
        if changed:
            self._publish()

    def _publish(self) -> None:
        if self._on_change is not None:
            try:
                self._on_change()
            except Exception:
                _log.warning("provider update change listener failed", exc_info=True)

    # -- the click ---------------------------------------------------------------------

    def update(self, provider: str) -> dict[str, Any]:
        """``provider_update``: start the installation's updater, or say why not."""
        cli = PROVIDER_CLIS.get(provider)
        if cli is None or (cli.update is None and provider not in {"codex", "gemini"}):
            message = GEMINI_UPDATE_ADVICE if provider == "gemini" else (
                f"{PRODUCT_DISPLAY_NAME} has no updater to run for {provider}: update it the way "
                "you installed it."
            )
            return self._refusal(provider, "no_updater", message)
        executable, command, reason, advice = self._installation(cli)
        if executable is None or command is None:
            if self._set_capability(provider, False, advice):
                self._publish()
            return self._refusal(provider, reason or "no_updater", advice or "No updater is available.")
        manager_key = self._manager_key(cli, command)
        with self._lock:
            if provider in self._running:
                return self._refusal(provider, "busy", f"An update for {cli.label} is already running.")
            if manager_key is not None and manager_key in self._running_managers.values():
                manager = "npm" if manager_key[0] == "npm" else "Homebrew"
                return self._refusal(provider, "busy", f"Another update is using this {manager} installation. Try again when it finishes.")
            if len(self._running) >= MAX_CONCURRENT_UPDATES:
                return self._refusal(
                    provider, "busy", "Two updates are already running. Try again when one finishes."
                )
            self._running.add(provider)
            if manager_key is not None:
                self._running_managers[provider] = manager_key
            previous = self._records.get(provider, UpdateRecord())
            self._records[provider] = replace(
                previous,
                phase="running",
                from_version=None,
                to_version=None,
                message=f"Updating {cli.label}…",
                finished_at=None,
                updatable=True,
                update_advice=None,
                up_to_date_version=None,
            )
        self._publish()
        try:
            self._start(lambda: self._worker(provider, cli, executable, command), f"JRBarProviderUpdate-{provider}")
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
    def _manager_key(cli: ProviderCli, command: ProviderUpdateCommand) -> tuple[str, str] | None:
        if cli.provider not in {"codex", "gemini"}:
            return None
        if Path(command.executable).name == "npm":
            prefix = command.arguments[command.arguments.index("--prefix") + 1]
            return "npm", str(Path(prefix).resolve())
        if Path(command.executable).name == "brew":
            return "homebrew", str(Path(command.executable).resolve())
        return None

    @staticmethod
    def _refusal(provider: str, reason: str, message: str) -> dict[str, Any]:
        return {"provider": provider, "started": False, "reason": reason, "message": message}

    # -- the worker --------------------------------------------------------------------------

    def _worker(self, provider: str, cli: ProviderCli, executable: str, command: ProviderUpdateCommand) -> None:
        phase, before, after = "failed", None, None
        message = f"{cli.label}'s updater stopped unexpectedly."
        try:
            try:
                phase, before, after, message = self._perform(cli, executable, command)
            except Exception:
                pass
            self._log(f"core: provider update {provider} {phase}")
        finally:
            self._finish(provider, phase, before, after, message)

    def _stage(self, provider: str, message: str, before: str | None = None) -> None:
        with self._lock:
            record = self._records.get(provider)
            if provider not in self._running or record is None or record.phase != "running":
                return
            self._records[provider] = replace(
                record,
                from_version=before if before is not None else record.from_version,
                message=message,
            )
        self._publish()

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
            self._running_managers.pop(provider, None)
            record = self._records.get(provider, UpdateRecord())
            latest = record.latest_version
            if after is not None and latest is not None and not is_newer(latest, after):
                latest = None
            self._records[provider] = replace(
                record,
                phase=phase,
                from_version=before if before is not None else record.from_version,
                to_version=after,
                latest_version=latest,
                message=_one_line(message),
                finished_at=float(self._clock()),
            )
        self._publish()

    def _perform(self, cli: ProviderCli, executable: str, command: ProviderUpdateCommand) -> tuple[str, str | None, str | None, str]:
        home = self._home()
        env = search_environment(self._environ() if self._environ is not None else None)
        if cli.provider in {"codex", "gemini"}:
            if resolve_update_command(cli, executable) != command:
                return "failed", None, None, f"{cli.label}'s installation changed before its update could start."
            manager_directory = str(Path(command.executable).parent)
            env["PATH"] = manager_directory + ":" + env.get("PATH", "")
        self._stage(cli.provider, "Checking installed version…")
        before = installed_version(executable, cwd=home, env=env, run=self._run)
        self._stage(cli.provider, "Running updater…", before)
        if cli.update_needs_terminal:
            return self._needs_terminal(cli, executable, before, command)
        result = self._run(
            [command.executable, *command.arguments],
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
                return self._needs_terminal(cli, executable, before, command)
            detail = " / ".join(lines[-2:])
            code = result.returncode
            sentence = f"{cli.label}'s updater failed (exit {code})"
            return "failed", before, None, f"{sentence}: {detail}" if detail else f"{sentence}."
        self._stage(cli.provider, "Verifying installed version…")
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
        command: ProviderUpdateCommand,
    ) -> tuple[str, str | None, str | None, str]:
        display = " ".join((Path(command.executable).name, *command.arguments))
        typed = " ".join(shlex.quote(part) for part in (command.executable, *command.arguments))
        manager_key = self._manager_key(cli, command)
        if manager_key is not None:
            # A detached terminal cannot release a tracked manager reservation.
            # Stop the managed attempt and leave the explicit manual step to the user.
            message = f"{cli.label}'s updater needs a terminal. Run `{typed}` yourself."
            if len(message) > MESSAGE_LIMIT:
                manager = "npm" if manager_key[0] == "npm" else "Homebrew"
                message = (
                    f"{cli.label}'s updater needs a terminal. Update it with its original "
                    f"{manager} installation."
                )
            return "needs_terminal", before, None, message
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
                self._last_check_at = last
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
        found: dict[str, tuple[str, str | None, UpdateRecord | None]] = {}
        try:
            if self._checks_enabled() is not True:
                return
            home = self._home()
            env = search_environment(self._environ() if self._environ is not None else None)
            for provider, cli in PROVIDER_CLIS.items():
                if self._checks_enabled() is not True:
                    break
                if cli.npm_package is None:
                    continue
                executable = self._locate(cli.binary)
                if executable is None:
                    continue
                with self._lock:
                    observed_record = self._records.get(provider)
                installed = installed_version(executable, cwd=home, env=env, run=self._run)
                # Turned off while this ran: ask nothing more.
                if self._checks_enabled() is not True:
                    break
                latest = self._fetch_latest(cli.npm_package)
                if latest is None:
                    continue
                found[provider] = latest, installed, observed_record
        except Exception:
            pass
        finally:
            changed = False
            with self._lock:
                self._check_running = False
                for provider, (offer, installed, observed_record) in found.items():
                    record = self._records.get(provider, UpdateRecord())
                    if (record is not observed_record and record.phase in {"updated", "unchanged"}
                            and record.to_version is not None):
                        installed = record.to_version
                    latest = offer if is_newer(offer, installed) else None
                    current = None
                    offered_numbers, installed_numbers = _numbers(offer), _numbers(installed)
                    if (record.phase in {"idle", "updated", "unchanged"}
                            and offered_numbers is not None and installed_numbers is not None
                            and installed_numbers >= offered_numbers):
                        current = installed
                    if record.latest_version != latest or record.up_to_date_version != current:
                        self._records[provider] = replace(
                            record, latest_version=latest, up_to_date_version=current)
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
