"""Per-session transcript timeline for the Overview inspector.

Reads a provider session's own transcript file (Claude projects JSONL,
Codex rollout JSONL) and projects bounded, paginated timeline items:
user/assistant messages, tool_use/tool_result pairs (linked by
``tool_use_id``), turn ends and sidechain/subagent markers.

This is a *read* surface, not an event source: items carry the row's own
timestamp (occurrence time); JR-Bar never recorded per-row ingestion
time, so ``recorded_at`` is honestly null. Text is truncated to
``TIMELINE_TEXT_MAX`` and secret-run redacted; tool output and
assistant content are marked ``untrusted`` so the client never renders
them as commands (T44). Unknown row types are skipped rather than
synthesised.
"""

from __future__ import annotations

import json
import re
import threading
from collections import OrderedDict
from collections.abc import Iterable
from datetime import datetime, timezone
from pathlib import Path
from typing import Any, Final

from .models import parse_datetime

TIMELINE_SCHEMA: Final = 1
TIMELINE_DEFAULT_LIMIT: Final = 100
TIMELINE_MAX_LIMIT: Final = 500
#: Whole-file parse bound — a transcript beyond this is sampled from the
#: tail and the gap is named in ``gaps`` rather than silently truncated.
TIMELINE_MAX_BYTES: Final = 64 * 1024 * 1024
TIMELINE_TEXT_MAX: Final = 600
TIMELINE_MAX_ITEMS: Final = 5000
_FIND_MAX_FILES: Final = 4000

_UUID = re.compile(
    r"^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$",
    re.IGNORECASE,
)
_SECRET_RUN = re.compile(r"[A-Za-z0-9_\-+/=.]{24,}")
_REDACTED: Final = "[redacted]"

SUPPORTED_PROVIDERS: Final = ("claude", "codex")

# The command answers page turns — one client paging a session re-reads
# the same transcript on every request. Both caches are small LRU maps:
# the path cache skips the projects-tree sweep once a session's file is
# known (revalidated by one stat), the items cache skips the whole
# re-parse while the file's mtime+size stand. Transcripts only append,
# so an unchanged (mtime, size) is the same document.
_CACHE_MAX_ENTRIES: Final = 8
_cache_lock = threading.Lock()
_path_cache: OrderedDict[tuple[str, str, str | None], Path] = OrderedDict()
_items_cache: OrderedDict[str, tuple[float, int, list[dict[str, Any]], list[str]]] = OrderedDict()


def _string(value: object) -> str | None:
    return value.strip() if isinstance(value, str) and value.strip() else None


def _bound_text(value: object) -> str | None:
    """Bounded, secret-redacted text for the wire. ``None`` stays ``None``."""
    text = _string(value)
    if text is None:
        return None
    if len(text) > TIMELINE_TEXT_MAX:
        text = text[:TIMELINE_TEXT_MAX].rstrip() + "…"
    return _SECRET_RUN.sub(_REDACTED, text)


def _epoch(value: datetime | None) -> float | None:
    return value.timestamp() if isinstance(value, datetime) else None


def _content_text(content: object) -> str | None:
    """Plain text of a message content field (string or content blocks)."""
    if isinstance(content, str):
        return _string(content)
    if not isinstance(content, list):
        return None
    parts: list[str] = []
    for item in content:
        # Claude uses ``text``; Codex rollout blocks are ``input_text`` /
        # ``output_text`` — same ``{"type","text"}`` shape either way.
        if isinstance(item, dict) and item.get("type") in (
            "text", "input_text", "output_text",
        ):
            text = _string(item.get("text"))
            if text:
                parts.append(text)
        elif isinstance(item, str) and item.strip():
            parts.append(item.strip())
    return "\n".join(parts) if parts else None


def _iter_lines(path: Path) -> Iterable[str]:
    """Every line of the file (unlike read_recent_lines, which tails)."""
    try:
        with path.open("r", encoding="utf-8", errors="replace") as handle:
            yield from handle
    except OSError:
        return


