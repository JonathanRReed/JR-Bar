"""The decide lane: a PermissionRequest answered from any JR-Bar surface.

Claude Code and Codex both run a ``PermissionRequest`` hook when they are
about to ask for approval, and both take the hook's stdout as the answer:
``{"hookSpecificOutput": {"hookEventName": "PermissionRequest",
"decision": {"behavior": "allow" | "deny", ...}}}``. Empty stdout is "no
decision" and the agent's own prompt carries on (checked against both
vendors' hook references on 2026-09-22). That turns answering into a reply
on a socket instead of a keystroke typed into whichever window is in front,
so it works in Ghostty, in an IDE panel and in a headless run alike -- no
Accessibility grant, no frontmost-tab proof, no race.

The hook is the compiled shim run as ``jrbar-hook --decide``
(hook/jrbar-hook.c). The ingress (hook_ingress.py) parks the request here
before it queues the payload, and the connection waits on the parked slot.
One of four things ends the wait:

* an explicit Approve, Deny or Always allow through ``answer_ask`` --
  the verdict line goes back down the socket and the shim prints it;
* the hold lapses (``DECISION_HOLD_SECONDS``) -- nothing is printed;
* the request resolves without us: the agent ran the tool (the matching
  ``PostToolUse``), or the turn ended or moved on (``Stop``,
  ``UserPromptSubmit``, ``SessionEnd``) -- nothing is printed;
* the owner opens the session to answer it there, or the daemon stops.

Only a click decides. Nothing here ever answers on a timer, a rule or a
default, and "Always allow" is a verb of its own: it echoes the agent's
own ``permission_suggestions`` allow rules, never a mode change, and only
for Claude (Codex fails closed on ``updatedPermissions`` today).

Claude Code shows its own prompt while the hook runs and takes whichever
answer comes first, so a hold costs nothing there. Codex asks its hooks
before it shows the prompt, so a hold delays the prompt; a Codex request
is therefore not parked while its terminal is the frontmost app -- the
owner is at the terminal and the prompt should appear at once.
"""

from __future__ import annotations

import json
import math
import re
import threading
import time
from collections.abc import Callable, Iterable, Mapping
from dataclasses import dataclass, field
from enum import Enum
from pathlib import Path
from typing import Any, Final

#: How long a parked request waits for a click. Short enough that a
#: Codex prompt held behind the hook still appears within the minute;
#: long enough to reach the panel, the notch or a key on the pad.
DECISION_HOLD_SECONDS: Final = 45.0
#: Kept back from the hook's own wait, so the verdict line always lands
#: before the shim stops reading.
DECISION_MARGIN_SECONDS: Final = 1.5
#: A hold shorter than this is not worth parking: nobody can click in it.
MIN_DECISION_HOLD_SECONDS: Final = 2.0
#: Parked requests at once. Each one holds a socket and a thread; a burst
#: past this just falls through to the agents' own prompts.
MAX_PARKED_DECISIONS: Final = 16
#: How long an answered request stays answerable-looking and refuses a
#: second answer, while the provider's own events catch the state up.
DECIDED_TOMBSTONE_SECONDS: Final = 15.0
#: How long ``decide`` waits for the parked connection to write the line.
DELIVERY_WAIT_SECONDS: Final = 2.0

DECIDE_PROVIDERS: Final = frozenset({"claude", "codex"})
#: Claude takes ``updatedPermissions`` on an allow; Codex rejects the
#: field ("reserved for future behavior and fail closed today").
ALWAYS_ALLOW_PROVIDERS: Final = frozenset({"claude"})
#: Tools whose "allow" is not a permission but the answer itself: an
#: allow without the chosen option or the edited plan is ignored by
#: Claude Code, so these keep their own prompt.
UNDECIDABLE_TOOLS: Final = frozenset({"AskUserQuestion", "ExitPlanMode"})
#: Events that prove a parked prompt is gone.
_TURN_OVER_EVENTS: Final = frozenset(
    {"Stop", "StopFailure", "SessionEnd", "UserPromptSubmit", "Interrupt"}
)
_TOOL_RAN_EVENTS: Final = frozenset({"PostToolUse", "PostToolUseFailure"})

#: What Claude reads when the owner denies from JR-Bar. With
#: ``interrupt`` the turn stops, the same as Esc on Claude's own prompt.
DENY_MESSAGE: Final = "The user denied this tool call from JR-Bar."

_MAX_ALWAYS_ENTRIES: Final = 8
_MAX_ALWAYS_RULES: Final = 16
_MAX_RULE_TEXT: Final = 512
_ALWAYS_DESTINATIONS: Final = frozenset(
    {"session", "localSettings", "projectSettings", "userSettings"}
)
_PREVIEW_LIMIT: Final = 200


