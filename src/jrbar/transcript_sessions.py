"""Transcript fallback readers for the providers whose session logs are
plain JSONL: pi (``~/.pi/agent/sessions/**/*.jsonl``) and Gemini CLI
(``~/.gemini/tmp/<project>/chats/session-*.jsonl``).

Same contract as ``iter_claude_transcript_file``: a bounded read of the
newest lines, one canonical ``HookEvent`` per row that means something
(prompt, tool call, tool result, turn end), stamped from the row's own
timestamp, ``raw["source"]`` naming the transcript provider so the live
monitor treats them as fallback observations. Nothing here follows a
hook; these are read only when the matching ``transcript_monitoring``
switch is on and stand in for hooks that never fired.
"""

from __future__ import annotations

import json
import re
from collections.abc import Iterable
from datetime import datetime, timezone
from pathlib import Path
from typing import Any, Final

from .models import HookEvent, parse_datetime

PI_TRANSCRIPT_PROVIDER: Final = "pi-transcripts"
GEMINI_TRANSCRIPT_PROVIDER: Final = "gemini-transcripts"
PI_TRANSCRIPT_MAX_FILES: Final = 12
GEMINI_TRANSCRIPT_MAX_FILES: Final = 12
TRANSCRIPT_MAX_LINES: Final = 400
_MAX_LINE_BYTES: Final = 256 * 1024
_UUID = re.compile(r"([0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12})", re.IGNORECASE)


def default_pi_sessions_root(home: Path | None = None) -> Path:
    return (home or Path.home()) / ".pi" / "agent" / "sessions"


def default_gemini_chats_root(home: Path | None = None) -> Path:
    return (home or Path.home()) / ".gemini" / "tmp"


def _string(value: object) -> str | None:
    return value.strip() if isinstance(value, str) and value.strip() else None


def _stamp(value: object, fallback: datetime) -> datetime:
    if isinstance(value, (int, float)) and not isinstance(value, bool):
        seconds = float(value) / (1000.0 if float(value) > 1e11 else 1.0)
        try:
            return datetime.fromtimestamp(seconds, timezone.utc)
        except (OverflowError, OSError, ValueError):
            return fallback
    if isinstance(value, str) and value:
        try:
            return parse_datetime(value)
        except Exception:
            return fallback
    return fallback


def _mtime(path: Path) -> datetime:
    try:
        return datetime.fromtimestamp(path.stat().st_mtime, timezone.utc)
    except OSError:
        return datetime.now(timezone.utc)


def _recent_lines(path: Path, max_lines: int) -> list[str]:
    """The last ``max_lines`` lines, read from the tail without loading a
    long session into memory; over-long lines are dropped."""
    try:
        size = path.stat().st_size
    except OSError:
        return []
    chunk = 64 * 1024
    data = b""
    position = size
    try:
        with path.open("rb") as handle:
            while position > 0 and data.count(b"\n") <= max_lines:
                step = min(chunk, position)
                position -= step
                handle.seek(position)
                data = handle.read(step) + data
                if len(data) > _MAX_LINE_BYTES * 8:
                    break
    except OSError:
        return []
    lines = data.decode("utf-8", errors="replace").splitlines()
    if position > 0 and lines:
        lines = lines[1:]  # a partial first line
    return [line for line in lines[-max_lines:] if len(line) <= _MAX_LINE_BYTES]


def _text_of(content: object) -> str | None:
    if isinstance(content, str):
        return _string(content)
    if isinstance(content, list):
        parts = []
        for block in content:
            if isinstance(block, dict) and block.get("type") in (None, "text") and isinstance(block.get("text"), str):
                parts.append(block["text"])
        return _string("\n".join(parts))
    return None


def _event(provider: str, source: str, name: str, *, session_id: str, cwd: str | None, at: datetime, path: Path, **extra: Any) -> HookEvent:
    raw: dict[str, Any] = {
        "hook_event_name": name,
        "session_id": session_id,
        "cwd": cwd,
        "transcript_path": str(path),
        "source": source,
    }
    raw.update({key: value for key, value in extra.items() if value is not None})
    return HookEvent(
        provider=provider,
        logged_at=at,
        event_name=name,
        raw=raw,
        session_id=session_id,
        cwd=cwd,
        tool_name=extra.get("tool_name"),
        message=extra.get("prompt") or extra.get("last_assistant_message"),
    )


# --- pi -----------------------------------------------------------------------


def pi_session_header(path: Path) -> dict[str, Any] | None:
    """The first line when it is a ``{"type": "session", ...}`` header."""
    try:
        with path.open("r", encoding="utf-8", errors="replace") as handle:
            first = handle.readline(_MAX_LINE_BYTES)
    except OSError:
        return None
    try:
        row = json.loads(first)
    except ValueError:
        return None
    if not isinstance(row, dict) or row.get("type") != "session":
        return None
    return row


