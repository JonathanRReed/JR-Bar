"""Side-by-side run comparison for the Overview (S7.4).

Compares two roster sessions on what the daemon actually retains: the
projected roster row (outcome/review/freshness axes, lifecycle), the
transcript-derived activity (message/tool counts, tool failures and
retries, span), and the activity ledger's interruption rows (asks,
blocks, completions observed for that agent id).

Each side's ``artifacts`` is the files its edit tools named, read from
each tool call's own input in the transcript (Claude Edit/Write/
MultiEdit/NotebookEdit ``file_path``; Codex ``*** Add/Update/Delete
File:`` patch headers) -- what the run asked to change, not a diff of
the working tree; ``None`` with ``artifacts_not_tracked`` when a
transcript was not read.

What it deliberately does not do: model attribution (the roster does
not track per-session model — ``shared.model`` is ``None``, not a
guess) and benchmark claims — the document carries
``not_a_controlled_benchmark`` in ``warnings`` because uncontrolled
speed/cost numbers are not a fair model comparison.
"""

from __future__ import annotations

import json
import re
import time
from collections.abc import Iterable, Iterator
from pathlib import Path
from typing import Any, Final

from .session_timeline import TIMELINE_MAX_BYTES, _iter_lines, find_transcript, timeline_items

COMPARE_SCHEMA: Final = 1
FILES_TOUCHED_MAX: Final = 200
_CLAUDE_EDIT_TOOLS: Final = frozenset({"Edit", "Write", "MultiEdit", "NotebookEdit"})
_CODEX_CALL_TYPES: Final = frozenset({"function_call", "custom_tool_call", "local_shell_call"})
_PATCH_HEADER: Final = re.compile(r"^\*\*\* (?:Add|Update|Delete) File: (.+?)\s*$", re.MULTILINE)


def _epoch(value: Any) -> float | None:
    return value if isinstance(value, (int, float)) else None


def _timeline_aggregate(
    provider: str | None,
    session_id: str | None,
    cwd: str | None,
) -> tuple[dict[str, Any] | None, str | None]:
    """Transcript-derived counts for one side, or a named gap."""
    if provider not in ("claude", "codex"):
        return None, "unsupported_provider"
    path = find_transcript(provider, session_id, cwd=cwd)
    if path is None:
        return None, "transcript_not_found"
    items, gaps = timeline_items(provider, path)

    tools: dict[str, int] = {}
    failed_uses: set[str] = set()
    all_uses: set[str] = set()
    counts = {
        "user_messages": 0,
        "assistant_messages": 0,
        "tool_uses": 0,
        "tool_failures": 0,
        "turn_ends": 0,
        "sidechain_rows": 0,
    }
    first_at = last_at = None
    for item in items:
        at = _epoch(item.get("at"))
        if at is not None:
            first_at = at if first_at is None else min(first_at, at)
            last_at = at if last_at is None else max(last_at, at)
        if item.get("sidechain"):
            counts["sidechain_rows"] += 1
        kind = item.get("kind")
        if kind == "message":
            if item.get("role") == "user":
                counts["user_messages"] += 1
            elif item.get("role") == "assistant":
                counts["assistant_messages"] += 1
        elif kind == "tool_use":
            counts["tool_uses"] += 1
            name = item.get("name") or "unknown"
            tools[name] = tools.get(name, 0) + 1
            if item.get("tool_use_id"):
                all_uses.add(item["tool_use_id"])
        elif kind == "tool_result":
            if item.get("is_error"):
                counts["tool_failures"] += 1
                if item.get("tool_use_id"):
                    failed_uses.add(item["tool_use_id"])
        elif kind == "turn_end":
            counts["turn_ends"] += 1

    # A retry is a tool_use id that saw a failure and ran again — the
    # count of failing ids, since a retry is the same call re-issued.
    counts["retried_tools"] = len(failed_uses & all_uses)
    aggregate: dict[str, Any] = {
        "counts": counts,
        "tools": dict(sorted(tools.items(), key=lambda kv: -kv[1])),
        "span": {
            "first_at": first_at,
            "last_at": last_at,
            "duration_s": (last_at - first_at)
            if first_at is not None and last_at is not None
            else None,
        },
        "file": str(path),
    }
    if gaps:
        aggregate["timeline_gaps"] = gaps
    return aggregate, None


def _strings(value: object) -> Iterator[str]:
    if isinstance(value, str):
        yield value
    elif isinstance(value, dict):
        for item in value.values():
            yield from _strings(item)
    elif isinstance(value, list):
        for item in value:
            yield from _strings(item)


def _claude_edits(row: dict[str, Any]) -> Iterator[tuple[str, int]]:
    if row.get("type") != "assistant":
        return
    message = row.get("message")
    content = message.get("content") if isinstance(message, dict) else None
    if not isinstance(content, list):
        return
    for block in content:
        if not isinstance(block, dict) or block.get("type") != "tool_use":
            continue
        if block.get("name") not in _CLAUDE_EDIT_TOOLS:
            continue
        data = block.get("input")
        if not isinstance(data, dict):
            continue
        path = data.get("file_path") or data.get("notebook_path")
        if isinstance(path, str) and path.strip():
            edits = data.get("edits")
            yield path.strip(), len(edits) if isinstance(edits, list) and edits else 1


def _codex_edits(row: dict[str, Any]) -> Iterator[tuple[str, int]]:
    payload = row.get("payload")
    if not isinstance(payload, dict) or payload.get("type") not in _CODEX_CALL_TYPES:
        return
    for text in _strings({key: payload.get(key) for key in ("arguments", "input", "action")}):
        candidates = [text]
        if text.lstrip().startswith(("{", "[")):
            try:
                candidates = list(_strings(json.loads(text)))
            except ValueError:
                pass
        for candidate in candidates:
            for match in _PATCH_HEADER.finditer(candidate):
                yield match.group(1), 1


