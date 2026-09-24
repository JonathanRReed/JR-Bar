"""Answering through ``jrbar serve``: the Stream Deck's half of the answer path.

Stream Deck approvers answer a prompt from a physical key; ours goes through
the one answer path the panel uses. ``POST /answer`` names a session (the
daemon's id) or a deck slot (1-13, the key the Creator Micro and the Rail
show for it) and a decision -- ``approve``, ``deny``, ``always`` or
``answer`` with the picked options -- and the daemon runs ``answer_ask`` (or
``deck_answer`` for a slot): the same fences, command journal and decide
lane, so a key can never do what the panel's own buttons could not.
``GET /asks.json`` lists what is waiting and which of those verbs each ask
takes, so a key can draw only the buttons that work.

Both routes are bearer-authenticated like ``/status.json`` -- never
anonymous -- and answer only while ``serve_answer_enabled`` is on, a switch
of its own (off by default): reading the fleet and answering for the owner
are different grants. Nothing here types, raises a window or leaves the Mac.
"""

from __future__ import annotations

import json
import math
import threading
import time
from collections.abc import Callable, Mapping
from pathlib import Path
from typing import Any, Final

ANSWER_DECISIONS: Final = ("approve", "deny", "always", "answer")
#: The Creator Micro's session keys (``deck_session_board.SLOTS_PER_BANK``),
#: numbered from 1 as the keys are labelled.
DECK_SLOTS: Final = 13
MAX_ANSWER_BODY_BYTES: Final = 16 * 1024
MAX_REQUEST_IDENTITY: Final = 1024
MAX_SESSION_ID: Final = 512
MAX_PREVIEW: Final = 120
MAX_PUBLIC_ASKS: Final = 64
#: How long a standalone serve waits on core.sock for an answer's reply.
#: The daemon holds ``answer_ask`` open until the answer surface's own
#: verdict -- up to ``core_runtime.ANSWER_REPLY_BUDGET_SECONDS`` (6 s), plus
#: the hops to its main thread for the journal and the refresh -- and may send
#: nothing on the socket meanwhile. This must stay above that, or a slow
#: first focus check reads as "monitor unreachable" while the answer is
#: still typed, and the key's next press answers whatever ask comes next.
ANSWER_SOCKET_TIMEOUT_SECONDS: Final = 12.0
#: The reads (the switch, the waiting asks) come back at once.
READ_SOCKET_TIMEOUT_SECONDS: Final = 3.0
#: How long one core connection's settings and state serve the reads. Each
#: poll used to open two connections, each sent hello, state, lights and
#: settings (about 32 KB) and each took one of the daemon's four client
#: slots; a poll's switch check and ask list now share one.
READ_CACHE_SECONDS: Final = 1.0
#: A slot answer that names no ``request`` is refused while the ask on that
#: slot is younger than this: the key may still have shown the ask it
#: replaced. The panel always pins ``request``; a URL-only key cannot.
SLOT_ANSWER_SETTLE_SECONDS: Final = 1.5
#: What a receipt may carry back over HTTP: the verdict, never the host's
#: pid, tty or window evidence.
_RECEIPT_FIELDS: Final = frozenset(
    {
        "session",
        "index",
        "decision",
        "answered",
        "delivered",
        "mechanism",
        "code",
        "message",
        "confirmation",
        "replayed",
    }
)
#: HTTP status for each refusal code the answer path can raise; anything
#: else is a conflict with the ask's current state.
_REFUSAL_STATUS: Final = {
    "invalid_args": 400,
    "not_found": 404,
    "answering_off": 403,
    "unavailable": 503,
}


class ServeAnswerRefused(Exception):
    """A refusal with the answer path's own code and sentence."""

    def __init__(self, code: str, message: str) -> None:
        super().__init__(message)
        self.code = code
        self.message = message

    @property
    def http_status(self) -> int:
        return _REFUSAL_STATUS.get(self.code, 409)

    def document(self) -> dict[str, Any]:
        return {"ok": False, "error": {"code": self.code, "message": self.message}}


def _refuse(message: str) -> ServeAnswerRefused:
    return ServeAnswerRefused("invalid_args", message)


