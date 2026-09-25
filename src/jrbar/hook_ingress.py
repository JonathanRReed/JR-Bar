"""Bounded FIFO hook processing with guarded local admission and drain receipts."""

from __future__ import annotations

import json
import math
import os
import socket
import threading
import time
from collections import deque
from collections.abc import Callable
from dataclasses import dataclass, field
from datetime import datetime, timezone
from enum import Enum
from pathlib import Path
from typing import Final

from . import audit
from .hook_ingress_protocol import (
    HOOK_INGRESS_KIND_STATUSLINE,
    MAX_HOOK_INGRESS_WIRE_BYTES,
    HookIngressDisposition,
    HookIngressRequest,
    decode_hook_ingress_request,
    default_hook_ingress_socket_path,
    encode_hook_ingress_response,
)
from .hook_pending import PENDING_REPLAY_HORIZON_SECONDS, nudge_pending_drains
from .ipc import (
    ProviderRefreshHint,
    _accept_one,
    _AcceptWakeup,
    _bind_socket_in_guard,
    _existing_socket_refuses_connections,
    _identity,
    _same_uid_peer,
    _SocketPathGuard,
)
from .private_io import append_private_text, ensure_private_directory
from .state_paths import default_state_dir

# Outstanding hooks (running plus queued). 32 filled in ten seconds of
# parallel agents on 2026-09-22 and every refusal past it was lost; the
# shim now spools a refusal, and this bound is sized so it rarely has to.
MAX_HOOK_INGRESS_ACCEPTED: Final = 128
# The count alone would let 128 one-megabyte payloads sit in memory; the
# queue also refuses once the payloads it holds pass this many bytes.
MAX_HOOK_INGRESS_OUTSTANDING_BYTES: Final = 16 * 1024 * 1024
MAX_HOOK_INGRESS_METRIC_COUNT: Final = 10_000
HOOK_INGRESS_READ_TIMEOUT_SECONDS: Final = 0.25
# Whole-connection budget, not per-recv: a trickling client that keeps
# the byte stream just barely alive still dies at this deadline instead
# of holding a worker slot for hours.
HOOK_INGRESS_CONNECTION_DEADLINE_SECONDS: Final = 5.0
# Bound on simultaneous inbound connections, each served by its own
# worker thread (one wedged or trickling peer can no longer serialize
# every hook behind it).
MAX_HOOK_INGRESS_CONNECTIONS: Final = 8
HOOK_INGRESS_LISTEN_BACKLOG: Final = 32
# A parked ``--decide`` connection hands its worker slot back before it
# waits (answer_decisions.py bounds how many wait at once), so a burst of
# PermissionRequests held for a click never starves ordinary hooks of the
# eight slots above.
HOOK_DECISION_SEND_TIMEOUT_SECONDS: Final = 1.0


class HookIngressOutcome(str, Enum):
    SUCCEEDED = "succeeded"
    FAILED = "failed"
    REFUSED_FULL = "refused_full"
    REFUSED_CLOSED = "refused_closed"
    REFUSED_INVALID = "refused_invalid"
    REJECTED_SHUTDOWN_TIMEOUT = "rejected_shutdown_timeout"


@dataclass(frozen=True, slots=True)
class HookIngressReceipt:
    sequence: int
    outcome: HookIngressOutcome
    request: HookIngressRequest | None = field(default=None, repr=False, compare=False)
    error_code: str | None = None
    result: object = field(default=None, repr=False, compare=False)

    def __post_init__(self) -> None:
        if type(self.sequence) is not int or self.sequence <= 0:
            raise ValueError("invalid hook ingress receipt sequence")
        if type(self.outcome) is not HookIngressOutcome:
            raise ValueError("invalid hook ingress receipt outcome")
        expected_error = {
            HookIngressOutcome.SUCCEEDED: None,
            HookIngressOutcome.FAILED: "processing_failed",
            HookIngressOutcome.REFUSED_FULL: "refused_full",
            HookIngressOutcome.REFUSED_CLOSED: "refused_closed",
            HookIngressOutcome.REFUSED_INVALID: "refused_invalid",
            HookIngressOutcome.REJECTED_SHUTDOWN_TIMEOUT: "shutdown_timeout",
        }[self.outcome]
        if self.error_code != expected_error:
            raise ValueError("invalid hook ingress receipt error code")
        if self.request is not None and type(self.request) is not HookIngressRequest:
            raise ValueError("invalid hook ingress receipt request")

    @property
    def provider(self) -> str | None:
        return None if self.request is None else self.request.provider


