"""Bounded JSON-RPC stdio transport: the shared spine for managed sessions.

W21's contract: a Codex ``app-server``, a Claude SDK process, a Gemini or
Grok ACP bridge — all speak newline-delimited JSON-RPC over stdio. This
transport owns the mechanics every adapter needs and nothing else:

* request ids come from one counter, never recycled while in flight;
* a line over ``MAX_LINE_BYTES`` or a frame that is not an object is a
  protocol violation, not a crash — it is counted and skipped;
* responses match by id; notifications route to a callback the adapter
  supplies; a notification for an unknown method is logged, not fatal;
* ``request()`` honours a per-call deadline — a wedged peer times out
  instead of pinning the caller;
* ``close()`` is idempotent and fails every in-flight request so no
  waiter hangs on a dead pipe.

Provider quirks — method names, capability negotiation, auth — live in
the adapter, not here. This file speaks framing only.
"""

from __future__ import annotations

import json
import queue
import subprocess
import threading
import time
from collections.abc import Callable, Mapping
from typing import Any

# A single JSON-RPC line beyond this is a peer bug or a flood; either way
# it is dropped and counted, never buffered to memory.
MAX_LINE_BYTES = 1 << 20  # 1 MiB
# stderr is diagnostics: kept, but bounded so a chatty peer cannot grow
# the buffer without bound.
MAX_STDERR_CHARS = 16_384


class TransportClosed(RuntimeError):
    """The pipe is gone — close() was called or the peer exited."""


class TransportTimeout(TimeoutError):
    """The peer did not answer within the request's deadline."""


class TransportProtocolError(RuntimeError):
    """The peer sent a frame this transport cannot place."""


class JsonRpcTransport:
    """One stdio JSON-RPC session. ``popen`` is injectable so tests run a
    fake peer; production passes ``subprocess.Popen`` results."""

    def __init__(
        self,
        process: subprocess.Popen[str],
        *,
        on_notification: Callable[[str, Any], None] | None = None,
        on_stderr: Callable[[str], None] | None = None,
    ) -> None:
        self._process = process
        self._on_notification = on_notification
        self._on_stderr = on_stderr
        self._next_id = 0
        self._pending: dict[int, queue.Queue[dict[str, Any]]] = {}
        self._lock = threading.Lock()
        self._closed = False
        self._close_reason: str | None = None
        self.protocol_violations = 0
        self.stderr_tail = ""
        self._reader = threading.Thread(
            target=self._read_loop, name="JRBarJsonRpcRead", daemon=True)
        self._stderr_reader = threading.Thread(
            target=self._read_stderr, name="JRBarJsonRpcStderr", daemon=True)
        self._reader.start()
        self._stderr_reader.start()

    # -- reading ----------------------------------------------------------

    def _read_stderr(self) -> None:
        stderr = self._process.stderr
        if stderr is None:
            return
        try:
            for line in stderr:
                self.stderr_tail = (self.stderr_tail + line)[-MAX_STDERR_CHARS:]
                if self._on_stderr is not None:
                    self._on_stderr(line.rstrip("\n"))
        except (OSError, ValueError):
            pass

    def _read_loop(self) -> None:
        stdout = self._process.stdout
        reason = "peer closed stdout"
        try:
            if stdout is not None:
                while True:
                    line = stdout.readline()
                    if line == "":
                        break
                    if len(line.encode("utf-8", "replace")) > MAX_LINE_BYTES:
                        self.protocol_violations += 1
                        continue
                    self._dispatch_line(line)
        except (OSError, ValueError):
            reason = "stdout read failed"
        finally:
            self._fail_all(reason)

    def _dispatch_line(self, line: str) -> None:
        stripped = line.strip()
        if not stripped:
            return
        try:
            frame = json.loads(stripped)
        except ValueError:
            self.protocol_violations += 1
            return
        if not isinstance(frame, dict):
            self.protocol_violations += 1
            return
        if "id" in frame and ("result" in frame or "error" in frame):
            self._resolve_response(frame)
            return
        # A request *from* the peer (id + method, e.g. ACP permission
        # callbacks) or a notification: both go to the adapter's handler.
        if "method" in frame:
            method = frame.get("method")
            if isinstance(method, str) and self._on_notification is not None:
                self._on_notification(method, frame.get("params"))
            return
        self.protocol_violations += 1

    def _resolve_response(self, frame: dict[str, Any]) -> None:
        request_id = frame.get("id")
        if not isinstance(request_id, int):
            self.protocol_violations += 1
            return
        with self._lock:
            waiter = self._pending.pop(request_id, None)
        if waiter is None:
            # A response for an id we never sent (or already timed out) is
            # a protocol fact worth counting, not an error to raise.
            self.protocol_violations += 1
            return
        waiter.put(frame)

    def _fail_all(self, reason: str) -> None:
        with self._lock:
            if self._closed:
                return
            self._closed = True
            self._close_reason = reason
            pending = list(self._pending.values())
            self._pending.clear()
        for waiter in pending:
            waiter.put({"__closed__": reason})

    # -- sending ----------------------------------------------------------

    def request(self, method: str, params: Mapping[str, Any] | None = None,
                *, timeout: float = 30.0) -> Any:
        """Send a request, return ``result``; raise on error/timeout/close."""
        with self._lock:
            if self._closed:
                raise TransportClosed(self._close_reason or "transport closed")
            self._next_id += 1
            request_id = self._next_id
            waiter: queue.Queue[dict[str, Any]] = queue.Queue(maxsize=1)
            self._pending[request_id] = waiter
        frame: dict[str, Any] = {"jsonrpc": "2.0", "id": request_id, "method": method}
        if params is not None:
            frame["params"] = dict(params)
        self._write(frame)
        deadline = time.monotonic() + max(0.05, timeout)
        try:
            response = waiter.get(timeout=max(0.01, deadline - time.monotonic()))
        except queue.Empty:
            with self._lock:
                self._pending.pop(request_id, None)
            raise TransportTimeout(f"{method} did not answer in {timeout}s") from None
        if "__closed__" in response:
            raise TransportClosed(response["__closed__"])
        if "error" in response:
            error = response["error"]
            message = error.get("message") if isinstance(error, dict) else str(error)
            raise TransportProtocolError(f"{method}: {message}")
        return response.get("result")

    def notify(self, method: str, params: Mapping[str, Any] | None = None) -> None:
        """Fire-and-forget: a notification has no id and no reply."""
        frame: dict[str, Any] = {"jsonrpc": "2.0", "method": method}
        if params is not None:
            frame["params"] = dict(params)
        self._write(frame)

    def respond(self, request_id: int, result: Any) -> None:
        """Answer a peer's request (e.g. an ACP permission callback)."""
        self._write({"jsonrpc": "2.0", "id": request_id, "result": result})

    def _write(self, frame: dict[str, Any]) -> None:
        stdin = self._process.stdin
        if stdin is None:
            raise TransportClosed("peer has no stdin")
        try:
            stdin.write(json.dumps(frame, separators=(",", ":")) + "\n")
            stdin.flush()
        except (OSError, ValueError) as error:
            raise TransportClosed(f"stdin write failed: {error}") from error

    @property
    def closed(self) -> bool:
        return self._closed

    def close(self) -> None:
        """Idempotent: kill the reader's blockers, fail the waiters."""
        self._fail_all("closed locally")
        try:
            if self._process.stdin is not None:
                self._process.stdin.close()
        except OSError:
            pass
