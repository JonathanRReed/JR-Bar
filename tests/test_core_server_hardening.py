"""The daemon's socket under the inputs it should never trust itself with.

Three promises the protocol makes and the server has to keep: a frame is
always JSON the app can decode (a number that is not finite goes out as
``null``), a reply obeys the same size limit as every other frame, and a
scan that takes minutes does not hold up the short reads the person waits
on. Everything here is deterministic: an Event stands in for the slow work,
and every wait only bounds a hang.
"""

from __future__ import annotations

import json
import math
import shutil
import socket
import tempfile
import threading
from pathlib import Path

import pytest

from jrbar.core_server import MAX_FRAME_BYTES, CoreServer, encode_frame
from tests.test_core_server import _connect

HANG_BOUND_SECONDS = 30.0


@pytest.fixture
def sock_dir():
    """AF_UNIX paths are capped at 104 bytes; pytest's tmp_path is too long."""
    path = Path(tempfile.mkdtemp(prefix="jrbar-", dir=tempfile.gettempdir()))
    try:
        yield path
    finally:
        shutil.rmtree(path, ignore_errors=True)


def _bare_constant(token: str):
    raise ValueError(f"bare {token} is not JSON")


def strict_loads(line: bytes | str) -> dict:
    """The rule the Swift decoder applies: a bare NaN or Infinity token is
    not JSON, so the whole frame is refused."""
    return json.loads(line, parse_constant=_bare_constant)


def _read_strict(client: socket.socket, count: int, timeout: float = HANG_BOUND_SECONDS) -> list[dict]:
    client.settimeout(timeout)
    buffer = b""
    frames: list[dict] = []
    while len(frames) < count:
        while b"\n" in buffer and len(frames) < count:
            line, buffer = buffer.split(b"\n", 1)
            frames.append(strict_loads(line))
        if len(frames) >= count:
            break
        try:
            chunk = client.recv(65536)
        except TimeoutError:
            break
        if not chunk:
            break
        buffer += chunk
    return frames


def _command(command_id: str, name: str, args: dict | None = None) -> bytes:
    return encode_frame({"t": "command", "v": 1, "id": command_id, "name": name, "args": args or {}})


def _serve(sock_dir: Path, dispatch, documents=(), **overrides) -> CoreServer:
    kwargs = dict(
        dispatch=dispatch,
        initial_documents=lambda: list(documents),
        socket_path=sock_dir / "core.sock",
    )
    kwargs.update(overrides)
    instance = CoreServer(**kwargs)
    instance.start()
    return instance


# -- 1. a number that is not finite never reaches the wire ---------------------


NON_FINITE = (float("nan"), float("inf"), float("-inf"))


@pytest.mark.parametrize("bad", NON_FINITE, ids=("nan", "inf", "minus_inf"))
def test_a_frame_with_a_non_finite_number_is_still_json_the_app_can_decode(bad: float) -> None:
    document = {
        "t": "state",
        "v": 1,
        "usage": {"providers": [{"id": "claude", "windows": [{"used_pct": bad, "resets_at": 5.5}]}]},
        "battery": {"temperature_c": bad},
        "samples": [1.0, bad, [bad, {"deep": bad}]],
        "ok": True,
        "count": 3,
    }

    frame = encode_frame(document)

    assert frame.endswith(b"\n") and frame.count(b"\n") == 1
    decoded = strict_loads(frame)
    window = decoded["usage"]["providers"][0]["windows"][0]
    assert window == {"used_pct": None, "resets_at": 5.5}
    assert decoded["battery"] == {"temperature_c": None}
    assert decoded["samples"] == [1.0, None, [None, {"deep": None}]]
    # Everything that was finite is untouched, and the caller's document is
    # not rewritten behind its back.
    assert decoded["ok"] is True and decoded["count"] == 3
    assert math.isnan(document["battery"]["temperature_c"]) or document["battery"]["temperature_c"] == bad


def test_a_finite_frame_encodes_exactly_as_it_always_did() -> None:
    document = {"t": "state", "v": 1, "a": [1, 2.5, None, True, "xé"], "b": {"c": -0.0}}

    frame = encode_frame(document)

    assert frame == b'{"t":"state","v":1,"a":[1,2.5,null,true,"x\\u00e9"],"b":{"c":-0.0}}\n'


