"""Per-day session counts from the agent-monitor event ledgers.

"Why does the graph only have Claude and Codex?" -- because tokens and
cost genuinely exist only in those two CLIs' local transcripts. But
SESSIONS exist for every provider JR-Bar watches: the hook ledgers
in the state directory record a `session_start` event with a timestamp
and a work id for grok, devin, and any other hook-emitting provider.
This module turns those ledgers into the same day-bucketed counts the
transcript scanner produces, so the sessions metric can chart the whole
fleet.

Bounded and defensive: ledgers are append-only JSONL that other code
trims; a torn last line or a foreign record is skipped, never fatal.

Because the trimming keeps only the newest events, a ledger can speak for the
days it still holds and no further. ``ledger_first_event_epochs`` says where
each one starts, so a chart can leave the days before that unknown instead of
drawing them as zero sessions.
"""

from __future__ import annotations

import json
import math
from collections.abc import Iterator
from datetime import datetime
from pathlib import Path

#: Providers whose sessions already come from their own transcripts --
#: the ledger must not double-count them.
TRANSCRIPT_SESSION_PROVIDERS = frozenset({"claude", "codex"})

_MAX_LEDGER_BYTES = 8 * 1024 * 1024


def _ledger_events(root: Path, provider_id: str) -> Iterator[dict]:
    """The readable events one provider's ledger holds, oldest first.

    A missing, oversized or unreadable ledger yields nothing. A torn line, a
    line that is not an object and a record another provider wrote are
    skipped.
    """
    path = root / f"{provider_id}.jsonl"
    try:
        if not path.is_file() or path.stat().st_size > _MAX_LEDGER_BYTES:
            return
        text = path.read_text(encoding="utf-8", errors="replace")
    except OSError:
        return
    for line in text.splitlines():
        line = line.strip()
        if not line.startswith("{"):
            continue
        try:
            event = json.loads(line)
        except ValueError:
            continue
        if isinstance(event, dict) and event.get("provider_id") == provider_id:
            yield event


def _event_epoch(event: dict) -> float | None:
    """The event's own timestamp, or None when it is not a usable one."""
    occurred = event.get("occurred_at_epoch")
    if isinstance(occurred, bool) or not isinstance(occurred, (int, float)):
        return None
    epoch = float(occurred)
    return epoch if math.isfinite(epoch) and epoch > 0.0 else None


def ledger_session_days(
    state_dir: Path,
    *,
    since_epoch: float,
    provider_ids: tuple[str, ...],
) -> dict[str, dict[str, int]]:
    """{provider_id: {ISO day: distinct session_start count}}.

    Distinctness is by provider_work_id per day, so a replayed or
    duplicated event never inflates the chart.
    """
    root = Path(state_dir)
    results: dict[str, dict[str, int]] = {}
    for provider_id in provider_ids:
        if provider_id in TRANSCRIPT_SESSION_PROVIDERS:
            continue
        seen: dict[str, set[str]] = {}
        for event in _ledger_events(root, provider_id):
            if event.get("event_name") != "session_start":
                continue
            occurred = _event_epoch(event)
            if occurred is None or occurred < since_epoch:
                continue
            try:
                day = datetime.fromtimestamp(occurred).strftime("%Y-%m-%d")
            except (OverflowError, OSError, ValueError):
                continue
            work_id = str(
                event.get("provider_work_id")
                or event.get("event_token")
                or f"line:{len(seen.get(day, ()))}"
            )
            seen.setdefault(day, set()).add(work_id)
        counts = {day: len(ids) for day, ids in seen.items() if ids}
        if counts:
            results[provider_id] = counts
    return results


def ledger_first_event_epochs(
    state_dir: Path,
    *,
    provider_ids: tuple[str, ...],
) -> dict[str, float]:
    """{provider_id: epoch of the earliest event its ledger still holds}.

    Any event counts, not only ``session_start``: the ledger is trimmed to
    its newest events, and a session already running at the cut has no start
    left, so the ledger begins at its earliest event of any kind. It is read
    before any window is applied. Claude and Codex have no ledger counts (their
    transcripts are the source) and a provider with no readable ledger is left
    out.
    """
    root = Path(state_dir)
    results: dict[str, float] = {}
    for provider_id in provider_ids:
        if provider_id in TRANSCRIPT_SESSION_PROVIDERS:
            continue
        earliest: float | None = None
        for event in _ledger_events(root, provider_id):
            epoch = _event_epoch(event)
            if epoch is not None and (earliest is None or epoch < earliest):
                earliest = epoch
        if earliest is not None:
            results[provider_id] = earliest
    return results


__all__ = [
    "TRANSCRIPT_SESSION_PROVIDERS",
    "ledger_first_event_epochs",
    "ledger_session_days",
]