class DecisionVerb(str, Enum):
    ALLOW = "allow"
    DENY = "deny"
    ALWAYS = "always"


class DecisionResult(str, Enum):
    #: The verdict went down the parked hook's socket.
    SENT = "sent"
    #: The hook had already gone (lapsed, released, killed): nothing sent.
    NOT_DELIVERED = "not_delivered"
    #: Nothing is parked for that request.
    NOT_PARKED = "not_parked"
    #: Somebody answered it a moment ago.
    ALREADY_DECIDED = "already_decided"
    #: That verb cannot be sent for this request (Always without rules).
    UNSUPPORTED = "unsupported"


# --- the payload ---------------------------------------------------------------


@dataclass(frozen=True, slots=True)
class PermissionFacts:
    """What the decide lane reads from one PermissionRequest payload."""

    provider: str
    session_id: str
    request_id: str
    tool_name: str
    tool_input: Mapping[str, Any] = field(repr=False)
    always_rules: tuple[dict[str, Any], ...] = ()
    cwd: str | None = None


def _request_identity(provider: str, payload_text: str) -> tuple[str, Any] | None:
    """``(actual provider, HookEvent)`` through the exact path the ingress
    worker takes, so the id computed here is the one the canonical state
    keys the request on (provider_adapters.hook_request_identity)."""
    from .hook import routed_hook_payload
    from .providers import parse_log_line

    try:
        actual, _log, line = routed_hook_payload(provider, Path("/dev/null"), payload_text)
        record = parse_log_line(actual, json.dumps(line, separators=(",", ":"), ensure_ascii=False))
    except Exception:
        return None
    if record is None:
        return None
    return actual, record


def permission_facts(provider: object, payload_text: object) -> PermissionFacts | None:
    """The facts to park, or ``None`` when this payload is not a request
    the lane can decide: another provider or event, a tool whose answer is
    not a yes/no, or no request identity to pin an answer to."""
    from .provider_adapters import hook_request_identity

    if type(provider) is not str or provider not in DECIDE_PROVIDERS:
        return None
    if type(payload_text) is not str or '"PermissionRequest"' not in payload_text:
        return None
    routed = _request_identity(provider, payload_text)
    if routed is None:
        return None
    actual, record = routed
    if actual != provider or record.event_name != "PermissionRequest":
        return None
    raw = record.raw if isinstance(record.raw, dict) else {}
    tool_name = record.tool_name or raw.get("tool_name")
    tool_input = raw.get("tool_input")
    session_id = record.session_id
    if (
        type(tool_name) is not str
        or not tool_name
        or tool_name in UNDECIDABLE_TOOLS
        or not isinstance(tool_input, dict)
        or type(session_id) is not str
        or not session_id
    ):
        return None
    request_id = hook_request_identity(record)
    if request_id is None:
        return None
    return PermissionFacts(
        provider=provider,
        session_id=session_id,
        request_id=request_id,
        tool_name=tool_name,
        tool_input=dict(tool_input),
        always_rules=(
            always_allow_rules(raw.get("permission_suggestions"))
            if provider in ALWAYS_ALLOW_PROVIDERS
            else ()
        ),
        cwd=record.cwd if type(record.cwd) is str else None,
    )


def _bounded_text(value: object) -> str | None:
    if type(value) is not str or not value or len(value) > _MAX_RULE_TEXT or not value.isprintable():
        return None
    return value


def always_allow_rules(suggestions: object) -> tuple[dict[str, Any], ...]:
    """The allow rules among the agent's own ``permission_suggestions``.

    "Always allow" means "don't ask again for this", which is exactly an
    ``addRules`` entry with ``behavior: allow`` -- the entry Claude's own
    "Yes, and don't ask again" writes. Mode changes (``setMode``, which
    could reach ``bypassPermissions``), directory grants and anything this
    parser does not recognise are dropped, and every kept field is copied
    one by one, bounded, so nothing the payload invented reaches the
    agent's settings.
    """
    if not isinstance(suggestions, list):
        return ()
    kept: list[dict[str, Any]] = []
    for entry in suggestions[:_MAX_ALWAYS_ENTRIES]:
        if not isinstance(entry, dict):
            continue
        if entry.get("type") != "addRules" or entry.get("behavior") != "allow":
            continue
        destination = entry.get("destination")
        if destination not in _ALWAYS_DESTINATIONS:
            continue
        rules = entry.get("rules")
        if not isinstance(rules, list) or not rules:
            continue
        clean_rules: list[dict[str, str]] = []
        for rule in rules[:_MAX_ALWAYS_RULES]:
            if not isinstance(rule, dict):
                continue
            tool = _bounded_text(rule.get("toolName"))
            if tool is None:
                continue
            clean: dict[str, str] = {"toolName": tool}
            if "ruleContent" in rule:
                content = _bounded_text(rule.get("ruleContent"))
                if content is None:
                    continue
                clean["ruleContent"] = content
            clean_rules.append(clean)
        if clean_rules:
            kept.append(
                {
                    "type": "addRules",
                    "rules": clean_rules,
                    "behavior": "allow",
                    "destination": destination,
                }
            )
    return tuple(kept)


