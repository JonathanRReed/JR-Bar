"""Where a live session is drawn, and how to put it in front of the owner.

Opening a live CLI session used to launch ``cd <cwd> && claude --resume
<id>`` in whatever terminal was frontmost: a second process on the same
session, in a new window, while the real one kept running somewhere else.
A live session already has a window. This module finds it and raises it:

* a pane inside tmux -- ``tmux list-panes -a`` names every pane's tty, so
  the session's own tty picks the pane, and ``select-window`` /
  ``select-pane`` put it in front of the client attached to it;
* a Terminal.app or iTerm2 tab -- both name each tab's tty over Apple
  events, so the tab is selected by the session's tty exactly;
* a Ghostty terminal -- Ghostty 1.3 names each terminal surface's id and
  working directory over Apple events and can ``focus`` one. The surface
  recorded when the session started wins; otherwise the one terminal in the
  session's working directory, or the one whose title carries the
  session's name. Two candidates and no record is a tie, and a tie is never
  guessed: Ghostty is brought forward and the reply says so;
* any other host (kitty, WezTerm, Warp, an IDE's terminal) -- the app.

``--resume`` stays the path for a session that has ended. A session that is
running where JR-Bar cannot find it refuses instead of starting a second
copy of itself.

The Ghostty surface is recorded at SessionStart (``SurfaceRecorder``): the
terminal the owner just typed the command into is the focused terminal of
Ghostty's front window, in the session's working directory. That probe is
an Apple event, so it runs only when macOS already allows JR-Bar to send
Ghostty Apple events -- asked with ``AEDeterminePermissionToAutomateTarget``
and ``askUserIfNeeded`` false. Starting an agent never raises a permission
prompt; the first explicit open does, where the owner can see why.
"""

from __future__ import annotations

import ctypes
import json
import os
import re
import shutil
import subprocess
import threading
import time
from collections import deque
from collections.abc import Callable, Mapping, Sequence
from dataclasses import dataclass
from pathlib import Path
from typing import Any, Final

GHOSTTY_BUNDLE_ID: Final = "com.mitchellh.ghostty"
TERMINAL_BUNDLE_ID: Final = "com.apple.Terminal"
ITERM_BUNDLE_ID: Final = "com.googlecode.iterm2"
#: A session hosted by its provider's own desktop app is opened by that
#: app's deep link (session_actions.py), not raised as a terminal.
APP_HOSTED_BUNDLE_IDS: Final = frozenset(
    {"com.anthropic.claudefordesktop", "com.openai.codex"}
)
SCRIPT_TIMEOUT_SECONDS: Final = 3.0
TMUX_TIMEOUT_SECONDS: Final = 2.0
MAX_ANCESTRY_DEPTH: Final = 12
MAX_RECORDED_SURFACES: Final = 256
#: How stale a recorded surface may be before it is dropped on load.
RECORDED_SURFACE_TTL_SECONDS: Final = 14 * 24 * 3600.0
SURFACES_FILE_NAME: Final = "session-surfaces.json"
_TMUX_CANDIDATES: Final = ("/opt/homebrew/bin/tmux", "/usr/local/bin/tmux", "/usr/bin/tmux")
_TTY: Final = re.compile(r"^/dev/tty[A-Za-z0-9]{1,16}$")
_SEP: Final = "\t"


# --- scripts (every argument arrives as argv, never spliced into source) ------

_TERMINAL_RAISE_BY_TTY: Final = """
on run argv
  set target to item 1 of argv
  tell application id "com.apple.Terminal"
    repeat with w in windows
      repeat with t in tabs of w
        if tty of t is target then
          set selected tab of w to t
          set index of w to 1
          activate
          return "tab"
        end if
      end repeat
    end repeat
  end tell
  return "missing"
end run
"""

_ITERM_RAISE_BY_TTY: Final = """
on run argv
  set target to item 1 of argv
  tell application id "com.googlecode.iterm2"
    repeat with w in windows
      repeat with t in tabs of w
        repeat with s in sessions of t
          if tty of s is target then
            select w
            tell t to select
            tell s to select
            activate
            return "tab"
          end if
        end repeat
      end repeat
    end repeat
  end tell
  return "missing"
end run
"""

# ``tab`` is a class in Ghostty's dictionary, so the separators are made
# outside its tell block.
_GHOSTTY_LIST_TERMINALS: Final = """
set sep to character id 9
set eol to character id 10
set out to ""
tell application id "com.mitchellh.ghostty"
  repeat with t in terminals
    set wd to ""
    try
      set wd to (working directory of t) as text
    end try
    set nm to ""
    try
      set nm to (name of t) as text
    end try
    set out to out & ((id of t) as text) & sep & wd & sep & nm & eol
  end repeat
end tell
return out
"""

