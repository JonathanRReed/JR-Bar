"""W03 upgrade regressions: the event stream is resumable.

Every published event is journaled under the flush lock with a
stream-scoped cursor — the journal IS the wire's order. A client that
missed frames (dropped slow consumer, reconnect) asks ``replay_events``
for the suffix; a cursor from another stream or one the bounded journal
evicted answers ``resync_required`` with the reason, never a fabricated
empty catch-up. ``hello`` carries the stream and tail cursor so a
reconnect anchors immediately.
"""

from __future__ import annotations

import socket
import tempfile
from pathlib import Path
from types import SimpleNamespace

import pytest

from jrbar import core_runtime
from jrbar.core_server import (
    MAX_JOURNAL_EVENTS,
    CommandRouter,
    CoreServer,
)


@pytest.fixture
def sock_dir():
    """AF_UNIX paths are capped at 104 bytes; pytest's tmp_path is too long."""
    import shutil

    path = Path(tempfile.mkdtemp(prefix="jrbar-", dir=tempfile.gettempdir()))
    try:
        yield path
    finally:
        shutil.rmtree(path, ignore_errors=True)


def _server(sock_dir) -> CoreServer:
    router = CommandRouter()
    router.register("ping", lambda args: {"pong": 1})
    return CoreServer(
        dispatch=router,
        initial_documents=lambda: [{"t": "state", "generation": 1, "sessions": []}],
        socket_path=sock_dir / "core.sock",
        core_version="test",
    )


@pytest.fixture
def server(sock_dir):
    instance = _server(sock_dir)
    instance.start()
    yield instance
    instance.stop()


def test_events_carry_stream_scoped_cursors_and_hello_anchors(server):
    assert server.hello_document()["stream"] == server._stream_id
    assert server.hello_document()["cursor"] is None

    first = server.publish_event({"kind": "completed", "session": "s1"})
    second = server.publish_event({"kind": "asked", "session": "s2"})

    assert first["cursor"].startswith(f"{server._stream_id}:")
    assert first["id"] in first["cursor"]
    assert first["cursor"] != second["cursor"]
    hello = server.hello_document()
    assert hello["cursor"] == second["cursor"]


def test_replay_returns_the_exact_suffix_in_order(server):
    events = [server.publish_event({"kind": "tick", "n": n}) for n in range(5)]
    after = events[1]["cursor"]
    reply = server.replay_events(after=after)
    assert reply["resync_required"] is False
    assert [event["id"] for event in reply["events"]] == [
        event["id"] for event in events[2:]
    ]
    assert reply["cursor"] == events[-1]["cursor"]
    assert "has_more" in reply and reply["has_more"] is False


def test_replay_everything_when_no_cursor(server):
    server.publish_event({"kind": "a"})
    server.publish_event({"kind": "b"})
    reply = server.replay_events()
    assert [event["kind"] for event in reply["events"]] == ["a", "b"]
    assert reply["resync_required"] is False


def test_foreign_stream_refuses_resync_not_empty(server):
    server.publish_event({"kind": "a"})
    reply = server.replay_events(after="someone-else:ev-3")
    assert reply["resync_required"] is True
    assert reply["reason"] == "foreign_stream"
    assert reply["events"] == []
    assert reply["cursor"] is not None  # the live tail, so the client can re-anchor


def test_expired_cursor_refuses_instead_of_silent_loss(server):
    # Publish more than the journal holds; the first events are evicted.
    first = server.publish_event({"kind": "first"})
    for n in range(MAX_JOURNAL_EVENTS + 10):
        server.publish_event({"kind": "burst", "n": n})
    reply = server.replay_events(after=first["cursor"])
    assert reply["resync_required"] is True
    assert reply["reason"] == "cursor_expired"
    assert reply["dropped"] > 0  # the gap is reported, not hidden


def test_suffix_pages_with_has_more(server):
    for n in range(10):
        server.publish_event({"kind": "e", "n": n})
    page = server.replay_events(limit=4)
    assert page["has_more"] is True
    assert len(page["events"]) == 4
    assert [e["n"] for e in page["events"]] == [0, 1, 2, 3]
    # Paging continues from the returned cursor — no loss, no dup.
    rest = server.replay_events(after=page["cursor"])
    assert [e["n"] for e in rest["events"]] == list(range(4, 10))
    assert rest["has_more"] is False


def test_event_during_delivery_lands_in_the_suffix_once(server):
    """T16: an event published between snapshot and replay appears in
    exactly the post-cursor suffix — journaled and fanned under one lock."""
    before = server.publish_event({"kind": "before"})
    server.publish_event({"kind": "during-snapshot"})
    server.publish_event({"kind": "after"})
    reply = server.replay_events(after=before["cursor"])
    assert [e["kind"] for e in reply["events"]] == ["during-snapshot", "after"]


def test_wire_frames_carry_the_same_cursor(sock_dir):
    """The cursor a client sees on the wire is the cursor it replays
    with — the journal entry and the frame are one document."""
    import json
    import time

    def read_frame(client: socket.socket, buffer: bytearray) -> dict:
        deadline = time.monotonic() + 3.0
        while b"\n" not in buffer:
            if time.monotonic() > deadline:
                raise TimeoutError("no frame within 3 s")
            buffer += client.recv(65536)
        line, rest = bytes(buffer).split(b"\n", 1)
        buffer[:] = rest
        return json.loads(line)

    instance = _server(sock_dir)
    instance.start()
    try:
        client = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
        client.settimeout(3.0)
        client.connect(str(instance.socket_path))
        try:
            buffer = bytearray()
            hello = read_frame(client, buffer)
            assert hello["t"] == "hello"
            assert hello["stream"] == instance._stream_id
            read_frame(client, buffer)  # state
            published = instance.publish_event({"kind": "seen-on-wire"})
            wire = read_frame(client, buffer)
            assert wire["t"] == "event"
            assert wire["cursor"] == published["cursor"]
            # And it replays against itself.
            reply = instance.replay_events(after=wire["cursor"])
            assert reply["resync_required"] is False
        finally:
            client.close()
    finally:
        instance.stop()


def test_replay_events_command(server):
    controller = SimpleNamespace(_core=server, _core_state_generation=3)
    server.publish_event({"kind": "one"})
    doc = core_runtime._cmd_replay_events(controller, {})
    assert doc["t"] == "events" and doc["generation"] == 3
    assert len(doc["events"]) == 1
    doc = core_runtime._cmd_replay_events(controller, {"after": "old:ev-1"})
    assert doc["resync_required"] is True and doc["reason"] == "foreign_stream"


def test_replay_events_command_reports_unsupported(serverless=True):
    controller = SimpleNamespace(_core=SimpleNamespace(), _core_state_generation=0)
    with pytest.raises(core_runtime.CommandError) as error:
        core_runtime._cmd_replay_events(controller, {})
    assert error.value.code == "unsupported"
