"""Clean-room, provider-neutral Creator Micro 2 vendor-HID boundary."""

from __future__ import annotations

import json
import logging
import time
from collections import deque
from collections.abc import Callable
from dataclasses import dataclass, field
from enum import Enum
from typing import Any, Protocol


class SemanticState(str, Enum):
    INPUT_REQUIRED = "input_required"
    FAILURE = "failure"
    QUOTA_EXHAUSTED = "quota_exhausted"
    RESET = "reset"
    ACTIVE = "active"
    COMPLETED = "completed"
    QUOTA_WARNING = "quota_warning"
    IDLE = "idle"

    def __str__(self) -> str:
        return self.value

    @property
    def priority(self) -> int:
        return _SEMANTIC_PRIORITY[self]


_SEMANTIC_PRIORITY = {
    SemanticState.INPUT_REQUIRED: 800,
    SemanticState.FAILURE: 700,
    SemanticState.QUOTA_EXHAUSTED: 600,
    SemanticState.RESET: 500,
    SemanticState.ACTIVE: 400,
    SemanticState.COMPLETED: 300,
    SemanticState.QUOTA_WARNING: 200,
    SemanticState.IDLE: 100,
}


@dataclass(frozen=True)
class Receipt:
    code: str
    detail: str = ""
    recoverable: bool = True


_log = logging.getLogger(__name__)


class DeviceTransport(Protocol):
    def open(self, *, nonexclusive: bool = True) -> None: ...
    def write(self, report: bytes) -> None: ...
    def read(self, *, timeout_ms: int) -> bytes | None: ...
    def close(self) -> None: ...


class NoDeviceError(OSError):
    """The optional backend is available, but no matching collection exists."""


class MalformedNotification(ValueError):
    """An id-less push that failed envelope validation.

    A notification is nobody's answer, so unlike a malformed response or an
    undecodable frame it must not tear down the transport: the decoder records
    what arrived, drops the object, and keeps reading.
    """


@dataclass(frozen=True)
class DeviceCapability:
    methods: frozenset[str] = frozenset()

    @classmethod
    def from_methods(cls, methods: list[str] | set[str] | frozenset[str]) -> DeviceCapability:
        return cls(frozenset(methods))

    @property
    def can_light(self) -> bool:
        return "lights.preview" in self.methods

    @property
    def can_agent_status(self) -> bool:
        return "v.oai.thstatus" in self.methods


@dataclass
class DeviceConflict:
    """Which answers on the wire are ours.

    The firmware offers no ownership handshake, so a response to an id we
    never issued is the only evidence that something else is driving the
    pad. An id we issued and already completed is not that evidence: over
    Bluetooth the pad can answer twice or late, and reading our own echo as
    a second controller stops output for good on a pad nobody else is
    touching. Completed ids are remembered for the rest of the connection's
    recent history so that echo is recognised rather than accused. ``since``
    records when the accusation began so a caller can retry the connection
    after a bounded delay instead of stopping output for the process's life.
    """

    issued_ids: set[int] = field(default_factory=set)
    completed_ids: deque[int] = field(default_factory=lambda: deque(maxlen=64))
    active: bool = False
    since: float | None = None
    clock: Callable[[], float] = time.monotonic

    def observe(self, response_id: object) -> str | None:
        if type(response_id) is not int:
            return self._accuse()
        if response_id in self.issued_ids:
            self.issued_ids.remove(response_id)
            self.completed_ids.append(response_id)
            return None
        if response_id in self.completed_ids:
            return "duplicate_response_id"
        return self._accuse()

    def _accuse(self) -> str:
        if not self.active:
            self.active = True
            self.since = self.clock()
        return "foreign_response_id"

    def reset(self) -> None:
        self.issued_ids.clear()
        self.completed_ids.clear()
        self.active = False
        self.since = None


