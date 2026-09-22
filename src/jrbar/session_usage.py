"""Per-session model, tokens, cost and context for the panel and Overview.

``usage_stats`` already reads every assistant line's model and token
counts, but it is built to total a corpus, not to name a run: records are
keyed by the transcript's physical file (``claude:<dev>:<ino>``) and Codex
thread ids are HMAC'd under a per-cache secret, so nothing downstream can
say "this session used 1.2M tokens on Opus". This module answers exactly
that question for the handful of sessions a surface is showing, by reading
each session's own transcript -- the same file ``session_timeline`` finds.

Reads are incremental: transcripts only append, so each file keeps the
byte offset it was parsed to and the next request reads only what was
written since (a working session's file grows every few seconds). A file
that shrank or was replaced (a different inode) is re-read from the start.
The per-file state is a small LRU; losing it costs one re-read, never a
wrong number.

Counting follows ``usage_stats``: Claude repeats a message's ``usage`` once
per content block and again in resumed files, so the first sighting of a
message id wins; Codex ``token_count`` rows carry a per-turn delta
(``last_token_usage``) or, on older rollouts, only the cumulative total the
delta is derived from. Codex reports cache reads and writes as subsets of
``input_tokens``; the canonical tuple here is ordinary input, cache reads,
cache writes and output, so the four parts sum to what was actually sent
and received.

Cost is the same local estimate the Usage Center shows
(``core_usage_history.record_cost``): list prices from the versioned table,
a stand-in rate marked ``cost_estimated`` for a model with no row, and no
dollars at all for a provider without a table. Context is the size of the
newest main-chain turn's prompt; Codex states its window
(``model_context_window``), Claude does not, so a Claude window is
``inferred`` from what the transcript has already shown fitting in it.
"""

from __future__ import annotations

import json
import threading
from collections import OrderedDict
from dataclasses import dataclass, field
from datetime import datetime
from pathlib import Path
from typing import Any, Final

from .session_timeline import SUPPORTED_PROVIDERS, find_transcript

SESSION_USAGE_SCHEMA: Final = 1
#: One request names at most this many sessions -- a panel's worth, and a
#: bound on how many transcripts a single socket reply may open.
SESSION_USAGE_MAX_IDS: Final = 64
#: A transcript larger than this is read from its tail only, and the reply
#: says so (``partial``); the head of a run that long is mostly cache
#: reads already priced into the turns that follow.
SESSION_USAGE_MAX_BYTES: Final = 64 * 1024 * 1024
#: Per-file state kept between requests (offset, totals, turns).
_CACHE_MAX_FILES: Final = 64
#: Turns kept per file for ``tokens_since`` -- a very long run keeps its
#: newest turns, which are the ones a quota window asks about.
_MAX_TURNS: Final = 20_000
#: Claude message ids remembered per file for the first-sighting rule.
_MAX_SEEN_IDS: Final = 50_000

#: Claude's default prompt window, and the long-context one a transcript
#: proves it is using by showing a prompt larger than the default.
CLAUDE_DEFAULT_CONTEXT: Final = 200_000
CLAUDE_LONG_CONTEXT: Final = 1_000_000

_USAGE_MARKER: Final = '"usage"'
_CODEX_MARKERS: Final = ('"token_count"', '"turn_context"')


@dataclass(slots=True)
class _FileUsage:
    provider: str
    device: int
    inode: int
    offset: int = 0
    partial: bool = False
    #: model -> [input, cached_input, cache_creation, output]
    models: dict[str, list[int]] = field(default_factory=dict)
    last_model: str | None = None
    #: (epoch, tokens) per counted assistant turn, oldest first.
    turns: list[tuple[float, int]] = field(default_factory=list)
    context_tokens: int | None = None
    context_window: int | None = None
    max_context: int = 0
    first_at: float | None = None
    last_at: float | None = None
    seen_ids: set[str] = field(default_factory=set)
    #: Codex: the previous cumulative total, for rollouts without deltas.
    codex_previous: tuple[int, int, int, int] | None = None
    codex_model: str | None = None
    malformed: int = 0


_lock = threading.Lock()
_files: OrderedDict[str, _FileUsage] = OrderedDict()


def reset_cache() -> None:
    """Forget every file's state (tests; a daemon never needs to)."""
    with _lock:
        _files.clear()


def _epoch(value: object) -> float | None:
    if not isinstance(value, str) or not value:
        return None
    try:
        return datetime.fromisoformat(value.replace("Z", "+00:00")).timestamp()
    except ValueError:
        return None


def _count(mapping: object, key: str) -> int:
    if not isinstance(mapping, dict):
        return 0
    value = mapping.get(key)
    if isinstance(value, bool) or not isinstance(value, (int, float)):
        return 0
    return max(0, int(value))


def _record(state: _FileUsage, model: str, parts: tuple[int, int, int, int], at: float | None) -> None:
    total = sum(parts)
    if total <= 0:
        return
    bucket = state.models.setdefault(model, [0, 0, 0, 0])
    for index, value in enumerate(parts):
        bucket[index] += value
    state.last_model = model
    if at is not None:
        state.turns.append((at, total))
        if len(state.turns) > _MAX_TURNS:
            del state.turns[: len(state.turns) - _MAX_TURNS]
        state.first_at = at if state.first_at is None else min(state.first_at, at)
        state.last_at = at if state.last_at is None else max(state.last_at, at)


