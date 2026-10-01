"""Thin hook admission entry point with a synchronous fail-open fallback."""

from __future__ import annotations

import re
import sys
from collections.abc import Callable
from pathlib import Path
from typing import Final

from .hook_ingress_protocol import (
    HOOK_DECISION_WAIT_MS,
    MAX_HOOK_INGRESS_PAYLOAD_BYTES,
    HookIngressDisposition,
    HookIngressRequest,
    submit_hook_ingress,
    submit_hook_ingress_for_decision,
)

# Admission never proven: the payload may not have reached the daemon.
_UNPROVEN_DISPOSITIONS = frozenset(
    {HookIngressDisposition.UNAVAILABLE, HookIngressDisposition.SUBMISSION_AMBIGUOUS}
)
# A daemon that heard the payload and could not take it: its queue was
# full, or it was shutting down. It never processes a payload it refused.
_REFUSED_FOR_LATER = frozenset(
    {HookIngressDisposition.REFUSED_FULL, HookIngressDisposition.REFUSED_CLOSED}
)


def _synchronous_fallback(provider: str, log_path: Path, payload_text: str) -> None:
    from .hook import process_hook_payload

    process_hook_payload(provider, log_path, payload_text)


def _spool(provider: str, log_path: Path, payload_text: str) -> None:
    """Queue a refused payload where the compiled shim queues it; the
    daemon drains ``<provider>.pending.jsonl`` behind what its queue still
    holds (hook_pending). A spool that cannot be written falls back to
    processing it here: late and out of order beats lost."""
    from .hook_pending import spool_pending_hook

    if not spool_pending_hook(provider, payload_text):
        _synchronous_fallback(provider, log_path, payload_text)


def run_hook_client(
    provider: str,
    log_path: Path,
    payload_text: str,
    *,
    submit: Callable[[HookIngressRequest], HookIngressDisposition] = submit_hook_ingress,
    fallback: Callable[[str, Path, str], object] = _synchronous_fallback,
    spool: Callable[[str, Path, str], object] = _spool,
) -> int:
    try:
        request = HookIngressRequest(provider, str(Path(log_path).expanduser()), payload_text)
    except (TypeError, ValueError):
        return 0

    # Only the hook process can see which agent spawned it. Register that
    # process before handing the payload to the app, so the app can later
    # notice the agent is gone even when no hook ever says so.
    try:
        from .process_registry import note_hook_payload

        note_hook_payload(provider, payload_text)
    except Exception:
        pass

    try:
        disposition = submit(request)
        # UNAVAILABLE means the payload never left this process.
        # SUBMISSION_AMBIGUOUS means the ack was lost after connect: the
        # ingress MAY have queued it, but "maybe" is not a delivery
        # guarantee for a turn boundary. Falling back re-processes the
        # same payload through the dedupe-checked path, so the worst case
        # is a suppressed duplicate -- the other direction is a silent
        # drop, which is the failure this file exists to prevent.
        if disposition in _UNPROVEN_DISPOSITIONS:
            fallback(provider, Path(log_path).expanduser(), payload_text)
        # A refusal is never processed here, where it would land ahead of
        # everything the full queue still holds: it is spooled, and the
        # drain replays it behind them once the queue is empty.
        elif disposition in _REFUSED_FOR_LATER:
            spool(provider, Path(log_path).expanduser(), payload_text)
    except Exception:
        try:
            fallback(provider, Path(log_path).expanduser(), payload_text)
        except Exception:
            pass
    return 0


def run_decide_hook_client(
    provider: str,
    log_path: Path,
    payload_text: str,
    *,
    submit: Callable[
        [HookIngressRequest], tuple[HookIngressDisposition, str | None]
    ] = submit_hook_ingress_for_decision,
    fallback: Callable[[str, Path, str], object] = _synchronous_fallback,
    spool: Callable[[str, Path, str], object] = _spool,
) -> str | None:
    """``run_hook_client`` for the decide lane: the verdict line to print,
    or ``None`` for "print nothing" (the agent's own prompt carries on).

    The same admission, fallback and spool as every other hook; the only
    addition is that an accepted frame waits for the daemon's verdict, as
    the compiled shim's ``--decide`` does (hook/jrbar-hook.c). A daemon that
    is down gets the payload through the synchronous fallback, and one that
    refused it through the spool; neither gets a verdict: nothing can be
    decided without it.
    """
    try:
        request = HookIngressRequest(
            provider,
            str(Path(log_path).expanduser()),
            payload_text,
            decide_ms=HOOK_DECISION_WAIT_MS,
        )
    except (TypeError, ValueError):
        return None
    try:
        from .process_registry import note_hook_payload

        note_hook_payload(provider, payload_text)
    except Exception:
        pass
    try:
        disposition, verdict = submit(request)
    except Exception:
        disposition, verdict = HookIngressDisposition.UNAVAILABLE, None
    if disposition in _UNPROVEN_DISPOSITIONS:
        try:
            fallback(provider, Path(log_path).expanduser(), payload_text)
        except Exception:
            pass
        return None
    if disposition in _REFUSED_FOR_LATER:
        try:
            spool(provider, Path(log_path).expanduser(), payload_text)
        except Exception:
            pass
        return None
    return verdict if disposition is HookIngressDisposition.ACCEPTED else None


