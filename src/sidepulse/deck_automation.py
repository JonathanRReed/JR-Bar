"""Explicit named macOS Shortcuts, outside AppKit and outside the HID protocol.

The shortcut is chosen by the user in settings. No script text, arguments,
provider text or device-supplied name reaches this subprocess boundary.
"""
from __future__ import annotations

import os
import queue
import signal
import subprocess
import threading
import time

from .deck_actions import DeckAction
from .deck_actions_macos import DeckActionReceipt


class DeckAutomationRunner:
    def __init__(self, callback=None):
        self._callback = callback
        self._queue: queue.Queue = queue.Queue(maxsize=8)
        self._lock = threading.RLock()
        self._closed = False
        self._process = None
        self._thread = None

    def submit(self, name: str) -> DeckActionReceipt:
        DeckAction("run_system_shortcut", shortcut_name=name)
        with self._lock:
            if self._closed:
                return DeckActionReceipt("shortcut_runner_closed", False)
            try:
                self._queue.put_nowait((time.monotonic(), name))
            except queue.Full:
                return DeckActionReceipt("shortcut_queue_full", False)
            if self._thread is None or not self._thread.is_alive():
                self._thread = threading.Thread(target=self._run, name="JRBarSystemShortcuts", daemon=True)
                self._thread.start()
        return DeckActionReceipt("shortcut_queued", True)

    @staticmethod
    def _stop(process) -> None:
        if process is not None and process.poll() is None:
            try:
                os.killpg(process.pid, signal.SIGTERM)
                process.wait(timeout=1.0)
            except subprocess.TimeoutExpired:
                try:
                    os.killpg(process.pid, signal.SIGKILL)
                    process.wait(timeout=1.0)
                except (ProcessLookupError, subprocess.TimeoutExpired):
                    pass
            except ProcessLookupError:
                pass

    def _run(self) -> None:
        while True:
            with self._lock:
                if self._closed:
                    return
                try:
                    created, name = self._queue.get_nowait()
                except queue.Empty:
                    self._thread = None
                    return
                if time.monotonic() - created > 0.5:
                    result = DeckActionReceipt("shortcut_expired", False)
                    process = None
                else:
                    try:
                        process = subprocess.Popen(
                            ["/usr/bin/shortcuts", "run", name], stdin=subprocess.DEVNULL,
                            stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL,
                            start_new_session=True, close_fds=True,
                        )
                        self._process = process
                        result = None
                    except OSError:
                        process = None
                        result = DeckActionReceipt("shortcut_unavailable", False)
            if process is not None:
                try:
                    code = process.wait(timeout=30.0)
                    result = DeckActionReceipt("shortcut_finished" if code == 0 else "shortcut_failed", code == 0)
                except subprocess.TimeoutExpired:
                    self._stop(process)
                    result = DeckActionReceipt("shortcut_timeout", False)
                finally:
                    with self._lock:
                        self._process = None
            if self._callback is not None:
                self._callback(result)

    def close(self) -> None:
        with self._lock:
            self._closed = True
            process = self._process
        # Do not block AppKit during app termination.
        if process is not None:
            threading.Thread(target=self._stop, args=(process,), name="JRBarShortcutStop", daemon=True).start()
