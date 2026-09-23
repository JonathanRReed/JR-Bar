"""Answering an ask in place: the exact key each provider's CLI takes at its
permission prompt -- or, for an ``input`` ask, the reply text typed out and
submitted with Return -- behind a chain of safety checks.

This is the local runtime surface ``local.answer_in_place`` that the product
contract binds ``ProductCapability.ANSWERING`` to (provider_contracts.py). A
provider only reaches it when its negotiated contract declares answering AND a
handler for that exact invocation is registered (answer_runtime.py), so the
capability gate and the executable route can never disagree.

The mechanism is a synthetic keystroke posted to the process that hosts the
session's terminal, because that is the only thing macOS offers: ``TIOCSTI``
refuses a tty that is not the caller's own controlling terminal, and no
terminal this product supports (Ghostty above all) exposes a scripting call
that writes a single key into one session. Typing into the wrong window is
therefore the whole risk, and every check below exists to refuse instead:

* the ask is still live in the daemon's canonical state, same request id and
  same state generation;
* the session's process is PROVEN alive and its pid is known -- an unread
  liveness check refuses like a dead one;
* the frontmost application is the app that hosts this session;
* the frontmost application's process is PROVEN an ANCESTOR of the session's
  process -- an unwalkable ancestry is a refusal, because on a terminal that
  shares one process across windows (Ghostty above all) ancestry alone cannot
  tell this session's window from a sibling's;
* the terminal names its focused tab's tty and that tty IS the session's.
  Terminal.app and iTerm2 expose that proof. Ghostty names no tty, so its
  proof is the focused terminal of its front window being in the session
  process's working directory while no other Ghostty terminal is; two
  terminals in one directory cannot be told apart and refuse, and so does
  a terminal that names no directory, which could be the session's. A session
  hosted anywhere else -- or whose own tty could not be resolved -- has no
  safe in-place answer and refuses, leaving Open-in-terminal as the honest
  path;
* the session's process is not stopped (a Ctrl-Z'd job's terminal shows the
  shell, and a key there is a shell command);
* Accessibility is granted, without which the keystroke silently goes nowhere.

A permission prompt the agent's own hook is holding for JR-Bar never gets
here: answer_decisions.py replies to the hook instead, with nothing typed.

Anything that fails refuses, and anything that cannot be proven refuses too.
There is no "type it anyway" path.

The keys were measured against the real CLIs on this Mac (2026-09-10, Claude
Code 2.1.263 and codex-cli 0.153.4) with scripts/verify_providers_live.py's
scripted endpoint; see docs/NATIVE-PROVIDERS.md.
"""

from __future__ import annotations

import ctypes
import os
import subprocess
import threading
import time
from collections.abc import Callable, Iterable, Mapping
from dataclasses import dataclass
from typing import Final

from .answer_in_place import MAX_ANSWER_REPLY_LENGTH

# --- refusal vocabulary ------------------------------------------------------
#: Every code this surface can answer with. ``docs/CORE-PROTOCOL.md`` documents
#: the same list for the ``answer_ask`` command.
ANSWER_REFUSAL_CODES: Final = (
    "not_frontmost",
    "accessibility_required",
    "unsupported",
    "session_gone",
    "stale_ask",
    "send_failed",
)

#: Where the owner turns Accessibility on. Quoted verbatim in the refusal so
#: the message is actionable without a second lookup.
ACCESSIBILITY_SETTINGS_PANE: Final = "System Settings > Privacy & Security > Accessibility"
#: The row to turn on when the running process cannot name itself.
DEFAULT_ACCESSIBILITY_APP_NAME: Final = "JR-Bar"
ACCESSIBILITY_SETTINGS_PATH: Final = (
    f"{ACCESSIBILITY_SETTINGS_PANE} > {DEFAULT_ACCESSIBILITY_APP_NAME}"
)


def accessibility_refusal_message(app_name: str | None = None) -> str:
    """The refusal, naming the exact row the owner has to switch on."""
    name = app_name if type(app_name) is str and app_name.strip() else None
    row = (name or DEFAULT_ACCESSIBILITY_APP_NAME).strip()
    return (
        "JR-Bar cannot answer this ask until macOS lets it send the keystroke. "
        f"Turn on {ACCESSIBILITY_SETTINGS_PANE} > {row}."
    )


ACCESSIBILITY_REFUSAL_MESSAGE: Final = accessibility_refusal_message()

#: How long a delivery may take from preflight to posted key. A keystroke that
#: has waited longer than this is stale by definition: the prompt it was aimed
#: at may already be gone.
DELIVERY_BUDGET_SECONDS: Final = 4.0
#: How long the terminal-scripting tty probe may block.
SCRIPT_PROBE_TIMEOUT_SECONDS: Final = 1.5
GHOSTTY_BUNDLE_ID: Final = "com.mitchellh.ghostty"
#: Ancestry walk depth, matching the daemon's own terminal resolution.
MAX_ANCESTRY_DEPTH: Final = 12


class AnswerRefusal(Exception):
    """A refusal with an exact code and an owner-facing sentence."""

    __slots__ = ("code", "message", "reason")

    def __init__(self, code: str, message: str, reason: str | None = None) -> None:
        if code not in ANSWER_REFUSAL_CODES:
            raise ValueError("unknown answer refusal code")
        super().__init__(message)
        self.code = code
        self.message = message
        self.reason = reason

    def detail(self) -> str:
        return f"{self.message} ({self.reason})" if self.reason else self.message

    @property
    def answer_status_text(self) -> str:
        """What the answer surface shows instead of an exception name."""
        return self.message


# --- what each provider's prompt takes ---------------------------------------


@dataclass(frozen=True, slots=True)
class AnswerKey:
    """One key press: what it types, and the macOS virtual key code for it."""

    label: str
    key_code: int

    def __post_init__(self) -> None:
        if not (
            type(self.label) is str
            and self.label
            and type(self.key_code) is int
            and 0 <= self.key_code <= 0x7F
        ):
            raise ValueError("invalid answer key")