# ---- A payload past MAX_HOOK_INGRESS_PAYLOAD_BYTES --------------------------
#
# The same small record the compiled shim sends in its place
# (hook/jrbar-hook.c, ``build_metadata``), for Claude and Codex: the event, the
# session, the tool, and ``"payload_truncated":true``, found by one scan over
# the first MiB. The scan walks the top-level object only and steps over every
# value it does not want, so a key spelled inside a tool's output is never
# taken for a top-level one. Values are plain printable ASCII of bounded
# length, copied verbatim; the call's own ``tool_input`` is kept when it is a
# whole object of at most ``_RECORD_INPUT_BYTES``, and otherwise a 64-bit
# FNV-1a fingerprint of its first ``_RECORD_INPUT_BYTES`` names the call. Keep
# the two in step: tests/test_hook_client_oversize.py feeds both the same
# payloads and compares what they make.

_RECORD_PROVIDERS: Final = frozenset({"claude", "codex"})
_RECORD_VALUE_BYTES: Final = 256
_RECORD_PATH_BYTES: Final = 1024
_RECORD_INPUT_BYTES: Final = 64 * 1024
_RECORD_BYTES: Final = _RECORD_INPUT_BYTES + 4096
# In the order they are written; the first two are required.
_RECORD_KEYS: Final = (
    (b"hook_event_name", _RECORD_VALUE_BYTES),
    (b"session_id", _RECORD_VALUE_BYTES),
    (b"tool_name", _RECORD_VALUE_BYTES),
    (b"turn_id", _RECORD_VALUE_BYTES),
    (b"agent_id", _RECORD_VALUE_BYTES),
    (b"transcript_path", _RECORD_PATH_BYTES),
)
_WHITESPACE: Final = b" \t\n\r"
_STRING_EDGE: Final = re.compile(rb'["\\]')
_STRUCTURE: Final = re.compile(rb'["{}\[\]]')
_SCALAR_END: Final = re.compile(rb"[,}\] \t\n\r]")
_PLAIN_ASCII: Final = re.compile(rb"[\x20-\x5b\x5d-\x7e]+")
_FNV_OFFSET: Final = 0xCBF29CE484222325
_FNV_PRIME: Final = 0x100000001B3


def _skip_whitespace(head: bytes, i: int, n: int) -> int:
    while i < n and head[i] in _WHITESPACE:
        i += 1
    return i


def _skip_string(head: bytes, i: int, n: int) -> int:
    """``i`` is at an opening quote: the index after the closing one, or 0
    when the head ends first."""
    i += 1
    while i < n:
        edge = _STRING_EDGE.search(head, i, n)
        if edge is None:
            return 0
        at = edge.start()
        if head[at] == 0x22:
            return at + 1
        if at + 1 >= n:
            return 0
        i = at + 2
    return 0


def _skip_value(head: bytes, i: int, n: int) -> int:
    """The index after the value at ``i``, or 0 when the head ends inside it."""
    if i >= n:
        return 0
    first = head[i]
    if first == 0x22:
        return _skip_string(head, i, n)
    if first in (0x7B, 0x5B):
        depth = 0
        while i < n:
            edge = _STRUCTURE.search(head, i, n)
            if edge is None:
                return 0
            at = edge.start()
            mark = head[at]
            if mark == 0x22:
                i = _skip_string(head, at, n)
                if not i:
                    return 0
                continue
            i = at + 1
            if mark in (0x7B, 0x5B):
                depth += 1
            else:
                depth -= 1
                if depth == 0:
                    return i
        return 0
    end = _SCALAR_END.search(head, i, n)
    return end.start() if end is not None else 0


def _fnv1a64(data: bytes) -> int:
    value = _FNV_OFFSET
    for byte in data:
        value = ((value ^ byte) * _FNV_PRIME) & 0xFFFFFFFFFFFFFFFF
    return value


