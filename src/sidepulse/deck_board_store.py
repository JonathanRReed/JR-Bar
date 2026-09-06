"""Coalesced private persistence for presentation-only session slot identities."""
from __future__ import annotations

import json
import threading

from .integration_settings import default_integration_settings_path
from .private_io import atomic_private_write, read_private_text


class DeckBoardStore:
    def __init__(self, path=None):
        self.path = path or default_integration_settings_path().with_name("deck-session-slots.json")
        self._lock = threading.Lock()
        self._pending = None
        self._last = None
        self._running = False
        self.error = None

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
        payload = json.dumps(board.serialize(), sort_keys=True, separators=(",", ":")) + "\n"
        with self._lock:
            if self.error or payload == self._last:
                return
            self._pending = payload
            if self._running:
                return
            self._running = True
        threading.Thread(target=self._write, name="JRBarDeckSlots", daemon=True).start()

    def _write(self) -> None:
        while True:
            with self._lock:
                payload, self._pending = self._pending, None
                if payload is None:
                    self._running = False
                    return
            try:
                atomic_private_write(self.path, payload)
            except (OSError, ValueError):
                with self._lock:
                    self.error = "Session-slot persistence failed; assignments remain in memory."
                    self._running = False
                    self._pending = None
                return
            with self._lock:
                self._last = payload
