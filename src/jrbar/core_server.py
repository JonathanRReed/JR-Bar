"""The core daemon's socket: protocol 1 over a Unix socket (docs/CORE-PROTOCOL.md).

One accept thread, one reader thread per client, one flusher thread that
coalesces the ``state`` / ``lights`` / ``settings`` documents (latest wins,
bounded rate) and fans every frame out to every connected client, and three
slow-lane workers for the heavy reads and the one click that can wait on a
provider: one for the minutes-long usage scans, one for the short reads a
person waits on, one for Fix sign-in.

The server knows nothing about AppKit or the controller. Commands arrive on
a client's reader thread and are handed to ``dispatch(name, args)``; the
runtime wraps that callable so it runs on the main thread. A slow-lane
command (``SLOW_LANE_COMMANDS``) is queued for a worker instead and
answered by id when it is done, so a transcript scan never holds up the
Approve the same client sends after it, and a usage scan never holds up
History. Publishing is thread-safe and never blocks the caller on socket
I/O.
"""

from __future__ import annotations

import json
import math
import os
import socket
import stat
import struct
import threading
import time
from collections import deque
from collections.abc import Callable, Iterable
from pathlib import Path
from typing import Any, Final

from . import __version__
from .ipc import _accept_one, _AcceptWakeup, _same_uid_peer
from .state_paths import default_state_dir

PROTOCOL_VERSION: Final = 1
CORE_SOCKET_NAME: Final = "core.sock"
MAX_FRAME_BYTES: Final = 1024 * 1024
MAX_CLIENTS: Final = 4
STATE_MIN_INTERVAL_SECONDS: Final = 1.0 / 20.0
LIGHTS_MIN_INTERVAL_SECONDS: Final = 1.0 / 30.0
SETTINGS_MIN_INTERVAL_SECONDS: Final = 1.0 / 10.0
# SO_SNDTIMEO on every accepted client: the flusher fans frames out
# serially, so one peer that stops reading must not wedge publishing for
# the rest. A send that blocks longer than this drops the client at once:
# a timed-out sendall may have written part of a frame, so the stream is
# already suspect. The app reconnects with backoff and replays the events
# it missed (``replay_events``).
CLIENT_SEND_TIMEOUT_SECONDS: Final = 1.0
# The kernel's default send buffer for a Unix socket is 8 KB on macOS, so a
# 30-60 KB state frame stalls the moment the peer is a little slow. A
# larger buffer on the daemon's side lets a reader that pauses for a moment
# catch up without being dropped. Best effort: a failure to set it is not
# a reason to refuse the client.
CLIENT_SEND_BUFFER_BYTES: Final = 256 * 1024
# Bound on queued event/log frames waiting for the flusher. Coalesced
# kinds (state/lights/settings) live in `_pending` latest-wins and are
# already bounded; this cap keeps an absent flusher or a burst of logs
# from growing memory without limit. Overflow drops the OLDEST frames.
MAX_QUEUED_FRAMES: Final = 128
# The resumable-event journal: every published event is journaled under
# the flush lock with a stream-scoped cursor, so a client that missed
# frames (a dropped slow consumer, a reconnect) can ask for the exact
# suffix instead of a full resubscribe. Larger than the send queue on
# purpose: the queue sheds under backpressure, the journal is where the
# shed frames stay replayable. In-memory by design — replay survives
# socket churn, not a daemon restart (a new stream id makes that honest).
MAX_JOURNAL_EVENTS: Final = 512
STALE_SOCKET_PROBE_TIMEOUT_SECONDS: Final = 0.5
_SEND_TIMEOUT_TIMEVAL: Final = struct.pack(
    "ll",
    int(CLIENT_SEND_TIMEOUT_SECONDS),
    int((CLIENT_SEND_TIMEOUT_SECONDS % 1.0) * 1_000_000),
)
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
    "roster",
    "event_replay",
)
_COALESCED_KINDS: Final = ("state", "lights", "settings")
# Reads that scan transcripts or run diagnostics, all ``main_thread=False``
# in the runtime. A usage_graph took 107 s and then 195 s on 2026-09-23, and
# every command the app sent behind it on its one connection -- an Approve,
# a ping -- waited just as long. They run on workers shared by every client
# and out of order with everything else. There are two lanes, so the scans
# do not make a short read wait either.
#
# The SCAN lane holds the usage scans. Its one worker keeps them in order
# among themselves: two scans never overlap and fight for the GIL, and the
# one the person is watching on Overview is not slowed by a second parse of
# the same files.
SCAN_LANE_COMMANDS: Final = frozenset({"usage_graph", "usage_history"})
# The READ lane holds the short reads: a History open, one session's
# timeline, a comparison, a doctor run. It has its own worker, so opening
# History while the Overview's graph is being built answers at once.
#
# ``mark_history_seen`` is not a read, but History sends it right behind a
# ``list_history`` whose ``unseen`` flags measure from the watermark it
# moves. Inline it would overtake the queued read and every row would come
# back seen; on this lane it waits its turn. It is ``main_thread=True``, so
# the dispatch still hops it to the main thread from the worker.
READ_LANE_COMMANDS: Final = frozenset(
    {
        "session_timeline",
        "list_history",
        "mark_history_seen",
        "compare_sessions",
        "session_usage",
        "doctor",
    }
)
# The ACTION lane holds a click that can wait on a provider's own tool: Fix
# sign-in asks Claude Code to renew its sign-in with a real call the daemon
# allows 90 s. It is not a read, so it has a worker of its own: it must not
# make History, a doctor run or a comparison wait, nor wait behind a scan.
ACTION_LANE_COMMANDS: Final = frozenset({"provider_sign_in"})
SLOW_LANE_COMMANDS: Final = SCAN_LANE_COMMANDS | READ_LANE_COMMANDS | ACTION_LANE_COMMANDS
_SCAN_LANE: Final = "scan"
_READ_LANE: Final = "read"
_ACTION_LANE: Final = "action"
_LANE_THREAD_NAMES: Final = {
    _SCAN_LANE: "JRBarCoreScanLane",
    _READ_LANE: "JRBarCoreReadLane",
    _ACTION_LANE: "JRBarCoreActionLane",
}
# Stamped into a slow-lane command's args when it is queued (epoch
# seconds), so a command that records "now" -- mark_history_seen's
# watermark -- can record when it was sent, not when a scan ahead of it
# finished.
SLOW_LANE_RECEIVED_AT: Final = "_received_at"
# Slow-lane commands waiting for a lane's worker, across every client. The
# app keeps a few in flight; past this a new one is refused ``busy`` at once
# rather than answered minutes late. Each lane has its own bound, so a
# backlog of scans never makes a short read busy.
MAX_SLOW_LANE_QUEUED: Final = 32