_GHOSTTY_FOCUS: Final = """
on run argv
  set target to item 1 of argv
  tell application id "com.mitchellh.ghostty"
    repeat with t in terminals
      if ((id of t) as text) is target then
        focus t
        activate
        return "terminal"
      end if
    end repeat
  end tell
  return "missing"
end run
"""

# A new tab in Ghostty's front window (a new window when it has none), in the
# session's directory, with the resume command typed into the owner's own
# shell -- so the shell, its environment and its history are the usual ones
# and the tab stays open when the agent exits.
_GHOSTTY_NEW_TAB: Final = """
on run argv
  set wd to item 1 of argv
  set typed to item 2 of argv
  tell application id "com.mitchellh.ghostty"
    set cfg to {initial working directory:wd, initial input:typed}
    if (count of windows) > 0 then
      new tab in front window with configuration cfg
    else
      new window with configuration cfg
    end if
    activate
  end tell
  return "tab"
end run
"""

_GHOSTTY_FOCUSED_TERMINAL: Final = """
set sep to character id 9
tell application id "com.mitchellh.ghostty"
  set t to focused terminal of selected tab of front window
  set wd to ""
  try
    set wd to (working directory of t) as text
  end try
  return ((id of t) as text) & sep & wd
end tell
"""


# --- the host ----------------------------------------------------------------


@dataclass(frozen=True, slots=True)
class SessionHost:
    """What the process table says about where a session's CLI runs."""

    pid: int | None
    tty: str | None
    app_name: str | None
    bundle_id: str | None
    in_tmux: bool = False


def host_from_ancestry(pid: object, table: Mapping[int, Any]) -> tuple[str | None, str | None, bool]:
    """``(app name, bundle id, inside tmux)`` from the session's ancestry.

    The walk starts at the PARENT: the CLI's own executable is named after
    its provider (``codex``), which reads as that provider's desktop app.
    A tmux server on the way means the terminal around it is tmux's client,
    not an ancestor, so the walk stops there.
    """
    from .core_projection import terminal_from_command

    if type(pid) is not int or pid <= 1:
        return None, None, False
    entry = table.get(pid)
    current = getattr(entry, "ppid", None)
    for _ in range(MAX_ANCESTRY_DEPTH):
        if type(current) is not int or current <= 1:
            break
        entry = table.get(current)
        if entry is None:
            break
        command = getattr(entry, "command", "") or ""
        if Path(command.strip()).name.lower() == "tmux":
            return None, None, True
        match = terminal_from_command(command)
        if match is not None:
            return match[0], match[1], False
        current = getattr(entry, "ppid", None)
    return None, None, False


# --- Ghostty -----------------------------------------------------------------


@dataclass(frozen=True, slots=True)
class GhosttyTerminal:
    id: str
    working_directory: str | None
    name: str | None


def parse_ghostty_terminals(text: object) -> tuple[GhosttyTerminal, ...]:
    if type(text) is not str:
        return ()
    terminals: list[GhosttyTerminal] = []
    for line in text.splitlines():
        parts = line.split(_SEP)
        if len(parts) < 3 or not parts[0].strip():
            continue
        working_directory = parts[1].strip() or None
        name = _SEP.join(parts[2:]).strip() or None
        terminals.append(GhosttyTerminal(parts[0].strip(), working_directory, name))
    return tuple(terminals)


def _same_directory(left: str | None, right: str | None) -> bool:
    if not left or not right:
        return False
    left_path = left.rstrip("/") or "/"
    right_path = right.rstrip("/") or "/"
    if left_path == right_path:
        return True
    try:
        return os.path.realpath(left_path) == os.path.realpath(right_path)
    except (OSError, ValueError):
        return False


def choose_ghostty_terminal(
    terminals: Sequence[GhosttyTerminal],
    *,
    recorded_id: str | None,
    cwd: str | None,
    title: str | None,
) -> GhosttyTerminal | None:
    """The one terminal this session is in, or ``None`` for a tie or a miss.

    The surface recorded at SessionStart is the strongest evidence, while
    it is still in the session's directory (a terminal the session has left
    may be running something else by now); then the only terminal in the
    session's working directory; then, among several there, the only one
    whose title carries the session's name.
    """
    if recorded_id:
        for terminal in terminals:
            if terminal.id == recorded_id and (
                not cwd or not terminal.working_directory or _same_directory(terminal.working_directory, cwd)
            ):
                return terminal
    in_directory = [terminal for terminal in terminals if _same_directory(terminal.working_directory, cwd)]
    if len(in_directory) == 1:
        return in_directory[0]
    if title and len(title.strip()) >= 3:
        needle = title.strip().lower()
        pool = in_directory or list(terminals)
        named = [terminal for terminal in pool if terminal.name and needle in terminal.name.lower()]
        if len(named) == 1:
            return named[0]
    return None


