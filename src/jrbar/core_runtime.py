"""``python -m jrbar core``: the production controller, headless, behind
the protocol-1 socket (docs/CORE-PROTOCOL.md).

The controller class is the same one the menu-bar app runs
(``application_composition.compose_status_bar_application``); this module
subclasses its final form and

* skips every AppKit surface in ``applicationDidFinishLaunching_`` (status
  item, menus, hotkeys, windows, the Screen Bar window) while keeping the
  timers, hook ingress, event and cloud sockets, device writers, power
  holds, calendar and remote peers;
* taps the emission seams (``refresh_``, ``record_activity_entries``,
  ``apply_escalation``, ``_dnd_projection_changed``,
  ``sync_virtual_status_device``, ``_apply_hardware_write_result``) to
  publish ``state`` / ``lights`` / ``event`` frames;
* turns ``settings`` into a property with a generation so every save,
  from any code path, republishes the ``settings`` document;
* answers protocol commands on the main thread (the socket thread hands
  each one over with ``performSelectorOnMainThread``).

Everything AppKit is imported lazily so importing this module stays inert.
"""

from __future__ import annotations

import argparse
import json
import os
import signal
import subprocess
import sys
import threading
import time
import traceback
from collections import deque
from collections.abc import Callable
from dataclasses import dataclass
from pathlib import Path
from typing import Any, Final

from . import __version__, core_deck
from .completion_visibility import END_EVENT_NAMES
from .core_projection import (
    READ_ONLY_SETTINGS,
    DeviceFacts,
    EscalationFacts,
    LightFacts,
    PowerFacts,
    SessionExtras,
    SurfaceFacts,
    build_lights_document,
    build_settings_document,
    build_state_document,
    history_rows,
    light_why,
    origin_document,
    terminal_from_command,
    why_detail,
    why_for_glance,
)
from .core_server import CommandError, CoreServer, default_core_socket_path
from .core_usage_samples import SAMPLES_FILE_NAME, UsageSampleBuffer
from .hook_pending import (
    PendingHookDrainer,
    orphaned_drain_files,
    pending_hook_files,
)
from .state_paths import default_state_dir

CORE_VERSION: Final = __version__
HOUSEKEEPING_SECONDS: Final = 1.0
SUPERVISION_SECONDS: Final = 2.0
EXTRAS_TTL_SECONDS: Final = 30.0
# How long after a session's last event the daemon keeps re-reading a
# registry record the liveness sweep closed. Long enough for a provider's
# own ``SessionEnd`` to land behind its process's exit, short enough that a
# session that really was killed settles and stops costing a file read.
UNSETTLED_EXTRAS_SECONDS: Final = 60.0
# How long ``answer_ask`` waits on the answer surface's worker before it gives
# up and says so. A delivery is a few process reads and one posted key; the
# surface's own budget (answer_local.DELIVERY_BUDGET_SECONDS) is smaller, so
# this only ever fires when the worker itself is wedged.
ANSWER_REPLY_BUDGET_SECONDS: Final = 6.0
MAX_EXTRA_LOOKUPS_PER_BUILD: Final = 6
PREVIEW_MAX_SECONDS: Final = 30.0
# A calibration preview is held, not flashed: the sheet is open for
# minutes while the eye decides, so the device keeps the patch until the
# sheet ends it or this backstop passes -- a dead client must not leave a
# strip lit on a colour nobody asked for. Every `preview_calibration`
# call re-arms the deadline.
CALIBRATION_HOLD_SECONDS: Final = 600.0
# The guided flow's named patches; a literal "#RRGGBB" is also accepted.
CALIBRATION_PATCHES: Final = {
    "white": "#FFFFFF",
    "red": "#FF0000",
    "green": "#00FF00",
    "blue": "#0000FF",
    "grey": "#808080",
}
# The Creator Micro 2: how often the daemon looks for the pad over HID
# (a background enumerate, ~30 ms), how long an inspected keymap stays
# good for planning, how long a setup operation may take (a runtime stop
# of up to 17 s plus the transfer), and how long a device approval may.
DECK_PROBE_SECONDS: Final = 10.0
DECK_INSPECTION_TTL_SECONDS: Final = 120.0
DECK_SETUP_TIMEOUT_SECONDS: Final = 60.0
DECK_APPROVE_TIMEOUT_SECONDS: Final = 15.0
DECK_INTEGRATION_TTL_SECONDS: Final = 2.0
# ``health.detected`` re-runs the reviewed installed-agent markers at most
# this often: the scan is a few dozen lstats, but ``state`` rebuilds on
# every refresh and "is the CLI still installed" does not move that fast.
DETECTED_AGENTS_TTL_SECONDS: Final = 60.0
# Display kinds a live claim arms for a bounded window only. The lights
# document reads the kind the last sync recorded; when the write path
# misses, that record survives the claim by hours -- a dead quota blink
# reported itself as "capacity" long after its window closed. A recorded
# kind past its own deadline cannot still be playing, so the why falls
# back to the glance.
_TRANSIENT_KIND_DEADLINE: Final = {
    "quota_alert": "quota_blink_until",
    "reset_celebration": "quota_reset_celebration_until",
    "connection_notice": "connection_notice_until",
    "reminders": "reminders_glow_until",
    "calendar": "calendar_glow_until",
    "completion": "completion_sweep_until",
    "all_clear": "all_clear_until",
    "peek": "peek_until",
    "signal_test": "test_signal_until",
}
LEGACY_WINDOWS: Final = {
    "settings": "show_settings_window",
    "setup": "show_setup_window",
    "agent_browser": "openAgentBrowser_",
    "effect_studio": "openEffectStudio_",
    "usage_center": "openProviderUsageCenter_",
    "control_center": "openDeckControlCenter_",
    "why": "openWhyPanel_",
}
_APP_OWNED_DIAGNOSTICS: Final = frozenset({"alcove_follow_state"})
_HEALTHY_DIAGNOSTIC_CODES: Final = frozenset(
    {
        "source_checkout",
        "installed_package",
        "packaged_bundle",
        "not_applicable",
        "verified",
        "installed",
        "private",
        "configured",
        "healthy",
        "bounded",
        "connected",
    }
)


def _running_commit() -> str | None:
    """The commit this daemon runs: ``JRBAR_COMMIT`` from an installed
    deployment (scripts/install-agents.sh), else the checkout's HEAD."""
    explicit = os.environ.get("JRBAR_COMMIT")
    if explicit:
        return explicit
    root = Path(__file__).resolve().parents[2]
    if not (root / ".git").exists():
        return None
    try:
        completed = subprocess.run(
            ["git", "-C", str(root), "rev-parse", "HEAD"],
            check=False, stdout=subprocess.PIPE, stderr=subprocess.DEVNULL, text=True, timeout=2.0,
        )
    except (OSError, subprocess.SubprocessError):
        return None
    value = completed.stdout.strip()
    return value or None


def mono_to_epoch(value: object) -> float | None:
    """A ``time.monotonic()`` reading as wall-clock epoch seconds."""
    if value is None or isinstance(value, bool) or not isinstance(value, (int, float)):
        return None
    return time.time() + (float(value) - time.monotonic())


def split_path(path: str) -> list[str | int]:
    parts: list[str | int] = []
    for piece in str(path).split("."):
        if not piece:
            continue
        parts.append(int(piece) if piece.isdigit() else piece)
    return parts


def get_path(root: Any, path: str) -> tuple[Any, bool]:
    node = root
    for part in split_path(path):
        if isinstance(part, int):
            if not isinstance(node, list) or not 0 <= part < len(node):
                return None, False
            node = node[part]
        else:
            if not isinstance(node, dict) or part not in node:
                return None, False
            node = node[part]
    return node, True


def set_path(root: Any, path: str, value: Any) -> bool:
    parts = split_path(path)
    if not parts:
        return False
    node = root
    for part in parts[:-1]:
        if isinstance(part, int):
            if not isinstance(node, list) or not 0 <= part < len(node):
                return False
            node = node[part]
        else:
            if not isinstance(node, dict):
                return False
            node = node.setdefault(part, {})
    leaf = parts[-1]
    if isinstance(leaf, int):
        if not isinstance(node, list) or not 0 <= leaf < len(node):
            return False
        node[leaf] = value
        return True
    if not isinstance(node, dict):
        return False
    node[leaf] = value
    return True


def plan_extra_lookups(
    agent_ids: list[str],
    cached: dict[str, tuple[float, Any]],
    *,
    now: float,
    ttl: float,
    budget: int,
) -> list[str]:
    """Which sessions get a registry / session-title lookup this build.

    Never-looked-up sessions come first, then the stalest expired entries,
    within ``budget``: refreshing the same first few every build starved
    everything after them of a label (each expired at the same moment, so
    the budget went to the same ids every time)."""
    fresh: list[str] = []
    expired: list[tuple[float, str]] = []
    for agent_id in agent_ids:
        entry = cached.get(agent_id)
        if entry is None:
            fresh.append(agent_id)
        elif now - entry[0] >= ttl:
            expired.append((entry[0], agent_id))
    expired.sort()
    chosen = fresh[:budget]
    chosen.extend(agent_id for _at, agent_id in expired[: max(0, budget - len(chosen))])
    return chosen


# Paths whose values move on every build without the document having
# changed: a stamped clock, monotonic ages, and now-relative forecasts.
# ``*`` matches any mapping key or list index. Comparing significance
# without them is what makes an unchanged projection skip its broadcast --
# the server's byte-level dedupe can never fire while these fields tick.
# A missed field degrades to the old publish-everything behaviour, never
# to wrong data.
_VOLATILE_DOC_PATHS: dict[str, tuple[tuple[str, ...], ...]] = {
    "state": (
        ("now",),
        ("generation",),
        ("health", "sources", "*", "heard_age_seconds"),
        ("health", "intake", "silence_seconds"),
        ("usage", "providers", "*", "forecast", "exhausts_at"),
        ("usage", "providers", "*", "windows", "*", "forecast", "exhausts_at"),
        # Battery estimates move on every read; a percent step or a plug
        # change is what earns a broadcast.
        ("power", "battery", "minutes_left"),
        ("power", "battery", "minutes_to_full"),
        ("power", "battery", "draw_watts"),
        ("power", "battery", "temperature_c"),
        ("power", "battery", "runway", "minutes_left"),
        # A device's write health moves with every write; starting or
        # stopping failing, or a new reason, is what earns a broadcast. The
        # refusal count and stamp tick with every retry of a dead device.
        ("devices", "*", "write_health", "latency_ms"),
        ("devices", "*", "write_health", "writes"),
        ("devices", "*", "write_health", "transformed"),
        ("devices", "*", "write_health", "refused"),
        ("devices", "*", "write_health", "last_refusal_at"),
    ),
    "lights": (
        ("now",),
        ("surfaces", "*", "why_detail", "seconds_in_state"),
        ("linked_skew_at",),
        ("linked_skew_ms",),
        ("linked_skew_corrected_ms",),
        ("auto_dim", "lux"),
        ("auto_dim", "factor"),
        # The sensor's value, smoothed and raw: it moves with every read,
        # and the brightness it earns already shows in the surfaces.
        ("auto_dim", "reading"),
        ("auto_dim", "raw"),
    ),
}


def _path_is_volatile(path: tuple[str, ...], volatile: tuple[tuple[str, ...], ...]) -> bool:
    return any(
        len(pattern) == len(path)
        and all(segment == "*" or segment == part for segment, part in zip(pattern, path))
        for pattern in volatile
    )


def _equal_ignoring_volatile(a: Any, b: Any, path: tuple[str, ...], volatile) -> bool:
    if _path_is_volatile(path, volatile):
        return True
    if isinstance(a, dict) and isinstance(b, dict):
        for key in a.keys() ^ b.keys():
            if not _path_is_volatile((*path, str(key)), volatile):
                return False
        return all(
            _equal_ignoring_volatile(a[key], b[key], (*path, str(key)), volatile)
            for key in a.keys() & b.keys()
        )
    if isinstance(a, (list, tuple)) and isinstance(b, (list, tuple)):
        return len(a) == len(b) and all(
            _equal_ignoring_volatile(x, y, (*path, str(index)), volatile)
            for index, (x, y) in enumerate(zip(a, b))
        )
    return type(a) is type(b) and a == b


def doc_significant_equal(kind: str, a: Any, b: Any) -> bool:
    """True when two builds of the same document differ only in volatile
    fields -- the ones that tick without a state change."""
    return _equal_ignoring_volatile(a, b, (), _VOLATILE_DOC_PATHS.get(kind, ()))


def screen_bar_anchor(own: float | None, hardware: float | None, *, linked: bool) -> float | None:
    """The Screen Bar's playback anchor. Linked to a strip it follows the
    strip's write-completion moment: the strip loops from there and never
    re-anchors on a Screen Bar re-sync, so the bar must not either."""
    if linked and hardware is not None:
        return hardware
    return own


def device_transitions(
    previous: dict[str, bool] | None, devices: list[Any]
) -> tuple[dict[str, bool], list[tuple[str, str, str]]]:
    """(connected-by-name, [(event kind, name, device id)]) for one refresh.

    Keyed by name: a device's id moves from its mount path to its firmware
    serial once STATUS.TXT is read, and that is not a disconnect/connect
    pair. The first refresh (``previous`` None) reports nothing.
    """
    connected: dict[str, bool] = {}
    ids: dict[str, str] = {}
    for device in devices:
        name = str(getattr(device, "name", "") or getattr(device, "device_id", ""))
        connected[name] = connected.get(name, False) or bool(getattr(device, "connected", False))
        if getattr(device, "connected", False) or name not in ids:
            ids[name] = str(getattr(device, "device_id", name))
    events: list[tuple[str, str, str]] = []
    if previous is not None:
        for name, is_connected in connected.items():
            if is_connected and not previous.get(name, False):
                events.append(("device_connected", name, ids.get(name, name)))
        for name, was_connected in previous.items():
            if was_connected and not connected.get(name, False):
                events.append(("device_disconnected", name, ids.get(name, name)))
    return connected, events


def settings_from_document(document: dict[str, Any], *, scratch_dir: Path | None = None):
    """Round a settings dict through the real loader (validation, defaults)."""
    from . import _settings_legacy as settings_legacy

    scratch = (scratch_dir or default_state_dir()) / "core-tmp"
    scratch.mkdir(parents=True, exist_ok=True, mode=0o700)
    try:
        os.chmod(scratch, 0o700)
    except OSError:
        pass
    target = scratch / f"settings-{os.getpid()}-{threading.get_ident()}.json"
    fd = os.open(target, os.O_WRONLY | os.O_CREAT | os.O_TRUNC, 0o600)
    try:
        with os.fdopen(fd, "w", encoding="utf-8") as handle:
            json.dump(document, handle)
        return settings_legacy.load_settings(target)
    finally:
        try:
            target.unlink()
        except OSError:
            pass


class HeadlessNotificationClient:
    """Stands in for ``MacOSNotificationClient``: the app delivers banners."""

    available = False
    last_diagnostic = "headless"

    def authorization_state(self):
        from .macos_notifications import NotificationAuthorizationState

        return NotificationAuthorizationState.UNAVAILABLE

    def set_delegate(self, _delegate) -> bool:
        return False

    def request_authorization(self, _completed) -> bool:
        return False

    def deliver(self, _identifier, _title, _body, _user_info) -> bool:
        return False

    def wait_idle(self, *, timeout_seconds: float) -> bool:
        return True

    def close(self, *, timeout_seconds: float) -> bool:
        return True


class CoreCommandBox:
    """One command crossing from the socket thread to the main thread."""

    __slots__ = ("args", "error", "name", "result")

    def __init__(self, name: str, args: dict[str, Any]) -> None:
        self.name = name
        self.args = args
        self.result: Any = None
        self.error: CommandError | None = None


class CoreCallableBox:
    """A callable crossing to the main thread -- ``runCoreCallable:``.

    For commands that run off the main thread (``main_thread=False``) but
    still need a short critical section there: touching AppKit, the
    command journal (not thread-safe), or controller state other threads
    read.
    """

    __slots__ = ("callable", "error", "result")

    def __init__(self, callable_: Callable[[], Any]) -> None:
        self.callable = callable_
        self.result: Any = None
        self.error: BaseException | None = None


@dataclass(slots=True)
class _Preview:
    program: str
    until_monotonic: float
    started_epoch: float
    device_ids: tuple[str, ...]
    # A held preview owns its devices' write path until it ends or expires;
    # a `preview_program` flash does not -- three seconds can ride out one
    # refresh, a ten-minute calibration hold cannot.
    held: bool = False
    # For a companion lit only to be matched against (the strip beside a
    # Dot under calibration): the primary session's device id, so ending or
    # applying on the Dot drops the strip's patch too.
    companion_of: str | None = None


@dataclass(frozen=True, slots=True)
class CommandSpec:
    handler: Callable[[Any, dict[str, Any]], Any]
    main_thread: bool = True


_CLASS_CACHE: dict[type, type] = {}
_MAIN_THREAD_COMMANDS: dict[str, CommandSpec] = {}
# Tests replace these; production resolves them lazily from Foundation/AppKit.
NSTimer: Any = None
NSApp: Any = None


def _timer_api():
    if NSTimer is not None:
        return NSTimer
    from Foundation import NSTimer as timer

    return timer


def _application():
    if NSApp is not None:
        return NSApp
    from AppKit import NSApp as application

    return application


def _schedule_timer(interval: float, target, selector: str, repeats: bool):
    return _timer_api().scheduledTimerWithTimeInterval_target_selector_userInfo_repeats_(
        interval, target, selector, None, repeats
    )


def command(name: str, *, main_thread: bool = True):
    def register(function):
        _MAIN_THREAD_COMMANDS[name] = CommandSpec(function, main_thread)
        return function

    return register


def command_names() -> tuple[str, ...]:
    return tuple(sorted(_MAIN_THREAD_COMMANDS))


# --- command handlers (self is the headless controller) ----------------------


def _find_status(self, session: object):
    if not isinstance(session, str) or not session:
        raise CommandError("invalid_args", "session is required")
    snapshot = getattr(self, "last_snapshot", None)
    if snapshot is None:
        raise CommandError("not_found", "no snapshot yet")
    for status in (*snapshot.statuses, *getattr(snapshot, "stale_statuses", ())):
        if status.agent_id == session:
            return status
    raise CommandError("not_found", "no such session")


def _command_journal(self):
    """The durable command ledger, lazily loaded from the state dir.

    ``answer_ask`` writes its intent before the effect so a crash
    mid-answer leaves an ``accepted`` record — outcome unknown — and a
    retried command id replays its first receipt instead of re-typing.
    A journal that cannot load or persist degrades to memory-only: the
    answer path still runs, the ledger simply forgets on restart.
    """
    journal = getattr(self, "_jrbar_command_journal", None)
    if journal is None:
        from .command_journal import CommandJournal
        try:
            journal = CommandJournal.load(default_state_dir())
        except Exception:
            journal = CommandJournal()
        self._jrbar_command_journal = journal
    return journal


def _ask_event_identity(status) -> str | None:
    """The episode identity the ask diff and events are keyed on.

    The canonical request key's announcer identity when the status
    carries one; ``None`` when it does not (a legacy-path ask). ``None``
    is the honest "cannot prove replacement": the diff then falls back to
    session presence, exactly as before this field existed.
    """
    request_key = getattr(status, "request_key", None)
    if request_key is None:
        return None
    try:
        from .announcer_stack import announcer_alert_identity

        return str(announcer_alert_identity(request_key).value)
    except Exception:
        return None


def _diff_ask_episodes(previous: dict, current: dict) -> list[tuple[str, str, object, str | None]]:
    """(kind, agent_id, status, request_identity) for the ask-set change.

    Keyed by session AND episode: a session present on both sides whose
    request identity moved emits ``ask_resolved`` for the old episode and
    ``ask_opened`` for the new one — a surface holding A's card never has
    it silently become B. Identities of ``None`` (unmodelled asks) never
    prove a replacement; presence alone decides, as before.
    """
    events: list[tuple[str, str, object, str | None]] = []
    for agent_id, (status, identity) in current.items():
        previous_entry = previous.get(agent_id)
        if previous_entry is None:
            events.append(("ask_opened", agent_id, status, identity))
            continue
        prev_status, prev_identity = previous_entry
        if identity is not None and prev_identity is not None and identity != prev_identity:
            events.append(("ask_resolved", agent_id, prev_status, prev_identity))
            events.append(("ask_opened", agent_id, status, identity))
    for agent_id, (status, identity) in previous.items():
        if agent_id not in current:
            events.append(("ask_resolved", agent_id, status, identity))
    return events


@command("open_session", main_thread=False)
def _cmd_open_session(self, args):
    """Open a session: raise a live one's own window, resume an ended one.

    Runs on the socket thread, not the main run loop: finding and raising a
    session's window is a process-table walk, osascript and tmux calls --
    seconds on the first open, while macOS asks for Automation consent --
    and on the main thread that stalls every refresh and timer behind it.
    The row, its extras, Settings and the controller's own open ladder are
    main-thread state and hop over through ``_core_on_main``.
    """
    on_main = getattr(self, "_core_on_main", None) or (lambda fn: fn())
    status = on_main(lambda: _find_status(self, args.get("session")))
    # A live CLI session already has a window: raise that tab, pane or
    # Ghostty terminal instead of starting a second ``--resume`` process;
    # an ended one resumes in the terminal it ran in (answer_surfaces.py).
    # ``None`` is a remote or app-hosted session, an explicit app/VS Code
    # choice, or no record of its terminal: the ladder below.
    from .answer_surfaces import open_session_surface

    raised = open_session_surface(self, status, args, on_main=on_main)
    if raised is not None:
        return raised

    def ladder():
        self.open_session(
            status, args.get("action") if isinstance(args.get("action"), str) else None, remember=False
        )
        extras = self._core_extras_for(status)
        return {
            "session": status.agent_id,
            "activated": (extras.terminal or {}).get("app") if extras is not None else None,
            "origin": extras.origin if extras is not None else None,
        }

    return on_main(ladder)


@command("answer_ask", main_thread=False)
def _cmd_answer_ask(self, args):
    """Answer one live ask in the session's own terminal.

    The whole command is one round trip: the answer goes through the reviewed
    ``local.answer_in_place`` surface (answer_local.py) on the runtime's
    worker, and this handler waits for that surface's own verdict so the reply
    says what actually happened rather than "dispatched". Every refusal code
    the surface can produce is documented in docs/CORE-PROTOCOL.md.

    ``only_if_frontmost`` (default true) does not gate the safety checks --
    nothing does. False means "raise the session's terminal first"; the same
    chain then runs against whatever is genuinely in front.

    Runs on the socket thread, not the main run loop: the surface verdict
    wait is up to ``ANSWER_REPLY_BUDGET_SECONDS`` and holding it on the main
    thread stalls every refresh, timer and other command behind it. The
    pieces that are main-thread state -- the journal (not thread-safe), the
    answer controller's in-flight bookkeeping, the refresh -- hop over
    through ``_core_on_main``.
    """
    on_main = getattr(self, "_core_on_main", None) or (lambda fn: fn())
    lock = getattr(self, "_core_answer_ask_lock", None)
    if lock is None:
        # A controller built before the socket server (or a test stub)
        # still gets mutual exclusion once the attribute lands.
        lock = threading.Lock()
        try:
            self._core_answer_ask_lock = lock
        except Exception:
            pass
    from .announcer_stack import announcer_alert_identity
    from .answer_controller import AnswerBrowserCommand
    from .answer_in_place import MAX_ANSWER_REPLY_LENGTH, AnswerActionKind
    from .answer_local import raise_application, session_host

    status = _find_status(self, args.get("session"))
    # The decide lane first: a PermissionRequest the agent's own hook is
    # holding for JR-Bar is answered by replying to that hook, from any
    # terminal, with nothing typed (answer_decisions.py). ``None`` is "not
    # held here" and the keystroke path below takes it as before.
    from .answer_decisions import answer_through_decision_lane

    lane_reply = answer_through_decision_lane(
        self, status, args, journal_for=_command_journal, on_main=on_main
    )
    if lane_reply is not None:
        return lane_reply
    decision = str(args.get("decision") or "approve").lower()
    if decision not in ("approve", "deny"):
        raise CommandError("invalid_args", "decision must be approve or deny")
    reply_text = args.get("reply_text")
    if reply_text is not None:
        # An ``input`` ask takes the words themselves: normalized to one
        # bounded printable line here, then typed into the session's
        # terminal and submitted by the same fenced surface.
        if type(reply_text) is not str:
            raise CommandError("invalid_args", "reply_text must be a string")
        normalized = " ".join(reply_text.split())[:MAX_ANSWER_REPLY_LENGTH]
        if not normalized or not normalized.isprintable():
            raise CommandError(
                "invalid_args", "reply_text must be non-empty printable text"
            )
        reply_text = normalized
    state = getattr(self, "current_operator_state", None)
    work_key = getattr(status, "work_key", None)
    request = None
    if state is not None and work_key is not None:
        for candidate in state.requests:
            if candidate.key.work_key == work_key and candidate.phase.value.startswith("live"):
                request = candidate
                break
    if request is None:
        raise CommandError("not_found", "no live ask for that session")
    # A card pinned to one request must never answer its replacement: when
    # the caller names the ask it is looking at, a different live request
    # refuses BEFORE anything is armed or typed (T07). An identity the
    # daemon cannot even compute cannot verify — same refusal.
    expected_request = args.get("request")
    if expected_request is not None:
        try:
            live_identity = str(announcer_alert_identity(request.key).value)
        except Exception:
            live_identity = None
        if expected_request != live_identity:
            raise CommandError(
                "stale_request",
                "that request was replaced — the card is stale; answer the current ask",
            )
    surface = getattr(self, "local_answer_surface", None)
    if surface is None:
        raise CommandError("unsupported", "no local answer surface is registered")
    from .command_journal import STATUS_ACCEPTED, STATUS_COMPLETED
    # The journal is lazily created and not thread-safe: the getter hops
    # to main so two socket threads cannot race the one-time load.
    journal = on_main(lambda: _command_journal(self))
    command_id = args.get("command_id")
    if type(command_id) is not str or not command_id:
        command_id = None
    record = on_main(
        lambda: journal.begin(
            "answer_ask",
            {"session": status.agent_id,
             "decision": "reply" if reply_text is not None else decision,
             "request": expected_request},
            command_id=command_id,
        )
    )
    if record.status != STATUS_ACCEPTED:
        # A retry of a settled command replays its first receipt — the
        # second send never re-types an answer (T09/T70).
        if record.status == STATUS_COMPLETED and record.receipt is not None:
            return {**record.receipt, "replayed": True}
        raise CommandError(
            (record.error or {}).get("code", "send_failed"),
            (record.error or {}).get("message", "that command already failed"),
        )
    # One in-flight answer at a time: the surface's completed event is
    # shared, so a second command must not arm it while the first waits.
    with lock:
        if not bool(args.get("only_if_frontmost", True)):
            # Explicitly asked to answer a terminal that is not in front: raise it,
            # then let the unchanged check chain decide. Never a bypass.
            # The session's own tab, tmux pane or Ghostty terminal first
            # (answer_surfaces.py), so the focused-target proof can pass;
            # the app-level raise below stays the fallback.
            from .answer_surfaces import raise_for_answer

            raise_for_answer(self, status, on_main=on_main)
            host = session_host(
                getattr(status, "provider", None),
                getattr(status, "session_id", None),
                getattr(status, "origin", None),
            )
            for bundle_id in sorted(host.bundle_ids):
                if raise_application(bundle_id):
                    break
        command_payload = AnswerBrowserCommand(
            work_key=work_key,
            generation=state.generation,
            request_identity=announcer_alert_identity(request.key),
            action=(
                AnswerActionKind.REPLY
                if reply_text is not None
                else AnswerActionKind.APPROVE
                if decision == "approve"
                else AnswerActionKind.DENY
            ),
            reply_text=reply_text,
        )
        snapshot = self.last_snapshot
        surface.arm()
        try:
            accepted = on_main(
                lambda: self.answer_controller.perform_browser_answer(
                    command_payload, state, tuple(snapshot.statuses)
                )
            )
            if not accepted:
                raise CommandError("unsupported", "this ask cannot be answered from here")
            # The long pole: wait on the socket thread so the main run
            # loop keeps driving timers, refreshes and other commands.
            if not surface.completed.wait(ANSWER_REPLY_BUDGET_SECONDS):
                raise CommandError("busy", "answering did not finish in time")
            outcome = surface.last_outcome
            if outcome is None:
                raise CommandError("send_failed", "the answer surface reported nothing")
            if not outcome.delivered:
                raise CommandError(outcome.code, outcome.message)
        except CommandError as error:
            # The journal settles as the same refusal the caller sees — a
            # retry of this command id replays that verdict, never re-runs.
            on_main(
                lambda error=error: journal.settle(
                    record.command_id,
                    error={"code": error.code, "message": str(error)})
            )
            raise
    on_main(lambda: self.refresh_(None))
    result = {
        "session": status.agent_id,
        "decision": "reply" if reply_text is not None else decision,
        "answered": True,
        **outcome.document(),
    }
    on_main(lambda: journal.settle(record.command_id, receipt=result))
    return result


@command("snooze")
def _cmd_snooze(self, args):
    from .agent_browser_window import AgentBrowserActionPayload
    from .navigation_policy import OperatorActionKind

    seconds = float(args.get("seconds") or 0)
    session = args.get("session") or "all"
    state = getattr(self, "current_operator_state", None)
    if state is None:
        raise CommandError("not_found", "no operator state yet")
    if session == "all":
        if seconds <= 0:
            # Unsnooze-all means every family actually snoozed — quiet
            # working rows too, not just the sessions currently asking.
            snapshot = getattr(self, "last_snapshot", None)
            pool = [*snapshot.statuses, *getattr(snapshot, "stale_statuses", ())] if snapshot else []
            snoozed = set(self._core_snoozed_untils(pool))
            targets = [status for status in pool if status.agent_id in snoozed]
        else:
            targets = list(self._core_ask_statuses())
    else:
        targets = [_find_status(self, session)]
    applied: list[str] = []
    for status in targets:
        work_key = getattr(status, "work_key", None)
        if work_key is None:
            continue
        if seconds <= 0:
            payload = AgentBrowserActionPayload(work_key, state.generation, OperatorActionKind.UNSNOOZE)
        else:
            preset = "15-minutes" if seconds <= 900 else "1-hour" if seconds <= 3600 else "tomorrow"
            payload = AgentBrowserActionPayload(
                work_key, state.generation, OperatorActionKind.SNOOZE, snooze_preset=preset
            )
        try:
            if self._apply_preference_action(payload):
                applied.append(status.agent_id)
        except Exception as exc:
            self._core_log(f"snooze failed for {status.agent_id}: {exc}")
    self.refresh_(None)
    return {"sessions": applied, "until": (time.time() + seconds) if seconds > 0 else None}


