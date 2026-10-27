from __future__ import annotations

import shutil
import threading

import pytest
from test_core_server import _connect, _read_frames

from jrbar.core_server import CommandRouter, CoreServer, encode_frame


@pytest.fixture
def sock_dir(short_tmp_path):
    path = short_tmp_path
    try:
        yield path
    finally:
        shutil.rmtree(path, ignore_errors=True)


DECK_COMMANDS = (
    "deck_plan_keymap", "deck_apply_keymap", "deck_restore_keymap",
    "deck_approve_device", "deck_disable", "deck_set_settings",
)


@pytest.mark.parametrize("name", DECK_COMMANDS)
def test_deck_setup_keeps_person_commands_available_and_refuses_overlap(sock_dir, name):
    started = threading.Event()
    release = threading.Event()
    calls = []
    router = CommandRouter()

    def setup(args):
        calls.append(threading.current_thread().name)
        started.set()
        assert release.wait(5)
        return {"done": True}

    for command in DECK_COMMANDS:
        router.register(command, setup)
    router.register("answer_ask", lambda args: {"synthetic_person_dispatch": True})
    router.register("ping", lambda args: {"pong": True})
    for command in ("usage_graph", "list_history", "provider_sign_in"):
        router.register(command, lambda args: {"independent": True})
    server = CoreServer(dispatch=router, initial_documents=lambda: [], socket_path=sock_dir / "deck.sock")
    server.start()
    client = _connect(server)

    def send(identifier, command):
        client.sendall(encode_frame({"t": "command", "v": 1, "id": identifier, "name": command, "args": {}}))

    try:
        _read_frames(client, 1)
        send("setup", name)
        assert started.wait(2)
        send("ping", "ping")
        send("answer", "answer_ask")
        replies = _read_frames(client, 2, timeout=0.5)
        assert [reply["id"] for reply in replies] == ["ping", "answer"]
        assert all(reply["ok"] for reply in replies)
        for command in ("usage_graph", "list_history", "provider_sign_in"):
            send(command, command)
            independent = _read_frames(client, 1)[0]
            assert independent["id"] == command and independent["ok"]
        for command in DECK_COMMANDS:
            send("busy", command)
            refusal = _read_frames(client, 1)[0]
            assert refusal["id"] == "busy"
            assert refusal["error"]["code"] == "busy"
        assert calls == ["JRBarCoreDeckLane"]
        release.set()
        assert _read_frames(client, 1)[0]["id"] == "setup"
        send("next", "deck_disable")
        assert _read_frames(client, 1)[0]["id"] == "next"
        assert calls == ["JRBarCoreDeckLane", "JRBarCoreDeckLane"]
    finally:
        release.set()
        client.close()
        server.stop()


def test_deck_lane_survives_start_failure(sock_dir, monkeypatch):
    server = CoreServer(dispatch=lambda name, args: {}, initial_documents=lambda: [], socket_path=sock_dir / "deck.sock")
    original_start = threading.Thread.start

    def fail_deck_start(thread):
        if thread.name == "JRBarCoreDeckLane":
            raise RuntimeError("synthetic start failure")
        original_start(thread)

    with monkeypatch.context() as patch:
        patch.setattr(threading.Thread, "start", fail_deck_start)
        with pytest.raises(RuntimeError, match="synthetic start failure"):
            server.start()
    assert not server._running
    assert not server.socket_path.exists()
    server.start()
    client = _connect(server)
    try:
        _read_frames(client, 1)
        client.sendall(encode_frame({"t": "command", "v": 1, "id": "retry", "name": "deck_disable", "args": {}}))
        assert _read_frames(client, 1)[0]["ok"]
    finally:
        client.close()
        server.stop()


def test_stopped_deck_work_keeps_exclusive_admission_until_completion(sock_dir):
    started = threading.Event()
    release = threading.Event()
    finished = threading.Event()
    calls = []

    def dispatch(name, args):
        calls.append(name)
        started.set()
        assert release.wait(5)
        finished.set()
        return {}

    server = CoreServer(dispatch=dispatch, initial_documents=lambda: [], socket_path=sock_dir / "deck.sock")
    server.start()
    client = _connect(server)
    _read_frames(client, 1)
    client.sendall(encode_frame({"t": "command", "v": 1, "id": "old", "name": "deck_apply_keymap", "args": {}}))
    assert started.wait(2)
    try:
        server.stop()
        assert server._deck_busy
        assert not any(server._slow_queues.values())
        server.start()
        retry = _connect(server)
        try:
            _read_frames(retry, 1)
            retry.sendall(encode_frame({"t": "command", "v": 1, "id": "new", "name": "deck_disable", "args": {}}))
            assert _read_frames(retry, 1)[0]["error"]["code"] == "busy"
            assert calls == ["deck_apply_keymap"]
        finally:
            retry.close()
    finally:
        release.set()
        assert finished.wait(2)
        client.close()
        server.stop()