# ---------------------------------------------------------------------------
# Transcript discovery


def claude_projects_root(home: Path | None = None) -> Path:
    return (home or Path.home()) / ".claude" / "projects"


def codex_sessions_root(home: Path | None = None) -> Path:
    return (home or Path.home()) / ".codex" / "sessions"


def _claude_project_dir_name(cwd: str) -> str:
    """Claude's project dir slug: ``/a/b c`` -> ``-a-b-c``."""
    slug = re.sub(r"[^A-Za-z0-9]", "-", cwd)
    return slug if slug.startswith("-") else "-" + slug


def _find_named(root: Path, session_id: str, *, max_files: int) -> Path | None:
    """Newest ``*.jsonl`` under ``root`` whose name carries the uuid.

    The name check runs inside the ``rglob`` sweep — it needs no stat —
    so a projects tree holding tens of thousands of transcripts costs one
    readdir walk, not a stat per file. ``max_files`` bounds the matches
    kept for the mtime tiebreak (a uuid can appear in several project
    dirs when the same session is resumed under a different cwd).
    """
    needle = session_id.lower()
    matches: list[tuple[float, Path]] = []
    try:
        iterator = root.rglob("*.jsonl")
        for path in iterator:
            if needle not in path.name.lower():
                continue
            try:
                if not path.is_file():
                    continue
                mtime = path.stat().st_mtime
            except OSError:
                continue
            matches.append((mtime, path))
            if len(matches) >= max_files:
                break
    except OSError:
        return None
    if not matches:
        return None
    return max(matches, key=lambda pair: pair[0])[1]


def find_transcript(
    provider: str,
    session_id: str | None,
    *,
    cwd: str | None = None,
    home: Path | None = None,
) -> Path | None:
    """The transcript file owning ``session_id``, or ``None``.

    Claude rows are found by uuid-in-filename inside the projects tree —
    the ``cwd``-slugged project dir is tried first so a uuid named file
    elsewhere does not win. Codex rollout files embed the uuid the same
    way under the date-partitioned sessions tree.
    """
    if not session_id or not _UUID.match(session_id.strip()):
        return None
    sid = session_id.strip()
    cacheable = home is None  # a test-rooted lookup never poisons the cache
    cache_key = (provider, sid, cwd)
    if cacheable:
        with _cache_lock:
            cached = _path_cache.get(cache_key)
            if cached is not None:
                _path_cache.move_to_end(cache_key)
        if cached is not None and cached.is_file():
            return cached
        with _cache_lock:
            _path_cache.pop(cache_key, None)
    found = _find_transcript_uncached(provider, sid, cwd=cwd, home=home)
    if found is not None and cacheable:
        with _cache_lock:
            _path_cache[cache_key] = found
            _path_cache.move_to_end(cache_key)
            while len(_path_cache) > _CACHE_MAX_ENTRIES:
                _path_cache.popitem(last=False)
    return found


def _find_transcript_uncached(
    provider: str,
    sid: str,
    *,
    cwd: str | None = None,
    home: Path | None = None,
) -> Path | None:
    if provider == "claude":
        root = claude_projects_root(home)
        if cwd:
            project_dir = root / _claude_project_dir_name(cwd)
            direct = project_dir / f"{sid}.jsonl"
            if direct.is_file():
                return direct
        return _find_named(root, sid, max_files=_FIND_MAX_FILES)
    if provider == "codex":
        return _find_named(codex_sessions_root(home), sid, max_files=_FIND_MAX_FILES)
    return None


# ---------------------------------------------------------------------------
# Row → item projection


def _item(
    *,
    seq: int,
    at: datetime | None,
    kind: str,
    uuid: str | None = None,
    parent_uuid: str | None = None,
    **fields: Any,
) -> dict[str, Any]:
    item: dict[str, Any] = {
        "seq": seq,
        "at": _epoch(at),
        "kind": kind,
        "uuid": uuid,
        "parent_uuid": parent_uuid,
        "origin": "transcript",
        "recorded_at": None,  # per-row ingestion time was never kept
    }
    item.update(fields)
    return item