def oversize_payload_record(head: bytes) -> str | None:
    """The record that stands in for a payload past the cap, from its first
    MiB; ``None`` when the head does not name both the event and the session
    (the daemon could not place it) or the record is not valid text."""
    n = len(head)
    kept: list[bytes | None] = [None] * len(_RECORD_KEYS)
    seen = [False] * len(_RECORD_KEYS)
    tool_input: bytes | None = None
    fingerprint: int | None = None
    input_seen = False
    i = _skip_whitespace(head, 0, n)
    if i >= n or head[i] != 0x7B:
        return None
    i += 1
    while True:
        i = _skip_whitespace(head, i, n)
        if i >= n or head[i] == 0x7D:
            break
        if head[i] == 0x2C:
            i += 1
            continue
        if head[i] != 0x22:
            break
        after_key = _skip_string(head, i, n)
        if not after_key:
            break
        key = head[i + 1 : after_key - 1]
        i = _skip_whitespace(head, after_key, n)
        if i >= n or head[i] != 0x3A:
            break
        i = _skip_whitespace(head, i + 1, n)
        if i >= n:
            break
        end = _skip_value(head, i, n)
        is_input = key == b"tool_input"
        if is_input and not input_seen:
            input_seen = True
            if head[i] == 0x7B:
                # A value the head ends inside runs to the end of the head.
                span = end - i if end else n - i
                if end and span <= _RECORD_INPUT_BYTES:
                    tool_input = head[i : i + span]
                else:
                    fingerprint = _fnv1a64(head[i : i + min(span, _RECORD_INPUT_BYTES)])
        if not end:
            break
        if not is_input:
            for slot, (name, cap) in enumerate(_RECORD_KEYS):
                if key != name:
                    continue
                if seen[slot]:
                    break
                seen[slot] = True
                if head[i] != 0x22:
                    break
                value = head[i + 1 : end - 1]
                if not value or len(value) > cap:
                    break
                if _PLAIN_ASCII.fullmatch(value):
                    kept[slot] = value
                break
        i = end
    if kept[0] is None or kept[1] is None:
        return None
    members = [b'"%b":"%b"' % (name, value) for (name, _), value in zip(_RECORD_KEYS, kept) if value is not None]
    record = b"{" + b",".join(members)
    if tool_input is not None:
        record += b',"tool_input":' + tool_input
    if fingerprint is not None:
        record += b',"payload_fingerprint":"%016x"' % fingerprint
    record += b',"payload_truncated":true}'
    if len(record) >= _RECORD_BYTES:
        return None
    try:
        return record.decode("utf-8", errors="strict")
    except UnicodeDecodeError:
        return None


def _read_bounded_payload(provider: str = "") -> tuple[str | None, bool]:
    """The hook's stdin as text, and whether that text is the record standing
    in for a payload past the cap (``None`` when there is nothing to send).

    Never more than the cap and one byte is read: a payload past it is not
    buffered, only its head is scanned for the record."""
    try:
        payload = sys.stdin.buffer.read(MAX_HOOK_INGRESS_PAYLOAD_BYTES + 1)
    except (AttributeError, OSError):
        return None, False
    if len(payload) > MAX_HOOK_INGRESS_PAYLOAD_BYTES:
        if provider not in _RECORD_PROVIDERS:
            return None, False
        record = oversize_payload_record(payload)
        return record, record is not None
    try:
        return payload.decode("utf-8", errors="strict"), False
    except UnicodeDecodeError:
        return None, False


def hook_client_main(provider: str, log_path: Path, *, decide: bool = False) -> int:
    try:
        payload_text, is_record = _read_bounded_payload(provider)
        if payload_text is None:
            return 0
        # A record stands in for an ask whose input cannot be shown, so it is
        # never held for a verdict: it goes as an ordinary hook and nothing
        # is printed (hook/jrbar-hook.c does the same).
        if decide and not is_record:
            verdict = run_decide_hook_client(provider, Path(log_path).expanduser(), payload_text)
            if verdict is not None:
                try:
                    sys.stdout.write(verdict + "\n")
                    sys.stdout.flush()
                except Exception:
                    pass
            return 0
        return run_hook_client(provider, Path(log_path).expanduser(), payload_text)
    finally:
        # Cursor and Gemini CLI read a hook's stdout as its JSON verdict;
        # "{}" is the documented no-op.
        if provider in ("cursor", "gemini"):
            try:
                sys.stdout.write("{}\n")
                sys.stdout.flush()
            except Exception:
                pass


def main(argv: list[str] | None = None) -> int:
    args = list(sys.argv[1:] if argv is None else argv)
    try:
        provider = args[args.index("--provider") + 1]
        log_path = Path(args[args.index("--log") + 1]).expanduser()
    except (ValueError, IndexError):
        return 0

    return hook_client_main(provider, log_path, decide="--decide" in args)


if __name__ == "__main__":
    raise SystemExit(main())


__all__ = [
    "hook_client_main",
    "main",
    "oversize_payload_record",
    "run_decide_hook_client",
    "run_hook_client",
]
