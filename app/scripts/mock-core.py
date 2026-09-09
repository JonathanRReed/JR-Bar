#!/usr/bin/env python3
"""A mock jrbar-core daemon for exercising the native app without the real core.

Speaks protocol 1 (docs/CORE-PROTOCOL.md) over a Unix socket: on connect it
sends hello, a full state, lights and settings, then plays a scripted
timeline so every panel section has something to show:

  1. a Claude session starts working              (working relay on the lights)
  2. a Codex permission ask opens                  (amber ask pulse, ask_opened)
  3. the ask resolves (or you Approve/Deny it)     (ask_resolved)
  4. Codex completes                               (completed, done light)
  5. the SidePulse Pro disconnects                 (device_disconnected)
  6. ...and reconnects                             (device_connected)
  7. Claude completes, then everything goes idle   (idle breath)

and loops. Usage numbers tick up every step. Commands are logged to stderr
and answered with an ok reply; answer_ask, set_brightness, clear_completed,
quiet and snooze also change the world so the UI round-trips.

Standard library only.

  mock-core.py                       # listen on ~/.local/state/jrbar/core.sock
  mock-core.py --socket /tmp/x.sock  # elsewhere
  mock-core.py --step 1.5            # seconds between timeline steps
  mock-core.py --once                # hello/state/lights/settings, then exit
"""

from __future__ import annotations

import argparse
import json
import os
import signal
import socket
import sys
import threading
import time
from pathlib import Path

PROTOCOL_VERSION = 1
DEFAULT_SOCKET = Path(os.environ.get("XDG_STATE_HOME") or Path.home() / ".local" / "state") / "jrbar" / "core.sock"

WORKING_RELAY = (
    "off 160ms cosine\n"
    "0:#00E5FF 1400ms pulse 0ms; 1:#00E5FF 1400ms pulse 170ms; 2:#00E5FF 1400ms pulse 340ms; "
    "3:#00E5FF 1400ms pulse 510ms; 4:#00E5FF 1400ms pulse 680ms; 5:#00E5FF 1400ms pulse 850ms; "
    "6:#00E5FF 1400ms pulse 1020ms; 7:#00E5FF 1400ms pulse 1190ms\n"
    "repeat"
)
ASK_PULSE = "off 160ms cosine\n#FF3A00 1.6s pulse\nrepeat"
COMPLETED_UNSEEN = "off 160ms cosine\n#00FF66 2200ms pulse\nrepeat"
IDLE_BREATH = "off 160ms cosine\n#2B2F36 1900ms cosine\noff 2550ms cosine\noff 850ms none\nrepeat"
DOT_WORKING = "off 160ms cosine\n0:#00E5FF 1400ms pulse 0ms; 1:#00E5FF 1400ms pulse 700ms\nrepeat"
DOT_ASK = ASK_PULSE
DOT_DONE = COMPLETED_UNSEEN
DOT_IDLE = IDLE_BREATH

HOME = str(Path.home())
CLAUDE_ID = "claude:session:fca1eb06-f6d1-413e-aa5f-dd19d8e05973"
CLAUDE_WORKER_ID = "claude:session:fca1eb06-f6d1-413e-aa5f-dd19d8e05973:worker:1"
CODEX_ID = "codex:session:0f3b2c9a-71d4-4e0e-9a8e-2c1d5f6a7b8c"
GEMINI_ID = "gemini:session:8a1c2e3f-5b6d-4c7e-9f0a-1b2c3d4e5f6a"
PRO_ID = "sidepulse:pro:B293A1"
DOT_ID = "sidepulse:dot:7F02C4"


def log(message: str) -> None:
    sys.stderr.write(f"mock-core: {message}\n")
    sys.stderr.flush()


