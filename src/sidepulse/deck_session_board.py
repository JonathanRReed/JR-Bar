"""Hardware-independent, stable session slots and capability-scoped navigation.

Never owns agent execution. Missing identities stay vacant rather than silently
reassigning a physical key. Reassignment and bank changes revoke old revisions.
"""
from __future__ import annotations

import hashlib
import json
import re
import threading
from dataclasses import dataclass
from datetime import datetime, timezone
from itertools import islice

from .models import AgentMode, AgentStatus
from .provider_facts import WorkKey, work_key_to_payload

SLOTS_PER_BANK = 13
MAX_SESSIONS = 520


def session_identity(status: AgentStatus) -> str | None:
    # Native source identity includes account/harness/source-instance boundaries.
    # Legacy observations without a WorkKey remain visible in Agent Browser,
    # but do not acquire a physical control capability from their display name.
    if type(status.work_key) is not WorkKey:
        return None
    raw = json.dumps(work_key_to_payload(status.work_key), sort_keys=True, separators=(",", ":"))
    return hashlib.sha256(raw.encode("utf-8")).hexdigest()


def _text(value: object, limit: int = 64) -> str:
    return "".join(char for char in str(value or "") if char.isprintable())[:limit]


def _fresh(status: AgentStatus, now: datetime) -> bool:
    if status.stale:
        return False
    try:
        age = (now - status.updated_at).total_seconds()
    except (TypeError, ValueError):
        return False
    # The canonical monitor owns stale/ended reconciliation. Do not invent a
    # shorter timeout that turns a legitimately long tool call into idle.
    return age >= -5


@dataclass(frozen=True, slots=True)
class SessionSlot:
    index: int
    identity: str | None
    title: str
    subtitle: str
    state: str
    navigable: bool
    pinned: bool = False


@dataclass(frozen=True, slots=True)
class BoardSnapshot:
    revision: int
    bank: int
    bank_count: int
    slots: tuple[SessionSlot, ...]
    unscoped_count: int = 0


class DeckSessionBoard:
    def __init__(self, *, clock=lambda: datetime.now(timezone.utc)):
        self._lock = threading.RLock()
        self._clock = clock
        self._order: list[str | None] = []
        self._statuses: dict[str, AgentStatus] = {}
        self._pinned: set[str] = set()
        self._bank = 0
        self._revision = 0
        self._unscoped_count = 0
        self._navigation_keys: set[str] = set()

    def update(self, statuses, *, navigation_keys=()) -> None:
        admitted = {}
        unscoped = 0
        for status in islice(statuses, MAX_SESSIONS):
            if type(status) is not AgentStatus or status.is_subagent:
                continue
            identity = session_identity(status)
            if identity is None:
                unscoped += 1
                continue
            admitted[identity] = status
        with self._lock:
            self._statuses = admitted
            self._navigation_keys = set(navigation_keys) & set(admitted)
            self._unscoped_count = unscoped
            # Append, never sort/reuse occupied slots after their first assignment.
            known = set(self._order)
            new = sorted(identity for identity in admitted if identity not in known)
            appended = new[:max(0, MAX_SESSIONS - len(self._order))]
            self._order.extend(appended)
            if appended:
                self._revision += 1

    def resolve_slot(self, index: int) -> tuple[int, str | None]:
        with self._lock:
            offset = self._bank * SLOTS_PER_BANK + index
            identity = self._order[offset] if 0 <= index < SLOTS_PER_BANK and offset < len(self._order) else None
            return self._revision, identity

    def navigation_target(self, identity: str, revision: int | None) -> AgentStatus | None:
        with self._lock:
            if revision != self._revision:
                return None
            status = self._statuses.get(identity)
            if status is None or identity not in self._navigation_keys or not _fresh(status, self._clock()):
                return None
            return status

    def change_bank(self, delta: int) -> None:
        if type(delta) is not int or delta not in (-1, 1):
            raise ValueError("invalid bank movement")
        with self._lock:
            count = max(1, (len(self._order) + SLOTS_PER_BANK - 1) // SLOTS_PER_BANK)
            self._bank = (self._bank + delta) % count
            self._revision += 1

    def toggle_pin(self, index: int) -> None:
        with self._lock:
            _, identity = self.resolve_slot(index)
            if identity is None:
                return
            if identity in self._pinned:
                self._pinned.remove(identity)
            else:
                self._pinned.add(identity)
            self._revision += 1

    def clear_inactive(self) -> None:
        """Explicitly compact only unpinned, absent sessions; never on a refresh."""
        with self._lock:
            self._order = [key for key in self._order if key in self._statuses or key in self._pinned]
            self._bank = min(self._bank, max(0, (len(self._order) - 1) // SLOTS_PER_BANK))
            self._revision += 1

    def serialize(self) -> dict:
        with self._lock:
            # Only opaque hashes persist. No provider titles, paths, or credentials.
            return {"version": 1, "slots": list(self._order), "pinned": sorted(self._pinned), "bank": self._bank}

    def restore(self, value: object) -> None:
        if (type(value) is not dict or set(value) != {"version", "slots", "pinned", "bank"}
                or type(value["version"]) is not int or value["version"] != 1
                or type(value["slots"]) is not list or len(value["slots"]) > MAX_SESSIONS
                or type(value["pinned"]) is not list or len(value["pinned"]) > MAX_SESSIONS
                or type(value["bank"]) is not int or not 0 <= value["bank"] < MAX_SESSIONS // SLOTS_PER_BANK):
            raise ValueError("invalid session board")
        slots, pinned = value["slots"], value["pinned"]
        if (any(type(key) is not str or re.fullmatch(r"[a-f0-9]{64}", key) is None for key in slots + pinned)
                or len(set(slots)) != len(slots) or not set(pinned) <= set(slots)):
            raise ValueError("invalid session board identity")
        with self._lock:
            self._order = list(slots)
            self._pinned = set(pinned)
            self._bank = min(value["bank"], max(0, (len(slots) - 1) // SLOTS_PER_BANK))
            self._revision += 1

    def snapshot(self) -> BoardSnapshot:
        with self._lock:
            now = self._clock()
            slots = []
            states = {
                AgentMode.WAITING_FOR_INPUT: "input_required", AgentMode.BLOCKED_ERROR: "failure",
                AgentMode.WORKING: "active", AgentMode.TOOL_RUNNING: "active",
                AgentMode.LONG_TASK_PROGRESS: "active", AgentMode.COMPLETED: "completed",
                AgentMode.UNKNOWN: "unknown", AgentMode.ENDED_UNCONFIRMED: "ended_unconfirmed",
            }
            for index in range(SLOTS_PER_BANK):
                _, identity = self.resolve_slot(index)
                status = self._statuses.get(identity)
                pinned = identity in self._pinned
                if status is None:
                    slots.append(SessionSlot(index, identity, "Reserved" if identity else "Unassigned",
                                             "Session not observed" if identity else "No session assigned",
                                             "unavailable", False, pinned))
                    continue
                fresh = _fresh(status, now)
                source = status.work_key.source_key
                slots.append(SessionSlot(index, identity, _text(status.display_name),
                                         f"{_text(status.provider, 24)} · {_text(source.adapter_id, 28)} · "
                                         f"{_text(source.source_instance_id, 24)}",
                                         states.get(status.mode, "idle") if fresh else "stale",
                                         fresh and identity in self._navigation_keys, pinned))
            return BoardSnapshot(self._revision, self._bank,
                                 max(1, (len(self._order) + SLOTS_PER_BANK - 1) // SLOTS_PER_BANK),
                                 tuple(slots), self._unscoped_count)