class CreatorMicro2Framer:
    REPORT_ID = 6
    RPC_CHANNEL = 2
    DEBUG_CHANNEL = 1
    REPORT_SIZE = 64
    CHUNK_SIZE = 61
    VENDOR_ID = 0x303A
    PRODUCT_IDS = frozenset((0x8297, 0x8298))
    USAGE_PAGE = 0xFF00
    USAGE = 1
    MAX_REPORTS = 64
    MAX_SETUP_BYTES = 132_096  # Two JSON encodings of a 64 KiB keymap, plus envelope.

    @classmethod
    def bounded_budget(cls, value: int) -> int:
        if type(value) is not int or not 1 <= value <= cls.MAX_SETUP_BYTES:
            raise ValueError("invalid JSON-RPC byte budget")
        return value

    @staticmethod
    def _valid_id(value: object) -> bool:
        return type(value) is int and 0 <= value < 1000

    @classmethod
    def validate_request(cls, value: Any) -> None:
        if not isinstance(value, dict) or value.get("jsonrpc") != "2.0":
            raise ValueError("invalid JSON-RPC 2.0 request")
        if not isinstance(value.get("method"), str) or not value["method"] or not cls._valid_id(value.get("id")):
            raise ValueError("invalid JSON-RPC 2.0 request")
        if set(value) - {"jsonrpc", "method", "params", "id"}:
            raise ValueError("invalid JSON-RPC 2.0 request")

    @classmethod
    def _notification_error(cls, value: dict[str, Any], reason: str | None = None) -> MalformedNotification:
        # Name the key set and show a bounded slice of the payload so a live
        # receipt records what the firmware actually sent, not just that the
        # shape was unexpected.
        detail = "invalid JSON-RPC notification"
        if reason:
            detail += f": {reason}"
        detail += f" (keys: {sorted(map(str, value))})"
        snippet = repr(value)
        if len(snippet) > 120:
            snippet = snippet[:117] + "..."
        return MalformedNotification(f"{detail} {snippet}")

    @classmethod
    def validate_incoming(cls, value: Any) -> None:
        if not isinstance(value, dict):
            raise ValueError("invalid JSON-RPC 2.0 envelope")
        if "id" in value:
            if value.get("jsonrpc", "2.0") != "2.0":
                raise ValueError("invalid JSON-RPC 2.0 envelope")
            if not cls._valid_id(value["id"]):
                # Name the shape so a live receipt says what the firmware
                # actually sent instead of just that it was wrong.
                raise ValueError(f"invalid JSON-RPC response id ({type(value['id']).__name__})")
            keys = set(value) - {"jsonrpc"}
            conventional = keys in ({"id", "result"}, {"id", "error"})
            firmware = keys in (
                {"id", "method", "params"},
                {"id", "method", "result"},
                {"id", "method", "error"},
            ) and isinstance(value.get("method"), str)
            if not conventional and not firmware:
                raise ValueError("invalid JSON-RPC response")
            if "error" in value and not isinstance(value["error"], dict):
                raise ValueError("invalid JSON-RPC error")
            return
        # An id-less message is a notification: the method is the only field
        # that must check out, because the firmware attaches whatever else it
        # likes. Params are optional and extra keys are allowed through.
        if value.get("jsonrpc", "2.0") != "2.0":
            raise cls._notification_error(value, "invalid JSON-RPC 2.0 envelope")
        if "m" in value and "method" in value and value["m"] != value["method"]:
            raise cls._notification_error(value, "conflicting m/method")
        method = value["m"] if "m" in value else value.get("method")
        if not isinstance(method, str) or not method:
            raise cls._notification_error(value)

    @classmethod
    def _encode(
        cls, message: dict[str, Any], *, max_bytes: int | None = None,
        line_delimited: bool = False,
    ) -> list[bytes]:
        budget = cls.bounded_budget(cls.MAX_REPORTS * cls.CHUNK_SIZE if max_bytes is None else max_bytes)
        payload = json.dumps(message, separators=(",", ":"), ensure_ascii=False).encode("utf-8")
        if line_delimited:
            # The firmware parses the shared channel on line boundaries. The
            # leading delimiter also separates a previous incomplete request.
            # Count delimiters in the wire budget, not only the JSON body.
            payload = b"\r\n" + payload + b"\r\n"
        if not payload or len(payload) > budget:
            raise ValueError("payload exceeds report limit")
        parts = [payload[offset : offset + cls.CHUNK_SIZE] for offset in range(0, len(payload), cls.CHUNK_SIZE)]
        return [
            bytes((cls.REPORT_ID, cls.RPC_CHANNEL, len(part))) + part.ljust(cls.CHUNK_SIZE, b"\0") for part in parts
        ]

    @classmethod
    def encode_request(cls, message: dict[str, Any], *, max_bytes: int | None = None) -> list[bytes]:
        cls.validate_request(message)
        return cls._encode(message, max_bytes=max_bytes, line_delimited=True)

    @classmethod
    def encode_message(cls, message: dict[str, Any]) -> list[bytes]:
        cls.validate_incoming(message)
        return cls._encode(message)

    encode = encode_request

    @classmethod
    def decode(cls, reports: bytes) -> dict[str, Any]:
        decoder = RpcStreamDecoder()
        messages: list[dict[str, Any]] = []
        if not reports or len(reports) % cls.REPORT_SIZE:
            raise ValueError("incomplete HID report")
        for offset in range(0, len(reports), cls.REPORT_SIZE):
            messages.extend(decoder.feed(reports[offset : offset + cls.REPORT_SIZE]))
        if len(messages) != 1 or decoder.pending_bytes:
            raise ValueError("incomplete JSON-RPC message")
        return messages[0]

    @classmethod
    def discover(cls, info: dict[str, Any]) -> bool:
        return (
            info.get("vendor_id") == cls.VENDOR_ID
            and info.get("product_id") in cls.PRODUCT_IDS
            and info.get("usage_page") == cls.USAGE_PAGE
            and info.get("usage") == cls.USAGE
        )


