"""Drain the shim's ``<provider>.pending.jsonl`` files into the ingress FIFO.

When the daemon is not listening, or answers ``refused_full`` or
``refused_closed``, ``jrbar-hook`` appends each payload as one JSON line
``{"provider", "ppid", "ppid_start", "queued_at_ms", "payload"}`` under the
state directory, rotating the file to ``<provider>.overflow.jsonl`` once it
reaches 16 MiB; the Python hook client appends the same line through
``spool_pending_hook``. The daemon drains those files when it starts, every
``PENDING_DRAIN_INTERVAL_SECONDS`` after that, and at once when the ingress
queue that refused a payload is empty again (``nudge_pending_drains``). A
file is renamed before it is read so a shim appending at the same moment
starts a fresh file instead of racing the reader. Every shim appends under
an ``flock`` on the file its path still names, and the drain takes that
lock on the renamed file before it reads: an append already under way
lands first, and a shim that locks later finds the file moved and reopens
the pending path.

A record queued inside ``PENDING_REPLAY_HORIZON_SECONDS`` replays as a live
one, stamped when it is drained; one older than that keeps the time the
shim queued it and reaches the log without waking the live monitor
(hook_ingress).

The drain the daemon runs at launch is bounded. Each line costs about 4 ms,
so a backlog of 5000 lines kept a launch that drained it whole deaf for
about 21 s per provider. ``PendingHookDrainer`` with a
``first_pass_budget_seconds`` drains until the budget is spent, tells the
daemon to hold live hooks behind the rest (``hold_live``), and lets its
worker finish the same pass: the same files, the same lines, the same order.
The worker puts back what it never reached when it is stopped, and releases
the live hooks when the pass is over.
"""

from __future__ import annotations

import fcntl
import json
import math
import os
import threading
import time
from collections import deque
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
# A shim holds its lock for one write. Waiting longer than this means one
# was stopped mid-append, and the drain goes on without the lock rather
# than hold up the daemon behind it.
PENDING_LOCK_WAIT_SECONDS: Final = 1.0
# Reopens of the pending path when a shim rotated it under a requeue.
_APPEND_ATTEMPTS: Final = 8
# The spool's rotation size, the shim's MAX_SPOOL_BYTES (hook/jrbar-hook.c).
MAX_SPOOL_BYTES: Final = 16 * 1024 * 1024
# A nudged drain waits this long first: a shim told refused_full appends
# within its 250 ms budget, and the drain should find the line there.
PENDING_NUDGE_SETTLE_SECONDS: Final = 0.3
# How long the daemon's launch drains the spool before it opens its sockets.
# Long enough for the usual backlog (a restart's few hundred lines) to land
# whole, short enough that a long outage's does not leave the app waiting.
PENDING_STARTUP_BUDGET_SECONDS: Final = 1.5

