"""Strict, content-bounded wire protocol for ordered hook admission."""

from __future__ import annotations

import json
import math
import os
import socket
import stat
import struct
import time
from collections.abc import Callable
from dataclasses import dataclass, field
from enum import Enum
from pathlib import Path
from typing import Final

from .state_paths import candidate_state_dirs, default_state_dir

HOOK_INGRESS_SOCKET_NAME: Final = "hook-ingress.sock"
HOOK_INGRESS_PROTOCOL_VERSION: Final = 1
HOOK_INGRESS_SEND_TIMEOUT_SECONDS: Final = 0.03
MAX_HOOK_INGRESS_PAYLOAD_BYTES: Final = 1024 * 1024
MAX_HOOK_INGRESS_HEADER_BYTES: Final = 8 * 1024
MAX_HOOK_INGRESS_WIRE_BYTES: Final = (
    MAX_HOOK_INGRESS_PAYLOAD_BYTES + MAX_HOOK_INGRESS_HEADER_BYTES + 32
)
MAX_HOOK_INGRESS_RESPONSE_BYTES: Final = 64
MAX_HOOK_LOG_PATH_BYTES: Final = 4096

_MAGIC: Final = b"JRBARHOOK\x01"
_LENGTHS = struct.Struct("!II")
_HEADER_FIELDS: Final = frozenset({"version", "provider", "log_path"})
# Set by the compiled shim (hook/jrbar-hook.c): the hook process' parent
# pid and that process' start time, so the daemon can register the agent
# process itself instead of forking `ps` inside the hook. ``decide_ms`` is
# the decide lane's: the shim runs as ``--decide`` on a PermissionRequest
# hook and will wait that long for the daemon's verdict line.
_OPTIONAL_HEADER_FIELDS: Final = frozenset({"ppid", "ppid_start", "decide_ms"})
MAX_HOOK_PPID: Final = 2**31 - 1
# How long a ``--decide`` hook waits for the verdict after its payload is in
# hand. The hook entries are installed with a 60 s provider timeout, so the
# shim always gives up first and the agent never cancels it mid-read; the
# daemon holds a request for less than this (answer_decisions.py).
HOOK_DECISION_WAIT_MS: Final = 50_000
MIN_HOOK_DECISION_WAIT_MS: Final = 1_000
MAX_HOOK_DECISION_WAIT_MS: Final = 60_000
# The verdict line: the provider's own hookSpecificOutput document. An
# "always allow" echoes the request's permission suggestions, which are a
# few hundred bytes; the bound is only there so a runaway can't be printed.
MAX_HOOK_DECISION_BYTES: Final = 64 * 1024
_DECISION_PREFIX: Final = b'{"hookSpecificOutput":'
_HOOK_PROVIDERS: Final = frozenset(
    {
        "antigravity",
        "claude",
        "codex",
        "cursor",
        "devin",
        "grok",
        "gemini",
        "hermes",
        "kiro",
        "openclaw",
        "opencode",
        "pi",
    }
)


class HookIngressDisposition(str, Enum):
    ACCEPTED = "accepted"
    REFUSED_FULL = "refused_full"
    REFUSED_CLOSED = "refused_closed"
    REFUSED_INVALID = "refused_invalid"
    SUBMISSION_AMBIGUOUS = "submission_ambiguous"
    UNAVAILABLE = "unavailable"


@dataclass(frozen=True, slots=True)
class HookIngressRequest:
    provider: str
    log_path: str
    payload_text: str = field(repr=False)
    ppid: int | None = None
    ppid_start: float | None = None
    # When the shim spooled this payload (hook_pending); never on the wire,
    # where the daemon's own arrival time is the event's time.
    queued_at_epoch: float | None = None
    # How long the sender will wait for a verdict line, when it is a
    # ``--decide`` hook. ``None`` is every other hook: one disposition line.
    decide_ms: int | None = None

    def __post_init__(self) -> None:
        if self.ppid is not None and (
            type(self.ppid) is not int or self.ppid <= 1 or self.ppid > MAX_HOOK_PPID
        ):
            raise ValueError("invalid hook ingress request")
        if self.decide_ms is not None and (
            type(self.decide_ms) is not int
            or not MIN_HOOK_DECISION_WAIT_MS <= self.decide_ms <= MAX_HOOK_DECISION_WAIT_MS
        ):
            raise ValueError("invalid hook ingress request")
        if self.queued_at_epoch is not None and (
            isinstance(self.queued_at_epoch, bool)
            or not isinstance(self.queued_at_epoch, (int, float))
            or not math.isfinite(float(self.queued_at_epoch))
            or float(self.queued_at_epoch) <= 0.0
        ):
            raise ValueError("invalid hook ingress request")
        if self.ppid_start is not None and (
            isinstance(self.ppid_start, bool)
            or not isinstance(self.ppid_start, (int, float))
            or not math.isfinite(float(self.ppid_start))
            or float(self.ppid_start) < 0.0
        ):
            raise ValueError("invalid hook ingress request")
        if (
            type(self.provider) is not str
            or self.provider not in _HOOK_PROVIDERS
            or type(self.log_path) is not str
            or not self.log_path
            or not Path(self.log_path).is_absolute()
            or len(self.log_path.encode("utf-8")) > MAX_HOOK_LOG_PATH_BYTES
            or any(ord(character) < 32 for character in self.log_path)
            or type(self.payload_text) is not str
        ):
            raise ValueError("invalid hook ingress request")
        try:
            payload_size = len(self.payload_text.encode("utf-8"))
        except UnicodeEncodeError as exc:
            raise ValueError("invalid hook ingress request") from exc
        if payload_size > MAX_HOOK_INGRESS_PAYLOAD_BYTES:
            raise ValueError("invalid hook ingress request")


