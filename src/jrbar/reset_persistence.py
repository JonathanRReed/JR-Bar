"""Revision-owned reset saves with three timed retries on the owner loop."""

from __future__ import annotations

from dataclasses import dataclass

from .persistence_writer import PersistenceReceipt

RETRY_DELAYS = (1.0, 5.0, 30.0)


@dataclass(frozen=True)
class ResetPersistenceCompletion:
    revision: int
    receipt: PersistenceReceipt


class ResetPersistence:
    def __init__(self) -> None:
        self.state = None
        self.revision = 0
        self.dirty = False
        self.in_flight = False
        self.retries = 0
        self.retry_at: float | None = None
        self.error: str | None = None

    def changed(self, state, *, retry: bool = False) -> None:
        if state == self.state and not retry:
            return
        self.state = state
        self.revision += 1
        self.dirty = True
        self.in_flight = False
        self.retries = 0
        self.retry_at = None
        self.error = None

    def begin(self, *, now: float) -> int | None:
        if not self.dirty or self.in_flight:
            return None
        if self.error is not None:
            if self.retry_at is None or now < self.retry_at:
                return None
            self.retries += 1
        self.retry_at = None
        self.in_flight = True
        return self.revision

    def complete(self, revision: int, *, succeeded: bool, reason: str | None, now: float) -> None:
        if revision != self.revision or not self.in_flight:
            return
        self.in_flight = False
        self.dirty = not succeeded
        self.error = None if succeeded else reason or "write_failed"
        self.retry_at = (now + RETRY_DELAYS[self.retries]
                         if not succeeded and self.retries < len(RETRY_DELAYS) else None)

    def document(self) -> dict:
        return dict(revision=self.revision, dirty=self.dirty, in_flight=self.in_flight,
                    retries=self.retries, retry_at=self.retry_at, error=self.error)
