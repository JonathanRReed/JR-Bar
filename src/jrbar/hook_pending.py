"""Drain the shim's ``<provider>.pending.jsonl`` files into the ingress FIFO.

When the daemon is not listening, ``jrbar-hook`` appends each payload as one
JSON line ``{"provider", "ppid", "ppid_start", "queued_at_ms", "payload"}``
under the state directory, rotating the file to ``<provider>.overflow.jsonl``
once it reaches 16 MiB. The daemon drains those files when it starts and
every ``PENDING_DRAIN_INTERVAL_SECONDS`` after that. A file is renamed before
it is read so a shim appending at the same moment starts a fresh file
instead of racing the reader.

A replayed record keeps the time the shim queued it; one older than
``PENDING_REPLAY_HORIZON_SECONDS`` still reaches the log but does not wake
the live monitor (hook_ingress).
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
# No drain reads more than this: an oversized file drains its newest bytes
# and keeps the older head as the overflow generation.
MAX_PENDING_FILE_BYTES: Final = 64 * 1024 * 1024
# A spooled payload older than this is history, not a live turn.
PENDING_REPLAY_HORIZON_SECONDS: Final = 30 * 60.0
MAX_PENDING_LINES_PER_DRAIN: Final = 5000
DRAINING_INFIX: Final = ".draining-"
REJECTED_SUFFIX: Final = ".rejected.jsonl"
OVERFLOW_SUFFIX: Final = ".overflow.jsonl"
MAX_REJECTED_FILE_BYTES: Final = 16 * 1024 * 1024


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


def _drain_owner_pid(name: str) -> int | None:
    """The pid embedded in a ``…pending.jsonl.draining-<pid>-<ms>`` name."""
    marker = f"{PENDING_SUFFIX}{DRAINING_INFIX}"
    if marker not in name:
        return None
    try:
        return int(name.rsplit(marker, 1)[1].split("-", 1)[0])
    except (IndexError, ValueError):
        return None


def _pid_alive(pid: int) -> bool:
    if pid <= 1:
        return False
    try:
        os.kill(pid, 0)
    except OSError as exc:  # ESRCH means gone; EPERM means alive but foreign.
        import errno

        return exc.errno == errno.EPERM
    return True


def orphaned_drain_files(state_dir: Path | None = None) -> list[Path]:
    """Drain files whose owning process died before it finished reading.

    ``drain_pending_hooks`` renames a pending file before reading it, so a
    shim appending at that moment starts a fresh file instead of racing the
    reader. The cost is that a crash between the rename and the unlink
    strands every record in the renamed file: nothing looks at that name
    again. A HID crash loop on 2026-09-10 left 36 such files holding 226
    records. These are adopted on the next drain; the ingress deduplicates
    by event token, so a record that did reach the log is not counted twice.
    """
    base = Path(state_dir) if state_dir is not None else default_state_dir()
    orphans: list[Path] = []
    try:
        entries = list(base.iterdir())
    except OSError:
        return []
    for path in entries:
        if not path.is_file() or path.is_symlink():
            continue
        owner = _drain_owner_pid(path.name)
        if owner is None or _pid_alive(owner):
            continue
        orphans.append(path)
    return sorted(orphans)


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
    queued_at_ms = row.get("queued_at_ms")
    try:
        return HookIngressRequest(
            provider,
            log_path_for(provider),
            payload,
            ppid=ppid if isinstance(ppid, int) and not isinstance(ppid, bool) and ppid > 1 else None,
            # The shim writes -1 when it could not read its parent's start.
            ppid_start=(
                float(ppid_start)
                if isinstance(ppid_start, (int, float))
                and not isinstance(ppid_start, bool)
                and ppid_start >= 0
                else None
            ),
            # Lines from a shim older than the stamp replay at drain time.
            queued_at_epoch=(
                queued_at_ms / 1000.0
                if isinstance(queued_at_ms, int) and not isinstance(queued_at_ms, bool) and queued_at_ms > 0
                else None
            ),
        )
    except ValueError:
        return None


def _pending_name(draining_name: str) -> str:
    """The ``<provider>.pending.jsonl`` a draining file was renamed from."""
    marker = f"{PENDING_SUFFIX}{DRAINING_INFIX}"
    if marker in draining_name:
        return draining_name.split(marker, 1)[0] + PENDING_SUFFIX
    return draining_name


def _sibling(path: Path, suffix: str) -> Path:
    """``claude.pending.jsonl`` -> ``claude<suffix>``."""
    pending = _pending_name(path.name)
    base = pending[: -len(PENDING_SUFFIX)] if pending.endswith(PENDING_SUFFIX) else pending
    return path.with_name(base + suffix)


def _read_newest(path: Path, limit: int) -> tuple[str, int]:
    """The text of ``path``'s newest whole lines within ``limit`` bytes, and
    the size of the older head left unread (0 when the file fits)."""
    with open(path, "rb") as handle:
        size = os.fstat(handle.fileno()).st_size
        if size <= limit:
            return handle.read().decode("utf-8", errors="replace"), 0
        # One byte early, so a tail that starts exactly on a line boundary
        # keeps its first line.
        start = size - limit - 1
        handle.seek(start)
        tail = handle.read(limit + 1)
    cut = tail.find(b"\n") + 1
    if not cut:  # no line ends in the window: all of it is head
        return "", start + len(tail)
    return tail[cut:].decode("utf-8", errors="replace"), start + cut


def _append_lines(path: Path, lines: list[str]) -> bool:
    """Append whole lines to ``path``; append-mode keeps pace with a shim
    writing the same file at the same moment."""
    if not lines:
        return True
    try:
        with open(path, "a", encoding="utf-8") as handle:
            handle.write("".join(line if line.endswith("\n") else f"{line}\n" for line in lines))
        return True
    except OSError:
        return False


def drain_pending_hooks(
    submit: Callable[[HookIngressRequest], object],
    *,
    state_dir: Path | None = None,
    log_path_for: Callable[[str], str] = _default_log_path,
    log: Callable[[str], None] | None = None,
) -> int:
    """Submit every queued payload in file order. Returns the number submitted.

    Nothing the drain cannot deliver is silently dropped: lines past
    ``MAX_PENDING_LINES_PER_DRAIN`` and lines whose submit raised are
    appended back to the pending file for the next pass; malformed lines
    are written to ``<provider>.rejected.jsonl`` so a corrupt record is
    accounted for rather than unlinked; a file over
    ``MAX_PENDING_FILE_BYTES`` drains its newest ``MAX_PENDING_FILE_BYTES``
    and its older head is kept as ``.overflow.jsonl`` (one generation, the
    same file the shim rotates into) -- the newest events are the ones live
    state needs, where quarantining the whole file replayed none of them.
    """
    log = log or (lambda _line: None)
    submitted = 0
    # A drain file left behind by a process that died mid-read is adopted
    # before the fresh pending files, so its records keep their order.
    for path in [*orphaned_drain_files(state_dir), *pending_hook_files(state_dir)]:
        adopted = DRAINING_INFIX in path.name
        draining = path.with_name(
            f"{path.name}{DRAINING_INFIX}{os.getpid()}-{int(time.time() * 1000)}"
            if not adopted
            else path.name
        )
        try:
            if not adopted:
                path.rename(draining)
            text, head_bytes = _read_newest(draining, MAX_PENDING_FILE_BYTES)
        except OSError:
            continue
        lines = text.splitlines()
        retry: list[str] = []
        rejected: list[str] = []
        for line in lines[:MAX_PENDING_LINES_PER_DRAIN]:
            if not line.strip():
                continue
            request = request_from_pending_line(line, log_path_for=log_path_for)
            if request is None:
                rejected.append(line)
                continue
            try:
                submit(request)
            except Exception:
                retry.append(line)
                continue
            submitted += 1
        retry.extend(lines[MAX_PENDING_LINES_PER_DRAIN:])
        if rejected:
            rejected_path = _sibling(draining, REJECTED_SUFFIX)
            # One rotation, bounded: an earlier rejected file this size has
            # already said what it had to say.
            try:
                if rejected_path.stat().st_size > MAX_REJECTED_FILE_BYTES:
                    rejected_path.unlink()
            except OSError:
                pass
            if not _append_lines(rejected_path, rejected):
                log(f"hook_pending could not retain {len(rejected)} rejected lines for {rejected_path.name}")
        if retry:
            pending_path = draining.with_name(_pending_name(draining.name))
            if not _append_lines(pending_path, retry):
                # The write failed -- keep the draining file so the records
                # survive as an orphan for the next drain to adopt.
                log(f"hook_pending could not requeue {len(retry)} lines; keeping {draining.name}")
                continue
        if head_bytes:
            overflow = _sibling(draining, OVERFLOW_SUFFIX)
            try:
                os.truncate(draining, head_bytes)
                draining.replace(overflow)
                log(f"hook_pending oversized file: drained its newest lines, kept {head_bytes} older bytes in {overflow.name}")
                continue
            except OSError:
                pass
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
        count = drain_pending_hooks(self._submit, state_dir=self._state_dir, log=self._log)
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
    "PENDING_REPLAY_HORIZON_SECONDS",
    "PENDING_SUFFIX",
    "PendingHookDrainer",
    "drain_pending_hooks",
    "pending_hook_files",
    "request_from_pending_line",
]