def default_hook_ingress_socket_path() -> Path:
    return default_state_dir() / HOOK_INGRESS_SOCKET_NAME


def candidate_hook_ingress_socket_paths() -> tuple[Path, ...]:
    return tuple(path / HOOK_INGRESS_SOCKET_NAME for path in candidate_state_dirs())


def _strict_object(pairs: list[tuple[object, object]]) -> dict[object, object]:
    result: dict[object, object] = {}
    for key, value in pairs:
        if type(key) is not str or key in result:
            raise ValueError("invalid hook ingress header")
        result[key] = value
    return result


def _reject_constant(_value: str) -> None:
    raise ValueError("invalid hook ingress header")


def encode_hook_ingress_request(request: HookIngressRequest) -> bytes:
    if type(request) is not HookIngressRequest:
        raise ValueError("invalid hook ingress request")
    document: dict[str, object] = {
        "version": HOOK_INGRESS_PROTOCOL_VERSION,
        "provider": request.provider,
        "log_path": request.log_path,
    }
    if request.ppid is not None:
        document["ppid"] = request.ppid
    if request.ppid_start is not None:
        document["ppid_start"] = float(request.ppid_start)
    if request.decide_ms is not None:
        document["decide_ms"] = request.decide_ms
    header = json.dumps(
        document,
        ensure_ascii=False,
        separators=(",", ":"),
        sort_keys=True,
    ).encode("utf-8")
    payload = request.payload_text.encode("utf-8")
    if len(header) > MAX_HOOK_INGRESS_HEADER_BYTES:
        raise ValueError("invalid hook ingress request")
    encoded = _MAGIC + _LENGTHS.pack(len(header), len(payload)) + header + payload
    if len(encoded) > MAX_HOOK_INGRESS_WIRE_BYTES:
        raise ValueError("invalid hook ingress request")
    return encoded


def decode_hook_ingress_request(payload: bytes) -> HookIngressRequest | None:
    if type(payload) is not bytes or not payload.startswith(_MAGIC):
        return None
    lengths_at = len(_MAGIC)
    header_at = lengths_at + _LENGTHS.size
    if len(payload) < header_at:
        return None
    try:
        header_size, body_size = _LENGTHS.unpack(payload[lengths_at:header_at])
    except struct.error:
        return None
    if (
        header_size <= 0
        or header_size > MAX_HOOK_INGRESS_HEADER_BYTES
        or body_size > MAX_HOOK_INGRESS_PAYLOAD_BYTES
        or len(payload) != header_at + header_size + body_size
        or len(payload) > MAX_HOOK_INGRESS_WIRE_BYTES
    ):
        return None
    header_end = header_at + header_size
    try:
        document = json.loads(
            payload[header_at:header_end].decode("utf-8"),
            object_pairs_hook=_strict_object,
            parse_constant=_reject_constant,
        )
        body = payload[header_end:].decode("utf-8")
    except (TypeError, UnicodeError, ValueError):
        return None
    if (
        type(document) is not dict
        or not _HEADER_FIELDS <= frozenset(document)
        or not frozenset(document) <= _HEADER_FIELDS | _OPTIONAL_HEADER_FIELDS
        or type(document["version"]) is not int
        or document["version"] != HOOK_INGRESS_PROTOCOL_VERSION
        or type(document["provider"]) is not str
        or type(document["log_path"]) is not str
    ):
        return None
    ppid = document.get("ppid")
    ppid_start = document.get("ppid_start")
    decide_ms = document.get("decide_ms")
    if ppid is not None and type(ppid) is not int:
        return None
    if ppid_start is not None and (
        type(ppid_start) not in (int, float) or not math.isfinite(float(ppid_start))
    ):
        return None
    if decide_ms is not None and type(decide_ms) is not int:
        return None
    try:
        return HookIngressRequest(
            document["provider"],
            document["log_path"],
            body,
            ppid=ppid,
            ppid_start=None if ppid_start is None else float(ppid_start),
            decide_ms=decide_ms,
        )
    except ValueError:
        return None


