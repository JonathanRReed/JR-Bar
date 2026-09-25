"""Notice when the daemon's run loop stops answering, and say where it was.

Most commands run on the daemon's main thread, so anything that blocks the
run loop -- a ``ps`` fork, a tccd round trip, a slow file under a virus
scanner -- shows up as Settings lag in the app. The native samples of past
stalls only showed "waiting on a child process"; this names the Python
call site.

A worker thread posts a no-op to the run loop every ``interval`` seconds.
When one has waited longer than ``threshold``, the watchdog takes the main
thread's Python stack and the command in flight right then, while the
stall is still happening. When the no-op finally runs, the stall is logged
once with its length. Logs are rate-limited; the stalls in between are
counted in the next line. The clock, the post and the stack reader are
injected, so tests drive it by hand.
"""

from __future__ import annotations

import sys
import threading
import time
import traceback
from collections.abc import Callable
from pathlib import Path
from typing import Final

INTERVAL_SECONDS: Final = 0.25
THRESHOLD_SECONDS: Final = 0.75
# A stall this long is logged while it is still going, in case it never ends.
ONGOING_REPORT_SECONDS: Final = 5.0
LOG_EVERY_SECONDS: Final = 30.0
MAX_STACK_FRAMES: Final = 10


def python_stack_of(thread_id: int | None, *, frames=sys._current_frames) -> str:
    """The innermost frames of one thread, as ``file:line function`` joined
    outermost-last, or ``""`` when the thread is not running Python."""
    if thread_id is None:
        return ""
    frame = frames().get(thread_id)
    if frame is None:
        return ""
    entries = traceback.extract_stack(frame)[-MAX_STACK_FRAMES:]
    return " < ".join(
        f"{Path(entry.filename).name}:{entry.lineno} {entry.name}" for entry in reversed(entries)
    )


class RunLoopWatchdog:
    def __init__(
        self,
        *,
        post: Callable[[], None],
        log: Callable[[str], None],
        clock: Callable[[], float] = time.monotonic,
        stack: Callable[[], str] | None = None,
        in_flight: Callable[[], str | None] = lambda: None,
        record: Callable[[float], None] | None = None,
        interval_seconds: float = INTERVAL_SECONDS,
        threshold_seconds: float = THRESHOLD_SECONDS,
        ongoing_report_seconds: float = ONGOING_REPORT_SECONDS,
        log_every_seconds: float = LOG_EVERY_SECONDS,
    ) -> None:
        main_id = threading.main_thread().ident
        self._post = post
        self._log = log
        self._clock = clock
        self._stack = stack if stack is not None else (lambda: python_stack_of(main_id))
        self._in_flight = in_flight
        self._record = record
        self.interval_seconds = interval_seconds
        self._threshold = threshold_seconds
        self._ongoing = ongoing_report_seconds
        self._log_every = log_every_seconds
        self._lock = threading.Lock()
        self._sent_at: float | None = None
        self._answered_at: float | None = None
        self._captured: tuple[str, str | None] | None = None
        self._reported_ongoing = False
        self._last_log_at: float | None = None
        self._suppressed = 0
        self.stalls = 0
        self._stop = threading.Event()
        self._thread: threading.Thread | None = None

    # -- the run loop's side ---------------------------------------------------

    def pong(self) -> None:
        """Called on the run loop when the posted no-op runs."""
        at = self._clock()
        with self._lock:
            self._answered_at = at

    # -- the watchdog's side ---------------------------------------------------

    def tick(self) -> None:
        """One watchdog step: settle the last ping, or wait on it, or post
        the next one."""
        now = self._clock()
        with self._lock:
            sent, answered = self._sent_at, self._answered_at
        if sent is not None and answered is None:
            waited = now - sent
            if waited > self._threshold and self._captured is None:
                # Now, while the run loop is still stuck: afterwards the
                # stack would only show whatever it went on to do.
                self._captured = (self._stack(), self._in_flight())
            if waited > self._ongoing and not self._reported_ongoing:
                self._reported_ongoing = True
                self._report(waited, ongoing=True)
            return
        if sent is not None and answered is not None:
            late = answered - sent
            if late > self._threshold:
                self.stalls += 1
                if self._record is not None:
                    try:
                        self._record(late * 1000.0)
                    except Exception:
                        pass
                if not self._reported_ongoing:
                    self._report(late, ongoing=False)
        with self._lock:
            self._sent_at = now
            self._answered_at = None
        self._captured = None
        self._reported_ongoing = False
        try:
            self._post()
        except Exception:
            with self._lock:
                self._sent_at = None

    def _report(self, seconds: float, *, ongoing: bool) -> None:
        now = self._clock()
        if self._last_log_at is not None and now - self._last_log_at < self._log_every:
            self._suppressed += 1
            return
        stack, command = self._captured or ("", None)
        parts = [f"core: run loop {'stalled for' if ongoing else 'stalled'} {seconds:.2f}s"]
        if ongoing:
            parts.append("and counting")
        if command:
            parts.append(f"in {command}")
        if self._suppressed:
            parts.append(f"(+{self._suppressed} stalls not logged)")
        line = " ".join(parts)
        if stack:
            line += f": {stack}"
        self._last_log_at = now
        self._suppressed = 0
        try:
            self._log(line)
        except Exception:
            pass

    # -- the thread ------------------------------------------------------------

    def start(self) -> None:
        if self._thread is not None:
            return
        self._stop.clear()
        thread = threading.Thread(target=self._run, name="JRBarRunLoopWatchdog", daemon=True)
        self._thread = thread
        thread.start()

    def stop(self) -> None:
        self._stop.set()
        self._thread = None

    def _run(self) -> None:
        while not self._stop.wait(self.interval_seconds):
            try:
                self.tick()
            except Exception:
                pass


__all__ = ["RunLoopWatchdog", "python_stack_of"]