def decision_document(
    provider: str,
    verb: DecisionVerb,
    *,
    always_rules: Iterable[Mapping[str, Any]] = (),
) -> dict[str, Any]:
    """The exact hookSpecificOutput each agent documents for its verdict."""
    if provider not in DECIDE_PROVIDERS or type(verb) is not DecisionVerb:
        raise ValueError("invalid decision")
    if verb is DecisionVerb.DENY:
        decision: dict[str, Any] = {"behavior": "deny", "message": DENY_MESSAGE}
        if provider == "claude":
            # Esc on Claude's own prompt stops the turn; a deny from JR-Bar
            # does the same instead of letting Claude try its way around it.
            decision["interrupt"] = True
    elif verb is DecisionVerb.ALWAYS:
        rules = [dict(rule) for rule in always_rules]
        if provider not in ALWAYS_ALLOW_PROVIDERS or not rules:
            raise ValueError("always allow needs the agent's own allow rules")
        decision = {"behavior": "allow", "updatedPermissions": rules}
    else:
        decision = {"behavior": "allow"}
    return {"hookSpecificOutput": {"hookEventName": "PermissionRequest", "decision": decision}}


# --- what the card shows ---------------------------------------------------------

_SECRET_RUN: Final = re.compile(r"(?<![A-Za-z0-9_\-+=])[A-Za-z0-9_\-+=]{32,}")
_PATCH_FILE: Final = re.compile(r"^\*\*\* (?:Update|Add|Delete) File: (.+)$", re.MULTILINE)


def _one_line(value: str) -> str:
    text = " ".join(value.split())
    text = _SECRET_RUN.sub(
        lambda match: "[redacted]"
        if any(c.isdigit() for c in match.group(0)) and any(c.isalpha() for c in match.group(0))
        else match.group(0),
        text,
    )
    return text if len(text) <= _PREVIEW_LIMIT else text[: _PREVIEW_LIMIT - 1] + "…"


def tool_preview(tool_name: object, tool_input: object) -> str | None:
    """One bounded line that says what the agent wants to do: the command,
    the file, the URL -- enough to judge the ask without switching windows.
    Token-shaped runs are masked; the card is a glance surface."""
    if type(tool_name) is not str or not isinstance(tool_input, Mapping):
        return None
    command = tool_input.get("command")
    if isinstance(command, list) and all(type(part) is str for part in command):
        command = " ".join(command)
    if tool_name == "apply_patch" and type(command) is str:
        files = _PATCH_FILE.findall(command)
        if files:
            more = f" +{len(files) - 1}" if len(files) > 1 else ""
            return _one_line(files[0].strip() + more)
    if type(command) is str and command.strip():
        return _one_line(command)
    for key in ("file_path", "notebook_path", "path", "url", "query", "pattern"):
        value = tool_input.get(key)
        if type(value) is str and value.strip():
            return _one_line(value)
    if tool_name.startswith("mcp__"):
        parts = tool_name.split("__")
        if len(parts) >= 3 and parts[1] and parts[2]:
            return _one_line(f"{parts[1]} · {'__'.join(parts[2:])}")
    return None


