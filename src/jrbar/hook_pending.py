"""Drain the shim's ``<provider>.pending.jsonl`` files into the ingress FIFO.

When the daemon is not listening, ``jrbar-hook`` appends each payload as one
JSON line ``{"provider", "ppid", "ppid_start", "payload"}`` under the state
directory. The daemon drains those files when it starts and every
``PENDING_DRAIN_INTERVAL_SECONDS`` after that. A file is renamed before it is
read so a shim appending at the same moment starts a fresh file instead of
racing the reader.
"""

from __future__ import annotations

import json
import os
import threading
import time
from collections.abc import Callable
from pathlib import Path
from typing import Final

from .hook_ingress_protocol import (
    MAX_HOOK_INGRESS_PAYLOAD_BYTES,
    HookIngressRequest,
)
from .state_paths import default_state_dir

PENDING_SUFFIX: Final = ".pending.jsonl"
PENDING_DRAIN_INTERVAL_SECONDS: Final = 30.0
MAX_PENDING_FILE_BYTES: Final = 64 * 1024 * 1024
MAX_PENDING_LINES_PER_DRAIN: Final = 5000


def pending_hook_files(state_dir: Path | None = None) -> list[Path]:
    base = Path(state_dir) if state_dir is not None else default_state_dir()
    try:
        return sorted(
            path
            for path in base.iterdir()
            if path.name.endswith(PENDING_SUFFIX) and path.is_file() and not path.is_symlink()
        )
    except OSError:
        return []


def _default_log_path(provider: str) -> str:
    try:
        from .providers import detect_log_path

        return str(detect_log_path(provider))
    except Exception:
        return str(default_state_dir() / f"{provider}.jsonl")


def request_from_pending_line(
    line: str,
    *,
    log_path_for: Callable[[str], str] = _default_log_path,
) -> HookIngressRequest | None:
    try:
        row = json.loads(line)
    except ValueError:
        return None
    if not isinstance(row, dict):
        return None
    provider = row.get("provider")
    payload = row.get("payload")
    if not isinstance(provider, str) or not isinstance(payload, str):
        return None
    if len(payload.encode("utf-8", errors="replace")) > MAX_HOOK_INGRESS_PAYLOAD_BYTES:
        return None
    ppid = row.get("ppid")
    ppid_start = row.get("ppid_start")
    try:
        return HookIngressRequest(
            provider,
            log_path_for(provider),
            payload,
            ppid=ppid if isinstance(ppid, int) and not isinstance(ppid, bool) and ppid > 1 else None,
            ppid_start=(
                float(ppid_start)
                if isinstance(ppid_start, (int, float)) and not isinstance(ppid_start, bool)
                else None
            ),
        )
    except ValueError:
        return None


def drain_pending_hooks(
    submit: Callable[[HookIngressRequest], object],
    *,
    state_dir: Path | None = None,
    log_path_for: Callable[[str], str] = _default_log_path,
) -> int:
    """Submit every queued payload in file order. Returns the number submitted."""
    submitted = 0
    for path in pending_hook_files(state_dir):
        draining = path.with_name(f"{path.name}.draining-{os.getpid()}-{int(time.time() * 1000)}")
        try:
            if path.stat().st_size > MAX_PENDING_FILE_BYTES:
                path.unlink()
                continue
            path.rename(draining)
            text = draining.read_text(encoding="utf-8", errors="replace")
        except OSError:
            continue
        for line in text.splitlines()[:MAX_PENDING_LINES_PER_DRAIN]:
            if not line.strip():
                continue
            request = request_from_pending_line(line, log_path_for=log_path_for)
            if request is None:
                continue
            try:
                submit(request)
            except Exception:
                continue
            submitted += 1
        try:
            draining.unlink()
        except OSError:
            pass
    return submitted


class PendingHookDrainer:
    """A daemon thread that drains at start and then on an interval."""

    def __init__(
        self,
        submit: Callable[[HookIngressRequest], object],
        *,
        state_dir: Path | None = None,
        interval_seconds: float = PENDING_DRAIN_INTERVAL_SECONDS,
        log: Callable[[str], None] | None = None,
    ) -> None:
        self._submit = submit
        self._state_dir = state_dir
        self._interval = max(1.0, float(interval_seconds))
        self._log = log or (lambda _line: None)
        self._stop = threading.Event()
        self._thread: threading.Thread | None = None

    def start(self) -> None:
        if self._thread is not None and self._thread.is_alive():
            return
        self._stop.clear()
        self._thread = threading.Thread(target=self._run, name="JRBarPendingHookDrain", daemon=True)
        self._thread.start()

    def stop(self, timeout_seconds: float = 1.0) -> None:
        self._stop.set()
        thread = self._thread
        if thread is not None and thread is not threading.current_thread():
            thread.join(timeout_seconds)
        self._thread = None

    def drain_now(self) -> int:
        count = drain_pending_hooks(self._submit, state_dir=self._state_dir)
        if count:
            self._log(f"hook_pending drained={count}")
        return count

    def _run(self) -> None:
        while not self._stop.is_set():
            try:
                self.drain_now()
            except Exception as exc:
                self._log(f"hook_pending drain failed: {exc}")
            if self._stop.wait(self._interval):
                return


__all__ = [
    "PENDING_DRAIN_INTERVAL_SECONDS",
    "PENDING_SUFFIX",
    "PendingHookDrainer",
    "drain_pending_hooks",
    "pending_hook_files",
    "request_from_pending_line",
]