def iter_pi_transcript_file(path: Path) -> Iterable[HookEvent]:
    header = pi_session_header(path)
    if header is None:
        return
    session_id = _string(header.get("id"))
    if session_id is None:
        match = _UUID.search(path.name)
        session_id = match.group(1) if match else None
    if session_id is None:
        return
    cwd = _string(header.get("cwd"))
    previous = _stamp(header.get("timestamp"), _mtime(path))
    for line in _recent_lines(path, TRANSCRIPT_MAX_LINES):
        try:
            row = json.loads(line)
        except ValueError:
            continue
        if not isinstance(row, dict) or row.get("type") != "message":
            continue
        message = row.get("message")
        if not isinstance(message, dict):
            continue
        at = _stamp(row.get("timestamp") or message.get("timestamp"), previous)
        previous = at
        role = message.get("role")
        if role == "user":
            prompt = _text_of(message.get("content"))
            if prompt:
                yield _event("pi", PI_TRANSCRIPT_PROVIDER, "UserPromptSubmit", session_id=session_id, cwd=cwd, at=at, path=path, prompt=prompt)
        elif role == "assistant":
            content = message.get("content")
            call = next((block for block in content if isinstance(block, dict) and block.get("type") == "toolCall"), None) if isinstance(content, list) else None
            if call is not None:
                yield _event("pi", PI_TRANSCRIPT_PROVIDER, "PreToolUse", session_id=session_id, cwd=cwd, at=at, path=path, tool_name=_string(call.get("name")), tool_use_id=_string(call.get("id")))
            elif message.get("stopReason") in ("stop", "length", "aborted", "error"):
                name = "StopFailure" if message.get("stopReason") == "error" else "Stop"
                yield _event("pi", PI_TRANSCRIPT_PROVIDER, name, session_id=session_id, cwd=cwd, at=at, path=path, last_assistant_message=_text_of(content))
        elif role == "toolResult":
            failed = message.get("isError") is True
            yield _event("pi", PI_TRANSCRIPT_PROVIDER, "PostToolUseFailure" if failed else "PostToolUse", session_id=session_id, cwd=cwd, at=at, path=path, tool_name=_string(message.get("toolName")), tool_use_id=_string(message.get("toolCallId")))


# --- gemini -------------------------------------------------------------------


def gemini_chat_header(path: Path) -> dict[str, Any] | None:
    try:
        with path.open("r", encoding="utf-8", errors="replace") as handle:
            first = handle.readline(_MAX_LINE_BYTES)
    except OSError:
        return None
    try:
        row = json.loads(first)
    except ValueError:
        return None
    if not isinstance(row, dict) or not isinstance(row.get("sessionId"), str):
        return None
    return row


def _gemini_message_event(message: dict[str, Any], *, session_id: str, cwd: str | None, previous: datetime, path: Path) -> tuple[HookEvent | None, datetime]:
    at = _stamp(message.get("timestamp"), previous)
    kind = message.get("type")
    if kind == "user":
        prompt = _text_of(message.get("content"))
        if not prompt or prompt.lstrip().startswith("<session_context>"):
            return None, at
        return _event("gemini", GEMINI_TRANSCRIPT_PROVIDER, "UserPromptSubmit", session_id=session_id, cwd=cwd, at=at, path=path, prompt=prompt), at
    if kind in ("gemini", "model", "assistant"):
        calls = message.get("toolCalls")
        if isinstance(calls, list) and calls:
            call = calls[0] if isinstance(calls[0], dict) else {}
            return _event("gemini", GEMINI_TRANSCRIPT_PROVIDER, "PreToolUse", session_id=session_id, cwd=cwd, at=at, path=path, tool_name=_string(call.get("name")), tool_use_id=_string(call.get("id"))), at
        return _event("gemini", GEMINI_TRANSCRIPT_PROVIDER, "Stop", session_id=session_id, cwd=cwd, at=at, path=path, last_assistant_message=_text_of(message.get("content"))), at
    return None, at


def iter_gemini_transcript_file(path: Path) -> Iterable[HookEvent]:
    header = gemini_chat_header(path)
    if header is None:
        return
    session_id = header["sessionId"]
    cwd = None
    previous = _stamp(header.get("startTime"), _mtime(path))
    for line in _recent_lines(path, TRANSCRIPT_MAX_LINES):
        try:
            row = json.loads(line)
        except ValueError:
            continue
        if not isinstance(row, dict):
            continue
        messages: list[Any] = []
        for op in ("$set", "$push"):
            patch = row.get(op)
            if isinstance(patch, dict):
                value = patch.get("messages")
                if isinstance(value, list):
                    messages.extend(value)
                elif isinstance(value, dict):
                    messages.append(value)
        if isinstance(row.get("type"), str) and "id" in row:
            messages.append(row)
        for message in messages:
            if not isinstance(message, dict):
                continue
            event, previous = _gemini_message_event(message, session_id=session_id, cwd=cwd, previous=previous, path=path)
            if event is not None:
                yield event


__all__ = [
    "GEMINI_TRANSCRIPT_MAX_FILES",
    "GEMINI_TRANSCRIPT_PROVIDER",
    "PI_TRANSCRIPT_MAX_FILES",
    "PI_TRANSCRIPT_PROVIDER",
    "default_gemini_chats_root",
    "default_pi_sessions_root",
    "gemini_chat_header",
    "iter_gemini_transcript_file",
    "iter_pi_transcript_file",
    "pi_session_header",
]
