"""Coalesced private persistence for presentation-only session slot identities."""
from __future__ import annotations

import json
import threading
import time

from .integration_settings import default_integration_settings_path
from .private_io import atomic_private_write, read_private_text

#: A failed write is retried on a later submit, no sooner than this, doubling
#: with each failure in a row up to the cap.
WRITE_RETRY_SECONDS = 5.0
WRITE_RETRY_CAP_SECONDS = 60.0


class DeckBoardStore:
    def __init__(self, path=None, *, monotonic=time.monotonic):
        self.path = path or default_integration_settings_path().with_name("deck-session-slots.json")
        self._monotonic = monotonic
        self._lock = threading.Condition()
        self._pending = None
        self._last = None
        self._running = False
        self._closed = False
        self._last_board = None
        self._last_revision = -1
        #: Load failures only, and sticky: the original file is preserved.
        self.error = None
        #: A failed write. It is not sticky: a failed atomic write leaves the
        #: old file intact, so the next submit after the backoff tries again.
        self.write_error = None
        self._failures = 0
        self._retry_at = None

    def load(self, board) -> None:
        try:
            raw = read_private_text(self.path, max_bytes=96 * 1024)
        except FileNotFoundError:
            return
        try:
            board.restore(json.loads(raw))
        except (ValueError, TypeError):
            self.error = "Stored session slots are invalid; the original file was preserved."
            raise ValueError(self.error) from None

    def submit(self, board) -> None:
        # The board's revision covers every serialized field, so an
        # unchanged revision means an identical payload -- the ~35 KB
        # ``json.dumps`` is skipped on the caller's thread, not just
        # the write deduped after it ran.
        revision = getattr(board, "revision", None)
        with self._lock:
            if self.error or self._closed:
                return
            # Inside the backoff window nothing is serialized or recorded, so
            # a failing disk costs a comparison per tick, not a 35 KB dump.
            if self._retry_at is not None and self._monotonic() < self._retry_at:
                return
            if revision is not None and board is self._last_board and revision == self._last_revision:
                return
            self._last_board, self._last_revision = board, revision
        payload = json.dumps(board.serialize(), sort_keys=True, separators=(",", ":")) + "\n"
        with self._lock:
            if not self._running and payload == self._last:
                # The board is back to what the file already holds.
                self._clear_write_failure()
                return
            self._pending = payload
            if self._running:
                return
            self._running = True
        # A bounded local save must finish during normal interpreter shutdown.
        threading.Thread(target=self._write, name="JRBarDeckSlots", daemon=False).start()

    def _write(self) -> None:
        while True:
            with self._lock:
                payload, self._pending = self._pending, None
                if payload is None:
                    self._running = False
                    self._lock.notify_all()
                    return
                if payload == self._last:
                    continue
            try:
                atomic_private_write(self.path, payload)
            except (OSError, ValueError):
                with self._lock:
                    self.write_error = "Session-slot persistence failed; assignments remain in memory."
                    self._failures += 1
                    delay = min(
                        WRITE_RETRY_CAP_SECONDS,
                        WRITE_RETRY_SECONDS * 2 ** (self._failures - 1),
                    )
                    self._retry_at = self._monotonic() + delay
                    # Forget the revision memo, so the retry serializes the
                    # board again even when nothing has changed since. This
                    # also repairs a newer payload dropped just below.
                    self._last_board, self._last_revision = None, -1
                    self._running = False
                    self._pending = None
                    self._lock.notify_all()
                return
            with self._lock:
                self._last = payload
                self._clear_write_failure()

    def _clear_write_failure(self) -> None:
        # Called with the lock held.
        self.write_error = None
        self._failures = 0
        self._retry_at = None

    def close(self) -> None:
        """Refuse new saves; let the single writer finish its latest pending save."""
        with self._lock:
            self._closed = True

    def wait_until_idle(self, timeout: float = 2.0) -> bool:
        """Wait from a shutdown worker or test, never from an AppKit callback."""
        deadline = time.monotonic() + max(0.0, timeout)
        with self._lock:
            while self._running:
                remaining = deadline - time.monotonic()
                if remaining <= 0:
                    return False
                self._lock.wait(remaining)
            return self.error is None and self.write_error is None