@dataclass(frozen=True, slots=True)
class HookIngressSnapshot:
    accepting: bool
    running: bool
    pending_count: int
    accepted_outstanding: int
    thread_alive: bool
    socket_running: bool
    submitted: int
    accepted: int
    refused_full: int
    refused_closed: int
    refused_invalid: int
    succeeded: int
    failed: int
    shutdown_timeout: int


@dataclass(frozen=True, slots=True)
class _AcceptedHook:
    sequence: int
    request: HookIngressRequest = field(repr=False)
    size: int = 0


@dataclass(frozen=True, slots=True)
class AppOwnedHookIngressProcessor:
    """Canonical hook processing with a synchronous app monitor refresh."""

    refresh_hint_handler: Callable[[ProviderRefreshHint], object] = field(repr=False)
    # The live ingress's handler for the line it just appended (the monitor
    # takes it without rereading the log), and its resident deduplicators.
    appended_handler: Callable[[ProviderRefreshHint, object], object] | None = field(default=None, repr=False)
    deduplicator_for: Callable[[Path], object] | None = field(default=None, repr=False)

    def __post_init__(self) -> None:
        if not callable(self.refresh_hint_handler):
            raise ValueError("invalid hook ingress refresh handler")

    def __call__(self, request: HookIngressRequest) -> object:
        from .hook import process_hook_payload

        register_shim_process(request)
        return process_hook_payload(
            request.provider,
            Path(request.log_path),
            request.payload_text,
            refresh_hint_handler=self.refresh_hint_handler,
            appended_handler=self.appended_handler,
            deduplicator_for=self.deduplicator_for,
            **_replay_arguments(request),
        )


class DeferredRefreshHints:
    """Refresh hints held while a drain replays the spool, then applied once
    per provider source when the pass ends.

    A hint only wakes the monitor, which rereads the provider's log for
    whatever was appended (``LiveAgentMonitor.reconcile_refresh_hint``), so
    the last hint of a source covers every line the drain wrote before it.
    Applied per hook, a 12-hook backlog opened, read and reconciled the same
    log twelve times in front of the first client (84 ms a hook measured)."""

    def __init__(self, apply: Callable[[ProviderRefreshHint], object]) -> None:
        if not callable(apply):
            raise ValueError("invalid refresh hint handler")
        self._apply = apply
        self._lock = threading.Lock()
        self._held: dict[object, ProviderRefreshHint] = {}

    def note(self, hint: ProviderRefreshHint) -> None:
        with self._lock:
            self._held[hint.source_key] = hint

    def flush(self) -> int:
        """Apply the newest hint of every source held, in first-seen order."""
        with self._lock:
            hints = tuple(self._held.values())
            self._held.clear()
        for hint in hints:
            try:
                self._apply(hint)
            except Exception:
                continue
        return len(hints)


def _replay_arguments(request: HookIngressRequest) -> dict[str, object]:
    """A payload the shim spooled inside the replay horizon is stamped on
    arrival, like a live one; only one older than the horizon keeps the
    time it was queued, and is written without the refresh hint: drained
    hours later it is history for the log, not a live turn.

    The arrival stamp is what lets a fresh replay reach live state. The
    monitor keeps one watermark per provider source, shared by every
    session, and skips any batch older than it. Stamped with its queued
    time, session A's spooled prompt was older than the live hook session
    B had just sent, so it was logged, skipped, and never read again; A
    never appeared."""
    queued_at = request.queued_at_epoch
    if queued_at is None or time.time() - queued_at <= PENDING_REPLAY_HORIZON_SECONDS:
        return {}
    from .hook import hook_logged_at

    return {"logged_at": hook_logged_at(queued_at), "refresh": False}


def register_shim_process(request: HookIngressRequest) -> None:
    """The compiled shim cannot walk the process table itself; it sends its
    parent pid and the daemon registers the agent process here. Requests
    from the Python hook client carry no ``ppid`` and registered themselves
    before submitting."""
    if request.ppid is None:
        return
    try:
        from .process_registry import note_hook_payload

        note_hook_payload(
            request.provider,
            request.payload_text,
            start_pid=request.ppid,
            start_pid_started=request.ppid_start,
        )
    except Exception:
        pass


_SOL_LOCAL: Final = 0
_LOCAL_PEERPID: Final = 0x002


def _peer_pid(connection: socket.socket) -> int | None:
    """The hook process on the other end (macOS ``LOCAL_PEERPID``). A
    parked decision watches it: the shim shuts its write side at once, so
    the socket itself reads as hung up long before the process is gone."""
    try:
        raw = connection.getsockopt(_SOL_LOCAL, _LOCAL_PEERPID, 4)
        pid = int.from_bytes(raw[:4], "little", signed=True)
    except (OSError, ValueError, TypeError):
        return None
    return pid if pid > 1 else None


