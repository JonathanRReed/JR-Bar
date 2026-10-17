"""Socket-free checks for the local ingest and status request boundaries."""

from __future__ import annotations

import io
import json
import threading
from email.message import Message
from types import SimpleNamespace

import pytest

from jrbar import cloud_ingest, serve
from jrbar.agent_browser_payloads import AgentBrowserActionPayload
from jrbar.capacity_types import SourceKey
from jrbar.navigation_policy import OperatorActionKind
from jrbar.provider_facts import WorkIdentifier, WorkKey
from jrbar.serve_answers import ServeAnswerRefused, decode_answer_body, parse_answer_target

TOKEN = b"synthetic-loopback-token-0123456789"


def _handler(headers: list[tuple[str, str]], *, body: bytes = b"", path: str = "/answer"):
    handler = serve._ServeHandler.__new__(serve._ServeHandler)
    handler.headers = Message()
    for name, value in headers:
        handler.headers[name] = value
    handler.path = path
    handler.rfile = io.BytesIO(body)
    handler.wfile = io.BytesIO()
    handler.server = SimpleNamespace(
        serve_configuration=serve.ServeConfiguration(status_access_token=TOKEN),
        server_address=("127.0.0.1", 8737),
        deadlines=SimpleNamespace(disarm=lambda request: None),
    )
    handler.request = object()
    return handler


@pytest.mark.parametrize("headers", [
    [("Host", "127.0.0.1"), ("host", "evil.example")],
    [("Authorization", "Bearer x"), ("authorization", "Bearer y")],
    [("Content-Length", "0"), ("Content-Length", "1")],
    [("Transfer-Encoding", "chunked")],
    [("Origin", "")],
    [("Origin", "https://example.test")],
])
def test_serve_rejects_ambiguous_headers_and_browser_origins(headers):
    handler = _handler([])
    handler.raw_requestline = b"GET /status.json HTTP/1.0\r\n"
    handler.rfile = io.BytesIO(
        ("".join(f"{name}: {value}\r\n" for name, value in headers) + "\r\n").encode()
    )
    errors = []
    handler.send_error = lambda code: errors.append(code)
    assert handler.parse_request() is False
    assert errors == [403 if headers[0][0] == "Origin" else 400]


class _Answers:
    def __init__(self, *, fail: bool = False):
        self.calls = []
        self.fail = fail

    def asks(self):
        raise RuntimeError("synthetic private credential")

    def answer(self, target):
        self.calls.append(target)
        if self.fail:
            raise RuntimeError("synthetic private credential")
        return {"answered": True}


@pytest.mark.parametrize("length,body,path,status", [
    ("+1", b"x", "/answer", 400),
    ("\u00b2", b"x", "/answer", 400),
    ("9" * 5000, b"", "/answer", 413),
    ("20", b'{}', "/answer", 400),
    ("0", b"", "/answer?slot=1&slot=2&decision=approve", 400),
])
def test_invalid_answer_framing_never_calls_the_source(length, body, path, status):
    handler = _handler([("Content-Length", length)], body=body, path=path)
    answers = _Answers()
    handler._answer_source = lambda: answers
    responses = []
    handler._send_json = lambda code, document: responses.append((code, document))
    handler._serve_answer()
    assert responses[0][0] == status
    assert answers.calls == []


def test_unexpected_answer_errors_never_reveal_exception_content():
    handler = _handler([], path="/answer?slot=1&decision=approve")
    handler._answer_source = lambda: _Answers(fail=True)
    responses = []
    handler._send_json = lambda code, document: responses.append((code, document))
    handler._serve_answer()
    handler._serve_asks()
    assert [code for code, _ in responses] == [500, 500]
    assert "private credential" not in json.dumps(responses)


