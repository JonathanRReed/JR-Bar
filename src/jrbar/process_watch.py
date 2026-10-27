"""The process a "while this runs" keep-awake hold waits on.

``jrbar awake -- swift test`` and ``jrbar awake --pid 4242`` hold the Mac
awake until one process exits. Two facts about that process matter: who it
is (its pid and when it started, so a pid the system hands to someone else
after a restart is never mistaken for it) and its short name ("swift"),
which is all a surface ever shows. Never its arguments: a command line can
carry a token.

The exit is learnt from the kernel, not by asking again and again: one
``kqueue`` ``NOTE_EXIT`` watch on a thread of its own, woken once when the
process ends, or by a pipe when the hold changes first.
"""

from __future__ import annotations

import ctypes
import os
import select
import threading
from collections.abc import Callable
from dataclasses import dataclass

#: The longest name a surface shows for the process.
MAX_PROCESS_LABEL_LENGTH = 32
_PROC_PIDTBSDINFO = 3


@dataclass(frozen=True, slots=True)
class ProcessIdentity:
    """One running process: its pid, when it started (microseconds since
    the epoch) and its short name."""

    pid: int
    started: int
    name: str


class _ProcBsdInfo(ctypes.Structure):
    _fields_ = [
        ("pbi_flags", ctypes.c_uint32),
        ("pbi_status", ctypes.c_uint32),
        ("pbi_xstatus", ctypes.c_int32),
        ("pbi_pid", ctypes.c_uint32),
        ("pbi_ppid", ctypes.c_uint32),
        ("pbi_uid", ctypes.c_uint32),
        ("pbi_gid", ctypes.c_uint32),
        ("pbi_ruid", ctypes.c_uint32),
        ("pbi_rgid", ctypes.c_uint32),
        ("pbi_svuid", ctypes.c_uint32),
        ("pbi_svgid", ctypes.c_uint32),
        ("rfu_1", ctypes.c_uint32),
        ("pbi_comm", ctypes.c_char * 16),
        ("pbi_name", ctypes.c_char * 32),
        ("pbi_nfiles", ctypes.c_uint32),
        ("pbi_pgid", ctypes.c_uint32),
        ("pbi_pjobc", ctypes.c_uint32),
        ("e_tdev", ctypes.c_uint32),
        ("e_tpgid", ctypes.c_uint32),
        ("pbi_nice", ctypes.c_int32),
        ("pbi_start_tvsec", ctypes.c_uint64),
        ("pbi_start_tvusec", ctypes.c_uint64),
    ]


def valid_pid(value: object) -> bool:
    """A pid a hold may wait on: a positive int, never the kernel or launchd."""
    return type(value) is int and 1 < value <= 0x7FFFFFFF


def process_label(value: object) -> str | None:
    """A process's short name as a surface may show it: the last path
    component, trimmed, printable, at most 32 characters, and nothing that
    reads like an argument or an assignment. None when ``value`` is not one."""
    if type(value) is not str:
        return None
    text = os.path.basename(value.strip()).strip()
    if (
        not text
        or len(text) > MAX_PROCESS_LABEL_LENGTH
        or not text.isprintable()
        or text.startswith("-")
        or "=" in text
    ):
        return None
    return text


def read_identity(pid: int) -> ProcessIdentity | None:
    """Who ``pid`` is right now, from ``proc_pidinfo``; None when no such
    process runs (or the system will not say)."""
    if not valid_pid(pid):
        return None
    try:
        libproc = ctypes.CDLL("/usr/lib/libproc.dylib", use_errno=True)
        libproc.proc_pidinfo.argtypes = [
            ctypes.c_int,
            ctypes.c_int,
            ctypes.c_uint64,
            ctypes.c_void_p,
            ctypes.c_int,
        ]
        libproc.proc_pidinfo.restype = ctypes.c_int
        info = _ProcBsdInfo()
        size = ctypes.sizeof(info)
        if libproc.proc_pidinfo(pid, _PROC_PIDTBSDINFO, 0, ctypes.byref(info), size) != size:
            return None
    except (AttributeError, OSError, ValueError):
        return None
    raw = info.pbi_name or info.pbi_comm
    name = process_label(raw.decode("utf-8", "replace")) or "a process"
    started = int(info.pbi_start_tvsec) * 1_000_000 + int(info.pbi_start_tvusec)
    return ProcessIdentity(pid=pid, started=started, name=name)


class ProcessExitWatch:
    """One ``NOTE_EXIT`` watch. ``on_exit`` runs once, on the watch's own
    thread, when the process ends -- at once when it has already gone.
    ``cancel()`` wakes the thread through a pipe; it then ends without
    calling ``on_exit``. Nothing here ticks: the thread sleeps in the
    kernel until one of the two things happens."""

    def __init__(
        self,
        pid: int,
        on_exit: Callable[[], None],
        *,
        start: bool = True,
    ) -> None:
        self.pid = pid
        self._on_exit = on_exit
        self._cancelled = threading.Event()
        self._fired = threading.Event()
        self._wake_read, self._wake_write = os.pipe()
        # The pipe closes when the thread ends; a cancel after that must
        # never write to a descriptor number the process has reused.
        self._pipe_lock = threading.Lock()
        self._pipe_open = True
        self._thread = threading.Thread(target=self._run, name="JRBarProcessExitWatch", daemon=True)
        self._started = start
        if start:
            self._thread.start()

    @property
    def fired(self) -> bool:
        return self._fired.is_set()

    def wait_fired(self, timeout: float) -> bool:
        """For tests: wait at most ``timeout`` for the exit to be heard."""
        return self._fired.wait(timeout)

    def cancel(self) -> None:
        if self._cancelled.is_set():
            return
        self._cancelled.set()
        if not self._started:
            self._close_pipe()
            return
        with self._pipe_lock:
            if not self._pipe_open:
                return
            try:
                os.write(self._wake_write, b"x")
            except OSError:
                pass

    def _fire(self) -> None:
        if self._cancelled.is_set() or self._fired.is_set():
            return
        self._fired.set()
        try:
            self._on_exit()
        except Exception:
            pass

    def _run(self) -> None:
        queue = None
        try:
            queue = select.kqueue()
            watch = select.kevent(
                self.pid,
                filter=select.KQ_FILTER_PROC,
                flags=select.KQ_EV_ADD | select.KQ_EV_ONESHOT,
                fflags=select.KQ_NOTE_EXIT,
            )
            wake = select.kevent(
                self._wake_read,
                filter=select.KQ_FILTER_READ,
                flags=select.KQ_EV_ADD,
            )
            try:
                queue.control([watch], 0, 0)
            except ProcessLookupError:
                # Gone before the watch could start: that is the exit.
                self._fire()
                return
            queue.control([wake], 0, 0)
            while not self._cancelled.is_set():
                events = queue.control(None, 2, None)
                if any(event.filter == select.KQ_FILTER_PROC for event in events):
                    self._fire()
                    return
        except OSError:
            # A watch the kernel refused is not an exit; the hold keeps its
            # own 24-hour bound.
            return
        finally:
            if queue is not None:
                queue.close()
            self._close_pipe()

    def _close_pipe(self) -> None:
        with self._pipe_lock:
            if not self._pipe_open:
                return
            self._pipe_open = False
            for descriptor in (self._wake_read, self._wake_write):
                try:
                    os.close(descriptor)
                except OSError:
                    pass


__all__ = [
    "MAX_PROCESS_LABEL_LENGTH",
    "ProcessExitWatch",
    "ProcessIdentity",
    "process_label",
    "read_identity",
    "valid_pid",
]
