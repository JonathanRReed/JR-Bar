"""Durable command journal: persist intent before effect, replay receipts.

W19's execution contract asks that a command — "answer this ask", "snooze
this session" — is *written down before it runs*, so a crash mid-effect
leaves a record the next boot can reconcile, and a retried command replays
its first receipt instead of running twice.

The journal is one bounded JSON file in the state dir: ``command_id`` is
the caller's idempotency key (the panel makes one per click), ``status``
moves ``accepted -> completed`` or ``accepted -> failed`` — and a command
that dies mid-effect stays ``accepted`` forever, which ``reconcile`` reads
as *outcome unknown* rather than pretending it finished.

Nothing here executes anything; it is the ledger, not the worker.
"""

from __future__ import annotations

import json
import time
import uuid
from collections.abc import Mapping
from dataclasses import dataclass
from pathlib import Path
from typing import Any

from .private_io import atomic_private_write

JOURNAL_FILENAME = "command-journal.json"

# Commands older than this are compaction candidates: a journal is a
# recovery window, not a history.
_RETENTION_SECONDS = 7 * 24 * 3600
# Hard bound on file size in entries — beyond this the oldest
# completed/failed records drop first (accepted ones never do).
_MAX_ENTRIES = 256

STATUS_ACCEPTED = "accepted"      # intent recorded, effect not confirmed
STATUS_COMPLETED = "completed"    # effect confirmed with a receipt
STATUS_FAILED = "failed"          # effect refused or errored before running


class CommandJournalError(ValueError):
    pass


@dataclass(frozen=True, slots=True)
class CommandRecord:
    command_id: str
    command: str
    args: dict[str, Any]
    status: str
    accepted_at: float
    settled_at: float | None
    receipt: dict[str, Any] | None
    error: dict[str, Any] | None

    def to_payload(self) -> dict[str, Any]:
        return {
            "command_id": self.command_id,
            "command": self.command,
            "args": self.args,
            "status": self.status,
            "accepted_at": self.accepted_at,
            "settled_at": self.settled_at,
            "receipt": self.receipt,
            "error": self.error,
        }

    @classmethod
    def from_payload(cls, payload: Mapping[str, Any]) -> CommandRecord | None:
        command_id = payload.get("command_id")
        command = payload.get("command")
        status = payload.get("status")
        accepted_at = payload.get("accepted_at")
        if not all(isinstance(v, str) and v for v in (command_id, command, status)):
            return None
        if not isinstance(accepted_at, (int, float)):
            return None
        args = payload.get("args")
        receipt = payload.get("receipt")
        error = payload.get("error")
        settled_at = payload.get("settled_at")
        return cls(
            command_id=str(command_id),
            command=str(command),
            args=dict(args) if isinstance(args, Mapping) else {},
            status=str(status),
            accepted_at=float(accepted_at),
            settled_at=float(settled_at) if isinstance(settled_at, (int, float)) else None,
            receipt=dict(receipt) if isinstance(receipt, Mapping) else None,
            error=dict(error) if isinstance(error, Mapping) else None,
        )


def new_command_id() -> str:
    return f"cmd-{uuid.uuid4().hex[:20]}"