def _claude_line(state: _FileUsage, line: str) -> None:
    if _USAGE_MARKER not in line:
        return
    try:
        row = json.loads(line)
    except (json.JSONDecodeError, RecursionError, ValueError):
        state.malformed += 1
        return
    if not isinstance(row, dict) or row.get("type") != "assistant":
        return
    message = row.get("message")
    if not isinstance(message, dict):
        return
    usage = message.get("usage")
    if not isinstance(usage, dict):
        return
    message_id = message.get("id")
    if isinstance(message_id, str) and message_id:
        if message_id in state.seen_ids:
            return
        if len(state.seen_ids) < _MAX_SEEN_IDS:
            state.seen_ids.add(message_id)
    else:
        # No id means no safe dedupe (usage_stats skips these too).
        return
    model = message.get("model")
    model = model.strip() if isinstance(model, str) and model.strip() else "unknown"
    parts = (
        _count(usage, "input_tokens"),
        _count(usage, "cache_read_input_tokens"),
        _count(usage, "cache_creation_input_tokens"),
        _count(usage, "output_tokens"),
    )
    # A `<synthetic>` placeholder carries zero usage and is dropped by the
    # zero-total guard in `_record`, so it never becomes "the model".
    _record(state, model, parts, _epoch(row.get("timestamp")))
    if sum(parts) > 0 and not row.get("isSidechain"):
        # The prompt this turn sent: everything it read, cached or not. A
        # sub-agent's sidechain turn has its own, smaller context.
        prompt = parts[0] + parts[1] + parts[2]
        state.context_tokens = prompt
        state.max_context = max(state.max_context, prompt)


def _codex_line(state: _FileUsage, line: str) -> None:
    if not any(marker in line for marker in _CODEX_MARKERS):
        return
    try:
        row = json.loads(line)
    except (json.JSONDecodeError, RecursionError, ValueError):
        state.malformed += 1
        return
    if not isinstance(row, dict):
        return
    payload = row.get("payload")
    if not isinstance(payload, dict):
        return
    if row.get("type") == "turn_context" or payload.get("type") == "turn_context":
        model = payload.get("model")
        if isinstance(model, str) and 0 < len(model.strip()) <= 128:
            state.codex_model = model.strip()
        return
    if payload.get("type") != "token_count":
        return
    info = payload.get("info")
    if not isinstance(info, dict):
        return
    window = info.get("model_context_window")
    if isinstance(window, (int, float)) and not isinstance(window, bool) and window > 0:
        state.context_window = int(window)
    totals = info.get("total_token_usage")
    last = info.get("last_token_usage")
    keys = ("input_tokens", "cached_input_tokens", "cache_write_input_tokens", "output_tokens")
    cumulative = tuple(_count(totals, key) for key in keys) if isinstance(totals, dict) else None
    if cumulative is not None and cumulative == state.codex_previous:
        # A repeated cumulative row (Codex re-emits it on resume and after
        # a rate-limit refresh) is the same turn again, not new work.
        return
    if isinstance(last, dict):
        delta = tuple(_count(last, key) for key in keys)
        # The newest turn's prompt, cache included.
        state.context_tokens = delta[0]
        state.max_context = max(state.max_context, delta[0])
    elif cumulative is not None:
        previous = state.codex_previous or (0, 0, 0, 0)
        delta = tuple(max(0, now - before) for now, before in zip(cumulative, previous))
    else:
        return
    if cumulative is not None:
        state.codex_previous = cumulative
    inp, cached, written, out = delta
    parts = (max(0, inp - cached - written), cached, written, out)
    _record(state, state.codex_model or "codex", parts, _epoch(row.get("timestamp")))


def _read_new_text(path: Path, state: _FileUsage, size: int) -> str:
    """The complete lines written since ``state.offset``; advances it."""
    start = state.offset
    if start == 0 and size > SESSION_USAGE_MAX_BYTES:
        start = size - SESSION_USAGE_MAX_BYTES
        state.partial = True
    try:
        with path.open("rb") as handle:
            handle.seek(start)
            payload = handle.read(size - start)
    except OSError:
        return ""
    if start > state.offset:
        # Landed mid-line: the first partial line belongs to the skipped head.
        newline = payload.find(b"\n")
        payload = payload[newline + 1 :] if newline >= 0 else b""
        start = size - len(payload)
    cut = payload.rfind(b"\n")
    if cut < 0:
        state.offset = start
        return ""
    state.offset = start + cut + 1
    return payload[: cut + 1].decode("utf-8", errors="replace")