class CommandError(Exception):
    """A command the daemon refuses; ``code`` goes on the wire as-is."""

    def __init__(self, code: str, message: str | None = None) -> None:
        super().__init__(message or code)
        self.code = code
        self.message = message


def default_core_socket_path() -> Path:
    return default_state_dir() / CORE_SOCKET_NAME


def _without_non_finite(value: Any, replaced: list[int]) -> Any:
    """A copy of ``value`` with every NaN and infinity replaced by ``None``.

    ``replaced[0]`` counts them. Only containers JSON writes (dicts, lists,
    tuples) are rebuilt; everything else is returned as it came, so a value
    ``json`` cannot write still fails loudly in the encoder.
    """
    if isinstance(value, float):
        if math.isfinite(value):
            return value
        replaced[0] += 1
        return None
    if isinstance(value, dict):
        return {key: _without_non_finite(item, replaced) for key, item in value.items()}
    if isinstance(value, (list, tuple)):
        return [_without_non_finite(item, replaced) for item in value]
    return value


def _dump(document: Any) -> bytes:
    text = json.dumps(document, separators=(",", ":"), ensure_ascii=True, allow_nan=False)
    return (text + "\n").encode("ascii")


def encode_frame_counting(document: dict[str, Any]) -> tuple[bytes, int]:
    """``encode_frame`` and how many non-finite numbers it had to replace.

    A document nobody built a NaN into costs one ``json.dumps`` and nothing
    more; only a document that holds one is walked and rewritten.
    """
    try:
        return _dump(document), 0
    except ValueError:
        # Either a NaN or infinity somewhere in the document (the encoder
        # refuses them) or something worse, which the second pass raises
        # again for the caller to count as a drop.
        replaced = [0]
        try:
            clean = _without_non_finite(document, replaced)
        except RecursionError as error:
            # A document that holds itself: json refused it above as a
            # circular reference, and walking it would never end.
            raise ValueError("the document is circular or nested too deeply") from error
        return _dump(clean), replaced[0]