# --- tmux ----------------------------------------------------------------------


@dataclass(frozen=True, slots=True)
class TmuxPane:
    session: str
    window: str
    pane: str

    @property
    def window_target(self) -> str:
        return f"{self.session}:{self.window}"

    @property
    def target(self) -> str:
        return f"{self.session}:{self.window}.{self.pane}"


def parse_tmux_pane_for_tty(text: object, tty: str | None) -> TmuxPane | None:
    """The pane whose tty is ``tty`` in ``list-panes -a`` output."""
    if type(text) is not str or not tty:
        return None
    for line in text.splitlines():
        parts = line.split(_SEP)
        if len(parts) == 4 and parts[0] == tty and all(parts[1:]):
            return TmuxPane(parts[1], parts[2], parts[3])
    return None


def tmux_clients(text: object) -> tuple[tuple[str, str], ...]:
    """``(client tty, attached session)`` rows from ``list-clients``."""
    if type(text) is not str:
        return ()
    rows = []
    for line in text.splitlines():
        parts = line.split(_SEP)
        if len(parts) == 2 and parts[0] and parts[1]:
            rows.append((parts[0], parts[1]))
    return tuple(rows)


# --- the macOS boundary -------------------------------------------------------


class SurfaceRunner:
    """Every side effect this module has, so the plans above test without
    a terminal, tmux or Apple events."""

    def osascript(self, script: str, *arguments: str) -> tuple[int, str]:
        try:
            completed = subprocess.run(
                ["/usr/bin/osascript", "-e", script, *arguments],
                check=False,
                stdout=subprocess.PIPE,
                stderr=subprocess.DEVNULL,
                text=True,
                timeout=SCRIPT_TIMEOUT_SECONDS,
            )
        except Exception:
            return 1, ""
        return completed.returncode, completed.stdout.strip()

    def tmux(self, *arguments: str) -> tuple[int, str]:
        executable = next(
            (path for path in _TMUX_CANDIDATES if os.access(path, os.X_OK)),
            shutil.which("tmux"),
        )
        if executable is None:
            return 1, ""
        try:
            completed = subprocess.run(
                [executable, *arguments],
                check=False,
                stdout=subprocess.PIPE,
                stderr=subprocess.DEVNULL,
                text=True,
                timeout=TMUX_TIMEOUT_SECONDS,
            )
        except Exception:
            return 1, ""
        return completed.returncode, completed.stdout

    def activate(self, bundle_id: str) -> bool:
        from .answer_local import raise_application

        return raise_application(bundle_id, timeout_seconds=1.0)

    def launch_in_terminal(self, bundle_id: str, command: str) -> bool:
        """Run ``command`` in a new window of that terminal, through the
        reviewed launch plans the rest of the app uses. ``False`` when that
        terminal has no reviewed plan here (the plan fell back to another
        app): the caller's own ladder decides then."""
        from ._status_bar_launch_legacy import resolve_terminal_launch, terminal_launch_arguments

        try:
            plan = resolve_terminal_launch(bundle_id)
            if plan.selected_bundle_identifier != bundle_id:
                return False
            subprocess.Popen(
                terminal_launch_arguments(plan, command),
                stdout=subprocess.DEVNULL,
                stderr=subprocess.DEVNULL,
            )
        except Exception:
            return False
        return True

    def frontmost_bundle(self) -> str | None:
        from .answer_local import frontmost_application

        return frontmost_application()[0]

    def automation_permitted(self, bundle_id: str) -> bool | None:
        return automation_permitted(bundle_id)


def _fourcc(text: str) -> int:
    return int.from_bytes(text.encode("ascii"), "big")


class _AEDesc(ctypes.Structure):
    _fields_ = [("descriptorType", ctypes.c_uint32), ("dataHandle", ctypes.c_void_p)]