@command("clear_completed")
def _cmd_clear_completed(self, args):
    """Acknowledge every finished-or-stale row the panel is listing.

    Not "clear recent completions": the rows the user is looking at, whatever
    made them stop -- a Stop, a closed terminal, a process that died, a source
    that went quiet. Afterwards ``state.sessions`` holds only live sessions and
    the rest are in ``list_history``. ``sessions`` may name a subset;
    ``"all"`` (the default) takes the lot.
    """
    import secrets

    from .clear_agents import ClearAgentsPlanError, plan_clear_agents_commit
    from .completion_visibility import project_clearable_sessions

    snapshot = getattr(self, "last_snapshot", None)
    if snapshot is None:
        raise CommandError("not_found", "no snapshot yet")
    if getattr(self, "_clear_agents_operation_pending", False):
        raise CommandError("busy", "a clear is already in flight")
    requested = args.get("sessions")
    if requested in (None, "all", "*"):
        session_ids = None
    elif isinstance(requested, (list, tuple)):
        session_ids = [str(value) for value in requested if isinstance(value, str)]
        if not session_ids:
            return {"batch": None, "cleared": []}
    else:
        raise CommandError("invalid_args", "sessions must be a list or \"all\"")
    with self._core_lock:
        listed = [
            str(row.get("id") or "")
            for row in (self._core_documents.get("state") or {}).get("sessions") or ()
        ]
    if not listed:
        # No published document yet (a command before the first refresh):
        # fall back to the snapshot's own rows.
        listed = [
            str(getattr(status, "agent_id", ""))
            for status in (*snapshot.statuses, *getattr(snapshot, "stale_statuses", ()))
        ]
    try:
        preview = project_clearable_sessions(
            (*snapshot.statuses, *getattr(snapshot, "stale_statuses", ())),
            listed_ids=listed,
            state=self.clear_agents_state,
            now_epoch=time.time(),
            session_ids=session_ids,
        )
        if preview.clearable_count <= 0:
            return {"batch": None, "cleared": []}
        plan = plan_clear_agents_commit(
            preview,
            preview,
            self.clear_agents_state,
            batch_id=secrets.token_hex(16),
            committed_at_epoch=time.time(),
        )
    except ClearAgentsPlanError as error:
        raise CommandError("refused", str(getattr(error, "reason", error))) from error
    except (TypeError, ValueError) as error:
        raise CommandError("internal", str(error)) from error
    self._clear_agents_preview = preview
    _apply_clear_agents_plan(self, "commit", plan)
    self._core_last_clear_batch = plan.batch_receipt.batch_id
    # Every acknowledged row, not only the twenty the popover previews.
    cleared = sorted({key.agent_id for key in plan.batch_receipt.newly_added_keys})
    return {"batch": plan.batch_receipt.batch_id, "cleared": cleared}


def _apply_clear_agents_plan(self, kind: str, plan) -> None:
    """Save the receipts and republish, in order, on this thread.

    The menu's own path hands the write to the persistence writer and picks
    the result up later on the main thread. A command has to answer now: the
    reply says the rows are gone, so the next ``state`` must already agree.
    """
    from .clear_agents_store import save_clear_agents_state

    try:
        save_clear_agents_state(self.clear_agents_path, plan.next_state)
    except (OSError, TypeError, ValueError) as error:
        raise CommandError("refused", f"could not save the clear receipts: {error}") from error
    self.clear_agents_state = plan.next_state
    self.current_mailbox_projection = None
    self._menu_signature = None
    if kind == "commit":
        self._clear_agents_commit_plan = plan
    self._core_publish_state()


@command("undo_clear")
def _cmd_undo_clear(self, args):
    """Put a cleared batch back, inside its 300 s window.

    The rows return to ``state.sessions`` exactly as they were: the undo
    removes the receipts, and visibility is recomputed from them.
    """
    from .clear_agents import ClearAgentsCommitPlan, ClearAgentsPlanError, plan_clear_agents_undo

    batch = str(args.get("batch") or getattr(self, "_core_last_clear_batch", "") or "")
    commit_plan = getattr(self, "_clear_agents_commit_plan", None)
    if type(commit_plan) is not ClearAgentsCommitPlan or commit_plan.batch_receipt.batch_id != batch:
        raise CommandError("not_found", "no such batch")
    try:
        plan = plan_clear_agents_undo(self.clear_agents_state, batch_id=batch, now_epoch=time.time())
    except ClearAgentsPlanError as error:
        reason = getattr(getattr(error, "reason", None), "value", "refused")
        raise CommandError("expired" if reason == "expired" else "refused", str(reason)) from error
    restored = sorted({key.agent_id for key in plan.batch_receipt.newly_added_keys})
    _apply_clear_agents_plan(self, "undo", plan)
    return {"batch": batch, "restored": restored}


@command("dismiss_session")
def _cmd_dismiss_session(self, args):
    """Acknowledge one live or stuck row until its session next speaks.

    The same receipt ``clear_completed`` writes, aimed at a single session
    the batch clear would never touch: its ``completed_at_epoch`` is the
    row's own ``updated_at``, so the row leaves ``state.sessions`` now and
    returns the moment a newer event lands. A row pinned by an open ask is
    refused -- the ask is the point -- and a ``remote:`` row is the peer's
    to manage.
    """
    from .clear_agents import (
        MAX_COMPLETION_RECEIPTS,
        ClearAgentsState,
        CompletionPresentationKey,
        CompletionPresentationReceipt,
    )
    from .clear_agents_store import save_clear_agents_state

    status = _find_status(self, args.get("session"))
    agent_id = status.agent_id
    if agent_id.startswith("remote:"):
        raise CommandError("refused", "a remote session is the peer's to manage")
    if agent_id in {s.agent_id for s in self._core_ask_statuses()}:
        raise CommandError("refused", "the session has an open ask")
    try:
        key = CompletionPresentationKey(
            source_key=status.work_key.source_key,
            agent_id=agent_id,
            event_name=status.event_name,
            completed_at_epoch=status.updated_at.timestamp(),
        )
    except (AttributeError, TypeError, ValueError, OSError, OverflowError) as error:
        raise CommandError("refused", "the session cannot be acknowledged") from error
    state = getattr(self, "clear_agents_state", None)
    if type(state) is not ClearAgentsState:
        state = ClearAgentsState()
    # Keys the live (un-undone) batch still claims must stay: dropping one
    # would make ``latest_batch`` invalid on the next state.
    protected = (
        set(state.latest_batch.newly_added_keys)
        if state.latest_batch is not None and not state.latest_batch.undone
        else frozenset()
    )
    merged = {receipt.key: receipt for receipt in state.receipts}
    merged[key] = CompletionPresentationReceipt(
        key=key, acknowledged_at_epoch=time.time()
    )
    kept = sorted(merged.values(), key=lambda receipt: receipt.key)
    if len(kept) > MAX_COMPLETION_RECEIPTS:
        # Retire the oldest acknowledgements first; a dismissed row simply
        # reappears if its receipt ages out.
        excess = len(kept) - MAX_COMPLETION_RECEIPTS
        droppable = [
            receipt.key
            for receipt in sorted(kept, key=lambda r: r.acknowledged_at_epoch)
            if receipt.key not in protected
        ][:excess]
        dropped = set(droppable)
        kept = [receipt for receipt in kept if receipt.key not in dropped]
    try:
        next_state = ClearAgentsState(
            generation=state.generation + 1,
            receipts=tuple(kept),
            latest_batch=state.latest_batch,
        )
    except ValueError as error:
        raise CommandError("internal", f"could not record the dismissal: {error}") from error
    try:
        save_clear_agents_state(self.clear_agents_path, next_state)
    except (OSError, TypeError, ValueError) as error:
        raise CommandError("refused", f"could not save the dismissal: {error}") from error
    self.clear_agents_state = next_state
    self.current_mailbox_projection = None
    self._menu_signature = None
    self._core_publish_state()
    return {"session": agent_id, "dismissed": True}


def _apply_settings_document(self, document: dict[str, Any], *, touched: list[str]) -> int:
    legacy = self._core_legacy()
    try:
        candidate = settings_from_document(document)
    except Exception as error:
        raise CommandError("invalid_value", f"settings did not validate: {error}") from error
    self.settings = candidate
    try:
        legacy.save_settings(self.settings)
    except Exception as error:
        self.settings = legacy.load_settings()
        raise CommandError("refused", f"could not save settings: {error}") from error
    self._core_after_settings_change(touched)
    return self._core_settings_generation


@command("set_setting")
def _cmd_set_setting(self, args):
    path = str(args.get("path") or "")
    if not path:
        raise CommandError("invalid_path", "path is required")
    if split_path(path)[0] in READ_ONLY_SETTINGS:
        raise CommandError("read_only", f"{path!r} is a fact about the daemon, not a preference")
    document = self.settings.to_dict()
    _current, exists = get_path(document, path)
    if not exists and not isinstance(get_path(document, ".".join(str(p) for p in split_path(path)[:-1]))[0], dict):
        raise CommandError("invalid_path", f"cannot write {path!r}")
    if not set_path(document, path, args.get("value")):
        raise CommandError("invalid_path", f"cannot write {path!r}")
    generation = _apply_settings_document(self, document, touched=[path])
    value, _ = get_path(self.settings.to_dict(), path)
    return {"generation": generation, "path": path, "value": value}


@command("reset_settings")
def _cmd_reset_settings(self, args):
    from ._settings_legacy import AgentMonitorSettings, DeviceDisplaySetting

    paths = [str(path) for path in (args.get("paths") or []) if isinstance(path, str)]
    defaults = AgentMonitorSettings().to_dict()
    # A defaults document carries no remembered devices, so a
    # ``devices.N.<field>`` reset has no row to read -- the leaf default
    # on a stock DeviceDisplaySetting is the answer instead. Identity
    # fields (id, name, path) are not preferences and never reset.
    device_defaults = {
        key: value
        for key, value in DeviceDisplaySetting(device_id="", name="", path="").to_dict().items()
        if key not in ("id", "name", "path")
    }
    document = self.settings.to_dict()
    reset: list[str] = []
    for path in paths:
        value, found = get_path(defaults, path)
        if not found:
            parts = split_path(path)
            if (
                len(parts) == 3
                and parts[0] == "devices"
                and isinstance(parts[1], int)
                and parts[2] in device_defaults
            ):
                value, found = device_defaults[parts[2]], True
        if found and set_path(document, path, json.loads(json.dumps(value))):
            reset.append(path)
    generation = _apply_settings_document(self, document, touched=reset) if reset else self._core_settings_generation
    return {"generation": generation, "reset": reset}


@command("set_brightness")
def _cmd_set_brightness(self, args):
    target = args.get("device") or "all"
    try:
        value = float(args.get("value"))
    except (TypeError, ValueError) as error:
        raise CommandError("invalid_args", "value must be a number") from error
    value = max(0.0, min(1.0, value))
    devices = [
        device
        for device in self.status_bar_devices(remember=False)
        if target == "all" or device.device_id == target
    ]
    if not devices:
        raise CommandError("not_found", "no such device")
    for device in devices:
        self.set_device_brightness(device.device_id, value * 255.0)
    if target == "all":
        # The panel slider: in ambient auto-dim, a vote for how bright the
        # lights should be at this much light (jrbar.core_lights). Auto-dim
        # scales only the hardware, so only a slider over hardware votes.
        try:
            from . import core_lights

            virtual = self._core_legacy().VIRTUAL_DEVICE_ID
            if any(device.connected and device.device_id != virtual for device in devices):
                core_lights.note_brightness_nudge(self, value)
        except Exception:
            pass
    self._core_publish_lights()
    return {"value": value, "devices": [device.device_id for device in devices]}


@command("set_device_display")
def _cmd_set_device_display(self, args):
    legacy = self._core_legacy()
    device = args.get("device")
    mode = str(args.get("mode") or "agent")
    if mode not in legacy.LED_DISPLAY_CHOICES:
        raise CommandError("invalid_args", f"unknown display mode {mode!r}")
    if not isinstance(device, str) or not device:
        raise CommandError("invalid_args", "device is required")
    self.set_device_display(device, mode)
    return {"device": device, "mode": mode}


@command("apply_calibration")
def _cmd_apply_calibration(self, args):
    device = args.get("device")
    profile = args.get("profile") or {}
    if not isinstance(device, str) or not device or not isinstance(profile, dict):
        raise CommandError("invalid_args", "device and profile are required")
    known = {entry.device_id for entry in self.settings.devices} | {
        entry.device_id for entry in self.status_bar_devices(remember=False)
    }
    if device not in known:
        raise CommandError("not_found", "no such device")

    def number(key: str) -> float | None:
        if key not in profile:
            return None
        try:
            value = float(profile[key])
        except (TypeError, ValueError) as error:
            raise CommandError("invalid_args", f"{key} must be a number") from error
        if value != value or value in (float("inf"), float("-inf")):
            raise CommandError("invalid_args", f"{key} must be finite")
        return value

    settings = self.settings
    applied: dict[str, float] = {}
    for channel in ("red", "green", "blue"):
        key = f"{channel}_gain"
        value = number(key)
        if value is not None:
            # The mutator clamps to MIN..MAX_CHANNEL_GAIN; the reply echoes
            # what persisted, not what was asked for.
            settings = settings.with_device_channel_gain(device, channel, value)
            applied[key] = settings.channel_gains_for_device(device)[
                ("red", "green", "blue").index(channel)
            ]
    glow = number("resting_glow")
    if glow is not None:
        settings = settings.with_device_resting_glow(device, glow)
        applied["resting_glow"] = settings.resting_glow_for_device(device)
    brightness = number("brightness")
    if brightness is not None:
        # Brightness is calibration too: two LEDs an arm's length away (the
        # Dot) read far brighter than eight across a desk, so matching by
        # eye ends here as often as it ends on the gains.
        settings = settings.with_device_brightness(device, brightness)
        applied["brightness"] = float(settings.brightness_for_device(device))
    self.settings = settings
    self._core_legacy().save_settings(self.settings)
    # The applied values ARE the live ones now: a held preview still
    # showing the working numbers would be claiming a calibration the
    # device is no longer running.
    self._core_end_calibration_preview(device, refresh=False)
    self._core_after_settings_change(["devices"])
    return {"device": device, "profile": applied, "generation": self._core_settings_generation}


@command("preview_program")
def _cmd_preview_program(self, args):
    from ._led_status_legacy import LedDisplayState, led_count_for_target

    legacy = self._core_legacy()
    surface = str(args.get("surface") or "screen_bar")
    program = args.get("program")
    if not isinstance(program, str) or not program.strip():
        raise CommandError("invalid_args", "program is required")
    try:
        seconds = float(args.get("seconds", 3.0))
    except (TypeError, ValueError) as error:
        raise CommandError("invalid_args", "seconds must be a number") from error
    seconds = max(0.2, min(PREVIEW_MAX_SECONDS, seconds))
    wanted_leds = {"hardware": 8, "dot": 2}.get(surface)
    targets = [
        device
        for device in self.status_bar_devices(remember=False)
        if device.connected
        and device.device_id != legacy.VIRTUAL_DEVICE_ID
        and (
            surface == device.device_id
            or (wanted_leds is not None and led_count_for_target(device.target) == wanted_leds)
        )
    ]
    # A held calibration preview owns its surface for minutes; a flash
    # over it would drop the hold's entry and paint the patch away.
    existing = self._core_previews.get(surface)
    held = self._core_held_preview_devices()
    if (existing is not None and existing.held) or any(
        device.device_id in held for device in targets
    ):
        raise CommandError("busy", "a calibration preview holds this surface")
    device_ids: list[str] = []
    for device in targets:
        controller = self.agent_controller_for_device(device)
        try:
            controller.sync_program(legacy.apply_brightness(program, controller.brightness), LedDisplayState.IDLE)
        except Exception as exc:
            raise CommandError("refused", f"device refused the program: {exc}") from exc
        device_ids.append(device.device_id)
    if surface not in ("screen_bar",) and not device_ids:
        raise CommandError("not_found", "no such surface")
    self._core_previews[surface] = _Preview(program, time.monotonic() + seconds, time.time(), tuple(device_ids))
    self._core_publish_lights()
    return {"surface": surface, "until": time.time() + seconds, "devices": device_ids}


@command("preview_calibration")
def _cmd_preview_calibration(self, args):
    """Show a calibration patch through the GIVEN values, held on the device.

    Unlike ``preview_program`` this writes bytes that have already been
    through the device's write boundary -- resting glow and the caller's
    gains applied here, never the stored ones and never twice. ``sync_program``
    would apply the stored profile on top, which is how the old sheet's
    preview lied: the hex it built carried the working gains and the write
    path carried the stored ones, so the strip showed neither.
    """
    import re

    from ._led_status_legacy import (
        LedDisplayState,
        apply_brightness,
        apply_channel_gain_to_program,
        apply_resting_glow_to_program,
        apply_strip_transform_to_program,
        led_count_for_target,
        normalize_brightness,
        normalize_channel_gain,
    )

    legacy = self._core_legacy()
    device_id = args.get("device")
    if not isinstance(device_id, str) or not device_id:
        raise CommandError("invalid_args", "device is required")
    devices = self.status_bar_devices(remember=False)
    device = next(
        (entry for entry in devices if entry.device_id == device_id and entry.connected),
        None,
    )
    if device is None:
        raise CommandError("not_found", "no such device")

    def number(key: str, default: float, lo: float, hi: float) -> float:
        raw = args.get(key)
        if raw is None:
            return default
        try:
            value = float(raw)
        except (TypeError, ValueError) as error:
            raise CommandError("invalid_args", f"{key} must be a number") from error
        if value != value or value in (float("inf"), float("-inf")):
            raise CommandError("invalid_args", f"{key} must be finite")
        return max(lo, min(hi, value))

    gains_arg = args.get("gains")
    if not isinstance(gains_arg, dict):
        raise CommandError("invalid_args", "gains must be a mapping")
    try:
        gains = (
            normalize_channel_gain(float(gains_arg["red"])),
            normalize_channel_gain(float(gains_arg["green"])),
            normalize_channel_gain(float(gains_arg["blue"])),
        )
    except (KeyError, TypeError, ValueError) as error:
        raise CommandError("invalid_args", "gains need numeric red, green and blue") from error
    resting_glow = number("resting_glow", device.resting_glow, 0.0, 0.35)
    brightness = normalize_brightness(number("brightness", device.brightness, 0.0, 255.0))

    patch = args.get("patch", "white")
    if isinstance(patch, str) and patch in CALIBRATION_PATCHES:
        patch_hex = CALIBRATION_PATCHES[patch]
    elif isinstance(patch, str) and re.fullmatch(r"#[0-9A-Fa-f]{6}", patch):
        patch_hex = patch.upper()
    else:
        raise CommandError("invalid_args", "patch must be a name or #RRGGBB")
    companion = bool(args.get("companion", False))

    # The nominal patch: the colour the device SHOULD read as, with the
    # caller's brightness as the program's own `brightness N` line. All the
    # transforms below run on this nominal text exactly as the live path
    # runs on rendered programs.
    nominal = apply_brightness(f"{patch_hex} 500ms\nrepeat", brightness)
    until_monotonic = time.monotonic() + CALIBRATION_HOLD_SECONDS
    until_epoch = time.time() + CALIBRATION_HOLD_SECONDS
    started_epoch = time.time()

    if device.device_id == legacy.VIRTUAL_DEVICE_ID:
        # The Screen Bar's boundary is the code-domain one: its on-screen
        # engine multiplies the encoded code, so gains multiply the code
        # too -- the strip's light-domain decode would double-dim it. The
        # bar itself renders from the lights document, so the preview is
        # the surface entry; nothing is written to hardware.
        program = apply_channel_gain_to_program(
            apply_resting_glow_to_program(nominal, resting_glow),
            gains,
        )
        self._core_previews["screen_bar"] = _Preview(
            program, until_monotonic, started_epoch, (device.device_id,), held=True
        )
        self._core_publish_lights()
        return {
            "device": device_id,
            "surface": "screen_bar",
            "until": until_epoch,
            "program": program,
            "companion": None,
        }

    leds = led_count_for_target(device.target)
    program = apply_strip_transform_to_program(
        nominal, resting_glow=resting_glow, gains=gains
    )
    surface = (
        "dot"
        if leds == 2
        else "hardware" if self._core_is_followed_strip(device) else device.device_id
    )
    # The hold is registered BEFORE the write: a queued live command that
    # lands between them used to paint over the patch and then be refused
    # at the write boundary for the rest of the 600 s hold (2026-09-11
    # audit). The except path withdraws the registration a refused write
    # never earned.
    self._core_previews[surface] = _Preview(
        program, until_monotonic, started_epoch, (device.device_id,), held=True
    )
    controller = self.agent_controller_for_device(device)
    try:
        # IDLE, not ASK: the state is bookkeeping on the controller, and an
        # ASK left there makes the next real ask's arrival_fresh check read
        # "already asking", so its crest never plays.
        controller.sync_transferred_program(program, LedDisplayState.IDLE)
    except Exception as exc:
        self._core_previews.pop(surface, None)
        raise CommandError("refused", f"device refused the program: {exc}") from exc

    companion_id: str | None = None
    if companion and leds == 2:
        # Dot brightness matching: the followed strip shows the same patch
        # through the strip's OWN stored profile, so the user dims the Dot
        # down to meet the light it actually sits beside. The strip's entry
        # is held too, or the next refresh would repaint it mid-comparison.
        strip_id = self._core_followed_strip_id()
        strip = next(
            (entry for entry in devices if entry.device_id == strip_id and entry.connected),
            None,
        )
        if strip is not None:
            companion_nominal = apply_brightness(
                f"{patch_hex} 500ms\nrepeat",
                strip.brightness,
            )
            companion_program = apply_strip_transform_to_program(
                companion_nominal,
                resting_glow=strip.resting_glow,
                gains=strip.channel_gains,
            )
            # Same order as the primary: the hold exists before the write,
            # and is withdrawn if the strip refuses it.
            self._core_previews["hardware"] = _Preview(
                companion_program,
                until_monotonic,
                started_epoch,
                (strip.device_id,),
                held=True,
                companion_of=device.device_id,
            )
            strip_controller = self.agent_controller_for_device(strip)
            try:
                strip_controller.sync_transferred_program(companion_program, LedDisplayState.IDLE)
            except Exception as exc:
                self._core_previews.pop("hardware", None)
                raise CommandError("refused", f"companion strip refused the program: {exc}") from exc
            companion_id = strip.device_id

    self._core_publish_lights()
    return {
        "device": device_id,
        "surface": surface,
        "until": until_epoch,
        "program": program,
        "companion": companion_id,
    }


@command("end_calibration_preview")
def _cmd_end_calibration_preview(self, args):
    device = args.get("device")
    if not isinstance(device, str) or not device:
        raise CommandError("invalid_args", "device is required")
    ended = self._core_end_calibration_preview(device)
    return {"device": device, "ended": ended}


@command("apply_effect")
def _cmd_apply_effect(self, args):
    """The protocol-1 alias: ``effect`` null or ``"none"`` is the remove.

    ``set_assignment``/``clear_assignment`` are the current spellings; this
    one stays for older clients and answers the same fuller assignment
    document, parameters sidecar included.
    """
    from . import core_effects
    from .effect_assignment_store import (
        EffectAssignmentRecord,
        EffectAssignmentStoreError,
        default_effect_assignment_path,
        save_effect_assignments,
    )

    cache = getattr(type(self), "_effect_assignment_cache", None)
    if cache is None:
        raise CommandError("unsupported", "effect assignments are unavailable")
    effect = args.get("effect")
    scope = args.get("scope") or "global"
    target = args.get("target")
    removing = effect in (None, "", "none")
    before_count = 0
    try:
        before_count = len(cache.snapshot().assignments)
        document = cache.snapshot()
        if removing:
            from .effect_studio import AssignmentScope

            document = document.without_assignment(AssignmentScope(str(scope)), target)
        else:
            record = EffectAssignmentRecord.create(effect, scope, target, registry=cache.registry())
            document = document.with_assignment(record)
        save_effect_assignments(default_effect_assignment_path(), document)
        cache.replace(document)
    except (EffectAssignmentStoreError, TypeError, ValueError) as error:
        raise CommandError("invalid_args", str(error)) from error
    if removing:
        removed = len(document.assignments) < before_count
        table = core_effects.load_assignment_parameters()
        if table.pop(core_effects.assignment_key(str(scope), target), None) is not None:
            try:
                core_effects.save_assignment_parameters(table)
            except OSError:
                pass
    else:
        assigned = cache.registry().get(str(effect))
        pack_effect = core_effects.pack_effect_for(_effect_packs(self), str(effect))
        parameters = _jsonable(
            core_effects.normalize_parameters(assigned, args.get("parameters"), pack_effect=pack_effect)
        ) if assigned is not None else {}
        table = core_effects.load_assignment_parameters()
        key = core_effects.assignment_key(str(scope), target)
        if parameters:
            table[key] = parameters
        else:
            table.pop(key, None)
        try:
            core_effects.save_assignment_parameters(table)
        except OSError as error:
            self._core_log(f"core: assignment parameters not saved: {error}")
    self.refresh_(None)
    result = _assignments_document(self)
    if removing:
        result.update({"effect": None, "scope": scope, "target": target, "removed": removed})
    else:
        result.update({
            "effect": effect,
            "scope": scope,
            "target": target,
            "assignment": {
                "effect_id": effect,
                "scope": scope,
                "target_id": target,
                "parameters": parameters,
            },
        })
    return result


def _jsonable(value: Any) -> Any:
    if isinstance(value, tuple):
        return [_jsonable(item) for item in value]
    if isinstance(value, list):
        return [_jsonable(item) for item in value]
    if isinstance(value, dict):
        return {str(key): _jsonable(item) for key, item in value.items()}
    return value


def _effects_cache(self):
    cache = getattr(type(self), "_effect_assignment_cache", None)
    if cache is None:
        raise CommandError("unsupported", "effect assignments are unavailable")
    return cache


def _effect_packs(self) -> tuple:
    from .effect_pack_store import EffectPackStore

    try:
        return tuple(EffectPackStore().list())
    except Exception as exc:
        self._core_log(f"core: effect packs unavailable: {exc.__class__.__name__}")
        return ()


def _effect_catalog(self) -> dict[str, Any]:
    from . import core_effects

    cache = _effects_cache(self)
    packs = _effect_packs(self)
    paths = {pack.pack_id: str(getattr(self, "_core_pack_paths", {}).get(pack.pack_id, "")) or None for pack in packs}
    return _jsonable(
        core_effects.catalog_document(
            cache.registry(),
            packs,
            # Content-derived, so the Studio badge tracks the catalog
            # instead of reading "gen 0" until something saves an
            # assignment; the cache's counter still moves it.
            generation=core_effects.catalog_generation(
                cache.registry(), packs, revision=cache.generation
            ),
            pack_paths={key: value for key, value in paths.items() if value},
        )
    )


def _assignments_document(self) -> dict[str, Any]:
    from . import core_effects

    cache = _effects_cache(self)
    document = cache.snapshot()
    active_scene = getattr(self.settings, "active_scene", None)
    return core_effects.assignment_document(
        document,
        parameters=core_effects.load_assignment_parameters(),
        active_scene=active_scene,
        generation=core_effects.assignments_generation(document, active_scene=active_scene),
    )


def _require_effect(self, effect_id: object):
    cache = _effects_cache(self)
    if not isinstance(effect_id, str) or not effect_id:
        raise CommandError("unknown_effect", "effect_id is required")
    effect = cache.registry().get(effect_id)
    if effect is None:
        raise CommandError("unknown_effect", f"no such effect: {effect_id}")
    return effect


@command("list_effects", main_thread=False)
def _cmd_list_effects(self, args):
    return _effect_catalog(self)


@command("render_effect", main_thread=False)
def _cmd_render_effect(self, args):
    from . import core_effects

    effect = _require_effect(self, args.get("effect_id"))
    try:
        led_count = int(args.get("led_count") or 8)
    except (TypeError, ValueError) as error:
        raise CommandError("invalid_args", "led_count must be a number") from error
    pack_effect = core_effects.pack_effect_for(_effect_packs(self), effect.identifier)
    parameters = core_effects.normalize_parameters(effect, args.get("parameters"), pack_effect=pack_effect)
    color = args.get("color") if isinstance(args.get("color"), str) else None
    try:
        program = core_effects.render_effect(effect, parameters, led_count=led_count, color=color)
    except Exception as error:
        raise CommandError("internal", f"render failed: {error.__class__.__name__}") from error
    return {
        "effect_id": effect.identifier,
        "program": program,
        "led_count": core_effects._render_led_count(led_count),
        "parameters": _jsonable(parameters),
        "cadence": core_effects.effect_cadence(effect, parameters),
    }


@command("list_assignments", main_thread=False)
def _cmd_list_assignments(self, args):
    return _assignments_document(self)


def _assignment_scope(value: object):
    from .effect_studio import AssignmentScope

    try:
        return AssignmentScope(str(value or ""))
    except ValueError as error:
        raise CommandError("invalid_scope", "unknown assignment scope") from error


def _save_assignments(self, document) -> None:
    from .effect_assignment_store import (
        EffectAssignmentStoreError,
        default_effect_assignment_path,
        save_effect_assignments,
    )

    cache = _effects_cache(self)
    try:
        save_effect_assignments(default_effect_assignment_path(), document)
    except (EffectAssignmentStoreError, OSError) as error:
        raise CommandError("refused", f"could not save assignments: {error}") from error
    cache.replace(document)
    self.refresh_(None)


# Semantic-scope targets the event-driven router can actually deliver:
# ``_semantic_kind`` only ever produces these four, so assigning the rest
# would persist a row nothing ever resolves.
_ROUTABLE_SEMANTIC_TARGETS: Final = frozenset(
    {"asking", "failure", "completion", "notification"}
)


def _apply_provider_motion_assignment(self, effect, scope, target_id) -> str | None:
    """Provider-scope motion assignments write the live color policy.

    ``provider_animation``-catalog effects are the persistent per-provider
    motion the solo renderers read through ``colors.provider_animation``.
    Recording the assignment alone would leave the picker's promise a dead
    write, so a provider target also lands in settings. Returns a warning
    string when the motion could not be applied; the assignment itself is
    already saved either way.
    """
    from .effect_studio import AssignmentScope

    if effect.catalog != "provider_animation" or scope is not AssignmentScope.PROVIDER:
        return None
    legacy = self._core_legacy()
    try:
        colors = self.settings.colors.with_agent_animation(target_id, effect.identifier)
    except (TypeError, ValueError):
        return f"{effect.identifier} is not a motion this build can apply"
    self.settings = self.settings.with_colors(colors)
    try:
        legacy.save_settings(self.settings)
    except Exception as error:
        return f"the motion was assigned but settings would not save: {error}"
    self._core_publish_settings()
    return None


def _clear_provider_motion_assignment(self, record) -> None:
    """Undo the settings half of a provider-scope motion assignment."""
    from .effect_studio import AssignmentScope

    if record is None or record.scope is not AssignmentScope.PROVIDER:
        return
    cache = _effects_cache(self)
    effect = cache.registry().get(record.effect_id)
    if effect is None or effect.catalog != "provider_animation":
        return
    from .colors import PROVIDER_ANIMATION_AUTO

    legacy = self._core_legacy()
    try:
        colors = self.settings.colors.with_agent_animation(
            record.target_id, PROVIDER_ANIMATION_AUTO
        )
    except (TypeError, ValueError):
        return
    self.settings = self.settings.with_colors(colors)
    try:
        legacy.save_settings(self.settings)
    except Exception:
        return
    self._core_publish_settings()