def _refresh(provider: str, path: Path) -> _FileUsage | None:
    try:
        info = path.stat()
    except OSError:
        return None
    key = str(path)
    with _lock:
        state = _files.get(key)
        if (
            state is None
            or state.provider != provider
            or state.device != info.st_dev
            or state.inode != info.st_ino
            or info.st_size < state.offset
        ):
            state = _FileUsage(provider=provider, device=info.st_dev, inode=info.st_ino)
            _files[key] = state
        _files.move_to_end(key)
        while len(_files) > _CACHE_MAX_FILES:
            _files.popitem(last=False)
        if info.st_size > state.offset:
            text = _read_new_text(path, state, info.st_size)
            parse = _claude_line if provider == "claude" else _codex_line
            for line in text.splitlines():
                if line:
                    parse(state, line)
        return state


def _cost(provider: str, models: dict[str, list[int]]) -> tuple[float | None, bool, list[str]]:
    """(dollars, any stand-in rate, models with no price) for one run."""
    from .core_usage_history import default_codex_model, price_quote, quote_cost

    codex_default = default_codex_model() if provider == "codex" else None
    total = 0.0
    priced = False
    estimated = False
    unpriced: list[str] = []
    for model, (inp, cached, written, out) in models.items():
        quote = price_quote(provider, model, codex_default_model=codex_default)
        if quote is None:
            unpriced.append(model)
            continue
        priced = True
        estimated = estimated or quote.estimated
        total += quote_cost(provider, quote, inp, cached, written, out)
    return (round(total, 4) if priced else None), estimated, sorted(unpriced)


def _context_window(state: _FileUsage) -> tuple[int | None, str | None]:
    if state.context_window:
        return state.context_window, "reported"
    if state.provider == "claude" and state.context_tokens is not None:
        if state.max_context > CLAUDE_DEFAULT_CONTEXT:
            return CLAUDE_LONG_CONTEXT, "inferred"
        return CLAUDE_DEFAULT_CONTEXT, "inferred"
    return None, None


def usage_document(provider: str, state: _FileUsage, *, since: float | None = None) -> dict[str, Any]:
    """One session's usage as the wire carries it."""
    inp = sum(parts[0] for parts in state.models.values())
    cached = sum(parts[1] for parts in state.models.values())
    written = sum(parts[2] for parts in state.models.values())
    out = sum(parts[3] for parts in state.models.values())
    cost, estimated, unpriced = _cost(provider, state.models)
    window, window_source = _context_window(state)
    document: dict[str, Any] = {
        "provider": provider,
        "model": state.last_model,
        "models": {
            model: sum(parts) for model, parts in sorted(
                state.models.items(), key=lambda item: -sum(item[1])
            )
        },
        "tokens": {
            "input": inp,
            "cached_input": cached,
            "cache_creation": written,
            "output": out,
        },
        "turns": len(state.turns),
        "estimated_cost_usd": cost,
        "cost_estimated": estimated,
        "unpriced_models": unpriced,
        "context_tokens": state.context_tokens,
        "context_window": window,
        "context_window_source": window_source,
        "first_at": state.first_at,
        "last_at": state.last_at,
        "partial": state.partial,
    }
    if since is not None:
        document["tokens_since"] = sum(tokens for at, tokens in state.turns if at >= since)
    return document


def session_usage(
    provider: str,
    session_id: str | None,
    *,
    cwd: str | None = None,
    since: float | None = None,
    home: Path | None = None,
) -> tuple[dict[str, Any] | None, str | None]:
    """(document, None) for a readable transcript, else (None, gap)."""
    if provider not in SUPPORTED_PROVIDERS:
        return None, "unsupported_provider"
    path = find_transcript(provider, session_id, cwd=cwd, home=home)
    if path is None:
        return None, "transcript_not_found"
    state = _refresh(provider, path)
    if state is None:
        return None, "transcript_unreadable"
    with _lock:
        return usage_document(provider, state, since=since), None


def session_usage_document(
    requests: list[tuple[str, str | None, str | None, str | None]],
    *,
    since: float | None = None,
    home: Path | None = None,
) -> dict[str, Any]:
    """The ``session_usage`` reply for ``(id, provider, session, cwd)`` rows.

    Every id lands in exactly one of ``sessions`` (its usage) or ``gaps``
    (why there is none), so a surface can tell "not read yet" from "no
    transcript" from "this provider keeps none" without guessing.
    """
    from . import usage_stats

    sessions: dict[str, Any] = {}
    gaps: dict[str, str] = {}
    for agent_id, provider, session_id, cwd in requests[:SESSION_USAGE_MAX_IDS]:
        if not provider:
            gaps[agent_id] = "not_found"
            continue
        document, gap = session_usage(
            provider, session_id, cwd=cwd, since=since, home=home
        )
        if document is None:
            gaps[agent_id] = gap or "transcript_not_found"
        else:
            sessions[agent_id] = document
    return {
        "schema": SESSION_USAGE_SCHEMA,
        "sessions": sessions,
        "gaps": gaps,
        "since": since,
        "pricing": {
            "as_of": usage_stats.PRICING_TABLE_AS_OF,
            "table_version": usage_stats.PRICING_TABLE_VERSION,
            "semantics": "api_equivalent_estimate",
        },
    }


def cache_size() -> int:
    with _lock:
        return len(_files)