@dataclass(frozen=True, slots=True)
class ProviderAnswerKeys:
    """The approve and deny keys one provider's permission prompt takes."""

    provider: str
    approve: AnswerKey
    deny: AnswerKey
    approve_meaning: str
    deny_meaning: str

    def __post_init__(self) -> None:
        if not (
            type(self.provider) is str
            and self.provider
            and type(self.approve) is AnswerKey
            and type(self.deny) is AnswerKey
            and type(self.approve_meaning) is str
            and type(self.deny_meaning) is str
        ):
            raise ValueError("invalid provider answer keys")

    def key_for(self, decision: str) -> AnswerKey:
        if decision == "approve":
            return self.approve
        if decision == "deny":
            return self.deny
        raise ValueError("decision must be approve or deny")

    def meaning_for(self, decision: str) -> str:
        return self.approve_meaning if decision == "approve" else self.deny_meaning


# macOS virtual key codes (Carbon ``kVK_ANSI_*``): 1=18, 3=20, y=16, esc=53.
_KEY_1: Final = AnswerKey("1", 18)
_KEY_3: Final = AnswerKey("3", 20)
_KEY_Y: Final = AnswerKey("y", 16)
_KEY_ESCAPE: Final = AnswerKey("esc", 53)

#: Measured, not guessed. Claude Code renders "Do you want to proceed?" with
#: "1. Yes" always first and the "No" row's number varying with how many
#: always-allow rows the tool earns, so approve is the stable ``1`` and deny is
#: the ``Esc to cancel`` the prompt itself advertises. Codex renders
#: "1. Yes, proceed (y) / 2. …(p) / 3. No, and tell Codex what to do
#: differently (esc)" with fixed numbering, so approve is ``y`` and deny is the
#: explicit ``3`` rather than Esc (Esc is also Codex's global interrupt).
ANSWER_KEYS: Final[Mapping[str, ProviderAnswerKeys]] = {
    "claude": ProviderAnswerKeys(
        provider="claude",
        approve=_KEY_1,
        deny=_KEY_ESCAPE,
        approve_meaning='select "1. Yes" on the permission prompt',
        deny_meaning="cancel the permission prompt (Esc to cancel)",
    ),
    "codex": ProviderAnswerKeys(
        provider="codex",
        approve=_KEY_Y,
        deny=_KEY_3,
        approve_meaning='select "1. Yes, proceed (y)" on the approval prompt',
        deny_meaning='select "3. No, and tell Codex what to do differently"',
    ),
}

#: Providers whose contracts may declare ``ProductCapability.ANSWERING``.
ANSWERABLE_PROVIDERS: Final = frozenset(ANSWER_KEYS)


def answer_keys_for_provider(provider: object) -> ProviderAnswerKeys | None:
    """The measured keys for that provider, or None when it has no recipe."""
    if type(provider) is not str:
        return None
    return ANSWER_KEYS.get(provider.strip().lower())


# --- the facts one delivery is decided on ------------------------------------


@dataclass(frozen=True, slots=True)
class AnswerHostFacts:
    """Everything observed about where the session actually lives."""

    session_pid: int | None
    session_alive: bool | None
    session_tty: str | None
    expected_bundle_ids: frozenset[str]
    frontmost_bundle_id: str | None
    frontmost_pid: int | None
    frontmost_ancestor_of_session: bool | None
    focused_tab_tty: str | None
    accessibility_trusted: bool
    #: What System Settings will call the process that must be trusted. The
    #: keystroke is posted by the daemon, which on an installed deployment is
    #: the ``jrbar-core`` helper inside JR-Bar.app and NOT JR-Bar itself, so
    #: naming the wrong row would send the owner to a switch that changes
    #: nothing.
    accessibility_app_name: str | None = None
    #: Ghostty's stand-in for ``focused_tab_tty``, which it cannot name:
    #: ``True`` when the focused terminal of its front window is in the
    #: session process's working directory AND is the only Ghostty terminal
    #: there; ``False`` when the focused terminal is somewhere else; ``None``
    #: when that cannot be told (two terminals in one directory, no Apple
    #: events, not Ghostty).
    focused_surface_proven: bool | None = None
    #: The session's process is stopped (Ctrl-Z): its prompt is not what the
    #: terminal is showing, the shell is, and a key would go to the shell.
    session_stopped: bool | None = None

    def __post_init__(self) -> None:
        if not (
            (self.focused_surface_proven is None or type(self.focused_surface_proven) is bool)
            and (self.session_stopped is None or type(self.session_stopped) is bool)
            and (self.session_pid is None or type(self.session_pid) is int)
            and (self.session_alive is None or type(self.session_alive) is bool)
            and (self.session_tty is None or type(self.session_tty) is str)
            and type(self.expected_bundle_ids) is frozenset
            and (
                self.frontmost_bundle_id is None
                or type(self.frontmost_bundle_id) is str
            )
            and (self.frontmost_pid is None or type(self.frontmost_pid) is int)
            and (
                self.frontmost_ancestor_of_session is None
                or type(self.frontmost_ancestor_of_session) is bool
            )
            and (self.focused_tab_tty is None or type(self.focused_tab_tty) is str)
            and type(self.accessibility_trusted) is bool
            and (
                self.accessibility_app_name is None
                or type(self.accessibility_app_name) is str
            )
        ):
            raise ValueError("invalid answer host facts")

    def document(self) -> dict[str, object]:
        """What the socket reply shows about the window that was answered."""
        return {
            "pid": self.session_pid,
            "tty": self.session_tty,
            "app": self.frontmost_bundle_id,
            "app_pid": self.frontmost_pid,
            "window_evidence": self.window_evidence(),
        }

    def window_evidence(self) -> str:
        """How sure JR-Bar is that the window in front is this session's."""
        if (
            self.focused_tab_tty is not None
            and self.session_tty is not None
            and self.focused_tab_tty == self.session_tty
        ):
            return "focused_tab_tty"
        if self.focused_surface_proven is True and self.frontmost_bundle_id == GHOSTTY_BUNDLE_ID:
            return "focused_surface_cwd"
        if self.frontmost_ancestor_of_session:
            return "host_process_ancestry"
        return "frontmost_application_only"


@dataclass(frozen=True, slots=True)
class AnswerPlan:
    """A delivery the checks agreed to: which key, to which process."""

    provider: str
    decision: str
    key: AnswerKey
    target_pid: int
    mechanism: str
    meaning: str
    facts: AnswerHostFacts

    def __post_init__(self) -> None:
        if not (
            type(self.provider) is str
            and self.decision in ("approve", "deny")
            and type(self.key) is AnswerKey
            and type(self.target_pid) is int
            and self.target_pid > 0
            and type(self.mechanism) is str
            and type(self.facts) is AnswerHostFacts
        ):
            raise ValueError("invalid answer plan")

    def document(self) -> dict[str, object]:
        return {
            "mechanism": self.mechanism,
            "key": self.key.label,
            "key_code": self.key.key_code,
            "meaning": self.meaning,
            "host": self.facts.document(),
        }


