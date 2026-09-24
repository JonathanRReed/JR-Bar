"""Answering through ``jrbar serve``: a Stream Deck key reaches the one answer
path the panel uses, bearer-authenticated and off by default."""

from __future__ import annotations

import json
import threading
import urllib.error
import urllib.request
from pathlib import Path

import pytest

from jrbar.cli_control import ControlError
from jrbar.core_server import CommandError
from jrbar.serve import create_serve_server
from jrbar.serve_answers import (
    ANSWER_SOCKET_TIMEOUT_SECONDS,
    DECK_SLOTS,
    READ_CACHE_SECONDS,
    SLOT_ANSWER_SETTLE_SECONDS,
    ControllerAnswers,
    CoreSocketAnswers,
    ServeAnswerRefused,
    _command_for,
    decode_answer_body,
    parse_answer_target,
    public_asks,
    receipt_document,
)

TOKEN = b"serve-answer-test-token-0123456789"


def test_a_key_can_put_the_whole_answer_in_its_url() -> None:
    assert parse_answer_target({"slot": "2", "decision": "Deny"}, None) == {"slot": 2, "decision": "deny"}
    assert parse_answer_target({"session": " claude:session:a ", "decision": "approve"}, None) == {
        "session": "claude:session:a",
        "decision": "approve",
    }


def test_a_json_body_carries_a_choice_and_wins_over_the_query() -> None:
    target = parse_answer_target(
        {"decision": "approve", "slot": "1"},
        {"decision": "answer", "answers": {"Which branch?": "main"}, "request": "request:v1:{}"},
    )
    assert target == {
        "slot": 1,
        "decision": "answer",
        "answers": {"Which branch?": "main"},
        "request": "request:v1:{}",
    }


@pytest.mark.parametrize(
    ("query", "body"),
    [
        ({"slot": "1"}, None),  # an answer names its verb
        ({"slot": "1", "decision": "maybe"}, None),
        ({"decision": "approve"}, None),  # nobody named
        ({"slot": "1", "session": "s", "decision": "approve"}, None),
        ({"slot": "0", "decision": "approve"}, None),
        ({"slot": str(DECK_SLOTS + 1), "decision": "approve"}, None),
        ({"slot": "two", "decision": "approve"}, None),
        ({}, {"slot": 2.5, "decision": "approve"}),
        ({}, {"slot": True, "decision": "approve"}),
        ({}, {"slot": 1e999, "decision": "approve"}),
        ({}, {"session": 7, "decision": "approve"}),
        ({"slot": "1", "decision": "answer"}, None),  # a choice needs its answers
        ({}, {"slot": 1, "decision": "approve", "answers": {"q": "a"}}),
        ({}, {"slot": 1, "decision": "approve", "request": ""}),
        ({}, ["not", "an", "object"]),
    ],
)
def test_anything_else_is_refused_whole(query: dict, body: object) -> None:
    with pytest.raises(ServeAnswerRefused) as refused:
        parse_answer_target(query, body)
    assert refused.value.code == "invalid_args" and refused.value.http_status == 400


def test_the_body_is_empty_or_one_json_object() -> None:
    assert decode_answer_body(b"") is None and decode_answer_body(b"  \n") is None
    assert decode_answer_body(b'{"slot": 1}') == {"slot": 1}
    for raw in (b"{", b"\xff", b'{"slot": NaN}'):
        with pytest.raises(ServeAnswerRefused):
            decode_answer_body(raw)


def test_a_slot_answers_through_deck_answer_and_a_session_through_answer_ask() -> None:
    assert _command_for({"slot": 3, "decision": "always", "request": "r"}) == (
        "deck_answer",
        {"index": 2, "decision": "always", "request": "r"},
    )
    assert _command_for({"session": "s", "decision": "deny"}) == (
        "answer_ask",
        {"session": "s", "decision": "deny", "only_if_frontmost": True},
    )


def test_the_receipt_says_the_verdict_never_the_host() -> None:
    receipt = receipt_document(
        {"session": "s", "decision": "approve", "answered": True, "mechanism": "permission_hook",
         "host": {"pid": 42, "tty": "/dev/ttys001"}, "key": "1"}
    )
    assert receipt == {"ok": True, "result": {"session": "s", "decision": "approve", "answered": True,
                                              "mechanism": "permission_hook"}}