@command("set_assignment")
def _cmd_set_assignment(self, args):
    from . import core_effects
    from .effect_assignment_store import EffectAssignmentRecord, EffectAssignmentStoreError
    from .effect_studio import AssignmentScope, EffectStudioError, plan_assignment

    effect = _require_effect(self, args.get("effect_id"))
    scope = _assignment_scope(args.get("scope"))
    target = args.get("target_id")
    target = str(target).strip() if target is not None else None
    if target == "":
        target = None
    if scope is AssignmentScope.SEMANTIC and target not in _ROUTABLE_SEMANTIC_TARGETS:
        raise CommandError(
            "unroutable_semantic",
            f"{target} is a persistent state, not a deliverable effect; "
            "assign to a provider or scene instead",
        )
    if scope is AssignmentScope.SEMANTIC and target in ("asking", "failure") and effect.identifier != "alert":
        raise CommandError("reserved_semantic", "asking and failure keep their reserved effects")
    cache = _effects_cache(self)
    try:
        plan = plan_assignment(effect.identifier, scope, target, cache.registry())
        record = EffectAssignmentRecord(plan.effect_id, plan.scope, plan.target_id)
        document = cache.snapshot().with_assignment(record)
    except (EffectStudioError, EffectAssignmentStoreError, TypeError, ValueError) as error:
        raise CommandError("invalid_target", str(error)) from error
    _save_assignments(self, document)
    pack_effect = core_effects.pack_effect_for(_effect_packs(self), effect.identifier)
    parameters = _jsonable(core_effects.normalize_parameters(effect, args.get("parameters"), pack_effect=pack_effect))
    table = core_effects.load_assignment_parameters()
    key = core_effects.assignment_key(plan.scope.value, plan.target_id)
    if parameters:
        table[key] = parameters
    else:
        table.pop(key, None)
    try:
        core_effects.save_assignment_parameters(table)
    except OSError as error:
        self._core_log(f"core: assignment parameters not saved: {error}")
    motion_error = _apply_provider_motion_assignment(self, effect, plan.scope, plan.target_id)
    result = _assignments_document(self)
    result["assignment"] = {
        "effect_id": plan.effect_id,
        "scope": plan.scope.value,
        "target_id": plan.target_id,
        "parameters": parameters,
    }
    if motion_error is not None:
        result["motion_warning"] = motion_error
    return result


@command("clear_assignment")
def _cmd_clear_assignment(self, args):
    from . import core_effects

    scope = _assignment_scope(args.get("scope"))
    target = args.get("target_id")
    target = str(target).strip() if target is not None else None
    if target == "":
        target = None
    cache = _effects_cache(self)
    current = cache.snapshot()
    removed_record = current.assignment_for(scope, target)
    document = current.without_assignment(scope, target)
    removed = len(document.assignments) < len(current.assignments)
    if removed:
        _save_assignments(self, document)
        table = core_effects.load_assignment_parameters()
        if table.pop(core_effects.assignment_key(scope.value, target), None) is not None:
            try:
                core_effects.save_assignment_parameters(table)
            except OSError:
                pass
        _clear_provider_motion_assignment(self, removed_record)
    result = _assignments_document(self)
    result["removed"] = removed
    return result


def _reload_effect_registry(self) -> None:
    from . import core_effects

    cache = _effects_cache(self)
    cache.replace(cache.snapshot(), registry=core_effects.registry_with_packs(_effect_packs(self)))


@command("import_effect_pack")
def _cmd_import_effect_pack(self, args):
    from .effect_pack_store import EffectPackStore, EffectPackStoreError, PackMutationStatus

    raw = args.get("path")
    if not isinstance(raw, str) or not raw.strip():
        raise CommandError("invalid_args", "path is required")
    path = Path(raw).expanduser()
    try:
        receipt = EffectPackStore().install(path)
    except EffectPackStoreError as error:
        raise CommandError("invalid_pack", str(error)) from error
    except OSError as error:
        raise CommandError("invalid_pack", f"cannot read pack: {error.__class__.__name__}") from error
    if receipt.status is PackMutationStatus.REFUSED:
        code = "conflict" if receipt.reason == "already_installed" else "refused"
        raise CommandError(code, f"pack {receipt.pack_id} refused: {receipt.reason}")
    if not hasattr(self, "_core_pack_paths"):
        self._core_pack_paths = {}
    self._core_pack_paths[receipt.pack_id] = str(path)
    _reload_effect_registry(self)
    self.refresh_(None)
    catalog = _effect_catalog(self)
    pack = next((entry for entry in catalog["packs"] if entry["id"] == receipt.pack_id), None)
    catalog["imported"] = {
        "id": receipt.pack_id,
        "name": pack["name"] if pack else receipt.pack_id,
        "effects": len(pack["effects"]) if pack else 0,
    }
    return catalog


@command("remove_effect_pack")
def _cmd_remove_effect_pack(self, args):
    from .effect_pack_store import EffectPackStore, EffectPackStoreError, PackMutationStatus

    raw = args.get("pack_id")
    if not isinstance(raw, str) or not raw.strip():
        raise CommandError("invalid_args", "pack_id is required")
    try:
        receipt = EffectPackStore().remove(raw.strip())
    except EffectPackStoreError as error:
        raise CommandError("remove_failed", str(error)) from error
    if receipt.status is PackMutationStatus.REFUSED:
        code = "not_installed" if receipt.reason == "not_installed" else "refused"
        raise CommandError(code, f"pack {receipt.pack_id} refused: {receipt.reason}")
    paths = getattr(self, "_core_pack_paths", None)
    if type(paths) is dict:
        paths.pop(receipt.pack_id, None)
    _reload_effect_registry(self)
    self.refresh_(None)
    catalog = _effect_catalog(self)
    catalog["removed"] = {"id": receipt.pack_id}
    return catalog


@command("export_effect_pack", main_thread=False)
def _cmd_export_effect_pack(self, args):
    from . import core_effects
    from .effect_packs import MAX_PACK_BYTES, EffectPackError
    from .private_export import write_private_export

    raw = args.get("path")
    if not isinstance(raw, str) or not raw.strip():
        raise CommandError("invalid_args", "path is required")
    path = Path(raw).expanduser()
    ids = [str(item) for item in (args.get("ids") or []) if isinstance(item, str)]
    if not ids:
        raise CommandError("invalid_args", "ids[] is empty")
    name = args.get("name") if isinstance(args.get("name"), str) else None
    cache = _effects_cache(self)
    try:
        payload, encoded = core_effects.build_export_pack(cache.registry(), _effect_packs(self), ids, name=name, path=path)
    except KeyError as error:
        raise CommandError("unknown_effect", f"no such effect: {error.args[0]}") from error
    except (EffectPackError, ValueError) as error:
        raise CommandError("export_failed", str(error)) from error
    try:
        path.parent.mkdir(parents=True, exist_ok=True)
        written = write_private_export(path, encoded, max_bytes=MAX_PACK_BYTES)
    except (OSError, ValueError) as error:
        raise CommandError("export_failed", f"could not write {path}: {error.__class__.__name__}") from error
    return {"path": str(written), "effects": len(payload["effects"]), "bytes": len(encoded), "id": payload["id"]}


def _scene_pack_summary(pack) -> dict[str, Any]:
    """One ``list_scene_packs`` row: the ``ScenePackSummary`` the app decodes."""
    return {
        "id": pack.pack_id,
        "name": pack.name,
        "scenes": [entry.scene.value for entry in pack.scenes],
        "installed": True,
    }


# The strip tour ``preview_scene_pack`` renders, one step per scene the pack
# overrides: the colour names the scene, the policy's brightness dims it,
# the policy's motion picks the interpolation. A pack is policy, not pixels
# -- this is what its policies *feel* like, not a stored animation.
_SCENE_PACK_COLORS: Final = {
    "focus": "#FF9F0A",
    "calm": "#0A84FF",
    "night": "#5E5CE6",
    "demo": "#FFD60A",
    "travel": "#64D2FF",
    "dnd": "#6E6E73",
}
_SCENE_PACK_STEP_MS: Final = {"full": 600, "reduced": 900, "static": 1400}
_SCENE_PACK_INTERPOLATION: Final = {"full": "pulse", "reduced": "cosine", "static": "none"}


def _dimmed_color(color: str, brightness: float) -> str:
    try:
        factor = max(0.0, min(1.0, float(brightness)))
    except (TypeError, ValueError):
        factor = 1.0
    red = int(color[1:3], 16)
    green = int(color[3:5], 16)
    blue = int(color[5:7], 16)
    return f"#{round(red * factor):02X}{round(green * factor):02X}{round(blue * factor):02X}"


def _scene_pack_program(pack, *, led_count: int) -> str:
    """Compile the pack's scene-by-scene policy tour into a safe program."""
    from .core_effects import BASE_COLOR
    from .presentation_compiler import compile_presentation_program

    lines: list[str] = []
    for entry in pack.scenes:
        policy = entry.policy
        color = _dimmed_color(
            _SCENE_PACK_COLORS.get(entry.scene.value, BASE_COLOR),
            getattr(policy, "brightness", 1.0),
        )
        motion = getattr(getattr(policy, "effective_motion", None), "value", "static")
        lines.append(
            f"{color} {_SCENE_PACK_STEP_MS.get(motion, 1400)}ms "
            f"{_SCENE_PACK_INTERPOLATION.get(motion, 'none')}"
        )
    if len(lines) > 1:
        lines.append("repeat")
    compiled = compile_presentation_program(
        "\n".join(lines) or "off", led_count=led_count
    )
    return compiled.program


@command("list_scene_packs", main_thread=False)
def _cmd_list_scene_packs(self, args):
    from .scene_pack_store import ScenePackStore, ScenePackStoreError

    try:
        packs = ScenePackStore().list()
    except ScenePackStoreError as error:
        raise CommandError("internal", str(error)) from error
    return {"packs": [_scene_pack_summary(pack) for pack in packs]}


@command("import_scene_pack")
def _cmd_import_scene_pack(self, args):
    from .effect_pack_store import PackMutationStatus
    from .scene_pack_store import ScenePackStore, ScenePackStoreError

    raw = args.get("path")
    if not isinstance(raw, str) or not raw.strip():
        raise CommandError("invalid_args", "path is required")
    path = Path(raw).expanduser()
    store = ScenePackStore()
    try:
        # Validate and preview BEFORE any mutation -- the store re-validates
        # the same plan on install, so a refused pack never writes a byte.
        plan = store.preview_source(path)
    except ScenePackStoreError as error:
        raise CommandError("invalid_pack", str(error)) from error
    try:
        if args.get("update"):
            receipt = store.update(plan.pack)
        else:
            receipt = store.install(plan.pack)
    except ScenePackStoreError as error:
        raise CommandError("invalid_pack", str(error)) from error
    if receipt.status is PackMutationStatus.REFUSED:
        code = "conflict" if receipt.reason == "already_installed" else "refused"
        raise CommandError(code, f"scene pack {receipt.pack_id} refused: {receipt.reason}")
    self._core_log(f"core: imported scene pack {receipt.pack_id} ({len(plan.pack.scenes)} scenes)")
    return {
        "pack_id": receipt.pack_id,
        "name": plan.pack.name,
        "scenes": [entry.scene.value for entry in plan.pack.scenes],
        "installed": True,
        "migrated": bool(plan.migrated),
        "status": receipt.status.value,
    }


@command("preview_scene_pack", main_thread=False)
def _cmd_preview_scene_pack(self, args):
    from .core_effects import _render_led_count
    from .scene_pack_store import ScenePackStore, ScenePackStoreError

    pack_id = args.get("pack_id")
    if not isinstance(pack_id, str) or not pack_id.strip():
        raise CommandError("invalid_args", "pack_id is required")
    try:
        plan = ScenePackStore().preview(pack_id.strip())
    except ScenePackStoreError as error:
        raise CommandError("not_found", f"no such scene pack: {pack_id}") from error
    led_count = _render_led_count(args.get("led_count"))
    try:
        program = _scene_pack_program(plan.pack, led_count=led_count)
    except Exception as error:
        raise CommandError("internal", f"preview render failed: {error.__class__.__name__}") from error
    return {"pack_id": plan.pack.pack_id, "led_count": led_count, "program": program}


#: Seconds after the daemon is ready before the transcript caches warm.
USAGE_WARM_DELAY_SECONDS = 8.0


def _usage_history_service(self):
    """The daemon's one ``UsageHistoryService`` (scans off the socket thread)."""
    from . import core_usage_history

    service = getattr(self, "_core_usage_history_service", None)
    if service is None:
        service = core_usage_history.UsageHistoryService(
            lambda provider, days: core_usage_history.scan_provider_records(provider, days=days),
            self._core_publish_event,
            log=self._core_log,
        )
        self._core_usage_history_service = service
    return service


def _usage_history_warm_later(self) -> None:
    """Warm the transcript caches shortly after start so the first
    ``usage_history`` answers inside its budget instead of a cold scan."""

    service = _usage_history_service(self)

    def warm() -> None:
        # Waiting on the service's own stopping flag, not sleeping: a quit
        # inside the delay ends this thread now rather than leaving it to
        # wake during interpreter shutdown.
        if service.stopping.wait(USAGE_WARM_DELAY_SECONDS):
            return
        try:
            service.warm()
        except Exception as error:
            self._core_log(f"core: usage history warm-up failed: {error.__class__.__name__}")

    threading.Thread(target=warm, name="JRBarUsageWarm", daemon=True).start()


@command("usage_history", main_thread=False)
def _cmd_usage_history(self, args):
    from . import core_usage_history

    provider = str(args.get("provider") or "").strip()
    if not provider:
        raise CommandError("not_found", "provider is required")
    range_name = str(args.get("range") or "30d")
    if core_usage_history.range_days(range_name) is None:
        raise CommandError("invalid_range", "range must be 7d, 30d, 90d or 365d")
    with self._core_lock:
        state = self._core_documents.get("state") or {}
    account = None
    source_state = None
    for entry in ((state.get("usage") or {}).get("providers") or []):
        if entry.get("id") == provider:
            account = entry.get("account")
            source_state = entry.get("state")
            break
    # A provider with no configured account still answers when the daemon
    # can say something true about it: transcripts to scan, or a price table
    # to quote (Gemini has no transcripts here but the Usage window still
    # shows its rate card, marked estimated). Anything else is not found.
    if (
        account is None
        and source_state is None
        and provider not in core_usage_history.SCANNED_PROVIDERS
        and provider not in core_usage_history.REFERENCE_MODEL
    ):
        raise CommandError("not_found", f"no usage source for {provider}")
    return _usage_history_service(self).document(provider, range_name, account=account, state=source_state)


@command("usage_graph", main_thread=False)
def _cmd_usage_graph(self, args):
    """The shared-axis usage chart -- the Overview's Usage pane.

    Same local-transcript scan the old Settings graph ran. days,
    metric and providers are per-request overrides: nothing the pane
    picks rewrites the stored settings. Heavy (~9s warm, ~30s cold),
    so it rides the client's socket thread at utility QoS and never
    touches the menu.
    """
    from .t3_compat import T3ReadOnlyPolicy
    from .usage_graph_worker import _drop_to_utility_qos, usage_graph_document

    _drop_to_utility_qos()
    t3_policy = getattr(self, "_t3_read_only_policy", None)
    if type(t3_policy) is not T3ReadOnlyPolicy:
        t3_policy = None
    try:
        return usage_graph_document(
            self.settings,
            days=args.get("days"),
            metric=args.get("metric"),
            provider_ids=args.get("providers"),
            t3_policy=t3_policy,
        )
    except ValueError as error:
        raise CommandError("invalid_args", str(error)) from error


@command("refresh_usage")
def _cmd_refresh_usage(self, args):
    providers = tuple(p for p in (args.get("providers") or []) if isinstance(p, str))
    self._request_provider_usage(force=True, providers=providers or None)
    return {"requested_at": time.time(), "providers": list(providers)}


def _provider_credentials(self):
    from .provider_credential_store import ProviderCredentialStore

    store = getattr(self, "_jrbar_provider_credential_store", None)
    if store is None:
        store = ProviderCredentialStore()
        self._jrbar_provider_credential_store = store
    return store


@command("list_providers")
def _cmd_list_providers(self, args):
    only = args.get("provider")
    instance = args.get("instance")
    if only is not None and (not isinstance(only, str) or not only):
        raise CommandError("invalid_args", "provider must be a nonempty string")
    if instance is not None and (not isinstance(instance, str) or not instance):
        raise CommandError("invalid_args", "instance must be a nonempty string")
    from .provider_management import ProviderManagementError, provider_rows

    try:
        rows = provider_rows(
            credentials=_provider_credentials(self),
            state=getattr(self, "provider_usage_state", None),
            only=only,
            instance=instance,
        )
    except ProviderManagementError as exc:
        raise CommandError(exc.code, str(exc)) from exc
    return {"providers": rows}


@command("set_provider_enabled")
def _cmd_set_provider_enabled(self, args):
    provider = args.get("provider")
    enabled = args.get("enabled")
    instance = args.get("instance") or "default"
    if not isinstance(provider, str) or not provider:
        raise CommandError("invalid_args", "provider is required")
    if type(enabled) is not bool:
        raise CommandError("invalid_args", "enabled must be a boolean")
    if not isinstance(instance, str) or not instance:
        raise CommandError("invalid_args", "instance must be a nonempty string")
    from .provider_management import ProviderManagementError, set_provider_enabled

    try:
        row = set_provider_enabled(
            provider,
            enabled,
            source_instance_id=instance,
            credentials=_provider_credentials(self),
        )
    except ProviderManagementError as exc:
        raise CommandError(exc.code, str(exc)) from exc
    # Either direction lands in the next state push: an enable needs a
    # fresh read, a disable needs the row to stop showing the old quota.
    try:
        self._request_provider_usage(force=True, providers=(provider,))
    except Exception:
        pass
    return {"provider": row}


@command("provider_consent")
def _cmd_provider_consent(self, args):
    action = args.get("action")
    provider = args.get("provider")
    browser = args.get("browser")
    profile = args.get("profile")
    instance = args.get("instance")
    if instance is not None and (not isinstance(instance, str) or not instance):
        raise CommandError("invalid_args", "instance must be a nonempty string")
    from .provider_browser_consent import load_browser_consents
    from .provider_management import (
        ProviderManagementError,
        grant_browser_consent,
        revoke_browser_consent,
    )

    if action == "list":
        rows = [
            {
                "provider_id": consent.provider_id,
                "source_instance_id": consent.source_instance_id,
                "browser": consent.browser,
                "profile": consent.profile,
                "domains": list(consent.domains),
                "fields": list(consent.fields),
                "background_repair": consent.background_repair,
                "granted_at": consent.granted_at,
            }
            for consent in load_browser_consents().store.consents
            if (provider is None or consent.provider_id == provider)
            and (instance is None or consent.source_instance_id == instance)
        ]
        return {"consents": rows}
    for name, value in (("provider", provider), ("browser", browser), ("profile", profile)):
        if not isinstance(value, str) or not value:
            raise CommandError("invalid_args", f"{name} is required")
    try:
        if action == "grant":
            consent = grant_browser_consent(
                provider,
                browser,
                profile,
                background_repair=bool(args.get("background_repair")),
                source_instance_id=instance or "default",
            )
        elif action == "revoke":
            consent = revoke_browser_consent(
                provider,
                browser,
                profile,
                source_instance_id=instance or "default",
                credentials=_provider_credentials(self),
            )
            try:
                self._request_provider_usage(force=True, providers=(provider,))
            except Exception:
                pass
        else:
            raise CommandError("invalid_args", "action must be list, grant, or revoke")
    except ProviderManagementError as exc:
        raise CommandError(exc.code, str(exc)) from exc
    return {"consent": consent}


@command("provider_add_instance")
def _cmd_provider_add_instance(self, args):
    provider = args.get("provider")
    instance = args.get("instance")
    label = args.get("label")
    if not isinstance(provider, str) or not provider:
        raise CommandError("invalid_args", "provider is required")
    if not isinstance(instance, str) or not instance:
        raise CommandError("invalid_args", "instance is required")
    if label is not None and not isinstance(label, str):
        raise CommandError("invalid_args", "label must be a string")
    from .provider_management import (
        ProviderManagementError,
        add_provider_instance,
    )

    try:
        row = add_provider_instance(
            provider,
            instance,
            label=label,
            credentials=_provider_credentials(self),
        )
    except ProviderManagementError as exc:
        raise CommandError(exc.code, str(exc)) from exc
    try:
        self._request_provider_usage(force=True, providers=(provider,))
    except Exception:
        pass
    return {"provider": row}


@command("provider_action")
def _cmd_provider_action(self, args):
    provider = args.get("provider")
    instance = args.get("instance") or "default"
    action = args.get("action")
    if not isinstance(provider, str) or not provider:
        raise CommandError("invalid_args", "provider is required")
    if not isinstance(instance, str) or not instance:
        raise CommandError("invalid_args", "instance must be a nonempty string")
    if action is not None and action != "resign_in":
        raise CommandError("invalid_args", "action must be resign_in")
    from .provider_browser_access import perform_provider_usage_action
    from .provider_usage_platform import provider_descriptor

    try:
        provider_descriptor(provider)
    except ValueError as exc:
        raise CommandError("unknown_provider", f"unknown provider {provider!r}") from exc
    if action == "resign_in":
        # "Re-sign in" / "Update provider" from the Usage Center: re-pull
        # whatever sign-in the provider's own tooling holds even when no
        # staged action label is on the card, then the same feedback +
        # outcome-watch + forced-refresh tail the staged flow uses.
        from .provider_reconnect import reconnect_provider

        state = getattr(self, "provider_usage_state", None)
        snapshot = next(
            (
                item
                for item in getattr(state, "snapshots", ()) or ()
                if getattr(item, "identity", None) == (provider, instance)
            ),
            None,
        )
        result = reconnect_provider(
            provider,
            instance,
            reason_code=getattr(snapshot, "reason_code", None),
        )
        message = result.message
        feedback = getattr(self, "_show_provider_usage_feedback", None)
        if callable(feedback):
            try:
                feedback(message)
            except Exception:
                pass
        try:
            self._jrbar_reconnect_watch = (provider, instance, time.time())
        except Exception:
            pass
        try:
            scope = (
                (provider,)
                if instance == "default"
                else ((provider, instance),)
            )
            self._request_provider_usage(force=True, providers=scope)
        except Exception:
            pass
        return {
            "provider": provider,
            "instance": instance,
            "message": message,
            "sign_in_url": result.sign_in_url,
        }
    message = perform_provider_usage_action(self, provider, instance)
    if message is None:
        raise CommandError(
            "unsupported",
            "no staged action matches this provider's current state",
        )
    return {"provider": provider, "instance": instance, "message": message}


def _hooks_command(self, args, *, install: bool):
    from .install import install_provider_hooks, uninstall_provider_hooks

    providers = [p for p in (args.get("providers") or []) if isinstance(p, str) and p]
    if not providers:
        raise CommandError("invalid_args", "providers[] is required")
    try:
        detected = self._core_detected_agents()
    except Exception:
        detected = {}
    results: dict[str, Any] = {}
    changed = False
    for provider in providers:
        # A provider whose CLI was never found cannot be hooked; the reply
        # carries that per provider, not as a failed command.
        if install and detected.get(provider) is False:
            results[provider] = {
                "ok": False,
                "detected": False,
                "error": "no CLI found on PATH",
            }
            continue
        try:
            result = install_provider_hooks(provider) if install else uninstall_provider_hooks(provider)
            changed = changed or bool(result.changed)
            results[provider] = {
                "ok": True,
                "detected": detected.get(provider),
                **result.to_dict(),
            }
        except Exception as exc:
            results[provider] = {
                "ok": False,
                "detected": detected.get(provider),
                "error": str(exc)[:500],
            }
    self.performSelectorOnMainThread_withObject_waitUntilDone_(
        "hooksUpdated:",
        {"ok": True, "changed": changed, "provider": ",".join(providers), "install": install},
        False,
    )
    return {"providers": providers, "results": results}


@command("install_hooks", main_thread=False)
def _cmd_install_hooks(self, args):
    return _hooks_command(self, args, install=True)


@command("uninstall_hooks", main_thread=False)
def _cmd_uninstall_hooks(self, args):
    return _hooks_command(self, args, install=False)


@command("set_closed_lid_policy")
def _cmd_set_closed_lid_policy(self, args):
    legacy = self._core_legacy()
    policy = str(args.get("policy") or "")
    if policy not in legacy.CLOSED_LID_AWAKE_CHOICES:
        raise CommandError("invalid_args", f"unknown policy {policy!r}")
    self.set_closed_lid_awake_policy(policy)
    return {"policy": self.settings.closed_lid_awake_policy}


@command("quiet")
def _cmd_quiet(self, args):
    from .dnd_policy import DndMode

    raw = str(args.get("mode") or "dnd").lower()
    mode = {
        "dnd": DndMode.PAUSE,
        "pause": DndMode.PAUSE,
        "dim": DndMode.DIM,
        "mute": DndMode.MUTE,
        "dark": DndMode.DARK,
        "asks_only": DndMode.ASKS_ONLY,
    }.get(raw)
    if mode is None:
        raise CommandError("invalid_args", f"unknown quiet mode {raw!r}")
    try:
        seconds = float(args.get("seconds", 1800))
    except (TypeError, ValueError) as error:
        raise CommandError("invalid_args", "seconds must be a number") from error
    if seconds <= 0:
        self.endDndOverride_(None)
        self._core_publish_state()
        return {"until": None}
    if not self._set_dnd_for_duration(mode, seconds):
        raise CommandError("refused", "DND override was not applied")
    self._core_publish_state()
    until = getattr(getattr(self.settings, "dnd_override", None), "until_epoch", None)
    return {"until": until if until is not None else time.time() + max(60.0, seconds), "mode": mode.value}


@command("hold_awake")
def _cmd_hold_awake(self, args):
    """The person's keep-awake lease (jrbar.core_power.hold_awake)."""
    from . import core_power

    return core_power.hold_awake(self, args)


@command("release_awake")
def _cmd_release_awake(self, args):
    from . import core_power

    return core_power.release_awake(self, args)


@command("session_energy", main_thread=False)
def _cmd_session_energy(self, args):
    """Which agent session is keeping the CPU busy (jrbar.session_energy)."""
    from . import core_power

    return core_power.session_energy(self, args)


@command("presence")
def _cmd_presence(self, args):
    """The app's report of what it senses: a live microphone, camera or
    screen share, a locked screen, its own Focus reading, a meeting's end
    (jrbar.presence)."""
    from . import core_power

    return core_power.set_presence(self, args)


# --- light controls that lived only in the legacy window (jrbar.core_lights) ---


@command("list_cues")
def _cmd_list_cues(self, args):
    from . import core_lights

    return core_lights.list_cues(self, args)


@command("set_cue")
def _cmd_set_cue(self, args):
    from . import core_lights

    return core_lights.set_cue(self, args)


@command("burn_init", main_thread=False)
def _cmd_burn_init(self, args):
    from . import core_lights

    return core_lights.burn_init(self, args)


@command("calibration_profile")
def _cmd_calibration_profile(self, args):
    from . import core_lights

    return core_lights.calibration_profile(self, args)


@command("list_focuses", main_thread=False)
def _cmd_list_focuses(self, args):
    from . import core_lights

    return core_lights.list_focuses(self, args)


@command("auto_dim_learning", main_thread=False)
def _cmd_auto_dim_learning(self, args):
    from . import core_lights

    return core_lights.auto_dim_learning(self, args)


@command("check_palette", main_thread=False)
def _cmd_check_palette(self, args):
    from . import core_lights

    return core_lights.check_palette(self, args)


@command("preview_fleet", main_thread=False)
def _cmd_preview_fleet(self, args):
    from . import core_lights

    return core_lights.preview_fleet(self, args)


@command("list_light_log")
def _cmd_list_light_log(self, args):
    from . import core_lights

    return core_lights.list_light_log(self, args)


@command("resolve_effect", main_thread=False)
def _cmd_resolve_effect(self, args):
    from . import core_lights

    return core_lights.resolve_effect(self, args)


@command("list_history", main_thread=False)
def _cmd_list_history(self, args):
    since = args.get("since")
    try:
        limit = int(args.get("limit") or 500)
    except (TypeError, ValueError):
        limit = 500
    # The ledger lives on the main thread (lazy restore mutates controller
    # state), so it is fetched there; the frozen object then reads off-main.
    on_main = getattr(self, "_core_on_main", None) or (lambda fn: fn())
    ledger = on_main(lambda: self.ensure_activity_ledger())
    rows = history_rows(ledger, since=float(since) if isinstance(since, (int, float)) else None, limit=limit)
    # The power log's rows ("let go: Mac too hot", "put the Mac to sleep")
    # sit beside the sessions' in the one History list.
    from . import core_power

    rows = core_power.merge_history(
        self,
        rows,
        since=float(since) if isinstance(since, (int, float)) else None,
        limit=limit,
        last_seen=float(ledger.last_seen_epoch or 0.0),
    )
    return {"rows": rows, "total": len(ledger.entries), "last_seen": ledger.last_seen_epoch}


@command("list_commands")
def _cmd_list_commands(self, args):
    """The durable command journal: what was asked, and how it settled.

    ``commands`` are the recent records (newest first, bounded); the
    ``outcome_unknown`` ids are the ones a restart must not pretend
    finished — an ``accepted`` record with no settlement is evidence of
    a command whose effect was never confirmed.
    """
    journal = _command_journal(self)
    report = journal.reconcile()
    records = sorted(
        (r for r in journal._records.values() if r.status != "accepted"),
        key=lambda r: r.settled_at or 0, reverse=True,
    )[:50]
    return {
        "outcome_unknown": report["outcome_unknown"],
        "counts": {
            "completed": report["completed"],
            "failed": report["failed"],
            "pending": len(report["outcome_unknown"]),
        },
        "commands": [r.to_payload() for r in records],
    }


@command("list_roster")
def _cmd_list_roster(self, args):
    """Every session the collector retains, panel visibility aside.

    ``state.sessions`` is a view; this is the record set under it —
    workers, the quiet-stale, the acknowledged, the aged-out — each row
    the same ``session_document`` shape the panel reads, plus the
    separated axes and the visibility verdict the panel would give.
    """
    from .agent_roster import ROSTER_SCOPES

    scope = str(args.get("scope") or "all")
    if scope not in ROSTER_SCOPES:
        raise CommandError(
            "invalid_value", f"scope must be one of {', '.join(ROSTER_SCOPES)}"
        )
    provider = args.get("provider")
    parent = args.get("parent")
    since = args.get("since")
    try:
        limit = int(args.get("limit") or 0) or None
    except (TypeError, ValueError):
        limit = None
    document = _roster_document(
        self,
        scope=scope,
        provider=str(provider) if provider else None,
        parent=str(parent) if parent else None,
        since=float(since) if isinstance(since, (int, float)) else None,
        limit=limit if limit is not None else 500,
    )
    document["generation"] = self._core_state_generation
    return document