def parse_answer_target(query: Mapping[str, str], body: object) -> dict[str, Any]:
    """One validated answer from a query string and/or a JSON object body.

    A Stream Deck "API request" key can put everything in the URL
    (``/answer?slot=2&decision=deny``); a script can send JSON. The body
    wins where both name a field. Exactly one of ``session`` / ``slot``,
    an explicit ``decision``, ``answers`` (an object) only with ``answer``.
    Raises ``ServeAnswerRefused`` (``invalid_args``) on anything else.
    """
    if body is not None and not isinstance(body, dict):
        raise _refuse("the body must be a JSON object")
    fields: dict[str, Any] = {**dict(query), **(body or {})}
    decision = fields.get("decision")
    if not isinstance(decision, str) or decision.strip().lower() not in ANSWER_DECISIONS:
        raise _refuse("decision must be approve, deny, always or answer")
    target: dict[str, Any] = {"decision": decision.strip().lower()}
    session, slot = fields.get("session"), fields.get("slot")
    if (session is None) == (slot is None):
        raise _refuse("name one session or one deck slot")
    if session is not None:
        if not isinstance(session, str) or not session.strip() or len(session) > MAX_SESSION_ID:
            raise _refuse("session must be a session id")
        target["session"] = session.strip()
    else:
        if isinstance(slot, bool):
            raise _refuse(f"slot must be 1..{DECK_SLOTS}")
        try:
            number = int(slot)
        except (TypeError, ValueError, OverflowError):
            raise _refuse(f"slot must be 1..{DECK_SLOTS}") from None
        if isinstance(slot, float) and not slot.is_integer():
            raise _refuse(f"slot must be 1..{DECK_SLOTS}")
        if not 1 <= number <= DECK_SLOTS:
            raise _refuse(f"slot must be 1..{DECK_SLOTS}")
        target["slot"] = number
    answers = fields.get("answers")
    if target["decision"] == "answer":
        if not isinstance(answers, dict) or not answers:
            raise _refuse("answer needs answers: {<question>: <label>} as JSON")
        target["answers"] = answers
    elif answers is not None:
        raise _refuse("answers go with decision answer only")
    request = fields.get("request")
    if request is not None:
        if not isinstance(request, str) or not request or len(request) > MAX_REQUEST_IDENTITY:
            raise _refuse("request must be the ask's request identity")
        target["request"] = request
    return target


def decode_answer_body(raw: bytes) -> object:
    """The POST body: empty (everything in the query) or one JSON object."""
    if not raw.strip():
        return None
    try:
        return json.loads(raw.decode("utf-8"), parse_constant=_reject_constant)
    except (UnicodeDecodeError, ValueError):
        raise _refuse("the body must be a JSON object") from None


def _reject_constant(_value: str) -> None:
    raise ValueError("non-finite number")


def receipt_document(result: Mapping[str, Any]) -> dict[str, Any]:
    """The answer's verdict for the HTTP caller, host details left out."""
    return {"ok": True, "result": {key: value for key, value in result.items() if key in _RECEIPT_FIELDS}}


def _text(value: object, limit: int) -> str | None:
    if not isinstance(value, str):
        return None
    text = " ".join(value.split())
    return text[:limit] if text else None