def _checked_answer_host(
    *,
    provider: str,
    ask_live: bool,
    facts: AnswerHostFacts,
) -> ProviderAnswerKeys:
    """Every check a delivery must pass, whichever payload it carries.

    Raises ``AnswerRefusal`` with the exact refusal code for the first check
    that fails, in the order that makes the refusal most useful to read.
    Returns the provider's measured key recipe -- a provider with no recipe
    has no in-place answer of ANY kind.
    """
    if type(facts) is not AnswerHostFacts:
        raise ValueError("invalid answer host facts")

    keys = answer_keys_for_provider(provider)
    if keys is None:
        raise AnswerRefusal(
            "unsupported",
            f"JR-Bar has no in-place answer for {provider}.",
            "no_keystroke_recipe",
        )
    if not ask_live:
        raise AnswerRefusal(
            "stale_ask",
            "That ask is no longer live; nothing was sent.",
            "resolved_elsewhere",
        )
    if facts.session_pid is None or facts.session_alive is False:
        raise AnswerRefusal(
            "session_gone",
            "That session's process is no longer running.",
            "no_live_process",
        )
    if facts.session_alive is not True:
        # ``None`` is "nobody could look", not "alive": a keystroke aimed at
        # a process that may be gone lands wherever the terminal is focused.
        raise AnswerRefusal(
            "session_gone",
            "JR-Bar cannot confirm that session's process is still running; "
            "nothing was sent.",
            "liveness_unproven",
        )

    if facts.frontmost_bundle_id is None:
        raise AnswerRefusal(
            "not_frontmost",
            "No application is frontmost.",
            "no_frontmost_app",
        )
    if not facts.expected_bundle_ids:
        raise AnswerRefusal(
            "not_frontmost",
            "JR-Bar does not know which application hosts that session.",
            "unknown_host",
        )
    if facts.frontmost_bundle_id not in facts.expected_bundle_ids:
        raise AnswerRefusal(
            "not_frontmost",
            "The session's terminal is not in front.",
            f"frontmost_is:{facts.frontmost_bundle_id}",
        )
    if facts.frontmost_pid is None:
        raise AnswerRefusal(
            "not_frontmost",
            "The frontmost application has no process identity.",
            "no_frontmost_pid",
        )
    # The strongest signal available for a terminal with no scripting
    # interface: the app in front must be the very process the session
    # descends from, not merely another window of the same kind of terminal.
    if facts.frontmost_ancestor_of_session is False:
        raise AnswerRefusal(
            "not_frontmost",
            "A different window of that terminal is in front.",
            "other_window",
        )
    if facts.frontmost_ancestor_of_session is not True:
        # ``None`` is "the walk could not decide". On a one-process-many-
        # windows terminal that is exactly the case ancestry cannot rule on,
        # so unknown ownership is a refusal, never permission.
        raise AnswerRefusal(
            "not_frontmost",
            "JR-Bar cannot prove the window in front owns that session; "
            "nothing was sent.",
            "ownership_unproven",
        )
    # A stopped session (Ctrl-Z) is alive, but its terminal is showing the
    # shell: a key would be a shell command, not an answer.
    if facts.session_stopped is True:
        raise AnswerRefusal(
            "session_gone",
            "That session is suspended in its terminal; nothing was sent.",
            "process_stopped",
        )
    # The exact focused-target proof, required of every host now. The key
    # lands on whatever tab is focused in the frontmost window, so the
    # terminal must name that tab's tty and it must be this session's.
    # ``focused_tab_tty`` is ``None`` both for terminals with no scripting
    # call (kitty, WezTerm, Alacritty -- where ancestry cannot pick a
    # window) and for a probe that failed; neither is affirmative proof.
    # Ghostty names no tty, but it names its focused terminal's working
    # directory: the only Ghostty terminal in the session's own directory,
    # focused, is the same proof by other means.
    ghostty_in_front = facts.frontmost_bundle_id == GHOSTTY_BUNDLE_ID
    if ghostty_in_front and facts.focused_surface_proven is False:
        raise AnswerRefusal(
            "not_frontmost",
            "A different Ghostty tab or split is in front.",
            "other_surface",
        )
    if not (ghostty_in_front and facts.focused_surface_proven is True):
        if facts.session_tty is None:
            raise AnswerRefusal(
                "not_frontmost",
                "JR-Bar cannot name that session's terminal tab; nothing was "
                "sent.",
                "session_tty_unknown",
            )
        if facts.focused_tab_tty is None:
            raise AnswerRefusal(
                "not_frontmost",
                "JR-Bar cannot prove which tab of that terminal is in front; "
                "nothing was sent. Open the session's terminal to answer there.",
                "focused_tab_unproven",
            )
        if facts.focused_tab_tty != facts.session_tty:
            raise AnswerRefusal(
                "not_frontmost",
                "A different tab of that terminal is in front.",
                f"other_tab:{facts.focused_tab_tty}",
            )
    if not facts.accessibility_trusted:
        raise AnswerRefusal(
            "accessibility_required",
            accessibility_refusal_message(facts.accessibility_app_name),
            "ax_not_trusted",
        )

    return keys


def plan_local_answer(
    *,
    provider: str,
    decision: str,
    ask_live: bool,
    facts: AnswerHostFacts,
) -> AnswerPlan:
    """Decide, from facts alone, whether this key may be sent. Pure."""
    if decision not in ("approve", "deny"):
        raise ValueError("decision must be approve or deny")
    keys = _checked_answer_host(provider=provider, ask_live=ask_live, facts=facts)
    return AnswerPlan(
        provider=keys.provider,
        decision=decision,
        key=keys.key_for(decision),
        target_pid=facts.frontmost_pid,
        mechanism="synthetic_keystroke",
        meaning=keys.meaning_for(decision),
        facts=facts,
    )


# --- typed replies -------------------------------------------------------------
#
# An ``input`` ask wants words, not a verdict. The payload is the same
# synthetic keystroke macOS offers -- a keyboard event posted to the session
# host's pid -- but carrying a unicode string instead of a key code, then a
# bare Return to submit. Every fence above applies unchanged: the ask must
# still be live, the session's terminal must still be the frontmost window.