_DESTRUCTIVE: Final = tuple(
    re.compile(pattern)
    for pattern in (
        r"(?:^|[\s;&|(])rm\s+(?:-[A-Za-z]*[rR][A-Za-z]*|--recursive)\b",
        r"(?:^|[\s;&|(])sudo\s",
        r"(?:^|[\s;&|(])git\s+push\b[^;&|]*\s(?:--force(?:-with-lease)?|-f)\b",
        r"(?:^|[\s;&|(])git\s+reset\s+--hard\b",
        r"(?:^|[\s;&|(])git\s+clean\s+-[A-Za-z]*f",
        r"(?:^|[\s;&|(])git\s+(?:checkout|restore)\s+(?:--\s+)?\.(?:\s|$)",
        r"(?:^|[\s;&|(])git\s+branch\s+-D\b",
        r"(?:^|[\s;&|(])(?:chmod|chown)\s+-[A-Za-z]*R",
        r"(?:^|[\s;&|(])(?:mkfs(?:\.\w+)?|diskutil\s+(?:erase\w*|partitionDisk))\b",
        r"(?:^|[\s;&|(])dd\s+[^;&|]*\bof=",
        r"\b(?:curl|wget)\b[^|;&]*\|\s*(?:sudo\s+)?(?:sh|bash|zsh)\b",
        r"(?i)\bdrop\s+(?:table|database|schema)\b",
        r"(?:^|[\s;&|(])(?:kubectl\s+delete|terraform\s+destroy)\b",
        r"(?:^|[\s;&|(])(?:sudo\s+)?(?:shutdown|reboot|halt)(?=$|[\s;&|)])",
        r">\s*/dev/(?:disk|sd|rdisk)",
    )
)


def tool_risk(tool_name: object, tool_input: object) -> str | None:
    """``"destructive"`` when a shell command matches a pattern that loses
    work or data if it runs by mistake; ``None`` otherwise. A mark on the
    card, never a block: the decision stays the owner's."""
    if type(tool_name) is not str or not isinstance(tool_input, Mapping):
        return None
    command = tool_input.get("command")
    if isinstance(command, list) and all(type(part) is str for part in command):
        command = " ".join(command)
    if tool_name == "apply_patch" or type(command) is not str:
        return None
    return "destructive" if any(pattern.search(command) for pattern in _DESTRUCTIVE) else None


# --- the broker --------------------------------------------------------------------


@dataclass(frozen=True, slots=True)
class ParkedDecision:
    """What the projection and ``answer_ask`` see of one parked request."""

    provider: str
    session_id: str
    request_id: str
    tool_name: str
    hold_until_epoch: float
    can_always_allow: bool
    preview: str | None
    risk: str | None
    #: True for a request answered moments ago (the tombstone).
    decided: bool = False

    def document(self) -> dict[str, Any]:
        return {
            "hold_until": round(self.hold_until_epoch, 3),
            "always": self.can_always_allow,
            "decided": self.decided,
        }


class _Slot:
    __slots__ = (
        "deadline",
        "delivered",
        "delivered_event",
        "event",
        "facts",
        "hold_until_epoch",
        "state",
        "token",
        "verdict",
    )

    def __init__(self, token: int, facts: PermissionFacts, deadline: float, hold_until_epoch: float) -> None:
        self.token = token
        self.facts = facts
        self.deadline = deadline
        self.hold_until_epoch = hold_until_epoch
        self.state = "parked"
        self.verdict: dict[str, Any] | None = None
        self.event = threading.Event()
        self.delivered: bool | None = None
        self.delivered_event = threading.Event()


def _default_watching(facts: PermissionFacts, host_pid: int | None) -> bool:
    """Whether the owner is at the session's terminal right now: the
    frontmost app is on the agent process's ancestry. Only asked for a
    Codex request, whose prompt waits behind the hook."""
    if facts.provider != "codex" or type(host_pid) is not int or host_pid <= 1:
        return False
    try:
        from .answer_local import frontmost_application, process_ancestry

        _bundle, frontmost_pid = frontmost_application()
        if frontmost_pid is None:
            return False
        return frontmost_pid == host_pid or frontmost_pid in process_ancestry(host_pid)
    except Exception:
        return False