def automation_permitted(bundle_id: object) -> bool | None:
    """Whether macOS already lets this process send that app Apple events.

    Never prompts (``askUserIfNeeded`` is false). ``True`` granted,
    ``False`` denied, ``None`` not decided yet or the app is not running --
    the cases where an Apple event would either ask or fail.
    """
    if type(bundle_id) is not str or not bundle_id:
        return None
    try:
        services = ctypes.cdll.LoadLibrary(
            "/System/Library/Frameworks/CoreServices.framework/CoreServices"
        )
        create = services.AECreateDesc
        create.argtypes = [ctypes.c_uint32, ctypes.c_void_p, ctypes.c_long, ctypes.POINTER(_AEDesc)]
        create.restype = ctypes.c_int16
        determine = services.AEDeterminePermissionToAutomateTarget
        determine.argtypes = [ctypes.POINTER(_AEDesc), ctypes.c_uint32, ctypes.c_uint32, ctypes.c_bool]
        determine.restype = ctypes.c_int32
        dispose = services.AEDisposeDesc
        dispose.argtypes = [ctypes.POINTER(_AEDesc)]
        dispose.restype = ctypes.c_int16
        data = bundle_id.encode("utf-8")
        desc = _AEDesc()
        if create(_fourcc("bund"), data, len(data), ctypes.byref(desc)) != 0:
            return None
        try:
            status = determine(ctypes.byref(desc), _fourcc("****"), _fourcc("****"), False)
        finally:
            dispose(ctypes.byref(desc))
    except Exception:
        return None
    if status == 0:
        return True
    if status == -1743:  # errAEEventNotPermitted
        return False
    return None  # -1744 would ask; -600 not running


# --- raising -------------------------------------------------------------------


@dataclass(frozen=True, slots=True)
class RaiseOutcome:
    """What an open did: ``pane``, ``tab``, ``terminal``, ``app`` or ``none``."""

    raised: str
    app_name: str | None = None
    bundle_id: str | None = None
    detail: str | None = None

    def document(self) -> dict[str, Any]:
        return {"raised": self.raised, "app": self.app_name, "bundle_id": self.bundle_id, "detail": self.detail}


def _raise_tab_by_tty(runner: SurfaceRunner, bundle_id: str, tty: str | None) -> bool:
    script = {TERMINAL_BUNDLE_ID: _TERMINAL_RAISE_BY_TTY, ITERM_BUNDLE_ID: _ITERM_RAISE_BY_TTY}.get(bundle_id)
    if script is None or not tty or not _TTY.match(tty):
        return False
    code, output = runner.osascript(script, tty)
    return code == 0 and output == "tab"


def _raise_ghostty(
    runner: SurfaceRunner,
    *,
    recorded_id: str | None,
    cwd: str | None,
    title: str | None,
) -> str | None:
    """The Ghostty terminal id that was focused, or ``None``."""
    code, output = runner.osascript(_GHOSTTY_LIST_TERMINALS)
    if code != 0:
        return None
    chosen = choose_ghostty_terminal(
        parse_ghostty_terminals(output), recorded_id=recorded_id, cwd=cwd, title=title
    )
    if chosen is None:
        return None
    code, output = runner.osascript(_GHOSTTY_FOCUS, chosen.id)
    return chosen.id if code == 0 and output == "terminal" else None


def _select_tmux_pane(runner: SurfaceRunner, tty: str | None) -> TmuxPane | None:
    code, output = runner.tmux(
        "list-panes", "-a", "-F", "#{pane_tty}\t#{session_name}\t#{window_index}\t#{pane_index}"
    )
    pane = parse_tmux_pane_for_tty(output, tty) if code == 0 else None
    if pane is None:
        return None
    code, output = runner.tmux("list-clients", "-F", "#{client_tty}\t#{client_session}")
    clients = tmux_clients(output) if code == 0 else ()
    if clients and not any(session == pane.session for _tty, session in clients) and len(clients) == 1:
        # One client, looking at another session: bring it to this one.
        runner.tmux("switch-client", "-c", clients[0][0], "-t", pane.session)
    runner.tmux("select-window", "-t", pane.window_target)
    code, _ = runner.tmux("select-pane", "-t", pane.target)
    return pane if code == 0 else None


def raise_session_host(
    host: SessionHost,
    *,
    cwd: str | None,
    title: str | None,
    recorded_ghostty_id: str | None,
    runner: SurfaceRunner | None = None,
) -> RaiseOutcome:
    """Put a live session's own window in front, as exactly as its host
    allows. ``none`` means nothing was raised."""
    runner = runner or SurfaceRunner()
    if host.in_tmux:
        pane = _select_tmux_pane(runner, host.tty)
        if pane is not None:
            return RaiseOutcome("pane", "tmux", None, pane.target)
        return RaiseOutcome("none", "tmux", None, "no tmux pane has that tty")
    bundle = host.bundle_id
    if not bundle:
        return RaiseOutcome("none", None, None, "no terminal hosts that session")
    if bundle in (TERMINAL_BUNDLE_ID, ITERM_BUNDLE_ID) and _raise_tab_by_tty(runner, bundle, host.tty):
        return RaiseOutcome("tab", host.app_name, bundle, host.tty)
    if bundle == GHOSTTY_BUNDLE_ID:
        terminal_id = _raise_ghostty(runner, recorded_id=recorded_ghostty_id, cwd=cwd, title=title)
        if terminal_id is not None:
            return RaiseOutcome("terminal", host.app_name, bundle, terminal_id)
    if runner.activate(bundle):
        return RaiseOutcome("app", host.app_name, bundle, None)
    return RaiseOutcome("none", host.app_name, bundle, "the host app did not come forward")