def _pid_alive(pid: int) -> bool:
    try:
        os.kill(pid, 0)
    except ProcessLookupError:
        return False
    except OSError:
        return True
    return True


def _bounded_increment(value: int, amount: int = 1) -> int:
    return min(MAX_HOOK_INGRESS_METRIC_COUNT, value + max(0, amount))


def _valid_timeout(value: object) -> bool:
    return (
        isinstance(value, (int, float))
        and not isinstance(value, bool)
        and math.isfinite(float(value))
        and float(value) >= 0.0
    )


def default_hook_ingress_rejection_path() -> Path:
    return default_state_dir() / "hook-ingress-rejections.jsonl"


def _process_request(request: HookIngressRequest) -> object:
    from .hook import process_hook_payload

    register_shim_process(request)
    return process_hook_payload(
        request.provider,
        Path(request.log_path),
        request.payload_text,
        **_replay_arguments(request),
    )


class HookIngressService:
    """One guarded socket, one bounded admission FIFO, and one worker."""

    def __init__(
        self,
        *,
        process: Callable[[HookIngressRequest], object] = _process_request,
        maximum_accepted: int = MAX_HOOK_INGRESS_ACCEPTED,
        maximum_outstanding_bytes: int = MAX_HOOK_INGRESS_OUTSTANDING_BYTES,
        receipt_handler: Callable[[HookIngressReceipt], None] | None = None,
        rejection_recorder: Callable[[HookIngressReceipt], None] | None = None,
        rejection_path: Path | None = None,
        socket_path: Path | None = None,
        peer_uid_reader: Callable[[socket.socket], int] | None = None,
        monotonic: Callable[[], float] = time.monotonic,
        decision_broker: object | None = None,
        surface_recorder: object | None = None,
        backlog_cleared: Callable[[], object] | None = None,
        statusline_enabled: Callable[[], bool] | None = None,
    ) -> None:
        if not callable(process):
            raise ValueError("invalid hook ingress processor")
        if (
            type(maximum_accepted) is not int
            or maximum_accepted <= 0
            or maximum_accepted > MAX_HOOK_INGRESS_ACCEPTED
        ):
            raise ValueError("invalid hook ingress bound")
        if (
            type(maximum_outstanding_bytes) is not int
            or maximum_outstanding_bytes <= 0
            or maximum_outstanding_bytes > MAX_HOOK_INGRESS_OUTSTANDING_BYTES
        ):
            raise ValueError("invalid hook ingress byte bound")
        if backlog_cleared is not None and not callable(backlog_cleared):
            raise ValueError("invalid hook ingress backlog handler")
        if statusline_enabled is not None and not callable(statusline_enabled):
            raise ValueError("invalid hook ingress statusline reader")
        if receipt_handler is not None and not callable(receipt_handler):
            raise ValueError("invalid hook ingress receipt handler")
        if rejection_recorder is not None and not callable(rejection_recorder):
            raise ValueError("invalid hook ingress rejection recorder")
        if peer_uid_reader is not None and not callable(peer_uid_reader):
            raise ValueError("invalid hook ingress peer reader")
        if not callable(monotonic):
            raise ValueError("invalid hook ingress clock")
        self._process = process
        self._maximum_accepted = maximum_accepted
        self._maximum_outstanding_bytes = maximum_outstanding_bytes
        # A shim told refused_full spools its payload (hook_pending); once
        # the queue that refused it is empty again the spool is drained at
        # once, not at the next 30 s pass, so the refused events land before
        # the next human-paced one instead of after it.
        self._backlog_cleared = backlog_cleared or nudge_pending_drains
        self._refused_since_idle = False
        self._receipt_handler = receipt_handler
        self._rejection_path = Path(
            rejection_path or default_hook_ingress_rejection_path()
        ).expanduser()
        self._rejection_recorder = rejection_recorder or self._record_rejection
        self.socket_path = Path(
            socket_path or default_hook_ingress_socket_path()
        ).expanduser()
        self._peer_uid_reader = peer_uid_reader
        self._monotonic = monotonic
        # ``None`` resolves to the daemon's one broker on first use, so
        # constructing a service stays free of the decide lane's imports.
        self._decision_broker = decision_broker
        self._parked: set[object] = set()
        # Records which Ghostty terminal each session started in
        # (answer_surfaces.py), so opening it later lands on that pane.
        self._surface_recorder = surface_recorder
        # The daemon hands its live settings flag so each statusline frame
        # does not stat and parse the settings document behind a 5 s cache.
        self._statusline_enabled = statusline_enabled

        self._condition = threading.Condition()
        self._pending: deque[_AcceptedHook] = deque()
        self._running: _AcceptedHook | None = None
        self._worker: threading.Thread | None = None
        self._accepting = True
        self._sequence = 0
        self._timed_out_sequences: set[int] = set()
        self._metrics = {
            "submitted": 0,
            "accepted": 0,
            "refused_full": 0,
            "refused_closed": 0,
            "refused_invalid": 0,
            "succeeded": 0,
            "failed": 0,
            "shutdown_timeout": 0,
        }

        self._server_lock = threading.RLock()
        self._server_socket: socket.socket | None = None
        self._server_thread: threading.Thread | None = None
        self._server_running = False
        self._accept_wakeup: _AcceptWakeup | None = None
        self._connection_slots = threading.BoundedSemaphore(
            MAX_HOOK_INGRESS_CONNECTIONS
        )
        self._connections: set[socket.socket] = set()
        self._connection_workers: set[threading.Thread] = set()
        self._path_guard: _SocketPathGuard | None = None
        self._bound_identity: tuple[int, int] | None = None

    def start(self) -> Path:
        with self._condition:
            if not self._accepting:
                raise OSError("hook ingress is closed")
        with self._server_lock:
            if (
                self._server_running
                or self._server_socket is not None
                or self._path_guard is not None
                or (
                    self._server_thread is not None
                    and self._server_thread.is_alive()
                )
            ):
                raise OSError("hook ingress server is already running")
            ensure_private_directory(self.socket_path.parent)
            guard = _SocketPathGuard(self.socket_path)
            server: socket.socket | None = None
            bound_identity: tuple[int, int] | None = None
            try:
                existing = guard.leaf()
                if existing is not None:
                    expected = _identity(guard.socket_leaf())
                    if not _existing_socket_refuses_connections(guard, expected):
                        raise OSError(
                            f"refusing to replace live or unproven socket: {self.socket_path}"
                        )
                    guard.unlink_socket(expected)
                guard.assert_absent()
                server = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
                bound_identity = _bind_socket_in_guard(server, guard)
                guard.assert_parent()
                guard.chmod_socket(bound_identity, 0o600)
                server.listen(HOOK_INGRESS_LISTEN_BACKLOG)
                guard.assert_socket_identity(bound_identity)
                self._connection_slots = threading.BoundedSemaphore(
                    MAX_HOOK_INGRESS_CONNECTIONS
                )
                self._connections.clear()
                self._connection_workers.clear()
                self._accept_wakeup = _AcceptWakeup()
                self._path_guard = guard
                self._bound_identity = bound_identity
                self._server_socket = server
                self._server_running = True
                thread = threading.Thread(
                    target=self._serve,
                    name="JRBarHookIngressAccept",
                    daemon=True,
                )
                self._server_thread = thread
                thread.start()
                return self.socket_path
            except Exception:
                if server is not None:
                    server.close()
                if self._accept_wakeup is not None:
                    self._accept_wakeup.close()
                    self._accept_wakeup = None
                if bound_identity is not None:
                    try:
                        guard.unlink_owned_socket(bound_identity)
                    except OSError:
                        pass
                guard.close()
                self._path_guard = None
                self._bound_identity = None
                self._server_socket = None
                self._server_running = False
                raise

    def submit(self, request: HookIngressRequest) -> HookIngressDisposition:
        if type(request) is not HookIngressRequest:
            self.refuse_invalid()
            return HookIngressDisposition.REFUSED_INVALID
        receipt: HookIngressReceipt | None = None
        size = len(request.payload_text.encode("utf-8", errors="replace"))
        with self._condition:
            self._sequence += 1
            sequence = self._sequence
            self._increment("submitted")
            if not self._accepting:
                self._increment("refused_closed")
                receipt = HookIngressReceipt(
                    sequence,
                    HookIngressOutcome.REFUSED_CLOSED,
                    request=request,
                    error_code="refused_closed",
                )
                disposition = HookIngressDisposition.REFUSED_CLOSED
            elif (
                self._outstanding_locked() >= self._maximum_accepted
                or self._outstanding_bytes_locked() + size
                > self._maximum_outstanding_bytes
            ):
                self._increment("refused_full")
                self._refused_since_idle = True
                receipt = HookIngressReceipt(
                    sequence,
                    HookIngressOutcome.REFUSED_FULL,
                    request=request,
                    error_code="refused_full",
                )
                disposition = HookIngressDisposition.REFUSED_FULL
            else:
                command = _AcceptedHook(sequence, request, size)
                self._pending.append(command)
                self._increment("accepted")
                disposition = HookIngressDisposition.ACCEPTED
                if self._worker is None or not self._worker.is_alive():
                    thread = threading.Thread(
                        target=self._run,
                        name="JRBarHookIngressWorker",
                        daemon=True,
                    )
                    self._worker = thread
                    try:
                        thread.start()
                    except Exception:
                        self._worker = None
                        self._pending.remove(command)
                        self._accepting = False
                        self._increment("refused_closed")
                        receipt = HookIngressReceipt(
                            sequence,
                            HookIngressOutcome.REFUSED_CLOSED,
                            request=request,
                            error_code="refused_closed",
                        )
                        disposition = HookIngressDisposition.REFUSED_CLOSED
                self._condition.notify_all()
        if receipt is not None:
            self._publish(receipt)
        return disposition

    def refuse_invalid(self) -> HookIngressReceipt:
        with self._condition:
            self._sequence += 1
            sequence = self._sequence
            self._increment("submitted")
            self._increment("refused_invalid")
        receipt = HookIngressReceipt(
            sequence,
            HookIngressOutcome.REFUSED_INVALID,
            error_code="refused_invalid",
        )
        self._publish(receipt)
        return receipt

    def wait_idle(self, *, timeout_seconds: float) -> bool:
        deadline = self._deadline(timeout_seconds)
        with self._condition:
            while self._running is not None or self._pending:
                remaining = deadline - self._now()
                if remaining <= 0.0:
                    return False
                self._condition.wait(remaining)
            return True

    def wait_stopped(self, *, timeout_seconds: float) -> bool:
        deadline = self._deadline(timeout_seconds)
        with self._condition:
            while self._worker is not None and self._worker.is_alive():
                remaining = deadline - self._now()
                if remaining <= 0.0:
                    return False
                self._condition.wait(remaining)
        with self._server_lock:
            thread = self._server_thread
        if thread is not None and thread.is_alive():
            remaining = deadline - self._now()
            if remaining <= 0.0:
                return False
            thread.join(remaining)
        return not (thread is not None and thread.is_alive())

    def close(self, *, timeout_seconds: float) -> bool:
        deadline = self._deadline(timeout_seconds)
        with self._condition:
            self._accepting = False
            self._condition.notify_all()
            worker = self._worker
        current = threading.current_thread()
        if worker is current:
            drained = False
        else:
            if worker is not None:
                worker.join(max(0.0, deadline - self._now()))
            drained = worker is None or not worker.is_alive()

        timeout_receipts: list[HookIngressReceipt] = []
        if not drained:
            with self._condition:
                unfinished = tuple(
                    command
                    for command in (
                        *((self._running,) if self._running is not None else ()),
                        *self._pending,
                    )
                    if command.sequence not in self._timed_out_sequences
                )
                self._pending.clear()
                for command in unfinished:
                    self._timed_out_sequences.add(command.sequence)
                    self._increment("shutdown_timeout")
                    timeout_receipts.append(
                        HookIngressReceipt(
                            command.sequence,
                            HookIngressOutcome.REJECTED_SHUTDOWN_TIMEOUT,
                            request=command.request,
                            error_code="shutdown_timeout",
                        )
                    )
                self._condition.notify_all()
        for receipt in timeout_receipts:
            self._publish(receipt)

        socket_stopped = self._stop_server(deadline)
        return drained and socket_stopped

    def snapshot(self) -> HookIngressSnapshot:
        with self._condition:
            worker = self._worker
            outstanding = self._outstanding_locked()
            snapshot_values = {
                name: self._metrics[name]
                for name in (
                    "submitted",
                    "accepted",
                    "refused_full",
                    "refused_closed",
                    "refused_invalid",
                    "succeeded",
                    "failed",
                    "shutdown_timeout",
                )
            }
            accepting = self._accepting
            running = self._running is not None
            pending_count = len(self._pending)
            thread_alive = bool(worker is not None and worker.is_alive())
        with self._server_lock:
            socket_running = self._server_running
        return HookIngressSnapshot(
            accepting=accepting,
            running=running,
            pending_count=pending_count,
            accepted_outstanding=outstanding,
            thread_alive=thread_alive,
            socket_running=socket_running,
            **snapshot_values,
        )

    def _run(self) -> None:
        while True:
            with self._condition:
                while not self._pending and self._accepting:
                    self._condition.wait()
                if not self._pending:
                    self._worker = None
                    self._condition.notify_all()
                    return
                command = self._pending.popleft()
                self._running = command
            try:
                result = self._process(command.request)
                receipt = HookIngressReceipt(
                    command.sequence,
                    HookIngressOutcome.SUCCEEDED,
                    request=command.request,
                    result=result,
                )
            except Exception:
                receipt = HookIngressReceipt(
                    command.sequence,
                    HookIngressOutcome.FAILED,
                    request=command.request,
                    error_code="processing_failed",
                )
            with self._condition:
                self._running = None
                timed_out = command.sequence in self._timed_out_sequences
                if not timed_out:
                    self._increment(
                        "succeeded"
                        if receipt.outcome is HookIngressOutcome.SUCCEEDED
                        else "failed"
                    )
                backlog_cleared = self._refused_since_idle and not self._pending
                if backlog_cleared:
                    self._refused_since_idle = False
                self._condition.notify_all()
            if not timed_out:
                self._publish(receipt)
            if backlog_cleared:
                try:
                    self._backlog_cleared()
                except Exception:
                    pass

    def _serve(self) -> None:
        while True:
            with self._server_lock:
                server = self._server_socket
                wakeup = self._accept_wakeup
                if not self._server_running or server is None or wakeup is None:
                    return
            try:
                connection = _accept_one(server, wakeup)
            except OSError:
                return
            if connection is None:
                continue
            with self._server_lock:
                if not self._server_running or self._server_socket is not server:
                    connection.close()
                    return
                slot = self._connection_slots.acquire(blocking=False)
                if slot:
                    worker = threading.Thread(
                        target=self._serve_connection,
                        args=(connection,),
                        name="JRBarHookIngressConn",
                        daemon=True,
                    )
                    self._connections.add(connection)
                    self._connection_workers.add(worker)
            if not slot:
                # Outside the server lock: the refusal takes the queue's.
                self._refuse_without_a_slot(connection)
                continue
            worker.start()

    def _refuse_without_a_slot(self, connection: socket.socket) -> None:
        """Every worker slot is held: answer refused_full, then close.

        A bare close read as delivered to the C shim -- its small frame was
        already in the socket buffer, it read EOF and spooled nothing -- so
        a burst of parallel hooks lost the ones past the slots. With the
        answer it spools them for the drain, and so does the Python client
        when the answer reaches it before its send fails. The frame is
        never read. Nothing is written to the rejection log on the accept thread
        a burst is already crowding; the counter still says it happened.
        """
        with self._condition:
            self._sequence += 1
            self._increment("submitted")
            self._increment("refused_full")
            self._refused_since_idle = True
        try:
            # Never block the accept loop: a fresh socket's send buffer
            # takes one short line, and a peer already gone costs nothing.
            connection.setblocking(False)
            connection.send(
                encode_hook_ingress_response(HookIngressDisposition.REFUSED_FULL)
            )
        except OSError:
            pass
        finally:
            connection.close()

    def _serve_connection(self, connection: socket.socket) -> None:
        parked = None
        try:
            try:
                parked = self._handle_connection(connection)
            finally:
                # A parked decision waits outside the worker slots.
                self._connection_slots.release()
            if parked is not None:
                self._await_decision(connection, parked)
        finally:
            try:
                connection.close()
            except OSError:
                pass
            with self._server_lock:
                self._connections.discard(connection)
                self._connection_workers.discard(threading.current_thread())

    def _broker(self):
        if self._decision_broker is None:
            from .answer_decisions import default_decision_broker

            self._decision_broker = default_decision_broker()
        return self._decision_broker

    def _observe_for_decisions(self, request: HookIngressRequest) -> None:
        """Every arriving hook may prove a parked prompt is gone, and every
        PermissionRequest leaves the card a preview of what it wants to run."""
        try:
            self._broker().observe(request.provider, request.payload_text)
        except Exception:
            pass
        if '"PermissionRequest"' not in request.payload_text:
            return
        try:
            from .answer_decisions import default_ask_previews

            default_ask_previews().note(request.provider, request.payload_text)
        except Exception:
            pass

    def _note_surface(self, request: HookIngressRequest) -> None:
        """A SessionStart from the compiled shim carries the agent's pid:
        the moment to note which terminal surface the session lives in.
        Returns at once; the probe runs on the recorder's own thread."""
        if request.ppid is None or '"SessionStart"' not in request.payload_text:
            return
        try:
            if self._surface_recorder is None:
                from .answer_surfaces import default_surface_recorder

                self._surface_recorder = default_surface_recorder()
            self._surface_recorder.note_session_start(
                request.provider, request.payload_text, request.ppid
            )
        except Exception:
            pass

    def _park_decision(self, request: HookIngressRequest):
        """A ``--decide`` request the lane can hold, parked BEFORE the payload
        is queued, so the state that shows the ask already shows it as
        answerable. ``None`` sends the ordinary reply: the shim then prints
        nothing and the agent's own prompt carries on."""
        if request.decide_ms is None:
            return None
        try:
            from .answer_decisions import permission_facts

            facts = permission_facts(request.provider, request.payload_text)
            if facts is None:
                return None
            slot = self._broker().park(
                facts,
                wait_limit_seconds=request.decide_ms / 1000.0,
                host_pid=request.ppid,
            )
        except Exception:
            return None
        if slot is not None:
            with self._server_lock:
                self._parked.add(slot)
        return slot

    def _unpark(self, slot) -> None:
        with self._server_lock:
            self._parked.discard(slot)
        try:
            self._broker().release_slot(slot)
        except Exception:
            pass

    def _await_decision(self, connection: socket.socket, slot) -> None:
        broker = self._broker()
        delivered = False
        peer = _peer_pid(connection)
        try:
            verdict = broker.wait(
                slot,
                alive=None if peer is None else (lambda: _pid_alive(peer)),
            )
            if verdict is not None:
                from .hook_ingress_protocol import encode_hook_decision

                connection.settimeout(HOOK_DECISION_SEND_TIMEOUT_SECONDS)
                connection.sendall(encode_hook_decision(verdict))
                delivered = True
        except (OSError, ValueError):
            delivered = False
        finally:
            with self._server_lock:
                self._parked.discard(slot)
            broker.delivered(slot, delivered)

    def _handle_connection(self, connection: socket.socket):
        if not _same_uid_peer(connection, self._peer_uid_reader):
            return None
        deadline = self._now() + HOOK_INGRESS_CONNECTION_DEADLINE_SECONDS
        chunks: list[bytes] = []
        total = 0
        while True:
            remaining = deadline - self._now()
            if remaining <= 0.0:
                return None
            try:
                connection.settimeout(
                    min(HOOK_INGRESS_READ_TIMEOUT_SECONDS, remaining)
                )
                chunk = connection.recv(65536)
            except (TimeoutError, OSError):
                return None
            if not chunk:
                break
            total += len(chunk)
            if total > MAX_HOOK_INGRESS_WIRE_BYTES:
                self.refuse_invalid()
                self._send_response(
                    connection,
                    HookIngressDisposition.REFUSED_INVALID,
                )
                return None
            chunks.append(chunk)
        request = decode_hook_ingress_request(b"".join(chunks))
        parked = None
        if request is None:
            self.refuse_invalid()
            disposition = HookIngressDisposition.REFUSED_INVALID
        elif request.kind == HOOK_INGRESS_KIND_STATUSLINE:
            # Claude Code's statusLine (jrbar-hook --statusline): rate
            # limits for the quota source, and never a hook event, so it
            # can never keep a session alive (claude_statusline_source).
            disposition = self._accept_statusline(request)
        else:
            self._observe_for_decisions(request)
            parked = self._park_decision(request)
            disposition = self.submit(request)
            if parked is not None and disposition is not HookIngressDisposition.ACCEPTED:
                self._unpark(parked)
                parked = None
            if disposition is HookIngressDisposition.ACCEPTED:
                self._note_surface(request)
        if not self._send_response(connection, disposition) and parked is not None:
            # The hook went away before it heard the disposition: nobody is
            # left to print a verdict.
            self._unpark(parked)
            parked = None
        return parked

    def _accept_statusline(self, request: HookIngressRequest) -> HookIngressDisposition:
        try:
            from .claude_statusline_source import ingest

            reader = self._statusline_enabled
            ingest(request.payload_text, enabled=reader() if reader is not None else None)
        except Exception:
            pass
        return HookIngressDisposition.ACCEPTED

    @staticmethod
    def _send_response(
        connection: socket.socket,
        disposition: HookIngressDisposition,
    ) -> bool:
        try:
            connection.sendall(encode_hook_ingress_response(disposition))
        except OSError:
            return False
        return True

    def _stop_server(self, deadline: float) -> bool:
        with self._server_lock:
            parked = tuple(self._parked)
            self._parked.clear()
        # Parked hooks fall through to the agents' own prompts before their
        # connections close under them.
        for slot in parked:
            try:
                self._broker().release_slot(slot)
            except Exception:
                pass
        with self._server_lock:
            self._server_running = False
            server = self._server_socket
            self._server_socket = None
            connections = tuple(self._connections)
            workers = tuple(self._connection_workers)
            thread = self._server_thread
            wakeup = self._accept_wakeup
            if wakeup is not None:
                # Interrupt the accept thread's select BEFORE touching the
                # listening socket so it sees `_server_running` False on a
                # live descriptor rather than a possibly-recycled fd.
                wakeup.wake()
            for connection in connections:
                try:
                    connection.shutdown(socket.SHUT_RDWR)
                except OSError:
                    pass
                try:
                    connection.close()
                except OSError:
                    pass
        current = threading.current_thread()
        if thread is not None and thread is not current:
            thread.join(max(0.0, deadline - self._now()))
        if server is not None:
            try:
                server.close()
            except OSError:
                pass
        for worker in workers:
            # A worker still between "added to the set" and ".start()" was
            # never started: join() on it raises, and its already-closed
            # connection makes it exit on its own anyway.
            if worker is current or worker.ident is None:
                continue
            remaining = deadline - self._now()
            if remaining <= 0.0:
                break
            worker.join(remaining)
        if wakeup is not None:
            with self._server_lock:
                if self._accept_wakeup is wakeup:
                    self._accept_wakeup = None
            wakeup.close()
        stopped = thread is None or not thread.is_alive()
        with self._server_lock:
            guard = self._path_guard
            expected = self._bound_identity
            self._path_guard = None
            self._bound_identity = None
            if stopped:
                self._server_thread = None
            if guard is not None:
                if expected is not None:
                    try:
                        guard.unlink_owned_socket(expected)
                    except OSError:
                        pass
                guard.close()
        return stopped

    def _publish(self, receipt: HookIngressReceipt) -> None:
        handlers: tuple[Callable[[HookIngressReceipt], None] | None, ...]
        if receipt.outcome is HookIngressOutcome.SUCCEEDED:
            handlers = (self._receipt_handler,)
        else:
            handlers = (self._receipt_handler, self._rejection_recorder)
        delivered: list[Callable[[HookIngressReceipt], None]] = []
        for handler in handlers:
            if handler is None or handler in delivered:
                continue
            delivered.append(handler)
            try:
                handler(receipt)
            except Exception:
                continue

    def _record_rejection(self, receipt: HookIngressReceipt) -> None:
        document = {
            "version": 1,
            "recorded_at": datetime.now(timezone.utc).strftime(
                "%Y-%m-%dT%H:%M:%SZ"
            ),
            "sequence": receipt.sequence,
            "provider": receipt.provider,
            "reason": receipt.outcome.value,
        }
        append_private_text(
            self._rejection_path,
            json.dumps(document, separators=(",", ":"), sort_keys=True) + "\n",
        )
        audit.compact_jsonl_file(self._rejection_path)

    def _outstanding_locked(self) -> int:
        running = int(
            self._running is not None
            and self._running.sequence not in self._timed_out_sequences
        )
        return running + sum(
            command.sequence not in self._timed_out_sequences
            for command in self._pending
        )

    def _outstanding_bytes_locked(self) -> int:
        running = (
            self._running.size
            if self._running is not None
            and self._running.sequence not in self._timed_out_sequences
            else 0
        )
        return running + sum(
            command.size
            for command in self._pending
            if command.sequence not in self._timed_out_sequences
        )

    def _increment(self, name: str, amount: int = 1) -> None:
        self._metrics[name] = _bounded_increment(self._metrics[name], amount)

    def _now(self) -> float:
        value = self._monotonic()
        if (
            not isinstance(value, (int, float))
            or isinstance(value, bool)
            or not math.isfinite(float(value))
        ):
            raise RuntimeError("hook ingress clock returned an invalid value")
        return float(value)

    def _deadline(self, timeout_seconds: float) -> float:
        if not _valid_timeout(timeout_seconds):
            raise ValueError("invalid hook ingress timeout")
        return self._now() + float(timeout_seconds)


__all__ = [
    "HOOK_INGRESS_READ_TIMEOUT_SECONDS",
    "MAX_HOOK_INGRESS_ACCEPTED",
    "MAX_HOOK_INGRESS_OUTSTANDING_BYTES",
    "DeferredRefreshHints",
    "HookIngressOutcome",
    "HookIngressReceipt",
    "HookIngressService",
    "HookIngressSnapshot",
    "default_hook_ingress_rejection_path",
    "register_shim_process",
]