class DecisionBroker:
    """The parked PermissionRequests, keyed by the canonical request id."""

    def __init__(
        self,
        *,
        hold_seconds: float = DECISION_HOLD_SECONDS,
        capacity: int = MAX_PARKED_DECISIONS,
        clock: Callable[[], float] = time.monotonic,
        wall_clock: Callable[[], float] = time.time,
        watching: Callable[[PermissionFacts, int | None], bool] = _default_watching,
    ) -> None:
        if (
            type(hold_seconds) not in (int, float)
            or not math.isfinite(hold_seconds)
            or hold_seconds <= 0
            or type(capacity) is not int
            or capacity <= 0
            or not callable(clock)
            or not callable(wall_clock)
            or not callable(watching)
        ):
            raise ValueError("invalid decision broker")
        self._hold = float(hold_seconds)
        self._capacity = capacity
        self._clock = clock
        self._wall = wall_clock
        self._watching = watching
        self._lock = threading.Lock()
        self._token = 0
        self._slots: dict[int, _Slot] = {}
        self._decided: dict[tuple[str, str], float] = {}

    # -- parking (the ingress side) --

    def park(
        self,
        facts: PermissionFacts,
        *,
        wait_limit_seconds: float,
        host_pid: int | None = None,
    ) -> _Slot | None:
        """Hold ``facts`` for a click; ``None`` when it will not be held --
        full, too short a wait, or a Codex prompt the owner is watching."""
        if type(facts) is not PermissionFacts:
            return None
        hold = min(self._hold, float(wait_limit_seconds) - DECISION_MARGIN_SECONDS)
        if not math.isfinite(hold) or hold < MIN_DECISION_HOLD_SECONDS:
            return None
        if self._watching(facts, host_pid):
            return None
        now = self._clock()
        with self._lock:
            self._expire_locked(now)
            if len(self._slots) >= self._capacity:
                return None
            self._token += 1
            slot = _Slot(self._token, facts, now + hold, self._wall() + hold)
            self._slots[slot.token] = slot
            self._decided.pop((facts.provider, facts.request_id), None)
            return slot

    def wait(
        self,
        slot: _Slot,
        *,
        alive: Callable[[], bool] | None = None,
        check_seconds: float = 1.0,
    ) -> dict[str, Any] | None:
        """Block until the slot is decided, released or lapses. Returns the
        verdict document to send, or ``None`` for "print nothing".

        ``alive`` is asked every ``check_seconds``: a hook process the agent
        has already let go of cannot print a verdict, so its request stops
        looking answerable instead of taking a click that goes nowhere."""
        while True:
            remaining = slot.deadline - self._clock()
            if remaining <= 0:
                break
            if slot.event.wait(remaining if alive is None else min(remaining, check_seconds)):
                break
            if alive is not None:
                try:
                    still_there = bool(alive())
                except Exception:
                    still_there = True
                if not still_there:
                    self.release_slot(slot)
                    break
        with self._lock:
            if slot.state == "parked":
                slot.state = "expired"
            self._slots.pop(slot.token, None)
            return slot.verdict if slot.state == "decided" else None

    def delivered(self, slot: _Slot, ok: bool) -> None:
        """The parked connection's report: the verdict line was written."""
        slot.delivered = bool(ok)
        slot.delivered_event.set()

    # -- answering (the answer_ask side) --

    def decide(self, provider: str, request_id: str, verb: DecisionVerb) -> DecisionResult:
        if type(verb) is not DecisionVerb:
            return DecisionResult.UNSUPPORTED
        now = self._clock()
        with self._lock:
            self._expire_locked(now)
            slot = self._first_locked(provider, request_id)
            if slot is None:
                if (provider, request_id) in self._decided:
                    return DecisionResult.ALREADY_DECIDED
                return DecisionResult.NOT_PARKED
            if verb is DecisionVerb.ALWAYS and not slot.facts.always_rules:
                return DecisionResult.UNSUPPORTED
            slot.verdict = decision_document(
                slot.facts.provider, verb, always_rules=slot.facts.always_rules
            )
            slot.state = "decided"
            self._slots.pop(slot.token, None)
            self._decided[(provider, request_id)] = now + DECIDED_TOMBSTONE_SECONDS
            slot.event.set()
        if not slot.delivered_event.wait(DELIVERY_WAIT_SECONDS):
            return DecisionResult.NOT_DELIVERED
        return DecisionResult.SENT if slot.delivered else DecisionResult.NOT_DELIVERED

    def release(self, provider: str, *, request_id: str | None = None, session_id: str | None = None) -> int:
        """Let parked requests fall through to the agent's own prompt."""
        released = 0
        with self._lock:
            for slot in list(self._slots.values()):
                facts = slot.facts
                if facts.provider != provider:
                    continue
                if request_id is not None and facts.request_id != request_id:
                    continue
                if session_id is not None and facts.session_id != session_id:
                    continue
                self._release_locked(slot)
                released += 1
        return released

    def release_slot(self, slot: _Slot) -> bool:
        """Let one parked request fall through (its connection is closing)."""
        with self._lock:
            if self._slots.get(slot.token) is not slot:
                return False
            self._release_locked(slot)
            return True

    def release_all(self) -> int:
        with self._lock:
            slots = list(self._slots.values())
            for slot in slots:
                self._release_locked(slot)
            return len(slots)

    def observe(self, provider: object, payload_text: object) -> int:
        """Release what a later hook event proves is no longer on screen:
        the tool ran (its ``PostToolUse``), or the turn ended or moved on.
        Parses nothing while nothing is parked for that provider."""
        if type(provider) is not str or type(payload_text) is not str:
            return 0
        with self._lock:
            if not any(slot.facts.provider == provider for slot in self._slots.values()):
                return 0
        try:
            payload = json.loads(payload_text)
        except ValueError:
            return 0
        if not isinstance(payload, dict):
            return 0
        event = payload.get("hook_event_name") or payload.get("hookEventName")
        session_id = payload.get("session_id")
        if type(session_id) is not str or not session_id:
            return 0
        if event in _TURN_OVER_EVENTS:
            return self.release(provider, session_id=session_id)
        if event in _TOOL_RAN_EVENTS:
            from .provider_adapters import hook_request_identity

            routed = _request_identity(provider, payload_text)
            if routed is None:
                return 0
            request_id = hook_request_identity(routed[1])
            if request_id is None:
                return 0
            return self.release(provider, request_id=request_id)
        return 0

    # -- reading (the projection side) --

    def parked(self, provider: object, request_id: object) -> ParkedDecision | None:
        if type(provider) is not str or type(request_id) is not str:
            return None
        now = self._clock()
        with self._lock:
            self._expire_locked(now)
            slot = self._first_locked(provider, request_id)
            if slot is not None:
                return self._snapshot(slot, decided=False)
            if (provider, request_id) in self._decided:
                return ParkedDecision(
                    provider=provider,
                    session_id="",
                    request_id=request_id,
                    tool_name="",
                    hold_until_epoch=self._wall(),
                    can_always_allow=False,
                    preview=None,
                    risk=None,
                    decided=True,
                )
        return None

    def parked_count(self) -> int:
        with self._lock:
            return len(self._slots)

    # -- internals --

    @staticmethod
    def _snapshot(slot: _Slot, *, decided: bool) -> ParkedDecision:
        facts = slot.facts
        return ParkedDecision(
            provider=facts.provider,
            session_id=facts.session_id,
            request_id=facts.request_id,
            tool_name=facts.tool_name,
            hold_until_epoch=slot.hold_until_epoch,
            can_always_allow=bool(facts.always_rules),
            preview=tool_preview(facts.tool_name, facts.tool_input),
            risk=tool_risk(facts.tool_name, facts.tool_input),
            decided=decided,
        )

    def _first_locked(self, provider: str, request_id: str) -> _Slot | None:
        # Oldest first: two identical calls in one turn share an id, and
        # the prompt on screen is the one that asked first.
        for token in sorted(self._slots):
            slot = self._slots[token]
            if slot.facts.provider == provider and slot.facts.request_id == request_id:
                return slot
        return None

    def _release_locked(self, slot: _Slot) -> None:
        slot.state = "released"
        slot.verdict = None
        self._slots.pop(slot.token, None)
        slot.event.set()

    def _expire_locked(self, now: float) -> None:
        for slot in list(self._slots.values()):
            if slot.deadline <= now:
                slot.state = "expired"
                self._slots.pop(slot.token, None)
                slot.event.set()
        for key, until in list(self._decided.items()):
            if until <= now:
                del self._decided[key]