# --- recording the surface at SessionStart ------------------------------------


def _surface_key(provider: str, session_id: str) -> str:
    return f"{provider}\x1f{session_id}"


class SurfaceRecorder:
    """Where each session started, kept across restarts: the terminal app
    that hosts it (from the process table, no permission needed) and, in
    Ghostty, the exact terminal surface (when Apple events are already
    allowed). The app is what resumes an ended session in its own terminal;
    the surface is what raises a live one.

    ``note_session_start`` is called by the hook ingress for every
    SessionStart and returns at once; the probe runs on one worker thread
    with a bounded queue, so a burst of starts never slows a hook.
    """

    def __init__(
        self,
        *,
        path: Path | None = None,
        runner: SurfaceRunner | None = None,
        process_table: Callable[[], Mapping[int, Any]] | None = None,
        wall_clock: Callable[[], float] = time.time,
        synchronous: bool = False,
    ) -> None:
        self._path = path
        self._runner = runner or SurfaceRunner()
        self._table = process_table
        self._wall = wall_clock
        self._synchronous = synchronous
        self._lock = threading.Lock()
        self._records: dict[str, dict[str, Any]] | None = None
        self._queue: deque[tuple[str, str, str | None, int | None]] = deque(maxlen=8)
        self._wake = threading.Event()
        self._worker: threading.Thread | None = None

    # -- reading --

    def recorded(self, provider: object, session_id: object) -> str | None:
        """The Ghostty terminal the session started in, if one was proven."""
        return self._field(provider, session_id, "ghostty_terminal")

    def recorded_host(self, provider: object, session_id: object) -> str | None:
        """The bundle id of the terminal app the session started in."""
        return self._field(provider, session_id, "host_bundle")

    def _field(self, provider: object, session_id: object, name: str) -> str | None:
        if type(provider) is not str or type(session_id) is not str:
            return None
        with self._lock:
            record = self._loaded().get(_surface_key(provider, session_id))
        value = record.get(name) if isinstance(record, dict) else None
        return value if type(value) is str and value else None

    # -- recording --

    def note_session_start(self, provider: object, payload_text: object, ppid: object) -> bool:
        """Queue a probe for this SessionStart; ``False`` when it is not one."""
        if type(provider) is not str or type(payload_text) is not str or '"SessionStart"' not in payload_text:
            return False
        try:
            payload = json.loads(payload_text)
        except ValueError:
            return False
        if not isinstance(payload, dict) or payload.get("hook_event_name") != "SessionStart":
            return False
        session_id = payload.get("session_id")
        cwd = payload.get("cwd")
        if type(session_id) is not str or not session_id:
            return False
        item = (provider, session_id, cwd if type(cwd) is str else None, ppid if type(ppid) is int else None)
        if self._synchronous:
            self._probe(*item)
            return True
        with self._lock:
            self._queue.append(item)
            if self._worker is None or not self._worker.is_alive():
                self._worker = threading.Thread(target=self._drain, name="JRBarSurfaceRecorder", daemon=True)
                self._worker.start()
        self._wake.set()
        return True

    def _drain(self) -> None:
        while True:
            with self._lock:
                item = self._queue.popleft() if self._queue else None
            if item is None:
                self._wake.clear()
                if not self._wake.wait(30.0):
                    with self._lock:
                        if not self._queue:
                            self._worker = None
                            return
                continue
            try:
                self._probe(*item)
            except Exception:
                continue

    def _probe(self, provider: str, session_id: str, cwd: str | None, ppid: int | None) -> None:
        if ppid is None or not cwd:
            return
        try:
            if self._table is not None:
                table = self._table()
            else:
                from .process_registry import list_processes

                table = list_processes()
        except Exception:
            return
        # The shim's parent is the agent (or the shell the agent ran the
        # hook through); either way the host is above it.
        _app, bundle, in_tmux = host_from_ancestry(ppid, table)
        if in_tmux or bundle is None or bundle in APP_HOSTED_BUNDLE_IDS:
            return
        self._store(provider, session_id, host_bundle=bundle, terminal_id=self._ghostty_surface(bundle, cwd), cwd=cwd)

    def _ghostty_surface(self, bundle: str, cwd: str) -> str | None:
        """The focused Ghostty terminal, when it is provably this session's:
        Apple events already allowed, Ghostty in front, and its focused
        terminal in the session's directory -- the one the command was just
        typed into."""
        if bundle != GHOSTTY_BUNDLE_ID:
            return None
        runner = self._runner
        if runner.automation_permitted(GHOSTTY_BUNDLE_ID) is not True:
            return None
        if runner.frontmost_bundle() != GHOSTTY_BUNDLE_ID:
            return None
        code, output = runner.osascript(_GHOSTTY_FOCUSED_TERMINAL)
        if code != 0:
            return None
        terminal_id, _sep, working_directory = output.partition(_SEP)
        if not terminal_id.strip() or not _same_directory(working_directory.strip(), cwd):
            return None
        return terminal_id.strip()

    # -- persistence --

    def _loaded(self) -> dict[str, dict[str, Any]]:
        if self._records is not None:
            return self._records
        records: dict[str, dict[str, Any]] = {}
        path = self._records_path()
        if path is not None:
            try:
                from .private_io import read_private_text

                document = json.loads(read_private_text(path, tighten=False))
            except Exception:
                document = None
            now = self._wall()
            rows = document.get("surfaces") if isinstance(document, dict) else None
            if isinstance(rows, dict):
                for key, row in rows.items():
                    if not (
                        type(key) is str
                        and isinstance(row, dict)
                        and type(row.get("recorded_at")) in (int, float)
                        and now - float(row["recorded_at"]) < RECORDED_SURFACE_TTL_SECONDS
                    ):
                        continue
                    kept = {
                        name: row[name]
                        for name in ("host_bundle", "ghostty_terminal", "cwd")
                        if type(row.get(name)) is str and row[name]
                    }
                    if "host_bundle" in kept or "ghostty_terminal" in kept:
                        records[key] = {**kept, "recorded_at": float(row["recorded_at"])}
        self._records = records
        return records

    def _store(
        self,
        provider: str,
        session_id: str,
        *,
        host_bundle: str,
        terminal_id: str | None,
        cwd: str,
    ) -> None:
        row: dict[str, Any] = {"host_bundle": host_bundle, "cwd": cwd, "recorded_at": self._wall()}
        if terminal_id:
            row["ghostty_terminal"] = terminal_id
        with self._lock:
            records = self._loaded()
            # Every start replaces the record: a session resumed in another
            # terminal must not be raised in the one it left.
            records[_surface_key(provider, session_id)] = row
            while len(records) > MAX_RECORDED_SURFACES:
                oldest = min(records, key=lambda key: records[key]["recorded_at"])
                del records[oldest]
            snapshot = {"version": 1, "surfaces": dict(records)}
        path = self._records_path()
        if path is None:
            return
        try:
            from .private_io import atomic_private_write, ensure_private_directory

            ensure_private_directory(path.parent)
            atomic_private_write(path, json.dumps(snapshot, sort_keys=True, separators=(",", ":")))
        except Exception:
            pass

    def _records_path(self) -> Path | None:
        if self._path is not None:
            return self._path
        try:
            from .state_paths import default_state_dir

            return default_state_dir() / SURFACES_FILE_NAME
        except Exception:
            return None