def public_asks(state: Mapping[str, Any]) -> list[dict[str, Any]]:
    """What is waiting, from a ``state`` document, for a key to draw.

    Each ask names its session, provider and label, the deck slot showing
    it (1-based, the current bank; null when it has none), its kind and
    ``request`` identity, one bounded line of what it wants, and the
    ``decisions`` an answer may carry: ``approve``/``deny`` only while it is
    ``answerable``, ``always`` only when the agent offered a rule to
    remember, ``answer`` only for a held question with ``choices``. An ask
    the decide lane has already ``decided`` (the seconds while the agent's
    events catch up) is held no longer, so it offers neither -- the app's
    own ``canAlwaysAllow`` and ``canChoose`` read it the same way.
    """
    sessions = {
        row.get("id"): row
        for row in state.get("sessions") or ()
        if isinstance(row, dict) and isinstance(row.get("id"), str)
    }
    slots: dict[str, int] = {}
    deck = state.get("deck") if isinstance(state.get("deck"), dict) else {}
    for slot in deck.get("slots") or ():
        if isinstance(slot, dict) and isinstance(slot.get("session"), str):
            index = slot.get("index")
            if isinstance(index, int) and not isinstance(index, bool) and 0 <= index < DECK_SLOTS:
                slots.setdefault(slot["session"], index + 1)
    public: list[dict[str, Any]] = []
    for ask in state.get("asks") or ():
        if not isinstance(ask, dict) or not isinstance(ask.get("session"), str):
            continue
        session = ask["session"]
        row = sessions.get(session, {})
        decision = ask.get("decision") if isinstance(ask.get("decision"), dict) else None
        held = decision is not None and decision.get("decided") is not True
        choices = [
            choice
            for choice in (decision or {}).get("choices") or ()
            if held and isinstance(choice, dict)
        ]
        verbs: list[str] = []
        if ask.get("answerable") is True:
            verbs += ["approve", "deny"]
        if held and decision.get("always") is True:
            verbs.append("always")
        if choices:
            verbs.append("answer")
        opened = ask.get("opened_at")
        public.append(
            {
                "session": session,
                "provider": row.get("provider") if isinstance(row.get("provider"), str) else None,
                "label": _text(row.get("label"), 80),
                "slot": slots.get(session),
                "kind": ask.get("kind") if isinstance(ask.get("kind"), str) else None,
                "request": ask.get("request") if isinstance(ask.get("request"), str) else None,
                "opened_at": opened if isinstance(opened, (int, float)) and not isinstance(opened, bool)
                and math.isfinite(float(opened)) else None,
                "preview": _text(ask.get("preview"), MAX_PREVIEW) or _text(ask.get("summary"), MAX_PREVIEW),
                "risk": ask.get("risk") if ask.get("risk") == "destructive" else None,
                "decisions": verbs,
                "choices": choices,
            }
        )
        if len(public) >= MAX_PUBLIC_ASKS:
            break
    return public


def refuse_a_slot_that_just_changed(target: Mapping[str, Any], state: Mapping[str, Any], *, now: float) -> None:
    """Raise ``stale_request`` for a slot answer with no ``request`` whose
    slot shows an ask that opened within ``SLOT_ANSWER_SETTLE_SECONDS``.
    ``deck_answer`` answers whatever the slot holds at press time; this is
    serve's own guard, so the app's Rail is untouched."""
    if "slot" not in target or "request" in target:
        return
    opened = [
        ask["opened_at"]
        for ask in public_asks(state)
        if ask["slot"] == target["slot"] and ask["opened_at"] is not None
    ]
    if opened and now - max(opened) < SLOT_ANSWER_SETTLE_SECONDS:
        raise ServeAnswerRefused(
            "stale_request",
            "The ask on that key just changed; look at the key and press it again.",
        )


def _command_for(target: Mapping[str, Any]) -> tuple[str, dict[str, Any]]:
    """The daemon command one validated target runs."""
    extras = {key: target[key] for key in ("answers", "request") if key in target}
    if "slot" in target:
        return "deck_answer", {"index": int(target["slot"]) - 1, "decision": target["decision"], **extras}
    return "answer_ask", {
        "session": target["session"],
        "decision": target["decision"],
        "only_if_frontmost": True,
        **extras,
    }


class ControllerAnswers:
    """The daemon's own serve thread: the switch, the published state and
    the command dispatch, in process."""

    def __init__(self, controller: object, *, clock: Callable[[], float] = time.time) -> None:
        self._controller = controller
        self._clock = clock

    def enabled(self) -> bool:
        return bool(getattr(getattr(self._controller, "settings", None), "serve_answer_enabled", False))

    def _state(self) -> Mapping[str, Any]:
        lock = getattr(self._controller, "_core_lock", None)
        documents = getattr(self._controller, "_core_documents", None) or {}
        if lock is None:
            return documents.get("state") or {}
        with lock:
            return documents.get("state") or {}

    def asks(self) -> list[dict[str, Any]]:
        return public_asks(self._state())

    def answer(self, target: Mapping[str, Any]) -> dict[str, Any]:
        from .core_server import CommandError

        refuse_a_slot_that_just_changed(target, self._state(), now=self._clock())
        name, args = _command_for(target)
        dispatch = getattr(self._controller, "_core_dispatch", None)
        if not callable(dispatch):
            raise ServeAnswerRefused("unavailable", "the monitor is still starting")
        try:
            result = dispatch(name, args)
        except CommandError as error:
            raise ServeAnswerRefused(error.code, str(error)) from None
        return result if isinstance(result, dict) else {}