def _roster_document(
    self,
    *,
    scope: str,
    provider: str | None,
    parent: str | None,
    since: float | None,
    limit: int,
):
    """The projection both ``list_roster`` and ``audit_export`` share."""
    from .agent_roster import build_roster_document, roster_rows
    from .completion_visibility import acknowledged_epoch_by_session
    from .core_projection import project_session_rows

    snapshot = getattr(self, "last_snapshot", None)
    statuses = (
        [*snapshot.statuses, *getattr(snapshot, "stale_statuses", ())]
        if snapshot is not None
        else []
    )
    ask_statuses = self._core_ask_statuses()
    extras: dict[str, SessionExtras] = {}
    extras_cache = getattr(self, "_core_extras", None)
    if statuses and isinstance(extras_cache, dict):
        now_mono = time.monotonic()
        ordered = [status.agent_id for status in statuses if not status.stale]
        ordered += [status.agent_id for status in statuses if status.stale]
        planned = set(
            plan_extra_lookups(
                ordered,
                extras_cache,
                now=now_mono,
                ttl=EXTRAS_TTL_SECONDS,
                budget=MAX_EXTRA_LOOKUPS_PER_BUILD,
            )
        )
        for status in statuses:
            cached = extras_cache.get(status.agent_id)
            if status.agent_id in planned:
                extras[status.agent_id] = self._core_extras_for(status)
            elif cached is not None:
                extras[status.agent_id] = cached[1]
    projected, ask_ids = project_session_rows(
        snapshot,
        ask_statuses=ask_statuses,
        operator_state=getattr(self, "current_operator_state", None),
        extras_by_id=extras,
        snoozed_until_by_id=self._core_snoozed_untils(statuses),
        answer_contracts=getattr(self, "_answer_contracts_by_source", None),
        has_answer_handler=getattr(
            getattr(self, "answer_handler_registry", None), "has_handler", None
        ),
        acknowledged_keys=self._core_acknowledged_keys(),
    )
    rows = roster_rows(
        projected,
        ask_ids=ask_ids,
        acknowledged_at_by_id=acknowledged_epoch_by_session(self._core_acknowledged_keys()),
        now=time.time(),
    )
    return build_roster_document(
        rows,
        now=time.time(),
        scope=scope,
        provider=provider,
        parent=parent,
        since=since,
        limit=limit,
    )


@command("audit_export")
def _cmd_audit_export(self, args):
    """The redacted audit bundle: roster + activity + the named gaps.

    ``scope``/``provider``/``since`` narrow the session rows the same way
    ``list_roster`` does; ``format`` selects ``json`` (the document) or
    ``markdown`` (the rendered report). The export is the projections the
    surfaces already show — the audit cannot claim more than the app
    knows (spec S7.4/T36).
    """
    from .agent_roster import ROSTER_MAX_LIMIT, ROSTER_SCOPES
    from .audit_export import audit_export_document, audit_export_markdown
    from .core_projection import history_rows
    from .core_usage_history import SCANNED_PROVIDERS

    scope = str(args.get("scope") or "all")
    if scope not in ROSTER_SCOPES:
        raise CommandError("invalid_value", f"unknown roster scope: {scope}")
    since = args.get("since")
    since = float(since) if isinstance(since, (int, float)) else None
    roster = _roster_document(
        self,
        scope=scope,
        provider=str(args["provider"]) if args.get("provider") else None,
        parent=str(args["parent"]) if args.get("parent") else None,
        since=since,
        limit=ROSTER_MAX_LIMIT,
    )
    ledger = self.ensure_activity_ledger()
    rows = history_rows(ledger, since=since, limit=2000)

    gaps: list[str] = []
    if getattr(self, "last_snapshot", None) is None:
        gaps.append("No collector snapshot yet — session coverage is empty, not quiet.")
    retained = int((getattr(ledger, "entries", ()) and len(ledger.entries)) or 0)
    if retained > len(rows):
        gaps.append(
            f"Activity ledger retains {retained} entries; this export carries {len(rows)}."
        )
    pricing = None
    try:
        # Zero budget: the export carries whatever the scan cache already
        # holds and names it pending otherwise — it never blocks a save
        # on a cold transcript scan.
        service = _usage_history_service(self)
        per_provider: dict[str, Any] = {}
        for provider in SCANNED_PROVIDERS:
            doc = service.document(provider, "30d", budget=0)
            per_provider[provider] = {
                key: doc.get(key)
                for key in ("records", "estimated_records", "unpriced_records",
                            "unpriced_models", "pending", "stale")
                if key in doc
            }
        pricing = {"range": "30d", "providers": per_provider}
        if any(row.get("pending") for row in per_provider.values()):
            gaps.append("A usage scan is in progress — pricing coverage is partial.")
    except Exception:
        gaps.append("Usage history unavailable — pricing coverage could not be read.")

    document = audit_export_document(
        roster=roster,
        history_rows=rows,
        pricing=pricing,
        gaps=gaps,
        scope=scope,
        since=since,
        generated_at=time.time(),
        core_version=CORE_VERSION,
        home=str(Path.home()),
    )
    fmt = str(args.get("format") or "json")
    if fmt == "markdown":
        payload: dict[str, Any] = {"format": "markdown", "document": document,
                                   "text": audit_export_markdown(document)}
    else:
        payload = {"format": "json", "document": document}

    # ``path`` writes the bundle the same way ``export_effect_pack`` does:
    # a user-picked destination, scratch-write, identity-checked publish.
    raw_path = args.get("path")
    if isinstance(raw_path, str) and raw_path.strip():
        from .private_export import write_private_export

        path = Path(raw_path).expanduser()
        encoded = (
            payload["text"].encode("utf-8")
            if fmt == "markdown"
            else (json.dumps(document, indent=1, sort_keys=True) + "\n").encode("utf-8")
        )
        try:
            path.parent.mkdir(parents=True, exist_ok=True)
            written = write_private_export(path, encoded, max_bytes=8 * 1024 * 1024)
        except (OSError, ValueError) as error:
            raise CommandError(
                "export_failed", f"could not write {path}: {error.__class__.__name__}"
            ) from error
        payload["written"] = {"path": str(written), "bytes": len(encoded)}
    return payload


@command("session_timeline", main_thread=False)
def _cmd_session_timeline(self, args):
    """A session's transcript as bounded, paginated timeline items.

    Off the main run loop: transcript discovery and parsing are file I/O
    that used to stall every timer and refresh behind a page turn. The
    snapshot/ledger reads below are immutable swaps; the transcript side
    is cached in session_timeline.py.

    ``id`` is a roster row id — the status's provider/session_id/cwd
    resolve the transcript. An ended session whose status has aged out
    is still inspectable via ``session`` + ``provider`` (+ optional
    ``cwd``). ``before`` is the seq cursor for older pages. Items carry
    occurrence time only; per-row ingestion time was never recorded
    (spec S7.2 — the distinction is surfaced, not fabricated).
    """
    from .session_timeline import TIMELINE_DEFAULT_LIMIT, session_timeline

    agent_id = args.get("id")
    provider = args.get("provider")
    session_id = args.get("session")
    cwd = args.get("cwd")
    if isinstance(agent_id, str) and agent_id:
        status = next(
            (
                status
                for status in [
                    *getattr(getattr(self, "last_snapshot", None), "statuses", ()),
                    *getattr(
                        getattr(self, "last_snapshot", None), "stale_statuses", ()
                    ),
                ]
                if getattr(status, "agent_id", None) == agent_id
            ),
            None,
        )
        if status is None:
            # A row that aged out between roster load and click still
            # resolves when the caller carried its provider/session/cwd —
            # only a bare unknown id is a real not_found.
            if not (isinstance(provider, str) and provider and session_id):
                raise CommandError("not_found", f"unknown session id: {agent_id}")
        else:
            provider = provider or getattr(status, "provider", None)
            session_id = session_id or getattr(status, "session_id", None)
            cwd = cwd or getattr(status, "cwd", None)
    if not isinstance(provider, str) or not provider:
        raise CommandError("invalid_value", "provider is required")
    try:
        limit = int(args.get("limit") or 0)
    except (TypeError, ValueError):
        limit = 0
    before = args.get("before")
    document = session_timeline(
        provider,
        str(session_id) if session_id else None,
        cwd=str(cwd) if cwd else None,
        limit=limit or TIMELINE_DEFAULT_LIMIT,
        before=int(before) if isinstance(before, (int, float)) else None,
    )
    if isinstance(agent_id, str) and agent_id:
        document["session"] = agent_id
    return document


@command("compare_sessions", main_thread=False)
def _cmd_compare_sessions(self, args):
    """Two runs side by side on retained facts only (S7.4).

    Each side carries the projected roster row's axes, the transcript
    aggregate (messages, tools, failures/retries, span), and the
    ledger's interruption counts for that agent id. ``warnings`` always
    names ``not_a_controlled_benchmark``; ``gaps`` names what is not
    tracked (artifacts, model). Refuses ``not_found`` for an unknown id.

    Runs on the socket thread like ``session_timeline``: the roster and
    ledger are mutable controller state, so they hop to main for one
    snapshot; the transcript walk and parse (``compare_runs``) stay off.
    """
    from .agent_roster import ROSTER_MAX_LIMIT
    from .run_compare import compare_runs

    id_a, id_b = args.get("a"), args.get("b")
    if not (isinstance(id_a, str) and id_a and isinstance(id_b, str) and id_b):
        raise CommandError("invalid_value", "a and b session ids are required")
    if id_a == id_b:
        raise CommandError("invalid_value", "choose two different sessions")

    snapshot = getattr(self, "last_snapshot", None)
    statuses = [
        *getattr(snapshot, "statuses", ()),
        *getattr(snapshot, "stale_statuses", ()),
    ]
    by_id = {getattr(s, "agent_id", None): s for s in statuses}
    status_a, status_b = by_id.get(id_a), by_id.get(id_b)
    if status_a is None:
        raise CommandError("not_found", f"unknown session id: {id_a}")
    if status_b is None:
        raise CommandError("not_found", f"unknown session id: {id_b}")

    def _gather():
        roster = _roster_document(
            self, scope="all", provider=None, parent=None,
            since=None, limit=ROSTER_MAX_LIMIT,
        )
        rows = {row.get("id"): row for row in roster.get("sessions", ())}
        ledger = self.ensure_activity_ledger()
        return rows.get(id_a), rows.get(id_b), getattr(ledger, "entries", ())

    on_main = getattr(self, "_core_on_main", None) or (lambda fn: fn())
    row_a, row_b, ledger_entries = on_main(_gather)
    return compare_runs(
        row_a=row_a, row_b=row_b,
        status_a=status_a, status_b=status_b,
        ledger_entries=ledger_entries,
        id_a=id_a, id_b=id_b,
    )


@command("import_radar_report", main_thread=False)
def _cmd_import_radar_report(self, args):
    """Store a bounded, version-checked Radar report (S7.5/T38).

    Import is data-only: the file is parsed, capped, normalized and
    stored — never executed. Every imported edge is ``evidence:
    "static"``; the inspector labels it and nothing consumes it as a
    live call.
    """
    from .radar_import import RadarImportError, import_radar_report

    raw_path = args.get("path")
    if not isinstance(raw_path, str) or not raw_path.strip():
        raise CommandError("invalid_value", "path is required")
    try:
        summary = import_radar_report(Path(raw_path))
    except RadarImportError as error:
        raise CommandError(error.code, str(error)) from error
    return {"imported": summary}


@command("list_radar_reports", main_thread=False)
def _cmd_list_radar_reports(self, args):
    """The stored report summaries (analyzer, scan, repo, counts)."""
    from .radar_import import list_radar_reports

    return {"reports": list_radar_reports()}


@command("radar_report", main_thread=False)
def _cmd_radar_report(self, args):
    """One stored report's normalized graph for the inspector lens."""
    from .radar_import import load_radar_report

    report_id = args.get("id")
    if not isinstance(report_id, str) or not report_id:
        raise CommandError("invalid_value", "id is required")
    report = load_radar_report(report_id)
    if report is None:
        raise CommandError("not_found", f"unknown report id: {report_id}")
    return {"report": report}


@command("replay_events")
def _cmd_replay_events(self, args):
    """The resumable event stream's suffix after a cursor.

    ``hello.cursor`` anchors a fresh client; each event frame carries its
    own ``cursor``. A foreign stream or evicted cursor is answered
    ``resync_required`` with the reason and the live tail — the caller
    resubscribes rather than trusting an empty page."""
    server = getattr(self, "_core", None)
    replay = getattr(server, "replay_events", None)
    if not callable(replay):
        raise CommandError("unsupported", "this core cannot replay events")
    after = args.get("after")
    try:
        limit = int(args.get("limit") or 500)
    except (TypeError, ValueError):
        limit = 500
    document = replay(
        after=str(after) if after else None,
        limit=limit,
    )
    document["generation"] = self._core_state_generation
    return document


@command("mark_history_seen")
def _cmd_mark_history_seen(self, args):
    """The user just looked at History: advance the ledger's ``last_seen``.

    Same stamp the menu writes when the dropdown opens -- ``unseen`` rows
    and the "while you were away" banner measure from the last look, not
    from a restart.
    """
    self.mark_activity_seen_now()
    return {"last_seen": self.ensure_activity_ledger().last_seen_epoch}


@command("serve_token", main_thread=False)
def _cmd_serve_token(self, args):
    """The loopback status endpoint's bearer token, for the reveal row.

    The token travels on the local Unix socket only -- never inside the
    HTTP document it guards. ``None`` when the daemon was not launched
    with one; the app's copy action reports that honestly.
    """
    from .cli import SERVE_ACCESS_TOKEN_ENV

    token = os.environ.get(SERVE_ACCESS_TOKEN_ENV) or None
    return {
        "token": token,
        "enabled": bool(getattr(self.settings, "serve_enabled", False)),
        "running": getattr(self, "_core_serve_server", None) is not None,
    }


@command("doctor", main_thread=False)
def _cmd_doctor(self, args):
    # Diagnostics shell out (codesign, probes) and scan pending-hook
    # state -- none of it belongs on the run loop that drives the daemon.
    return self._core_doctor_document()


@command("new_session", main_thread=False)
def _cmd_new_session(self, args):
    """Start an agent in a directory, in the owner's own terminal -- a new
    Ghostty tab there, or a new Terminal.app / iTerm2 window. Explicit only:
    the Overview's "New session here"; nothing calls it on its own, and the
    agent's first prompt is still the owner's to type (answer_surfaces.py)."""
    from .answer_surfaces import start_session_in_terminal

    return start_session_in_terminal(
        args.get("provider"), args.get("cwd"), terminal=args.get("terminal")
    )


@command("resume_session", main_thread=False)
def _cmd_resume_session(self, args):
    """History's Resume, by agent id: a session the list still shows opens
    exactly as ``open_session`` would (raised while it runs, resumed once it
    has ended); one the list no longer shows is found in the process
    registry and resumed in the terminal it ran in, or raised when it turns
    out to be running still (answer_surfaces.py). Explicit only."""
    from .answer_surfaces import resume_ended_session

    session = args.get("session")
    on_main = getattr(self, "_core_on_main", None) or (lambda fn: fn())

    def listed():
        try:
            return _find_status(self, session)
        except CommandError:
            return None

    if on_main(listed) is not None:
        # open_session hops only its main-thread pieces; its raise stays here.
        return _cmd_open_session(self, {"session": session})
    return resume_ended_session(session, terminal=args.get("terminal"))


@command("session_in_front", main_thread=False)
def _cmd_session_in_front(self, args):
    """Whether the owner is looking at that session's own tab, pane or
    Ghostty terminal right now, for "Quiet while you watch": ``in_front``
    true on proof, false when something else is in front, null when it
    cannot be told. Never raises, types or asks for a permission
    (answer_surfaces.py)."""
    from .answer_surfaces import session_in_front

    status = _find_status(self, args.get("session"))
    on_main = getattr(self, "_core_on_main", None) or (lambda fn: fn())
    return session_in_front(self, status, on_main=on_main)


@command("hooks_doctor", main_thread=False)
def _cmd_hooks_doctor(self, args):
    """``jrbar hooks doctor`` as data, for Settings > Agents: per provider,
    whether its hooks are installed and in which shape, whether the decide
    lane is, when its last event arrived and how many are queued. Content
    free: paths, shapes, counts and times, never a payload. Repair is
    ``install_hooks``."""
    from .hook_doctor import hook_doctor_report

    return hook_doctor_report()


@command("open_legacy_window")
def _cmd_open_legacy_window(self, args):
    name = str(args.get("name") or "")
    selector = LEGACY_WINDOWS.get(name)
    if selector is None:
        raise CommandError("not_found", f"no legacy window named {name!r}")
    method = getattr(self, selector, None)
    if not callable(method):
        raise CommandError("unsupported", f"{name} is unavailable in this build")
    if selector.endswith("_"):
        method(None)
    else:
        method()
    from .window_presentation import activate_app

    try:
        activate_app()
    except Exception:
        pass
    return {"window": name}


@command("quit")
def _cmd_quit(self, args):
    self.performSelector_withObject_afterDelay_("coreQuit:", None, 0.15)
    return {"bye": True}


@command("ping")
def _cmd_ping(self, args):
    return {"pong": True, "now": time.time()}


# --- the Creator Micro 2 deck (app/README.md, "The Creator Micro 2 deck") ----


def deck_probe() -> list[dict[str, Any]]:
    """One read-only HID enumeration: the pads this Mac can see right now
    (``serial_number``, ``bus_type``, ``product_id``). Tests replace it."""
    from .creator_micro_hidapi import HidApiTransport

    rows = []
    for row in HidApiTransport().enumerate():
        rows.append(
            {
                "serial_number": row.get("serial_number"),
                "bus_type": row.get("bus_type"),
                "product_id": row.get("product_id"),
            }
        )
    return rows


def _deck_index(args: dict[str, Any], *, limit: int = core_deck.CONTROL_COUNT) -> int:
    value = args.get("index")
    if isinstance(value, bool) or not isinstance(value, int) or not 0 <= value < limit:
        raise CommandError("invalid_args", f"index must be 0..{limit - 1}")
    return value


def _deck_plan_args(args: dict[str, Any]) -> tuple[int, int, bool]:
    profile = args.get("profile", 0)
    layer = args.get("layer", 0)
    include_auxiliary = args.get("include_auxiliary", False)
    if type(profile) is not int:
        raise CommandError("invalid_plan", "invalid selected profile")
    if type(layer) is not int:
        raise CommandError("invalid_plan", "invalid selected layer")
    if type(include_auxiliary) is not bool:
        raise CommandError("invalid_plan", "include_auxiliary must be a bool")
    return profile, layer, include_auxiliary


def _deck_layers_arg(args: dict[str, Any]) -> tuple[tuple[int, ...], tuple[tuple[int, str], ...]] | None:
    """Optional ``layers`` rows ({"layer": int, "name": str}) for a
    multi-layer apply: every listed layer is claimed and named."""
    rows = args.get("layers")
    if rows is None:
        return None
    if type(rows) is not list or not rows or len(rows) > 24:
        raise CommandError("invalid_plan", "layers must be a list of {layer, name} rows")
    indexes = []
    names = []
    for row in rows:
        if type(row) is not dict or set(row) != {"layer", "name"}:
            raise CommandError("invalid_plan", "layers rows must be {layer, name}")
        layer, name = row["layer"], row["name"]
        if type(layer) is not int or layer < 0:
            raise CommandError("invalid_plan", "invalid selected layer")
        if type(name) is not str or not name.strip() or len(name) > 64 or not name.isprintable():
            raise CommandError("invalid_plan", "invalid layer name")
        indexes.append(layer)
        names.append((layer, name))
    return tuple(indexes), tuple(names)


def _deck_plan(preview, profile: int, layer: int, include_auxiliary: bool,
               layer_indexes=None, layer_names=None):
    """Re-plan the inspected keymap for another layer without touching the
    device (``plan_keymap`` is pure; ``setup.apply`` re-verifies it)."""
    from .creator_micro_keymap import plan_keymap

    plan = preview.plan
    try:
        return plan_keymap(
            plan.original_json,
            {"profile_index": plan.observed_profile, "layer_index": plan.observed_layer + 1},
            profile_index=profile,
            layer_index=layer,
            layer_indexes=layer_indexes,
            layer_names=layer_names,
            include_auxiliary=include_auxiliary,
        )
    except ValueError as error:
        raise CommandError("invalid_plan", str(error)) from error


@command("deck_press", main_thread=False)
def _cmd_deck_press(self, args):
    index = _deck_index(args)
    if getattr(self, "_deck_input_check_active", False):
        raise CommandError("input_check", core_deck.INPUT_CHECK_MESSAGE)
    return self._core_deck_press(index)


@command("deck_pin")
def _cmd_deck_pin(self, args):
    from .deck_control_center import revoke_deck_context
    from .deck_session_board import SLOTS_PER_BANK

    index = _deck_index(args, limit=SLOTS_PER_BANK)
    board = self._core_deck_board()
    _revision, identity = board.resolve_slot(index)
    if identity is None:
        raise CommandError("not_found", core_deck.NO_SESSION_MESSAGE)
    revoke_deck_context(self)
    board.toggle_pin(index)
    self._core_deck_store_board()
    pinned = identity in set(board.serialize()["pinned"])
    self._core_deck_publish()
    return {"index": index, "identity": identity, "pinned": pinned}


@command("deck_bank")
def _cmd_deck_bank(self, args):
    from .deck_control_center import change_deck_bank

    delta = args.get("delta", 1)
    if isinstance(delta, bool) or type(delta) is not int:
        raise CommandError("invalid_args", "delta must be an integer")
    board = self._core_deck_board()
    count = board.snapshot().bank_count
    steps = abs(delta) % max(1, count)
    for _ in range(steps):
        change_deck_bank(self, 1 if delta > 0 else -1)
    snapshot = board.snapshot()
    self._core_publish_state()
    return {"index": snapshot.bank, "count": snapshot.bank_count}


@command("deck_scope")
def _cmd_deck_scope(self, args):
    from .deck_controller import cycle_deck_scope

    delta = args.get("delta", 1)
    if isinstance(delta, bool) or type(delta) is not int:
        raise CommandError("invalid_args", "delta must be an integer")
    controls = getattr(self, "_deck_control_settings", None)
    count = 1 + len(controls.all_scopes()) if controls is not None else 1
    for _ in range(abs(delta) % count):
        cycle_deck_scope(self, 1 if delta > 0 else -1)
    snapshot = self._core_deck_board().snapshot()
    self._core_publish_state()
    return {"scope": snapshot.scope, "scopes": list(controls.all_scopes()) if controls is not None else []}


@command("deck_rail")
def _cmd_deck_rail(self, args):
    board = self._core_deck_board()
    try:
        board.set_rail_edge(args.get("edge"))
    except ValueError as error:
        raise CommandError("invalid_args", "edge must be off, left, right, top or bottom") from error
    self._core_deck_store_board()
    self._core_publish_state()
    return {"edge": board.snapshot().rail_edge}


@command("deck_clear_absent")
def _cmd_deck_clear_absent(self, args):
    from .deck_control_center import revoke_deck_context

    board = self._core_deck_board()
    before = len(board.serialize()["slots"])
    revoke_deck_context(self)
    board.clear_inactive()
    self._core_deck_store_board()
    after = board.snapshot()
    self._core_deck_publish()
    self._core_log(f"deck: cleared {before - len(board.serialize()['slots'])} absent slots")
    return {
        "removed": before - len(board.serialize()["slots"]),
        "banks": {"index": after.bank, "count": after.bank_count},
    }


@command("deck_plan_keymap", main_thread=False)
def _cmd_deck_plan_keymap(self, args):
    profile, layer, include_auxiliary = _deck_plan_args(args)
    layers = _deck_layers_arg(args)
    preview = self._core_deck_inspect()
    return core_deck.plan_document(
        _deck_plan(preview, profile, layer, include_auxiliary,
                   layer_indexes=None if layers is None else layers[0],
                   layer_names=None if layers is None else layers[1]))


@command("deck_apply_keymap", main_thread=False)
def _cmd_deck_apply_keymap(self, args):
    from .creator_micro_setup_controller import SetupPreview, begin_creator_micro_apply

    profile, layer, include_auxiliary = _deck_plan_args(args)
    layers = _deck_layers_arg(args)
    preview = self._core_deck_inspect()
    plan = _deck_plan(preview, profile, layer, include_auxiliary,
                      layer_indexes=None if layers is None else layers[0],
                      layer_names=None if layers is None else layers[1])
    self._deck_control_labels = plan.control_labels
    result = self._core_deck_run_setup(
        lambda: begin_creator_micro_apply(self, SetupPreview(preview.approved_serial, plan))
    )
    if result.code not in ("keymap_verified", "already_configured"):
        raise CommandError(result.code, core_deck.receipt_message(result.code))
    document = {"code": result.code, "message": core_deck.receipt_message(result.code), "changes": list(plan.changes)}
    document.update(self._core_deck_keymap_document(preview.approved_serial))
    return document


@command("deck_restore_keymap", main_thread=False)
def _cmd_deck_restore_keymap(self, args):
    from .creator_micro_setup_controller import begin_creator_micro_restore

    # The confirmation is the app's; the daemon never runs the alert.
    result = self._core_deck_run_setup(lambda: begin_creator_micro_restore(self, confirm=lambda: True))
    if result.code not in ("keymap_restored", "already_restored"):
        raise CommandError(result.code, core_deck.receipt_message(result.code))
    document = {"code": result.code, "message": core_deck.receipt_message(result.code)}
    document.update(self._core_deck_keymap_document(self._core_deck_integration()[1]))
    return document


@command("deck_approve_device", main_thread=False)
def _cmd_deck_approve_device(self, args):
    from .creator_micro_settings import save_creator_micro_choice_async

    # Approval is of a pad that is here: look once more (it may have just
    # come on), then refuse rather than enable a remembered serial blindly.
    self._core_deck_probe_now(wait=True)
    if not self._core_deck_probe_rows():
        raise CommandError("no_device", core_deck.NO_DEVICE_MESSAGE)
    self._core_deck_settings_done.clear()
    save_creator_micro_choice_async(self, True)
    if not self._core_deck_settings_done.wait(DECK_APPROVE_TIMEOUT_SECONDS):
        raise CommandError("busy", "Creator Micro 2 approval did not finish in time.")
    result = self._core_deck_settings_result
    if result is None or not result.saved:
        reason = getattr(result, "reason", "settings_save_failed")
        message = core_deck.NO_DEVICE_MESSAGE if reason == "no_device" else f"Creator Micro 2: {reason.replace('_', ' ')}."
        raise CommandError(reason if reason in ("no_device", "ambiguous_device_identity", "device_identity_unavailable") else "refused", message)
    self._core_deck_integration_cache = None
    _enabled, serial = self._core_deck_integration()
    self._core_deck_probe_now()
    self._core_publish_state_soon()
    return {"serial": serial, "approved": True}


@command("deck_disable", main_thread=False)
def _cmd_deck_disable(self, args):
    """The off half of approve: writes `creator_micro_enabled = false` so
    the output service is torn down; the approved serial stays, so the
    next enable does not ask for the pad again."""
    from .creator_micro_settings import save_creator_micro_choice_async

    self._core_deck_settings_done.clear()
    save_creator_micro_choice_async(self, False)
    if not self._core_deck_settings_done.wait(DECK_APPROVE_TIMEOUT_SECONDS):
        raise CommandError("busy", "Creator Micro 2 disable did not finish in time.")
    result = self._core_deck_settings_result
    if result is None or not result.saved:
        reason = getattr(result, "reason", "settings_save_failed")
        raise CommandError("refused", f"Creator Micro 2: {reason.replace('_', ' ')}.")
    self._core_deck_integration_cache = None
    self._core_publish_state_soon()
    return {"enabled": False}


@command("deck_check_input")
def _cmd_deck_check_input(self, args):
    enabled = args.get("enabled")
    if type(enabled) is not bool:
        raise CommandError("invalid_args", "enabled must be a bool")
    self._core_deck_set_input_check(enabled)
    self._core_publish_state()
    return {"enabled": enabled}


def _deck_bindings_update(value, previous) -> tuple:
    """The ``bindings`` argument: a full replacement list of auxiliary
    (13..19) and analog-sector (20..23) mappings, {"index": int,
    "action": kind | null}. Matrix-key bindings are managed by the
    Devices pane and survive."""
    from .deck_actions import DeckAction

    if type(value) is not list or len(value) > 11:
        raise CommandError("invalid_args", "bindings must be a list of auxiliary control mappings")
    aux = []
    for row in value:
        if type(row) is not dict or set(row) != {"index", "action"}:
            raise CommandError("invalid_args", "binding rows must be {index, action}")
        index, action = row["index"], row["action"]
        if type(index) is not int or not 13 <= index < 24:
            raise CommandError("invalid_args", "binding index must name an auxiliary control (13-23)")
        if action is not None:
            if type(action) is not str:
                raise CommandError("invalid_args", "binding action must be a deck action kind or null")
            try:
                aux.append((index, DeckAction(action)))
            except (TypeError, ValueError) as error:
                raise CommandError("invalid_args", "binding action must be a deck action kind or null") from error
    if len({index for index, _action in aux}) != len(aux):
        raise CommandError("invalid_args", "duplicate auxiliary binding")
    kept = tuple(entry for entry in previous.bindings if not 13 <= entry[0] < 24)
    return tuple(sorted((*kept, *aux)))


def _deck_layer_map_update(value) -> tuple:
    if type(value) is not list or len(value) > 24:
        raise CommandError("invalid_args", "layer_map must be a list of {layer, scope} rows")
    entries = []
    for row in value:
        if type(row) is not dict or set(row) != {"layer", "scope"}:
            raise CommandError("invalid_args", "layer_map rows must be {layer, scope}")
        entries.append((row["layer"], row["scope"]))
    return tuple(entries)


def _deck_scopes_update(value) -> tuple:
    if type(value) is not list or len(value) > 24:
        raise CommandError("invalid_args", "scopes must be a list of provider ids")
    scopes = []
    for scope in value:
        if type(scope) is not str:
            raise CommandError("invalid_args", "scopes must be provider id strings")
        if scope not in scopes:
            scopes.append(scope)
    return tuple(scopes)


def _deck_layer_owners_update(value) -> tuple:
    if type(value) is not list or len(value) > 24:
        raise CommandError("invalid_args", "layer_owners must be a list of {layer, owner} rows")
    entries = []
    for row in value:
        if type(row) is not dict or set(row) != {"layer", "owner"}:
            raise CommandError("invalid_args", "layer_owners rows must be {layer, owner}")
        entries.append((row["layer"], row["owner"]))
    return tuple(entries)