_DEFAULT_RECORDER: SurfaceRecorder | None = None
_RECORDER_LOCK = threading.Lock()


def default_surface_recorder() -> SurfaceRecorder:
    global _DEFAULT_RECORDER
    with _RECORDER_LOCK:
        if _DEFAULT_RECORDER is None:
            _DEFAULT_RECORDER = SurfaceRecorder()
        return _DEFAULT_RECORDER


# --- open_session --------------------------------------------------------------

#: Open actions that mean "take me to the session's terminal".
RAISE_ACTIONS: Final = frozenset({"terminal", "raise"})


def _live_host(
    controller: object,
    status: object,
    *,
    process_table: Callable[[], Mapping[int, Any]] | None = None,
    on_main: Callable[[Callable[[], Any]], Any] | None = None,
) -> tuple[SessionHost, object] | None:
    """The live, terminal-hosted session's host and the row's extras, or
    ``None`` for an ended session or one its provider's app hosts."""
    extras = None
    lookup = getattr(controller, "_core_extras_for", None)
    if callable(lookup):
        try:
            extras = on_main(lambda: lookup(status)) if on_main is not None else lookup(status)
        except Exception:
            extras = None
    pid = getattr(extras, "pid", None)
    if type(pid) is not int or pid <= 1:
        return None
    try:
        if process_table is not None:
            table = process_table()
        else:
            from .process_registry import list_processes

            table = list_processes()
    except Exception:
        table = {}
    app_name, bundle_id, in_tmux = host_from_ancestry(pid, table)
    if bundle_id in APP_HOSTED_BUNDLE_IDS:
        return None
    terminal = getattr(extras, "terminal", None)
    tty = terminal.get("tty") if isinstance(terminal, Mapping) else None
    host = SessionHost(
        pid=pid,
        tty=tty if type(tty) is str else None,
        app_name=app_name,
        bundle_id=bundle_id,
        in_tmux=in_tmux,
    )
    return host, extras


