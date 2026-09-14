"""The JSON-RPC transport: ids, matching, bounds, and teardown."""

import subprocess
import sys
import threading
import time

import pytest

from jrbar.acp_transport import (
    JsonRpcTransport,
    TransportClosed,
    TransportProtocolError,
    TransportTimeout,
)

# A fake peer: echoes each request's method back as the result, replies
# to "crash" by exiting, and answers "ping" with a notification first —
# the adapter-visible cases a real ACP peer produces.
FAKE_PEER = """
import json, sys
for line in sys.stdin:
    line = line.strip()
    if not line:
        continue
    frame = json.loads(line)
    if "method" not in frame:
        continue
    if frame["method"] == "crash":
        sys.exit(0)
    if frame["method"] == "slow":
        import time; time.sleep(5)
    if frame["method"] == "notice":
        # notification — no id, no reply
        continue
    if "id" not in frame:
        continue
    if frame["method"] == "ping":
        sys.stdout.write(json.dumps(
            {"jsonrpc": "2.0", "method": "peer/notice", "params": {"seen": True}}) + "\\n")
        sys.stdout.flush()
    if frame["method"] == "fail":
        sys.stdout.write(json.dumps(
            {"jsonrpc": "2.0", "id": frame["id"],
             "error": {"code": -32601, "message": "no such method"}}) + "\\n")
    else:
        sys.stdout.write(json.dumps(
            {"jsonrpc": "2.0", "id": frame["id"], "result": {"echo": frame["method"]}}) + "\\n")
    sys.stdout.flush()
"""


@pytest.fixture()
def peer():
    process = subprocess.Popen(
        [sys.executable, "-c", FAKE_PEER],
        stdin=subprocess.PIPE, stdout=subprocess.PIPE,
        stderr=subprocess.DEVNULL, text=True, bufsize=1,
    )
    yield process
    try:
        process.kill()
    except Exception:
        pass


def test_request_response_round_trip(peer):
    transport = JsonRpcTransport(peer)
    result = transport.request("session/new", {"cwd": "/tmp"}, timeout=5)
    assert result == {"echo": "session/new"}
    transport.close()


def test_request_ids_increase_and_match(peer):
    transport = JsonRpcTransport(peer)
    a = transport.request("one", timeout=5)
    b = transport.request("two", timeout=5)
    assert (a, b) == ({"echo": "one"}, {"echo": "two"})
    transport.close()


def test_notification_routes_to_handler(peer):
    seen = threading.Event()
    notices = []
    transport = JsonRpcTransport(
        peer, on_notification=lambda m, p: (notices.append(m), seen.set()))
    transport.request("ping", timeout=5)
    assert seen.wait(5)
    assert notices == ["peer/notice"]
    transport.close()


def test_error_frame_raises_protocol_error(peer):
    transport = JsonRpcTransport(peer)
    with pytest.raises(TransportProtocolError, match="no such method"):
        transport.request("fail", timeout=5)
    transport.close()


def test_deadline_bounds_a_silent_peer(peer):
    transport = JsonRpcTransport(peer)
    with pytest.raises(TransportTimeout):
        transport.request("slow", timeout=0.2)
    transport.close()


def test_peer_exit_closes_every_waiter(peer):
    transport = JsonRpcTransport(peer)
    transport.request("crash", timeout=5) if False else None
    # Ask the peer to exit without an in-flight request first.
    transport.notify("crash")
    deadline = time.monotonic() + 5
    while not transport.closed and time.monotonic() < deadline:
        time.sleep(0.02)
    assert transport.closed
    with pytest.raises(TransportClosed):
        transport.request("anything", timeout=1)


def test_close_is_idempotent(peer):
    transport = JsonRpcTransport(peer)
    transport.close()
    transport.close()
    assert transport.closed
