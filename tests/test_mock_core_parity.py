"""The mock daemon (`app/scripts/mock-core.py`) speaks the same expanded
contract the Swift app was built against: session dismissal, history
watermarks, scene packs, detected-agent metadata and the serve token.
These tests load the script in-process and drive its command handler the
way the socket loop does.
"""

from __future__ import annotations

import importlib.util
import json
import sys
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


def test_sessions_carry_remote_flags(world) -> None:
    sessions = world.state()["sessions"]
    assert sessions
    assert all("remote" in s for s in sessions)
    assert all(s["remote"] is False for s in sessions)


def test_dismiss_session_hides_until_it_speaks(world) -> None:
    sid = world.state()["sessions"][0]["id"]
    reply = _call(world, "dismiss_session", {"session": sid})
    assert reply["ok"] is True
    assert sid not in {s["id"] for s in world.state()["sessions"]}

    # The row returns the moment the session next speaks.
    world.set_mode(sid, "working", "active", "provider")
    assert sid in {s["id"] for s in world.state()["sessions"]}


def test_dismiss_session_refusals(world) -> None:
    assert _error(_call(world, "dismiss_session", {"session": "nope"}))["code"] == "not_found"

    sid = world.state()["sessions"][0]["id"]
    world.open_ask(sid, "Run tests?")
    assert _error(_call(world, "dismiss_session", {"session": sid}))["code"] == "refused"


def test_asks_carry_answer_flags(world) -> None:
    sid = world.state()["sessions"][0]["id"]  # a claude session
    world.open_ask(sid, "Run tests?", kind="permission")
    ask = next(a for a in world.state()["asks"] if a["session"] == sid)
    assert ask["answerable"] is True and ask["replyable"] is False

    gemini = next(s["id"] for s in world.state()["sessions"] if s["provider"] == "gemini")
    world.open_ask(gemini, "Proceed?", kind="input")
    ask = next(a for a in world.state()["asks"] if a["session"] == gemini)
    assert ask["answerable"] is False and ask["replyable"] is False


def test_history_watermark_and_mark_seen(world) -> None:
    first = _call(world, "list_history")
    assert first["ok"] is True
    assert any(r["unseen"] for r in first["result"]["rows"])

    seen = _call(world, "mark_history_seen")
    assert seen["ok"] is True and seen["result"]["last_seen"] >= first["result"]["last_seen"]

    after = _call(world, "list_history")
    assert after["result"]["last_seen"] == seen["result"]["last_seen"]
    assert all(r["unseen"] is False for r in after["result"]["rows"])


def test_serve_token_is_deterministic(world) -> None:
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
