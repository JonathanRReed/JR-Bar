from __future__ import annotations

import json
import os
import socket
import stat
import threading
import time
from pathlib import Path

import pytest

from jrbar.core_server import (
    MAX_FRAME_BYTES,
    SLOW_LANE_RECEIVED_AT,
    CommandError,
    CommandRouter,
    CoreServer,
    encode_frame,
)


@pytest.fixture
def sock_dir():
    """AF_UNIX paths are capped at 104 bytes; pytest's tmp_path is too long."""
    import shutil as _shutil
    import tempfile as _tempfile

    path = Path(_tempfile.mkdtemp(prefix="jrbar-", dir=_tempfile.gettempdir()))
    try:
        yield path
    finally:
        _shutil.rmtree(path, ignore_errors=True)


def _read_frames(client: socket.socket, count: int, timeout: float = 3.0) -> list[dict]:
    client.settimeout(timeout)
    buffer = b""
    frames: list[dict] = []
    deadline = time.monotonic() + timeout
    while len(frames) < count and time.monotonic() < deadline:
        while b"\n" in buffer and len(frames) < count:
            line, buffer = buffer.split(b"\n", 1)
            frames.append(json.loads(line))
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


def _server(sock_dir: Path, **overrides) -> CoreServer:
    router = CommandRouter()
    router.register("ping", lambda args: {"pong": args.get("value", 1)})
    router.register("boom", lambda args: (_ for _ in ()).throw(RuntimeError("kaboom")))

    def refuse(args):
        raise CommandError("not_frontmost", "terminal is not in front")

    router.register("answer_ask", refuse)
    documents = [
        {"t": "state", "generation": 1, "sessions": []},
        {"t": "lights", "surfaces": {}},
        {"t": "settings", "generation": 1, "document": {}},
    ]
    kwargs = dict(
        dispatch=router,
        initial_documents=lambda: documents,
        socket_path=sock_dir / "core.sock",
        core_version="0.8.0-test",
    )
    kwargs.update(overrides)
    return CoreServer(**kwargs)


@pytest.fixture
def server(sock_dir: Path):
    instance = _server(sock_dir)
    instance.start()
    yield instance
    instance.stop()


def _connect(server: CoreServer) -> socket.socket:
    client = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
    client.settimeout(3.0)
    client.connect(str(server.socket_path))
    return client


def test_initial_connection_recovers_only_recent_quota_resets(server: CoreServer, monkeypatch) -> None:
    from types import SimpleNamespace

    reset = server.publish_event({"kind": "quota_reset", "provider": "claude", "lane": "weekly", "at": 990.0})
    server.publish_event({"kind": "quota_reset", "at": 700.0})
    server.publish_event({"kind": "quota_reset", "at": 1001.0})
    server.publish_event({"kind": "completed", "at": 990.0})
    server.publish_event({"kind": "confetti", "at": 990.0})
    server.publish_event({"kind": "quota_reset", "at": 990.0, "detail": "x" * MAX_FRAME_BYTES})
    monkeypatch.setattr("jrbar.core_server.time.time", lambda: 1000.0)
    frames = []
    client = SimpleNamespace(
        alive=True,
        index=1,
        send=lambda frame: frames.append(json.loads(frame)),
        finish_priming=lambda: None,
    )
    monkeypatch.setattr(server, "_read_commands", lambda _: None)
    monkeypatch.setattr(server, "_drop_clients", lambda _: None)
    server._serve_client(client)
    assert [frame["t"] for frame in frames] == ["hello", "state", "lights", "settings", "event"]
    assert frames[-1] == reset
    assert reset in server.recent_reset_events(now=1289.0)
    assert reset not in server.recent_reset_events(now=1290.0)