STATE = {
    "sessions": [
        {"id": "claude:session:a", "provider": "claude", "label": "jr-bar-b7"},
        {"id": "codex:session:b", "provider": "codex", "label": "sidepulse-core"},
    ],
    "asks": [
        {"session": "claude:session:a", "kind": "permission", "request": "request:v1:a", "opened_at": 10.0,
         "answerable": True, "summary": "Bash", "preview": "rm   -rf build", "risk": "destructive",
         "decision": {"always": True, "choices": []}},
        {"session": "codex:session:b", "kind": "input", "answerable": False, "summary": "x" * 400,
         "decision": {"always": False, "choices": [{"question": "Which?", "options": ["a", "b"]}]}},
        {"kind": "orphan"},
    ],
    "deck": {"slots": [{"index": 0, "session": "codex:session:b"}, {"index": 4, "session": "claude:session:a"}]},
}


def test_asks_say_which_answers_each_one_takes() -> None:
    first, second = public_asks(STATE)
    assert first == {
        "session": "claude:session:a", "provider": "claude", "label": "jr-bar-b7", "slot": 5,
        "kind": "permission", "request": "request:v1:a", "opened_at": 10.0, "preview": "rm -rf build",
        "risk": "destructive", "decisions": ["approve", "deny", "always"], "choices": [],
    }
    assert second["slot"] == 1 and second["decisions"] == ["answer"]
    assert len(second["preview"]) == 120
    assert public_asks({}) == []


def test_an_ask_already_decided_offers_no_always_and_no_choice() -> None:
    # The seconds after an answer, while the agent's events catch up: the
    # hold is spent, so a key must not draw an Always allow or a choice the
    # answer path would only refuse as stale.
    decided = {
        **STATE,
        "asks": [
            {**ask, "decision": {**ask["decision"], "decided": True}}
            for ask in STATE["asks"]
            if "decision" in ask
        ],
    }
    first, second = public_asks(decided)
    assert first["decisions"] == ["approve", "deny"]
    assert second["decisions"] == [] and second["choices"] == []


class _Controller:
    def __init__(self, *, enabled: bool, reply=None, error: CommandError | None = None) -> None:
        self.settings = type("S", (), {"serve_answer_enabled": enabled})()
        self._core_lock = threading.RLock()
        self._core_documents = {"state": STATE}
        self.sent: list[tuple[str, dict]] = []
        self._reply = reply or {"answered": True}
        self._error = error

    def _core_dispatch(self, name, args):
        self.sent.append((name, args))
        if self._error is not None:
            raise self._error
        return self._reply


def test_the_daemons_own_source_reads_the_switch_and_speaks_its_refusals() -> None:
    assert not ControllerAnswers(_Controller(enabled=False)).enabled()
    controller = _Controller(enabled=True)
    answers = ControllerAnswers(controller)
    assert answers.enabled() and len(answers.asks()) == 2
    assert answers.answer({"slot": 1, "decision": "deny"}) == {"answered": True}
    assert controller.sent == [("deck_answer", {"index": 0, "decision": "deny"})]
    refusing = ControllerAnswers(_Controller(enabled=True, error=CommandError("stale_ask", "already answered")))
    with pytest.raises(ServeAnswerRefused) as refused:
        refusing.answer({"session": "s", "decision": "approve"})
    assert refused.value.code == "stale_ask" and refused.value.http_status == 409


class _Connection:
    def __init__(self, *, settings=None, error: ControlError | None = None) -> None:
        self.settings = settings or {"document": {"serve_answer_enabled": True}}
        self.error = error
        self.commands: list[tuple[str, dict]] = []

    def __enter__(self):
        return self

    def __exit__(self, *_exc):
        return None

    def document(self, kind):
        return self.settings if kind == "settings" else {"t": "state", **STATE}

    def command(self, name, args):
        self.commands.append((name, args))
        if self.error is not None:
            raise self.error
        return {"answered": True}