@command("deck_set_settings", main_thread=False)
def _cmd_deck_set_settings(self, args):
    from dataclasses import replace

    from .deck_control_settings import DeckControlSettings, load_deck_controls, save_deck_controls
    from .deck_settings_controller import DeckSettingsApplyResult

    updates = {key: args[key] for key in ("enabled", "session_mode", "analog_enabled") if key in args}
    if any(type(value) is not bool for value in updates.values()):
        raise CommandError("invalid_args", "enabled, session_mode and analog_enabled must be bools")
    previous = getattr(self, "_deck_control_settings", None)
    if type(previous) is not DeckControlSettings:
        try:
            previous = load_deck_controls()
        except (OSError, ValueError, TypeError) as error:
            raise CommandError("refused", "Deck settings could not be read safely.") from error
    if "bindings" in args:
        updates["bindings"] = _deck_bindings_update(args["bindings"], previous)
    if "layer_map" in args:
        updates["layer_map"] = _deck_layer_map_update(args["layer_map"])
    if "scopes" in args:
        updates["scopes"] = _deck_scopes_update(args["scopes"])
    if "ownership" in args:
        if type(args["ownership"]) is not str or args["ownership"] not in ("yield", "hold"):
            raise CommandError("invalid_args", "ownership must be yield or hold")
        updates["ownership"] = args["ownership"]
    if "layer_owners" in args:
        updates["layer_owners"] = _deck_layer_owners_update(args["layer_owners"])
    if not updates:
        raise CommandError(
            "invalid_args",
            "enabled, session_mode and analog_enabled must be bools; bindings, layer_map, layer_owners and scopes must be lists",
        )
    try:
        candidate = replace(previous, **updates)
    except (TypeError, ValueError) as error:
        raise CommandError("invalid_args", str(error)) from error
    if candidate != previous:
        try:
            save_deck_controls(candidate, expected=previous)
        except ValueError as error:
            raise CommandError("refused", "Deck settings changed. Reload before saving.") from error
        except OSError as error:
            raise CommandError("refused", "Could not save device actions. The previous settings are unchanged.") from error
        generation = int(getattr(self, "_deck_settings_save_generation", 0)) + 1
        self._deck_settings_save_generation = generation
        self._deck_settings_save_in_flight = True
        self.performSelectorOnMainThread_withObject_waitUntilDone_(
            "applyDeckSettingsResult:", DeckSettingsApplyResult(generation, previous, candidate), True
        )
    self._core_publish_state_soon()
    return {
        "enabled": candidate.enabled,
        "session_mode": candidate.session_mode,
        "analog_enabled": candidate.analog_enabled,
        "bindings": [{"index": index, "action": action.kind} for index, action in candidate.bindings],
        "layer_map": [{"layer": layer, "scope": scope} for layer, scope in candidate.layer_map],
        "scopes": list(candidate.scopes),
        "ownership": candidate.ownership,
        "layer_owners": [{"layer": layer, "owner": owner} for layer, owner in candidate.layer_owners],
    }


# --- the headless controller ---------------------------------------------------


