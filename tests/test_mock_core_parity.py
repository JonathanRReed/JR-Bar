"""The mock daemon (`app/scripts/mock-core.py`) speaks the same expanded
contract the Swift app was built against: session dismissal, history
watermarks, scene packs, detected-agent metadata and the serve token.
These tests load the script in-process and drive its command handler the
way the socket loop does.
"""

from __future__ import annotations

import importlib.util
import json
import socket as _socket
import sys
import threading as _threading
from contextlib import contextmanager
from pathlib import Path

import pytest

ROOT = Path(__file__).resolve().parents[1]
MOCK_PATH = ROOT / "app" / "scripts" / "mock-core.py"


@pytest.fixture(scope="module")
def mock_module():
    spec = importlib.util.spec_from_file_location("mock_core_under_test", MOCK_PATH)
    module = importlib.util.module_from_spec(spec)
    sys.modules[spec.name] = module
    spec.loader.exec_module(module)
    return module


@pytest.fixture()
def world(mock_module):
    return mock_module.World(step_seconds=0.01, loop=False)


def _call(world, name, args=None):
    return world.handle_command({"name": name, "args": args or {}, "id": "t-1"})


def _error(reply) -> dict:
    assert reply["ok"] is False
    return reply["error"]


def test_settings_paths_use_a_synthetic_home(mock_module):
    path = mock_module.default_settings_document()["cloud_ingest_token_path"]
    synthetic = path == "/synthetic/jrbar-proof/.local/state/jrbar/cloud-ingest.token"
    assert synthetic


def test_session_paths_use_a_synthetic_home(world):
    paths = [session["cwd"] for session in world.sessions.values()]
    synthetic = bool(paths) and all(path.startswith("/synthetic/jrbar-proof/") for path in paths)
    assert synthetic


def test_auto_dim_mock_clock_covers_the_exclusive_end_minute(world) -> None:
    world.document["auto_dim"] = {
        "mode": "schedule",
        "schedule": {"start_minutes": 0, "end_minutes": 1439, "fraction": 0.25},
    }
    world.auto_dim_now_minutes = 720
    assert world.auto_dim()["factor"] == 0.25

    world.auto_dim_now_minutes = 1439
    assert world.auto_dim()["factor"] == 1.0


def test_sessions_carry_remote_flags__and_2_more(world) -> None:
    # --- scenario: sessions_carry_remote_flags
    sessions = world.state()["sessions"]
    assert sessions
    assert all("remote" in s for s in sessions)
    assert all(s["remote"] is False for s in sessions)

    # --- scenario: dismiss_session_hides_until_it_speaks
    sid = world.state()["sessions"][0]["id"]
    reply = _call(world, "dismiss_session", {"session": sid})
    assert reply["ok"] is True
    assert sid not in {s["id"] for s in world.state()["sessions"]}

    # The row returns the moment the session next speaks.
    world.set_mode(sid, "working", "active", "provider")
    assert sid in {s["id"] for s in world.state()["sessions"]}

    # --- scenario: dismiss_session_refusals
    assert _error(_call(world, "dismiss_session", {"session": "nope"}))["code"] == "not_found"

    sid = world.state()["sessions"][0]["id"]
    world.open_ask(sid, "Run tests?")
    assert _error(_call(world, "dismiss_session", {"session": sid}))["code"] == "refused"



def test_asks_carry_answer_flags__and_2_more(world) -> None:
    # --- scenario: asks_carry_answer_flags
    sid = world.state()["sessions"][0]["id"]  # a claude session
    world.open_ask(sid, "Run tests?", kind="permission")
    ask = next(a for a in world.state()["asks"] if a["session"] == sid)
    assert ask["answerable"] is True and ask["replyable"] is False

    gemini = next(s["id"] for s in world.state()["sessions"] if s["provider"] == "gemini")
    world.open_ask(gemini, "Proceed?", kind="input")
    ask = next(a for a in world.state()["asks"] if a["session"] == gemini)
    assert ask["answerable"] is False and ask["replyable"] is False

    # --- scenario: history_watermark_and_mark_seen
    first = _call(world, "list_history")
    assert first["ok"] is True
    assert any(r["unseen"] for r in first["result"]["rows"])

    seen = _call(world, "mark_history_seen")
    assert seen["ok"] is True and seen["result"]["last_seen"] >= first["result"]["last_seen"]

    after = _call(world, "list_history")
    assert after["result"]["last_seen"] == seen["result"]["last_seen"]
    assert all(r["unseen"] is False for r in after["result"]["rows"])

    # --- scenario: serve_token_is_deterministic
    reply = _call(world, "serve_token")
    assert reply["ok"] is True
    assert reply["result"]["token"] == "mock-serve-token-7f02"