def test_a_standalone_serve_answers_over_the_core_socket() -> None:
    connection = _Connection()
    answers = CoreSocketAnswers(Path("/tmp/core.sock"), connect=lambda _path, **_kw: connection)
    assert answers.enabled() and len(answers.asks()) == 2
    assert answers.answer({"session": "s", "decision": "always"}) == {"answered": True}
    assert connection.commands == [("answer_ask", {"session": "s", "decision": "always", "only_if_frontmost": True})]
    off = CoreSocketAnswers(Path("/x"), connect=lambda _path, **_kw: _Connection(settings={"document": {}}))
    assert not off.enabled()
    refused = CoreSocketAnswers(
        Path("/x"),
        connect=lambda _path, **_kw: _Connection(error=ControlError("deck_answer: no ask", 1, code="not_found")),
    )
    with pytest.raises(ServeAnswerRefused) as refusal:
        refused.answer({"slot": 1, "decision": "approve"})
    assert refusal.value.code == "not_found" and refusal.value.http_status == 404


def test_a_standalone_answer_outwaits_the_daemons_answer_budget() -> None:
    # The daemon replies to answer_ask only once the surface has spoken --
    # up to its reply budget -- so a shorter recv timeout would report a
    # refusal for an answer that still gets typed.
    from jrbar.core_runtime import ANSWER_REPLY_BUDGET_SECONDS

    opened: list[tuple[str, float]] = []

    def connect(path: Path, *, timeout: float) -> _Connection:
        opened.append((str(path), timeout))
        return _Connection()

    answers = CoreSocketAnswers(Path("/tmp/core.sock"), connect=connect)
    assert answers.enabled() and answers.asks()
    answers.answer({"slot": 3, "decision": "deny"})
    reads, answer = opened[:-1], opened[-1]
    assert len(reads) == 1  # the switch and the asks share one connection
    assert answer == ("/tmp/core.sock", ANSWER_SOCKET_TIMEOUT_SECONDS)
    assert ANSWER_SOCKET_TIMEOUT_SECONDS > ANSWER_REPLY_BUDGET_SECONDS + 2.0
    # The reads stay quick: a wedged monitor must not hold /asks.json.
    assert all(timeout < ANSWER_REPLY_BUDGET_SECONDS for _path, timeout in reads)


def test_the_real_core_connection_is_opened_with_the_answer_timeout(monkeypatch: pytest.MonkeyPatch) -> None:
    import jrbar.cli_control as cli_control

    made: list[float] = []

    class _Recording(_Connection):
        def __init__(self, path: Path, timeout: float = 3.0) -> None:
            super().__init__()
            made.append(timeout)

    monkeypatch.setattr(cli_control, "CoreConnection", _Recording)
    CoreSocketAnswers(Path("/tmp/core.sock")).answer({"session": "s", "decision": "approve"})
    assert made == [ANSWER_SOCKET_TIMEOUT_SECONDS]


class _Answers:
    def __init__(self, *, enabled: bool = True, refusal: Exception | None = None) -> None:
        self.on = enabled
        self.refusal = refusal
        self.targets: list[dict] = []

    def enabled(self) -> bool:
        return self.on

    def asks(self):
        return public_asks(STATE)

    def answer(self, target):
        self.targets.append(target)
        if self.refusal is not None:
            raise self.refusal
        return {"session": "claude:session:a", "decision": target["decision"], "answered": True, "host": {"pid": 1}}


def _serve(answers, **kwargs):
    server = create_serve_server(port=0, answers=answers, **kwargs)
    thread = threading.Thread(target=server.serve_forever, daemon=True)
    thread.start()
    return server, f"http://127.0.0.1:{server.server_address[1]}"


def _call(url: str, *, data: bytes | None = None, token: bytes | None = TOKEN, method: str = "POST"):
    request = urllib.request.Request(url, data=data, method=method)
    if token is not None:
        request.add_header("Authorization", f"Bearer {token.decode()}")
    if data is not None:
        request.add_header("Content-Type", "application/json")
    try:
        with urllib.request.urlopen(request, timeout=5) as response:
            return response.status, json.loads(response.read() or b"null")
    except urllib.error.HTTPError as error:
        body = error.read()
        return error.code, (json.loads(body) if body.startswith(b"{") else None)