def encode_frame(document: dict[str, Any]) -> bytes:
    """One NDJSON line. ``t`` and ``v`` must be present; the result never
    contains a raw newline because ``ensure_ascii`` escapes them.

    A number that is not finite (NaN, +inf, -inf) goes out as ``null``: a bare
    ``NaN`` or ``Infinity`` token is not JSON, and the app drops the whole
    frame that holds one. ``null`` reads as "no reading" everywhere the
    protocol already says so (``used_pct: null``). Raises ``TypeError`` or
    ``ValueError`` for a document that cannot be written at all, which the
    server turns into a counted drop (``CoreServer._encode``).
    """
    return encode_frame_counting(document)[0]


def _envelope(kind: str, document: dict[str, Any]) -> dict[str, Any]:
    body = {"t": kind, "v": PROTOCOL_VERSION}
    body.update({key: value for key, value in document.items() if key not in ("t", "v")})
    return body


class _Client:
    def __init__(
        self,
        connection: socket.socket,
        index: int,
        log: Callable[[str], None] | None = None,
    ) -> None:
        self.connection = connection
        self.index = index
        self.write_lock = threading.Lock()
        self.alive = True
        self._log = log or (lambda _line: None)
        # A client is registered for live frames before its greeting is sent,
        # so no event falls between the journal tail in ``hello`` and the
        # live stream. Until the greeting is done the flusher holds live
        # frames here (``deliver``), and ``finish_priming`` sends them after
        # it, in order. ``None`` means the client is primed.
        self._gate = threading.Lock()
        self._held: list[bytes] | None = []

    def deliver(self, frame: bytes) -> bool:
        """The flusher's send. Never blocks on a client that is still being
        greeted: its frames wait behind the greeting instead."""
        if not self.alive:
            return False
        with self._gate:
            if self._held is not None:
                if len(self._held) >= MAX_QUEUED_FRAMES:
                    # A greeting that stalls this long is not coming back;
                    # dropping it loses nothing the reconnect cannot replay,
                    # and buffering without bound would.
                    self.alive = False
                    return False
                self._held.append(frame)
                return True
        return self.send(frame)

    def finish_priming(self) -> None:
        """Send what was held during the greeting, in order, then go live.

        ``_held`` only becomes ``None`` under the gate after a drain finds
        nothing new, so no live frame can overtake a held one.
        """
        while True:
            with self._gate:
                batch = self._held
                if not batch:
                    self._held = None
                    return
                self._held = []
            for frame in batch:
                if not self.send(frame):
                    return

    def send(self, frame: bytes) -> bool:
        if not self.alive:
            return False
        with self.write_lock:
            try:
                self.connection.sendall(frame)
            except (TimeoutError, BlockingIOError):
                # SO_SNDTIMEO fired: the peer stopped draining its buffer.
                # On a blocking socket the kernel deadline surfaces as
                # BlockingIOError (EAGAIN), not TimeoutError. The stall may
                # have left a partial NDJSON line on the wire, so nothing
                # can safely follow it: drop the client now. It recovers by
                # reconnecting and replaying the events it missed.
                self.alive = False
                self._log(f"core dropped client {self.index}: send stalled")
                return False
            except OSError:
                self.alive = False
                return False
            return True

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
        core_version: str = __version__,
        capabilities: Iterable[str] = DEFAULT_CAPABILITIES,
        max_clients: int = MAX_CLIENTS,
        peer_uid_reader: Callable[[socket.socket], int] | None = None,
        on_client_change: Callable[[int], None] | None = None,
        log: Callable[[str], None] | None = None,
        clock: Callable[[], float] = time.monotonic,
        slow_commands: Iterable[str] = SLOW_LANE_COMMANDS,
        scan_commands: Iterable[str] = SCAN_LANE_COMMANDS,
        action_commands: Iterable[str] = ACTION_LANE_COMMANDS,
        slow_lane_setup: Callable[[], None] | None = None,
    ) -> None:
        if not callable(dispatch) or not callable(initial_documents):
            raise ValueError("invalid core server dependency")
        if slow_lane_setup is not None and not callable(slow_lane_setup):
            raise ValueError("invalid core server slow-lane setup")
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
        self._slow_commands = frozenset(slow_commands)
        # The slow commands that take a long scan's lane, and the ones that
        # take the action lane; every other slow command takes the read lane.
        self._scan_commands = frozenset(scan_commands)
        self._action_commands = frozenset(action_commands)
        # Runs once on each lane's worker before its first command (the
        # runtime drops it to utility QoS there, never on a client's reader
        # thread).
        self._slow_lane_setup = slow_lane_setup
        self._slow_condition = threading.Condition()
        self._slow_queues: dict[str, deque[tuple[_Client, str | None, str, dict[str, Any]]]] = {
            _SCAN_LANE: deque(),
            _READ_LANE: deque(),
            _ACTION_LANE: deque(),
        }
        self._slow_workers: list[threading.Thread] = []
        # Bumped at each start: a worker left finishing a scan from before a
        # stop exits instead of serving beside the new one.
        self._slow_generation = 0

        self._lock = threading.RLock()
        self._clients: list[_Client] = []
        self._client_counter = 0
        self._server: socket.socket | None = None
        self._accept_thread: threading.Thread | None = None
        self._accept_wakeup: _AcceptWakeup | None = None
        self._running = False
        self._own_inode: int | None = None

        self._flush_condition = threading.Condition()
        self._pending: dict[str, dict[str, Any]] = {}
        self._queue: deque[bytes] = deque()
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
        # The replay journal and the stream it belongs to. ``_stream_id``
        # is set at ``start()``; every cursor carries it, so a cursor from
        # a previous incarnation is provably foreign (resync_required),
        # never mistaken for an empty suffix.
        self._stream_id: str | None = None
        self._journal: deque[dict[str, Any]] = deque()
        self._journal_dropped = 0
        self.stats = {"frames_out": 0, "commands": 0, "dropped_oversize": 0,
                      "refused_clients": 0, "deduped_frames": 0,
                      "dropped_queue": 0, "journal_dropped": 0,
                      "slow_lane": 0, "slow_lane_refused": 0,
                      "sanitized_frames": 0, "dropped_unencodable": 0}

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
            self._own_inode = os.stat(path).st_ino
            self._accept_wakeup = _AcceptWakeup()
            self._server = server
            self._running = True
            # One incarnation, one stream: pid + start epoch identifies
            # the journal a cursor belongs to. A restart is a new stream —
            # its journal starts empty and old cursors refuse as foreign.
            self._stream_id = f"{os.getpid()}-{int(time.time() * 1000):x}"
            self._journal.clear()
            self._journal_dropped = 0
            self._accept_thread = threading.Thread(
                target=self._accept_loop, name="JRBarCoreAccept", daemon=True
            )
            self._flusher = threading.Thread(
                target=self._flush_loop, name="JRBarCoreFlush", daemon=True
            )
            with self._slow_condition:
                self._slow_generation += 1
                generation = self._slow_generation
            self._slow_workers = [
                threading.Thread(
                    target=self._slow_lane_loop,
                    args=(generation, lane),
                    name=_LANE_THREAD_NAMES[lane],
                    daemon=True,
                )
                for lane in (_SCAN_LANE, _READ_LANE, _ACTION_LANE)
            ]
            self._accept_thread.start()
            self._flusher.start()
            for worker in self._slow_workers:
                worker.start()
            self._log(f"core listening on {path}")
            return path

    def stop(self, *, timeout_seconds: float = 2.0) -> None:
        with self._lock:
            if not self._running:
                return
            self._running = False
            server = self._server
            self._server = None
            wakeup = self._accept_wakeup
            clients = list(self._clients)
            self._clients = []
        with self._flush_condition:
            self._flush_condition.notify_all()
        with self._slow_condition:
            for queue in self._slow_queues.values():
                queue.clear()
            self._slow_condition.notify_all()
        if wakeup is not None:
            # Interrupt the accept thread's select BEFORE closing the
            # listening socket so the loop observes `running` False on a
            # live descriptor rather than a possibly-recycled fd number.
            wakeup.wake()
        for client in clients:
            client.close()
        # The slow-lane workers are not joined: mid-scan one would hold a quit
        # for the whole timeout, as a client's reader thread running one
        # never did. It sees the server stopped when the scan ends, and the
        # reply goes nowhere.
        for thread in (self._accept_thread, self._flusher):
            if thread is not None and thread is not threading.current_thread():
                thread.join(timeout_seconds)
        if server is not None:
            try:
                server.close()
            except OSError:
                pass
        if wakeup is not None:
            with self._lock:
                if self._accept_wakeup is wakeup:
                    self._accept_wakeup = None
            wakeup.close()
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
        """Unlink the socket path only when a live listener is DISPROVEN.

        A clean refusal (``ECONNREFUSED``) means nobody listens on that
        inode. A probe TIMEOUT means the opposite of proof: a wedged or
        overloaded live daemon reads exactly like that, and unlinking its
        path lets a second daemon steal it -- the split-brain this method
        exists to prevent. Ambiguous outcomes refuse to start instead.
        Mirrors ``ipc._existing_socket_refuses_connections``.
        """
        try:
            info = path.lstat()
        except FileNotFoundError:
            return
        if not stat.S_ISSOCK(info.st_mode):
            raise OSError(f"refusing to replace a non-socket at {path}")
        expected = (info.st_dev, info.st_ino)
        probe = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
        try:
            probe.settimeout(STALE_SOCKET_PROBE_TIMEOUT_SECONDS)
            probe.connect(str(path))
        except ConnectionRefusedError:
            pass  # proven dead; re-verify the inode below, then unlink
        except OSError:
            raise OSError(f"refusing to replace a live or unproven socket: {path}")
        else:
            raise OSError(f"another core is listening on {path}")
        finally:
            probe.close()
        try:
            current = path.lstat()
        except FileNotFoundError:
            return
        if not stat.S_ISSOCK(current.st_mode) or (current.st_dev, current.st_ino) != expected:
            raise OSError(f"socket path changed while proving staleness: {path}")
        path.unlink()
        try:
            after = path.lstat()
        except FileNotFoundError:
            return
        if stat.S_ISSOCK(after.st_mode) and (after.st_dev, after.st_ino) == expected:
            raise OSError(f"socket path survived removal: {path}")

    # -- publishing ---------------------------------------------------------

    def hello_document(self) -> dict[str, Any]:
        with self._flush_condition:
            cursor = self._journal[-1]["cursor"] if self._journal else None
        return {
            "t": "hello",
            "v": PROTOCOL_VERSION,
            "core_version": self._core_version,
            "pid": os.getpid(),
            "capabilities": list(self._capabilities),
            # The event stream this daemon serves: a reconnecting client
            # anchors its resume point here and calls ``replay_events``.
            "stream": self._stream_id,
            "cursor": cursor,
        }

    def publish_state(self, document: dict[str, Any]) -> None:
        self._publish_coalesced("state", document)

    def publish_lights(self, document: dict[str, Any]) -> None:
        self._publish_coalesced("lights", document)

    def publish_settings(self, document: dict[str, Any]) -> None:
        self._publish_coalesced("settings", document)

    def recent_reset_events(self, *, now: float | None = None) -> list[dict[str, Any]]:
        """Resets still within their delivery window, with original cursors."""
        from .provider_reset_events import RESET_DELIVERY_WINDOW_SECONDS

        current = time.time() if now is None else now
        with self._flush_condition:
            return [
                dict(event) for event in self._journal
                if event.get("kind") == "quota_reset"
                and isinstance(event.get("at"), (int, float))
                and 0 <= current - event["at"] < RESET_DELIVERY_WINDOW_SECONDS
            ]

    def publish_event(self, document: dict[str, Any]) -> dict[str, Any]:
        with self._flush_condition:
            self._event_counter += 1
            body = _envelope("event", document)
            body.setdefault("id", f"ev-{self._event_counter}")
            body.setdefault("at", time.time())
            # Journal and wire share one critical section, so the journal
            # IS the wire's order: a cursor's suffix replays exactly what
            # the socket fanned out, nothing dropped in between.
            if self._stream_id is None:
                # No stream yet -- a ``None:`` cursor would enter the
                # journal and be served under the future stream's id,
                # poisoning a resuming client's position. Pre-start
                # events are ephemeral: fan out (no clients yet) but do
                # not journal.
                self._enqueue_locked(body)
                self._flush_condition.notify_all()
                return body
            body["cursor"] = f"{self._stream_id}:{body['id']}"
            self._journal.append(body)
            while len(self._journal) > MAX_JOURNAL_EVENTS:
                self._journal.popleft()
                self._journal_dropped += 1
                self.stats["journal_dropped"] = self._journal_dropped
            self._enqueue_locked(body)
            self._flush_condition.notify_all()
        return body

    def replay_events(self, *, after: str | None = None, limit: int = 500) -> dict[str, Any]:
        """The journal suffix after ``after`` — the resumable-activity
        half of the snapshot/cursor boundary.

        A cursor is ``<stream>:<event id>``; every event frame carries it,
        so a client's position is the last ``cursor`` it saw. ``after``
        of ``None`` replays the whole retained journal. A foreign stream
        or an evicted id answers ``resync_required`` with the reason and
        the live tail cursor — never a fabricated empty catch-up. Long
        suffixes page: ``events`` holds the first ``limit`` in order,
        ``has_more`` says the tail was cut, and ``cursor`` is the last
        event actually returned.
        """
        try:
            limit = max(1, min(int(limit), MAX_JOURNAL_EVENTS))
        except (TypeError, ValueError):
            limit = 500
        with self._flush_condition:
            stream = self._stream_id
            tail = self._journal[-1]["cursor"] if self._journal else None
            base: dict[str, Any] = {
                "t": "events",
                "stream": stream,
                "retained": len(self._journal),
                "dropped": self._journal_dropped,
            }
            if stream is None:
                return {
                    **base,
                    "events": [],
                    "cursor": None,
                    "resync_required": True,
                    "reason": "no_stream",
                }
            start = 0
            if after:
                if not str(after).startswith(f"{stream}:"):
                    return {
                        **base,
                        "events": [],
                        "cursor": tail,
                        "resync_required": True,
                        "reason": "foreign_stream",
                    }
                index = next(
                    (i for i, entry in enumerate(self._journal) if entry["cursor"] == after),
                    None,
                )
                if index is None:
                    return {
                        **base,
                        "events": [],
                        "cursor": tail,
                        "resync_required": True,
                        "reason": "cursor_expired",
                    }
                start = index + 1
            suffix = list(self._journal)[start:]
            page = suffix[:limit]
            return {
                **base,
                "events": [dict(entry) for entry in page],
                "cursor": page[-1]["cursor"] if page else (after or tail),
                "has_more": len(suffix) > len(page),
                "resync_required": False,
            }

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
        frame = self._encode(body, body.get("t"))
        if frame is None:
            return
        if len(frame) > MAX_FRAME_BYTES:
            self.stats["dropped_oversize"] += 1
            self._log(f"core dropped oversize {body.get('t')} frame ({len(frame)} bytes)")
            return
        self._queue.append(frame)
        # Bound the backlog: drop the OLDEST queued frames so a flusher
        # that cannot keep up sheds history instead of memory.
        while len(self._queue) > MAX_QUEUED_FRAMES:
            self._queue.popleft()
            self.stats["dropped_queue"] += 1
        if self.stats["dropped_queue"] and self.stats["dropped_queue"] % 128 == 1:
            self._log("core queue overflow; dropped oldest frames")

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
                    frame = self._encode(body, kind)
                    if frame is None:
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
        dead = [client for client in clients if not client.deliver(frame)]
        if dead:
            self._drop_clients(dead)

    # -- clients ------------------------------------------------------------

    def _accept_loop(self) -> None:
        while True:
            with self._lock:
                server = self._server
                wakeup = self._accept_wakeup
                if not self._running or server is None or wakeup is None:
                    return
            try:
                connection = _accept_one(server, wakeup)
            except OSError as exc:
                self._log(f"core accept loop exited: {exc}")
                return
            if connection is None:
                continue
            try:
                # Kernel-level send deadline: a peer that stops reading
                # must not wedge the serial fan-out for everyone else.
                connection.setsockopt(
                    socket.SOL_SOCKET, socket.SO_SNDTIMEO, _SEND_TIMEOUT_TIMEVAL
                )
            except OSError:
                connection.close()
                continue
            try:
                connection.setsockopt(
                    socket.SOL_SOCKET, socket.SO_SNDBUF, CLIENT_SEND_BUFFER_BYTES
                )
            except OSError:
                pass
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
                client = _Client(connection, self._client_counter, self._log)
                self._clients.append(client)
            try:
                threading.Thread(
                    target=self._serve_client,
                    args=(client,),
                    name=f"JRBarCoreClient{client.index}",
                    daemon=True,
                ).start()
            except Exception as exc:  # pragma: no cover - resource exhaustion
                # A failed spawn must not kill the accept loop: the loop
                # dying while the listener stays bound wedges every future
                # connect in the kernel backlog with no error to the peer.
                self._log(f"core could not spawn client thread: {exc}")
                self._drop_clients([client])
                continue
            try:
                self._notify_client_change()
            except Exception as exc:  # pragma: no cover - defensive
                self._log(f"core client-change hook failed: {exc}")

    def _serve_client(self, client: _Client) -> None:
        try:
            try:
                self._greet(client)
            finally:
                # Frames published while the greeting was being sent follow
                # it, in order; a skipped frame or an early exit must never
                # leave the client held forever.
                client.finish_priming()
            self._read_commands(client)
        except Exception as exc:  # pragma: no cover - defensive
            self._log(f"core client {client.index} failed: {exc}")
        finally:
            self._drop_clients([client])

    def _greet(self, client: _Client) -> None:
        hello = self._encode(self.hello_document(), "hello")
        if hello is not None:
            client.send(hello)
        for document in self._initial_documents():
            if not client.alive:
                break
            kind = document.get("t")
            if not isinstance(kind, str):
                continue
            frame = self._encode(_envelope(kind, document), kind)
            if frame is None:
                continue
            if len(frame) > MAX_FRAME_BYTES:
                self._log(f"core skipped oversize initial {document.get('t')} frame")
                continue
            client.send(frame)
        for event in self.recent_reset_events():
            if not client.alive:
                break
            frame = self._encode(event, "quota_reset")
            if frame is None:
                continue
            if len(frame) > MAX_FRAME_BYTES:
                self._log("core skipped oversize initial quota_reset frame")
                continue
            client.send(frame)

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
            self._send_reply(client, self._reply(None, ok=False, code="bad_frame", message="not JSON"))
            return
        if not isinstance(message, dict):
            self._send_reply(client, self._reply(None, ok=False, code="bad_frame", message="not an object"))
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
            self._send_reply(client, self._reply(command_id, ok=False, code="bad_command", message="missing name"))
            return
        self.stats["commands"] += 1
        if name in self._slow_commands:
            self._queue_slow(client, command_id, name, {**args, SLOW_LANE_RECEIVED_AT: time.time()})
            return
        self._send_reply(client, self.run_command(command_id, name, args), name)

    def _queue_slow(self, client: _Client, command_id: str | None, name: str, args: dict[str, Any]) -> None:
        if name in self._action_commands:
            lane = _ACTION_LANE
        elif name in self._scan_commands:
            lane = _SCAN_LANE
        else:
            lane = _READ_LANE
        queue = self._slow_queues[lane]
        with self._slow_condition:
            if len(queue) < MAX_SLOW_LANE_QUEUED:
                queue.append((client, command_id, name, args))
                self.stats["slow_lane"] += 1
                self._slow_condition.notify_all()
                return
            self.stats["slow_lane_refused"] += 1
        self._send_reply(
            client,
            self._reply(command_id, ok=False, code="busy", message=f"{name}: too many slow reads queued; try again"),
        )

    def _slow_lane_loop(self, generation: int, lane: str) -> None:
        if self._slow_lane_setup is not None:
            try:
                self._slow_lane_setup()
            except Exception as exc:  # pragma: no cover - defensive
                self._log(f"core slow-lane setup failed: {exc}")
        queue = self._slow_queues[lane]
        while True:
            with self._slow_condition:
                while self._running and generation == self._slow_generation and not queue:
                    self._slow_condition.wait()
                if not self._running or generation != self._slow_generation:
                    return
                client, command_id, name, args = queue.popleft()
            # A client that left while its read waited gets no scan.
            if not client.alive:
                continue
            # _Client.send holds the client's write lock, so this reply
            # never interleaves with a frame the flusher or the reader
            # thread is writing to the same socket.
            try:
                self._send_reply(client, self.run_command(command_id, name, args), name)
            except Exception as exc:  # pragma: no cover - defensive
                # A lane that died would leave every later read queued for good.
                self._log(f"core slow-lane {lane} worker survived {name}: {exc.__class__.__name__}: {exc}")

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
        return reply

    def _encode(self, document: dict[str, Any], kind: object) -> bytes | None:
        """The wire bytes for ``document``, or ``None`` after a counted,
        logged drop when it cannot be written at all.

        A non-finite number is sent as ``null`` (``encode_frame``) and the
        frame is counted in ``sanitized_frames``. Nothing here raises: a
        document that cannot be encoded costs that one frame, never the
        flusher, a reader thread or the client's connection.
        """
        try:
            frame, replaced = encode_frame_counting(document)
        except Exception as exc:
            self.stats["dropped_unencodable"] += 1
            self._log(f"core could not encode a {kind} frame, dropped: {exc.__class__.__name__}: {str(exc)[:200]}")
            return None
        if replaced:
            self._note_sanitized(kind, replaced)
        return frame

    def _note_sanitized(self, kind: object, replaced: int) -> None:
        self.stats["sanitized_frames"] += 1
        count = self.stats["sanitized_frames"]
        # A producer of NaN would repeat on every state build; say it once,
        # then rarely.
        if count == 1 or count % 256 == 0:
            self._log(
                f"core sent null for {replaced} non-finite number(s) in a {kind} frame "
                f"({count} frame(s) so far)"
            )

    def _reply_frame(self, reply: dict[str, Any], name: str = "") -> bytes | None:
        """The wire bytes for a reply: always a frame the client can read.

        A result that cannot be written is replaced by its ``repr``; one over
        the frame limit is replaced by a ``frame_too_large`` error carrying
        the same id, so the app's command fails at once instead of waiting
        out its reply timeout for a frame its splitter threw away. ``None``
        when even that error cannot be sent (the id the client chose is
        itself over the limit).
        """
        try:
            frame, replaced = encode_frame_counting(reply)
        except Exception:
            reply = dict(reply)
            try:
                text = repr(reply.get("result"))[:2000]
            except Exception:
                text = "<a result that cannot be shown>"
            reply["result"] = {"repr": text}
            try:
                frame, replaced = encode_frame_counting(reply)
            except Exception:
                # Nothing about this reply can be written: count it and let
                # the caller carry on rather than end the connection.
                self.stats["dropped_unencodable"] += 1
                self._log(f"core dropped an unwritable reply to {name or 'a command'}")
                return None
        if replaced:
            self._note_sanitized("reply", replaced)
        if len(frame) <= MAX_FRAME_BYTES:
            return frame
        self.stats["dropped_oversize"] += 1
        self._log(f"core dropped an oversize reply to {name or 'a command'} ({len(frame)} bytes)")
        error = self._reply(
            reply.get("id") if isinstance(reply.get("id"), str) else None,
            ok=False,
            code="frame_too_large",
            message=f"{name or 'the command'}: the reply is {len(frame)} bytes, over the {MAX_FRAME_BYTES}-byte frame limit",
        )
        frame = self._encode(error, "reply")
        if frame is None or len(frame) > MAX_FRAME_BYTES:
            return None
        return frame

    def _send_reply(self, client: _Client, reply: dict[str, Any], name: str = "") -> None:
        frame = self._reply_frame(reply, name)
        if frame is not None:
            client.send(frame)

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
    "ACTION_LANE_COMMANDS",
    "CORE_SOCKET_NAME",
    "DEFAULT_CAPABILITIES",
    "MAX_CLIENTS",
    "MAX_FRAME_BYTES",
    "PROTOCOL_VERSION",
    "READ_LANE_COMMANDS",
    "SCAN_LANE_COMMANDS",
    "SLOW_LANE_COMMANDS",
    "STATE_MIN_INTERVAL_SECONDS",
    "CommandError",
    "CommandRouter",
    "CoreServer",
    "default_core_socket_path",
    "encode_frame",
    "encode_frame_counting",
]