def test_non_finite_numbers_in_state_and_event_frames_reach_a_client_as_null(sock_dir: Path) -> None:
    watch = _LogWatch()
    instance = _serve(
        sock_dir,
        lambda name, args: {},
        documents=[{"t": "state", "generation": 1, "usage": {"x": float("nan")}}],
        log=watch,
    )
    try:
        instance._min_interval["state"] = 0
        client = _connect(instance)
        greeting = _read_strict(client, 2)
        assert [frame["t"] for frame in greeting] == ["hello", "state"]
        assert greeting[1]["usage"] == {"x": None}

        instance.publish_state({"generation": 2, "sessions": [{"id": "s", "age": [float("inf")]}]})
        instance.publish_event({"kind": "completed", "detail": {"left": float("-inf"), "n": 2}})
        frames = _read_strict(client, 2)
        by_kind = {frame["t"]: frame for frame in frames}
        assert by_kind["state"]["sessions"] == [{"id": "s", "age": [None]}]
        assert by_kind["event"]["detail"] == {"left": None, "n": 2}
        # Each sanitised frame is counted, and the first is logged.
        assert instance.stats["sanitized_frames"] == 3
        assert watch.count("non-finite") >= 1
        client.close()
    finally:
        instance.stop()


def test_a_reply_with_a_non_finite_number_is_sanitised_not_turned_into_a_repr(sock_dir: Path) -> None:
    instance = _serve(sock_dir, lambda name, args: {"until": float("inf"), "rows": [float("nan"), 1]})
    try:
        client = _connect(instance)
        _read_strict(client, 1)
        client.sendall(_command("c-1", "snooze"))
        reply = _read_strict(client, 1)[0]
        assert reply["ok"] is True
        assert reply["result"] == {"until": None, "rows": [None, 1]}
        client.close()
    finally:
        instance.stop()


class _LogWatch:
    """Collects the server's log lines and lets a test wait for the nth one
    that mentions a word, without sleeping."""

    def __init__(self) -> None:
        self.lines: list[str] = []
        self._condition = threading.Condition()

    def __call__(self, line: str) -> None:
        with self._condition:
            self.lines.append(line)
            self._condition.notify_all()

    def count(self, word: str) -> int:
        with self._condition:
            return sum(word in line for line in self.lines)

    def wait_for_count(self, word: str, expected: int) -> bool:
        with self._condition:
            return self._condition.wait_for(
                lambda: sum(word in line for line in self.lines) >= expected, HANG_BOUND_SECONDS
            )


def test_a_frame_that_cannot_be_encoded_is_a_counted_drop_and_the_connection_lives(sock_dir: Path) -> None:
    watch = _LogWatch()
    unencodable = {"t": "state", "generation": 1, "bad": {1, 2}}
    circular: dict = {"t": "lights"}
    circular["self"] = circular
    deep: list = []
    for _ in range(60_000):
        deep = [deep]
    instance = _serve(
        sock_dir,
        lambda name, args: {},
        documents=[unencodable, circular, {"t": "settings", "generation": 1, "deep": deep}, {"t": "state", "generation": 2}],
        log=watch,
    )
    try:
        instance._min_interval["state"] = 0
        client = _connect(instance)
        # hello, then only the document that could be encoded: the three
        # that could not are dropped one by one, never the connection.
        frames = _read_strict(client, 2)
        assert [frame["t"] for frame in frames] == ["hello", "state"]
        assert frames[1]["generation"] == 2
        assert instance.stats["dropped_unencodable"] == 3

        # The flusher and the event path survive the same kind of document.
        instance.publish_state({"generation": 3, "bad": {1}})
        assert watch.wait_for_count("could not encode", 4)
        instance.publish_event({"kind": "completed", "bad": object()})
        assert watch.wait_for_count("could not encode", 5)
        instance.publish_state({"generation": 4})
        instance.publish_event({"kind": "completed", "n": 1})
        later = _read_strict(client, 2)
        assert {frame["t"] for frame in later} == {"state", "event"}
        assert instance.stats["dropped_unencodable"] == 5
        client.sendall(_command("alive", "ping"))
        assert _read_strict(client, 1)[0]["id"] == "alive"
        client.close()
    finally:
        instance.stop()


def test_a_circular_document_is_a_value_error_not_a_recursion_error() -> None:
    circular: dict = {"t": "lights", "v": 1}
    circular["self"] = circular
    with pytest.raises(ValueError):
        encode_frame(circular)