class RpcStreamDecoder:
    """Reassemble the unnumbered HID fragment stream into complete JSON objects."""

    MAX_BUFFER = CreatorMicro2Framer.MAX_REPORTS * CreatorMicro2Framer.CHUNK_SIZE

    def __init__(self, *, max_bytes: int = MAX_BUFFER) -> None:
        self.max_bytes = CreatorMicro2Framer.bounded_budget(max_bytes)
        self._buffer = bytearray()
        self._reset_scan()
        self.skipped: deque[str] = deque(maxlen=16)

    def drain_skipped(self) -> list[str]:
        """Details of malformed notifications dropped since the last drain."""
        skipped = list(self.skipped)
        self.skipped.clear()
        return skipped

    def _reset_scan(self) -> None:
        self._scan = 0
        self._start = None
        self._depth = 0
        self._in_string = False
        self._escaped = False

    @property
    def pending_bytes(self) -> int:
        return len(self._buffer)

    def feed(self, report: bytes) -> list[dict[str, Any]]:
        try:
            fragment = self._fragment(report)
            if fragment is None:
                return []
            self._buffer.extend(fragment)
            if len(self._buffer) > self.max_bytes:
                raise ValueError("JSON-RPC fragment buffer limit exceeded")
            return self._drain()
        except ValueError:
            self._buffer.clear()
            self._reset_scan()
            raise

    @staticmethod
    def _fragment(report: bytes) -> bytes | None:
        if len(report) == CreatorMicro2Framer.REPORT_SIZE:
            if report[0] != CreatorMicro2Framer.REPORT_ID:
                raise ValueError("unexpected HID report id")
            channel, length, start = report[1], report[2], 3
        elif len(report) == CreatorMicro2Framer.REPORT_SIZE - 1:
            channel, length, start = report[0], report[1], 2
        else:
            raise ValueError("incomplete HID report")
        if channel not in (CreatorMicro2Framer.DEBUG_CHANNEL, CreatorMicro2Framer.RPC_CHANNEL):
            raise ValueError("unexpected HID channel")
        if length > CreatorMicro2Framer.CHUNK_SIZE or start + length > len(report):
            raise ValueError("invalid HID report length")
        if channel == CreatorMicro2Framer.DEBUG_CHANNEL:
            return None
        return report[start : start + length]

    def _drain(self) -> list[dict[str, Any]]:
        messages: list[dict[str, Any]] = []
        consumed = 0
        # Resume at the next byte. Rescanning every earlier fragment makes a
        # full keymap quadratic even though the wire arrives 61 bytes at a time.
        for index in range(self._scan, len(self._buffer)):
            byte = self._buffer[index]
            char = chr(byte)
            if self._start is None:
                if char.isspace():
                    consumed = index + 1
                    continue
                if char != "{":
                    raise ValueError("invalid JSON-RPC payload")
                self._start, self._depth = index, 1
                continue
            if self._in_string:
                if self._escaped:
                    self._escaped = False
                elif char == "\\":
                    self._escaped = True
                elif char == '"':
                    self._in_string = False
            elif char == '"':
                self._in_string = True
            elif char == "{":
                self._depth += 1
            elif char == "}":
                self._depth -= 1
                if self._depth == 0:
                    raw = bytes(self._buffer[self._start : index + 1])
                    try:
                        value = json.loads(raw)
                    except (UnicodeDecodeError, json.JSONDecodeError, RecursionError) as exc:
                        raise ValueError("invalid JSON-RPC payload") from exc
                    # JSON-RPC 2.0 lets a notification carry ``"id": null``,
                    # and the pad's firmware does on its unsolicited pushes.
                    # A null id is nobody's answer: drop the key so the
                    # message routes as a notification instead of failing
                    # the whole stream as a malformed response.
                    if isinstance(value, dict) and "id" in value and value["id"] is None:
                        value = {key: item for key, item in value.items() if key != "id"}
                    try:
                        CreatorMicro2Framer.validate_incoming(value)
                    except MalformedNotification as exc:
                        # An id-less push we cannot read is nobody's answer:
                        # record what arrived, drop the object, and keep the
                        # stream (and the transport) alive.
                        self.skipped.append(str(exc))
                    else:
                        messages.append(value)
                    consumed, self._start = index + 1, None
        self._scan = len(self._buffer) - consumed
        if consumed:
            del self._buffer[:consumed]
            if self._start is not None:
                self._start -= consumed
        return messages


