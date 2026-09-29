"""A Creator Micro key's window and ask requests go to the app.

The daemon has no windows of its own. The deck's Agent Browser, Usage and
Control Center keys ask the connected app for its Overview, Usage and
Control Center windows (`open_window {window}`), and its ask key asks for
the waiting ask on the panel (`reveal_ask`). The app runs both the way it
runs a `jrbar://` link; revealing an ask never answers it. With no app
connected the key's receipt says so.
"""

from __future__ import annotations

import json
import shutil
import socket
import tempfile
import time
from pathlib import Path
from types import SimpleNamespace

from jrbar.core_server import CommandRouter, CoreServer
from jrbar.deck_actions import DeckAction
from jrbar.deck_actions_macos import DeckActionReceipt, MacDeckActionExecutor
from jrbar.deck_control_center import APP_WINDOW_FOR_ACTION, deck_executor


class _Target:
    def __init__(self, *, connected: bool) -> None:
        self.connected = connected
        self.requests: list[tuple[str, dict]] = []

    def _core_request_app(self, kind: str, **fields) -> bool:
        self.requests.append((kind, fields))
        return self.connected


def test_window_keys_ask_the_app_for_its_windows__and_1_more() -> None:
    # --- scenario: window_keys_ask_the_app_for_its_windows
    target = _Target(connected=True)
    executor = deck_executor(target)

    receipts = {
        kind: executor.execute(DeckAction(kind=kind))
        for kind in ("open_agent_browser", "open_usage", "open_control_center")
    }

    assert target.requests == [
        ("open_window", {"window": "overview"}),
        ("open_window", {"window": "usage"}),
        ("open_window", {"window": "control-center"}),
    ]
    assert receipts == {
        "open_agent_browser": DeckActionReceipt("opened_agent_browser", True),
        "open_usage": DeckActionReceipt("opened_usage", True),
        "open_control_center": DeckActionReceipt("opened_control_center", True),
    }
    # Link names the app's AppCommand.AppWindow knows.
    assert set(APP_WINDOW_FOR_ACTION.values()) <= {"overview", "usage", "control-center"}

    # --- scenario: the_ask_key_asks_for_the_waiting_ask
    target = _Target(connected=True)

    receipt = deck_executor(target).execute(DeckAction(kind="reveal_current_ask"))

    assert target.requests == [("reveal_ask", {})]
    assert receipt == DeckActionReceipt("revealed_current_ask", True)


def test_with_no_app_connected_the_receipt_says_so__and_1_more() -> None:
    # --- scenario: with_no_app_connected_the_receipt_says_so
    target = _Target(connected=False)
    executor = deck_executor(target)

    for kind in ("open_agent_browser", "open_usage", "open_control_center", "reveal_current_ask"):
        assert executor.execute(DeckAction(kind=kind)) == DeckActionReceipt("app_not_connected", False)

    # --- scenario: a_target_without_the_hook_is_not_connected_either
    receipt = deck_executor(SimpleNamespace()).execute(DeckAction(kind="open_usage"))

    assert receipt == DeckActionReceipt("app_not_connected", False)


def test_a_callback_may_name_its_own_receipt() -> None:
    refused = DeckActionReceipt("app_not_connected", False)
    executor = MacDeckActionExecutor(open_usage=lambda: refused, reveal_current_ask=lambda: None)

    assert executor.execute(DeckAction(kind="open_usage")) is refused
    assert executor.execute(DeckAction(kind="reveal_current_ask")) == DeckActionReceipt(
        "revealed_current_ask", True
    )


def _sock_dir():
    """AF_UNIX paths are capped at 104 bytes; pytest's tmp_path is too long."""
    return Path(tempfile.mkdtemp(prefix="jrbar-", dir=tempfile.gettempdir()))


def _real_server(sock_dir: Path) -> CoreServer:
    return CoreServer(
        dispatch=CommandRouter(),
        initial_documents=lambda: [],
        socket_path=sock_dir / "core.sock",
    )