def test_a_reply_whose_result_cannot_even_be_shown_still_answers_and_the_connection_lives(sock_dir: Path) -> None:
    class Unshowable:
        def __repr__(self) -> str:
            raise RuntimeError("no text for this")

    def dispatch(name: str, args: dict):
        return Unshowable() if name == "odd" else {}

    instance = _serve(sock_dir, dispatch)
    try:
        client = _connect(instance)
        _read_strict(client, 1)
        client.sendall(_command("odd-1", "odd"))
        reply = _read_strict(client, 1)[0]
        assert reply["id"] == "odd-1" and reply["ok"] is True
        assert isinstance(reply["result"]["repr"], str)
        client.sendall(_command("alive", "ping"))
        assert _read_strict(client, 1)[0]["id"] == "alive"
        client.close()
    finally:
        instance.stop()


# -- 2. a reply obeys the frame limit -----------------------------------------


def test_an_oversize_reply_becomes_a_frame_too_large_error_for_that_command(sock_dir: Path) -> None:
    watch = _LogWatch()

    def dispatch(name: str, args: dict):
        if name == "audit_export":
            return {"text": "x" * MAX_FRAME_BYTES}
        if name == "usage_graph":
            return {"text": "x" * MAX_FRAME_BYTES}
        return {"pong": True}

    instance = _serve(sock_dir, dispatch, log=watch)
    try:
        client = _connect(instance)
        _read_strict(client, 1)
        # The same answer from the reader thread and from the slow lane.
        client.sendall(_command("big-inline", "audit_export"))
        client.sendall(_command("big-slow", "usage_graph"))
        client.sendall(_command("after", "ping"))
        replies = {reply["id"]: reply for reply in _read_strict(client, 3)}
        for command_id in ("big-inline", "big-slow"):
            reply = replies[command_id]
            assert reply["ok"] is False
            assert reply["error"]["code"] == "frame_too_large"
            assert "limit" in reply["error"]["message"]
            assert "result" not in reply
        assert replies["after"]["result"] == {"pong": True}
        assert instance.stats["dropped_oversize"] == 2
        assert watch.count("oversize reply") == 2
        client.close()
    finally:
        instance.stop()


def test_a_reply_just_under_the_limit_is_delivered_whole(sock_dir: Path) -> None:
    envelope = len(encode_frame({"t": "reply", "v": 1, "id": "fit", "ok": True, "result": {"text": ""}}))
    text = "x" * (MAX_FRAME_BYTES - envelope)

    instance = _serve(sock_dir, lambda name, args: {"text": text})
    try:
        client = _connect(instance)
        _read_strict(client, 1)
        client.sendall(_command("fit", "audit_export"))
        reply = _read_strict(client, 1)[0]
        assert reply["ok"] is True and reply["result"]["text"] == text
        assert instance.stats["dropped_oversize"] == 0
        client.close()
    finally:
        instance.stop()


# -- 3. the short reads do not wait behind a scan ------------------------------


def test_a_history_read_is_answered_while_a_usage_scan_is_still_running(sock_dir: Path) -> None:
    """A usage_graph took 107 s and then 195 s; opening History used to
    queue behind it on the one slow-lane worker."""
    scan_running = threading.Event()
    release_scan = threading.Event()
    read_threads: dict[str, str] = {}

    def dispatch(name: str, args: dict):
        if name == "usage_graph":
            scan_running.set()
            assert release_scan.wait(HANG_BOUND_SECONDS)
            return {"scan": True}
        read_threads[name] = threading.current_thread().name
        return {"name": name}

    instance = _serve(sock_dir, dispatch)
    try:
        client = _connect(instance)
        _read_strict(client, 1)
        client.sendall(_command("scan", "usage_graph"))
        assert scan_running.wait(HANG_BOUND_SECONDS)
        client.sendall(_command("history", "list_history"))
        client.sendall(_command("timeline", "session_timeline"))
        client.sendall(_command("seen", "mark_history_seen"))
        # Every short read answers with the scan still held.
        replies = _read_strict(client, 3)
        assert [reply["id"] for reply in replies] == ["history", "timeline", "seen"]
        assert not release_scan.is_set()
        assert len(set(read_threads.values())) == 1
        assert next(iter(read_threads.values())) != "JRBarCoreClient1"
        release_scan.set()
        assert _read_strict(client, 1)[0]["id"] == "scan"
        client.close()
    finally:
        release_scan.set()
        instance.stop()