class World:
    """Everything the daemon knows, plus the timeline that mutates it."""

    def __init__(self, step_seconds: float, loop: bool) -> None:
        self.lock = threading.RLock()
        self.step_seconds = step_seconds
        self.loop = loop
        self.generation = 4800
        self.settings_generation = 17
        self.clients: list[Client] = []
        self.event_counter = 0
        self.start = time.time()
        now = self.start
        self.sessions: dict[str, dict] = {
            CLAUDE_ID: self._session(
                CLAUDE_ID, "claude", "jr-bar-b7", f"{HOME}/Downloads/JR-Bar", now - 3600,
                origin={"kind": "claude_desktop", "label": "Claude Desktop", "bundle_id": "com.anthropic.claudefordesktop"},
                terminal={"app": "Ghostty", "bundle_id": "com.mitchellh.ghostty", "tty": "/dev/ttys004"},
                pid=9170,
            ),
            CODEX_ID: self._session(
                CODEX_ID, "codex", "sidepulse-core", f"{HOME}/Downloads/JR-Bar/src", now - 1500,
                origin={"kind": "terminal", "label": "Terminal", "bundle_id": "com.apple.Terminal"},
                terminal={"app": "Terminal", "bundle_id": "com.apple.Terminal", "tty": "/dev/ttys007"},
                pid=9311,
            ),
            GEMINI_ID: self._session(
                GEMINI_ID, "gemini", "docs-sweep", f"{HOME}/Projects/notes", now - 9000,
                origin={"kind": "terminal", "label": "Ghostty", "bundle_id": "com.mitchellh.ghostty"},
                terminal={"app": "Ghostty", "bundle_id": "com.mitchellh.ghostty", "tty": "/dev/ttys009"},
                pid=8020, mode="idle", lifecycle="active", next_actor="user",
            ),
        }
        self.sessions[CLAUDE_WORKER_ID] = self._session(
            CLAUDE_WORKER_ID, "claude", "worker", f"{HOME}/Downloads/JR-Bar", now - 600,
            kind="worker", parent=CLAUDE_ID, pid=9188,
        )
        self.asks: list[dict] = []
        self.devices: dict[str, dict] = {
            PRO_ID: {"id": PRO_ID, "kind": "pro", "name": "SidePulse", "path": "/Volumes/SidePulse", "leds": 8,
                     "connected": True, "brightness": 79, "linked": True, "last_write": now, "error": None},
            DOT_ID: {"id": DOT_ID, "kind": "dot", "name": "PulseDot", "path": "/Volumes/PulseDot", "leds": 2,
                     "connected": True, "brightness": 60, "linked": True, "last_write": now, "error": None},
            "screen-bar": {"id": "screen-bar", "kind": "screen_bar", "leds": 8, "enabled": True},
        }
        self.usage = {
            "claude": {"h5": 42.0, "d7": 61.0, "fidelity": "official", "pace": "ahead"},
            "codex": {"h5": 12.0, "d7": 30.0, "fidelity": "derived", "pace": "on_pace"},
            "gemini": {"h5": 3.0, "d7": 8.0, "fidelity": "derived", "pace": "behind"},
        }
        self.focus = {"mode": "normal", "source": "default", "until": None}
        self.escalation = {"stage": "none", "since": None}
        self.lights_semantic = "idle"
        self.anchor = now
        self.brightness = 0.79
        self.snoozed_until = 0.0

    # -- construction helpers ------------------------------------------------

    @staticmethod
    def _session(sid, provider, label, cwd, since, *, kind="main", parent=None, origin=None, terminal=None,
                 pid=None, mode="idle", lifecycle="active", next_actor="provider"):
        return {
            "id": sid, "provider": provider, "kind": kind, "parent": parent, "label": label, "cwd": cwd,
            "mode": mode, "lifecycle": lifecycle, "next_actor": next_actor, "since": since,
            "updated_at": since, "stale": False, "pid": pid, "origin": origin, "ask": None,
            "terminal": terminal, "workers": 0,
        }

    # -- documents ------------------------------------------------------------

    def hello(self) -> dict:
        return {"t": "hello", "v": PROTOCOL_VERSION, "core_version": "0.8.0-mock", "pid": os.getpid(),
                "capabilities": ["sessions", "lights", "usage", "devices", "power", "effects", "calibration",
                                 "history", "peers", "ingest"]}

    def aggregate(self) -> dict:
        mains = [s for s in self.sessions.values() if s["kind"] == "main"]
        needs_you = len(self.asks) + sum(1 for s in mains if s["next_actor"] == "user" and s["lifecycle"] == "active" and not s["ask"])
        active = sum(1 for s in mains if s["lifecycle"] == "active" and s["mode"] in ("working", "tool_running", "thinking"))
        ready = sum(1 for s in mains if s["lifecycle"] == "completed")
        failed = sum(1 for s in mains if s["lifecycle"] == "failed")
        if self.asks:
            mode = "needs_you"
        elif failed:
            mode = "failed"
        elif active:
            mode = "working"
        elif ready:
            mode = "done"
        else:
            mode = "idle"
        return {"mode": mode, "needs_you": needs_you, "active": active, "ready": ready}

    def state(self) -> dict:
        now = time.time()
        for s in self.sessions.values():
            if s["kind"] == "main":
                s["workers"] = sum(1 for w in self.sessions.values() if w["parent"] == s["id"] and w["lifecycle"] == "active")
        providers = []
        for pid, u in self.usage.items():
            providers.append({
                "id": pid,
                "windows": [
                    {"name": "5h", "used_pct": round(u["h5"], 1), "resets_at": now + 2 * 3600 + 840},
                    {"name": "7d", "used_pct": round(u["d7"], 1), "resets_at": now + 3 * 86400 + 5 * 3600},
                ],
                "fidelity": u["fidelity"],
                "state": "ok" if u["h5"] < 85 else "warning",
                "forecast": {"exhausts_at": now + 4 * 3600, "pace": u["pace"]},
            })
        return {
            "t": "state", "v": PROTOCOL_VERSION, "generation": self.generation, "now": now,
            "aggregate": self.aggregate(),
            "sessions": list(self.sessions.values()),
            "asks": list(self.asks),
            "devices": list(self.devices.values()),
            "usage": {"refreshed_at": now - 45, "providers": providers},
            "power": {"keep_awake": True, "closed_lid": {"policy": "agents", "holding": False, "helper_installed": True}},
            "focus": self.focus,
            "escalation": self.escalation,
            "health": {"hooks": {"claude": "ok", "codex": "ok", "gemini": "ok", "pi": "missing"},
                       "sources": {"codex": {"fresh": True}}},
            "settings_generation": self.settings_generation,
            # Forward-compatibility bait: the app must ignore this.
            "x_mock_extra": {"note": "unknown keys are fine"},
        }

    def lights(self) -> dict:
        programs = {
            "working": (WORKING_RELAY, DOT_WORKING, "working"),
            "ask": (ASK_PULSE, DOT_ASK, "needs_you"),
            "done": (COMPLETED_UNSEEN, DOT_DONE, "completed_unseen"),
            "idle": (IDLE_BREATH, DOT_IDLE, "idle"),
        }
        strip, dot, why = programs[self.lights_semantic]
        motion = {"working": "chase", "ask": "beat", "done": "pulse", "idle": "breathe"}[self.lights_semantic]
        fallback = {"working": "#00E5FF", "ask": "#FF3A00", "done": "#00FF66", "idle": "#020204"}[self.lights_semantic]
        surface = {"program": strip, "led_count": 8, "anchor": self.anchor, "motion": motion,
                   "static_fallback": fallback, "brightness": self.brightness, "why": why}
        return {
            "t": "lights", "v": PROTOCOL_VERSION,
            "surfaces": {
                "hardware": dict(surface),
                "screen_bar": dict(surface),
                "dot": {"program": dot, "led_count": 2, "anchor": self.anchor, "motion": motion,
                        "static_fallback": fallback, "brightness": self.brightness, "why": why},
            },
            "linked": True,
        }

    def settings(self) -> dict:
        return {
            "t": "settings", "v": PROTOCOL_VERSION, "generation": self.settings_generation, "schema": 3,
            "document": {
                "screen_bar": {"enabled": True, "wrap_menu_bar": True, "min_glow": 0.25},
                "devices": {PRO_ID: {"brightness": self.brightness}, DOT_ID: {"brightness": 0.6}},
                "sounds": {"completed": "glass", "ask": "tink"},
                "quiet": {"mode": self.focus["mode"]},
                "providers": {"claude": {"color": "#D97757"}, "codex": {"color": "#2B8FFF"}},
            },
        }

    def event(self, kind: str, session: str | None = None, label: str | None = None, **extra) -> dict:
        self.event_counter += 1
        payload = {"t": "event", "v": PROTOCOL_VERSION, "id": f"ev-{self.event_counter}", "kind": kind,
                   "session": session, "label": label, "at": time.time(), "sound": None, "notify": True}
        payload.update(extra)
        return payload

    # -- broadcasting ---------------------------------------------------------

    def broadcast(self, *documents: dict) -> None:
        with self.lock:
            clients = list(self.clients)
        for client in clients:
            for document in documents:
                client.send(document)

    def push_state(self) -> None:
        with self.lock:
            self.generation += 1
            document = self.state()
        self.broadcast(document)

    def push_lights(self, semantic: str) -> None:
        with self.lock:
            if semantic != self.lights_semantic:
                self.anchor = time.time()
            self.lights_semantic = semantic
            document = self.lights()
        self.broadcast(document)

    def push_settings(self) -> None:
        with self.lock:
            self.settings_generation += 1
            document = self.settings()
        self.broadcast(document)

    def push_event(self, kind: str, session: str | None = None, label: str | None = None, **extra) -> None:
        with self.lock:
            document = self.event(kind, session, label, **extra)
        self.broadcast(document)

    # -- mutations used by the timeline and commands ---------------------------

    def set_mode(self, sid: str, mode: str, lifecycle: str = "active", next_actor: str = "provider") -> None:
        with self.lock:
            s = self.sessions[sid]
            changed = (s["mode"], s["lifecycle"], s["next_actor"]) != (mode, lifecycle, next_actor)
            s["mode"], s["lifecycle"], s["next_actor"] = mode, lifecycle, next_actor
            s["updated_at"] = time.time()
            if changed:
                s["since"] = time.time()

    def open_ask(self, sid: str, summary: str, kind: str = "permission") -> None:
        with self.lock:
            ask = {"session": sid, "kind": kind, "opened_at": time.time(), "summary": summary}
            self.asks = [a for a in self.asks if a["session"] != sid] + [ask]
            self.sessions[sid]["ask"] = {"kind": kind, "opened_at": ask["opened_at"], "summary": summary}
            self.set_mode(sid, "waiting", "active", "user")

    def resolve_ask(self, sid: str, decision: str) -> bool:
        with self.lock:
            had = any(a["session"] == sid for a in self.asks)
            self.asks = [a for a in self.asks if a["session"] != sid]
            if sid in self.sessions:
                self.sessions[sid]["ask"] = None
                self.set_mode(sid, "tool_running" if decision == "approve" else "thinking", "active", "provider")
            return had

    def light_for_world(self) -> str:
        with self.lock:
            agg = self.aggregate()["mode"]
        return {"needs_you": "ask", "working": "working", "done": "done"}.get(agg, "idle")

    # -- timeline -------------------------------------------------------------

    def timeline_steps(self) -> list[tuple[str, float]]:
        """(name, pause multiplier) for every step; `--start-at N` begins at index N."""
        return [
            ("claude_working", 1.5),
            ("codex_ask", 2.5),
            ("codex_ask_resolved", 1.0),
            ("codex_completed", 1.5),
            ("pro_disconnected", 1.0),
            ("pro_reconnected", 1.0),
            ("claude_completed", 1.5),
            ("idle", 2.0),
        ]

    def play_step(self, name: str) -> None:
        if name == "claude_working":
            log("timeline: claude starts working")
            self.set_mode(CLAUDE_ID, "tool_running")
            self.set_mode(CLAUDE_WORKER_ID, "tool_running")
            self.push_state()
            self.push_lights("working")
        elif name == "codex_ask":
            log("timeline: codex ask opens")
            self.open_ask(CODEX_ID, "Run: rm -rf build")
            self.push_state()
            self.push_lights("ask")
            self.push_event("ask_opened", CODEX_ID, "sidepulse-core", sound="tink")
        elif name == "codex_ask_resolved":
            # Resolves on its own unless someone answered it already.
            if self.resolve_ask(CODEX_ID, "approve"):
                log("timeline: codex ask times out as approved")
                self.push_event("ask_resolved", CODEX_ID, "sidepulse-core")
            self.push_state()
            self.push_lights(self.light_for_world())
        elif name == "codex_completed":
            log("timeline: codex completes")
            self.set_mode(CODEX_ID, "idle", "completed", "user")
            self.push_state()
            self.push_lights("done")
            self.push_event("completed", CODEX_ID, "sidepulse-core", sound="glass")
        elif name == "pro_disconnected":
            log("timeline: pro disconnects")
            with self.lock:
                self.devices[PRO_ID]["connected"] = False
                self.devices[PRO_ID]["error"] = "volume unmounted"
            self.push_state()
            self.push_event("device_disconnected", None, "SidePulse")
        elif name == "pro_reconnected":
            log("timeline: pro reconnects")
            with self.lock:
                self.devices[PRO_ID]["connected"] = True
                self.devices[PRO_ID]["error"] = None
                self.devices[PRO_ID]["last_write"] = time.time()
            self.push_state()
            self.push_lights(self.light_for_world())
            self.push_event("device_connected", None, "SidePulse")
        elif name == "claude_completed":
            log("timeline: claude completes")
            self.set_mode(CLAUDE_ID, "idle", "completed", "user")
            self.set_mode(CLAUDE_WORKER_ID, "idle", "completed", "user")
            self.push_state()
            self.push_lights("done")
            self.push_event("completed", CLAUDE_ID, "jr-bar-b7", sound="glass")
        elif name == "idle":
            log("timeline: idle")
            with self.lock:
                for sid in (CLAUDE_ID, CODEX_ID, CLAUDE_WORKER_ID):
                    if self.sessions[sid]["lifecycle"] == "completed":
                        self.set_mode(sid, "idle", "active", "provider")
            self.push_state()
            self.push_lights("idle")

    def run_timeline(self, stop: threading.Event, start_at: int = 0) -> None:
        def pause(mult: float = 1.0) -> bool:
            deadline = time.time() + self.step_seconds * mult
            while time.time() < deadline:
                if stop.is_set():
                    return False
                self.tick_usage(0.35 / max(self.step_seconds, 0.1))
                stop.wait(0.5)
            return not stop.is_set()

        steps = self.timeline_steps()
        index = max(0, min(start_at, len(steps) - 1))
        if index:
            # Fast-forward through the earlier steps so the world is consistent.
            for name, _ in steps[:index]:
                self.play_step(name)
        while not stop.is_set():
            for name, mult in steps[index:]:
                self.play_step(name)
                if not pause(mult):
                    return
            index = 0
            if not self.loop:
                break

    def tick_usage(self, amount: float) -> None:
        changed = False
        with self.lock:
            for u in self.usage.values():
                u["h5"] = min(99.0, u["h5"] + amount)
                u["d7"] = min(99.0, u["d7"] + amount * 0.3)
                changed = True
        if changed:
            self.push_state()

    # -- commands -------------------------------------------------------------

    def handle_command(self, command: dict) -> dict:
        name = command.get("name")
        args = command.get("args") or {}
        cid = command.get("id")
        result: dict = {}
        if name == "answer_ask":
            sid = args.get("session")
            decision = args.get("decision", "approve")
            had = self.resolve_ask(sid, decision)
            if had:
                self.push_event("ask_resolved", sid, self.sessions.get(sid, {}).get("label"))
            self.push_state()
            self.push_lights(self.light_for_world())
            result = {"answered": had, "decision": decision}
            if not had:
                return {"t": "reply", "v": PROTOCOL_VERSION, "id": cid, "ok": False,
                        "error": {"code": "not_found", "message": "no live ask for that session"}}
        elif name == "open_session":
            sid = args.get("session")
            s = self.sessions.get(sid)
            result = {"activated": (s or {}).get("terminal", {}).get("app") if s else None}
            if s is None:
                return {"t": "reply", "v": PROTOCOL_VERSION, "id": cid, "ok": False,
                        "error": {"code": "not_found", "message": "no such session"}}
        elif name == "set_brightness":
            value = float(args.get("value", 0.5))
            with self.lock:
                self.brightness = max(0.0, min(1.0, value))
                target = args.get("device", "all")
                for dev in self.devices.values():
                    if dev["kind"] in ("pro", "dot") and (target == "all" or dev["id"] == target):
                        dev["brightness"] = int(round(self.brightness * 100))
            self.push_state()
            self.broadcast(self.lights())
            result = {"value": self.brightness}
        elif name == "clear_completed":
            with self.lock:
                cleared = []
                for s in self.sessions.values():
                    if s["lifecycle"] == "completed":
                        s["lifecycle"] = "active"
                        s["mode"] = "idle"
                        s["next_actor"] = "provider"
                        s["since"] = time.time()
                        cleared.append(s["id"])
            self.push_state()
            self.push_lights(self.light_for_world())
            result = {"batch": "b-1", "cleared": cleared}
        elif name == "quiet":
            with self.lock:
                seconds = float(args.get("seconds", 1800))
                self.focus = {"mode": args.get("mode", "dnd"), "source": "manual", "until": time.time() + seconds}
            self.push_state()
            self.push_settings()
            result = {"until": self.focus["until"]}
        elif name == "snooze":
            with self.lock:
                self.snoozed_until = time.time() + float(args.get("seconds", 600))
            result = {"until": self.snoozed_until}
        elif name == "set_setting":
            self.push_settings()
            result = {"generation": self.settings_generation}
        elif name == "quit":
            result = {"bye": True}
        elif name == "doctor":
            result = {"ok": True, "socket": "mock"}
        return {"t": "reply", "v": PROTOCOL_VERSION, "id": cid, "ok": True, "result": result}