def _normalized_reply_text(value: object) -> str:
    """One bounded single line of printable text, or ``ValueError``."""
    if type(value) is not str:
        raise ValueError("invalid reply text")
    normalized = " ".join(value.split())[:MAX_ANSWER_REPLY_LENGTH]
    if not normalized or not normalized.isprintable():
        raise ValueError("invalid reply text")
    return normalized


@dataclass(frozen=True, slots=True)
class AnswerReplyPlan:
    """A typed reply the checks agreed to: the text, and Return after it."""

    provider: str
    text: str
    target_pid: int
    mechanism: str
    meaning: str
    facts: AnswerHostFacts

    def __post_init__(self) -> None:
        if not (
            type(self.provider) is str
            and type(self.text) is str
            and self.text == _normalized_reply_text(self.text)
            and type(self.target_pid) is int
            and self.target_pid > 0
            and type(self.mechanism) is str
            and type(self.meaning) is str
            and type(self.facts) is AnswerHostFacts
        ):
            raise ValueError("invalid reply plan")

    def document(self) -> dict[str, object]:
        return {
            "mechanism": self.mechanism,
            "characters": len(self.text),
            "meaning": self.meaning,
            "host": self.facts.document(),
        }


def plan_local_reply(
    *,
    provider: str,
    reply_text: str,
    ask_live: bool,
    facts: AnswerHostFacts,
) -> AnswerReplyPlan:
    """Decide, from facts alone, whether this reply may be typed. Pure."""
    text = _normalized_reply_text(reply_text)
    keys = _checked_answer_host(provider=provider, ask_live=ask_live, facts=facts)
    return AnswerReplyPlan(
        provider=keys.provider,
        text=text,
        target_pid=facts.frontmost_pid,
        mechanism="synthetic_text",
        meaning="type the reply text and press Return",
        facts=facts,
    )


# --- the macOS boundary ------------------------------------------------------

_APPLICATION_SERVICES: Final = (
    "/System/Library/Frameworks/ApplicationServices.framework/ApplicationServices"
)


def accessibility_trusted() -> bool:
    """Whether this process may post synthetic events / read other apps' UI.

    Never prompts: ``AXIsProcessTrusted`` only reports, and granting the right
    is the owner's to do in System Settings.
    """
    try:
        application_services = ctypes.cdll.LoadLibrary(_APPLICATION_SERVICES)
        trust_check = application_services.AXIsProcessTrusted
        trust_check.argtypes = []
        trust_check.restype = ctypes.c_bool
        return bool(trust_check())
    except Exception:
        return False


def running_app_name() -> str | None:
    """What System Settings calls THIS process, for the Accessibility row.

    On an installed deployment the daemon is the ``jrbar-core`` helper app
    inside JR-Bar.app, so its own bundle name is the row to turn on.
    """
    try:
        from Foundation import NSBundle

        bundle = NSBundle.mainBundle()
        if bundle is None:
            return None
        for key in ("CFBundleDisplayName", "CFBundleName"):
            value = bundle.objectForInfoDictionaryKey_(key)
            if isinstance(value, str) and value.strip():
                return value.strip()
        path = bundle.bundlePath()
        if isinstance(path, str) and path.endswith(".app"):
            return os.path.basename(path)[: -len(".app")] or None
    except Exception:
        return None
    return None


def frontmost_application() -> tuple[str | None, int | None]:
    """(bundle id, pid) of the frontmost application, or (None, None)."""
    try:
        from AppKit import NSWorkspace

        application = NSWorkspace.sharedWorkspace().frontmostApplication()
        if application is None:
            return (None, None)
        bundle_id = application.bundleIdentifier()
        pid = application.processIdentifier()
    except Exception:
        return (None, None)
    bundle = bundle_id.strip() if isinstance(bundle_id, str) and bundle_id.strip() else None
    return (bundle, int(pid) if isinstance(pid, int) and pid > 0 else None)


def process_ancestry(pid: int, depth: int = MAX_ANCESTRY_DEPTH) -> tuple[int, ...]:
    """The pid's ancestors, nearest first, from one ``ps`` table read."""
    if type(pid) is not int or pid <= 1:
        return ()
    try:
        from .process_registry import list_processes

        table = list_processes()
    except Exception:
        return ()
    chain: list[int] = []
    current = pid
    for _ in range(max(0, depth)):
        entry = table.get(current)
        if entry is None:
            break
        parent = getattr(entry, "ppid", None)
        if type(parent) is not int or parent <= 1:
            break
        chain.append(parent)
        current = parent
    return tuple(chain)


def process_alive(pid: object) -> bool:
    if type(pid) is not int or pid <= 0:
        return False
    try:
        os.kill(pid, 0)
    except ProcessLookupError:
        return False
    except PermissionError:
        return True
    except Exception:
        return False
    return True


def tty_for_pid(pid: object) -> str | None:
    """``/dev/ttysNNN`` for that process, from ``ps``."""
    if type(pid) is not int or pid <= 0:
        return None
    try:
        completed = subprocess.run(
            ["/bin/ps", "-o", "tty=", "-p", str(pid)],
            check=False,
            stdout=subprocess.PIPE,
            stderr=subprocess.DEVNULL,
            text=True,
            timeout=SCRIPT_PROBE_TIMEOUT_SECONDS,
        )
    except Exception:
        return None
    text = completed.stdout.strip()
    if not text or text in ("??", "-"):
        return None
    return text if text.startswith("/dev/") else f"/dev/{text}"


#: Terminals that will name their focused tab's tty over Apple events. Ghostty
#: proves its focused terminal another way (``ghostty_focused_surface_proven``);
#: kitty, Alacritty and WezTerm have no call at all, so a session hosted in
#: one can never be answered in place. The honest path there is
#: Open-in-terminal.
_FOCUSED_TTY_SCRIPTS: Final[Mapping[str, str]] = {
    "com.apple.Terminal": (
        'tell application id "com.apple.Terminal" to '
        "get tty of selected tab of front window"
    ),
    "com.googlecode.iterm2": (
        'tell application id "com.googlecode.iterm2" to '
        "tell current session of current window to get tty"
    ),
}