def claude_row_items(
    row: dict[str, Any],
    *,
    seq: int,
    fallback_at: datetime | None,
) -> tuple[list[dict[str, Any]], datetime | None]:
    """One Claude transcript row → zero or more timeline items."""
    at = parse_datetime(row.get("timestamp"), fallback_at)
    uuid = _string(row.get("uuid"))
    parent_uuid = _string(row.get("parentUuid"))
    sidechain = bool(row.get("isSidechain"))
    row_type = row.get("type")
    message = row.get("message")
    content = message.get("content") if isinstance(message, dict) else None

    items: list[dict[str, Any]] = []
    if row_type == "user" and row.get("isMeta") is not True:
        if isinstance(content, list):
            for block in content:
                if not isinstance(block, dict):
                    continue
                if block.get("type") == "tool_result":
                    items.append(
                        _item(
                            seq=seq + len(items),
                            at=at,
                            kind="tool_result",
                            uuid=uuid,
                            parent_uuid=parent_uuid,
                            tool_use_id=_string(block.get("tool_use_id")),
                            is_error=bool(block.get("is_error")),
                            sidechain=sidechain,
                            untrusted=True,
                            text=_bound_text(_content_text(block.get("content"))),
                        )
                    )
                elif block.get("type") == "text":
                    text = _content_text([block])
                    if text and not text.strip().startswith("<task-notification>"):
                        items.append(
                            _item(
                                seq=seq + len(items),
                                at=at,
                                kind="message",
                                role="user",
                                uuid=uuid,
                                parent_uuid=parent_uuid,
                                sidechain=sidechain,
                                untrusted=False,
                                text=_bound_text(text),
                            )
                        )
        else:
            text = _content_text(content)
            if text and not text.strip().startswith("<task-notification>"):
                items.append(
                    _item(
                        seq=seq,
                        at=at,
                        kind="message",
                        role="user",
                        uuid=uuid,
                        parent_uuid=parent_uuid,
                        sidechain=sidechain,
                        untrusted=False,
                        text=_bound_text(text),
                    )
                )
        # ``toolUseResult`` rides on the user row; it is the durable result
        # marker when the content blocks were compacted away.
        result = row.get("toolUseResult")
        if result is not None and not items:
            items.append(
                _item(
                    seq=seq,
                    at=at,
                    kind="tool_result",
                    uuid=uuid,
                    parent_uuid=parent_uuid,
                    tool_use_id=_string(row.get("sourceToolAssistantUUID")),
                    is_error=bool(
                        isinstance(result, dict)
                        and result.get("status") in ("error", "failed")
                    ),
                    sidechain=sidechain,
                    untrusted=True,
                    text=_bound_text(
                        _content_text(result.get("content"))
                        if isinstance(result, dict)
                        else (result if isinstance(result, str) else None)
                    ),
                )
            )
    elif row_type == "assistant" and isinstance(message, dict):
        if isinstance(content, list):
            for block in content:
                if not isinstance(block, dict):
                    continue
                if block.get("type") == "tool_use":
                    items.append(
                        _item(
                            seq=seq + len(items),
                            at=at,
                            kind="tool_use",
                            uuid=uuid,
                            parent_uuid=parent_uuid,
                            role="assistant",
                            name=_string(block.get("name")),
                            tool_use_id=_string(block.get("id")),
                            sidechain=sidechain,
                            untrusted=False,
                            text=_bound_text(_summarize_input(block.get("input"))),
                        )
                    )
        text = _content_text(content)
        stop = message.get("stop_reason")
        if text:
            items.append(
                _item(
                    seq=seq + len(items),
                    at=at,
                    kind="message",
                    role="assistant",
                    uuid=uuid,
                    parent_uuid=parent_uuid,
                    model=_string(message.get("model")),
                    sidechain=sidechain,
                    untrusted=True,  # model output is untrusted content (T44)
                    text=_bound_text(text),
                )
            )
        if stop:
            items.append(
                _item(
                    seq=seq + len(items),
                    at=at,
                    kind="turn_end",
                    uuid=uuid,
                    parent_uuid=parent_uuid,
                    name=str(stop),
                    sidechain=sidechain,
                    untrusted=False,
                    text=None,
                )
            )
    return items, at


