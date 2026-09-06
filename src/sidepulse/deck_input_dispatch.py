"""Bounded ordered handoff from accessory input to explicit local actions.

Output refreshes may be coalesced. Distinct user inputs must not be silently
coalesced; overload is counted and visible in the control center instead.
"""
from __future__ import annotations

import threading
import time
from collections import deque
from dataclasses import dataclass

from .deck_actions import DeckAction
from .deck_control_settings import DeckControlSettings
from .deck_input import ControlInput, DeckInputRouter


@dataclass(frozen=True, slots=True)
class DeckInputBatch:
    owner: DeckInputDispatch
    created_at: float
    actions: tuple[DeckAction, ...]
    generation: int = 0
    board_revision: int | None = None
    session_targets: tuple[str | None, ...] = ()


class DeckInputDispatch:
    MAX_QUEUED = 32
    MAX_AGE = 0.5

    def __init__(self, target, settings: DeckControlSettings, *, clock=time.monotonic):
        self._target = target
        self._settings = settings
        self._clock = clock
        self._router = DeckInputRouter(analog_enabled=settings.analog_enabled)
        self._lock = threading.RLock()
        self._pending: DeckInputBatch | None = None
        self._queue: deque[DeckInputBatch] = deque()
        self._closed = False
        self._generation = 0
        self.dropped_inputs = 0

    def _schedule(self) -> None:
        if self._pending is not None or self._closed:
            return
        while self._queue and (
            self._queue[0].generation != self._generation
            or not 0 <= self._clock() - self._queue[0].created_at <= self.MAX_AGE
        ):
            self.dropped_inputs += len(self._queue.popleft().actions)
            setattr(self._target, "_deck_dropped_inputs", self.dropped_inputs)
        if not self._queue:
            return
        self._pending = self._queue.popleft()
        try:
            self._target.performSelectorOnMainThread_withObject_waitUntilDone_(
                "applyDeckInput:", self._pending, False,
            )
        except Exception:
            self.dropped_inputs += len(self._pending.actions)
            self._pending = None
            self._queue.clear()

    def receive(self, messages: list[dict]) -> None:
        """Creator wire decoder; other adapters call receive_normalized instead."""
        with self._lock:
            if self._closed:
                return
            events = tuple(event for message in messages[:128]
                           if (event := self._router.normalize(message)) is not None)
            self.receive_normalized(events)

    def receive_normalized(self, events: tuple[ControlInput, ...], *, virtual: bool = False) -> None:
        """The same bounded resolver serves hardware and explicitly simulated input."""
        if type(events) is not tuple or len(events) > 128 or any(type(event) is not ControlInput for event in events):
            raise ValueError("invalid normalized input batch")
        with self._lock:
            if self._closed:
                return
            board = getattr(self._target, "_deck_session_board", None)
            for event in events:
                setattr(self._target, "_deck_last_input",
                        (event.index, ("virtual_" if virtual else "") + event.kind, self._clock()))
                if not self._settings.enabled or getattr(self._target, "_deck_input_check_active", False):
                    continue
                action = self._settings.action_for(event.index)
                revision, session = None, None
                if action is None and self._settings.session_mode and board is not None:
                    revision, session = board.resolve_slot(event.index)
                    if session is not None:
                        action = DeckAction("reveal_session")
                if action is None:
                    continue
                if len(self._queue) + int(self._pending is not None) >= self.MAX_QUEUED:
                    self.dropped_inputs += 1
                    setattr(self._target, "_deck_dropped_inputs", self.dropped_inputs)
                    continue
                self._queue.append(DeckInputBatch(self, self._clock(), (action,), self._generation,
                                                  revision, (session,)))
            self._schedule()

    def deliver(self, batch: DeckInputBatch, executor) -> tuple:
        with self._lock:
            if batch is not self._pending or self._closed:
                return ()
            self._pending = None
            try:
                if batch.generation != self._generation or not 0 <= self._clock() - batch.created_at <= self.MAX_AGE:
                    self.dropped_inputs += len(batch.actions)
                    setattr(self._target, "_deck_dropped_inputs", self.dropped_inputs)
                    return ()
                receipts = []
                for index, action in enumerate(batch.actions):
                    if (self._closed or batch.generation != self._generation
                            or getattr(self._target, "_deck_input_check_active", False)
                            or not 0 <= self._clock() - batch.created_at <= self.MAX_AGE):
                        break
                    session = batch.session_targets[index] if index < len(batch.session_targets) else None
                    if session is not None:
                        receipts.append(executor.reveal_session(session, batch.board_revision))
                    else:
                        receipts.append(executor.execute(action))
                return tuple(receipts)
            finally:
                self._schedule()

    def reset_connection(self) -> None:
        """Revoke already-dispatched inputs and held keys without disabling new input."""
        with self._lock:
            self._generation += 1
            self._pending = None
            self._queue.clear()
            self._router.reset()

    def close(self) -> None:
        with self._lock:
            self._closed = True
            self.reset_connection()