def test_socket_is_private_and_greets_with_hello_state_lights_settings__and_2_more(server: CoreServer) -> None:
    # --- scenario: socket_is_private_and_greets_with_hello_state_lights_settings
    mode = stat.S_IMODE(os.stat(server.socket_path).st_mode)
    assert mode == 0o600
    client = _connect(server)
    frames = _read_frames(client, 4)
    assert [frame["t"] for frame in frames] == ["hello", "state", "lights", "settings"]
    hello = frames[0]
    assert hello["v"] == 1
    assert hello["core_version"] == "0.8.0-test"
    assert hello["pid"] == os.getpid()
    assert "sessions" in hello["capabilities"]
    assert all(frame["v"] == 1 for frame in frames)
    client.close()

    # --- scenario: commands_reply_in_order_and_unknown_command_is_refused
    client = _connect(server)
    _read_frames(client, 4)
    client.sendall(encode_frame({"t": "command", "v": 1, "id": "c-1", "name": "ping", "args": {"value": 7}}))
    client.sendall(encode_frame({"t": "command", "v": 1, "id": "c-2", "name": "nope", "args": {}}))
    client.sendall(encode_frame({"t": "command", "v": 1, "id": "c-3", "name": "answer_ask", "args": {}}))
    client.sendall(encode_frame({"t": "command", "v": 1, "id": "c-4", "name": "boom"}))
    replies = _read_frames(client, 4)
    assert [reply["id"] for reply in replies] == ["c-1", "c-2", "c-3", "c-4"]
    assert replies[0] == {"t": "reply", "v": 1, "id": "c-1", "ok": True, "result": {"pong": 7}}
    assert replies[1]["ok"] is False and replies[1]["error"]["code"] == "unknown_command"
    assert replies[2]["ok"] is False and replies[2]["error"]["code"] == "not_frontmost"
    assert replies[3]["ok"] is False and replies[3]["error"]["code"] == "internal"
    assert server.stats["commands"] == 4
    client.close()

    # --- scenario: state_is_coalesced_latest_wins_and_bounded
    client = _connect(server)
    _read_frames(client, 4)
    started = time.monotonic()
    for generation in range(2, 202):
        server.publish_state({"generation": generation})
    # Whatever arrives, the last document delivered is the last published,
    # and 200 publishes inside a few ms cannot produce 200 frames. The
    # bounded read below doubles as the settle time.
    frames = _read_frames(client, 1000, timeout=0.5)
    states = [frame for frame in frames if frame["t"] == "state"]
    assert states, "no state frames arrived"
    assert states[-1]["generation"] == 201
    elapsed = time.monotonic() - started
    assert len(states) <= int(elapsed * 20) + 2
    client.close()



def test_identical_documents_are_not_rebroadcast__and_2_more(server: CoreServer) -> None:
    # --- scenario: identical_documents_are_not_rebroadcast
    client = _connect(server)
    _read_frames(client, 4)
    server._min_interval["state"] = 0
    document = {"generation": 9, "sessions": [{"id": "s1"}]}
    server.publish_state(dict(document))
    frames = _read_frames(client, 1)
    assert frames[0]["generation"] == 9
    # The same document again must not go back on the wire: the poke is
    # encoded, seen identical, and counted, but no frame is fanned out.
    server.publish_state(dict(document))
    frames = _read_frames(client, 1, timeout=0.4)
    assert frames == []
    assert server.stats["deduped_frames"] == 1
    # A changed document still publishes, and a fresh client still gets
    # the server's current documents on connect (dedupe only affects the
    # broadcast path, never the connect-time replay).
    server.publish_state({"generation": 10})
    assert _read_frames(client, 1)[0]["generation"] == 10
    second = _connect(server)
    greetings = _read_frames(second, 4)
    assert [frame["t"] for frame in greetings] == ["hello", "state", "lights", "settings"]
    client.close()
    second.close()

    # --- scenario: events_and_logs_are_not_coalesced
    client = _connect(server)
    _read_frames(client, 4)
    for index in range(5):
        server.publish_event({"kind": "completed", "session": f"s{index}"})
    server.publish_log("hello")
    frames = _read_frames(client, 6)
    kinds = [frame["t"] for frame in frames]
    assert kinds == ["event"] * 5 + ["log"]
    assert [frame["session"] for frame in frames[:5]] == [f"s{i}" for i in range(5)]
    assert all("id" in frame and "at" in frame for frame in frames[:5])
    assert frames[5]["message"] == "hello"
    client.close()

    # --- scenario: frames_are_capped_at_one_mebibyte
    client = _connect(server)
    _read_frames(client, 4)
    server.publish_event({"kind": "completed", "blob": "x" * (MAX_FRAME_BYTES + 10)})
    server.publish_state({"generation": 3})
    frames = _read_frames(client, 1)
    assert frames and frames[0] == {"t": "state", "v": 1, "generation": 3}
    assert server.stats["dropped_oversize"] == 1
    # An oversize inbound frame closes that client, nothing else.
    client.sendall(b"{" + b"x" * MAX_FRAME_BYTES)
    client.settimeout(3.0)
    assert client.recv(10) == b""
    client.close()