def _controller(server, published: list | None = None) -> SimpleNamespace:
    """The daemon's publish hook over a real CoreServer: with a list the
    event is only recorded, without one it goes out the way
    _core_publish_event sends it."""

    def publish(kind: str, **fields) -> None:
        document = {"kind": kind}
        document.update(fields)
        if published is not None:
            published.append((kind, fields))
        elif server is not None:
            server.publish_event(document)

    return SimpleNamespace(_core=server, _core_publish_event=publish)


def _request_app():
    from jrbar import core_runtime

    request = core_runtime.build_headless_controller_class()._core_request_app
    return getattr(request, "callable", request)


class _Frames:
    """Newline-delimited frames off a real socket, with a bounded wait."""

    def __init__(self, client: socket.socket, timeout: float = 3.0) -> None:
        self.client = client
        self.timeout = timeout
        self.buffer = b""

    def next(self) -> dict | None:
        deadline = time.monotonic() + self.timeout
        while time.monotonic() < deadline:
            if b"\n" in self.buffer:
                line, self.buffer = self.buffer.split(b"\n", 1)
                return json.loads(line)
            try:
                chunk = self.client.recv(65536)
            except TimeoutError:
                return None
            if not chunk:
                return None
            self.buffer += chunk
        return None

    def until_event(self, kind: str) -> dict | None:
        while (frame := self.next()) is not None:
            if frame.get("t") == "event" and frame.get("kind") == kind:
                return frame
        return None


def test_the_daemon_publishes_a_request_only_to_a_connected_app() -> None:
    # The real CoreServer, never started: client_count is a property there,
    # and a stub with a callable one once hid a request that never went out.
    request = _request_app()
    published: list[tuple[str, dict]] = []
    sock_dir = _sock_dir()
    try:
        server = _real_server(sock_dir)
        assert isinstance(type(server).client_count, property)
        assert server.client_count == 0

        assert request(_controller(server, published), "open_window", window="usage") is False
        assert request(_controller(None, published), "reveal_ask") is False
        assert published == []

        server._clients.append(SimpleNamespace(alive=True))
        assert request(_controller(server, published), "open_window", window="usage") is True
        assert published == [("open_window", {"window": "usage"})]
    finally:
        shutil.rmtree(sock_dir, ignore_errors=True)


def test_a_probe_that_raises_answers_not_connected_and_names_itself_in_the_log(monkeypatch) -> None:
    from jrbar import status_bar_legacy as legacy

    lines: list[str] = []
    monkeypatch.setattr(legacy, "log_status_bar", lines.append)
    published: list[tuple[str, dict]] = []

    class Broken:
        @property
        def client_count(self) -> int:
            raise RuntimeError("synthetic probe failure")

    assert _request_app()(_controller(Broken(), published), "reveal_ask") is False
    assert published == []
    assert len(lines) == 1
    assert lines[0].startswith("core: app request probe failed")
    assert "synthetic probe failure" in lines[0]


def test_a_connected_app_receives_the_window_and_ask_events() -> None:
    request = _request_app()
    sock_dir = _sock_dir()
    server = _real_server(sock_dir)
    client: socket.socket | None = None
    try:
        server.start()
        client = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
        client.settimeout(3.0)
        client.connect(str(server.socket_path))
        frames = _Frames(client)
        # The server counts a client before it sends hello, so a hello in
        # hand means client_count is already 1: no sleep, no polling.
        hello = frames.next()
        assert hello is not None and hello["t"] == "hello"
        assert server.client_count == 1
        controller = _controller(server)

        assert request(controller, "open_window", window="usage") is True
        opened = frames.until_event("open_window")
        assert opened is not None
        assert opened["window"] == "usage"

        assert request(controller, "reveal_ask") is True
        assert frames.until_event("reveal_ask") is not None
    finally:
        if client is not None:
            client.close()
        server.stop()
        shutil.rmtree(sock_dir, ignore_errors=True)