def encode_hook_ingress_response(disposition: HookIngressDisposition) -> bytes:
    if disposition not in {
        HookIngressDisposition.ACCEPTED,
        HookIngressDisposition.REFUSED_FULL,
        HookIngressDisposition.REFUSED_CLOSED,
        HookIngressDisposition.REFUSED_INVALID,
    }:
        raise ValueError("invalid hook ingress response")
    return f"{disposition.value}\n".encode("ascii")


def decode_hook_ingress_response(payload: bytes) -> HookIngressDisposition:
    if type(payload) is not bytes or len(payload) > MAX_HOOK_INGRESS_RESPONSE_BYTES:
        return HookIngressDisposition.UNAVAILABLE
    try:
        text = payload.decode("ascii")
    except UnicodeDecodeError:
        return HookIngressDisposition.UNAVAILABLE
    for disposition in (
        HookIngressDisposition.ACCEPTED,
        HookIngressDisposition.REFUSED_FULL,
        HookIngressDisposition.REFUSED_CLOSED,
        HookIngressDisposition.REFUSED_INVALID,
    ):
        if text == f"{disposition.value}\n":
            return disposition
    return HookIngressDisposition.UNAVAILABLE


def encode_hook_decision(document: object) -> bytes:
    """The verdict line a ``--decide`` hook prints: the provider's own
    ``{"hookSpecificOutput": ...}`` document, compact, on one line."""
    if type(document) is not dict or set(document) != {"hookSpecificOutput"}:
        raise ValueError("invalid hook decision")
    encoded = json.dumps(document, ensure_ascii=True, separators=(",", ":")).encode("ascii")
    if not encoded.startswith(_DECISION_PREFIX) or len(encoded) + 1 > MAX_HOOK_DECISION_BYTES:
        raise ValueError("invalid hook decision")
    return encoded + b"\n"


def decode_hook_decision(payload: bytes) -> str | None:
    """What a ``--decide`` hook may print from the bytes after the
    disposition line, or ``None``: a whole line, bounded, and a
    hookSpecificOutput document. Anything else prints nothing, so the agent
    falls through to its own prompt."""
    if type(payload) is not bytes or not payload.endswith(b"\n"):
        return None
    line = payload[:-1]
    if b"\n" in line or len(payload) > MAX_HOOK_DECISION_BYTES or not line.startswith(_DECISION_PREFIX):
        return None
    try:
        document = json.loads(line.decode("ascii"), object_pairs_hook=_strict_object)
    except (UnicodeDecodeError, ValueError):
        return None
    if type(document) is not dict or set(document) != {"hookSpecificOutput"}:
        return None
    return line.decode("ascii")


def _valid_timeout(value: object) -> bool:
    return (
        isinstance(value, (int, float))
        and not isinstance(value, bool)
        and math.isfinite(float(value))
        and 0.0 < float(value) <= 1.0
    )


def _trusted_socket_leaf(path: Path) -> bool:
    try:
        info = path.lstat()
    except OSError:
        return False
    return bool(
        stat.S_ISSOCK(info.st_mode)
        and not stat.S_ISLNK(info.st_mode)
        and info.st_uid == os.geteuid()
        and info.st_nlink == 1
    )


def submit_hook_ingress(
    request: HookIngressRequest,
    *,
    socket_path: Path | None = None,
    timeout_seconds: float = HOOK_INGRESS_SEND_TIMEOUT_SECONDS,
    socket_factory: Callable[..., socket.socket] = socket.socket,
    require_socket_leaf: bool = True,
) -> HookIngressDisposition:
    encoded = encode_hook_ingress_request(request)
    if not _valid_timeout(timeout_seconds):
        raise ValueError("invalid hook ingress timeout")
    if not callable(socket_factory) or type(require_socket_leaf) is not bool:
        raise ValueError("invalid hook ingress dependency")
    targets = (
        (Path(socket_path).expanduser(),)
        if socket_path is not None
        else candidate_hook_ingress_socket_paths()
    )
    for target in targets:
        if require_socket_leaf and not _trusted_socket_leaf(target):
            continue
        client = None
        connected = False
        try:
            client = socket_factory(socket.AF_UNIX, socket.SOCK_STREAM)
            client.settimeout(float(timeout_seconds))
            client.connect(str(target))
            connected = True
            client.sendall(encoded)
            client.shutdown(socket.SHUT_WR)
            response = client.recv(MAX_HOOK_INGRESS_RESPONSE_BYTES + 1)
            disposition = decode_hook_ingress_response(response)
            if disposition is not HookIngressDisposition.UNAVAILABLE:
                return disposition
            return HookIngressDisposition.SUBMISSION_AMBIGUOUS
        except Exception:
            if connected:
                return HookIngressDisposition.SUBMISSION_AMBIGUOUS
            continue
        finally:
            if client is not None:
                try:
                    client.close()
                except Exception:
                    pass
    return HookIngressDisposition.UNAVAILABLE