def _summarize_input(value: object) -> str | None:
    """A tool_use input as bounded text — shown as context, never run."""
    if value is None:
        return None
    if isinstance(value, str):
        return value
    try:
        return json.dumps(value, ensure_ascii=False, default=str)[: TIMELINE_TEXT_MAX * 2]
    except (TypeError, ValueError):
        return str(value)


def codex_row_items(
    row: dict[str, Any],
    *,
    seq: int,
    fallback_at: datetime | None,
    turn_id: str | None,
) -> tuple[list[dict[str, Any]], datetime | None, str | None]:
    """One Codex rollout row → items; tracks ``turn_context`` for turn ids."""
    at = parse_datetime(row.get("timestamp"), fallback_at)
    payload = row.get("payload")
    if not isinstance(payload, dict):
        return [], at, turn_id
    payload_type = payload.get("type")
    if row.get("type") == "turn_context" or payload_type == "turn_context":
        return [], at, _string(payload.get("turn_id")) or turn_id

    items: list[dict[str, Any]] = []
    if payload_type == "message":
        role = _string(payload.get("role"))
        text = _content_text(payload.get("content"))
        if text and role in ("user", "assistant"):
            items.append(
                _item(
                    seq=seq,
                    at=at,
                    kind="message",
                    role=role,
                    name=turn_id,
                    untrusted=(role == "assistant"),
                    text=_bound_text(text),
                )
            )
    elif payload_type in ("function_call", "local_shell_call", "custom_tool_call"):
        name = _string(payload.get("name"))
        items.append(
            _item(
                seq=seq,
                at=at,
                kind="tool_use",
                role="assistant",
                name=name,
                tool_use_id=_string(payload.get("call_id")) or _string(payload.get("id")),
                untrusted=False,
                text=_bound_text(_summarize_input(payload.get("arguments"))),
            )
        )
    elif payload_type == "function_call_output":
        output = payload.get("output")
        items.append(
            _item(
                seq=seq,
                at=at,
                kind="tool_result",
                tool_use_id=_string(payload.get("call_id")),
                is_error=bool(
                    isinstance(output, dict) and output.get("is_error")
                )
                or (isinstance(output, str) and "error" in output[:64].lower()),
                untrusted=True,
                text=_bound_text(
                    _content_text(output.get("content"))
                    if isinstance(output, dict)
                    else (output if isinstance(output, str) else None)
                ),
            )
        )
    elif payload_type == "task_complete":
        items.append(
            _item(
                seq=seq,
                at=at,
                kind="turn_end",
                name="task_complete",
                untrusted=False,
                text=_bound_text(payload.get("last_agent_message")),
            )
        )
    elif payload_type == "turn_aborted":
        items.append(
            _item(
                seq=seq,
                at=at,
                kind="turn_end",
                name="turn_aborted",
                is_error=True,
                untrusted=False,
                text=None,
            )
        )
    return items, at, turn_id