def focused_tab_tty(bundle_id: object) -> str | None:
    """The tty of the terminal's focused tab, when it will say.

    ``None`` means "could not be determined" -- a terminal with no scripting
    call, or an Apple-events permission the owner has not granted. It never
    means "mismatch"; a mismatch is a tty that differs.
    """
    if type(bundle_id) is not str:
        return None
    script = _FOCUSED_TTY_SCRIPTS.get(bundle_id)
    if script is None:
        return None
    try:
        completed = subprocess.run(
            ["/usr/bin/osascript", "-e", script],
            check=False,
            stdout=subprocess.PIPE,
            stderr=subprocess.DEVNULL,
            text=True,
            timeout=SCRIPT_PROBE_TIMEOUT_SECONDS,
        )
    except Exception:
        return None
    if completed.returncode != 0:
        return None
    value = completed.stdout.strip()
    return value or None


_LIBPROC: Final = "/usr/lib/libproc.dylib"
_PROC_PIDTBSDINFO: Final = 3
_PROC_BSDINFO_SIZE: Final = 136
_SSTOP: Final = 4
_PROC_PIDVNODEPATHINFO: Final = 9
_VNODE_INFO_SIZE: Final = 152
_MAXPATHLEN: Final = 1024


def _proc_pidinfo(pid: int, flavor: int, size: int) -> bytes | None:
    try:
        libproc = ctypes.cdll.LoadLibrary(_LIBPROC)
        call = libproc.proc_pidinfo
        call.argtypes = [ctypes.c_int, ctypes.c_int, ctypes.c_uint64, ctypes.c_void_p, ctypes.c_int]
        call.restype = ctypes.c_int
        buffer = ctypes.create_string_buffer(size)
        if call(pid, flavor, 0, buffer, size) != size:
            return None
        return buffer.raw
    except Exception:
        return None


def process_cwd(pid: object) -> str | None:
    """That process's current directory (libproc, as ``lsof`` reads it)."""
    if type(pid) is not int or pid <= 0:
        return None
    raw = _proc_pidinfo(pid, _PROC_PIDVNODEPATHINFO, 2 * (_VNODE_INFO_SIZE + _MAXPATHLEN))
    if raw is None:
        return None
    path = raw[_VNODE_INFO_SIZE : _VNODE_INFO_SIZE + _MAXPATHLEN].split(b"\0", 1)[0]
    return path.decode("utf-8", "surrogateescape") or None


def process_stopped(pid: object) -> bool | None:
    """Whether the process is stopped (``SSTOP``, a Ctrl-Z'd job)."""
    if type(pid) is not int or pid <= 0:
        return None
    raw = _proc_pidinfo(pid, _PROC_PIDTBSDINFO, _PROC_BSDINFO_SIZE)
    if raw is None:
        return None
    return int.from_bytes(raw[4:8], "little") == _SSTOP


def ghostty_focused_surface_proven(session_pid: object, runner: object = None) -> bool | None:
    """Ghostty's focused-target proof: ``True`` when the focused terminal of
    its front window is in the session process's working directory and no
    other Ghostty terminal is; ``False`` when the focused terminal is in
    another directory; ``None`` when it cannot be told -- two terminals in
    that directory, an Apple event macOS refused, no directory to compare.
    Ghostty 1.3 names no tty, so a directory only it holds is the proof.

    "Only it" has to cover every terminal: one that names no directory at
    all (started with a command instead of a shell, or with no shell
    integration) could be the session's own, leaving the focused terminal
    a plain shell that merely shares its directory -- so any such terminal
    makes the proof unknown, never a yes."""
    session_cwd = process_cwd(session_pid)
    if not session_cwd:
        return None
    from .answer_surfaces import (
        _GHOSTTY_FOCUSED_TERMINAL,
        _GHOSTTY_LIST_TERMINALS,
        SurfaceRunner,
        _same_directory,
        parse_ghostty_terminals,
    )

    scripts = runner if runner is not None else SurfaceRunner()
    code, output = scripts.osascript(_GHOSTTY_FOCUSED_TERMINAL)  # type: ignore[attr-defined]
    if code != 0 or not output:
        return None
    focused_id, _sep, focused_cwd = output.partition("\t")
    if not _same_directory(focused_cwd.strip(), session_cwd):
        return False
    code, output = scripts.osascript(_GHOSTTY_LIST_TERMINALS)  # type: ignore[attr-defined]
    if code != 0:
        return None
    terminals = parse_ghostty_terminals(output)
    if any(not terminal.working_directory for terminal in terminals):
        return None
    sharing = [
        terminal
        for terminal in terminals
        if _same_directory(terminal.working_directory, session_cwd)
    ]
    return True if len(sharing) == 1 and sharing[0].id == focused_id.strip() else None


#: The hosts that can satisfy the fence's exact focused-target proof:
#: Terminal.app and iTerm2 by the focused tab's tty, Ghostty by its focused
#: terminal being the only one in the session's directory.
FOCUSED_TAB_PROOF_BUNDLES: Final = frozenset({*_FOCUSED_TTY_SCRIPTS, GHOSTTY_BUNDLE_ID})


def host_offers_focused_tab_proof(bundle_ids: object) -> bool:
    """Whether any expected host can prove which tab or terminal is focused:
    by its tty (Terminal.app, iTerm2) or by its working directory (Ghostty).

    The projection uses this to keep ``answerable`` honest: a session hosted
    by a terminal with no scripting call can never pass the delivery fence,
    so the button must not be offered where it would always refuse.
    """
    if not isinstance(bundle_ids, (frozenset, set, list, tuple)):
        return False
    return any(
        type(bundle_id) is str and bundle_id in FOCUSED_TAB_PROOF_BUNDLES
        for bundle_id in bundle_ids
    )


def raise_application(bundle_id: object, timeout_seconds: float = 2.0) -> bool:
    """Bring that application to the front and wait for macOS to agree.

    Used only when the caller explicitly asked JR-Bar to raise the session's
    terminal first. It never relaxes a check: the same chain runs afterwards
    against whatever is actually frontmost when it returns.
    """
    if type(bundle_id) is not str or not bundle_id:
        return False
    try:
        from AppKit import NSApplicationActivateIgnoringOtherApps, NSRunningApplication

        running = list(
            NSRunningApplication.runningApplicationsWithBundleIdentifier_(bundle_id)
        )
        if not running:
            return False
        running[0].activateWithOptions_(NSApplicationActivateIgnoringOtherApps)
    except Exception:
        return False
    deadline = time.monotonic() + max(0.0, timeout_seconds)
    while time.monotonic() < deadline:
        if frontmost_application()[0] == bundle_id:
            return True
        time.sleep(0.05)
    return frontmost_application()[0] == bundle_id