def build_headless_controller_class() -> type:
    """Subclass the composed production controller for headless service."""
    import objc
    from AppKit import NSApplicationActivationPolicyAccessory, NSWorkspace

    from . import status_bar_legacy as legacy

    base = legacy.StatusBarController
    cached = _CLASS_CACHE.get(base)
    if cached is not None:
        return cached

    class JRCoreHeadlessController(base):
        headless = True

        # -- settings with a generation --------------------------------------

        @property
        def settings(self):
            return getattr(self, "_core_settings_value", None)

        @settings.setter
        def settings(self, value) -> None:
            self._core_settings_value = value
            self._core_settings_generation = getattr(self, "_core_settings_generation", 0) + 1
            if getattr(self, "_core", None) is not None:
                self._core_publish_settings()

        # -- construction ----------------------------------------------------

        def init(self):
            self = objc.super(JRCoreHeadlessController, self).init()
            if self is None:
                return None
            self.notification_client = HeadlessNotificationClient()
            device = getattr(self, "virtual_status_device", None)
            if device is not None:
                device.headless = True
                device._enabled = False
            self._core = None
            self._core_socket_path = None
            self._core_lock = threading.RLock()
            # Serializes answer_ask's arm -> dispatch -> wait window now that
            # the command runs on the socket thread: two in-flight answers
            # must not share the answer surface's single completion event.
            self._core_answer_ask_lock = threading.Lock()
            self._core_documents: dict[str, dict[str, Any]] = {}
            self._core_state_generation = 0
            self._core_lights_generation = 0
            # Set for the duration of the legacy refresh: publishes requested
            # from inside it (the virtual-device sync, the DND projection
            # callback, escalation) are dropped outright; the refresh tail
            # publishes each kind once, so nothing is lost.
            self._core_in_refresh = False
            # Broadcast stamps behind doctor's ``performance.frames``.
            self._core_state_frame_times: deque[float] = deque()
            self._core_lights_frame_times: deque[float] = deque()
            self._core_doctor_rusage: tuple[float, float] | None = None
            self._core_doctor_at: float | None = None
            self._core_hardware_anchor: dict[str, float] = {}
            # device_id -> volume root, so a disconnect can invalidate the
            # memoized STATUS.TXT LED count for the root it leaves behind.
            self._core_device_roots: dict[str, Path] = {}
            self._core_previews: dict[str, _Preview] = {}
            self._core_prev_asks: dict[str, Any] | None = None
            self._core_prev_devices: dict[str, bool] | None = None
            self._core_extras: dict[str, tuple[float, SessionExtras]] = {}
            # Keyed by (pid, process start epoch), not pid alone: a reused
            # pid must not inherit the previous owner's terminal. Entries
            # die with the process; the dicts are pruned when they grow.
            self._core_tty_by_pid: dict[tuple[int, float | None], str | None] = {}
            self._core_terminal_by_pid: dict[tuple[int, float | None], dict[str, Any] | None] = {}
            self._core_started_at = time.time()
            self._core_pending_drainer = None
            self._core_last_clear_batch = None
            self._core_housekeeping_timer = None
            self._core_supervision_timer = None
            self._core_last_stage_event = 0
            # Linked Pro + Dot: the Dot request riding on the Pro's worker
            # command, the Dot result waiting for the main thread, and the
            # last measured write skew (Dot completion minus Pro completion).
            self._core_linked_companion: tuple[str, int, Any] | None = None
            self._core_linked_results: dict[str, tuple[Any, Any]] = {}
            self._core_linked_skew_ms: float | None = None
            # The skew's rolling median: the last eight coupled-write gaps
            # per (pro, dot) pair. The median, not the latest sample, is
            # what the Dot's next program compensates for -- one slow write
            # should not re-phase the loop.
            self._core_linked_skew_samples: dict[tuple[str, str], deque[float]] = {}
            self._core_linked_skew_median_ms: float | None = None
            # The plan behind the pending companion write, and the shift it
            # baked in -- ``_apply_hardware_write_result`` reports both.
            self._core_linked_dot_plan = None
            self._core_linked_corrected_ms: float | None = None
            # The strip's latest nominal program and its LED count: what a
            # linked ``extend`` Dot replays. Set on every write to the
            # followed strip, cleared when no connected strip remains --
            # before the clear, a departed strip's last program looped on
            # the Dot forever.
            self._core_linked_pro_program: tuple[str, Any] | None = None
            self._core_linked_pro_leds = 8
            # The skew's measurement instant (epoch), so a reader can tell
            # "11 ms, just now" from "11 ms, three hours ago". Published
            # only together with the skew itself.
            self._core_linked_skew_at: float | None = None
            # Whether the last coupled Pro+Dot batch landed clean on both
            # devices. The lights document only stamps the Dot with the
            # strip's anchor while this is true -- an uncoupled batch means
            # the two are not running from one clock, and claiming the
            # shared anchor anyway was the lie this field exists to retire.
            self._core_linked_pair_ok = False
            # A short description of the last failed linked Dot write (the
            # exception class name, or the write's own error), surfaced as
            # ``lights.dot_link.error``; cleared by the next clean coupled
            # write.
            self._core_linked_dot_error: str | None = None
            # device_id -> monotonic time a bounded cue stops moving. A cue
            # that ends holds whatever its last line painted until something
            # writes again; these deadlines are what puts the live status
            # program back (coreHousekeepingTick_).
            self._core_finite_cue_end: dict[str, float] = {}
            # Usage window samples behind ``usage.providers[].forecast``.
            self._core_usage_samples = UsageSampleBuffer.load(default_state_dir() / SAMPLES_FILE_NAME)
            # The Creator Micro 2 deck.
            self._core_deck_last_input: tuple[int, str, float] | None = None
            self._core_deck_receipt: dict[str, Any] | None = None
            self._core_deck_last_output_reason: tuple[str, str] | None = None
            self._core_deck_inspection: tuple[float, Any] | None = None
            self._core_deck_keymap_generation = 0
            self._core_deck_setup_done = threading.Event()
            self._core_deck_setup_result: Any = None
            self._core_deck_settings_done = threading.Event()
            self._core_deck_settings_result: Any = None
            self._core_deck_devices: list[dict[str, Any]] = []
            self._core_deck_probe_at = 0.0
            self._core_deck_probe_pending = False
            # hidapi's IOHIDManager keeps the run loop of whichever thread
            # first touched it, so every probe has to run on the SAME
            # thread. A fresh thread per probe left the manager holding a
            # run loop that had gone with its thread, and the next
            # enumeration -- or a device arriving mid-enumeration -- died
            # on a pointer-authentication trap inside CoreFoundation, which
            # takes the whole daemon with it. One long-lived worker, woken
            # by an event, is the whole fix.
            self._core_deck_probe_wake = threading.Event()
            self._core_deck_probe_done = threading.Event()
            self._core_deck_probe_worker: threading.Thread | None = None
            self._core_deck_probe_error: str | None = None
            self._core_deck_integration_cache: tuple[float, bool, str | None] | None = None
            self._core_deck_lock = threading.Lock()
            # Live device position from the output owner's device.status
            # polls; input reports carry no layer field. None until the pad
            # answers, so the document falls back to the inspected values.
            self._deck_active_layer: int | None = None
            self._deck_active_profile: int | None = None
            return self

        # -- launch (the non-hostile half of the production launch) ---------

        def applicationDidFinishLaunching_(self, _notification):
            if getattr(self, "_runtime_started", False) or getattr(self, "_runtime_termination_started", False):
                return None
            try:
                self._core_launch()
            except Exception:
                # AppKit swallows exceptions raised in delegate callbacks; a
                # daemon that came up half-way must say so and stop.
                legacy.log_status_bar(f"core: launch failed: {traceback.format_exc(limit=8)}")
                self._core_stop_server()
                _application().terminate_(self)
                raise

        def _core_launch(self) -> None:
            _application().setActivationPolicy_(NSApplicationActivationPolicyAccessory)
            self.load_operator_local_state()
            self.trim_oversized_state_logs()
            legacy.log_status_bar("core: launching headless")
            # The backlog the shim spooled while the daemon was down drains
            # once here, before the ingress socket opens. A fresh replay is
            # stamped when it is drained (hook_ingress._replay_arguments),
            # so the order it reaches the monitor in is the order it counts
            # in: drained after the session's own first live hook, a spooled
            # prompt would land on top of the Stop that followed it. The
            # thread that drains on the interval starts further down.
            self._core_pending_drainer = PendingHookDrainer(
                self._core_submit_pending, log=legacy.log_status_bar
            )
            try:
                self._core_pending_drainer.drain_now()
            except Exception as exc:
                legacy.log_status_bar(f"hook_pending drain failed: {exc}")
            self.start_event_server()
            self.start_cloud_ingest_server()
            self.replay_debug_logs()
            self._runtime_started = True
            self._install_dnd_environment_observers()
            self._refresh_dnd_environment("start")
            sys.setswitchinterval(0.001)
            self.refresh_installed_agent_inventory()
            self._install_accessibility_display_observer()
            self.reconcile_lid_observation()
            self._core_start_server()
            self._core_sync_serve_server()
            self.refresh_(None)
            self.timer = _schedule_timer(legacy.STATUS_BAR_REFRESH_SECONDS, self, "refresh:", True)
            if not hasattr(self.virtual_status_device, "presentation_scheduler_inputs"):
                self.lid_timer = _schedule_timer(legacy.LID_POLL_SECONDS, self, "pollLid:", True)
            self.liveness_timer = _schedule_timer(legacy.LIVENESS_POLL_SECONDS, self, "pollLiveness:", True)
            self.start_remote_peer_timer()
            if self.settings.remote_peers.enabled:
                self.start_remote_peer_refresh()
            threading.Thread(
                target=lambda: legacy.trim_oversized_logs(default_state_dir()), daemon=True
            ).start()
            # The Screen Bar is the app's; the daemon only computes its program.
            self.virtual_status_device.hide()
            # The Creator Micro 2 output service and deck input, exactly as
            # the menu-bar app started them (provider_usage_status_bar).
            from .optional_integration_runtime import start_optional_integration_runtime

            self._jrbar_optional_integration_runtime = start_optional_integration_runtime(self)
            self._core_deck_probe_now()
            self._core_pending_drainer.start()
            self._core_housekeeping_timer = _schedule_timer(HOUSEKEEPING_SECONDS, self, "coreHousekeepingTick:", True)
            if os.environ.get("JRBAR_SUPERVISED") == "1":
                self._core_supervision_timer = _schedule_timer(SUPERVISION_SECONDS, self, "coreSupervisionTick:", True)
            _usage_history_warm_later(self)
            legacy.log_status_bar(f"core: ready pid={os.getpid()} socket={self._core.socket_path}")

        def applicationWillTerminate_(self, notification):
            if getattr(self, "_runtime_termination_started", False):
                return None
            self._core_stop_server()
            try:
                return objc.super(JRCoreHeadlessController, self).applicationWillTerminate_(notification)
            finally:
                self._core_quit_flush()

        def _core_quit_flush(self) -> None:
            """The daemon's last words: the usage sample buffer to disk,
            then every mounted strip off."""
            service = getattr(self, "_core_usage_history_service", None)
            if service is not None:
                service.close()
            try:
                self._core_usage_samples.save()
            except Exception as exc:
                legacy.log_status_bar(f"core: usage samples save at quit failed: {exc.__class__.__name__}")
            self._core_lights_off()

        def _core_lights_off(self) -> list[str]:
            """Write ``off`` to every connected hardware strip, Pro and Dot
            alike, straight to the volume.

            The controllers' paths are the wrong tool here: they dedupe on
            the last program identity (a linked Dot whose last write was
            the Pro's program would skip an identical ``off``), replace
            ``off`` with the resting glow, and ride a worker the legacy
            teardown has already closed. One direct write per device, no
            glow, no dedupe, so a quit never leaves a strip looping.
            """
            from .device_writer import write_led_program

            written: list[str] = []
            try:
                devices = self.status_bar_devices(remember=False)
            except Exception as exc:
                legacy.log_status_bar(f"core: quit: device scan failed: {exc.__class__.__name__}")
                return written
            for device in devices:
                if device.device_id == legacy.VIRTUAL_DEVICE_ID or not device.connected:
                    continue
                try:
                    write_led_program("off", device_path=device.target, preserve_existing_inode=True)
                    written.append(device.device_id)
                except Exception as exc:
                    legacy.log_status_bar(f"core: quit: {device.name} off failed: {exc.__class__.__name__}: {exc}")
            legacy.log_status_bar(f"core: quit: strips off: {', '.join(written) or 'none mounted'}")
            return written

        @objc.IBAction
        def quit_(self, _sender):
            self.closed_lid_awake.release()
            self.keep_awake.release()
            _application().terminate_(self)

        @objc.IBAction
        def coreQuit_(self, _sender):
            self.quit_(None)

        @objc.IBAction
        def coreSupervisionTick_(self, _timer):
            if os.getppid() == 1:
                legacy.log_status_bar("core: supervisor vanished; exiting")
                self.quit_(None)

        @objc.IBAction
        def coreHousekeepingTick_(self, _timer):
            now = time.monotonic()
            expired = [name for name, preview in self._core_previews.items() if preview.until_monotonic <= now]
            for name in expired:
                self._core_previews.pop(name, None)
            if self._core_repaint_finished_cues(now):
                expired.append("finite-cue")
            if expired:
                self.refresh_(None)
                self._core_publish_lights()
            if now - self._core_deck_probe_at >= DECK_PROBE_SECONDS:
                self._core_deck_probe_now()

        def _core_repaint_finished_cues(self, now: float) -> bool:
            """True when a bounded cue just ended and the device needs the
            live status program back.

            The write path dedupes on what it last wrote, so a device that
            has finished a cue and is sitting on its last frame looks
            up-to-date to the deduper -- the identity has to be cleared or the
            refresh below writes nothing at all.
            """
            done = [
                device_id
                for device_id, deadline in self._core_finite_cue_end.items()
                if deadline <= now
            ]
            for device_id in done:
                self._core_finite_cue_end.pop(device_id, None)
                controller = self.agent_led_controllers_by_device.get(device_id)
                if controller is None:
                    continue
                controller.last_program_identity = None
                controller.last_attempt_monotonic = 0.0
            return bool(done)

        @objc.IBAction
        def corePublishState_(self, _payload):
            self._core_publish_state()

        @objc.IBAction
        def coreClientsChanged_(self, count):
            try:
                clients = int(count)
            except (TypeError, ValueError):
                clients = 0
            legacy.log_status_bar(f"core: clients={clients}")
            if clients == 0:
                # The app went away: from here on, what happens is "while you
                # were away" until it comes back and looks.
                self.mark_activity_seen_now()
            else:
                self._core_publish_state()
                self._core_publish_lights()

        # -- surfaces this controller never has --------------------------------

        def update_status_menu(self, snapshot, state) -> None:
            self._menu_rebuild_pending = None

        def show_setup_window_if_needed(self) -> None:
            return None

        def set_settings_message(self, message: str) -> None:
            if isinstance(message, str) and message:
                legacy.log_status_bar(f"core: {message}")

        def _deliver_semantic_notification(self, event_key, interruption_class, **kwargs) -> bool:
            # Banners are the app's: the ledger and ask events carry the facts.
            return False

        @objc.IBAction
        def hooksUpdated_(self, payload):
            self.hooks_update_in_flight = False
            if not payload.get("ok"):
                legacy.log_status_bar(f"core: hooks failed: {payload.get('error')}")
                return
            self.refresh_intake_report(force=True)
            self.reload_monitor()
            self.refresh_(None)

        # -- emission seams ----------------------------------------------------

        @objc.IBAction
        def refresh_(self, sender):
            previous_asks = self._core_prev_asks
            previous_devices = self._core_prev_devices
            # Forget a departed strip BEFORE the legacy refresh plans the
            # Dot's next write: the disconnecting refresh itself would
            # otherwise still submit the ghost program it is reacting to.
            try:
                self._core_note_device_inventory(
                    [
                        d
                        for d in self.status_bar_devices(remember=False)
                        if d.device_id != legacy.VIRTUAL_DEVICE_ID
                    ],
                    (),
                )
            except Exception as exc:
                # A failure here is the linked-Dot ghost-write fix failing,
                # not noise: name it in the log.
                legacy.log_status_bar(f"core: inventory note failed: {exc.__class__.__name__}: {exc}")
            # Everything the legacy refresh publishes mid-pipeline (the
            # virtual-device sync, the DND callback, escalation) defers to
            # the two builds at the tail: one state build, one lights
            # build, per admitted tick.
            self._core_in_refresh = True
            try:
                result = objc.super(JRCoreHeadlessController, self).refresh_(sender)
            finally:
                self._core_in_refresh = False
            if getattr(self, "_core", None) is None:
                return result
            asks = {
                status.agent_id: (status, _ask_event_identity(status))
                for status in self._core_ask_statuses()
            }
            if previous_asks is not None:
                for kind, agent_id, status, identity in _diff_ask_episodes(
                    previous_asks, asks
                ):
                    self._core_publish_event(
                        kind,
                        session=agent_id,
                        provider=status.provider,
                        label=self._core_label(status),
                        detail=(
                            status.message or status.tool_name
                            if kind == "ask_opened"
                            else None
                        ),
                        request=identity,
                    )
            self._core_prev_asks = asks
            physical = [
                d
                for d in self.status_bar_devices(remember=False)
                if d.device_id != legacy.VIRTUAL_DEVICE_ID
            ]
            devices, transitions = device_transitions(previous_devices, physical)
            for kind, name, device_id in transitions:
                self._core_publish_event(kind, label=name, detail=device_id)
            self._core_prev_devices = devices
            self._core_note_device_inventory(physical, transitions)
            self._core_publish_state()
            self._core_publish_lights()
            return result

        def record_activity_entries(self, entries) -> None:
            objc.super(JRCoreHeadlessController, self).record_activity_entries(entries)
            if getattr(self, "_core", None) is None:
                return
            for entry in entries or ():
                kind = getattr(getattr(entry, "kind", None), "value", "")
                mapped = {"completed": "completed", "blocked": "failed", "threshold_crossed": "quota_crossed"}.get(kind)
                if mapped is None:
                    continue
                self._core_publish_event(
                    mapped,
                    session=entry.subject_id,
                    provider=entry.provider,
                    label=entry.label,
                    detail=entry.detail,
                    at=entry.occurred_at_epoch,
                )

        def apply_escalation(self, *, allow_refresh: bool = False) -> None:
            previous_stage = getattr(self, "escalation_last_stage", 0)
            previous_chimed = getattr(self, "escalation_chimed", False)
            objc.super(JRCoreHeadlessController, self).apply_escalation(allow_refresh=allow_refresh)
            if getattr(self, "_core", None) is None:
                return
            stage = getattr(self, "escalation_last_stage", 0)
            chimed_now = getattr(self, "escalation_chimed", False) and not previous_chimed
            if stage != previous_stage or chimed_now:
                oldest = self._core_oldest_ask()
                self._core_publish_event(
                    "escalation_stage",
                    session=oldest.agent_id if oldest is not None else None,
                    provider=oldest.provider if oldest is not None else None,
                    label=self._core_label(oldest) if oldest is not None else None,
                    stage=int(stage),
                    sound="glass" if chimed_now else None,
                )
                self._core_publish_state()

        def _dnd_projection_changed(self, projection) -> None:
            objc.super(JRCoreHeadlessController, self)._dnd_projection_changed(projection)
            self._core_publish_state()

        # -- power: the lease, the thermal governor, sleep on release -----------

        def sync_keep_awake(self, mode) -> None:
            """The legacy sync, told first what the holds yield to (the
            sessions a lease waits on, the battery floor, heat, the lid) and
            followed by the power events it recorded (jrbar.core_power)."""
            from . import core_power

            try:
                core_power.before_keep_awake_sync(self)
            except Exception:
                legacy.log_status_bar(f"core: power environment failed: {traceback.format_exc(limit=3)}")
            objc.super(JRCoreHeadlessController, self).sync_keep_awake(mode)
            try:
                core_power.after_keep_awake_sync(self)
            except Exception:
                legacy.log_status_bar(f"core: power events failed: {traceback.format_exc(limit=3)}")

        def low_power_active(self, battery_snapshot) -> bool:
            """The charge threshold, or the time left: a fast drain at 20% can
            be closer to empty than a slow one at 8% (jrbar.core_power)."""
            if objc.super(JRCoreHeadlessController, self).low_power_active(battery_snapshot):
                return True
            try:
                from . import core_power

                return core_power.low_battery_by_time_left(self, battery_snapshot)
            except Exception:
                return False

        # -- presence: a call holds the ladder at the light ----------------------

        def current_escalation_stage(self) -> int:
            """The legacy stage, adjusted for whether anyone can see it: held
            at the light on a call, past the invisible menu-bar pulse while the
            screen is locked (jrbar.presence, signals.presence_escalation_stage)."""
            stage = objc.super(JRCoreHeadlessController, self).current_escalation_stage()
            try:
                from . import core_power

                return core_power.escalation_stage(self, stage)
            except Exception:
                return stage

        def corePresenceExpired_(self, _timer) -> None:
            from . import core_power

            try:
                core_power.presence_expired(self)
            except Exception:
                legacy.log_status_bar(f"core: presence expiry failed: {traceback.format_exc(limit=3)}")

        def sync_virtual_status_device(self, *args, **kwargs) -> None:
            objc.super(JRCoreHeadlessController, self).sync_virtual_status_device(*args, **kwargs)
            self._core_publish_lights()

        def _core_note_hardware_write(self, command, result) -> None:
            objc.super(JRCoreHeadlessController, self)._apply_hardware_write_result(command, result)
            try:
                request = getattr(result, "request", None)
                write = getattr(result, "write", None)
                if request is not None and write is not None and write.changed and write.error is None:
                    anchor = mono_to_epoch(getattr(result, "completed_at", None))
                    if anchor is not None:
                        self._core_hardware_anchor[request.device.device_id] = anchor
                if request is not None and write is not None and write.error is None:
                    from ._led_status_legacy import (
                        finite_cue_duration_ms,
                        led_count_for_target,
                    )

                    if write.changed and write.program:
                        # A bounded cue on EITHER device: note when it stops.
                        # The Pro was found dark after a `repeat 8` completion
                        # flourish, and the Dot holding one lit LED after the
                        # same cue, because nothing re-armed the live program
                        # (2026-09-10).
                        span = finite_cue_duration_ms(write.program)
                        if span:
                            self._core_finite_cue_end[request.device.device_id] = (
                                time.monotonic() + span / 1000.0
                            )
                        else:
                            self._core_finite_cue_end.pop(request.device.device_id, None)

                    if led_count_for_target(request.device.target) != 2 and write.program:
                        # The strip's latest program is what a linked Dot
                        # replays, whichever path asks to write the Dot next.
                        # Its LED COUNT rides along: a program means nothing
                        # without the device it was rendered for, and the Dot
                        # has to narrow it before it can play it.
                        #
                        # NOMINAL, not the written bytes. The written program
                        # has already been through the strip transfer, and
                        # handing that to the Dot's own controller transfers
                        # it a SECOND time: #D187F5 arrived as #3103FF and
                        # `brightness 131` arrived as `brightness 1`, which
                        # is a Dot the owner reads as broken (2026-09-10).
                        # Only the FOLLOWED strip feeds the Dot: with two
                        # strips mounted, letting the second one's write
                        # overwrite the program would have the Dot extend a
                        # strip the lights document is not calling
                        # ``hardware``.
                        if self._core_is_followed_strip(request.device):
                            self._core_linked_pro_program = (
                                write.nominal_program or write.program,
                                write.state,
                            )
                            self._core_linked_pro_leds = led_count_for_target(request.device.target)
            except Exception:
                pass

        def _core_followed_strip_id(self) -> str | None:
            """The strip a linked Dot follows: the first connected strip in
            inventory order.

            ``status_bar_devices`` sorts connected devices first, then by
            name and mount path, and ``_core_build_lights`` names that same
            first strip the ``hardware`` surface -- so this is the one the
            app already sees as the hardware, and the only one whose writes
            may set the program a linked Dot replays.
            """
            from ._led_status_legacy import led_count_for_target

            try:
                for device in self.status_bar_devices(remember=False):
                    if device.device_id == legacy.VIRTUAL_DEVICE_ID or not device.connected:
                        continue
                    if led_count_for_target(device.target) != 2:
                        return device.device_id
            except Exception:
                return None
            return None

        def _core_is_followed_strip(self, device) -> bool:
            """Whether this device's writes may set the linked program.

            When the inventory cannot see the writer at all -- a test
            double, or a strip mid-disconnect whose row is already gone --
            there is nothing to follow but the writer itself, so it
            records. A visible inventory that names a different strip
            vetoes the write.
            """
            followed = self._core_followed_strip_id()
            return followed is None or device.device_id == followed

        def _core_held_preview_devices(self) -> frozenset:
            """Device ids a held preview currently owns.

            A three-second ``preview_program`` flash rides out one refresh;
            a ten-minute calibration hold cannot -- every sync would
            overwrite the patch the user is matching by eye. Requests for
            these devices are not built, and an in-flight command that
            predates the hold is refused at the write boundary.
            """
            # .copy(): the hardware-write worker calls this off the main
            # thread while commands insert and pop -- iterating the live
            # dict was a "dictionary changed size" that read as a failed
            # write (2026-09-11 audit).
            return frozenset(
                held_id
                for preview in self._core_previews.copy().values()
                if preview.held
                for held_id in preview.device_ids
            )

        def _core_end_calibration_preview(self, device_id: str, *, refresh: bool = True) -> bool:
            """Drop the held preview(s) a calibration session owns -- the
            device's own and a companion strip's -- and hand the devices
            back to the live render. Idempotent: the sheet calls this on
            Apply, on Cancel AND on disappear, so a second call must be a
            no-op rather than an error.
            """
            # .copy() for the same reason as _core_held_preview_devices:
            # this can run on the write worker while the dict mutates.
            dropped = [
                name
                for name, preview in self._core_previews.copy().items()
                if preview.held
                and (device_id in preview.device_ids or preview.companion_of == device_id)
            ]
            for name in dropped:
                preview = self._core_previews.pop(name)
                for held_id in preview.device_ids:
                    # The deduper believes the preview bytes are what is
                    # playing; clear the identity so the refresh writes the
                    # live program even when it is byte-identical to what
                    # the preview left on the device.
                    controller = self.agent_led_controllers_by_device.get(held_id)
                    if controller is not None:
                        controller.last_program_identity = None
                        controller.last_attempt_monotonic = 0.0
            if not dropped:
                return False
            if refresh:
                self.refresh_(None)
            self._core_publish_lights()
            return True

        def _core_note_device_inventory(self, devices, transitions) -> None:
            """Forget what departed hardware was playing.

            ``_core_linked_pro_program`` was set on every followed-strip
            write and never cleared, so a linked ``extend`` Dot kept
            looping the unplugged strip's last program forever -- the Dot
            looked busy beside a desk with no strip on it. A departure
            drops the device's write anchor, and the last strip leaving
            drops everything the link had claimed: the replayed program,
            the measured skew, the pair's clean-write record and its last
            error. The Dot's dedupe identity is cleared with them, or its
            next own-display request looks "already written" against the
            program it is no longer supposed to play.
            """
            from ._led_status_legacy import (
                invalidate_led_count_cache,
                led_count_for_target,
            )

            # Remember each connected device's volume so a disconnect can
            # drop its memoized STATUS.TXT answer -- a different device
            # remounting at the same root is re-read, not trusted.
            for device in devices:
                target = getattr(device, "target", None)
                if getattr(device, "connected", False) and target is not None:
                    self._core_device_roots[device.device_id] = Path(target).parent

            for kind, _name, device_id in transitions:
                if kind == "device_disconnected":
                    root = self._core_device_roots.pop(device_id, None)
                    if root is not None:
                        invalidate_led_count_cache(root)
                    self._core_hardware_anchor.pop(device_id, None)
                    # A held calibration preview outlives its device by
                    # minutes; left in place it would keep claiming the
                    # surface -- and suppressing live writes -- if the
                    # hardware came back inside the hold window, and a
                    # departed Dot would leave its companion strip stuck
                    # on the patch. refresh=False: the caller IS a refresh.
                    self._core_end_calibration_preview(device_id, refresh=False)
            try:
                strip_present = any(
                    bool(getattr(device, "connected", False))
                    and led_count_for_target(device.target) != 2
                    for device in devices
                )
            except Exception:
                return
            if strip_present:
                return
            if (
                self._core_linked_pro_program is None
                and self._core_linked_skew_ms is None
                and not self._core_linked_pair_ok
                and self._core_linked_dot_error is None
            ):
                # Nothing linked was ever claimed: resetting the Dot's
                # dedupe identity anyway would force a rewrite every
                # refresh the strip stays unplugged.
                return
            self._core_linked_pro_program = None
            self._core_linked_pro_leds = 8
            self._core_linked_skew_ms = None
            self._core_linked_skew_at = None
            self._core_linked_skew_samples.clear()
            self._core_linked_skew_median_ms = None
            self._core_linked_corrected_ms = None
            self._core_linked_dot_plan = None
            self._core_linked_pair_ok = False
            self._core_linked_dot_error = None
            for device in devices:
                try:
                    if not device.connected or led_count_for_target(device.target) != 2:
                        continue
                except Exception:
                    continue
                controller = self.agent_led_controllers_by_device.get(device.device_id)
                if controller is None:
                    continue
                controller.last_program_identity = None
                controller.last_attempt_monotonic = 0.0

        # -- what the Dot is FOR (jrbar.dot_role) ------------------------------

        def _core_dot_beacon_facts(self):
            """Whether a person is needed right now, for the ``asks`` role.

            The published ``state`` document already counts exactly this,
            past stale rows and cleared receipts, and the app reads the same
            numbers -- so the Dot and the Agent Browser can never disagree
            about whether anybody is waiting.
            """
            from .dot_role import DotBeaconFacts

            with self._core_lock:
                aggregate = (self._core_documents.get("state") or {}).get("aggregate") or {}
            try:
                stage = int(self.current_escalation_stage())
            except Exception:
                stage = 0
            mode = str(aggregate.get("mode") or "")
            # ``needs_you`` counts answerable asks; ``mode`` is the whole
            # fleet's headline and says "needs_you" for a session that is
            # merely waiting on input with no ask row to answer. Either is a
            # person being needed, which is the only question this surface
            # exists to answer, so a headline with no countable ask still
            # lights the beacon.
            asks = int(aggregate.get("needs_you") or 0)
            from . import core_power

            return DotBeaconFacts(
                ask_count=max(asks, 1 if mode == "needs_you" else 0),
                blocked=bool(aggregate.get("failed") or 0) or mode == "failed",
                unseen_completions=int(aggregate.get("ready") or 0),
                escalation_stage=stage,
                # The ``call`` role's busylight, and the shut lid that turns
                # an ``extend`` Dot into the asks beacon (jrbar.dot_role).
                on_call=core_power.on_call(self),
                in_meeting=core_power.in_meeting(self),
                lid_closed=core_power.lid_closed(self) is True,
            )

        def _core_dot_plan(self, controller=None, program: str | None = None):
            """The role's whole answer for the Dot, or ``None`` to fall through.

            ``None`` means ``status`` (or ``extend`` with nothing to extend):
            the Dot renders its own two-LED semantic display
            (``dot_binary_heartbeat`` through the ambient dispatch) exactly
            as an unlinked Dot always has.

            ``controller`` is optional because the ``lights`` frame wants the
            role and the ``why`` without wanting a brightness line.
            """
            from . import core_power
            from ._led_status_legacy import (
                normalize_brightness,
                scale_nominal_brightness,
            )
            from .dot_role import DotRole, normalize_dot_role, plan_dot_surface

            if not bool(getattr(self.settings, "devices_linked", True)):
                return None
            role = normalize_dot_role(getattr(self.settings, "dot_role", None))
            strip = getattr(self, "_core_linked_pro_program", None)
            body = program if program is not None else (strip[0] if strip else None)
            brightness = None
            if controller is not None:
                device = normalize_brightness(getattr(controller, "brightness", 255))
                # The strip's own brightness line still caps the Dot: the
                # linked scale is a ratio between two devices, not a licence
                # to outshine. ``body`` is NOMINAL here, so this reads a
                # nominal brightness -- reading the written bytes made the cap
                # an already-decoded drive code and dimmed the Dot twice.
                existing = min(
                    (
                        int(parts[1])
                        for parts in (line.strip().split() for line in (body or "").splitlines())
                        if len(parts) == 2 and parts[0] == "brightness" and parts[1].isdigit()
                    ),
                    default=255,
                )
                brightness = min(existing, device)
                # A shut lid makes an ``extend`` Dot the asks beacon, which is
                # never scaled down (see below).
                if role == DotRole.EXTEND.value and core_power.lid_closed(self) is not True:
                    # Exactly one place applies ``linked_dot_scale``, and it
                    # applies it to LIGHT. A code-domain multiply looks like a
                    # ratio and is not one: the write boundary then decodes
                    # the scaled code through sRGB, so 0.3 landed as 6.7% of
                    # the strip's light instead of 30%. ``asks`` is not a
                    # continuation of anything and is not scaled at all -- an
                    # attention beacon dimmed to a third is a beacon nobody
                    # notices.
                    brightness = scale_nominal_brightness(
                        brightness, float(getattr(self.settings, "linked_dot_scale", 0.3))
                    )
            return plan_dot_surface(
                role=getattr(self.settings, "dot_role", None),
                semantic=getattr(getattr(self, "_current_resolved_glance", None), "semantic", None),
                facts=self._core_dot_beacon_facts(),
                strip_program=body,
                strip_led_count=int(getattr(self, "_core_linked_pro_leds", 8) or 8),
                # The rolling median of measured write gaps: the program is
                # re-anchored by that much, so the Dot's late restart plays
                # the phase the strip is on (dot_role.shift_program_phase).
                skew_correction_ms=self._core_linked_skew_median_ms,
                brightness=brightness,
                include_completions=bool(
                    getattr(self.settings, "dot_role_include_completions", False)
                ),
            )

        def _core_linked_dot_follows(self, request) -> bool:
            """True when this request targets the Dot and its role says the
            daemon, not the Dot's own display path, decides what it shows.

            The role is the authority, and it outranks a per-device display
            kind: an ``extend`` or ``asks`` Dot that still carries a stale
            ``quota_runway`` from before roles existed follows its role.
            ``asks`` needs no strip at all -- an attention beacon is not a
            continuation of anything.
            """
            from ._led_status_legacy import led_count_for_target
            from .dot_role import DotRole, normalize_dot_role

            role = normalize_dot_role(getattr(self.settings, "dot_role", None))
            if role == DotRole.STATUS.value:
                return False
            if not bool(getattr(self.settings, "devices_linked", True)):
                return False
            if role == DotRole.EXTEND.value and getattr(self, "_core_linked_pro_program", None) is None:
                return False
            try:
                if led_count_for_target(request.device.target) != 2:
                    return False
            except Exception:
                return False
            identity = str(getattr(request, "coalesce_identity", "") or "")
            # Previews the operator asked for (calibration, Effect Studio)
            # still reach the Dot; ambient candidates and ordinary renders
            # do not: the role owns this surface.
            return identity in ("", "latest") or identity.startswith("ambient-")

        def _sync_hardware_device(self, request):
            if request.device.device_id in self._core_held_preview_devices():
                # A request queued before the hold began, or one that
                # slipped past the build-time skip: the held patch is the
                # truth on this device until the sheet ends it. Reporting
                # an unchanged write keeps the result pipeline honest
                # without repainting over the preview.
                return legacy.HardwareWriteResult(
                    request=request,
                    write=legacy.LedStatusWrite(
                        state=legacy.LedDisplayState.IDLE,
                        target=getattr(request.device, "target", None),
                        program="",
                        changed=False,
                    ),
                    label=f"{request.device.name} Calibration preview",
                    agent_display_rendered=False,
                    completed_at=self._runtime_worker_monotonic(),
                )
            if self._core_linked_dot_follows(request):
                controller = self.agent_controller_for_device(request.device)
                plan = self._core_dot_plan(controller)
                if plan is not None:
                    strip = getattr(self, "_core_linked_pro_program", None)
                    state = strip[1] if strip else legacy.LedDisplayState.IDLE
                    write = controller.sync_program(plan.program, state)
                    return legacy.HardwareWriteResult(
                        request=request,
                        write=write,
                        label=f"{request.device.name} {plan.role}",
                        agent_display_rendered=True,
                        completed_at=self._runtime_worker_monotonic(),
                    )
                # The role claimed this surface and then could not plan it,
                # so the Dot is about to render something from a completely
                # different vocabulary (its own binary heartbeat) while the
                # protocol still says `role: extend`. That disagreement is
                # exactly what made the 2026-09-10 defect so hard to place;
                # it is worth a line in the flight recorder every time.
                reason = str(getattr(request, "coalesce_identity", "") or "latest")
                if reason != getattr(self, "_core_dot_plan_gap_logged", None):
                    self._core_dot_plan_gap_logged = reason
                    legacy.log_status_bar(
                        f"core: dot role could not plan ({reason}); falling through"
                    )
            return objc.super(JRCoreHeadlessController, self)._sync_hardware_device(request)

        # -- linked Pro + Dot writes -------------------------------------------

        def _submit_hardware_write_requests(self, requests, now: float) -> None:
            """With ``devices_linked`` and a Pro plus one Dot mounted, the
            Dot's request rides on the FOLLOWED strip's worker command: the
            worker writes the strip, then the Dot immediately after, from
            the same presentation, relay epoch and anchor, so the two loop
            as one. Other strips in the batch submit on their own --
            coupling them to the Dot's clock would make a second strip's
            write decide what the Dot replays."""
            from ._led_status_legacy import led_count_for_target

            pro = dot = None
            if bool(getattr(self.settings, "devices_linked", True)) and len(requests) >= 2:
                dots = [r for r in requests if led_count_for_target(r.device.target) == 2]
                followed = self._core_followed_strip_id()
                if followed is not None:
                    strip = next(
                        (r for r in requests if r.device.device_id == followed), None
                    )
                else:
                    # The inventory cannot see the writers (test doubles):
                    # the batch's own order, device_id-sorted upstream, is
                    # the deterministic pick.
                    strips = [
                        r for r in requests if led_count_for_target(r.device.target) != 2
                    ]
                    strip = strips[0] if strips else None
                if strip is not None and len(dots) == 1:
                    pro, dot = strip, dots[0]
            if pro is None or dot is None:
                self._core_linked_companion = None
                # A batch that did not couple the pair cannot vouch for it:
                # until the next coupled write lands clean, the Dot keeps
                # its own anchor in the lights document.
                self._core_linked_pair_ok = False
                return objc.super(JRCoreHeadlessController, self)._submit_hardware_write_requests(requests, now)
            command = self._hardware_write_command(pro, now)
            self._core_linked_companion = (command.key, command.generation, dot)
            # The Dot's own pending command (from an unlinked refresh) must
            # not fire a second, skewed write.
            try:
                self._hardware_write_worker.discard_pending_prefix(self._hardware_worker_key(dot.device))
            except Exception:
                pass
            self._hardware_write_worker.submit(command)
            for request in requests:
                if request is not pro and request is not dot:
                    self._hardware_write_worker.submit(self._hardware_write_command(request, now))

        def _execute_hardware_write_command(self, command):
            result = objc.super(JRCoreHeadlessController, self)._execute_hardware_write_command(command)
            companion = self._core_linked_companion
            if companion is None or companion[0] != command.key or companion[1] != command.generation:
                return result
            dot_request = companion[2]
            if dot_request.device.device_id in self._core_held_preview_devices():
                # The Dot went under a held calibration preview after this
                # batch was queued: writing the strip's replay now would
                # paint over the patch mid-match.
                return result
            try:
                dot_result = self._core_linked_dot_write(dot_request, result)
            except Exception as exc:
                self._core_linked_dot_error = f"{exc.__class__.__name__}"
                self._core_linked_pair_ok = False
                self._core_linked_dot_plan = None
                legacy.log_status_bar(f"core: linked dot write failed: {exc.__class__.__name__}")
                return result
            dot_command = self._hardware_write_command(dot_request, command.deadline - 1.0)
            self._core_linked_results[command.key] = (dot_command, dot_result)
            return result

        def _core_linked_dot_write(self, dot_request, pro_result):
            """The Dot's program, written in the Pro's own worker command.

            Linked mode means one clock across both devices: the Dot is
            written from the Pro's presentation, immediately after it, so
            the two restart together. What the Dot PLAYS is its role's
            business (``jrbar.dot_role``) -- the strip's animation narrowed
            to two LEDs for ``extend``, the attention beacon for ``asks``.

            It used to be the Pro's exact bytes, on the theory that "the
            firmware ignores per-index colours beyond its LED count" made
            them LEDs 0 and 1 of the same wave. It does ignore them, which
            is the problem: an eight-LED chase whose lit index was anywhere
            but 0 or 1 arrived at the Dot as two black LEDs.
            """
            write = getattr(pro_result, "write", None)
            # The NOMINAL program, never the written bytes: the Dot's own
            # controller runs the strip transfer again on whatever it is
            # handed, so passing already-transferred text decodes the colours
            # and the brightness twice (2026-09-10: `brightness 131` reached
            # the hardware as `brightness 1`).
            program = getattr(write, "nominal_program", "") or getattr(write, "program", None)
            if not program or getattr(write, "error", None) is not None:
                return self._sync_hardware_device(dot_request)
            controller = self.agent_controller_for_device(dot_request.device)
            plan = self._core_dot_plan(
                controller,
                program,
            )
            # The apply side reports the shift this plan baked in and stamps
            # the Dot's anchor with it; stashed here because the result
            # pipeline rejoins on the main thread.
            self._core_linked_dot_plan = plan
            if plan is None:
                return self._sync_hardware_device(dot_request)
            dot_write = controller.sync_program(plan.program, write.state)
            return legacy.HardwareWriteResult(
                request=dot_request,
                write=dot_write,
                label=f"{dot_request.device.name} {plan.role} with {pro_result.request.device.name}",
                agent_display_rendered=True,
                completed_at=self._runtime_worker_monotonic(),
            )

        def _apply_hardware_write_result(self, command, result) -> None:
            self._core_note_hardware_write(command, result)
            companion = self._core_linked_results.pop(getattr(command, "key", ""), None)
            if companion is None:
                self._core_publish_lights()
                return
            dot_command, dot_result = companion
            if dot_command.generation != self._hardware_write_generation:
                self._core_publish_lights()
                return
            # The pair's word on this coupled batch, taken BEFORE the skew
            # bookkeeping below touches the program record: a clean pair is
            # what lets the lights document stamp the Dot with the strip's
            # anchor and clear the last linked-write error. A Dot-side
            # write error is a linked-write failure worth naming; the Pro
            # failing only means this batch did not couple, not that the
            # Dot's own write went wrong.
            dot_error = getattr(dot_result.write, "error", None)
            pro_ok = getattr(result.write, "error", None) is None
            self._core_linked_pair_ok = pro_ok and dot_error is None
            if dot_error is not None:
                self._core_linked_dot_error = str(dot_error)
            elif pro_ok:
                self._core_linked_dot_error = None
            try:
                skew = float(dot_result.completed_at) - float(result.completed_at)
            except Exception:
                skew = None
            if skew is not None and getattr(dot_result.write, "changed", False) and getattr(result.write, "changed", False):
                self._core_linked_skew_ms = round(skew * 1000.0, 1)
                # Epoch, so a stale number can be told apart from a fresh
                # one: the lights document publishes the two together.
                self._core_linked_skew_at = time.time()
                try:
                    from statistics import median

                    pair = (
                        str(result.request.device.device_id),
                        str(dot_result.request.device.device_id),
                    )
                    samples = self._core_linked_skew_samples.setdefault(
                        pair, deque(maxlen=8)
                    )
                    samples.append(self._core_linked_skew_ms)
                    self._core_linked_skew_median_ms = round(float(median(samples)), 1)
                except Exception:
                    self._core_linked_skew_median_ms = self._core_linked_skew_ms
                legacy.log_status_bar(f"linked write: dot {self._core_linked_skew_ms} ms after pro")
            self._core_note_hardware_write(dot_command, dot_result)
            plan = self._core_linked_dot_plan
            self._core_linked_dot_plan = None
            corrected = (
                float(getattr(plan, "corrected_ms", 0.0) or 0.0)
                if plan is not None
                else 0.0
            )
            if corrected:
                # The published program is already rotated to the strip's
                # phase, so its true on-device start is the Dot's own write
                # completion pulled back by the shift it baked in -- not
                # the strip's anchor, and not a planning-time guess.
                anchor = mono_to_epoch(getattr(dot_result, "completed_at", None))
                if anchor is not None:
                    self._core_hardware_anchor[dot_result.request.device.device_id] = (
                        anchor - corrected / 1000.0
                    )
            self._core_linked_corrected_ms = corrected or None
            self._core_publish_lights()

        # -- the Creator Micro 2 deck ------------------------------------------

        @property
        def _deck_last_input(self):
            """``DeckInputDispatch`` records every observed control here (from
            the HID thread); the daemon turns each one into a ``deck_input``
            event and a fresh ``state``."""
            return self._core_deck_last_input

        @_deck_last_input.setter
        def _deck_last_input(self, value) -> None:
            self._core_deck_last_input = value
            if getattr(self, "_core", None) is None or type(value) is not tuple or len(value) != 3:
                return
            index, kind, at = value
            self._core_publish_event(
                "deck_input",
                label=core_deck.control_label(int(index), dict(getattr(self, "_deck_control_labels", ()) or ())),
                input={"index": int(index), "kind": core_deck.input_kind(int(index), str(kind)), "at": mono_to_epoch(at)},
            )
            self._core_publish_state_soon()

        def _core_publish_state_soon(self) -> None:
            if threading.current_thread() is threading.main_thread():
                self._core_publish_state()
            else:
                self.performSelectorOnMainThread_withObject_waitUntilDone_("corePublishState:", None, False)

        def _core_deck_board(self):
            from .deck_control_center import ensure_deck_board

            return ensure_deck_board(self)

        def _core_deck_store_board(self) -> None:
            store = getattr(self, "_deck_board_store", None)
            board = getattr(self, "_deck_session_board", None)
            if store is not None and board is not None:
                store.submit(board)

        def _core_deck_publish(self) -> None:
            from .deck_control_center import publish_deck_frame

            try:
                publish_deck_frame(self)
            except Exception as exc:
                legacy.log_status_bar(f"core: deck frame not published: {exc.__class__.__name__}")
            self._core_publish_state()

        def _core_deck_note_receipt(self, code: str, message: str, detail: str = "") -> None:
            """The receipt the app shows. ``detail`` is the device's or the
            OS's own words: the sentence says what to do, the detail says
            what actually happened, which is all a first-contact failure on
            real hardware leaves behind."""
            self._core_deck_receipt = {"code": code, "message": message, "at": time.time()}
            if detail:
                self._core_deck_receipt["detail"] = detail[:256]
            self._core_publish_event(
                "deck_receipt", label=core_deck.DECK_NAME, code=code, message=message,
                **({"detail": detail[:256]} if detail else {}),
            )

        def applyCreatorMicroOutputReceipt_(self, receipt) -> None:
            self._creator_micro_output_receipt = receipt
            reason = str(getattr(receipt, "reason", "") or "")
            detail = str(getattr(receipt, "detail", "") or "")
            if reason and (reason, detail) != self._core_deck_last_output_reason:
                self._core_deck_last_output_reason = (reason, detail)
                legacy.log_status_bar(f"deck: {reason}" + (f" ({detail})" if detail else ""))
                self._core_deck_note_receipt(reason, core_deck.receipt_message(reason, source="output"), detail)
            self._core_publish_state()

        def applyCreatorMicroSettings_(self, result) -> None:
            from .creator_micro_settings import apply_creator_micro_settings

            apply_creator_micro_settings(self, result)
            self._core_deck_integration_cache = None
            self._core_deck_settings_result = result
            self._core_deck_settings_done.set()

        def applyCreatorMicroSetupResult_(self, result) -> None:
            """The setup thread's answer, without the Python alerts: the
            inspection is cached for planning and the pad is handed back to
            the output service; an apply or restore records its receipt."""
            from .creator_micro_setup_controller import SetupPreview

            if (
                getattr(result, "generation", None) is not getattr(self, "_creator_micro_setup_generation", None)
                or getattr(self, "_runtime_termination_started", False)
                or getattr(self, "_deck_runtime_stopping", False)
            ):
                return
            self._creator_micro_setup_busy = False
            if getattr(self, "_deck_runtime_generation", None) is not result.generation:
                return
            code = str(result.code)
            if code == "inspection_ready":
                preview = getattr(result, "preview", None)
                self._core_deck_inspection = (time.monotonic(), preview) if type(preview) is SetupPreview else None
                if getattr(result, "runtime_was_stopped", False):
                    self.reconfigureDeckRuntime_(None)
            else:
                if getattr(result, "runtime_was_stopped", False) or getattr(
                    self, "_creator_micro_setup_runtime_needs_restart", False
                ):
                    self._creator_micro_setup_runtime_needs_restart = False
                    self.reconfigureDeckRuntime_(None)
                self._core_deck_keymap_generation += 1
                self._core_deck_inspection = None
                self._core_deck_note_receipt(code, core_deck.receipt_message(code))
                legacy.log_status_bar(f"deck: {result.operation} -> {code}")
                if code == "keymap_verified":
                    self._core_deck_set_input_check(True)
            self._core_deck_setup_result = result
            self._core_deck_setup_done.set()
            self._core_publish_state()

        # The deck selectors of deck_status_bar.install_deck_status_bar, so the
        # daemon is whole even when the base class was composed without them.
        def reconfigureDeckRuntime_(self, _sender) -> None:
            from .deck_controller import reconfigure_deck_runtime

            reconfigure_deck_runtime(self)

        def applyDeckSettingsResult_(self, payload) -> None:
            from .deck_settings_controller import apply_deck_settings_result

            apply_deck_settings_result(self, payload)

        def applyDeckAutomationResult_(self, receipt) -> None:
            if not getattr(self, "_runtime_termination_started", False):
                self._deck_action_receipt = receipt

        def applyDeckControlsLoaded_(self, payload) -> None:
            self._core_publish_state()

        def applyDeckLayer_(self, payload) -> None:
            from .deck_controller import apply_deck_layer

            apply_deck_layer(self, payload)

        def applyDeckInput_(self, batch) -> None:
            """A physical input batch (main thread): the same executor as the
            menu-bar app, with the 0.8 session-key rule (answer a live ask
            when its terminal is in front, else reveal). Delivery leaves the
            main thread inside ``apply_deck_input``."""
            from .deck_controller import apply_deck_input

            apply_deck_input(self, batch)

        def _core_deck_executor(self):
            from .deck_control_center import deck_executor

            executor = deck_executor(self)
            executor._session_revealer = self._core_deck_reveal_or_answer
            return executor

        def _core_deck_statuses(self) -> tuple:
            monitor = getattr(self, "monitor", None)
            current = getattr(monitor, "current_statuses_by_key", None)
            if callable(current):
                try:
                    return tuple(current().values())
                except Exception:
                    pass
            return tuple(getattr(getattr(self, "last_snapshot", None), "statuses", ()) or ())

        def _core_deck_status_for_identity(self, identity: str):
            from .deck_session_board import session_identity

            for status in self._core_deck_statuses():
                if session_identity(status) == identity:
                    return status
            return None

        def _core_deck_try_answer(self, status) -> dict[str, Any] | None:
            """Answer the session's live ask through the answer_ask path when
            the daemon confirms its terminal is frontmost; ``None`` means
            reveal instead (no ask, not in front, or not answerable)."""
            try:
                return _cmd_answer_ask(self, {"session": status.agent_id, "decision": "approve", "only_if_frontmost": True})
            except CommandError as error:
                if error.code not in ("not_found", "not_frontmost", "unsupported"):
                    legacy.log_status_bar(f"deck: answer refused: {error.code}")
                return None

        def _core_deck_reveal_or_answer(self, identity: str, revision: int | None):
            """Answer-first reveal. Runs on whichever thread called it: the
            status read and the AppKit reveal hop to main, while the answer
            attempt's reply wait stays on the caller — the hardware input
            path posts ``deliver`` to a worker for exactly this reason."""
            from .deck_actions_macos import DeckActionReceipt
            from .deck_control_center import reveal_deck_session

            on_main = getattr(self, "_core_on_main", None) or (lambda fn: fn())
            status = on_main(lambda: self._core_deck_status_for_identity(identity))
            if status is not None and self._core_deck_try_answer(status) is not None:
                return DeckActionReceipt("ask_answered", True)
            return on_main(lambda: reveal_deck_session(self, identity, revision))

        def _core_deck_press(self, index: int) -> dict[str, Any]:
            """Runs on the socket thread: every board/settings/AppKit touch
            hops to main, so the answer attempt's ≤6s reply wait never
            parks the run loop behind a key press."""
            from .deck_control_center import reveal_deck_session
            from .deck_session_board import SLOTS_PER_BANK

            on_main = getattr(self, "_core_on_main", None) or (lambda fn: fn())

            def _action_result(action):
                receipt = self._core_deck_executor().execute(action)
                self._deck_action_receipt = receipt
                result: dict[str, Any] = {
                    "index": index,
                    "action": action.kind,
                    "identity": None,
                    "session": None,
                    "receipt": receipt.code,
                }
                if action.kind in ("next_bank", "previous_bank"):
                    snapshot = self._core_deck_board().snapshot()
                    result["bank"] = {"index": snapshot.bank, "count": snapshot.bank_count}
                elif action.kind in ("next_scope", "previous_scope"):
                    result["scope"] = self._core_deck_board().snapshot().scope
                elif not receipt.success:
                    raise CommandError("refused", core_deck.receipt_message(receipt.code, source="action"))
                legacy.log_status_bar(f"deck: {core_deck.control_label(index)} runs {action.kind}: {receipt.code}")
                self._core_publish_state()
                return result

            def _resolve_slot():
                if index >= SLOTS_PER_BANK:
                    raise CommandError("not_found", core_deck.AUXILIARY_MESSAGE)
                board = self._core_deck_board()
                revision, identity = board.resolve_slot(index)
                if identity is None:
                    raise CommandError("not_found", core_deck.NO_SESSION_MESSAGE)
                status = self._core_deck_status_for_identity(identity)
                if status is None:
                    raise CommandError("not_found", core_deck.RESERVED_MESSAGE)
                return revision, identity, status

            settings = on_main(lambda: getattr(self, "_deck_control_settings", None))
            action = settings.action_for(index) if settings is not None else None
            if action is not None:
                return on_main(lambda: _action_result(action))
            revision, identity, status = on_main(_resolve_slot)
            result = {"index": index, "identity": identity, "session": status.agent_id}
            answered = self._core_deck_try_answer(status)
            if answered is not None:
                legacy.log_status_bar(f"deck: key {index + 1} answers {status.agent_id}")
                result.update({"action": "answer_ask", "decision": answered.get("decision"), "answered": True})
                return result

            def _reveal():
                receipt = reveal_deck_session(self, identity, revision)
                self._deck_action_receipt = receipt
                if not receipt.success:
                    raise CommandError("refused", core_deck.receipt_message(receipt.code, source="action"))
                extras = self._core_extras_for(status)
                result.update(
                    {
                        "action": "reveal_session",
                        "receipt": receipt.code,
                        "activated": (extras.terminal or {}).get("app") if extras is not None else None,
                    }
                )
                legacy.log_status_bar(f"deck: key {index + 1} reveals {self._core_label(status)}")
                self._core_publish_state()
                return result

            return on_main(_reveal)

        def _core_deck_set_input_check(self, enabled: bool) -> None:
            self._deck_input_check_active = bool(enabled)
            runner = getattr(self, "_deck_automation_runner", None)
            if enabled and runner is not None:
                self._deck_automation_runner = None
                runner.close()
            dispatch = getattr(getattr(self, "_jrbar_optional_integration_runtime", None), "_deck_dispatch", None)
            if dispatch is not None:
                dispatch.reset_connection()

        def _core_deck_run_setup(self, start: Callable[[], Any]):
            """Start a setup operation (inspect / apply / restore) and wait
            for its result on this (socket) thread; the main thread receives
            it through ``applyCreatorMicroSetupResult:``."""
            if getattr(self, "_creator_micro_setup_busy", False):
                raise CommandError("busy", "Creator Micro 2 setup is already running.")
            self._core_deck_setup_done.clear()
            self._core_deck_setup_result = None
            thread = start()
            if thread is None:
                raise CommandError("busy", "Creator Micro 2 setup is already running.")
            if not self._core_deck_setup_done.wait(DECK_SETUP_TIMEOUT_SECONDS):
                raise CommandError("busy", "Creator Micro 2 did not answer in time.")
            result = self._core_deck_setup_result
            if result is None:
                raise CommandError("internal", "setup produced no result")
            return result

        def _core_deck_inspect(self):
            """The inspected keymap (a ``SetupPreview``), reading the device
            when the cached one is older than ``DECK_INSPECTION_TTL_SECONDS``."""
            from .creator_micro_setup_controller import SetupPreview, begin_creator_micro_inspection

            cached = self._core_deck_inspection
            if cached is not None and time.monotonic() - cached[0] < DECK_INSPECTION_TTL_SECONDS:
                return cached[1]
            result = self._core_deck_run_setup(lambda: begin_creator_micro_inspection(self))
            preview = getattr(result, "preview", None)
            if result.code != "inspection_ready" or type(preview) is not SetupPreview:
                code = result.code if result.code != "inspection_ready" else "setup_failed"
                # The setup thread's detail is the only account of a refused
                # open; without it every hardware failure reads the same.
                detail = str(getattr(result, "detail", "") or "")
                message = core_deck.receipt_message(code)
                raise CommandError(code, f"{message} ({detail[:160]})" if detail else message)
            return preview

        def _core_deck_integration(self) -> tuple[bool, str | None]:
            """(creator_micro_enabled, approved serial) from integrations.json."""
            cached = self._core_deck_integration_cache
            now = time.monotonic()
            if cached is not None and now - cached[0] < DECK_INTEGRATION_TTL_SECONDS:
                return cached[1], cached[2]
            enabled, serial = False, None
            try:
                from .integration_settings import load_integration_settings

                settings = load_integration_settings().settings
                serial = getattr(settings, "creator_micro_device_serial", None)
                serial = serial.strip() if isinstance(serial, str) and serial.strip() else None
                enabled = bool(getattr(settings, "creator_micro_enabled", False)) and serial is not None
            except Exception as exc:
                legacy.log_status_bar(f"core: integration settings unreadable: {exc.__class__.__name__}")
            self._core_deck_integration_cache = (now, enabled, serial)
            return enabled, serial

        def _core_deck_probe_rows(self) -> list[dict[str, Any]]:
            with self._core_deck_lock:
                return list(self._core_deck_devices)

        def _core_deck_probe_once(self) -> None:
            """One HID enumeration, on the probe thread and nowhere else."""
            error = None
            try:
                rows = deck_probe()
            except Exception as exc:
                rows, error = [], f"{exc.__class__.__name__}"
            with self._core_deck_lock:
                changed = rows != self._core_deck_devices or error != self._core_deck_probe_error
                self._core_deck_devices = rows
                self._core_deck_probe_error = error
                self._core_deck_probe_pending = False
                # Inside the lock: a ``wait`` caller that queues the next
                # probe can never clear ``done`` for the one that just
                # finished, so its wait always lands on its own answer.
                self._core_deck_probe_done.set()
            if changed and getattr(self, "_core", None) is not None:
                legacy.log_status_bar(f"deck: probe {len(rows)} pad(s)" + (f" ({error})" if error else ""))
                self._core_publish_state_soon()

        def _core_deck_probe_loop(self) -> None:
            while True:
                self._core_deck_probe_wake.wait()
                self._core_deck_probe_wake.clear()
                self._core_deck_probe_once()

        def _core_deck_probe_now(self, *, wait: bool = False) -> None:
            """Ask the probe thread to look for the pad over HID; a changed
            answer republishes ``state``. With ``wait``, an in-flight probe
            counts: the caller blocks on its completion instead of reading
            the previous (possibly stale ``no_device``) answer."""
            with self._core_deck_lock:
                if self._core_deck_probe_pending:
                    if wait:
                        # The requester that queued this probe already
                        # cleared ``done``; waiting on it lands on the
                        # in-flight probe's completion.
                        pass
                    else:
                        return
                else:
                    self._core_deck_probe_pending = True
                    if self._core_deck_probe_worker is None:
                        self._core_deck_probe_worker = threading.Thread(
                            target=self._core_deck_probe_loop, name="JRBarDeckProbe", daemon=True
                        )
                        self._core_deck_probe_worker.start()
                    self._core_deck_probe_at = time.monotonic()
                    self._core_deck_probe_done.clear()
                    self._core_deck_probe_wake.set()
            if wait:
                self._core_deck_probe_done.wait(2.0)

        def _core_deck_keymap_document(self, serial: str | None) -> dict[str, Any]:
            facts = core_deck.keymap_facts(self._core_deck_backup_path(serial))
            return {"state": facts.state, "backup_at": facts.backup_at, "generation": self._core_deck_keymap_generation}

        @staticmethod
        def _core_deck_backup_path(serial: str | None):
            if not serial:
                return None
            from .creator_micro_setup import device_backup_key
            from .integration_settings import default_integration_settings_path

            try:
                return default_integration_settings_path().parent / f"creator-micro-keymap-{device_backup_key(serial)}.json"
            except ValueError:
                return None

        def _core_deck_document(self, sessions: list[dict[str, Any]]) -> dict[str, Any]:
            from .creator_micro_lighting import CreatorMicroBrightnessProfile
            from .deck_control_center import refresh_deck_board
            from .deck_session_board import session_identity

            try:
                snapshot = refresh_deck_board(self)
            except Exception as exc:
                legacy.log_status_bar(f"core: deck board unavailable: {exc.__class__.__name__}")
                snapshot = self._core_deck_board().snapshot()
            controls = getattr(self, "_deck_control_settings", None)
            effective = controls.effective_bindings() if controls is not None else ()
            bindings = {index: action.kind for index, action in effective}
            control_labels = dict(getattr(self, "_deck_control_labels", ()) or ())
            enabled, approved_serial = self._core_deck_integration()
            rows = self._core_deck_probe_rows()
            receipt = getattr(self, "_creator_micro_output_receipt", None)
            reason = str(getattr(receipt, "reason", "") or "")
            service_connected = bool(getattr(receipt, "available", False)) or reason in (
                "device_conflict",
                "per_key_output_unsupported",
                "unsupported_firmware",
            )
            serial = approved_serial
            if serial is None and rows:
                serial = next((row.get("serial_number") for row in rows if isinstance(row.get("serial_number"), str)), None)
            row = next((row for row in rows if row.get("serial_number") == serial), None) if serial else None
            inspection = self._core_deck_inspection
            plan = inspection[1].plan if inspection is not None else None
            # The live position comes from the output owner's device.status
            # polls; until the pad has answered (or ever, without a service)
            # the inspected values are the honest ones.
            live_layer = getattr(self, "_deck_active_layer", None)
            live_profile = getattr(self, "_deck_active_profile", None)
            device = None
            if serial is not None or rows:
                device = core_deck.device_document(
                    serial=serial,
                    transport=core_deck.transport_word(row.get("bus_type")) if row else None,
                    connected=row is not None or service_connected,
                    approved=enabled and approved_serial is not None and serial == approved_serial,
                    layer=live_layer if live_layer is not None else (plan.observed_layer if plan is not None else None),
                    profile=live_profile if live_profile is not None else (plan.observed_profile if plan is not None else None),
                    conflict="foreign_responses" if reason == "device_conflict" else None,
                    receipt=self._core_deck_receipt,
                )
            labels = {row["id"]: row.get("label") for row in sessions if isinstance(row, dict) and row.get("id")}
            statuses = {}
            for status in self._core_deck_statuses():
                identity = session_identity(status)
                if identity is not None:
                    statuses[identity] = status
            slots = []
            for slot in snapshot.slots:
                status = statuses.get(slot.identity) if slot.identity else None
                slots.append(
                    core_deck.DeckSlotFacts(
                        index=slot.index,
                        identity=slot.identity,
                        session=status.agent_id if status is not None else None,
                        label=(labels.get(status.agent_id) or self._core_label(status)) if status is not None else None,
                        provider=status.provider if status is not None else None,
                        state=slot.state,
                        pinned=slot.pinned,
                        navigable=slot.navigable,
                    )
                )
            keymap = core_deck.keymap_facts(self._core_deck_backup_path(serial))
            layer_scopes = dict(getattr(controls, "layer_map", ()) or ())
            layer_owners = dict(getattr(controls, "layer_owners", ()) or ())
            layers = core_deck.keymap_layer_rows(
                plan.original_json if plan is not None else keymap.original_json,
                layer_scopes,
                layer_owners,
            )
            try:
                brightness = self.effective_brightness_for_device(CreatorMicroBrightnessProfile()) / 255.0
            except Exception:
                brightness = 0.4
            last = self._core_deck_last_input
            last_input = None
            if type(last) is tuple and len(last) == 3:
                last_input = {
                    "index": int(last[0]),
                    "kind": core_deck.input_kind(int(last[0]), str(last[1])),
                    "at": mono_to_epoch(last[2]),
                }
            colors = getattr(self.settings, "colors", None)
            return core_deck.build_deck_document(
                device=device,
                slots=slots,
                bank=snapshot.bank,
                bank_count=snapshot.bank_count,
                rail_edge=snapshot.rail_edge,
                keymap_state=core_deck.observed_keymap_state(plan, keymap.state),
                backup_at=keymap.backup_at,
                keymap_generation=self._core_deck_keymap_generation,
                layers=layers,
                input_check=bool(getattr(self, "_deck_input_check_active", False)),
                last_input=last_input,
                settings={
                    "enabled": bool(getattr(controls, "enabled", False)),
                    "session_mode": bool(getattr(controls, "session_mode", False)),
                    "analog_enabled": bool(getattr(controls, "analog_enabled", False)),
                    "bindings": [(index, action.kind) for index, action in getattr(controls, "bindings", ()) or ()],
                    "layer_map": list(layer_scopes.items()),
                    "scopes": list(getattr(controls, "scopes", ()) or ()),
                    "ownership": getattr(controls, "ownership", "yield"),
                    "layer_owners": list(layer_owners.items()),
                },
                bindings=bindings,
                control_labels=control_labels,
                colors=colors,
                brightness=brightness,
                driven=bool(getattr(receipt, "available", False)) and bool(getattr(controls, "session_mode", False)),
                scope=snapshot.scope,
                scopes=controls.all_scopes() if controls is not None else (),
            )

        # -- server plumbing ---------------------------------------------------

        def _core_legacy(self):
            return legacy

        def _core_log(self, message: str) -> None:
            legacy.log_status_bar(message)

        def _core_start_server(self) -> None:
            server = CoreServer(
                dispatch=self._core_dispatch,
                initial_documents=self._core_initial_documents,
                socket_path=self._core_socket_path or default_core_socket_path(),
                core_version=CORE_VERSION,
                on_client_change=self._core_client_change,
                log=legacy.log_status_bar,
            )
            server.start()
            self._core = server
            self._core_publish_settings()

        def _core_sync_serve_server(self) -> None:
            """Start/stop the loopback status endpoint to match settings.

            ``serve_enabled`` is the switch the Settings > Remote card
            writes; the token arrives in the daemon's environment (the app
            injects it at spawn), so an unsupervised ``jrbar core`` has no
            token and simply reports ``running: false``.
            """
            from .cli import SERVE_ACCESS_TOKEN_ENV

            enabled = bool(getattr(self.settings, "serve_enabled", False))
            token = os.environ.get(SERVE_ACCESS_TOKEN_ENV) or None
            server = getattr(self, "_core_serve_server", None)
            if not enabled or not token:
                if server is not None:
                    self._core_serve_server = None
                    # shutdown() deadlocks unless serve_forever is actually
                    # running -- the started event gates it (the test
                    # fixture's inert Thread never opens the loop).
                    try:
                        if self._core_serve_started.is_set():
                            server.shutdown()
                        server.server_close()
                    except Exception:
                        pass
                    legacy.log_status_bar("core: serve stopped")
                return
            if server is not None:
                return
            from .serve import SERVE_DEFAULT_PORT, create_serve_server

            try:
                port = int(os.environ.get("JRBAR_SERVE_PORT") or SERVE_DEFAULT_PORT)
            except ValueError:
                port = SERVE_DEFAULT_PORT
            try:
                server = create_serve_server(
                    port=port, status_access_token=token.encode("utf-8")
                )
            except OSError as error:
                legacy.log_status_bar(f"core: serve could not bind :{port}: {error}")
                return
            self._core_serve_server = server
            self._core_serve_started = threading.Event()

            def _serve_loop() -> None:
                self._core_serve_started.set()
                server.serve_forever(poll_interval=0.5)

            threading.Thread(target=_serve_loop, daemon=True, name="jrbar-serve").start()
            legacy.log_status_bar(
                f"core: serving status on http://127.0.0.1:{port}/status.json"
            )

        def _core_stop_server(self) -> None:
            drainer = self._core_pending_drainer
            self._core_pending_drainer = None
            if drainer is not None:
                drainer.stop()
            serve_server = getattr(self, "_core_serve_server", None)
            self._core_serve_server = None
            if serve_server is not None:
                try:
                    started = getattr(self, "_core_serve_started", None)
                    if started is not None and started.is_set():
                        serve_server.shutdown()
                    serve_server.server_close()
                except Exception:
                    pass
            for name in ("_core_housekeeping_timer", "_core_supervision_timer"):
                timer = getattr(self, name, None)
                setattr(self, name, None)
                if timer is not None:
                    timer.invalidate()
            server = self._core
            self._core = None
            if server is not None:
                server.stop()

        def _core_client_change(self, count: int) -> None:
            self.performSelectorOnMainThread_withObject_waitUntilDone_("coreClientsChanged:", int(count), False)

        def _core_submit_pending(self, request) -> object:
            from .hook_ingress import AppOwnedHookIngressProcessor

            processor = AppOwnedHookIngressProcessor(self.handle_hook_event_message)
            return processor(request)

        def _core_dispatch(self, name: str, args: dict[str, Any]) -> Any:
            spec = _MAIN_THREAD_COMMANDS.get(name)
            if spec is None:
                raise CommandError("unknown_command", f"no such command: {name}")
            if not spec.main_thread:
                return spec.handler(self, args)
            box = CoreCommandBox(name, args)
            self.performSelectorOnMainThread_withObject_waitUntilDone_("runCoreCommand:", box, True)
            if box.error is not None:
                raise box.error
            return box.result

        @objc.IBAction
        def runCoreCommand_(self, box):
            spec = _MAIN_THREAD_COMMANDS.get(box.name)
            try:
                if spec is None:
                    raise CommandError("unknown_command", f"no such command: {box.name}")
                box.result = spec.handler(self, box.args)
            except CommandError as error:
                box.error = error
            except Exception as error:
                legacy.log_status_bar(f"core: command {box.name} failed: {traceback.format_exc(limit=6)}")
                box.error = CommandError("internal", f"{error.__class__.__name__}: {error}"[:500])

        @objc.IBAction
        def runCoreCallable_(self, box):
            try:
                box.result = box.callable()
            except Exception as error:
                box.error = error

        def _core_on_main(self, callable_: Callable[[], Any]) -> Any:
            """Run ``callable_`` on the main thread from a socket thread.

            Only for the short critical sections of a ``main_thread=False``
            command -- the callable must not wait on the socket thread or
            the two threads deadlock each other.
            """
            box = CoreCallableBox(callable_)
            self.performSelectorOnMainThread_withObject_waitUntilDone_(
                "runCoreCallable:", box, True
            )
            if box.error is not None:
                raise box.error
            return box.result

        def _core_initial_documents(self):
            with self._core_lock:
                documents = dict(self._core_documents)
            return [documents[kind] for kind in ("state", "lights", "settings") if kind in documents]

        # -- publishing --------------------------------------------------------

        def _core_publish_state(self) -> None:
            if getattr(self, "_core_in_refresh", False):
                # Inside a refresh the tail publishes once; a mid-pipeline
                # request (DND, escalation) would only rebuild the same
                # projection.
                return
            server = getattr(self, "_core", None)
            if server is None:
                return
            try:
                document = self._core_build_state()
            except Exception:
                legacy.log_status_bar(f"core: state projection failed: {traceback.format_exc(limit=6)}")
                return
            with self._core_lock:
                previous = self._core_documents.get("state")
                if previous is not None and doc_significant_equal("state", previous, document):
                    return
                self._core_documents["state"] = document
            server.publish_state(document)
            self._core_note_frame(self._core_state_frame_times)
            self._core_publish_widget_snapshot(document)

        def _core_publish_widget_snapshot(self, document) -> None:
            """The desktop glance file: a redacted counts-and-tiles view a
            WidgetKit extension reads without holding the socket. Best
            effort — a disk hiccup must not stall the state pipeline."""
            try:
                from .widget_snapshot import write_widget_snapshot
                write_widget_snapshot(
                    document, default_state_dir(), now=time.time())
            except Exception:
                legacy.log_status_bar(
                    "core: widget snapshot write failed: "
                    + traceback.format_exc(limit=3))

        def _core_publish_lights(self) -> None:
            if getattr(self, "_core_in_refresh", False):
                return
            server = getattr(self, "_core", None)
            if server is None:
                return
            try:
                document = self._core_build_lights()
            except Exception:
                legacy.log_status_bar(f"core: lights projection failed: {traceback.format_exc(limit=6)}")
                return
            with self._core_lock:
                previous = self._core_documents.get("lights")
                if previous is not None and doc_significant_equal("lights", previous, document):
                    return
                self._core_documents["lights"] = document
            server.publish_lights(document)
            self._core_lights_generation += 1
            self._core_note_frame(self._core_lights_frame_times)

        def _core_note_frame(self, times: deque) -> None:
            """One broadcast stamp, pruned to the rolling 60 s window here so
            the deque stays bounded even when nobody ever calls ``doctor``."""
            now = time.monotonic()
            times.append(now)
            while times and times[0] < now - 60.0:
                times.popleft()

        def _core_publish_settings(self) -> None:
            server = getattr(self, "_core", None)
            settings = self.settings
            if server is None or settings is None:
                return
            try:
                document = build_settings_document(
                    settings.to_dict(),
                    generation=self._core_settings_generation,
                    read_only=self._core_read_only_settings(),
                )
            except Exception:
                legacy.log_status_bar(f"core: settings projection failed: {traceback.format_exc(limit=6)}")
                return
            with self._core_lock:
                self._core_documents["settings"] = document
            server.publish_settings(document)

        def _core_read_only_settings(self) -> dict[str, Any]:
            """The daemon's own facts the Settings window shows but never
            writes: today the cloud ingest bearer token's path."""
            from .cloud_ingest import default_token_path

            return {"cloud_ingest_token_path": str(default_token_path())}

        def _core_publish_event(self, kind: str, **fields: Any) -> None:
            server = getattr(self, "_core", None)
            if server is None:
                return
            document = {"kind": kind}
            document.update({key: value for key, value in fields.items() if value is not None})
            server.publish_event(document)

        def _core_after_settings_change(self, touched: list[str]) -> None:
            joined = " ".join(touched)
            try:
                if "closed_lid" in joined:
                    self.sync_closed_lid_awake()
                if "cloud_ingest" in joined:
                    self.start_cloud_ingest_server()
                if "transcript_monitoring" in joined:
                    self.reload_monitor()
                if "remote_peers" in joined and self.settings.remote_peers.enabled:
                    self.start_remote_peer_refresh()
                if "serve_enabled" in joined:
                    self._core_sync_serve_server()
                if "virtual_status_device" in joined or "screen_bar" in joined:
                    self.virtual_status_device.hide()
            except Exception as exc:
                legacy.log_status_bar(f"core: settings side effect failed: {exc}")
            self.refresh_(None)

        # -- facts -------------------------------------------------------------

        def _core_ask_statuses(self):
            projection = getattr(self, "current_attention_projection", None)
            if projection is None:
                return []
            try:
                return legacy.ask_statuses(projection, self.settings)
            except Exception:
                return []

        def _core_oldest_ask(self):
            tracked = getattr(self, "ask_blocked_by_agent", {}) or {}
            if not tracked:
                return None
            oldest_id = min(tracked, key=tracked.get)
            for status in self._core_ask_statuses():
                if status.agent_id == oldest_id:
                    return status
            return None

        @staticmethod
        def _core_label(status) -> str | None:
            if status is None:
                return None
            from .core_projection import strip_session_short_id

            return strip_session_short_id(status.display_name, status.session_id) or status.agent_id

        def _core_frontmost_bundle_id(self) -> str | None:
            try:
                application = NSWorkspace.sharedWorkspace().frontmostApplication()
                value = application.bundleIdentifier() if application is not None else None
            except Exception:
                return None
            return value.strip() if isinstance(value, str) and value.strip() else None

        def _core_session_bundle_ids(self, status) -> frozenset[str]:
            extras = self._core_extras_for(status)
            ids: set[str] = set()
            if extras is not None:
                for block in (extras.terminal, extras.origin):
                    bundle = (block or {}).get("bundle_id")
                    if isinstance(bundle, str) and bundle:
                        ids.add(bundle)
            return frozenset(ids)

        def _core_extras_for(self, status) -> SessionExtras | None:
            cached = self._core_extras.get(status.agent_id)
            if (
                cached is not None
                and time.monotonic() - cached[0] < EXTRAS_TTL_SECONDS
                and not self._core_extras_unsettled(cached[1], status)
            ):
                return cached[1]
            extras = self._core_lookup_extras(status)
            if len(self._core_extras) > 256:
                # Session ids never repeat, so the map would grow for the
                # daemon's uptime; a clear is cheaper than an eviction
                # policy for a cache this cheap to refill.
                self._core_extras.clear()
            self._core_extras[status.agent_id] = (time.monotonic(), extras)
            return extras

        @staticmethod
        def _core_extras_unsettled(extras: SessionExtras, status) -> bool:
            """Whether a cached answer of "the sweep ended this" is still
            worth re-reading.

            A one-shot CLI can exit before its own ``SessionEnd`` reaches the
            daemon, so the liveness sweep sometimes closes the record first
            and the provider's event upgrades it a moment later. Caching the
            first answer for a full ``EXTRAS_TTL_SECONDS`` would leave a
            finished run reading ``ended`` for half a minute before flipping
            to Done. Only a freshly-ended session with a terminal event on it
            is re-read, so a session that really was killed costs one small
            file read per refresh for a minute and then settles.
            """

            if extras.provider_ended is not False:
                return False
            if getattr(status, "event_name", None) not in END_EVENT_NAMES:
                return False
            updated_at = getattr(status, "updated_at", None)
            stamp = updated_at.timestamp() if hasattr(updated_at, "timestamp") else None
            return stamp is not None and time.time() - stamp < UNSETTLED_EXTRAS_SECONDS

        def _core_lookup_extras(self, status) -> SessionExtras:
            from .process_registry import SHARED_HOST_PROVIDERS, load_record, pid_exists

            pid = None
            record = None
            cwd = None
            name = None
            # None until the process registry actually answers: "no record"
            # must not read as "the process died".
            process_alive: bool | None = None
            # None until the record says how the session closed: ``hook`` is
            # the provider's own SessionEnd, anything else (``process_exited``,
            # ``pid_reused``) is the liveness sweep closing a session that
            # never said it was done.
            provider_ended: bool | None = None
            session_id = getattr(status, "session_id", None)
            if session_id:
                try:
                    record = load_record(status.provider, session_id)
                except Exception:
                    record = None
                shared_host = str(getattr(status, "provider", "")) in SHARED_HOST_PROVIDERS
                if record is not None:
                    cwd = record.cwd or None
                    if shared_host:
                        # The pid on file is the shared host's (``devin
                        # acp``), alive by design -- it can neither vouch
                        # for the session nor prove it dead, and it must
                        # not lend the row a terminal. Only the record's
                        # own end is session-level truth; liveness stays
                        # with the silence timer.
                        if record.ended_at_epoch is not None:
                            provider_ended = record.end_reason == "hook"
                        record = None
                    else:
                        alive = record.ended_at_epoch is None and pid_exists(record.pid)
                        process_alive = bool(alive)
                        if record.ended_at_epoch is not None:
                            provider_ended = record.end_reason == "hook"
                        if alive:
                            pid = record.pid
                name, cwd = self._core_session_title(status.provider, session_id, pid or (record.pid if record else None), cwd)
            origin_label = getattr(status, "origin", None)
            origin = origin_document(origin_label if isinstance(origin_label, str) else None)
            terminal = None
            if pid is not None:
                terminal = dict(self._core_terminal_for_pid(pid) or {})
                tty = self._core_tty_for_pid(pid)
                if tty:
                    terminal["tty"] = tty
                if not terminal:
                    terminal = None
            return SessionExtras(
                pid=pid,
                origin=origin,
                terminal=terminal,
                process_alive=process_alive,
                cwd=cwd,
                name=name,
                provider_ended=provider_ended,
            )

        def _core_session_title(self, provider: str, session_id: str, pid: int | None, cwd: str | None):
            """(name, cwd) from the provider's own session record: Claude's
            ``~/.claude/sessions/<pid>.json`` name, Codex's session index
            title; ``cwd`` is filled from the same file when the registry
            had none."""
            name = None
            try:
                if provider == "claude":
                    from .process_registry import claude_session_details

                    details = claude_session_details(session_id, pid)
                    if details:
                        name = details.get("name")
                        cwd = cwd or details.get("cwd")
                elif provider == "codex":
                    from ._collector_legacy import codex_session_title

                    name = codex_session_title(session_id)
            except Exception:
                name = None
            return name, cwd

        def _core_tty_for_pid(self, pid: int) -> str | None:
            from .process_registry import tty_and_start

            tty, started = tty_and_start(pid)
            if started is None:
                # No start time means the process is already gone or
                # unreadable; nothing safe to cache, and a reused pid
                # could inherit it.
                return tty
            key = (pid, started)
            if key in self._core_tty_by_pid:
                return self._core_tty_by_pid[key]
            if len(self._core_tty_by_pid) > 256:
                self._core_tty_by_pid.clear()
            self._core_tty_by_pid[key] = tty
            return tty

        def _core_terminal_for_pid(self, pid: int) -> dict[str, Any] | None:
            from .process_registry import list_processes

            terminal = None
            started = None
            try:
                table = list_processes()
                entry = table.get(pid)
                if entry is None:
                    return None
                started = entry.started_at_epoch
                key = (pid, started)
                if key in self._core_terminal_by_pid:
                    return self._core_terminal_by_pid[key]
                current = pid
                for _ in range(12):
                    entry = table.get(current)
                    if entry is None or current <= 1:
                        break
                    match = terminal_from_command(entry.command)
                    if match is not None:
                        terminal = {"app": match[0], "bundle_id": match[1]}
                        break
                    current = entry.ppid
            except Exception:
                return None
            if len(self._core_terminal_by_pid) > 256:
                self._core_terminal_by_pid.clear()
            self._core_terminal_by_pid[key] = terminal
            return terminal

        def _core_device_facts(self) -> tuple[DeviceFacts, ...]:
            from ._led_status_legacy import led_count_for_target

            facts: list[DeviceFacts] = []
            # Two different links, one field name -- which mechanism a row's
            # ``linked`` describes follows its ``kind``: the Screen Bar's is
            # its own setting (``link_screen_bar_to_hardware``, default on),
            # while a Pro or Dot reports whether the ``devices_linked`` link
            # is in effect for the pair -- which needs one of each connected.
            # Until the split a Dot's ``linked: true`` was claiming "the
            # Screen Bar follows the strip", a fact about a different device.
            bar_linked = bool(getattr(self.settings, "link_screen_bar_to_hardware", True))
            devices = self.status_bar_devices(remember=False)
            strip_connected = dot_connected = False
            for device in devices:
                if device.device_id == legacy.VIRTUAL_DEVICE_ID or not device.connected:
                    continue
                try:
                    if led_count_for_target(device.target) == 2:
                        dot_connected = True
                    else:
                        strip_connected = True
                except Exception:
                    continue
            pair_linked = bool(getattr(self.settings, "devices_linked", True)) and (
                strip_connected and dot_connected
            )
            for device in devices:
                if device.device_id == legacy.VIRTUAL_DEVICE_ID:
                    facts.append(
                        DeviceFacts(
                            id="screen-bar",
                            kind="screen_bar",
                            name=legacy.VIRTUAL_DEVICE_NAME,
                            leds=legacy.LED_COUNT,
                            enabled=bool(self.settings.virtual_status_device_enabled),
                            brightness=self._core_brightness_percent(device),
                            linked=bar_linked,
                        )
                    )
                    continue
                leds = led_count_for_target(device.target)
                facts.append(
                    DeviceFacts(
                        id=device.device_id,
                        kind="dot" if leds == 2 else "pro",
                        name=device.name,
                        path=str(device.root),
                        leds=leds,
                        connected=bool(device.connected),
                        brightness=self._core_brightness_percent(device),
                        # A row whose device is not connected is not linked
                        # to anything, whatever the pair's standing is.
                        linked=pair_linked and bool(device.connected),
                        last_write=self._core_hardware_anchor.get(device.device_id),
                        error=self.device_errors.get(device.device_id),
                    )
                )
            return tuple(facts)

        def _core_brightness_code(self, device) -> int | None:
            """The 0-255 ``brightness N`` the device's own policy drives it at."""
            try:
                return int(round(self.effective_brightness_for_device(device)))
            except Exception:
                return int(round(float(device.brightness))) if device.brightness is not None else None

        def _core_signal_brightness_code(self, device) -> int | None:
            """The 0-255 ``brightness N`` an admitted signal drives the device
            at: the plan that cuts through idle, sleep and night dims."""
            try:
                return int(round(self.effective_signal_brightness_for_device(device)))
            except Exception:
                return int(round(float(device.brightness))) if device.brightness is not None else None

        def _core_brightness_percent(self, device) -> int | None:
            code = self._core_brightness_code(device)
            return None if code is None else int(round(code / 255.0 * 100.0))

        def _core_acknowledged_keys(self):
            """The Clear Agents receipts that keep cleared rows off the list."""
            from .clear_agents import ClearAgentsState

            state = getattr(self, "clear_agents_state", None)
            if type(state) is not ClearAgentsState:
                return frozenset()
            return state.acknowledged_keys

        def _core_detected_agents(self) -> dict[str, bool]:
            """``{hook provider: the agent's CLI or app is on this Mac}``.

            The reviewed inventory markers (``installed_agent_inventory``)
            reduced to one flag per hook provider. Our own hook files
            (``LOCAL_HARNESS``) answer "are the hooks in", not "is the agent
            installed", so they never count. Cached for a minute: the scan
            is a few dozen lstats, but ``state`` rebuilds on every refresh
            and the answer does not move that fast.
            """
            now = time.monotonic()
            cached = getattr(self, "_core_detected_agents_cache", None)
            if (
                isinstance(cached, tuple)
                and len(cached) == 2
                and now - float(cached[0]) < DETECTED_AGENTS_TTL_SECONDS
            ):
                return dict(cached[1])
            try:
                from .installed_agent_inventory import (
                    collect_installed_agent_inventory,
                    default_inventory_roots,
                )
                from .installed_agents import (
                    InstalledSurfaceKind,
                    SurfacePresence,
                    installed_surface_registrations,
                )
                from .providers import HOOK_PROVIDERS

                result = collect_installed_agent_inventory(default_inventory_roots())
                present = {
                    observation.key
                    for observation in result.reduction.observations
                    if observation.presence is not SurfacePresence.ABSENT
                }
                detected: dict[str, bool] = {}
                for registration in installed_surface_registrations():
                    if registration.kind is InstalledSurfaceKind.LOCAL_HARNESS:
                        continue
                    provider = registration.provider_id
                    if provider not in HOOK_PROVIDERS:
                        # The inventory groups Google's surfaces under
                        # "google"; the hook provider is the surface's own
                        # name ("gemini-cli" -> "gemini").
                        provider = registration.surface_id.split("-", 1)[0]
                    if provider not in HOOK_PROVIDERS:
                        continue
                    if registration.key in present:
                        detected[provider] = True
                    else:
                        detected.setdefault(provider, False)
            except Exception:
                self._core_log(
                    f"core: agent detection failed: {traceback.format_exc(limit=3)}"
                )
                detected = dict(cached[1]) if isinstance(cached, tuple) and len(cached) == 2 else {}
            self._core_detected_agents_cache = (now, detected)
            return dict(detected)

        def _core_catalog_generation(self) -> int | None:
            """``state.catalog_generation``: the Effect Studio's reload cue.

            Content-derived (``core_effects.catalog_generation``), so a pack
            installed through the ``jrbar effects`` CLI while the daemon ran
            still moves it; the assignment cache's own revision folds in.
            """
            from . import core_effects

            cache = getattr(type(self), "_effect_assignment_cache", None)
            if cache is None:
                return None
            return int(
                core_effects.catalog_generation(
                    cache.registry(),
                    _effect_packs(self),
                    revision=cache.generation,
                )
            )

        def _core_snoozed_untils(self, statuses) -> dict[str, float]:
            """``agent_id`` -> the family mailbox's active ``snoozed_until``.

            Snooze lives on the family's mailbox preference, never on the
            session; the row reports it so the panel can show "Snoozed"
            and offer Unsnooze without a second document."""
            try:
                state = getattr(self, "current_operator_state", None)
                preferences = getattr(self, "mailbox_preferences", ()) or ()
                if state is None or not preferences:
                    return {}
                now = time.time()
                result: dict[str, float] = {}
                for status in statuses:
                    work_key = getattr(status, "work_key", None)
                    agent_id = str(getattr(status, "agent_id", "") or "")
                    if work_key is None or not agent_id:
                        continue
                    family = legacy._family_work_key(state, work_key)
                    if family is None:
                        continue
                    preference = legacy._preference_for_work_key(preferences, family)
                    until = getattr(preference, "snoozed_until", None) if preference is not None else None
                    if until is not None and float(until) > now:
                        result[agent_id] = float(until)
                return result
            except Exception:
                return {}

        def _core_build_state(self) -> dict[str, Any]:
            from .lid_sleep import sleep_helper_installed

            self._core_state_generation += 1
            snapshot = getattr(self, "last_snapshot", None)
            ask_statuses = self._core_ask_statuses()
            try:
                unseen = frozenset(status.agent_id for status in legacy.unseen_completions(snapshot, self)) if snapshot else frozenset()
            except Exception:
                unseen = frozenset()
            extras: dict[str, SessionExtras] = {}
            if snapshot is not None:
                statuses = [*snapshot.statuses, *getattr(snapshot, "stale_statuses", ())]
                now = time.monotonic()
                # Live sessions first; a stale row still deserves its registry
                # cwd and title (one file read: its process is gone, so no ps).
                ordered = [status.agent_id for status in statuses if not status.stale]
                ordered += [status.agent_id for status in statuses if status.stale]
                planned = set(
                    plan_extra_lookups(
                        ordered,
                        self._core_extras,
                        now=now,
                        ttl=EXTRAS_TTL_SECONDS,
                        budget=MAX_EXTRA_LOOKUPS_PER_BUILD,
                    )
                )
                for status in statuses:
                    cached = self._core_extras.get(status.agent_id)
                    if status.agent_id in planned:
                        extras[status.agent_id] = self._core_extras_for(status)
                    elif cached is not None:
                        extras[status.agent_id] = cached[1]
            try:
                intake = self.refresh_intake_report()
            except Exception:
                intake = getattr(self, "current_intake_report", None)
            try:
                helper = sleep_helper_installed()
            except Exception:
                helper = False
            wall_now = time.time()
            usage_state = getattr(self, "provider_usage_state", None)
            samples = self._core_usage_samples
            try:
                samples.record_state(usage_state, now=wall_now)
                samples.save_if_due()
            except Exception:
                legacy.log_status_bar(f"core: usage samples failed: {traceback.format_exc(limit=3)}")
            try:
                detected_agents = self._core_detected_agents()
            except Exception:
                detected_agents = None
            try:
                catalog_generation = self._core_catalog_generation()
            except Exception:
                catalog_generation = None
            document = build_state_document(
                now=wall_now,
                generation=self._core_state_generation,
                snapshot=snapshot,
                ask_statuses=ask_statuses,
                unseen_completion_ids=unseen,
                operator_state=getattr(self, "current_operator_state", None),
                devices=self._core_device_facts(),
                usage_state=usage_state,
                usage_samples=samples,
                power=PowerFacts(
                    keep_awake=bool(getattr(self.keep_awake, "holding_requested", False)),
                    closed_lid_policy=str(self.settings.closed_lid_awake_policy),
                    closed_lid_holding=bool(self.closed_lid_awake.active()),
                    helper_installed=bool(helper),
                ),
                dnd_projection=self.current_dnd_projection(),
                escalation=EscalationFacts(
                    stage=int(self.current_escalation_stage()),
                    since=mono_to_epoch(getattr(self, "ask_blocked_since", None)),
                ),
                intake_report=intake,
                settings_generation=self._core_settings_generation,
                extras_by_id=extras,
                acknowledged_keys=self._core_acknowledged_keys(),
                snoozed_until_by_id=self._core_snoozed_untils(
                    [*snapshot.statuses, *getattr(snapshot, "stale_statuses", ())] if snapshot else ()
                ),
                dnd_override_until=getattr(self.settings, "dnd_override_until_epoch", None),
                answer_contracts=getattr(self, "_answer_contracts_by_source", None),
                has_answer_handler=getattr(
                    getattr(self, "answer_handler_registry", None), "has_handler", None
                ),
                detected_agents=detected_agents,
                catalog_generation=catalog_generation,
            )
            try:
                document["deck"] = self._core_deck_document(document["sessions"])
            except Exception:
                legacy.log_status_bar(f"core: deck projection failed: {traceback.format_exc(limit=6)}")
            try:
                # Peer fleet facts, not projections: who was reachable at the
                # last refresh and how many rows they published. ``peers`` is
                # absent (not empty) while the feature is off.
                if self.settings.remote_peers.enabled:
                    refresh = getattr(self, "_remote_refresh", None)
                    health = tuple(getattr(refresh, "health", ()) or ())
                    if health:
                        document["peers"] = [
                            {
                                "machine": peer.machine,
                                "host": peer.host,
                                "reachable": bool(peer.reachable),
                                "rows": int(getattr(peer, "row_count", 0) or 0),
                                **({"failure": peer.failure} if getattr(peer, "failure", None) else {}),
                            }
                            for peer in health
                        ]
            except Exception:
                legacy.log_status_bar(f"core: peers projection failed: {traceback.format_exc(limit=6)}")
            try:
                from . import core_power

                core_power.augment_power_document(self, document)
                core_power.augment_presence_document(self, document, now=wall_now)
            except Exception:
                legacy.log_status_bar(f"core: power projection failed: {traceback.format_exc(limit=6)}")
            try:
                from . import core_lights

                core_lights.augment_device_health(document)
            except Exception:
                legacy.log_status_bar(f"core: write health failed: {traceback.format_exc(limit=3)}")
            return document

        def _core_light_facts(self, device, *, preview: bool, display_kind: str | None) -> LightFacts:
            """The dimming and DND facts behind one surface's ``why``."""
            dimming: list[str] = []
            factor: float | None = None
            try:
                plan = self.ambient_brightness_plan_for_device(device) if device is not None else None
            except Exception:
                plan = None
            if plan is not None:
                product = 1.0
                for step in getattr(plan, "trace", ()) or ():
                    word = {"idle_dim": "idle_dim", "sleep_dim": "sleep", "dnd_dim": "quiet", "night_dim": "auto_dim"}.get(
                        getattr(step, "name", "")
                    )
                    step_factor = getattr(step, "factor", None)
                    if word is None or step_factor is None:
                        continue
                    if float(step_factor) < 1.0:
                        dimming.append(word)
                        product *= float(step_factor)
                factor = round(product, 3)
            try:
                dnd = self.current_dnd_projection()
            except Exception:
                dnd = None
            admission = getattr(getattr(dnd, "display_admission", None), "value", None)
            return LightFacts(
                display_kind=display_kind,
                preview=preview,
                dnd_display_admission=admission,
                dnd_brightness_factor=getattr(dnd, "brightness_factor", None),
                dimming=tuple(dimming),
                brightness_factor=factor,
            )

        def _core_why_detail(self, why: str, facts: LightFacts, glance) -> dict[str, Any]:
            with self._core_lock:
                state = self._core_documents.get("state") or {}
            return why_detail(
                why,
                sessions=state.get("sessions") or [],
                asks=state.get("asks") or [],
                unseen_completion_ids=tuple(state.get("unseen_completions") or ()),
                now=time.time(),
                # The glance's ``relay_epoch`` is a monotonic reading; it is
                # only a duration against a monotonic "now".
                monotonic_now=time.monotonic(),
                facts=facts,
                glance=glance,
            )

        def _core_build_lights(self) -> dict[str, Any]:
            from ._led_status_legacy import delivered_brightness, led_count_for_target
            from .colors import lift_program_luminance
            from .dot_role import apply_brightness_line, normalize_dot_role, upsample_program
            from .presentation_policy import MotionClass

            glance = getattr(self, "_current_resolved_glance", None)
            _why, override = why_for_glance(glance)
            linked = bool(getattr(self.settings, "link_screen_bar_to_hardware", True))
            devices_linked = bool(getattr(self.settings, "devices_linked", True))
            dot_role = normalize_dot_role(getattr(self.settings, "dot_role", None))
            # ``screen_bar_phase_offset_ms`` in seconds: the fixed nudge
            # between the Screen Bar and a linked strip, positive holding
            # the bar's t=0 back behind the strip's write.
            bar_phase_offset = float(
                getattr(self.settings, "screen_bar_phase_offset_ms", 0.0) or 0.0
            ) / 1000.0
            surfaces: dict[str, SurfaceFacts] = {}
            hardware_anchor: float | None = None
            # The program a LINKED Screen Bar presents: what the followed
            # strip was asked to play. Set alongside the ``hardware``
            # surface below.
            hardware_mirror_program: str | None = None
            # Beside each mirror program: the device that plays it and the
            # display kind it renders, which decide the bar's ``brightness
            # N`` below. A preview carries no kind -- it plays at the
            # device's ambient brightness.
            hardware_mirror_source: tuple[Any, str | None] | None = None
            # The lone-Dot mirror source: with no strip mounted the bar can
            # still follow hardware -- the Dot's program, widened 2 -> 8.
            dot_anchor: float | None = None
            dot_mirror_program: str | None = None
            dot_mirror_source: tuple[Any, str | None] | None = None
            first_strip = True
            # Connectivity, tracked apart from surfaces: a connected device
            # with no program yet has no surface, but ``dot_link`` still has
            # to call it connected.
            dot_connected = strip_connected = False
            display_kinds = getattr(self, "last_led_display_kind_by_device", {}) or {}
            # One device list per build -- each call re-sorts and re-reads
            # per-device settings, and this build used to ask twice.
            devices = self.status_bar_devices(remember=False)
            for device in devices:
                if device.device_id == legacy.VIRTUAL_DEVICE_ID or not device.connected:
                    continue
                leds = led_count_for_target(device.target)
                if leds == 2:
                    dot_connected = True
                else:
                    strip_connected = True
                controller = self.agent_led_controllers_by_device.get(device.device_id)
                program = getattr(controller, "last_program", None)
                if not isinstance(program, str) or not program:
                    continue
                anchor = self._core_hardware_anchor.get(device.device_id)
                preview = self._core_previews.get("hardware" if leds != 2 else "dot") or self._core_previews.get(device.device_id)
                previewing = preview is not None and device.device_id in preview.device_ids
                if previewing:
                    program, anchor = preview.program, preview.started_epoch
                # The recorded display kind is only rewritten on a
                # successful sync; a missed write leaves it frozen at a
                # long-finished claim (a quota alert reported "capacity"
                # for three hours after its blink had ended). Transient
                # claims are time-windowed, so a recorded kind whose
                # window passed cannot be what the strip is still
                # playing -- report the glance instead of the corpse.
                recorded_kind = display_kinds.get(device.device_id)
                deadline_field = _TRANSIENT_KIND_DEADLINE.get(recorded_kind or "")
                if deadline_field is not None and (
                    time.monotonic()
                    > float(getattr(self, deadline_field, 0.0) or 0.0)
                ):
                    recorded_kind = None
                facts = self._core_light_facts(
                    device, preview=previewing, display_kind=recorded_kind
                )
                surface_why = light_why(glance, facts)
                name = "dot" if leds == 2 else ("hardware" if first_strip else f"hardware:{device.device_id}")
                if leds != 2 and first_strip:
                    first_strip = False
                    hardware_anchor = anchor
                    # NOMINAL, not the surface's written bytes: last_program
                    # has already been through the strip's write boundary
                    # (die gains, the light-domain brightness decode), and
                    # replaying those bytes on the Screen Bar would wear a
                    # calibration the display does not have -- the linked
                    # Dot replays the nominal text for the same reason
                    # (_core_note_hardware_write). Under a preview the
                    # surface entry IS the program, and it is what the
                    # strip is actually showing.
                    hardware_mirror_program = (
                        program
                        if previewing
                        else getattr(controller, "last_nominal_program", None) or program
                    )
                    hardware_mirror_source = (device, None if previewing else recorded_kind)
                if leds == 2:
                    # Same rule as the strip: the NOMINAL text, not the
                    # written bytes, for the lone-Dot mirror below.
                    dot_anchor = anchor
                    dot_mirror_program = (
                        program
                        if previewing
                        else getattr(controller, "last_nominal_program", None) or program
                    )
                    dot_mirror_source = (device, None if previewing else recorded_kind)
                surfaces[name] = SurfaceFacts(
                    program=program,
                    led_count=leds,
                    anchor=anchor,
                    motion=None,
                    static_fallback=None,
                    # What the DEVICE receives, not what the policy asked
                    # for. The two had drifted by 2.2x on the Dot -- the
                    # document said 0.51 beside a strip being driven at 0.23
                    # -- and the surface with the drift is the one the owner
                    # was told was broken.
                    brightness=delivered_brightness(program),
                    brightness_policy=(self._core_brightness_percent(device) or 0) / 100.0,
                    why=surface_why,
                    override=override,
                    why_detail=self._core_why_detail(surface_why, facts, glance),
                )
            if "dot" in surfaces and surfaces["dot"].why != "preview":
                # The Dot's ROLE outranks its per-device display kind. That
                # kind is recorded by the render path the role took away, so
                # on a role-driven Dot it is frozen at whatever it was the
                # last time the Dot rendered for itself -- which is how a
                # long-finished quota alert kept the Dot's ``why`` at
                # ``capacity`` beside a strip that said ``working``.
                dot = surfaces["dot"]
                dot_plan = self._core_dot_plan()
                # Linked Pro + Dot also share an anchor, so the app reads the
                # two as one unit (core_runtime linked writes) -- but only a
                # coupled batch that landed clean earns the shared stamp. A
                # batch that went out uncoupled or failed leaves the Dot its
                # own anchor rather than claiming a sync nobody measured.
                anchor = (
                    hardware_anchor
                    if devices_linked
                    and "hardware" in surfaces
                    and hardware_anchor is not None
                    and self._core_linked_pair_ok
                    else dot.anchor
                )
                why = dot_plan.why if dot_plan is not None else dot.why
                surfaces["dot"] = SurfaceFacts(
                    program=dot.program,
                    led_count=dot.led_count,
                    anchor=anchor,
                    brightness=dot.brightness,
                    brightness_policy=dot.brightness_policy,
                    why=why,
                    override=dot.override,
                    role=dot_plan.role if dot_plan is not None else None,
                    why_detail=(
                        self._core_why_detail(
                            why,
                            self._core_light_facts(None, preview=False, display_kind=None),
                            glance,
                        )
                        if dot_plan is not None
                        else dot.why_detail
                    ),
                )
            # What a linked bar mirrors: the followed strip when one is
            # mounted, else a lone Dot -- its two-LED program widened to the
            # bar's ``legacy.LED_COUNT``, since the bar compiles at eight and
            # a 2-LED text would leave six of them dark. Never ``asks``: the
            # beacon is deliberately dark until someone is needed, and the
            # bar must not mirror that darkness -- it keeps its own render.
            mirror = surfaces.get("hardware")
            mirror_anchor = hardware_anchor
            mirror_program = hardware_mirror_program
            mirror_source = hardware_mirror_source
            if mirror is None and "dot" in surfaces and dot_role not in ("asks", "call"):
                widened = upsample_program(
                    dot_mirror_program or surfaces["dot"].program,
                    source_leds=2,
                    led_count=legacy.LED_COUNT,
                )
                if widened is not None:
                    mirror = surfaces["dot"]
                    mirror_anchor = dot_anchor
                    mirror_program = widened
                    mirror_source = dot_mirror_source
            virtual = self.virtual_status_device
            call = getattr(virtual, "_live_program_call", None)
            virtual_device = next(
                (d for d in devices if d.device_id == legacy.VIRTUAL_DEVICE_ID),
                None,
            )
            # A linked bar plays the mirrored program at the bar's OWN
            # ``brightness N`` (``mirror_code``), never the strip's. The
            # strip's ambient N starts from the display backlight (auto
            # brightness) and the display then dims the bar by that
            # backlight again: dimmed twice, the band measured Y~0.058,
            # brown beside full-bright UI (2026-09-22). The bar's ambient
            # plan (``bar_code``) keeps every user-intent dim (idle, sleep,
            # DND, night) and its ``screen_bar_min_glow`` floor, and the
            # bar's own auto brightness is off unless the owner turns it on.
            # N scales the whole program: timing, phase and ``off`` beats
            # are untouched, so a dark beat stays dark.
            if virtual_device is not None:
                bar_code = self._core_brightness_code(virtual_device) or 0
                bar_brightness = int(round(bar_code / 255.0 * 100.0)) / 100.0
            else:
                bar_code = self.settings.brightness_for_device(legacy.VIRTUAL_DEVICE_ID)
                bar_brightness = bar_code / 255.0
            mirror_code = bar_code
            mirror_device, mirror_kind = mirror_source or (None, None)
            if (
                linked
                and mirror is not None
                and mirror_device is not None
                and mirror_kind is not None
                and mirror_kind
                not in (
                    legacy.LED_DISPLAY_AGENT,
                    legacy.LED_DISPLAY_BATTERY,
                    legacy.LED_DISPLAY_STUDIO,
                    legacy.LED_DISPLAY_QUOTA_RUNWAY,
                )
            ):
                # Only those four kinds render at the ambient plan. A signal
                # (completion, failure, calendar...) renders at the SIGNAL
                # plan -- no backlight term, cutting through idle, sleep and
                # night dims -- times its style's intensity, the way the
                # bar's own render does (status_bar_legacy
                # ``_sync_hardware_device``). The ambient code played an
                # idle-time completion at ~25% beside a full-bright strip.
                # The mirrored N over the strip's signal plan is that
                # intensity, the one term the two plans do not share.
                source_plan = self._core_signal_brightness_code(mirror_device) or 0
                played = delivered_brightness(mirror_program or mirror.program) * 255.0
                intensity = min(1.0, played / source_plan) if source_plan > 0 else 1.0
                bar_signal = (
                    self._core_signal_brightness_code(virtual_device)
                    if virtual_device is not None
                    else None
                )
                mirror_code = int(round((bar_code if bar_signal is None else bar_signal) * intensity))
            preview = self._core_previews.get("screen_bar")
            bar_facts = self._core_light_facts(
                virtual_device, preview=preview is not None, display_kind=display_kinds.get(legacy.VIRTUAL_DEVICE_ID)
            )
            bar_why = light_why(glance, bar_facts)
            if preview is not None:
                surfaces["screen_bar"] = SurfaceFacts(
                    program=preview.program,
                    led_count=legacy.LED_COUNT,
                    anchor=preview.started_epoch,
                    motion="continuous",
                    static_fallback="off",
                    brightness=bar_brightness,
                    why="preview",
                    why_detail=self._core_why_detail("preview", bar_facts, glance),
                )
            elif call is not None:
                program, kwargs = call
                motion = kwargs.get("motion")
                anchor = mono_to_epoch(kwargs.get("started_at"))
                anchor = screen_bar_anchor(anchor, mirror_anchor, linked=linked)
                if linked and mirror_anchor is not None:
                    anchor = mirror_anchor + bar_phase_offset
                if linked and mirror is not None:
                    # Linked means the bar FOLLOWS the mirrored device: its
                    # own program on its own anchor -- a lone Dot's widened
                    # to the bar's eight -- not the virtual render's
                    # re-reading of the same state. The two renderers draw
                    # from different palettes, which is how one anchor once
                    # carried two programs that read as "blink different".
                    # The lift is legibility only: codes the device can show
                    # as faint light read as "off" on a display.
                    mirrored = apply_brightness_line(
                        lift_program_luminance(mirror_program or mirror.program),
                        mirror_code,
                    )
                    surfaces["screen_bar"] = SurfaceFacts(
                        program=mirrored,
                        led_count=legacy.LED_COUNT,
                        anchor=anchor,
                        # What the mirrored program drives the bar at: the
                        # bar's own ``brightness N`` (see ``mirror_code``).
                        brightness=delivered_brightness(mirrored),
                        brightness_policy=bar_brightness,
                        why=mirror.why,
                        override=override,
                        why_detail=mirror.why_detail,
                    )
                else:
                    surfaces["screen_bar"] = SurfaceFacts(
                        program=str(program),
                        led_count=legacy.LED_COUNT,
                        anchor=anchor,
                        motion=motion.value if isinstance(motion, MotionClass) else None,
                        static_fallback=kwargs.get("static_fallback_program"),
                        brightness=bar_brightness,
                        why=bar_why,
                        override=override,
                        why_detail=self._core_why_detail(bar_why, bar_facts, glance),
                    )
            elif linked and mirror is not None:
                # The bar only mirrors the device while the two are linked;
                # unlinked and idle, it has no program of its own to claim.
                mirrored = apply_brightness_line(
                    lift_program_luminance(mirror_program or mirror.program),
                    mirror_code,
                )
                surfaces["screen_bar"] = SurfaceFacts(
                    program=mirrored,
                    led_count=legacy.LED_COUNT,
                    anchor=(
                        mirror_anchor + bar_phase_offset
                        if mirror_anchor is not None
                        else None
                    ),
                    # Same rule as the live-call branch above: the bar's own
                    # ``brightness N``, not the mirrored device's.
                    brightness=delivered_brightness(mirrored),
                    brightness_policy=bar_brightness,
                    why=mirror.why,
                    override=override,
                    why_detail=mirror.why_detail,
                )
            try:
                auto_dim = self.auto_dim_result().to_dict()
            except Exception:
                auto_dim = None
            document = build_lights_document(
                surfaces,
                linked=linked,
                devices_linked=devices_linked and "dot" in surfaces and "hardware" in surfaces,
                dot_link=self._core_dot_link(dot_connected, strip_connected, dot_role),
                auto_dim=auto_dim,
            )
            # The skew and its measurement instant travel together: a reader
            # shown only the number could not tell a fresh 11 ms from one
            # measured before the strip was last unplugged.
            if (
                document.get("devices_linked")
                and self._core_linked_skew_ms is not None
                and self._core_linked_skew_at is not None
            ):
                document["linked_skew_ms"] = self._core_linked_skew_ms
                document["linked_skew_at"] = self._core_linked_skew_at
                if self._core_linked_corrected_ms is not None:
                    document["linked_skew_corrected_ms"] = self._core_linked_corrected_ms
            try:
                from . import core_lights

                core_lights.augment_lights_cues(self, document)
            except Exception:
                legacy.log_status_bar(f"core: cue naming failed: {traceback.format_exc(limit=3)}")
            return document

        def _core_dot_link(self, dot_connected: bool, strip_connected: bool, dot_role: str) -> dict[str, Any]:
            """The ``lights.dot_link`` row: one honest word for what the
            Pro + Dot link is doing right now.

            The words a settings toggle cannot say on its own -- the strip
            is gone, the last coupled write failed -- used to be guesswork
            the app did from ``devices_linked`` and the surface list. The
            ``role`` echoes the normalized setting (``null`` only when no
            role is in play at all: the link off or no Dot connected), and
            ``error`` carries a short description of the last linked-write
            failure -- the exception class name, or the write's own error.
            """
            from .dot_role import DotRole

            if not bool(getattr(self.settings, "devices_linked", True)):
                return {"state": "off", "role": None, "error": None}
            if not dot_connected:
                return {"state": "no_dot", "role": None, "error": None}
            if dot_role in (DotRole.ASKS.value, DotRole.CALL.value):
                # A beacon needs no strip: it is lit by asks (and, for the
                # ``call`` role, by a call), not by light borrowed from the Pro.
                return {"state": "beacon", "role": dot_role, "error": None}
            if dot_role == DotRole.STATUS.value:
                return {"state": "solo", "role": dot_role, "error": None}
            if not strip_connected:
                return {"state": "no_strip", "role": dot_role, "error": None}
            if self._core_linked_dot_error is not None:
                return {"state": "failed", "role": dot_role, "error": self._core_linked_dot_error}
            # The steady state: extend with both devices connected is
            # "linked" the moment the next batch couples them -- the shared
            # anchor is the claim that waits for a clean coupled write, the
            # state word is not.
            return {"state": "linked", "role": dot_role, "error": None}

        def _core_doctor_document(self) -> dict[str, Any]:
            from .doctor import collect_diagnostics
            from .install import hook_shim_path
            from .memory_probe import memory_report

            checks: list[dict[str, Any]] = []
            try:
                result = collect_diagnostics()
                for finding in result.findings:
                    healthy = finding.code.value in _HEALTHY_DIAGNOSTIC_CODES
                    if finding.check.value in _APP_OWNED_DIAGNOSTICS:
                        # Alcove following is the app's job now; the daemon
                        # not running it is the design, not a fault.
                        healthy = True
                    checks.append(
                        {
                            "name": finding.check.value,
                            "ok": healthy,
                            "detail": f"{finding.code.value} ({finding.count}/{finding.limit})",
                        }
                    )
            except Exception as exc:
                checks.append({"name": "diagnostics", "ok": False, "detail": f"unavailable: {exc.__class__.__name__}"})
            shim = hook_shim_path()
            checks.append(
                {
                    "name": "hook shim",
                    "ok": shim is not None,
                    "detail": str(shim) if shim is not None else "python -m jrbar.hook_client",
                }
            )
            pending = pending_hook_files()
            orphaned = orphaned_drain_files()
            backlog = 0
            for path in pending:
                try:
                    backlog += sum(1 for line in path.read_text(
                        encoding="utf-8", errors="replace").splitlines() if line.strip())
                except OSError:
                    backlog = -1
                    break
            detail = f"{len(pending)} files"
            if backlog >= 0:
                detail += f", {backlog} lines"
            if orphaned:
                detail += f", {len(orphaned)} stranded mid-drain"
            checks.append({
                "name": "pending hook lines",
                "ok": not pending and not orphaned,
                "detail": detail,
            })
            try:
                performance = self._core_performance_document()
            except Exception:
                performance = {
                    "metrics": {},
                    "cpu": {"user_s": None, "system_s": None, "percent_since_last": None},
                    "frames": {
                        "state_generation": self._core_state_generation,
                        "lights_generation": self._core_lights_generation,
                        "state_per_minute": 0,
                        "lights_per_minute": 0,
                    },
                }
            server = self._core
            with self._core_lock:
                state = self._core_documents.get("state") or {}
            hooks = ((state.get("health") or {}).get("hooks")) or {}
            devices = {device.get("id"): ("connected" if device.get("connected", device.get("enabled")) else "absent") for device in state.get("devices") or []}
            deck_device = (state.get("deck") or {}).get("device")
            if deck_device:
                devices["creator-micro"] = "connected" if deck_device.get("connected") else "absent"
            return {
                "ok": all(check["ok"] for check in checks),
                "core_version": CORE_VERSION,
                "commit": _running_commit(),
                "python": sys.executable,
                "pid": os.getpid(),
                "socket": str(server.socket_path) if server is not None else None,
                "uptime_seconds": round(time.time() - self._core_started_at, 1),
                "clients": server.client_count if server is not None else 0,
                "hooks": hooks,
                "devices": devices,
                "settings_generation": self._core_settings_generation,
                "state_generation": self._core_state_generation,
                "commands": list(command_names()),
                "checks": checks,
                "memory": memory_report(),
                "performance": performance,
            }

        def _core_performance_document(self) -> dict[str, Any]:
            """The timings, CPU and frame counters behind ``doctor``.

            ``metrics`` is the production ``PerformanceRegistry`` (the same
            numbers the legacy Why panel renders). ``percent_since_last`` is
            CPU consumed between doctor calls: ``null`` on the first call,
            which has nothing to divide by. ``frames`` counts state/lights
            documents actually broadcast, per-minute over a rolling 60 s
            window of publish stamps.
            """
            import resource

            metrics: dict[str, Any] = {}
            performance = getattr(self, "_performance", None)
            if callable(performance):
                for metric in performance().snapshot().metrics:
                    metrics[metric.name] = {
                        "count": metric.count,
                        "p50_ms": round(metric.p50_ms, 3),
                        "p95_ms": round(metric.p95_ms, 3),
                        "max_ms": round(metric.maximum_ms, 3),
                        "outcomes": dict(metric.outcomes),
                    }
            usage = resource.getrusage(resource.RUSAGE_SELF)
            user_s, system_s = usage.ru_utime, usage.ru_stime
            now = time.monotonic()
            percent = None
            if self._core_doctor_rusage is not None and self._core_doctor_at is not None:
                wall = now - self._core_doctor_at
                if wall > 0:
                    cpu_used = (user_s - self._core_doctor_rusage[0]) + (system_s - self._core_doctor_rusage[1])
                    percent = cpu_used / wall * 100.0
            self._core_doctor_rusage = (user_s, system_s)
            self._core_doctor_at = now
            cutoff = now - 60.0
            for times in (self._core_state_frame_times, self._core_lights_frame_times):
                while times and times[0] < cutoff:
                    times.popleft()
            return {
                "metrics": metrics,
                "cpu": {
                    "user_s": round(user_s, 3),
                    "system_s": round(system_s, 3),
                    "percent_since_last": round(percent, 1) if percent is not None else None,
                },
                "frames": {
                    "state_generation": self._core_state_generation,
                    "lights_generation": self._core_lights_generation,
                    "state_per_minute": len(self._core_state_frame_times),
                    "lights_per_minute": len(self._core_lights_frame_times),
                },
            }

    _CLASS_CACHE[base] = JRCoreHeadlessController
    return JRCoreHeadlessController