def test_two_scans_still_never_overlap_and_the_short_reads_stay_in_order(sock_dir: Path) -> None:
    running = 0
    overlap: list[int] = []
    guard = threading.Lock()
    first_scan_running = threading.Event()
    release_first_scan = threading.Event()
    order: list[str] = []

    def dispatch(name: str, args: dict):
        nonlocal running
        if name in ("usage_graph", "usage_history"):
            with guard:
                running += 1
                overlap.append(running)
            try:
                if name == "usage_graph":
                    first_scan_running.set()
                    assert release_first_scan.wait(HANG_BOUND_SECONDS)
            finally:
                with guard:
                    running -= 1
        else:
            order.append(name)
        return {"name": name}

    instance = _serve(sock_dir, dispatch)
    try:
        client = _connect(instance)
        _read_strict(client, 1)
        client.sendall(_command("graph", "usage_graph"))
        assert first_scan_running.wait(HANG_BOUND_SECONDS)
        client.sendall(_command("history", "usage_history"))
        client.sendall(_command("list", "list_history"))
        client.sendall(_command("mark", "mark_history_seen"))
        client.sendall(_command("compare", "compare_sessions"))
        first_replies = _read_strict(client, 3)
        # The reads answer in the order they were sent, behind nothing.
        assert [reply["id"] for reply in first_replies] == ["list", "mark", "compare"]
        assert order == ["list_history", "mark_history_seen", "compare_sessions"]
        # The second scan waits for the first: the one the person is watching
        # on Overview must not be slowed by a second parse of the same files.
        assert overlap == [1]
        release_first_scan.set()
        assert [reply["id"] for reply in _read_strict(client, 2)] == ["graph", "history"]
        assert overlap == [1, 1]
        client.close()
    finally:
        release_first_scan.set()
        instance.stop()


def test_a_backlog_of_scans_does_not_make_a_short_read_busy(
    sock_dir: Path, monkeypatch: pytest.MonkeyPatch
) -> None:
    from jrbar import core_server

    scan_running = threading.Event()
    release_scan = threading.Event()

    def dispatch(name: str, args: dict):
        if name == "usage_graph":
            scan_running.set()
            assert release_scan.wait(HANG_BOUND_SECONDS)
        return {"name": name}

    monkeypatch.setattr(core_server, "MAX_SLOW_LANE_QUEUED", 1)
    instance = _serve(sock_dir, dispatch)
    try:
        client = _connect(instance)
        _read_strict(client, 1)
        client.sendall(_command("s1", "usage_graph"))
        assert scan_running.wait(HANG_BOUND_SECONDS)
        client.sendall(_command("s2", "usage_graph"))
        client.sendall(_command("s3", "usage_graph"))
        client.sendall(_command("read", "doctor"))
        replies = {reply["id"]: reply for reply in _read_strict(client, 2)}
        assert replies["s3"]["error"]["code"] == "busy"
        assert replies["read"]["ok"] is True
        release_scan.set()
        assert [reply["id"] for reply in _read_strict(client, 2)] == ["s1", "s2"]
        client.close()
    finally:
        release_scan.set()
        instance.stop()


def test_every_slow_lane_command_belongs_to_exactly_one_lane() -> None:
    from jrbar.core_server import (
        ACTION_LANE_COMMANDS,
        READ_LANE_COMMANDS,
        SCAN_LANE_COMMANDS,
        SLOW_LANE_COMMANDS,
    )

    assert SCAN_LANE_COMMANDS == {"usage_graph", "usage_history"}
    assert ACTION_LANE_COMMANDS == {"provider_sign_in"}
    assert not SCAN_LANE_COMMANDS & READ_LANE_COMMANDS
    assert not ACTION_LANE_COMMANDS & (SCAN_LANE_COMMANDS | READ_LANE_COMMANDS)
    assert SCAN_LANE_COMMANDS | READ_LANE_COMMANDS | ACTION_LANE_COMMANDS == SLOW_LANE_COMMANDS
    # History's pair shares a lane: the mark must wait behind the read.
    assert {"list_history", "mark_history_seen"} <= READ_LANE_COMMANDS