def test_the_endpoint_answers_a_key_through_the_wired_source() -> None:
    answers = _Answers()
    server, base = _serve(answers, status_access_token=TOKEN)
    try:
        status, body = _call(f"{base}/answer?slot=2&decision=deny")
        assert status == 200
        assert body == {"ok": True, "result": {"session": "claude:session:a", "decision": "deny", "answered": True}}
        status, _ = _call(f"{base}/answer", data=json.dumps(
            {"session": "claude:session:a", "decision": "answer", "answers": {"Which?": "a"}}).encode())
        assert status == 200
        assert answers.targets == [
            {"slot": 2, "decision": "deny"},
            {"session": "claude:session:a", "decision": "answer", "answers": {"Which?": "a"}},
        ]
        status, body = _call(f"{base}/asks.json", method="GET")
        assert status == 200 and [ask["slot"] for ask in body["asks"]] == [5, 1]
    finally:
        server.shutdown()
        server.server_close()


def test_the_endpoint_is_never_anonymous_and_off_until_switched_on() -> None:
    answers = _Answers(enabled=False)
    server, base = _serve(answers, status_access_token=TOKEN, allow_anonymous_status=True)
    try:
        assert _call(f"{base}/answer?slot=1&decision=approve", token=None)[0] == 401
        assert _call(f"{base}/asks.json", token=None, method="GET")[0] == 401
        assert _call(f"{base}/answer?slot=1&decision=approve", token=b"wrong-token-wrong-token-wrong")[0] == 401
        status, body = _call(f"{base}/answer?slot=1&decision=approve")
        assert status == 403 and body["error"]["code"] == "answering_off"
        assert _call(f"{base}/asks.json", method="GET")[0] == 403
        assert answers.targets == []
    finally:
        server.shutdown()
        server.server_close()


def test_refusals_carry_the_answer_paths_code_and_a_fitting_status() -> None:
    answers = _Answers(refusal=ServeAnswerRefused("stale_ask", "That ask was already answered from JR-Bar."))
    server, base = _serve(answers, status_access_token=TOKEN)
    try:
        status, body = _call(f"{base}/answer?slot=1&decision=approve")
        assert status == 409 and body["error"] == {"code": "stale_ask",
                                                   "message": "That ask was already answered from JR-Bar."}
        status, body = _call(f"{base}/answer?slot=99&decision=approve")
        assert status == 400 and body["error"]["code"] == "invalid_args"
        assert _call(f"{base}/answer", data=b"x" * (16 * 1024 + 1))[0] == 413
        assert _call(f"{base}/elsewhere")[0] == 404
        crowded = "&".join(f"f{index}=1" for index in range(12))
        status, body = _call(f"{base}/answer?slot=1&decision=approve&{crowded}")
        assert status == 400 and body["error"]["message"] == "too many query fields"
    finally:
        server.shutdown()
        server.server_close()

    # An unexpected failure on the answer path is said, never a dropped socket.
    server, base = _serve(_Answers(refusal=RuntimeError("socket thread gone")), status_access_token=TOKEN)
    try:
        status, body = _call(f"{base}/answer?slot=1&decision=approve")
        assert status == 500 and body["error"]["code"] == "internal"
    finally:
        server.shutdown()
        server.server_close()


def test_no_source_wired_means_no_answer_routes() -> None:
    server, base = _serve(None, status_access_token=TOKEN)
    try:
        assert _call(f"{base}/answer?slot=1&decision=approve")[0] == 404
        assert _call(f"{base}/asks.json", method="GET")[0] == 404
    finally:
        server.shutdown()
        server.server_close()
    with pytest.raises(ValueError):
        create_serve_server(port=0, answers=object())


def test_the_cli_wires_answers_only_when_asked(monkeypatch) -> None:
    from jrbar.cli import SERVE_ACCESS_TOKEN_ENV, build_jrbar_parser, cmd_serve

    parser = build_jrbar_parser()
    calls = []
    monkeypatch.setattr("jrbar.serve.serve", lambda **kwargs: calls.append(kwargs))
    monkeypatch.setenv(SERVE_ACCESS_TOKEN_ENV, TOKEN.decode())
    assert cmd_serve(parser.parse_args(["serve"])) == 0
    assert calls[-1]["answers"] is None
    assert cmd_serve(parser.parse_args(["serve", "--allow-answers"])) == 0
    assert isinstance(calls[-1]["answers"], CoreSocketAnswers)