def timeline_items(provider: str, path: Path) -> tuple[list[dict[str, Any]], list[str]]:
    """Parse the transcript into ordered items plus honest ``gaps``."""
    gaps: list[str] = []
    try:
        size = path.stat().st_size
    except OSError:
        return [], ["transcript_unreadable"]
    if size > TIMELINE_MAX_BYTES:
        return [], [f"transcript_too_large:{size}"]

    items: list[dict[str, Any]] = []
    fallback_at: datetime | None = datetime.fromtimestamp(
        path.stat().st_mtime, timezone.utc
    )
    turn_id: str | None = None
    truncated = False
    for line in _iter_lines(path):
        if len(items) >= TIMELINE_MAX_ITEMS:
            truncated = True
            break
        line = line.strip()
        if not line:
            continue
        try:
            row = json.loads(line)
        except json.JSONDecodeError:
            continue
        if not isinstance(row, dict):
            continue
        seq = len(items)
        if provider == "claude":
            made, fallback_at = claude_row_items(row, seq=seq, fallback_at=fallback_at)
        elif provider == "codex":
            made, fallback_at, turn_id = codex_row_items(
                row, seq=seq, fallback_at=fallback_at, turn_id=turn_id
            )
        else:
            made = []
        items.extend(made)
    if truncated:
        gaps.append(f"timeline_item_cap:{TIMELINE_MAX_ITEMS}")
    items.sort(key=lambda item: (item["at"] is None, item["at"] or 0.0, item["seq"]))
    for index, item in enumerate(items):
        item["seq"] = index
    return items, gaps


def _cached_timeline_items(
    provider: str, path: Path
) -> tuple[list[dict[str, Any]], list[str]]:
    """``timeline_items`` behind the mtime+size memo.

    A live transcript changes its size on every append, so the cache
    misses exactly when it should; a rewrite that somehow keeps both
    stamps identical is the one hole, and it is closed by the firmware's
    own rewrite semantics (appends only). The cached lists are shared
    read-only -- ``paginate`` slices, never mutates.
    """
    try:
        stamp = path.stat()
    except OSError:
        return [], ["transcript_unreadable"]
    key = str(path)
    with _cache_lock:
        hit = _items_cache.get(key)
        if hit is not None and hit[0] == stamp.st_mtime and hit[1] == stamp.st_size:
            _items_cache.move_to_end(key)
            return hit[2], hit[3]
    items, gaps = timeline_items(provider, path)
    with _cache_lock:
        _items_cache[key] = (stamp.st_mtime, stamp.st_size, items, gaps)
        _items_cache.move_to_end(key)
        while len(_items_cache) > _CACHE_MAX_ENTRIES:
            _items_cache.popitem(last=False)
    return items, gaps


def paginate(
    items: list[dict[str, Any]],
    *,
    limit: int,
    before: int | None,
) -> dict[str, Any]:
    """Newest-first paging: ``before`` is the seq of the oldest item the
    client already holds; the page is the ``limit`` items just older."""
    limit = max(1, min(limit, TIMELINE_MAX_LIMIT))
    window = items if before is None else items[: max(0, before)]
    page = window[-limit:]
    return {
        "events": page,
        "has_more": len(window) > len(page),
        "next_before": page[0]["seq"] if page else None,
        "total": len(items),
    }


def session_timeline(
    provider: str,
    session_id: str | None,
    *,
    cwd: str | None = None,
    limit: int = TIMELINE_DEFAULT_LIMIT,
    before: int | None = None,
    home: Path | None = None,
) -> dict[str, Any]:
    """The command payload: source facts, the page, and named gaps."""
    gaps: list[str] = []
    if provider not in SUPPORTED_PROVIDERS:
        return {
            "schema": TIMELINE_SCHEMA,
            "events": [],
            "has_more": False,
            "next_before": None,
            "total": 0,
            "source": {"provider": provider, "file": None},
            "gaps": ["unsupported_provider"],
        }
    path = find_transcript(provider, session_id, cwd=cwd, home=home)
    if path is None:
        return {
            "schema": TIMELINE_SCHEMA,
            "events": [],
            "has_more": False,
            "next_before": None,
            "total": 0,
            "source": {"provider": provider, "file": None},
            "gaps": ["transcript_not_found"],
        }
    items, gaps = _cached_timeline_items(provider, path)
    page = paginate(items, limit=limit, before=before)
    page.update(
        {
            "schema": TIMELINE_SCHEMA,
            "source": {
                "provider": provider,
                "file": str(path),
            },
            "gaps": gaps,
        }
    )
    return page