def _raise_live(
    host: SessionHost,
    extras: object,
    status: object,
    *,
    runner: SurfaceRunner | None,
    recorder: SurfaceRecorder | None,
) -> RaiseOutcome:
    cwd = getattr(status, "cwd", None) or getattr(extras, "cwd", None)
    return raise_session_host(
        host,
        cwd=cwd if type(cwd) is str else None,
        title=getattr(extras, "name", None),
        recorded_ghostty_id=(recorder or default_surface_recorder()).recorded(
            getattr(status, "provider", None), getattr(status, "session_id", None)
        ),
        runner=runner,
    )


def raise_for_answer(
    controller: object,
    status: object,
    *,
    on_main: Callable[[Callable[[], Any]], Any] | None = None,
    runner: SurfaceRunner | None = None,
    recorder: SurfaceRecorder | None = None,
    process_table: Callable[[], Mapping[int, Any]] | None = None,
) -> RaiseOutcome | None:
    """``answer_ask``'s "raise the session's terminal first", exactly: its
    own tab, tmux pane or Ghostty terminal comes forward, so the keystroke
    fence's focused-target proof can pass. Raising proves nothing -- the
    same fence still runs against whatever is in front afterwards."""
    try:
        live = _live_host(controller, status, process_table=process_table, on_main=on_main)
        if live is None:
            return None
        host, extras = live
        return _raise_live(host, extras, status, runner=runner, recorder=recorder)
    except Exception:
        return None


def _resolved_open_action(controller: object, status: object, args: Mapping[str, Any]) -> str | None:
    """The open action the controller's own ladder would take: the command's
    ``action``, a provider profile's, Settings' Clicks-open, else the row's
    default (a CLI session's is the terminal)."""
    action = args.get("action") if isinstance(args.get("action"), str) else None
    if action is not None:
        return action
    try:
        from .provider_usage_controller_actions import profile_session_action

        configured = profile_session_action(controller, status, None)
    except Exception:
        configured = None
    if configured is None:
        try:
            configured = controller.settings.session_open_action(  # type: ignore[attr-defined]
                str(getattr(status, "provider", "")).lower(), getattr(status, "origin", None)
            )
        except Exception:
            configured = None
    if configured is not None:
        return configured
    try:
        from .session_actions import default_session_open_action

        return default_session_open_action(status)  # type: ignore[arg-type]
    except Exception:
        return None


def resume_in_own_terminal(
    controller: object,
    status: object,
    args: Mapping[str, Any],
    *,
    runner: SurfaceRunner | None = None,
    recorder: SurfaceRecorder | None = None,
) -> dict[str, Any] | None:
    """``open_session`` for an ENDED CLI session whose open is a terminal
    resume: resume it in the terminal it ran in -- a new Ghostty tab in the
    session's directory, or a new Terminal.app/iTerm2 window -- rather than
    whichever app happened to be in front. ``None`` leaves it to the
    controller's ladder (no record of the terminal, a live or remote
    session, an app or VS Code open, a terminal with no reviewed plan)."""
    from .session_actions import SESSION_OPEN_TERMINAL, session_resume_command, session_resume_parts

    agent_id = getattr(status, "agent_id", "") or ""
    provider = getattr(status, "provider", None)
    session_id = getattr(status, "session_id", None)
    if not isinstance(agent_id, str) or agent_id.startswith("remote:"):
        return None
    if type(provider) is not str or type(session_id) is not str or not session_id:
        return None
    if _resolved_open_action(controller, status, args) not in (SESSION_OPEN_TERMINAL, "raise"):
        return None
    host = (recorder or default_surface_recorder()).recorded_host(provider, session_id)
    if host not in (GHOSTTY_BUNDLE_ID, TERMINAL_BUNDLE_ID, ITERM_BUNDLE_ID):
        return None
    runner = runner or SurfaceRunner()
    try:
        parts = session_resume_parts(status)  # type: ignore[arg-type]
        command = session_resume_command(status)  # type: ignore[arg-type]
    except Exception:
        return None
    if parts is None or command is None:
        return None
    opened = None
    if host == GHOSTTY_BUNDLE_ID:
        cwd, typed = parts
        code, output = runner.osascript(_GHOSTTY_NEW_TAB, cwd, typed + "\n")
        if code == 0 and output == "tab":
            opened = "new_tab"
    if opened is None and runner.launch_in_terminal(host, command):
        opened = "new_window"
    if opened is None:
        return None
    names = {GHOSTTY_BUNDLE_ID: "Ghostty", TERMINAL_BUNDLE_ID: "Terminal", ITERM_BUNDLE_ID: "iTerm"}
    return {
        "session": agent_id,
        "activated": names[host],
        "origin": None,
        "raised": opened,
        "app": names[host],
        "bundle_id": host,
        "detail": "resumed",
    }


