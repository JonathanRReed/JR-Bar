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
from contextlib import contextmanager
from contextvars import ContextVar
from datetime import datetime
from pathlib import Path

#: Providers whose sessions already come from their own transcripts --
#: the ledger must not double-count them.
TRANSCRIPT_SESSION_PROVIDERS = frozenset({"claude", "codex"})

_MAX_LEDGER_BYTES = 8 * 1024 * 1024


#: What the two questions below need from one ledger event: its name, its own
#: timestamp (None when unusable) and the id that makes a replay count once
#: (None when the event names none). Keeping only this, not the whole event,
#: is what makes a ledger cheap to hold for one rebuild.
_LedgerRow = tuple[object, float | None, str | None]

#: The rows of each ledger read so far inside ``shared_ledger_reads``, or None
#: outside one.
_shared_rows: ContextVar[dict[tuple[str, str], list[_LedgerRow]] | None] = ContextVar(
    "jrbar_shared_ledger_rows", default=None
)


@contextmanager
def shared_ledger_reads() -> Iterator[None]:
    """Read and parse each hook ledger once for everything asked inside.

    A Sessions rebuild asks for the daily counts and for where each ledger
    starts. Each answer used to read and parse the same ledger (up to 8 MiB)
    on its own. Inside this block the first ask reads it and the second reuses
    those rows, so both answers also come from one moment of the file. The
    rows are dropped when the block ends: nothing is kept between rebuilds,
    and outside a block every call reads the file as it always did.
    """
    if _shared_rows.get() is not None:
        yield
        return
    token = _shared_rows.set({})
    try:
        yield
    finally:
        _shared_rows.reset(token)


def _read_ledger_rows(root: Path, provider_id: str) -> Iterator[_LedgerRow]:
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
            work = event.get("provider_work_id") or event.get("event_token")
            yield event.get("event_name"), _event_epoch(event), (str(work) if work else None)


def _ledger_rows(root: Path, provider_id: str) -> Iterator[_LedgerRow]:
    shared = _shared_rows.get()
    if shared is None:
        yield from _read_ledger_rows(root, provider_id)
        return
    key = (str(root), provider_id)
    rows = shared.get(key)
    if rows is None:
        rows = list(_read_ledger_rows(root, provider_id))
        shared[key] = rows
    yield from rows


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
        for name, occurred, work in _ledger_rows(root, provider_id):
            if name != "session_start":
                continue
            if occurred is None or occurred < since_epoch:
                continue
            try:
                day = datetime.fromtimestamp(occurred).strftime("%Y-%m-%d")
            except (OverflowError, OSError, ValueError):
                continue
            work_id = work or f"line:{len(seen.get(day, ()))}"
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
        for _name, epoch, _work in _ledger_rows(root, provider_id):
            if epoch is not None and (earliest is None or epoch < earliest):
                earliest = epoch
        if earliest is not None:
            results[provider_id] = earliest
    return results


__all__ = [
    "TRANSCRIPT_SESSION_PROVIDERS",
    "ledger_first_event_epochs",
    "ledger_session_days",
    "shared_ledger_reads",
]