def test_foreign_uid_peer_is_refused__and_1_more(sock_dir: Path) -> None:
    # --- scenario: foreign_uid_peer_is_refused
    instance = _server(sock_dir, peer_uid_reader=lambda _connection: os.geteuid() + 1)
    instance.start()
    try:
        client = _connect(instance)
        client.settimeout(3.0)
        assert client.recv(10) == b""
        assert instance.stats["refused_clients"] == 1
        client.close()
    finally:
        instance.stop()

    # --- scenario: fifth_client_is_refused_and_stale_socket_is_replaced
    path = sock_dir / "core.sock"
    stale = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
    stale.bind(str(path))
    stale.close()
    assert path.exists()
    instance = _server(sock_dir)
    instance.start()
    clients = []
    try:
        for _ in range(4):
            client = _connect(instance)
            assert _read_frames(client, 1)[0]["t"] == "hello"
            clients.append(client)
        fifth = _connect(instance)
        fifth.settimeout(3.0)
        assert fifth.recv(10) == b""
        assert instance.client_count == 4
        with pytest.raises(OSError):
            _server(sock_dir).start()
    finally:
        for client in clients:
            client.close()
        instance.stop()
    assert not path.exists()



def test_a_client_that_stops_reading_is_dropped_without_wedging_fanout(
    server: CoreServer,
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    """One stalled reader must not park the serial flusher: SO_SNDTIMEO
    bounds every send, and a send blocked past that deadline drops the
    client so the other clients keep receiving frames."""
    import struct as _struct

    # Shrink the per-send deadline so the stall is measured in tenths of a
    # second rather than whole seconds.
    monkeypatch.setattr(
        "jrbar.core_server._SEND_TIMEOUT_TIMEVAL", _struct.pack("ll", 0, 200_000)
    )

    reader = _connect(server)
    assert _read_frames(reader, 4)[0]["t"] == "hello"

    # The healthy client drains continuously on its own thread so it
    # never accrues strikes itself; a client that cannot keep up DOES
    # legitimately lose frames to the send timeout.
    received: list[dict] = []
    read_errors: list[Exception] = []
    marker_seen = threading.Event()
    keep_reading = threading.Event()
    keep_reading.set()

    def drain() -> None:
        reader.settimeout(0.2)
        buffer = b""
        while keep_reading.is_set():
            try:
                chunk = reader.recv(65536)
            except TimeoutError:
                continue
            except OSError as exc:
                read_errors.append(exc)
                return
            if not chunk:
                return
            buffer += chunk
            while b"\n" in buffer:
                line, buffer = buffer.split(b"\n", 1)
                try:
                    frame = json.loads(line)
                except ValueError as exc:
                    read_errors.append(exc)
                    return
                received.append(frame)
                if frame.get("kind") == "marker":
                    marker_seen.set()

    drain_thread = threading.Thread(target=drain, daemon=True)
    drain_thread.start()

    staller = _connect(server)
    # Shrink the peer's receive buffer so a few big frames fill it, then
    # read only the greeting and never read again.
    staller.setsockopt(socket.SOL_SOCKET, socket.SO_RCVBUF, 8192)
    assert _read_frames(staller, 4)[0]["t"] == "hello"

    blob = "x" * (200 * 1024)
    deadline = time.monotonic() + 10.0
    while time.monotonic() < deadline and server.client_count > 1:
        server.publish_event({"kind": "fill", "blob": blob})
    assert server.client_count == 1, "a peer that never reads was never dropped"

    server.publish_event({"kind": "marker"})
    assert marker_seen.wait(3.0), (
        "a stalled peer starved every frame to healthy clients"
    )
    keep_reading.clear()
    drain_thread.join(1.0)
    assert read_errors == []
    staller.close()
    reader.close()


def _greeting_server(
    sock_dir: Path,
    monkeypatch: pytest.MonkeyPatch,
    *,
    snapshot_taken: threading.Event,
    release: threading.Event,
    block: dict[str, bool],
) -> tuple[CoreServer, threading.Semaphore]:
    """A started server whose initial snapshot can be held back, and whose
    flusher reports each finished fan-out."""

    def documents() -> list[dict]:
        taken = [
            {"t": "state", "generation": 1, "sessions": []},
            {"t": "lights", "surfaces": {}},
            {"t": "settings", "generation": 1, "document": {}},
        ]
        if block["on"]:
            snapshot_taken.set()
            release.wait(5.0)
        return taken

    server = _server(sock_dir, initial_documents=documents)
    original = server._fan_out
    fanned = threading.Semaphore(0)

    def counted(frame: bytes) -> None:
        original(frame)
        fanned.release()

    monkeypatch.setattr(server, "_fan_out", counted)
    server.start()
    return server, fanned


def test_a_state_published_during_the_greeting_follows_the_snapshot(
    sock_dir: Path,
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    snapshot_taken, release = threading.Event(), threading.Event()
    server, fanned = _greeting_server(
        sock_dir,
        monkeypatch,
        snapshot_taken=snapshot_taken,
        release=release,
        block={"on": True},
    )
    client = None
    try:
        client = _connect(server)
        assert snapshot_taken.wait(3.0), "the greeting never took its snapshot"
        server.publish_state({"t": "state", "generation": 2, "sessions": []})
        assert fanned.acquire(timeout=3.0), "the flusher never fanned the newer state out"
        release.set()

        frames = _read_frames(client, 5)
        assert [frame["t"] for frame in frames] == [
            "hello", "state", "lights", "settings", "state",
        ]
        states = [frame["generation"] for frame in frames if frame["t"] == "state"]
        assert states == [1, 2], "the older snapshot overtook the newer state"
    finally:
        release.set()
        if client is not None:
            client.close()
        server.stop()


def test_a_frame_published_before_hello_is_sent_waits_behind_hello(
    sock_dir: Path,
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    server, fanned = _greeting_server(
        sock_dir,
        monkeypatch,
        snapshot_taken=threading.Event(),
        release=threading.Event(),
        block={"on": False},
    )
    in_hello, release = threading.Event(), threading.Event()
    real_hello = server.hello_document

    def held_hello() -> dict:
        in_hello.set()
        release.wait(5.0)
        return real_hello()

    monkeypatch.setattr(server, "hello_document", held_hello)
    client = None
    try:
        client = _connect(server)
        assert in_hello.wait(3.0), "the greeting never reached hello"
        server.publish_event({"kind": "probe"})
        assert fanned.acquire(timeout=3.0), "the flusher never fanned the probe out"
        release.set()

        frames = _read_frames(client, 5)
        assert frames[0]["t"] == "hello"
        assert [frame["t"] for frame in frames] == [
            "hello", "state", "lights", "settings", "event",
        ]
        assert frames[-1]["kind"] == "probe"
    finally:
        release.set()
        if client is not None:
            client.close()
        server.stop()


def test_a_client_that_never_finishes_its_greeting_is_dropped_not_buffered_without_bound(
    sock_dir: Path,
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    from jrbar.core_server import MAX_QUEUED_FRAMES

    snapshot_taken, release = threading.Event(), threading.Event()
    block = {"on": False}
    server, fanned = _greeting_server(
        sock_dir,
        monkeypatch,
        snapshot_taken=snapshot_taken,
        release=release,
        block=block,
    )
    steady = stuck = None
    try:
        steady = _connect(server)
        assert [frame["t"] for frame in _read_frames(steady, 4)] == [
            "hello", "state", "lights", "settings",
        ]
        block["on"] = True
        stuck = _connect(server)
        assert snapshot_taken.wait(3.0), "the second greeting never took its snapshot"
        assert server.client_count == 2

        published = 0
        batch = MAX_QUEUED_FRAMES // 4
        # Batches, each waited out, so the flusher's own bounded queue never
        # sheds what the held client is being counted against.
        for _ in range(8):
            for _ in range(batch):
                server.publish_event({"kind": "tick"})
            published += batch
            for _ in range(batch):
                assert fanned.acquire(timeout=3.0), "the flusher stalled behind a greeting"
            if server.client_count == 1:
                break
        assert server.client_count == 1, "a greeting that never finished was buffered forever"

        server.publish_event({"kind": "marker"})
        published += 1
        frames = _read_frames(steady, published, timeout=5.0)
        assert frames[-1].get("kind") == "marker", (
            "the healthy client stopped receiving while another was greeting"
        )
    finally:
        release.set()
        for peer in (steady, stuck):
            if peer is not None:
                peer.close()
        server.stop()


def test_client_holds_live_frames_until_priming_finishes_then_sends_in_order() -> None:
    from types import SimpleNamespace

    from jrbar.core_server import MAX_QUEUED_FRAMES, _Client

    sent: list[bytes] = []
    client = _Client(SimpleNamespace(sendall=sent.append), 1)

    assert client.deliver(b"a") is True
    assert client.deliver(b"b") is True
    assert sent == [], "a live frame beat the greeting"
    client.finish_priming()
    assert sent == [b"a", b"b"]
    assert client.deliver(b"c") is True
    assert sent == [b"a", b"b", b"c"], "a primed client is sent to directly"

    unprimed = _Client(SimpleNamespace(sendall=sent.append), 2)
    for index in range(MAX_QUEUED_FRAMES):
        assert unprimed.deliver(b"x") is True, index
    assert unprimed.deliver(b"x") is False
    assert unprimed.alive is False


def _drain_without_waiting(reader: socket.socket) -> int:
    """Bytes already sitting in the peer's buffers; never waits for more."""
    reader.setblocking(False)
    total = 0
    while True:
        try:
            chunk = reader.recv(65536)
        except BlockingIOError:
            return total
        if not chunk:
            return total
        total += len(chunk)


def test_client_send_stall_drops_immediately_and_never_writes_after_a_partial_frame() -> None:
    import struct as _struct

    from jrbar.core_server import _Client

    writer, reader = socket.socketpair()
    try:
        writer.setsockopt(socket.SOL_SOCKET, socket.SO_SNDBUF, 4096)
        reader.setsockopt(socket.SOL_SOCKET, socket.SO_RCVBUF, 4096)
        writer.setsockopt(
            socket.SOL_SOCKET, socket.SO_SNDTIMEO, _struct.pack("ll", 0, 100_000)
        )
        client = _Client(writer, 1)
        frame = encode_frame({"t": "state", "v": 1, "blob": "x" * (64 * 1024)})

        assert client.send(frame) is False
        assert client.alive is False
        partial = _drain_without_waiting(reader)
        assert partial < len(frame), "the stalled send was not partial"

        # The stream now ends mid-line; nothing may follow it.
        assert client.send(encode_frame({"t": "event", "v": 1})) is False
        assert _drain_without_waiting(reader) == 0
    finally:
        writer.close()
        reader.close()


@pytest.mark.parametrize(
    "error",
    (
        BlockingIOError(35, "Resource temporarily unavailable"),
        TimeoutError("timed out"),
    ),
    ids=("blocking_io_error", "timeout_error"),
)
def test_blocking_io_error_from_a_stalled_send_is_classified_as_a_drop(error) -> None:
    from types import SimpleNamespace

    from jrbar.core_server import _Client

    calls: list[bytes] = []

    def sendall(frame: bytes) -> None:
        calls.append(frame)
        raise error

    client = _Client(SimpleNamespace(sendall=sendall), 1)

    # SO_SNDTIMEO on a blocking socket surfaces as BlockingIOError (EAGAIN),
    # not TimeoutError; either way one stall drops the client.
    assert client.send(b"{}\n") is False
    assert client.alive is False
    assert client.send(b"{}\n") is False
    assert len(calls) == 1, "a dropped client was written to again"


def test_accepted_client_send_buffer_absorbs_several_state_frames(
    server: CoreServer,
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    """A short reader pause must not drop the app: a state-sized frame or
    two goes into the kernel buffer without blocking the flusher."""
    import struct as _struct

    monkeypatch.setattr(
        "jrbar.core_server._SEND_TIMEOUT_TIMEVAL", _struct.pack("ll", 0, 200_000)
    )
    staller = _connect(server)
    staller.setsockopt(socket.SOL_SOCKET, socket.SO_RCVBUF, 8192)
    assert _read_frames(staller, 4)[0]["t"] == "hello"

    original = server._fan_out
    fanned = threading.Semaphore(0)

    def counted(frame: bytes) -> None:
        original(frame)
        fanned.release()

    monkeypatch.setattr(server, "_fan_out", counted)

    blob = "x" * (40 * 1024)
    for _ in range(5):
        server.publish_event({"kind": "state_sized", "blob": blob})
    for _ in range(5):
        assert fanned.acquire(timeout=3.0), "the flusher never finished a fan-out"
    # 5 x 40 KB is under the daemon-side buffer: nothing has blocked yet.
    assert server.client_count == 1
    with server._lock:
        connection = server._clients[0].connection
    assert connection.getsockopt(socket.SOL_SOCKET, socket.SO_SNDBUF) >= 256 * 1024

    overflow = "x" * (200 * 1024)
    deadline = time.monotonic() + 10.0
    while time.monotonic() < deadline and server.client_count > 0:
        server.publish_event({"kind": "fill", "blob": overflow})
    assert server.client_count == 0, "a peer that never reads was never dropped"
    staller.close()


def test_event_queue_is_bounded_and_drops_oldest__and_1_more(sock_dir: Path,
    monkeypatch: pytest.MonkeyPatch,) -> None:
    # --- scenario: event_queue_is_bounded_and_drops_oldest
    """Without a running flusher the queue must still stay bounded:
    event/log frames shed oldest-first while coalesced documents keep
    their latest-wins slot."""
    monkeypatch.setattr("jrbar.core_server.MAX_QUEUED_FRAMES", 4)
    instance = _server(sock_dir)  # not started: nothing drains the queue
    for index in range(10):
        instance.publish_event({"kind": "burst", "index": index})
    assert len(instance._queue) == 4
    assert instance.stats["dropped_queue"] == 6
    kept = [json.loads(frame)["index"] for frame in instance._queue]
    assert kept == [6, 7, 8, 9]

    # --- scenario: stale_socket_probe_ambiguity_never_unlinks
    monkeypatch.undo()
    """A probe TIMEOUT is not proof of death: a wedged-but-live daemon
    reads identically, so the path must be left alone and startup must
    refuse -- only ECONNREFUSED may unlink (ipc.py parity)."""
    import jrbar.core_server as core_server

    path = sock_dir / "core.sock"
    stale = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
    stale.bind(str(path))
    stale.close()
    assert path.exists()

    class _TimingOutProbe:
        def settimeout(self, _seconds: float) -> None:
            pass

        def connect(self, _path: str) -> None:
            raise TimeoutError("probe timed out under load")

        def close(self) -> None:
            pass

    class _SocketModule:
        AF_UNIX = socket.AF_UNIX
        SOCK_STREAM = socket.SOCK_STREAM

        @staticmethod
        def socket(*_args: object, **_kwargs: object) -> object:
            return _TimingOutProbe()

    monkeypatch.setattr(core_server, "socket", _SocketModule)
    with pytest.raises(OSError, match="unproven"):
        core_server.CoreServer._unlink_stale(path)
    monkeypatch.undo()
    assert path.exists(), "an ambiguous probe must never remove the path"

    # And the real path: a bound-then-closed socket refuses cleanly and is
    # still replaced exactly as before.
    instance = _server(sock_dir)
    instance.start()
    try:
        client = _connect(instance)
        assert _read_frames(client, 1)[0]["t"] == "hello"
        client.close()
    finally:
        instance.stop()



def test_dispatch_runs_on_the_reader_thread_and_reply_is_serialisable(sock_dir: Path) -> None:
    seen: dict[str, object] = {}

    def dispatch(name: str, args: dict) -> object:
        seen["thread"] = threading.current_thread().name
        return {"echo": args}

    instance = CoreServer(dispatch=dispatch, initial_documents=lambda: [], socket_path=sock_dir / "core.sock")
    instance.start()
    try:
        client = _connect(instance)
        _read_frames(client, 1)
        client.sendall(encode_frame({"t": "command", "v": 1, "id": "x", "name": "any", "args": {"a": [1, 2]}}))
        reply = _read_frames(client, 1)[0]
        assert reply["result"] == {"echo": {"a": [1, 2]}}
        assert seen["thread"].startswith("JRBarCoreClient")
        client.close()
    finally:
        instance.stop()



def test_a_slow_read_never_holds_up_a_later_command_on_the_same_socket__and_2_more(
    sock_dir: Path, monkeypatch: pytest.MonkeyPatch
) -> None:
    """A usage_graph took 107 s on 2026-09-23 and a ping sent behind it on
    the same connection waited just as long; an Approve gives up after 8 s.
    Slow-lane reads now run on one worker and reply by id when done."""
    from jrbar import core_server

    release = threading.Event()
    started = threading.Event()
    running = 0
    overlap: list[int] = []
    order: list[str] = []
    threads: dict[str, str] = {}
    guard = threading.Lock()

    def dispatch(name: str, args: dict) -> object:
        nonlocal running
        threads[name] = threading.current_thread().name
        if name in ("usage_graph", "list_history"):
            with guard:
                running += 1
                overlap.append(running)
            started.set()
            try:
                assert release.wait(5.0)
            finally:
                with guard:
                    running -= 1
                    order.append(args.get("tag", name))
        return {"name": name, "tag": args.get("tag")}

    setup_threads: list[str] = []
    instance = CoreServer(
        dispatch=dispatch,
        initial_documents=lambda: [],
        socket_path=sock_dir / "core.sock",
        slow_lane_setup=lambda: setup_threads.append(threading.current_thread().name),
    )
    instance.start()
    try:
        # --- scenario: a fast command behind a slow read answers first
        first = _connect(instance)
        _read_frames(first, 1)
        first.sendall(encode_frame({"t": "command", "v": 1, "id": "slow", "name": "usage_graph", "args": {"tag": "a"}}))
        assert started.wait(5.0)
        first.sendall(encode_frame({"t": "command", "v": 1, "id": "fast", "name": "answer_ask", "args": {}}))
        reply = _read_frames(first, 1)[0]
        assert reply["id"] == "fast" and reply["ok"] is True
        assert threads["answer_ask"].startswith("JRBarCoreClient")

        # --- scenario: two slow reads from two clients never overlap
        second = _connect(instance)
        _read_frames(second, 1)
        second.sendall(encode_frame({"t": "command", "v": 1, "id": "slow2", "name": "list_history", "args": {"tag": "b"}}))
        second.sendall(encode_frame({"t": "command", "v": 1, "id": "ping2", "name": "ping", "args": {}}))
        assert _read_frames(second, 1)[0]["id"] == "ping2"
        release.set()
        assert _read_frames(first, 1)[0]["result"] == {"name": "usage_graph", "tag": "a"}
        assert _read_frames(second, 1)[0]["result"] == {"name": "list_history", "tag": "b"}
        assert overlap == [1, 1]
        assert order == ["a", "b"]
        assert threads["usage_graph"] == threads["list_history"] == "JRBarCoreSlowLane"
        assert setup_threads == ["JRBarCoreSlowLane"]

        # --- scenario: past the queue bound a slow read is refused busy at once
        release.clear()
        started.clear()
        monkeypatch.setattr(core_server, "MAX_SLOW_LANE_QUEUED", 1)
        first.sendall(encode_frame({"t": "command", "v": 1, "id": "s1", "name": "usage_graph", "args": {}}))
        assert started.wait(5.0)  # s1 is running, so the queue is empty
        first.sendall(encode_frame({"t": "command", "v": 1, "id": "s2", "name": "usage_graph", "args": {}}))
        first.sendall(encode_frame({"t": "command", "v": 1, "id": "s3", "name": "usage_graph", "args": {}}))
        refused = _read_frames(first, 1)[0]
        assert refused["id"] == "s3" and refused["ok"] is False
        assert refused["error"]["code"] == "busy"
        release.set()
        assert [frame["id"] for frame in _read_frames(first, 2)] == ["s1", "s2"]
        first.close()
        second.close()
    finally:
        release.set()
        instance.stop()


def test_mark_history_seen_waits_behind_the_list_history_sent_before_it(sock_dir: Path) -> None:
    """History opens with list_history then mark_history_seen on one socket.
    With the read on the slow lane and the mark inline, the mark reached the
    main thread first and moved the watermark the read measures ``unseen``
    from, so every row came back seen. The mark now queues behind it."""
    watermark = {"last_seen": "old"}
    threads: dict[str, str] = {}
    # The reader thread handles one socket's frames in order, so once the
    # ping behind the mark has run, the mark has been handled too: run
    # inline (the bug) or queued behind the read.
    mark_handled = threading.Event()

    def dispatch(name: str, args: dict) -> object:
        threads[name] = threading.current_thread().name
        if name == "list_history":
            assert mark_handled.wait(5.0)
            return {"measured_from": watermark["last_seen"]}
        if name == "mark_history_seen":
            watermark["last_seen"] = "new"
            watermark["received_at"] = args.get(SLOW_LANE_RECEIVED_AT)
            return {"last_seen": "new"}
        if name == "ping":
            mark_handled.set()
        return {}

    instance = CoreServer(
        dispatch=dispatch,
        initial_documents=lambda: [],
        socket_path=sock_dir / "core.sock",
    )
    instance.start()
    try:
        client = _connect(instance)
        _read_frames(client, 1)
        sent_at = time.time()
        client.sendall(
            encode_frame({"t": "command", "v": 1, "id": "list", "name": "list_history", "args": {}})
            + encode_frame({"t": "command", "v": 1, "id": "mark", "name": "mark_history_seen", "args": {}})
            + encode_frame({"t": "command", "v": 1, "id": "ping", "name": "ping", "args": {}})
        )
        replies = _read_frames(client, 3)
        assert [reply["id"] for reply in replies] == ["ping", "list", "mark"]
        assert replies[1]["result"] == {"measured_from": "old"}
        assert replies[2]["result"] == {"last_seen": "new"}
        assert threads["mark_history_seen"] == "JRBarCoreSlowLane"
        # Stamped when it arrived, so the watermark is the look, not the
        # moment the read ahead of it finished.
        assert sent_at <= watermark["received_at"] <= time.time()
        client.close()
    finally:
        instance.stop()