class Client:
    def __init__(self, world: World, conn: socket.socket, once: bool, stop: threading.Event) -> None:
        self.world = world
        self.conn = conn
        self.once = once
        self.stop = stop
        self.write_lock = threading.Lock()
        self.alive = True

    def send(self, document: dict) -> None:
        if not self.alive:
            return
        line = json.dumps(document, separators=(",", ":")) + "\n"
        with self.write_lock:
            try:
                self.conn.sendall(line.encode("utf-8"))
            except OSError:
                self.alive = False

    def serve(self) -> None:
        world = self.world
        with world.lock:
            world.clients.append(self)
            documents = [world.hello(), world.state(), world.lights(), world.settings()]
        for document in documents:
            self.send(document)
        log("client connected; sent hello/state/lights/settings")
        if self.once:
            with world.lock:
                if self in world.clients:
                    world.clients.remove(self)
            try:
                self.conn.shutdown(socket.SHUT_WR)
                self.conn.settimeout(0.5)
                try:
                    self.conn.recv(1)
                except OSError:
                    pass
            finally:
                self.conn.close()
            self.alive = False
            self.stop.set()
            return
        buffer = b""
        try:
            while self.alive and not self.stop.is_set():
                chunk = self.conn.recv(65536)
                if not chunk:
                    break
                buffer += chunk
                while b"\n" in buffer:
                    line, buffer = buffer.split(b"\n", 1)
                    if not line.strip():
                        continue
                    try:
                        command = json.loads(line)
                    except json.JSONDecodeError as exc:
                        log(f"bad frame: {exc}")
                        continue
                    log(f"command {command.get('name')} {json.dumps(command.get('args') or {})} (id {command.get('id')})")
                    if command.get("t") != "command":
                        continue
                    self.send(world.handle_command(command))
        except OSError:
            pass
        finally:
            self.alive = False
            with world.lock:
                if self in world.clients:
                    world.clients.remove(self)
            try:
                self.conn.close()
            except OSError:
                pass
            log("client disconnected")


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--socket", default=str(DEFAULT_SOCKET), help="socket path (default: the real one)")
    parser.add_argument("--step", type=float, default=2.0, help="seconds between timeline steps")
    parser.add_argument("--once", action="store_true", help="send hello/state/lights/settings to the first client, then exit")
    parser.add_argument("--no-loop", action="store_true", help="play the timeline once instead of looping")
    parser.add_argument("--start-at", type=int, default=0, metavar="N",
                        help="begin the timeline at step N (0 claude working, 1 codex ask, 2 ask resolved, "
                             "3 codex completed, 4 pro disconnected, 5 pro reconnected, 6 claude completed, 7 idle)")
    parser.add_argument("--mode", default="0600", help="socket file mode (octal)")
    args = parser.parse_args()

    path = Path(args.socket).expanduser()
    path.parent.mkdir(parents=True, exist_ok=True)
    if path.exists():
        probe = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
        try:
            probe.connect(str(path))
        except OSError:
            path.unlink()
        else:
            probe.close()
            log(f"another daemon is listening on {path}; refusing to replace it")
            return 2
        finally:
            probe.close()

    stop = threading.Event()
    world = World(step_seconds=args.step, loop=not args.no_loop)

    server = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
    server.bind(str(path))
    os.chmod(path, int(args.mode, 8))
    server.listen(8)
    server.settimeout(0.25)
    log(f"listening on {path}{' (once)' if args.once else ''}; step {args.step}s")

    def shutdown(*_):
        stop.set()

    signal.signal(signal.SIGINT, shutdown)
    signal.signal(signal.SIGTERM, shutdown)

    timeline = None
    if not args.once:
        timeline = threading.Thread(target=world.run_timeline, args=(stop, args.start_at), name="timeline", daemon=True)
        timeline.start()

    try:
        while not stop.is_set():
            try:
                conn, _ = server.accept()
            except socket.timeout:
                continue
            except OSError:
                break
            client = Client(world, conn, args.once, stop)
            threading.Thread(target=client.serve, name="client", daemon=True).start()
    finally:
        stop.set()
        server.close()
        try:
            path.unlink()
        except OSError:
            pass
        log("stopped")
    return 0


if __name__ == "__main__":
    sys.exit(main())
