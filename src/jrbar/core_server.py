"""The core daemon's socket: protocol 1 over a Unix socket (docs/CORE-PROTOCOL.md).

One accept thread, one reader thread per client, one flusher thread that
coalesces the ``state`` / ``lights`` / ``settings`` documents (latest wins,
bounded rate) and fans every frame out to every connected client.

The server knows nothing about AppKit or the controller. Commands arrive on
a client's reader thread and are handed to ``dispatch(name, args)``; the
runtime wraps that callable so it runs on the main thread. Publishing is
thread-safe and never blocks the caller on socket I/O.
"""

from __future__ import annotations

import json
import os
import socket
import stat
import threading
import time
from collections.abc import Callable, Iterable
from pathlib import Path
from typing import Any, Final

from .ipc import _same_uid_peer
from .state_paths import default_state_dir

PROTOCOL_VERSION: Final = 1
CORE_SOCKET_NAME: Final = "core.sock"
MAX_FRAME_BYTES: Final = 1024 * 1024
MAX_CLIENTS: Final = 4
STATE_MIN_INTERVAL_SECONDS: Final = 1.0 / 20.0
LIGHTS_MIN_INTERVAL_SECONDS: Final = 1.0 / 30.0
SETTINGS_MIN_INTERVAL_SECONDS: Final = 1.0 / 10.0
ACCEPT_TIMEOUT_SECONDS: Final = 0.25
DEFAULT_CAPABILITIES: Final = (
    "sessions",
    "lights",
    "usage",
    "devices",
    "power",
    "effects",
    "calibration",
    "history",
    "peers",
    "ingest",
    "deck",
)
_COALESCED_KINDS: Final = ("state", "lights", "settings")


class CommandError(Exception):
    """A command the daemon refuses; ``code`` goes on the wire as-is."""

    def __init__(self, code: str, message: str | None = None) -> None:
        super().__init__(message or code)
        self.code = code
        self.message = message


def default_core_socket_path() -> Path:
    return default_state_dir() / CORE_SOCKET_NAME


def encode_frame(document: dict[str, Any]) -> bytes:
    """One NDJSON line. ``t`` and ``v`` must be present; the result never
    contains a raw newline because ``ensure_ascii`` escapes them."""
    return (json.dumps(document, separators=(",", ":"), ensure_ascii=True) + "\n").encode("ascii")


def _envelope(kind: str, document: dict[str, Any]) -> dict[str, Any]:
    body = {"t": kind, "v": PROTOCOL_VERSION}
    body.update({key: value for key, value in document.items() if key not in ("t", "v")})
    return body


class _Client:
    def __init__(self, connection: socket.socket, index: int) -> None:
        self.connection = connection
        self.index = index
        self.write_lock = threading.Lock()
        self.alive = True

    def send(self, frame: bytes) -> bool:
        if not self.alive:
            return False
        with self.write_lock:
            try:
                self.connection.sendall(frame)
                return True
            except OSError:
                self.alive = False
                return False

    def close(self) -> None:
        self.alive = False
        try:
            self.connection.shutdown(socket.SHUT_RDWR)
        except OSError:
            pass
        try:
            self.connection.close()
        except OSError:
            pass