#: How many ask previews are remembered, and for how long: an ask card
#: lives as long as its prompt, and a prompt nobody answers for an hour
#: has been answered in the terminal or abandoned.
MAX_ASK_PREVIEWS: Final = 64
ASK_PREVIEW_TTL_SECONDS: Final = 3600.0
#: Providers whose PermissionRequest carries ``tool_name``/``tool_input``.
PREVIEW_PROVIDERS: Final = frozenset({"claude", "codex", "devin", "grok", "opencode", "pi"})


class AskPreviews:
    """What every PermissionRequest the ingress sees wants to run, by its
    canonical request id -- so an ask card shows the command, the file or
    the URL whether or not the decide lane holds it (a hook installed
    before the lane existed, a provider the lane does not answer for)."""

    def __init__(self, *, clock: Callable[[], float] = time.monotonic) -> None:
        self._clock = clock
        self._lock = threading.Lock()
        self._rows: dict[tuple[str, str], tuple[float, str | None, str | None]] = {}

    def note(self, provider: object, payload_text: object) -> bool:
        if (
            type(provider) is not str
            or provider not in PREVIEW_PROVIDERS
            or type(payload_text) is not str
            or '"PermissionRequest"' not in payload_text
        ):
            return False
        from .provider_adapters import hook_request_identity

        routed = _request_identity(provider, payload_text)
        if routed is None or routed[1].event_name != "PermissionRequest":
            return False
        actual, record = routed
        raw = record.raw if isinstance(record.raw, dict) else {}
        request_id = hook_request_identity(record)
        tool_name = record.tool_name or raw.get("tool_name")
        tool_input = raw.get("tool_input")
        if request_id is None or not isinstance(tool_input, dict):
            return False
        preview = tool_preview(tool_name, tool_input)
        risk = tool_risk(tool_name, tool_input)
        if preview is None and risk is None:
            return False
        now = self._clock()
        with self._lock:
            self._rows[(actual, request_id)] = (now, preview, risk)
            if len(self._rows) > MAX_ASK_PREVIEWS:
                for key in sorted(self._rows, key=lambda key: self._rows[key][0])[
                    : len(self._rows) - MAX_ASK_PREVIEWS
                ]:
                    del self._rows[key]
        return True

    def lookup(self, provider: object, request_id: object) -> tuple[str | None, str | None]:
        if type(provider) is not str or type(request_id) is not str:
            return None, None
        with self._lock:
            row = self._rows.get((provider, request_id))
            if row is None:
                return None, None
            if self._clock() - row[0] > ASK_PREVIEW_TTL_SECONDS:
                del self._rows[(provider, request_id)]
                return None, None
            return row[1], row[2]


