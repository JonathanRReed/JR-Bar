"""Fix sign-in has a lane of its own: a held `provider_sign_in` delays nothing else.

`provider_sign_in` can wait up to 90 s on Claude Code. On the read lane that would have made
History, a doctor run, a timeline and a comparison wait for it, and on the scan lane it would
wait behind a usage graph. It has an action lane: one worker, its own 32-deep queue, its own
thread. Everything here is deterministic: an Event stands in for the slow work, and every wait
only bounds a hang.
"""

from __future__ import annotations

import threading
from pathlib import Path

from jrbar import core_server
from tests.test_core_server import _connect
from tests.test_core_server_hardening import (
    HANG_BOUND_SECONDS,
    _command,
    _read_strict,
    _serve,
    sock_dir,  # noqa: F401  (the short socket folder fixture)
)


def test_a_held_sign_in_does_not_delay_a_history_read_or_a_scan(sock_dir: Path) -> None:  # noqa: F811
    sign_in_running = threading.Event()
    release_sign_in = threading.Event()
    threads: dict[str, str] = {}

    def dispatch(name: str, args: dict):
        threads[name] = threading.current_thread().name
        if name == "provider_sign_in":
            sign_in_running.set()
            assert release_sign_in.wait(HANG_BOUND_SECONDS)
            return {"outcome": "renewed"}
        return {"name": name}

    instance = _serve(sock_dir, dispatch)
    try:
        client = _connect(instance)
        _read_strict(client, 1)
        client.sendall(_command("fix", "provider_sign_in", {"provider": "claude"}))
        assert sign_in_running.wait(HANG_BOUND_SECONDS)
        client.sendall(_command("history", "list_history"))
        client.sendall(_command("doctor", "doctor"))
        client.sendall(_command("timeline", "session_timeline"))
        client.sendall(_command("scan", "usage_graph"))
        client.sendall(_command("ask", "answer_ask"))
        # Every other command answers with the sign-in still held.
        replies = _read_strict(client, 5)
        assert sorted(reply["id"] for reply in replies) == ["ask", "doctor", "history", "scan", "timeline"]
        assert not release_sign_in.is_set()
        assert threads["provider_sign_in"] == "JRBarCoreActionLane"
        assert threads["list_history"] == threads["doctor"] == "JRBarCoreReadLane"
        assert threads["usage_graph"] == "JRBarCoreScanLane"
        release_sign_in.set()
        reply = _read_strict(client, 1)[0]
        assert reply["id"] == "fix" and reply["result"] == {"outcome": "renewed"}
        client.close()
    finally:
        release_sign_in.set()
        instance.stop()


def test_a_held_read_and_a_held_scan_do_not_delay_a_sign_in(sock_dir: Path) -> None:  # noqa: F811
    read_running = threading.Event()
    scan_running = threading.Event()
    release = threading.Event()

    def dispatch(name: str, args: dict):
        if name == "list_history":
            read_running.set()
            assert release.wait(HANG_BOUND_SECONDS)
        elif name == "usage_graph":
            scan_running.set()
            assert release.wait(HANG_BOUND_SECONDS)
        return {"name": name}

    instance = _serve(sock_dir, dispatch)
    try:
        client = _connect(instance)
        _read_strict(client, 1)
        client.sendall(_command("history", "list_history"))
        client.sendall(_command("scan", "usage_graph"))
        assert read_running.wait(HANG_BOUND_SECONDS) and scan_running.wait(HANG_BOUND_SECONDS)
        client.sendall(_command("fix", "provider_sign_in", {"provider": "grok"}))
        reply = _read_strict(client, 1)[0]
        assert reply["id"] == "fix" and reply["ok"] is True
        assert not release.is_set()
        release.set()
        assert sorted(reply["id"] for reply in _read_strict(client, 2)) == ["history", "scan"]
        client.close()
    finally:
        release.set()
        instance.stop()


def test_sign_ins_share_one_worker_and_a_bound_of_their_own(
    sock_dir: Path, monkeypatch  # noqa: F811
) -> None:
    release = threading.Event()
    running = threading.Event()
    order: list[str] = []

    def dispatch(name: str, args: dict):
        if name == "provider_sign_in":
            order.append(args["tag"])
            running.set()
            assert release.wait(HANG_BOUND_SECONDS)
        return {"name": name}

    monkeypatch.setattr(core_server, "MAX_SLOW_LANE_QUEUED", 1)
    instance = _serve(sock_dir, dispatch)
    try:
        client = _connect(instance)
        _read_strict(client, 1)
        client.sendall(_command("s1", "provider_sign_in", {"tag": "one"}))
        assert running.wait(HANG_BOUND_SECONDS)  # s1 is running, so the queue is empty
        client.sendall(_command("s2", "provider_sign_in", {"tag": "two"}))
        client.sendall(_command("s3", "provider_sign_in", {"tag": "three"}))
        refused = _read_strict(client, 1)[0]
        assert refused["id"] == "s3" and refused["ok"] is False and refused["error"]["code"] == "busy"
        # The other lanes' queues are untouched: a read is accepted, not refused.
        client.sendall(_command("history", "list_history"))
        assert _read_strict(client, 1)[0]["id"] == "history"
        assert order == ["one"], "two sign-ins never run at once"
        release.set()
        assert [reply["id"] for reply in _read_strict(client, 2)] == ["s1", "s2"]
        assert order == ["one", "two"]
        client.close()
    finally:
        release.set()
        instance.stop()
