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


def test_socket_is_private_and_greets_with_hello_state_lights_settings(server: CoreServer) -> None:
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


def test_commands_reply_in_order_and_unknown_command_is_refused(server: CoreServer) -> None:
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


def test_state_is_coalesced_latest_wins_and_bounded(server: CoreServer) -> None:
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


def test_identical_documents_are_not_rebroadcast(server: CoreServer) -> None:
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


def test_events_and_logs_are_not_coalesced(server: CoreServer) -> None:
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


def test_frames_are_capped_at_one_mebibyte(server: CoreServer) -> None:
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


def test_foreign_uid_peer_is_refused(sock_dir: Path) -> None:
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


def test_fifth_client_is_refused_and_stale_socket_is_replaced(sock_dir: Path) -> None:
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