def test_answering_from_serve_is_off_by_default_and_round_trips(tmp_path: Path) -> None:
    from jrbar.core_runtime import settings_from_document
    from jrbar.settings import AgentMonitorSettings

    assert AgentMonitorSettings().serve_answer_enabled is False
    document = AgentMonitorSettings().with_serve_answer_enabled(True).to_dict()
    assert document["serve_answer_enabled"] is True
    assert settings_from_document(document, scratch_dir=tmp_path).serve_answer_enabled is True
    mistyped = {**document, "serve_answer_enabled": "yes"}
    assert settings_from_document(mistyped, scratch_dir=tmp_path).serve_answer_enabled is False


def test_a_poll_reads_the_switch_and_the_asks_over_one_connection__and_1_more() -> None:
    # --- scenario: one connection serves the reads for a second, then a fresh one
    opened: list[_Connection] = []
    clock = [100.0]

    def connect(_path: Path, **_kw) -> _Connection:
        opened.append(_Connection())
        return opened[-1]

    answers = CoreSocketAnswers(Path("/tmp/core.sock"), connect=connect, monotonic=lambda: clock[0])
    assert answers.enabled() and len(answers.asks()) == 2
    assert answers.enabled() and len(answers.asks()) == 2
    assert len(opened) == 1
    clock[0] += READ_CACHE_SECONDS
    assert answers.enabled()
    assert len(opened) == 2

    # --- scenario: a failed read caches nothing
    failures = [ControlError("the JR-Bar monitor is not running", 1)]

    class _Down(_Connection):
        def __enter__(self):
            if failures:
                raise failures.pop()
            return self

    flaky = CoreSocketAnswers(Path("/x"), connect=lambda _path, **_kw: _Down(), monotonic=lambda: 5.0)
    assert not flaky.enabled()
    assert flaky.enabled()


def test_a_slot_answer_waits_out_an_ask_that_just_replaced_the_keys__and_2_more() -> None:
    """``/answer?slot=2&decision=approve`` names no request, and deck_answer
    answers whatever that slot holds when the press lands -- possibly an ask
    that replaced the one the key showed a moment ago."""
    fresh_state = {
        **STATE,
        "asks": [{**STATE["asks"][0], "opened_at": 1_000.0}, *STATE["asks"][1:]],
    }

    # --- scenario: the daemon's own source refuses stale_request until the ask settles
    controller = _Controller(enabled=True)
    controller._core_documents = {"state": fresh_state}
    now = [1_000.0 + SLOT_ANSWER_SETTLE_SECONDS - 0.1]
    answers = ControllerAnswers(controller, clock=lambda: now[0])
    with pytest.raises(ServeAnswerRefused) as refused:
        answers.answer({"slot": 5, "decision": "approve"})
    assert refused.value.code == "stale_request" and refused.value.http_status == 409
    assert controller.sent == []
    now[0] = 1_000.0 + SLOT_ANSWER_SETTLE_SECONDS
    assert answers.answer({"slot": 5, "decision": "approve"}) == {"answered": True}

    # --- scenario: a pinned request, a session answer or another slot is never held back
    now[0] = 1_000.0
    answers.answer({"slot": 5, "decision": "approve", "request": "request:v1:a"})
    answers.answer({"session": "claude:session:a", "decision": "approve"})
    answers.answer({"slot": 1, "decision": "deny"})
    assert [name for name, _args in controller.sent] == ["deck_answer", "deck_answer", "answer_ask", "deck_answer"]

    # --- scenario: a standalone serve checks the state its answer connection opened with
    class _Fresh(_Connection):
        def document(self, kind):
            return self.settings if kind == "settings" else {"t": "state", **fresh_state}

    connection = _Fresh()
    standalone = CoreSocketAnswers(Path("/x"), connect=lambda _path, **_kw: connection, clock=lambda: 1_000.5)
    with pytest.raises(ServeAnswerRefused) as refused:
        standalone.answer({"slot": 5, "decision": "deny"})
    assert refused.value.code == "stale_request"
    assert connection.commands == []