def post_answer_key(pid: int, key_code: int) -> None:
    """Post one key down/up pair to that process. Raises on any failure."""
    if type(pid) is not int or pid <= 0 or type(key_code) is not int:
        raise AnswerRefusal("send_failed", "Invalid keystroke target.", "bad_target")
    try:
        from Quartz import (
            CGEventCreateKeyboardEvent,
            CGEventPostToPid,
            CGEventSetFlags,
        )
    except Exception as error:  # pragma: no cover - macOS only
        raise AnswerRefusal(
            "send_failed",
            "This build cannot post keyboard events.",
            type(error).__name__,
        ) from error
    key_down = CGEventCreateKeyboardEvent(None, key_code, True)
    key_up = CGEventCreateKeyboardEvent(None, key_code, False)
    if key_down is None or key_up is None:
        raise AnswerRefusal(
            "send_failed",
            "macOS refused to build the keystroke.",
            "event_creation_failed",
        )
    # No modifiers: a permission prompt takes a bare key, and a stray flag
    # would turn "1" into something the TUI does not expect.
    CGEventSetFlags(key_down, 0)
    CGEventSetFlags(key_up, 0)
    try:
        CGEventPostToPid(pid, key_down)
        CGEventPostToPid(pid, key_up)
    except Exception as error:  # pragma: no cover - macOS only
        raise AnswerRefusal(
            "send_failed",
            "macOS refused to deliver the keystroke.",
            type(error).__name__,
        ) from error


#: macOS virtual key code for Return (Carbon ``kVK_Return``).
_KEY_RETURN: Final = AnswerKey("return", 36)

#: UTF-16 code units per keyboard event. ``CGEventKeyboardSetUnicodeString``
#: carries a bounded string; 20 keeps every event far inside that bound, and
#: chunking on characters means a surrogate pair is never split.
_TEXT_EVENT_UNIT_LIMIT: Final = 20


def _unicode_chunks(text: str) -> Iterable[str]:
    chunk: list[str] = []
    units = 0
    for char in text:
        char_units = len(char.encode("utf-16-le")) // 2
        if chunk and units + char_units > _TEXT_EVENT_UNIT_LIMIT:
            yield "".join(chunk)
            chunk, units = [], 0
        chunk.append(char)
        units += char_units
    if chunk:
        yield "".join(chunk)


def post_answer_text(pid: int, text: str) -> None:
    """Type ``text`` into that process, then press Return. Raises on failure.

    A key code can only name one physical key, so the reply rides
    ``CGEventKeyboardSetUnicodeString`` -- the unicode payload an ordinary
    keyboard event carries. The string goes on the key-DOWN event (typing is
    a key-down behaviour); a plain key-up follows, and a bare Return submits,
    the same as the binary path's single keystroke.
    """
    if type(pid) is not int or pid <= 0 or type(text) is not str or not text:
        raise AnswerRefusal("send_failed", "Invalid keystroke target.", "bad_target")
    try:
        from Quartz import (
            CGEventCreateKeyboardEvent,
            CGEventKeyboardSetUnicodeString,
            CGEventPostToPid,
            CGEventSetFlags,
        )
    except Exception as error:  # pragma: no cover - macOS only
        raise AnswerRefusal(
            "send_failed",
            "This build cannot post keyboard events.",
            type(error).__name__,
        ) from error
    for chunk in _unicode_chunks(text):
        key_down = CGEventCreateKeyboardEvent(None, 0, True)
        key_up = CGEventCreateKeyboardEvent(None, 0, False)
        if key_down is None or key_up is None:
            raise AnswerRefusal(
                "send_failed",
                "macOS refused to build the keystroke.",
                "event_creation_failed",
            )
        CGEventSetFlags(key_down, 0)
        CGEventSetFlags(key_up, 0)
        CGEventKeyboardSetUnicodeString(
            key_down, len(chunk.encode("utf-16-le")) // 2, chunk
        )
        try:
            CGEventPostToPid(pid, key_down)
            CGEventPostToPid(pid, key_up)
        except Exception as error:  # pragma: no cover - macOS only
            raise AnswerRefusal(
                "send_failed",
                "macOS refused to deliver the keystroke.",
                type(error).__name__,
            ) from error
    post_answer_key(pid, _KEY_RETURN.key_code)


def observe_host_facts(
    *,
    session_pid: int | None,
    expected_bundle_ids: Iterable[str],
    session_tty: str | None = None,
) -> AnswerHostFacts:
    """Read every fact ``plan_local_answer`` decides on, right now."""
    pid = session_pid if type(session_pid) is int and session_pid > 0 else None
    alive = process_alive(pid) if pid is not None else None
    tty = session_tty if type(session_tty) is str and session_tty else None
    if tty is None and pid is not None:
        tty = tty_for_pid(pid)
    frontmost_bundle, frontmost_pid = frontmost_application()
    ancestry_verdict: bool | None = None
    if pid is not None and frontmost_pid is not None:
        ancestors = process_ancestry(pid)
        # An empty walk is "could not be determined", never "mismatch".
        if ancestors:
            ancestry_verdict = frontmost_pid in ancestors or frontmost_pid == pid
    focused_tty = focused_tab_tty(frontmost_bundle) if frontmost_bundle else None
    surface_proven = (
        ghostty_focused_surface_proven(pid)
        if frontmost_bundle == GHOSTTY_BUNDLE_ID and pid is not None
        else None
    )
    return AnswerHostFacts(
        session_pid=pid,
        session_alive=alive,
        session_tty=tty,
        expected_bundle_ids=frozenset(
            value for value in expected_bundle_ids if type(value) is str and value
        ),
        frontmost_bundle_id=frontmost_bundle,
        frontmost_pid=frontmost_pid,
        frontmost_ancestor_of_session=ancestry_verdict,
        focused_tab_tty=focused_tty,
        accessibility_trusted=accessibility_trusted(),
        accessibility_app_name=running_app_name(),
        focused_surface_proven=surface_proven,
        session_stopped=process_stopped(pid) if pid is not None else None,
    )


@dataclass(frozen=True, slots=True)
class SessionHost:
    """Where one session's CLI is actually running."""

    pid: int | None
    tty: str | None
    bundle_ids: frozenset[str]
    app_name: str | None