def submit_hook_ingress_for_decision(
    request: HookIngressRequest,
    *,
    socket_path: Path | None = None,
    timeout_seconds: float = HOOK_INGRESS_SEND_TIMEOUT_SECONDS,
    socket_factory: Callable[..., socket.socket] = socket.socket,
    require_socket_leaf: bool = True,
    monotonic: Callable[[], float] = time.monotonic,
) -> tuple[HookIngressDisposition, str | None]:
    """``submit_hook_ingress`` for a ``--decide`` hook: the same frame, then
    the wait for the verdict line, bounded by ``request.decide_ms``.

    Returns the disposition and the line to print, or ``None`` for "print
    nothing" -- the daemon let the hold lapse, released it, or never
    parked the request. Every failure after the frame is sent is a
    ``None`` verdict, never a retry: the agent's own prompt is the
    fallback, and it only appears once this hook has returned.
    """
    if type(request) is not HookIngressRequest or request.decide_ms is None:
        raise ValueError("invalid hook ingress decision request")
    encoded = encode_hook_ingress_request(request)
    if not _valid_timeout(timeout_seconds):
        raise ValueError("invalid hook ingress timeout")
    deadline = monotonic() + request.decide_ms / 1000.0
    targets = (
        (Path(socket_path).expanduser(),)
        if socket_path is not None
        else candidate_hook_ingress_socket_paths()
    )
    for target in targets:
        if require_socket_leaf and not _trusted_socket_leaf(target):
            continue
        client = None
        connected = False
        try:
            client = socket_factory(socket.AF_UNIX, socket.SOCK_STREAM)
            client.settimeout(float(timeout_seconds))
            client.connect(str(target))
            connected = True
            client.sendall(encoded)
            client.shutdown(socket.SHUT_WR)
            received = b""
            while len(received) <= MAX_HOOK_INGRESS_RESPONSE_BYTES + MAX_HOOK_DECISION_BYTES:
                remaining = deadline - monotonic()
                if remaining <= 0.0:
                    break
                client.settimeout(remaining)
                chunk = client.recv(65536)
                if not chunk:
                    break
                received += chunk
            head, newline, rest = received.partition(b"\n")
            disposition = decode_hook_ingress_response(head + newline)
            if disposition is HookIngressDisposition.UNAVAILABLE:
                return HookIngressDisposition.SUBMISSION_AMBIGUOUS, None
            return disposition, decode_hook_decision(rest)
        except Exception:
            if connected:
                return HookIngressDisposition.SUBMISSION_AMBIGUOUS, None
            continue
        finally:
            if client is not None:
                try:
                    client.close()
                except Exception:
                    pass
    return HookIngressDisposition.UNAVAILABLE, None


__all__ = [
    "HOOK_DECISION_WAIT_MS",
    "HOOK_INGRESS_PROTOCOL_VERSION",
    "HOOK_INGRESS_SEND_TIMEOUT_SECONDS",
    "HOOK_INGRESS_SOCKET_NAME",
    "MAX_HOOK_DECISION_BYTES",
    "MAX_HOOK_DECISION_WAIT_MS",
    "MAX_HOOK_INGRESS_PAYLOAD_BYTES",
    "MAX_HOOK_INGRESS_RESPONSE_BYTES",
    "MAX_HOOK_INGRESS_WIRE_BYTES",
    "MIN_HOOK_DECISION_WAIT_MS",
    "HookIngressDisposition",
    "HookIngressRequest",
    "candidate_hook_ingress_socket_paths",
    "decode_hook_decision",
    "decode_hook_ingress_request",
    "decode_hook_ingress_response",
    "default_hook_ingress_socket_path",
    "encode_hook_decision",
    "encode_hook_ingress_request",
    "encode_hook_ingress_response",
    "submit_hook_ingress",
    "submit_hook_ingress_for_decision",
]