_DEFAULT_BROKER: DecisionBroker | None = None
_DEFAULT_PREVIEWS: AskPreviews | None = None
_DEFAULT_LOCK = threading.Lock()


def default_ask_previews() -> AskPreviews:
    global _DEFAULT_PREVIEWS
    with _DEFAULT_LOCK:
        if _DEFAULT_PREVIEWS is None:
            _DEFAULT_PREVIEWS = AskPreviews()
        return _DEFAULT_PREVIEWS


def ask_preview_for_request(request: object, previews: AskPreviews | None = None) -> tuple[str | None, str | None]:
    """``(preview, risk)`` for one operator-state request, by its exact key."""
    parts = _request_key_parts(request)
    if parts is None:
        return None, None
    return (previews or default_ask_previews()).lookup(*parts)


def default_decision_broker() -> DecisionBroker:
    """The daemon's one broker: the ingress parks into it, ``answer_ask``
    and the state projection read it."""
    global _DEFAULT_BROKER
    with _DEFAULT_LOCK:
        if _DEFAULT_BROKER is None:
            _DEFAULT_BROKER = DecisionBroker()
        return _DEFAULT_BROKER


def _request_key_parts(request: object) -> tuple[str, str] | None:
    key = getattr(request, "key", None)
    request_id = getattr(getattr(key, "request_id", None), "value", None)
    provider = getattr(getattr(getattr(key, "work_key", None), "source_key", None), "provider_id", None)
    if type(request_id) is not str or type(provider) is not str:
        return None
    return provider, request_id


def parked_decision_for_request(request: object, broker: object | None = None) -> ParkedDecision | None:
    """The parked entry for one operator-state request, by its exact key."""
    parts = _request_key_parts(request)
    if parts is None:
        return None
    lane = broker if broker is not None else default_decision_broker()
    try:
        return lane.parked(*parts)  # type: ignore[attr-defined]
    except Exception:
        return None


_VERBS: Final = {
    "approve": DecisionVerb.ALLOW,
    "deny": DecisionVerb.DENY,
    "always": DecisionVerb.ALWAYS,
}
_SENT_MESSAGES: Final = {
    DecisionVerb.ALLOW: "Approved through the agent's permission hook.",
    DecisionVerb.DENY: "Denied through the agent's permission hook.",
    DecisionVerb.ALWAYS: "Allowed, and the agent's own rule was saved so it won't ask again.",
}


def _live_request(controller: object, status: object) -> object | None:
    state = getattr(controller, "current_operator_state", None)
    work_key = getattr(status, "work_key", None)
    if state is None or work_key is None:
        return None
    for candidate in getattr(state, "requests", ()) or ():
        if candidate.key.work_key == work_key and candidate.phase.value.startswith("live"):
            return candidate
    return None