def session_host(
    provider: object,
    session_id: object,
    origin_label: object = None,
) -> SessionHost:
    """Resolve the session's process, tty and hosting application.

    The same walk the daemon's session rows use: the process registry names
    the CLI's pid, ``ps`` names its tty, and the ancestry names the terminal
    or IDE that owns it. The hook's origin annotation is added as a second
    acceptable identity for sessions launched from a provider's own app.
    """
    from .core_projection import origin_document, terminal_from_command
    from .process_registry import SHARED_HOST_PROVIDERS, list_processes, load_record

    pid: int | None = None
    bundles: set[str] = set()
    app_name: str | None = None
    if (
        type(provider) is str
        and provider not in SHARED_HOST_PROVIDERS
        and type(session_id) is str
        and session_id
    ):
        try:
            record = load_record(provider, session_id)
        except Exception:
            record = None
        if record is not None and record.ended_at_epoch is None:
            candidate = getattr(record, "pid", None)
            if type(candidate) is int and process_alive(candidate):
                pid = candidate
    tty = tty_for_pid(pid)
    if pid is not None:
        try:
            table = list_processes()
        except Exception:
            table = {}
        # Start at the PARENT, never at the session process itself. The CLI's
        # own executable is named after its provider ("claude", "codex"), which
        # ``terminal_from_command`` reads as that provider's DESKTOP app -- so a
        # walk that starts at the session would decide every Claude Code
        # session is hosted by Claude.app and refuse the real terminal.
        current: int | None = getattr(table.get(pid), "ppid", None)
        for _ in range(MAX_ANCESTRY_DEPTH):
            entry = table.get(current) if current else None
            if entry is None or current is None or current <= 1:
                break
            match = terminal_from_command(getattr(entry, "command", None))
            if match is not None:
                app_name, bundle = match
                bundles.add(bundle)
                break
            current = getattr(entry, "ppid", None)
    origin = origin_document(origin_label if type(origin_label) is str else None)
    origin_bundle = (origin or {}).get("bundle_id")
    if type(origin_bundle) is str and origin_bundle:
        bundles.add(origin_bundle)
    return SessionHost(
        pid=pid,
        tty=tty,
        bundle_ids=frozenset(bundles),
        app_name=app_name,
    )


# --- one delivery ------------------------------------------------------------


@dataclass(frozen=True, slots=True)
class AnswerDeliveryOutcome:
    """What one delivery did, for the socket reply and the app's status line."""

    delivered: bool
    code: str
    message: str
    plan: AnswerPlan | AnswerReplyPlan | None

    def document(self) -> dict[str, object]:
        document: dict[str, object] = {
            "delivered": self.delivered,
            "code": self.code,
            "message": self.message,
            # A posted key is an attempted delivery, never a confirmed
            # approval: only the provider's own stream closing the request
            # proves the answer landed. ``provider_pending`` keeps that
            # distinction on the wire instead of letting ``delivered``
            # read as "resolved".
            "confirmation": "provider_pending" if self.delivered else "none",
        }
        if self.plan is not None:
            document.update(self.plan.document())
        return document


class LocalAnswerDelivery:
    """Plan, fence again, then post. One at a time, with a hard budget.

    ``is_live`` is re-asked immediately before the key goes out, so an ask that
    was resolved (answered in the terminal, timed out, superseded) between the
    plan and the post refuses instead of leaving a keystroke to land on
    whatever replaced the prompt.
    """

    def __init__(
        self,
        *,
        sender: Callable[[int, int], None] | None = None,
        text_sender: Callable[[int, str], None] | None = None,
        observer: Callable[..., AnswerHostFacts] | None = None,
        clock: Callable[[], float] | None = None,
    ) -> None:
        self._sender = sender or post_answer_key
        self._text_sender = text_sender or post_answer_text
        self._observer = observer or observe_host_facts
        self._clock = clock or time.monotonic
        self._lock = threading.RLock()
        self.last_outcome: AnswerDeliveryOutcome | None = None

    def deliver(
        self,
        *,
        provider: str,
        decision: str | None = None,
        reply_text: str | None = None,
        session_pid: int | None,
        expected_bundle_ids: Iterable[str],
        session_tty: str | None,
        is_live: Callable[[], bool],
    ) -> AnswerDeliveryOutcome:
        started = self._clock()
        with self._lock:
            try:
                facts = self._observer(
                    session_pid=session_pid,
                    expected_bundle_ids=expected_bundle_ids,
                    session_tty=session_tty,
                )
                if reply_text is not None:
                    plan: AnswerPlan | AnswerReplyPlan = plan_local_reply(
                        provider=provider,
                        reply_text=reply_text,
                        ask_live=bool(is_live()),
                        facts=facts,
                    )
                else:
                    plan = plan_local_answer(
                        provider=provider,
                        decision=decision,
                        ask_live=bool(is_live()),
                        facts=facts,
                    )
                if self._clock() - started > DELIVERY_BUDGET_SECONDS:
                    raise AnswerRefusal(
                        "stale_ask",
                        "Answering took too long to be safe; nothing was sent.",
                        "budget_exceeded",
                    )
                # Last fence before anything leaves this process.
                if not is_live():
                    raise AnswerRefusal(
                        "stale_ask",
                        "That ask was resolved while JR-Bar was answering; "
                        "nothing was sent.",
                        "resolved_while_sending",
                    )
                if type(plan) is AnswerReplyPlan:
                    self._text_sender(plan.target_pid, plan.text)
                else:
                    self._sender(plan.target_pid, plan.key.key_code)
            except AnswerRefusal as refusal:
                outcome = AnswerDeliveryOutcome(
                    delivered=False,
                    code=refusal.code,
                    message=refusal.detail(),
                    plan=None,
                )
                self.last_outcome = outcome
                return outcome
            outcome = AnswerDeliveryOutcome(
                delivered=True,
                code="sent",
                message=(
                    f"Sent reply to {plan.facts.frontmost_bundle_id}."
                    if type(plan) is AnswerReplyPlan
                    else f"Sent {plan.key.label} to {plan.facts.frontmost_bundle_id}."
                ),
                plan=plan,
            )
            self.last_outcome = outcome
            return outcome


# --- the registered handler --------------------------------------------------