def test_scene_packs_list_preview_and_import(world, tmp_path) -> None:
    packs = _call(world, "list_scene_packs")["result"]["packs"]
    seeded = next(p for p in packs if p["id"] == "nightlab-scenes")
    assert seeded["installed"] is True and set(seeded["scenes"]) == {"calm", "night"}

    preview = _call(world, "preview_scene_pack", {"pack_id": "nightlab-scenes", "led_count": 4})
    assert preview["ok"] is True
    assert preview["result"]["led_count"] == 4 and "program" in preview["result"]

    assert _error(_call(world, "preview_scene_pack", {"pack_id": "missing"}))["code"] == "not_found"

    path = tmp_path / "pack.json"
    path.write_text(json.dumps({"id": "dusk", "name": "Dusk", "scenes": ["night", "dnd"]}))
    imported = _call(world, "import_scene_pack", {"path": str(path)})
    assert imported["ok"] is True and imported["result"]["pack_id"] == "dusk"
    assert any(p["id"] == "dusk" for p in _call(world, "list_scene_packs")["result"]["packs"])

    assert _error(_call(world, "import_scene_pack", {"path": str(tmp_path / "absent.json")}))["code"] == "invalid_pack"


def test_health_detected_and_hook_install(world) -> None:
    detected = world.state()["health"]["detected"]
    assert detected["claude"] is True and detected["grok"] is False

    reply = _call(world, "install_hooks", {"providers": ["claude", "grok"]})
    assert reply["ok"] is True
    results = reply["result"]["results"]
    assert results["claude"]["ok"] is True and results["claude"]["detected"] is True
    assert results["grok"]["ok"] is False and results["grok"]["detected"] is False


def test_session_usage_speaks_the_daemons_document(world) -> None:
    """X15: the mock's ``session_usage`` carries the daemon's keys, with one
    session that has ``window_tokens`` and one whose figure is null, so the
    app's Agent Overview window share is exercised both ways."""
    from jrbar import session_usage

    daemon_keys = set(
        session_usage.usage_document(
            "claude", session_usage._FileUsage(provider="claude", device=1, inode=1), since=0.0
        )
    )
    claude = next(sid for sid, s in world.sessions.items() if s["provider"] == "claude" and s["kind"] == "main")
    codex = next(sid for sid, s in world.sessions.items() if s["provider"] == "codex")
    gemini = next(sid for sid, s in world.sessions.items() if s["provider"] == "gemini")
    reply = _call(world, "session_usage", {"ids": [claude, codex, gemini, "remote:studio:claude:x"], "since": 0})
    assert reply["ok"] is True
    result = reply["result"]
    assert set(result["sessions"][claude]) == daemon_keys
    assert set(result["sessions"][codex]) == daemon_keys
    assert result["sessions"][claude]["window_tokens"] == 340_000
    assert result["sessions"][codex]["window_tokens"] is None
    assert result["gaps"] == {gemini: "unsupported_provider", "remote:studio:claude:x": "remote"}
    assert _error(_call(world, "session_usage", {"ids": []}))["code"] == "invalid_value"


def test_a_workers_request_is_quiet_by_default_and_counted_on_its_parent(world) -> None:
    from_state = world.state()
    parent = next(s for s in from_state["sessions"] if s["kind"] == "main" and s["workers"] > 0)
    worker = next(s for s in from_state["sessions"] if s["kind"] == "worker" and s["parent"] == parent["id"])
    assert parent["workers_waiting"] == 0
    assert "workers_waiting" not in worker
    baseline = from_state["aggregate"]["needs_you"]

    # Off by default: the worker waits, nothing asks, the parent row says so.
    assert world.document["subagent_asks_alert"] is False
    world.open_ask(worker["id"], "Run: make build")
    quiet = world.state()
    assert quiet["asks"] == []
    assert next(s for s in quiet["sessions"] if s["id"] == parent["id"])["workers_waiting"] == 1
    assert quiet["aggregate"]["needs_you"] == baseline

    # On: the same request is an ordinary ask and counts as needs you.
    world.document["subagent_asks_alert"] = True
    world.open_ask(worker["id"], "Run: make build")
    loud = world.state()
    assert [a["session"] for a in loud["asks"]] == [worker["id"]]
    assert next(s for s in loud["sessions"] if s["id"] == parent["id"])["workers_waiting"] == 0
    assert loud["aggregate"]["needs_you"] == baseline + 1