@pytest.mark.parametrize("failure", ["worker", "deadline"])
def test_serve_releases_connection_slot_when_worker_start_fails(monkeypatch, failure):
    server = serve._ServeServer.__new__(serve._ServeServer)
    server._connection_slots = threading.BoundedSemaphore(1)
    server._slot_lock = threading.Lock()
    server._slot_holders = set()
    disarmed = []
    def fail(*args):
        raise RuntimeError("cannot start worker")

    server.deadlines = SimpleNamespace(
        arm=fail if failure == "deadline" else lambda request: None,
        disarm=disarmed.append,
    )
    monkeypatch.setattr(serve.ThreadingHTTPServer, "process_request", fail)
    monkeypatch.setattr(serve.ThreadingHTTPServer, "shutdown_request", lambda *args: None)
    request = object()
    with pytest.raises(RuntimeError, match="cannot start worker"):
        server.process_request(request, ("127.0.0.1", 1))
    assert disarmed == [request]
    assert server._slot_holders == set()
    assert server._connection_slots.acquire(blocking=False)


def test_ingest_releases_connection_slot_when_deadline_start_fails(monkeypatch):
    server = cloud_ingest._IngestHTTPServer.__new__(cloud_ingest._IngestHTTPServer)
    server._slots = threading.BoundedSemaphore(1)
    disarmed = []

    def fail(request):
        raise RuntimeError("cannot start timer")

    server.deadlines = SimpleNamespace(arm=fail, disarm=disarmed.append)
    request = object()
    with pytest.raises(RuntimeError, match="cannot start timer"):
        server.process_request(request, ("127.0.0.1", 1))
    assert disarmed == [request]
    assert server._slots.acquire(blocking=False)


@pytest.mark.parametrize("extra,reason", [
    ({"Origin": ""}, cloud_ingest.IngestReason.FORBIDDEN_ORIGIN),
    ({"Transfer-Encoding": "chunked"}, cloud_ingest.IngestReason.MALFORMED),
    ({"Content-Length": "9" * 5000}, cloud_ingest.IngestReason.BODY_TOO_LARGE),
])
def test_ingest_rejects_bad_framing_before_reading_body(extra, reason):
    ingest = cloud_ingest.CloudIngest(token=TOKEN.decode(), config=cloud_ingest.CloudIngestConfig(enabled=True))
    reads = []
    response = ingest.handle(
        method="POST", path=cloud_ingest.INGEST_PATH, peer_host="127.0.0.1",
        headers={"Host": "127.0.0.1", "Authorization": f"Bearer {TOKEN.decode()}",
                 "Content-Length": "0", **extra},
        read_body=lambda length: reads.append(length), now=100.0,
    )
    assert response.reason is reason
    assert reads == []


@pytest.mark.parametrize("field,value", [
    ("max_events_per_second", float("inf")),
    ("session_idle_seconds", float("nan")),
    ("max_past_skew_seconds", float("inf")),
    ("burst_events", 1.5),
    ("max_queue_events", True),
])
def test_ingest_limits_require_finite_numbers_and_integer_capacities(field, value):
    with pytest.raises(ValueError, match="invalid cloud ingest limits"):
        cloud_ingest.CloudIngestLimits(**{field: value})


@pytest.mark.parametrize("raw", [
    b'{"slot":1,"slot":2}',
    b'{"answers":{"question":"a","question":"b"}}',
    b"[" * 1200 + b"0" + b"]" * 1200,
    b" " * 16385,
], ids=("duplicate-target", "duplicate-choice", "nested-array", "oversized-whitespace"))
def test_answer_json_refuses_duplicates_depth_and_oversized_whitespace(raw):
    with pytest.raises(ServeAnswerRefused):
        decode_answer_body(raw)


def test_answer_target_refuses_unknown_fields():
    with pytest.raises(ServeAnswerRefused, match="unknown answer field"):
        parse_answer_target({}, {"slot": 1, "decision": "approve", "transcript": "synthetic"})


@pytest.mark.parametrize("preset", [[], {}, True, 5])
def test_browser_snooze_refuses_non_string_preset(preset):
    key = WorkKey(SourceKey("codex", "hooks", "local:test", "live_agent_events"), WorkIdentifier("payload"))
    with pytest.raises(ValueError, match="invalid agent browser action payload"):
        AgentBrowserActionPayload(key, 1, OperatorActionKind.SNOOZE, preset)