@dataclass(frozen=True, slots=True)
class LocalAnswerTarget:
    """The one session a handler run is allowed to type into."""

    provider: str
    session_id: str
    session_pid: int | None
    session_tty: str | None
    expected_bundle_ids: frozenset[str]
    is_live: Callable[[], bool]

    def __post_init__(self) -> None:
        if not (
            type(self.provider) is str
            and self.provider
            and type(self.session_id) is str
            and (self.session_pid is None or type(self.session_pid) is int)
            and (self.session_tty is None or type(self.session_tty) is str)
            and type(self.expected_bundle_ids) is frozenset
            and callable(self.is_live)
        ):
            raise ValueError("invalid local answer target")


class LocalAnswerSurface:
    """``local.answer_in_place``: the handler the answer registry resolves to.

    One instance per controller. ``resolve_target`` is the owner's callback
    that turns the controller's in-flight request into the exact session facts;
    it raises ``AnswerRefusal`` when there is nothing safe to answer.
    """

    def __init__(
        self,
        *,
        resolve_target: Callable[[str], LocalAnswerTarget],
        delivery: LocalAnswerDelivery | None = None,
        log: Callable[[str], None] | None = None,
    ) -> None:
        if not callable(resolve_target):
            raise ValueError("invalid local answer target resolver")
        self._resolve_target = resolve_target
        self._delivery = delivery or LocalAnswerDelivery()
        self._log = log
        self.completed = threading.Event()
        self.last_outcome: AnswerDeliveryOutcome | None = None

    def arm(self) -> None:
        """Forget the previous outcome so a waiter cannot read a stale one."""
        self.last_outcome = None
        self.completed.clear()

    def register(self, registry: object, invocations: Iterable[object]) -> tuple[object, ...]:
        """Register this surface for each answering invocation. Returns them."""
        registered: list[object] = []
        for invocation in invocations:
            registry.register(invocation, self.handle)  # type: ignore[attr-defined]
            registered.append(invocation)
        return tuple(registered)

    def handle(
        self,
        invocation: object,
        *,
        request_kind: object,
        answer_kind: object,
        reply_text: str | None,
    ) -> None:
        """Answer the controller's in-flight request, or raise the refusal."""
        action_value = getattr(answer_kind, "value", answer_kind)
        decision = _decision_for(answer_kind)
        try:
            if action_value == "reply":
                try:
                    text = _normalized_reply_text(reply_text)
                except ValueError:
                    raise AnswerRefusal(
                        "unsupported",
                        "That reply cannot be typed in place.",
                        "invalid_reply_text",
                    ) from None
                target = self._resolve_target("reply")
                if type(target) is not LocalAnswerTarget:
                    raise AnswerRefusal(
                        "stale_ask",
                        "There is no live ask to answer.",
                        "no_target",
                    )
                outcome = self._delivery.deliver(
                    provider=target.provider,
                    reply_text=text,
                    session_pid=target.session_pid,
                    expected_bundle_ids=target.expected_bundle_ids,
                    session_tty=target.session_tty,
                    is_live=target.is_live,
                )
            else:
                if decision is None:
                    raise AnswerRefusal(
                        "unsupported",
                        "Only approve, deny and typed replies can be answered "
                        "in place.",
                        "unsupported_action",
                    )
                if reply_text is not None:
                    raise AnswerRefusal(
                        "unsupported",
                        "A typed reply belongs to the reply action, not a "
                        "decision.",
                        "reply_text_on_decision",
                    )
                target = self._resolve_target(decision)
                if type(target) is not LocalAnswerTarget:
                    raise AnswerRefusal(
                        "stale_ask",
                        "There is no live ask to answer.",
                        "no_target",
                    )
                outcome = self._delivery.deliver(
                    provider=target.provider,
                    decision=decision,
                    session_pid=target.session_pid,
                    expected_bundle_ids=target.expected_bundle_ids,
                    session_tty=target.session_tty,
                    is_live=target.is_live,
                )
        except AnswerRefusal as refusal:
            outcome = AnswerDeliveryOutcome(
                delivered=False,
                code=refusal.code,
                message=refusal.detail(),
                plan=None,
            )
            self._finish(outcome)
            raise
        except Exception as error:
            outcome = AnswerDeliveryOutcome(
                delivered=False,
                code="send_failed",
                message=f"Answering failed: {type(error).__name__}",
                plan=None,
            )
            self._finish(outcome)
            raise
        self._finish(outcome)
        if not outcome.delivered:
            raise AnswerRefusal(outcome.code, outcome.message)

    def _finish(self, outcome: AnswerDeliveryOutcome) -> None:
        self.last_outcome = outcome
        if self._log is not None:
            try:
                self._log(f"answer: {outcome.code}: {outcome.message}")
            except Exception:
                pass
        self.completed.set()


def _decision_for(answer_kind: object) -> str | None:
    """``approve``/``deny`` from an ``AnswerActionKind`` without importing it."""
    value = getattr(answer_kind, "value", answer_kind)
    if value in ("approve", "deny"):
        return str(value)
    return None


__all__ = [
    "ACCESSIBILITY_REFUSAL_MESSAGE",
    "ACCESSIBILITY_SETTINGS_PANE",
    "ACCESSIBILITY_SETTINGS_PATH",
    "ANSWERABLE_PROVIDERS",
    "ANSWER_KEYS",
    "ANSWER_REFUSAL_CODES",
    "DEFAULT_ACCESSIBILITY_APP_NAME",
    "DELIVERY_BUDGET_SECONDS",
    "FOCUSED_TAB_PROOF_BUNDLES",
    "GHOSTTY_BUNDLE_ID",
    "AnswerDeliveryOutcome",
    "AnswerHostFacts",
    "AnswerKey",
    "AnswerPlan",
    "AnswerRefusal",
    "AnswerReplyPlan",
    "LocalAnswerDelivery",
    "LocalAnswerSurface",
    "LocalAnswerTarget",
    "ProviderAnswerKeys",
    "SessionHost",
    "accessibility_refusal_message",
    "accessibility_trusted",
    "answer_keys_for_provider",
    "focused_tab_tty",
    "frontmost_application",
    "ghostty_focused_surface_proven",
    "host_offers_focused_tab_proof",
    "observe_host_facts",
    "plan_local_answer",
    "plan_local_reply",
    "post_answer_key",
    "post_answer_text",
    "process_alive",
    "process_ancestry",
    "process_cwd",
    "process_stopped",
    "raise_application",
    "running_app_name",
    "session_host",
    "tty_for_pid",
]