class CommandJournal:
    """The ledger. Construct empty or around loaded records; ``path`` may
    be None for a memory-only journal (tests, degraded state dir)."""

    def __init__(self, path: Path | None = None,
                 records: Mapping[str, CommandRecord] | None = None) -> None:
        self._path = path
        self._records: dict[str, CommandRecord] = dict(records or {})

    @classmethod
    def load(cls, state_dir: Path) -> CommandJournal:
        path = state_dir / JOURNAL_FILENAME
        try:
            raw = json.loads(path.read_text(encoding="utf-8"))
        except (OSError, json.JSONDecodeError):
            return cls(path=path)
        records: dict[str, CommandRecord] = {}
        entries = raw.get("commands") if isinstance(raw, Mapping) else None
        if isinstance(entries, list):
            for entry in entries:
                if not isinstance(entry, Mapping):
                    continue
                record = CommandRecord.from_payload(entry)
                if record is not None:
                    records[record.command_id] = record
        return cls(path=path, records=records)

    def _persist(self) -> None:
        if self._path is None:
            return
        self._path.parent.mkdir(parents=True, exist_ok=True)
        payload = json.dumps(
            {"schema": 1,
             "commands": [r.to_payload() for r in self._ordered()]},
            separators=(",", ":"),
        )
        atomic_private_write(self._path, payload)

    def _ordered(self) -> list[CommandRecord]:
        return sorted(self._records.values(), key=lambda r: r.accepted_at)

    def _compact(self, now: float) -> None:
        """Drop settled records past retention, then the oldest settled
        beyond the cap. ``accepted`` records are never compacted — an
        unfinished command is exactly what the journal must keep."""
        expired = [
            cid for cid, r in self._records.items()
            if r.status != STATUS_ACCEPTED
            and r.settled_at is not None
            and now - r.settled_at > _RETENTION_SECONDS
        ]
        for cid in expired:
            del self._records[cid]
        if len(self._records) <= _MAX_ENTRIES:
            return
        settled = sorted(
            (r for r in self._records.values() if r.status != STATUS_ACCEPTED),
            key=lambda r: r.settled_at or 0.0,
        )
        for record in settled[: len(self._records) - _MAX_ENTRIES]:
            del self._records[record.command_id]

    # -- the contract -----------------------------------------------------

    def begin(self, command: str, args: Mapping[str, Any],
              *, command_id: str | None = None, now: float | None = None) -> CommandRecord:
        """Persist intent BEFORE the effect. Re-beginning an existing id
        returns the original record — a retry never rewrites history."""
        cid = command_id or new_command_id()
        existing = self._records.get(cid)
        if existing is not None:
            return existing
        at = time.time() if now is None else now
        record = CommandRecord(
            command_id=cid, command=command, args=dict(args),
            status=STATUS_ACCEPTED, accepted_at=at,
            settled_at=None, receipt=None, error=None,
        )
        self._records[cid] = record
        self._compact(at)
        self._persist()
        return record

    def settle(self, command_id: str, *,
               receipt: Mapping[str, Any] | None = None,
               error: Mapping[str, Any] | None = None,
               now: float | None = None) -> CommandRecord:
        """Move an accepted record to completed/failed. Settling an
        already-settled record replays its first receipt — the second
        call is a no-op, not a rewrite (T09/T70)."""
        record = self._records.get(command_id)
        if record is None:
            raise CommandJournalError(f"unknown command {command_id}")
        if record.status != STATUS_ACCEPTED:
            return record
        if receipt is not None and error is not None:
            raise CommandJournalError("a command settles as completed or failed, not both")
        if receipt is None and error is None:
            raise CommandJournalError("settle needs a receipt or an error")
        at = time.time() if now is None else now
        settled = CommandRecord(
            command_id=record.command_id, command=record.command,
            args=record.args,
            status=STATUS_FAILED if error is not None else STATUS_COMPLETED,
            accepted_at=record.accepted_at, settled_at=at,
            receipt=dict(receipt) if receipt is not None else None,
            error=dict(error) if error is not None else None,
        )
        self._records[command_id] = settled
        self._persist()
        return settled

    def get(self, command_id: str) -> CommandRecord | None:
        return self._records.get(command_id)

    def reconcile(self, *, now: float | None = None) -> dict[str, Any]:
        """What a restart should do with the journal: settled records are
        receipts to replay; ``accepted`` ones are outcome-unknown — the
        honest answer is their ids, not a guess at the effect."""
        at = time.time() if now is None else now
        self._compact(at)
        settled = [r for r in self._ordered() if r.status != STATUS_ACCEPTED]
        unknown = [r for r in self._ordered() if r.status == STATUS_ACCEPTED]
        return {
            "commands": len(self._records),
            "completed": sum(1 for r in settled if r.status == STATUS_COMPLETED),
            "failed": sum(1 for r in settled if r.status == STATUS_FAILED),
            "outcome_unknown": [r.command_id for r in unknown],
            "receipts": {r.command_id: r.receipt for r in settled
                         if r.receipt is not None},
        }