def answer_through_decision_lane(
    controller: object,
    status: object,
    args: Mapping[str, Any],
    *,
    journal_for: Callable[[object], Any],
    on_main: Callable[[Callable[[], Any]], Any],
    broker: DecisionBroker | None = None,
) -> dict[str, Any] | None:
    """``answer_ask`` for a request the decide lane holds, or ``None`` to
    let the keystroke path take it.

    The same fences as that path -- the live request, the card's pinned
    ``request`` identity, the command journal -- and none of its window
    checks, because nothing is typed: the verdict is the hook's own reply.
    ``always`` exists only here. A typed reply is never a decision.
    """
    from .core_server import CommandError

    verb = _VERBS.get(str(args.get("decision") or "approve").lower())
    if verb is None or args.get("reply_text") is not None:
        return None
    lane = broker if broker is not None else default_decision_broker()
    request = _live_request(controller, status)
    parked = None if request is None else parked_decision_for_request(request, lane)
    if parked is None:
        if verb is DecisionVerb.ALWAYS:
            raise CommandError(
                "unsupported",
                "Always allow is offered only while JR-Bar holds the agent's "
                "own permission prompt",
            )
        return None
    expected_request = args.get("request")
    if expected_request is not None:
        try:
            from .announcer_stack import announcer_alert_identity

            live_identity = str(announcer_alert_identity(request.key).value)  # type: ignore[union-attr]
        except Exception:
            live_identity = None
        if expected_request != live_identity:
            raise CommandError(
                "stale_request",
                "that request was replaced — the card is stale; answer the current ask",
            )
    if parked.decided:
        raise CommandError("stale_ask", "That ask was already answered from JR-Bar.")
    if verb is DecisionVerb.ALWAYS and not parked.can_always_allow:
        raise CommandError(
            "unsupported", "This agent offered no rule to remember; approve it once instead."
        )
    from .command_journal import STATUS_ACCEPTED, STATUS_COMPLETED

    decision = "always" if verb is DecisionVerb.ALWAYS else "approve" if verb is DecisionVerb.ALLOW else "deny"
    agent_id = getattr(status, "agent_id", None)
    journal = on_main(lambda: journal_for(controller))
    command_id = args.get("command_id")
    if type(command_id) is not str or not command_id:
        command_id = None
    record = on_main(
        lambda: journal.begin(
            "answer_ask",
            {"session": agent_id, "decision": decision, "request": expected_request},
            command_id=command_id,
        )
    )
    if record.status != STATUS_ACCEPTED:
        if record.status == STATUS_COMPLETED and record.receipt is not None:
            return {**record.receipt, "replayed": True}
        raise CommandError(
            (record.error or {}).get("code", "send_failed"),
            (record.error or {}).get("message", "that command already failed"),
        )
    outcome = lane.decide(parked.provider, parked.request_id, verb)
    if outcome is not DecisionResult.SENT:
        code, message = {
            DecisionResult.NOT_DELIVERED: (
                "stale_ask",
                "The agent stopped waiting for JR-Bar; answer it in its own prompt.",
            ),
            DecisionResult.NOT_PARKED: (
                "stale_ask",
                "JR-Bar's hold on that ask lapsed; the agent's own prompt is showing.",
            ),
            DecisionResult.ALREADY_DECIDED: ("stale_ask", "That ask was already answered from JR-Bar."),
            DecisionResult.UNSUPPORTED: ("unsupported", "That answer can't be sent for this ask."),
        }[outcome]
        on_main(
            lambda: journal.settle(record.command_id, error={"code": code, "message": message})
        )
        raise CommandError(code, message)
    refresh = getattr(controller, "refresh_", None)
    if callable(refresh):
        on_main(lambda: refresh(None))
    result = {
        "session": agent_id,
        "decision": decision,
        "answered": True,
        "delivered": True,
        "code": "sent",
        "message": _SENT_MESSAGES[verb],
        # The hook printed the verdict; the agent's own stream closing the
        # request is still what proves it landed.
        "confirmation": "provider_pending",
        "mechanism": "permission_hook",
    }
    on_main(lambda: journal.settle(record.command_id, receipt=result))
    return result


def release_for_open(status: object, broker: DecisionBroker | None = None) -> int:
    """Opening a session to answer it there lets its held prompts go, so a
    Codex prompt waiting behind the hook appears at once."""
    provider = getattr(status, "provider", None)
    session_id = getattr(status, "session_id", None)
    if type(provider) is not str or type(session_id) is not str or not session_id:
        return 0
    lane = broker if broker is not None else default_decision_broker()
    try:
        return lane.release(provider, session_id=session_id)
    except Exception:
        return 0


__all__ = [
    "ALWAYS_ALLOW_PROVIDERS",
    "DECIDED_TOMBSTONE_SECONDS",
    "DECIDE_PROVIDERS",
    "DECISION_HOLD_SECONDS",
    "DENY_MESSAGE",
    "MAX_PARKED_DECISIONS",
    "UNDECIDABLE_TOOLS",
    "AskPreviews",
    "DecisionBroker",
    "DecisionResult",
    "DecisionVerb",
    "ParkedDecision",
    "PermissionFacts",
    "always_allow_rules",
    "answer_through_decision_lane",
    "ask_preview_for_request",
    "decision_document",
    "default_ask_previews",
    "default_decision_broker",
    "parked_decision_for_request",
    "permission_facts",
    "release_for_open",
    "tool_preview",
    "tool_risk",
]