class CreatorMicro2Adapter:
    PROBE_METHODS = ("v.oai.thstatus", "lights.preview")
    # A reply predating this process (or a late Bluetooth echo) can surface
    # just after connect with an id this process never issued. For this long
    # it is stale input, not evidence of a second controller.
    STARTUP_GRACE_SECONDS = 3.0
    # Reports consumed and discarded at connect before the first request.
    STALE_DRAIN_MAX_REPORTS = 64
    # A conflict is retried after this delay; three consecutive re-triggers
    # without a healthy answer in between back off to the longer delay.
    CONFLICT_RETRY_SECONDS = 60.0
    CONFLICT_RETRY_BACKOFF_SECONDS = 600.0
    CONFLICT_RETRY_STREAK = 3

    def __init__(
        self,
        transport: DeviceTransport,
        info: dict[str, Any],
        *,
        capabilities: DeviceCapability | None = None,
        clock: Callable[[], float] = time.monotonic,
        rpc_timeout_ms: int = 8_000,
        reconnect_backoff_s: float = 1.0,
        rpc_max_bytes: int = RpcStreamDecoder.MAX_BUFFER,
    ) -> None:
        self.transport = transport
        self.info = info
        self._capabilities = capabilities or DeviceCapability()
        self._clock = clock
        self._rpc_timeout_ms = max(1, min(rpc_timeout_ms, 8_000))
        self._reconnect_backoff_s = max(0.0, reconnect_backoff_s)
        self._reconnect_at = 0.0
        self._next_id = 1
        self._rpc_max_bytes = CreatorMicro2Framer.bounded_budget(rpc_max_bytes)
        self._decoder = RpcStreamDecoder(max_bytes=self._rpc_max_bytes)
        self._notifications: deque[tuple[float, dict[str, Any]]] = deque(maxlen=128)
        self.last_malformed_notification: str | None = None
        self._status_retry_at = 0.0
        self.conflict = DeviceConflict(clock=clock)
        self.connected = False
        self.connection_generation = 0
        self._connected_at = 0.0
        self._conflict_streak = 0
        self.stale_replies_drained = 0
        self.stale_replies_ignored = 0

    def discover(self) -> bool:
        return CreatorMicro2Framer.discover(self.info)

    def connect(self) -> Receipt:
        if not self.discover():
            return Receipt("no_device", "Creator Micro 2 vendor collection not found")
        if self._clock() < self._reconnect_at:
            return Receipt("backoff", "waiting before reconnect")
        if self.connected:
            return Receipt("connected")
        try:
            self.transport.open(nonexclusive=True)
        except NoDeviceError:
            return Receipt("no_device", "Creator Micro 2 vendor collection not found")
        except PermissionError as exc:
            # The reason travels with the receipt: on real hardware a refused
            # open is the difference between "grant Input Monitoring" and
            # "the pad is unplugged", and the caller cannot see the exception.
            return Receipt(
                getattr(exc, "code", "permission_denied"),
                str(exc) or "Device access or approved identity was refused",
            )
        except (ImportError, OSError) as exc:
            return Receipt("transport_unavailable", str(exc))
        self.connected = True
        self.connection_generation += 1
        self.conflict.reset()
        self._status_retry_at = 0.0
        self._decoder = RpcStreamDecoder(max_bytes=self._rpc_max_bytes)
        self._connected_at = self._clock()
        self._drain_stale_reports()
        return Receipt("connected")

    def _drain_stale_reports(self) -> None:
        """Consume whatever the pad queued before this connection's first request.

        A previous daemon process can leave a request in flight whose late
        reply lands here carrying an id this process never issued, and over
        Bluetooth the pad can answer twice. None of those ids can be ours
        yet, so id-bearing messages are counted and discarded rather than
        fed to the conflict tracker, which would read them as a second
        controller and stop output on a pad nobody else is driving.
        Notifications still queue normally.
        """
        discarded = 0
        for _ in range(self.STALE_DRAIN_MAX_REPORTS):
            try:
                report = self.transport.read(timeout_ms=0)
            except OSError:
                self._disconnect_for_retry()
                break
            if not report:
                break
            try:
                messages = self._decoder.feed(report)
            except ValueError:
                continue
            self._record_skipped_notifications()
            for message in messages:
                if "id" in message:
                    discarded += 1
                else:
                    self._queue_notification(message)
        self.stale_replies_drained += discarded
        if discarded:
            _log.info("Creator Micro 2: discarded %d stale response(s) queued before connect", discarded)

    def recover_conflict(self) -> Receipt:
        """Retry the connection after a conflict instead of stopping for good.

        A late or doubled reply from the pad itself can raise the foreign-id
        accusation, so it is not a lifetime sentence. Until the retry delay
        measured from ``conflict.since`` has elapsed the conflict stays
        active and the receipt keeps saying so; once due, ``close`` and
        ``connect`` reopen the pad and reset the accusation. A conflict that
        keeps re-triggering without a healthy answer in between backs off to
        the longer delay.
        """
        if not self.conflict.active:
            return Receipt("connected") if self.connected else Receipt("not_connected")
        if self.conflict.since is None:
            self.conflict.since = self._clock()
        delay = (
            self.CONFLICT_RETRY_BACKOFF_SECONDS
            if self._conflict_streak >= self.CONFLICT_RETRY_STREAK
            else self.CONFLICT_RETRY_SECONDS
        )
        if self._clock() - self.conflict.since < delay:
            return Receipt("device_conflict", "another client controls the device", recoverable=False)
        self.close()
        # The conflict delay already waited far longer than the ordinary
        # reconnect backoff; do not wait a second delay on top of it.
        self._reconnect_at = 0.0
        return self.connect()

    def capabilities(self) -> DeviceCapability:
        return self._capabilities

    def negotiate_capabilities(self) -> Receipt:
        if not self.connected:
            return Receipt("not_connected")
        supported: set[str] = set()
        for method in self.PROBE_METHODS:
            params: list[Any] | dict[str, Any] = [] if method == "v.oai.thstatus" else {}
            receipt, response = self._call(method, params)
            if receipt.code == "device_conflict":
                return receipt
            if receipt.code not in {"applied", "rpc_error"}:
                return receipt
            error = response.get("error") if response else None
            if isinstance(error, dict):
                if error.get("code") in {-32601, 404}:
                    continue
                return Receipt("capability_probe_failed", method)
            supported.add(method)
        self._capabilities = DeviceCapability.from_methods(supported)
        return Receipt("capabilities_negotiated", ",".join(sorted(supported)))

    def apply(self, state: SemanticState, params: list[Any] | dict[str, Any] | None = None) -> Receipt:
        if not self.connected:
            return Receipt("not_connected")
        if self.conflict.active:
            return Receipt("device_conflict", "another client controls the device", recoverable=False)
        method = "v.oai.thstatus"
        if method not in self._capabilities.methods:
            return Receipt("unsupported_method", method)
        if params is None:
            from .creator_micro_lighting import creator_micro_light_params

            params = creator_micro_light_params(state.value)
        receipt, _ = self._call(method, params)
        return receipt

    def apply_preview(self, frame) -> Receipt:
        """Nonpersistent whole-board fallback, valid without AG keycodes."""
        if not self.connected:
            return Receipt("not_connected")
        if self.conflict.active:
            return Receipt("device_conflict", recoverable=False)
        if not self._capabilities.can_light:
            return Receipt("unsupported_method", "lights.preview")
        side = {"effect": "solid" if frame.brightness else "off", "brightness": frame.brightness,
                "speed": 0.5, "magic": 1, "color": frame.color}
        receipt, _ = self._call("lights.preview", {"backlight": side, "underglow": dict(side)})
        return receipt

    def _call(self, method: str, params: list[Any] | dict[str, Any] | None) -> tuple[Receipt, dict[str, Any] | None]:
        ident = self._next_id
        self._next_id = 0 if ident == 999 else ident + 1
        self.conflict.issued_ids.add(ident)
        request = {"jsonrpc": "2.0", "method": method, "params": params, "id": ident}
        try:
            for report in CreatorMicro2Framer.encode_request(request, max_bytes=self._rpc_max_bytes):
                self.transport.write(report)
        except ValueError:
            self.conflict.issued_ids.discard(ident)
            return Receipt("request_too_large", "request exceeds the bounded RPC budget"), None
        except PermissionError as exc:
            self.conflict.issued_ids.discard(ident)
            return Receipt("write_opt_in_required", str(exc)), None
        except OSError as exc:
            self.conflict.issued_ids.discard(ident)
            self._disconnect_for_retry()
            return Receipt("transport_unavailable", str(exc)), None

        deadline = self._clock() + self._rpc_timeout_ms / 1000
        while self._clock() <= deadline:
            remaining = max(0, min(self._rpc_timeout_ms, int((deadline - self._clock()) * 1000)))
            try:
                report = self.transport.read(timeout_ms=remaining)
            except OSError as exc:
                self.conflict.issued_ids.discard(ident)
                self._disconnect_for_retry()
                return Receipt("transport_unavailable", str(exc)), None
            if not report:
                break
            try:
                messages = self._decoder.feed(report)
            except ValueError as exc:
                self.conflict.issued_ids.discard(ident)
                self._disconnect_for_retry()
                return Receipt("malformed_report", str(exc)), None
            self._record_skipped_notifications()
            response = None
            for message in messages:
                if "id" not in message:
                    self._queue_notification(message)
                    continue
                outcome = self._observe_response_id(message["id"])
                if outcome == "foreign_response_id":
                    return Receipt("device_conflict", "foreign response id", recoverable=False), message
                if outcome in {"duplicate_response_id", "stale_response_id"}:
                    # Our own answer arriving twice, or a reply that predates
                    # this connection: neither is a second controller. Keep
                    # waiting for this call's id.
                    continue
                if message["id"] != ident:
                    # A late answer to an earlier request of ours: observe()
                    # already retired that id. Keep waiting for this call's
                    # answer rather than accusing a second controller.
                    continue
                response = message
            if response is not None:
                # A correlated answer proves we are driving the pad, so any
                # run of consecutive conflicts is over.
                self._conflict_streak = 0
                if "method" in response and response["method"] != method:
                    self._disconnect_for_retry()
                    return Receipt("malformed_report", "response method does not match request"), None
                if "error" in response:
                    return Receipt("rpc_error", str(response["error"])), response
                return Receipt("applied"), response
        self.conflict.issued_ids.discard(ident)
        self._disconnect_for_retry()
        return Receipt("timeout", f"timeout waiting for {method}"), None

    def _observe_response_id(self, response_id: object) -> str | None:
        """Conflict-track one id-bearing message.

        Inside the startup grace a foreign id is a stale reply left by the
        previous process's in-flight request or a late Bluetooth answer: it
        is counted and dropped, not treated as proof of a second controller.
        Past the grace a foreign id remains the only evidence of another
        owner and stays an accusation. Each new accusation lengthens the
        consecutive-conflict streak that backs off ``recover_conflict``.
        """
        was_active = self.conflict.active
        outcome = self.conflict.observe(response_id)
        if outcome != "foreign_response_id":
            return outcome
        if self._clock() - self._connected_at < self.STARTUP_GRACE_SECONDS:
            if not was_active:
                self.conflict.active = False
                self.conflict.since = None
            self.stale_replies_ignored += 1
            if self.stale_replies_ignored == 1:
                _log.info("Creator Micro 2: ignoring a stale response id received within the startup grace")
            return "stale_response_id"
        if not was_active:
            self._conflict_streak += 1
        return outcome

    def _record_skipped_notifications(self) -> None:
        for detail in self._decoder.drain_skipped():
            # The detail reads like a malformed_report receipt but is harmless:
            # an unsolicited push we could not read is nobody's answer. Repeat
            # pushes are recorded but only logged when the shape changes.
            if detail != self.last_malformed_notification:
                _log.warning("Creator Micro 2: %s", detail)
            self.last_malformed_notification = detail

    def _queue_notification(self, message: dict[str, Any]) -> None:
        method = message["m"] if "m" in message else message.get("method")
        params = message["p"] if "p" in message else message.get("params")
        note: dict[str, Any] = {"method": method, "params": params}
        extra = {
            key: item
            for key, item in message.items()
            if key not in {"jsonrpc", "id", "m", "method", "p", "params"}
        }
        if extra:
            note["extra"] = extra
        self._notifications.append((self._clock(), note))

    def poll_inputs(self) -> list[dict[str, Any]]:
        if not self.connected or self.conflict.active:
            self._notifications.clear()
            return []
        if self.connected:
            for _ in range(64):
                try:
                    report = self.transport.read(timeout_ms=0)
                except OSError:
                    self._disconnect_for_retry()
                    break
                if not report:
                    break
                try:
                    messages = self._decoder.feed(report)
                except ValueError:
                    continue
                self._record_skipped_notifications()
                for message in messages:
                    if "id" in message:
                        self._observe_response_id(message["id"])
                    else:
                        self._queue_notification(message)
                if self.conflict.active:
                    break
        output = (
            [note for received, note in self._notifications if 0 <= self._clock() - received <= 0.5]
            if self.connected and not self.conflict.active else []
        )
        self._notifications.clear()
        return output

    def query_status(self) -> dict[str, Any] | None:
        """``device.status`` result, or None when it cannot be trusted.

        The call shares the single-writer generation and conflict rules with
        output writes; a failed answer is not retried on the next tick, it is
        retried after a long pause so a firmware without the method does not
        keep an 8-second RPC on the input path.
        """
        if not self.connected or self.conflict.active or self._clock() < self._status_retry_at:
            return None
        receipt, response = self._call("device.status", {})
        result = (response or {}).get("result") if receipt.code == "applied" else None
        if not isinstance(result, dict):
            self._status_retry_at = self._clock() + 30.0
            return None
        return result

    def _disconnect_for_retry(self) -> None:
        self._notifications.clear()
        if self.connected:
            try:
                self.transport.close()
            finally:
                self.connected = False
        self._reconnect_at = self._clock() + self._reconnect_backoff_s

    def close(self) -> None:
        self._notifications.clear()
        if self.connected:
            try:
                self.transport.close()
            finally:
                self.connected = False
        self.conflict.reset()