# --- the mock's side of the app handshake (docs/CORE-PROTOCOL.md, "Who may send what") ---

_SECRET = bytes(range(32))


@contextmanager
def _mock_peer(mock_module, world):
    """A mock `Client` served over a socketpair; returns the test's end."""
    left, right = _socket.socketpair()
    right.settimeout(5.0)
    # The mock broadcasts state to every client, read or not: room for it.
    for end in (left, right):
        end.setsockopt(_socket.SOL_SOCKET, _socket.SO_SNDBUF, 1 << 20)
        end.setsockopt(_socket.SOL_SOCKET, _socket.SO_RCVBUF, 1 << 20)
    client = mock_module.Client(world, left, once=False, stop=_threading.Event())
    thread = _threading.Thread(target=client.serve, daemon=True)
    thread.start()
    try:
        yield right
    finally:
        right.close()
        thread.join(timeout=5.0)
        assert not thread.is_alive(), "mock peer survived test teardown"


class _Wire:
    def __init__(self, connection) -> None:
        self.connection = connection
        self.buffer = b""
        self.count = 0

    def frame(self) -> dict:
        while b"\n" not in self.buffer:
            chunk = self.connection.recv(65536)
            assert chunk, "the mock closed the connection"
            self.buffer += chunk
        line, self.buffer = self.buffer.split(b"\n", 1)
        return json.loads(line)

    def until(self, kind: str) -> dict:
        while True:
            frame = self.frame()
            if frame.get("t") == kind:
                return frame

    def call(self, name: str, args: dict | None = None) -> dict:
        self.count += 1
        identifier = f"w-{self.count}"
        self.connection.sendall(
            (json.dumps({"t": "command", "v": 1, "id": identifier, "name": name, "args": args or {}}) + "\n").encode()
        )
        while True:
            frame = self.frame()
            if frame.get("t") == "reply" and frame.get("id") == identifier:
                return frame


def test_a_mock_with_no_secret_takes_every_command_from_every_connection(mock_module) -> None:
    world = mock_module.World(step_seconds=0.01, loop=False)
    with _mock_peer(mock_module, world) as connection:
        wire = _Wire(connection)
        assert "auth" not in wire.until("hello")
        assert wire.call("set_brightness", {"value": 0.4})["ok"] is True
        assert wire.call("auth", {"proof": "0" * 64})["error"]["code"] == "auth_unavailable"


def test_a_mock_with_a_secret_offers_a_nonce_and_refuses_strangers(mock_module) -> None:
    world = mock_module.World(step_seconds=0.01, loop=False)
    world.auth_secret = _SECRET
    with _mock_peer(mock_module, world) as app, _mock_peer(mock_module, world) as stranger:
        app_wire, stranger_wire = _Wire(app), _Wire(stranger)
        nonce = app_wire.until("hello")["auth"]["nonce"]
        assert stranger_wire.until("hello")["auth"]["nonce"] != nonce

        refused = stranger_wire.call("answer_ask", {"session": "claude:synthetic"})
        assert refused["error"]["code"] == "unauthenticated"
        assert stranger_wire.call("quiet", {"mode": "dim", "seconds": 5})["ok"] is True

        proved = app_wire.call("auth", {"proof": mock_module.auth_proof(_SECRET, nonce)})
        assert proved["ok"] is True and proved["result"] == {"authenticated": True}
        # Not "unauthenticated": the mock has no such session, which only an app may ask about.
        assert app_wire.call("answer_ask", {"session": "claude:none"})["error"]["code"] == "not_found"


def test_a_mock_closes_on_a_wrong_proof(mock_module) -> None:
    world = mock_module.World(step_seconds=0.01, loop=False)
    world.auth_secret = _SECRET
    with _mock_peer(mock_module, world) as connection:
        wire = _Wire(connection)
        wire.until("hello")
        assert wire.call("auth", {"proof": "0" * 64})["error"]["code"] == "auth_failed"
        assert connection.recv(65536) == b""


def test_the_mocks_proof_and_open_list_match_the_daemons(mock_module) -> None:
    from jrbar import core_auth

    assert mock_module.auth_proof(_SECRET, "a" * 32) == core_auth.auth_proof(_SECRET, "a" * 32)
    daemon_open = {
        name for name, kind in core_auth.COMMAND_PRIVILEGE.items()
        if kind == "open" and name not in ("set_setting", "reset_settings")
    }
    assert set(mock_module.MOCK_OPEN_COMMANDS) == daemon_open