def _display_path(raw: str, cwd: str | None) -> str:
    """Relative to the run's folder when inside it; the home folder as ~."""
    path = raw.strip()
    if cwd:
        root = cwd.rstrip("/") + "/"
        if path.startswith(root):
            return path[len(root):]
    home = str(Path.home())
    if path == home or path.startswith(home + "/"):
        return "~" + path[len(home):]
    return path


def files_touched(provider: str | None, path: Path, cwd: str | None) -> dict[str, Any] | None:
    """The files a run's edit tools named, most-edited first, capped at
    ``FILES_TOUCHED_MAX``; ``None`` for a transcript too large to read or
    a provider whose edit calls are not read."""
    if provider not in ("claude", "codex"):
        return None
    try:
        if path.stat().st_size > TIMELINE_MAX_BYTES:
            return None
    except OSError:
        return None
    reader = _claude_edits if provider == "claude" else _codex_edits
    marker = '"tool_use"' if provider == "claude" else '"payload"'
    counts: dict[str, int] = {}
    for line in _iter_lines(path):
        if marker not in line:
            continue
        try:
            row = json.loads(line)
        except ValueError:
            continue
        if not isinstance(row, dict):
            continue
        for raw, edits in reader(row):
            key = _display_path(raw, cwd)
            if key:
                counts[key] = counts.get(key, 0) + edits
    ordered = sorted(counts.items(), key=lambda kv: (-kv[1], kv[0]))
    return {
        "files": [{"path": name, "edits": edits} for name, edits in ordered[:FILES_TOUCHED_MAX]],
        "total": len(ordered),
        "truncated": len(ordered) > FILES_TOUCHED_MAX,
    }


def _interruptions(
    ledger_entries: Iterable[Any],
    agent_id: str,
) -> dict[str, int]:
    """Ledger rows for this agent id, by kind — the asks/blocks the run
    surfaced (S7.4's interruption axis)."""
    out = {"asked": 0, "blocked": 0, "completed": 0}
    for entry in ledger_entries or ():
        if getattr(entry, "subject_id", None) != agent_id:
            continue
        kind = getattr(getattr(entry, "kind", None), "value", None) or str(
            getattr(entry, "kind", "")
        )
        if kind in out:
            out[kind] += 1
    return out


def run_side(
    roster_row: dict[str, Any] | None,
    *,
    agent_id: str,
    status: Any,
    ledger_entries: Iterable[Any],
) -> dict[str, Any]:
    """One side of the comparison: projected row + aggregates + gaps."""
    # Roster rows are the session document flattened (id/label/provider/
    # cwd/mode at top level) plus axes/visibility/pinned — no nesting.
    row = roster_row or {}
    provider = row.get("provider") or getattr(status, "provider", None)
    session_id = getattr(status, "session_id", None)
    cwd = row.get("cwd") or getattr(status, "cwd", None)
    activity, gap = _timeline_aggregate(provider, session_id, cwd)
    artifacts = files_touched(provider, Path(activity["file"]), cwd) if activity else None
    gaps: list[str] = [gap] if gap else []
    if roster_row is None:
        gaps.append("not_in_roster")
    side: dict[str, Any] = {
        "id": agent_id,
        "label": row.get("label") or row.get("short_id") or agent_id,
        "provider": provider,
        "cwd": cwd,
        "lifecycle": row.get("lifecycle"),
        "mode": row.get("mode"),
        "axes": row.get("axes"),
        "remote": bool(row.get("remote")),
        "activity": activity,
        "interruptions": _interruptions(ledger_entries, agent_id),
        # What the run's edit tools named; absent, never fabricated,
        # when its transcript was not read (S7.3).
        "artifacts": artifacts,
        # The roster tracks no per-session model (session_usage does).
        "model": None,
        "gaps": gaps,
    }
    return side


def compare_runs(
    *,
    row_a: dict[str, Any] | None,
    row_b: dict[str, Any] | None,
    status_a: Any,
    status_b: Any,
    ledger_entries: Iterable[Any],
    id_a: str,
    id_b: str,
) -> dict[str, Any]:
    """The ``compare_sessions`` document."""
    side_a = run_side(row_a, agent_id=id_a, status=status_a,
                      ledger_entries=ledger_entries)
    side_b = run_side(row_b, agent_id=id_b, status=status_b,
                      ledger_entries=ledger_entries)
    warnings = [
        "not_a_controlled_benchmark",  # S7.4: uncontrolled runs are not a fair comparison
    ]
    if side_a["provider"] != side_b["provider"]:
        warnings.append("different_providers")
    if (side_a.get("cwd") or "") != (side_b.get("cwd") or ""):
        warnings.append("different_workspaces")
    return {
        "t": "compare_runs",
        "schema": COMPARE_SCHEMA,
        "generated_at": time.time(),
        "a": side_a,
        "b": side_b,
        "shared": {
            "provider": side_a["provider"] == side_b["provider"],
            "workspace": bool(side_a.get("cwd"))
            and side_a.get("cwd") == side_b.get("cwd"),
            # The roster tracks no per-session model: unknown, not equal.
            "model": None,
        },
        "warnings": warnings,
        "gaps": [
            *(["artifacts_not_tracked"] if side_a["artifacts"] is None or side_b["artifacts"] is None else []),
            "model_not_tracked",
        ],
    }