def open_session_surface(
    controller: object,
    status: object,
    args: Mapping[str, Any],
    *,
    runner: SurfaceRunner | None = None,
    recorder: SurfaceRecorder | None = None,
    process_table: Callable[[], Mapping[int, Any]] | None = None,
) -> dict[str, Any] | None:
    """``open_session`` through the session's own terminal: raise it while
    it runs, resume it there once it has ended. ``None`` is the controller's
    ladder (provider links, VS Code, the frontmost terminal)."""
    raised = open_live_session(
        controller, status, args, runner=runner, recorder=recorder, process_table=process_table
    )
    if raised is not None:
        return raised
    if _live_host(controller, status, process_table=process_table) is not None:
        return None
    return resume_in_own_terminal(controller, status, args, runner=runner, recorder=recorder)


def open_live_session(
    controller: object,
    status: object,
    args: Mapping[str, Any],
    *,
    runner: SurfaceRunner | None = None,
    recorder: SurfaceRecorder | None = None,
    process_table: Callable[[], Mapping[int, Any]] | None = None,
) -> dict[str, Any] | None:
    """``open_session`` for a session that is still running in a terminal:
    raise that terminal, or ``None`` to let the provider-link / ``--resume``
    ladder handle it (an ended session, a remote row, an app-hosted session,
    an explicit Open in VS Code or Open in the app).

    Raises ``CommandError`` for a session that is running where JR-Bar cannot
    find it: starting a second process on the same session is the one thing
    an open must never do.
    """
    from .core_server import CommandError

    agent_id = getattr(status, "agent_id", "") or ""
    provider = getattr(status, "provider", None)
    session_id = getattr(status, "session_id", None)
    if not isinstance(agent_id, str) or agent_id.startswith("remote:"):
        return None
    if type(provider) is not str or type(session_id) is not str or not session_id:
        return None
    action = args.get("action") if isinstance(args.get("action"), str) else None
    if action is not None and action not in RAISE_ACTIONS:
        return None
    if action is None:
        # An explicit choice elsewhere wins: a provider profile's open action,
        # then Settings > Agents > Clicks open. "Automatic" and "Terminal"
        # both mean the session's own window when it has one.
        configured = None
        try:
            from .provider_usage_controller_actions import profile_session_action

            configured = profile_session_action(controller, status, None)
        except Exception:
            configured = None
        if configured is None:
            try:
                configured = controller.settings.session_open_action(  # type: ignore[attr-defined]
                    provider.lower(), getattr(status, "origin", None)
                )
            except Exception:
                configured = None
        if configured is not None and configured not in RAISE_ACTIONS:
            return None
    live = _live_host(controller, status, process_table=process_table)
    if live is None:
        return None  # ended or app-hosted: the ladder's open is the right one
    host, extras = live
    from .answer_decisions import release_for_open

    # The owner is going to the session to answer there: a Codex prompt
    # held behind the decide lane must appear now, not when the hold lapses.
    release_for_open(status)
    outcome = _raise_live(host, extras, status, runner=runner, recorder=recorder)
    if outcome.raised == "none":
        raise CommandError(
            "not_found",
            "That session is still running, but JR-Bar can't find its window; "
            "nothing new was started.",
        )
    origin = getattr(extras, "origin", None)
    return {
        "session": agent_id,
        "activated": outcome.app_name,
        "origin": origin,
        **outcome.document(),
    }


__all__ = [
    "APP_HOSTED_BUNDLE_IDS",
    "GHOSTTY_BUNDLE_ID",
    "GhosttyTerminal",
    "RaiseOutcome",
    "SessionHost",
    "SurfaceRecorder",
    "SurfaceRunner",
    "TmuxPane",
    "automation_permitted",
    "choose_ghostty_terminal",
    "default_surface_recorder",
    "host_from_ancestry",
    "open_live_session",
    "open_session_surface",
    "parse_ghostty_terminals",
    "parse_tmux_pane_for_tty",
    "raise_for_answer",
    "raise_session_host",
    "resume_in_own_terminal",
    "tmux_clients",
]