# --- entry point ------------------------------------------------------------


def _install_log_mirror(get_server: Callable[[], CoreServer | None]) -> None:
    from . import status_bar_legacy as legacy

    original = legacy.log_status_bar

    def log_status_bar(message: str) -> None:
        original(message)
        server = get_server()
        if server is not None:
            try:
                server.publish_log(str(message))
            except Exception:
                pass

    legacy.log_status_bar = log_status_bar


def build_core_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(prog="jrbar core", description="Run the JR-Bar core daemon (headless).")
    parser.add_argument("--socket", default=None, help="core socket path (default: ~/.local/state/jrbar/core.sock)")
    return parser


def run_core(argv: list[str] | None = None) -> int:
    args = build_core_parser().parse_args(argv)
    from . import status_bar_legacy as legacy_module
    from .ipc import another_instance_alive
    from .memory_probe import start_if_requested

    # JRBAR_STACK_DUMPS=1: `kill -USR1 <core pid>` appends every Python
    # thread's stack to core-stacks.log — the one way to name a CPU burst
    # from outside on a machine where py-spy needs root. Opt-in: a
    # signal landing mid-syscall took the daemon down once (2026-09-16),
    # so it is never armed on a production launch.
    if os.environ.get("JRBAR_STACK_DUMPS") == "1":
        try:
            import faulthandler

            from .state_paths import default_state_dir

            stacks = open(default_state_dir() / "core-stacks.log", "a", buffering=1)
            faulthandler.register(signal.SIGUSR1, file=stacks, all_threads=True, chain=False)
        except (ImportError, AttributeError, RuntimeError, ValueError, OSError):
            pass

    # Crash breadcrumbs: a fatal fault (a segfault inside a pyobjc bridge,
    # an abort) writes every Python thread's stack to core-crash.log in the
    # state dir before the process dies. ``faulthandler.enable`` fires only
    # on fatal signals -- unlike the opt-in SIGUSR1 dump above, it can never
    # interrupt a healthy syscall.
    try:
        import faulthandler

        from .state_paths import default_state_dir

        crash_log = default_state_dir() / "core-crash.log"
        # Crash loops would grow the file forever; keep the tail.
        try:
            if crash_log.stat().st_size > 1024 * 1024:
                crash_log.write_bytes(crash_log.read_bytes()[-512 * 1024 :])
        except OSError:
            pass
        crash_handle = open(crash_log, "a", buffering=1)
        crash_handle.write(
            f"--- crash capture armed {time.strftime('%Y-%m-%dT%H:%M:%SZ', time.gmtime())} pid={os.getpid()} ---\n"
        )
        faulthandler.enable(file=crash_handle)
    except (ImportError, AttributeError, RuntimeError, ValueError, OSError):
        pass

    # JRBAR_TRACEMALLOC=1 profiles retained allocations from here on.
    start_if_requested(lambda message: legacy_module.log_status_bar(message))

    if another_instance_alive():
        print("jrbar core: another JR-Bar (core or status bar) already owns the event socket; exiting.", file=sys.stderr)
        return 2

    from AppKit import NSApplication

    from .application_composition import compose_status_bar_application
    from .migration import run_startup_migration

    run_startup_migration()
    compose_status_bar_application()
    controller_class = build_headless_controller_class()
    application = NSApplication.sharedApplication()
    controller = controller_class.alloc().init()
    controller._core_socket_path = Path(args.socket).expanduser() if args.socket else None
    _install_log_mirror(lambda: getattr(controller, "_core", None))
    application.setDelegate_(controller)

    def _terminate(_signum, _frame) -> None:
        controller.performSelectorOnMainThread_withObject_waitUntilDone_("coreQuit:", None, False)

    signal.signal(signal.SIGTERM, _terminate)
    signal.signal(signal.SIGINT, _terminate)
    print(f"jrbar core {CORE_VERSION} starting (pid {os.getpid()})", flush=True)
    application.run()
    return 0


__all__ = [
    "CORE_VERSION",
    "CoreCommandBox",
    "HeadlessNotificationClient",
    "build_headless_controller_class",
    "command_names",
    "deck_probe",
    "device_transitions",
    "get_path",
    "mono_to_epoch",
    "plan_extra_lookups",
    "run_core",
    "screen_bar_anchor",
    "set_path",
    "settings_from_document",
    "split_path",
]