class CoreSocketAnswers:
    """A standalone ``jrbar serve --allow-answers``: the same three reads and
    the one command, over the daemon's core socket."""

    def __init__(
        self,
        socket_path: Path,
        *,
        connect: Callable[..., Any] | None = None,
        clock: Callable[[], float] = time.time,
        monotonic: Callable[[], float] = time.monotonic,
    ) -> None:
        self._socket_path = socket_path
        self._connect = connect
        self._clock = clock
        self._monotonic = monotonic
        self._read_lock = threading.Lock()
        self._read: tuple[float, dict[str, Any], dict[str, Any] | None] | None = None

    def _connection(self, timeout: float = READ_SOCKET_TIMEOUT_SECONDS):
        if self._connect is not None:
            return self._connect(self._socket_path, timeout=timeout)
        from .cli_control import CoreConnection

        return CoreConnection(self._socket_path, timeout=timeout)

    def _documents(self) -> tuple[dict[str, Any], dict[str, Any] | None]:
        """``settings`` and ``state`` from one connection -- both arrive in
        the frames the daemon sends on connect -- kept ``READ_CACHE_SECONDS``.
        A state that does not come is ``None``; a failed connection raises
        ``ControlError`` and caches nothing."""
        from .cli_control import ControlError

        with self._read_lock:
            now = self._monotonic()
            cached = self._read
            if cached is not None and now - cached[0] < READ_CACHE_SECONDS:
                return cached[1], cached[2]
            with self._connection() as core:
                settings = core.document("settings")
                try:
                    state = core.document("state")
                except ControlError:
                    state = None
            self._read = (now, settings, state)
            return settings, state

    def enabled(self) -> bool:
        from .cli_control import ControlError

        try:
            settings, _state = self._documents()
        except ControlError:
            return False
        document = settings.get("document") if isinstance(settings.get("document"), dict) else settings
        return document.get("serve_answer_enabled") is True

    def asks(self) -> list[dict[str, Any]]:
        from .cli_control import ControlError

        try:
            _settings, state = self._documents()
        except ControlError as error:
            raise ServeAnswerRefused("unavailable", str(error)) from None
        if state is None:
            raise ServeAnswerRefused("unavailable", "the monitor sent no state yet")
        return public_asks(state)

    def answer(self, target: Mapping[str, Any]) -> dict[str, Any]:
        from .cli_control import ControlError

        name, args = _command_for(target)
        try:
            # Its own, longer wait: the daemon replies only once the answer
            # surface has said what happened, and a timeout here would call
            # a delivered answer a refusal.
            with self._connection(ANSWER_SOCKET_TIMEOUT_SECONDS) as core:
                if "slot" in target and "request" not in target:
                    # The state this connection opened with, not a cached
                    # one: the ask that just replaced the key's must count.
                    refuse_a_slot_that_just_changed(target, core.document("state"), now=self._clock())
                return core.command(name, args)
        except ControlError as error:
            raise ServeAnswerRefused(error.code or "unavailable", str(error)) from None


__all__ = [
    "ANSWER_DECISIONS",
    "ANSWER_SOCKET_TIMEOUT_SECONDS",
    "DECK_SLOTS",
    "MAX_ANSWER_BODY_BYTES",
    "READ_CACHE_SECONDS",
    "SLOT_ANSWER_SETTLE_SECONDS",
    "ControllerAnswers",
    "CoreSocketAnswers",
    "ServeAnswerRefused",
    "decode_answer_body",
    "parse_answer_target",
    "public_asks",
    "receipt_document",
    "refuse_a_slot_that_just_changed",
]