class CoreServer:
    """Serve protocol 1 to up to ``max_clients`` same-UID peers."""

    def __init__(
        self,
        *,
        dispatch: Callable[[str, dict[str, Any]], Any],
        initial_documents: Callable[[], Iterable[dict[str, Any]]],
        socket_path: Path | None = None,
        core_version: str = "0.8.0",
        capabilities: Iterable[str] = DEFAULT_CAPABILITIES,
        max_clients: int = MAX_CLIENTS,
        peer_uid_reader: Callable[[socket.socket], int] | None = None,
        on_client_change: Callable[[int], None] | None = None,
        log: Callable[[str], None] | None = None,
        clock: Callable[[], float] = time.monotonic,
    ) -> None:
        if not callable(dispatch) or not callable(initial_documents):
            raise ValueError("invalid core server dependency")
        if type(max_clients) is not int or max_clients <= 0:
            raise ValueError("invalid core server client bound")
        self.socket_path = Path(socket_path or default_core_socket_path()).expanduser()
        self._dispatch = dispatch
        self._initial_documents = initial_documents
        self._core_version = core_version
        self._capabilities = tuple(capabilities)
        self._max_clients = max_clients
        self._peer_uid_reader = peer_uid_reader
        self._on_client_change = on_client_change
        self._log = log or (lambda _line: None)
        self._clock = clock

        self._lock = threading.RLock()
        self._clients: list[_Client] = []
        self._client_counter = 0
        self._server: socket.socket | None = None
        self._accept_thread: threading.Thread | None = None
        self._running = False
        self._own_inode: int | None = None

        self._flush_condition = threading.Condition()
        self._pending: dict[str, dict[str, Any]] = {}
        self._queue: list[bytes] = []
        self._last_sent: dict[str, float] = {}
        # The last frame actually fanned out per coalesced kind; identical
        # documents are never put on the wire twice. A state poke that
        # changes nothing visible costs one encode, not a full
        # broadcast-and-redecode round on every client.
        self._last_frame: dict[str, bytes] = {}
        self._min_interval = {
            "state": STATE_MIN_INTERVAL_SECONDS,
            "lights": LIGHTS_MIN_INTERVAL_SECONDS,
            "settings": SETTINGS_MIN_INTERVAL_SECONDS,
        }
        self._flusher: threading.Thread | None = None
        self._event_counter = 0
        self.stats = {"frames_out": 0, "commands": 0, "dropped_oversize": 0,
                      "refused_clients": 0, "deduped_frames": 0}

    # -- lifecycle ----------------------------------------------------------

    def start(self) -> Path:
        with self._lock:
            if self._running:
                raise OSError("core server is already running")
            path = self.socket_path
            path.parent.mkdir(parents=True, exist_ok=True, mode=0o700)
            try:
                os.chmod(path.parent, 0o700)
            except OSError:
                pass
            self._unlink_stale(path)
            server = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
            previous_umask = os.umask(0o177)
            try:
                server.bind(str(path))
            finally:
                os.umask(previous_umask)
            os.chmod(path, 0o600)
            server.listen(8)
            server.settimeout(ACCEPT_TIMEOUT_SECONDS)
            self._own_inode = os.stat(path).st_ino
            self._server = server
            self._running = True
            self._accept_thread = threading.Thread(
                target=self._accept_loop, name="JRBarCoreAccept", daemon=True
            )
            self._flusher = threading.Thread(
                target=self._flush_loop, name="JRBarCoreFlush", daemon=True
            )
            self._accept_thread.start()
            self._flusher.start()
            self._log(f"core listening on {path}")
            return path

    def stop(self, *, timeout_seconds: float = 2.0) -> None:
        with self._lock:
            if not self._running:
                return
            self._running = False
            server = self._server
            self._server = None
            clients = list(self._clients)
            self._clients = []
        with self._flush_condition:
            self._flush_condition.notify_all()
        if server is not None:
            try:
                server.close()
            except OSError:
                pass
        for client in clients:
            client.close()
        for thread in (self._accept_thread, self._flusher):
            if thread is not None and thread is not threading.current_thread():
                thread.join(timeout_seconds)
        try:
            if self._own_inode is not None and os.stat(self.socket_path).st_ino == self._own_inode:
                self.socket_path.unlink()
        except OSError:
            pass
        self._own_inode = None
        self._notify_client_change()

    @property
    def running(self) -> bool:
        return self._running

    @property
    def client_count(self) -> int:
        with self._lock:
            return sum(1 for client in self._clients if client.alive)

    @staticmethod
    def _unlink_stale(path: Path) -> None:
        try:
            info = path.lstat()
        except FileNotFoundError:
            return
        if not stat.S_ISSOCK(info.st_mode):
            raise OSError(f"refusing to replace a non-socket at {path}")
        probe = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
        try:
            probe.settimeout(0.5)
            probe.connect(str(path))
        except OSError:
            path.unlink()
            return
        finally:
            probe.close()
        raise OSError(f"another core is listening on {path}")

    # -- publishing ---------------------------------------------------------

    def hello_document(self) -> dict[str, Any]:
        return {
            "t": "hello",
            "v": PROTOCOL_VERSION,
            "core_version": self._core_version,
            "pid": os.getpid(),
            "capabilities": list(self._capabilities),
        }

    def publish_state(self, document: dict[str, Any]) -> None:
        self._publish_coalesced("state", document)

    def publish_lights(self, document: dict[str, Any]) -> None:
        self._publish_coalesced("lights", document)

    def publish_settings(self, document: dict[str, Any]) -> None:
        self._publish_coalesced("settings", document)

    def publish_event(self, document: dict[str, Any]) -> dict[str, Any]:
        with self._flush_condition:
            self._event_counter += 1
            body = _envelope("event", document)
            body.setdefault("id", f"ev-{self._event_counter}")
            body.setdefault("at", time.time())
            self._enqueue_locked(body)
            self._flush_condition.notify_all()
        return body

    def publish_log(self, line: str, *, level: str = "info") -> None:
        body = {"t": "log", "v": PROTOCOL_VERSION, "level": level, "message": str(line)[:2000], "at": time.time()}
        with self._flush_condition:
            self._enqueue_locked(body)
            self._flush_condition.notify_all()

    def _publish_coalesced(self, kind: str, document: dict[str, Any]) -> None:
        with self._flush_condition:
            self._pending[kind] = _envelope(kind, document)
            self._flush_condition.notify_all()

    def _enqueue_locked(self, body: dict[str, Any]) -> None:
        try:
            frame = encode_frame(body)
        except (TypeError, ValueError) as exc:
            self._log(f"core frame not serialisable: {exc}")
            return
        if len(frame) > MAX_FRAME_BYTES:
            self.stats["dropped_oversize"] += 1
            self._log(f"core dropped oversize {body.get('t')} frame ({len(frame)} bytes)")
            return
        self._queue.append(frame)

    def _flush_loop(self) -> None:
        while True:
            with self._flush_condition:
                while self._running:
                    ready = self._ready_kinds_locked()
                    if self._queue or ready:
                        break
                    self._flush_condition.wait(self._next_wait_locked())
                if not self._running:
                    return
                frames = list(self._queue)
                self._queue.clear()
                for kind in ready:
                    body = self._pending.pop(kind)
                    self._last_sent[kind] = self._clock()
                    try:
                        frame = encode_frame(body)
                    except (TypeError, ValueError) as exc:
                        self._log(f"core {kind} not serialisable: {exc}")
                        continue
                    if len(frame) > MAX_FRAME_BYTES:
                        self.stats["dropped_oversize"] += 1
                        self._log(f"core dropped oversize {kind} frame ({len(frame)} bytes)")
                        continue
                    if frame == self._last_frame.get(kind):
                        self.stats["deduped_frames"] += 1
                        continue
                    self._last_frame[kind] = frame
                    frames.append(frame)
            for frame in frames:
                self._fan_out(frame)

    def _ready_kinds_locked(self) -> list[str]:
        now = self._clock()
        return [
            kind
            for kind in _COALESCED_KINDS
            if kind in self._pending
            and now - self._last_sent.get(kind, -1e9) >= self._min_interval[kind]
        ]

    def _next_wait_locked(self) -> float | None:
        now = self._clock()
        waits = [
            self._last_sent.get(kind, -1e9) + self._min_interval[kind] - now
            for kind in _COALESCED_KINDS
            if kind in self._pending
        ]
        if not waits:
            return None
        return max(0.001, min(waits))

    def _fan_out(self, frame: bytes) -> None:
        with self._lock:
            clients = list(self._clients)
        self.stats["frames_out"] += 1
        dead = [client for client in clients if not client.send(frame)]
        if dead:
            self._drop_clients(dead)

    # -- clients ------------------------------------------------------------

    def _accept_loop(self) -> None:
        while True:
            with self._lock:
                server = self._server
                if not self._running or server is None:
                    return
            try:
                connection, _ = server.accept()
            except TimeoutError:
                continue
            except OSError:
                return
            if not _same_uid_peer(connection, self._peer_uid_reader):
                self.stats["refused_clients"] += 1
                self._log("core refused a foreign-uid peer")
                connection.close()
                continue
            with self._lock:
                if not self._running:
                    connection.close()
                    return
                if sum(1 for client in self._clients if client.alive) >= self._max_clients:
                    self.stats["refused_clients"] += 1
                    self._log("core refused a client: too many connections")
                    connection.close()
                    continue
                self._client_counter += 1
                client = _Client(connection, self._client_counter)
                self._clients.append(client)
            threading.Thread(
                target=self._serve_client,
                args=(client,),
                name=f"JRBarCoreClient{client.index}",
                daemon=True,
            ).start()
            self._notify_client_change()

    def _serve_client(self, client: _Client) -> None:
        try:
            client.send(encode_frame(self.hello_document()))
            for document in self._initial_documents():
                if not client.alive:
                    break
                kind = document.get("t")
                if not isinstance(kind, str):
                    continue
                frame = encode_frame(_envelope(kind, document))
                if len(frame) > MAX_FRAME_BYTES:
                    self._log(f"core skipped oversize initial {document.get('t')} frame")
                    continue
                client.send(frame)
            self._read_commands(client)
        except Exception as exc:  # pragma: no cover - defensive
            self._log(f"core client {client.index} failed: {exc}")
        finally:
            self._drop_clients([client])

    def _read_commands(self, client: _Client) -> None:
        buffer = bytearray()
        connection = client.connection
        while client.alive and self._running:
            try:
                chunk = connection.recv(65536)
            except OSError:
                return
            if not chunk:
                return
            buffer.extend(chunk)
            while True:
                newline = buffer.find(b"\n")
                if newline < 0:
                    if len(buffer) > MAX_FRAME_BYTES:
                        self._log(f"core client {client.index} sent an oversize frame; closing")
                        return
                    break
                line = bytes(buffer[:newline])
                del buffer[: newline + 1]
                if len(line) > MAX_FRAME_BYTES:
                    self._log(f"core client {client.index} sent an oversize frame; closing")
                    return
                if not line.strip():
                    continue
                self._handle_line(client, line)

    def _handle_line(self, client: _Client, line: bytes) -> None:
        try:
            message = json.loads(line.decode("utf-8"))
        except (UnicodeDecodeError, ValueError):
            client.send(encode_frame(self._reply(None, ok=False, code="bad_frame", message="not JSON")))
            return
        if not isinstance(message, dict):
            client.send(encode_frame(self._reply(None, ok=False, code="bad_frame", message="not an object")))
            return
        if message.get("t") != "command":
            return
        command_id = message.get("id")
        if not isinstance(command_id, str):
            command_id = str(command_id) if command_id is not None else None
        name = message.get("name")
        args = message.get("args")
        if not isinstance(args, dict):
            args = {}
        if not isinstance(name, str) or not name:
            client.send(encode_frame(self._reply(command_id, ok=False, code="bad_command", message="missing name")))
            return
        self.stats["commands"] += 1
        reply = self.run_command(command_id, name, args)
        client.send(encode_frame(reply))

    def run_command(self, command_id: str | None, name: str, args: dict[str, Any]) -> dict[str, Any]:
        try:
            result = self._dispatch(name, args)
        except CommandError as exc:
            return self._reply(command_id, ok=False, code=exc.code, message=exc.message)
        except Exception as exc:
            self._log(f"core command {name} failed: {exc.__class__.__name__}: {exc}")
            return self._reply(command_id, ok=False, code="internal", message=str(exc)[:500])
        if result is None:
            result = {}
        reply = self._reply(command_id, ok=True)
        reply["result"] = result
        try:
            encode_frame(reply)
        except (TypeError, ValueError):
            reply["result"] = {"repr": repr(result)[:2000]}
        return reply

    @staticmethod
    def _reply(
        command_id: str | None,
        *,
        ok: bool,
        code: str | None = None,
        message: str | None = None,
    ) -> dict[str, Any]:
        reply: dict[str, Any] = {"t": "reply", "v": PROTOCOL_VERSION, "id": command_id, "ok": ok}
        if not ok:
            error: dict[str, Any] = {"code": code or "error"}
            if message:
                error["message"] = message
            reply["error"] = error
        return reply

    def _drop_clients(self, dead: list[_Client]) -> None:
        changed = False
        with self._lock:
            for client in dead:
                if client in self._clients:
                    self._clients.remove(client)
                    changed = True
                client.close()
        if changed:
            self._notify_client_change()

    def _notify_client_change(self) -> None:
        if self._on_client_change is None:
            return
        try:
            self._on_client_change(self.client_count)
        except Exception:
            pass


class CommandRouter:
    """``name -> handler(args)``; unknown names raise ``unknown_command``."""

    def __init__(self) -> None:
        self._handlers: dict[str, Callable[[dict[str, Any]], Any]] = {}

    def register(self, name: str, handler: Callable[[dict[str, Any]], Any]) -> None:
        self._handlers[name] = handler

    def names(self) -> tuple[str, ...]:
        return tuple(sorted(self._handlers))

    def __call__(self, name: str, args: dict[str, Any]) -> Any:
        handler = self._handlers.get(name)
        if handler is None:
            raise CommandError("unknown_command", f"no such command: {name}")
        return handler(args)


__all__ = [
    "CORE_SOCKET_NAME",
    "DEFAULT_CAPABILITIES",
    "MAX_CLIENTS",
    "MAX_FRAME_BYTES",
    "PROTOCOL_VERSION",
    "STATE_MIN_INTERVAL_SECONDS",
    "CommandError",
    "CommandRouter",
    "CoreServer",
    "default_core_socket_path",
    "encode_frame",
]