_drainers_lock = threading.Lock()
_running_drainers: set[PendingHookDrainer] = set()


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
    # The shim writes -1 when it could not read its parent's start, which
    # means the parent was already gone. The start is what stops a replay
    # hours later from registering whatever process reused the pid, so a
    # spooled line without one replays without its ppid too.
    started = (
        float(ppid_start)
        if isinstance(ppid_start, (int, float))
        and not isinstance(ppid_start, bool)
        and ppid_start >= 0
        else None
    )
    # Lines from a shim older than the stamp replay at drain time. A stamp
    # from the future (a clock stepped back, or a corrupt line) is capped
    # at the drain time: past year 9999 the stamp cannot be formatted, and
    # a submit that raises is requeued every pass forever.
    stamp = (
        min(queued_at_ms, time.time() * 1000.0)
        if isinstance(queued_at_ms, int) and not isinstance(queued_at_ms, bool) and queued_at_ms > 0
        else None
    )
    try:
        return HookIngressRequest(
            provider,
            log_path_for(provider),
            payload,
            ppid=(
                ppid
                if isinstance(ppid, int) and not isinstance(ppid, bool) and ppid > 1 and started is not None
                else None
            ),
            ppid_start=started,
            queued_at_epoch=None if stamp is None else stamp / 1000.0,
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


def spool_lines(text: str) -> list[str]:
    """Whole lines of a spool file. A record ends at "\n" only: U+2028,
    U+2029 and U+0085 inside a payload are data (the shim copies bytes at or
    above 0x80 verbatim), which ``str.splitlines`` would cut in half."""
    lines = text.split("\n")
    if lines and lines[-1] == "":
        lines.pop()  # the newline that ended the last record
    return lines


def pending_line_count(path: Path) -> int:
    """How many records wait in the spool file ``path``. Raises ``OSError``
    when it cannot be read, so a caller can say it is unknown."""
    text = path.read_text(encoding="utf-8", errors="replace")
    return sum(1 for line in spool_lines(text) if line.strip())


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


def _lock(descriptor: int, operation: int) -> bool:
    """Take ``operation`` on ``descriptor`` within ``PENDING_LOCK_WAIT_SECONDS``;
    False when the wait ran out."""
    deadline = time.monotonic() + PENDING_LOCK_WAIT_SECONDS
    while True:
        try:
            fcntl.flock(descriptor, operation | fcntl.LOCK_NB)
            return True
        except BlockingIOError:
            if time.monotonic() >= deadline:
                return False
            time.sleep(0.001)


def _names(path: Path, descriptor: int) -> bool:
    """Whether ``path`` still names the file open on ``descriptor``."""
    try:
        at, held = os.lstat(path), os.fstat(descriptor)
    except OSError:
        return False
    return (at.st_dev, at.st_ino) == (held.st_dev, held.st_ino)


def _settle(path: Path) -> None:
    """Wait out every append already under way into ``path``, a spool file
    this drain just renamed.

    The rename moves the file out of the shim's way, but a shim that found
    it just before still writes into it, and the unlink after the read lost
    that line (19 of 200 shims racing a drain every 10 ms). The shim holds
    the lock through its write, so taking it once waits that write out, and
    a shim that locks after this finds its path names another file and
    reopens it: nothing appends here any more. The lock is taken on the
    renamed file, never the live one, so no shim waits on this process."""
    descriptor = os.open(path, os.O_RDONLY | os.O_NOFOLLOW)
    try:
        _lock(descriptor, fcntl.LOCK_EX)
    finally:
        os.close(descriptor)


def _append_lines(path: Path, lines: list[str], *, rotate_to: Path | None = None) -> bool:
    """Append whole lines to ``path`` the way the shim appends: under the
    lock, on the file ``path`` still names, so a shim rotating the spool at
    that moment cannot carry them into the overflow generation, which is
    never replayed. With ``rotate_to`` a file the lines would take past
    ``MAX_SPOOL_BYTES`` is first renamed there, as the shim rotates it."""
    if not lines:
        return True
    data = "".join(line if line.endswith("\n") else f"{line}\n" for line in lines).encode("utf-8")
    for attempt in range(_APPEND_ATTEMPTS):
        try:
            descriptor = os.open(path, os.O_WRONLY | os.O_APPEND | os.O_CREAT | os.O_NOFOLLOW, 0o600)
        except OSError:
            return False
        try:
            # A shim rotated the file between the open and the lock: reopen.
            # Past the attempts the lines go in without the lock, not away.
            locked = _lock(descriptor, fcntl.LOCK_EX)
            last = attempt + 1 >= _APPEND_ATTEMPTS
            if locked and not _names(path, descriptor) and not last:
                continue
            if locked and rotate_to is not None and not last:
                size = os.fstat(descriptor).st_size
                if size and size + len(data) > MAX_SPOOL_BYTES:
                    try:
                        os.rename(path, rotate_to)
                    except OSError:
                        pass  # the line goes past the cap, as the shim's does
                    else:
                        continue
            view = memoryview(data)
            while view:
                view = view[os.write(descriptor, view) :]
            return True
        except OSError:
            return False
        finally:
            os.close(descriptor)
    return False


def spool_pending_hook(
    provider: str,
    payload_text: str,
    *,
    state_dir: Path | None = None,
    now: Callable[[], float] = time.time,
) -> bool:
    """Append one payload to ``<provider>.pending.jsonl`` exactly as the
    compiled shim does, for the Python hook client. The line carries no
    ``ppid``: that client registered its agent process itself before it
    submitted. False when nothing could be written."""
    base = Path(state_dir) if state_dir is not None else default_state_dir()
    line = json.dumps(
        {"provider": provider, "queued_at_ms": int(now() * 1000), "payload": payload_text},
        ensure_ascii=False,
        separators=(",", ":"),
    )
    try:
        base.mkdir(mode=0o700, parents=True, exist_ok=True)
    except OSError:
        return False
    return _append_lines(
        base / f"{provider}{PENDING_SUFFIX}",
        [line],
        rotate_to=base / f"{provider}{OVERFLOW_SUFFIX}",
    )


def nudge_pending_drains() -> None:
    """Drain the spool now rather than at the next interval: the ingress
    calls this once the queue that refused a payload is empty again."""
    with _drainers_lock:
        drainers = tuple(_running_drainers)
    for drainer in drainers:
        drainer.nudge()


class _SpoolFile:
    """One spool file in the middle of a pass: its lines, how far the pass
    got, and what it owes back to disk when it ends."""

    __slots__ = ("draining", "head_bytes", "index", "limit", "lines", "rejected", "retry")

    def __init__(self, draining: Path, lines: list[str], head_bytes: int) -> None:
        self.draining = draining
        self.lines = lines
        # A pass reads at most this many lines of a file; the rest are put
        # back for the next one.
        self.limit = min(len(lines), MAX_PENDING_LINES_PER_DRAIN)
        self.index = 0
        self.head_bytes = head_bytes
        self.retry: list[str] = []
        self.rejected: list[str] = []


class _PendingDrain:
    """One pass over the spool: the files in order, each file's lines in order.

    ``run`` submits until the spool is done or the caller says it is out of
    time, and can be called again to carry on from the same line of the same
    file, so a pass can start on one thread and finish on another with
    nothing skipped or repeated. A file that is not finished stays on disk
    under its draining name until its last line has been submitted.
    """

    def __init__(
        self,
        submit: Callable[[HookIngressRequest], object],
        *,
        state_dir: Path | None,
        log_path_for: Callable[[str], str],
        log: Callable[[str], None],
    ) -> None:
        self._submit = submit
        self._log_path_for = log_path_for
        self._log = log
        # A drain file left behind by a process that died mid-read is adopted
        # before the fresh pending files, so its records keep their order.
        self._paths = deque([*orphaned_drain_files(state_dir), *pending_hook_files(state_dir)])
        self._current: _SpoolFile | None = None
        self.submitted = 0

    def run(
        self,
        *,
        out_of_time: Callable[[], bool] = lambda: False,
        after_file: Callable[[], object] | None = None,
    ) -> bool:
        """Submit until the spool is drained (True) or ``out_of_time()`` is
        true between two lines (False). ``after_file`` runs when a file's
        last line has been submitted and the file is settled."""
        while True:
            if self._current is None:
                if not self._paths:
                    return True
                if out_of_time():
                    return False
                self._current = self._open(self._paths.popleft())
                if self._current is None:
                    continue
            spool = self._current
            while spool.index < spool.limit:
                if out_of_time():
                    return False
                line = spool.lines[spool.index]
                spool.index += 1
                if not line.strip():
                    continue
                request = request_from_pending_line(line, log_path_for=self._log_path_for)
                if request is None:
                    spool.rejected.append(line)
                    continue
                try:
                    self._submit(request)
                except Exception:
                    spool.retry.append(line)
                    continue
                except BaseException:
                    # Torn down mid-line: this line was not delivered, so
                    # ``abandon`` puts it back with the rest (the token
                    # dedupe makes one that did land harmless to replay).
                    spool.index -= 1
                    raise
                self.submitted += 1
            self._current = None
            self._finish(spool)
            if after_file is not None:
                after_file()

    def abandon(self) -> None:
        """Put back what a stopped pass never reached: the rest of the file in
        hand goes back to its pending file in order, behind the lines that
        failed. Files not yet opened were never touched."""
        spool, self._current = self._current, None
        if spool is not None:
            self._finish(spool)

    def _open(self, path: Path) -> _SpoolFile | None:
        adopted = DRAINING_INFIX in path.name
        draining = path.with_name(
            f"{path.name}{DRAINING_INFIX}{os.getpid()}-{int(time.time() * 1000)}"
            if not adopted
            else path.name
        )
        try:
            if not adopted:
                path.rename(draining)
                _settle(draining)
            text, head_bytes = _read_newest(draining, MAX_PENDING_FILE_BYTES)
        except OSError:
            return None
        return _SpoolFile(draining, spool_lines(text), head_bytes)

    def _finish(self, spool: _SpoolFile) -> None:
        """Settle a file: what was rejected is kept, what failed or was never
        reached goes back to the pending file, an oversized file's head is
        kept as the overflow generation, and the draining file goes."""
        draining = spool.draining
        # What a finished file never reached is the lines past the per-pass
        # cap; what a stopped pass never reached is everything from where it
        # stopped. Both are put back after the lines that failed.
        retry = [*spool.retry, *spool.lines[spool.index :]]
        if spool.rejected:
            rejected_path = _sibling(draining, REJECTED_SUFFIX)
            # One rotation, bounded: an earlier rejected file this size has
            # already said what it had to say.
            try:
                if rejected_path.stat().st_size > MAX_REJECTED_FILE_BYTES:
                    rejected_path.unlink()
            except OSError:
                pass
            if not _append_lines(rejected_path, spool.rejected):
                self._log(f"hook_pending could not retain {len(spool.rejected)} rejected lines for {rejected_path.name}")
        if retry:
            pending_path = draining.with_name(_pending_name(draining.name))
            if not _append_lines(pending_path, retry):
                # The write failed -- keep the draining file so the records
                # survive as an orphan for the next drain to adopt.
                self._log(f"hook_pending could not requeue {len(retry)} lines; keeping {draining.name}")
                return
        if spool.head_bytes:
            overflow = _sibling(draining, OVERFLOW_SUFFIX)
            try:
                os.truncate(draining, spool.head_bytes)
                draining.replace(overflow)
                self._log(
                    f"hook_pending oversized file: drained its newest lines, kept {spool.head_bytes} older bytes in {overflow.name}"
                )
                return
            except OSError:
                pass
        try:
            draining.unlink()
        except OSError:
            pass


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
    drain = _PendingDrain(
        submit,
        state_dir=state_dir,
        log_path_for=log_path_for,
        log=log or (lambda _line: None),
    )
    drain.run()
    return drain.submitted


class PendingHookDrainer:
    """A daemon thread that drains at start and then on an interval.

    With ``first_pass_budget_seconds`` the first ``drain_now`` (the daemon's
    launch pass, before its sockets open) stops once the budget is spent on
    ``clock`` and calls ``hold_live``: the daemon holds live hooks behind the
    rest of the backlog, because a spooled prompt replayed after the live
    Stop that followed it would land on top of it. The thread ``start`` runs
    then finishes that same pass -- the same files and lines, in the same
    order, through the same deduplicators -- and calls ``release_live`` when
    it is over, or when it is stopped, after putting back what it never
    reached.
    """

    def __init__(
        self,
        submit: Callable[[HookIngressRequest], object],
        *,
        state_dir: Path | None = None,
        interval_seconds: float = PENDING_DRAIN_INTERVAL_SECONDS,
        after_drain: Callable[[], object] | None = None,
        log: Callable[[str], None] | None = None,
        first_pass_budget_seconds: float | None = None,
        clock: Callable[[], float] = time.monotonic,
        hold_live: Callable[[], object] | None = None,
        release_live: Callable[[], object] | None = None,
    ) -> None:
        if first_pass_budget_seconds is not None and not (
            isinstance(first_pass_budget_seconds, (int, float))
            and not isinstance(first_pass_budget_seconds, bool)
            and math.isfinite(float(first_pass_budget_seconds))
            and first_pass_budget_seconds >= 0.0
        ):
            raise ValueError("invalid first pass budget")
        self._submit = submit
        # Runs once at the end of every pass, whatever it submitted: the
        # daemon applies the refresh hints the pass held back here.
        self._after_drain = after_drain
        self._state_dir = state_dir
        self._interval = max(1.0, float(interval_seconds))
        self._log = log or (lambda _line: None)
        self._first_pass_budget = first_pass_budget_seconds
        self._clock = clock
        self._hold_live = hold_live
        self._release_live = release_live
        # The first pass, when its budget ran out before the spool did.
        self._resume: _PendingDrain | None = None
        self._resume_lock = threading.Lock()
        self._stop = threading.Event()
        self._wake = threading.Event()
        self._thread: threading.Thread | None = None

    def start(self) -> None:
        if self._thread is not None and self._thread.is_alive():
            return
        self._stop.clear()
        self._wake.clear()
        self._thread = threading.Thread(target=self._run, name="JRBarPendingHookDrain", daemon=True)
        with _drainers_lock:
            _running_drainers.add(self)
        self._thread.start()

    def stop(self, timeout_seconds: float = 1.0) -> None:
        with _drainers_lock:
            _running_drainers.discard(self)
        self._stop.set()
        self._wake.set()
        thread = self._thread
        if thread is not None and thread is not threading.current_thread():
            thread.join(timeout_seconds)
        self._thread = None
        # A first pass nobody finished (the worker never started): put back
        # what it never reached and let the live hooks go.
        drain = self._take_resume()
        if drain is not None:
            try:
                drain.abandon()
            except Exception as exc:
                self._log(f"hook_pending could not put back the unfinished startup drain: {exc}")
            self._release()

    def nudge(self) -> None:
        """Run the next pass now (after ``PENDING_NUDGE_SETTLE_SECONDS``)
        instead of at the end of the interval."""
        self._wake.set()

    def drain_now(self) -> int:
        budget, self._first_pass_budget = self._first_pass_budget, None
        if budget is not None:
            return self._drain_first_pass(budget)
        try:
            count = drain_pending_hooks(self._submit, state_dir=self._state_dir, log=self._log)
        finally:
            self._after_pass()
        if count:
            self._log(f"hook_pending drained={count}")
        return count

    def _after_pass(self) -> None:
        if self._after_drain is not None:
            try:
                self._after_drain()
            except Exception as exc:
                self._log(f"hook_pending after-drain failed: {exc}")

    def _drain_first_pass(self, budget_seconds: float) -> int:
        deadline = self._clock() + budget_seconds
        drain = _PendingDrain(
            self._submit,
            state_dir=self._state_dir,
            log_path_for=_default_log_path,
            log=self._log,
        )
        try:
            done = drain.run(out_of_time=lambda: self._clock() >= deadline)
        except BaseException:
            # Whatever the pass had in hand goes back to its pending file: a
            # draining file owned by this live process is never adopted.
            try:
                drain.abandon()
            finally:
                self._after_pass()
            raise
        self._after_pass()
        if not done:
            with self._resume_lock:
                self._resume = drain
            if self._hold_live is not None:
                try:
                    self._hold_live()
                except Exception as exc:
                    self._log(f"hook_pending could not hold live hooks: {exc}")
            self._log(
                f"hook_pending startup drain: {drain.submitted} lines inside the budget, the rest continues on the worker"
            )
        elif drain.submitted:
            self._log(f"hook_pending drained={drain.submitted}")
        return drain.submitted

    def _take_resume(self) -> _PendingDrain | None:
        with self._resume_lock:
            drain, self._resume = self._resume, None
        return drain

    def _release(self) -> None:
        if self._release_live is not None:
            try:
                self._release_live()
            except Exception as exc:
                self._log(f"hook_pending could not release live hooks: {exc}")

    def _finish_first_pass(self) -> None:
        """Carry on with the first pass where the launch left off, on this
        thread: no budget now, the same order. Stopping puts the rest back."""
        drain = self._take_resume()
        if drain is None:
            return
        try:
            if not drain.run(out_of_time=self._stop.is_set, after_file=self._after_pass):
                drain.abandon()
        except BaseException as exc:
            self._log(f"hook_pending startup drain failed: {exc!r}")
            try:
                drain.abandon()
            except Exception:
                pass
            if not isinstance(exc, Exception):
                raise
        finally:
            self._after_pass()
            self._release()
        self._log(f"hook_pending startup drain finished: {drain.submitted} more lines")

    def _run(self) -> None:
        while not self._stop.is_set():
            try:
                self._finish_first_pass()
                # A stop that cut the first pass short has put its rest back
                # for the next daemon; draining it again here would not.
                if not self._stop.is_set():
                    self.drain_now()
                    self._finish_first_pass()
            except Exception as exc:
                self._log(f"hook_pending drain failed: {exc}")
            self._wake.wait(self._interval)
            if self._wake.is_set():
                self._wake.clear()
                if self._stop.wait(PENDING_NUDGE_SETTLE_SECONDS):
                    return


__all__ = [
    "PENDING_DRAIN_INTERVAL_SECONDS",
    "PENDING_REPLAY_HORIZON_SECONDS",
    "PENDING_STARTUP_BUDGET_SECONDS",
    "PENDING_SUFFIX",
    "PendingHookDrainer",
    "drain_pending_hooks",
    "nudge_pending_drains",
    "pending_hook_files",
    "request_from_pending_line",
    "spool_pending_hook",
]
