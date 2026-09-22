"""Pin hidapi's global IOHIDManager to a run loop that never dies.

hidapi's Darwin backend lazily creates one process-global
``IOHIDManager`` on the first ``enumerate``/``device`` call and schedules
it on *that calling thread's* ``CFRunLoop``. When that thread exits, the
manager keeps a dead run-loop pointer and the next enumeration -- or a
device arriving mid-enumeration -- dies on a pointer-authentication trap
inside CoreFoundation, taking the whole daemon with it.

Probe workers, the output owner, and setup helpers each run on their own
threads, so whichever happens to touch hidapi first wins the binding --
and the previous fix (pin enumeration to one thread) only guarded the
probe path. Rather than funnel every hidapi call through one executor --
the output owner holds a persistent device and a polling loop that would
starve everything else -- this module inits the manager once on a
thread that lives for the process's lifetime and keeps its run loop
*running*, so device-matching callbacks keep ``CopyDevices`` current for
every caller.
"""

from __future__ import annotations

import sys
import threading

_lock = threading.Lock()
_ready = threading.Event()
_error: BaseException | None = None
_stop = threading.Event()
_thread: threading.Thread | None = None


def _bind() -> None:
    """Init hidapi on this thread, then pump its run loop forever.

    The first ``enumerate`` makes hidapi schedule its global
    ``IOHIDManager`` on THIS thread's run loop. The loop must then keep
    running for two reasons: the manager's device-matching callbacks are
    delivered on it (a parked loop leaves ``IOHIDManagerCopyDevices``
    answering a stale set, so hotplug probes would stop seeing arrivals),
    and the thread must never exit while the manager is bound to it.
    """
    global _error
    try:
        # A run loop with no sources makes CFRunLoopRunInMode return
        # kCFRunLoopRunFinished instantly -- the pump would spin at a
        # full core. An empty mach port is the classic keep-alive: one
        # permanent source, never firing, so the loop truly sleeps
        # between matching callbacks. Resolve it BEFORE binding: if
        # PyObjC is absent the pump must fall back now, not fail after
        # ``_ready`` and leave a dying thread bound.
        try:
            from Foundation import (  # type: ignore[import-not-found]
                NSDate,
                NSDefaultRunLoopMode,
                NSMachPort,
                NSRunLoop,
            )

            pump = "nsrunloop"
        except ImportError:
            pump = "wait"

        import hid  # type: ignore[import-not-found]

        # First hidapi call on THIS thread: hid_init -> init_hid_manager
        # schedules the global manager on this run loop.
        hid.enumerate()
    except BaseException as error:  # noqa: BLE001 -- surfaced to callers
        _error = error
        _ready.set()
        return
    _ready.set()
    if pump == "nsrunloop":
        loop = NSRunLoop.currentRunLoop()
        # The port is retained by the loop while scheduled; the local
        # stays referenced here so nothing collects the source.
        keepalive = NSMachPort.port()
        loop.addPort_forMode_(keepalive, NSDefaultRunLoopMode)
        while not _stop.is_set():
            loop.runMode_beforeDate_(
                NSDefaultRunLoopMode,
                NSDate.dateWithTimeIntervalSinceNow_(0.5),
            )
    else:
        # No run-loop machinery: the binding alone still prevents the
        # dead-run-loop crash (the thread never exits); device-matching
        # callbacks just go unpumped, matching pre-affinity behaviour.
        while not _stop.is_set():
            _stop.wait(0.5)


def ensure_hid_binding() -> None:
    """Guarantee hidapi's manager is bound to the immortal worker.

    Idempotent and fast once bound. Raises ``OSError`` when hidapi itself
    is unavailable or the binding could not be established -- callers
    already translate that into ``transport_unavailable``.
    """
    if sys.platform != "darwin":
        return
    global _thread
    if _ready.is_set():
        if _error is not None:
            raise OSError(f"hidapi binding failed: {_error}") from _error
        return
    with _lock:
        if _thread is None:
            _thread = threading.Thread(
                target=_bind, name="JRBarHidAffinity", daemon=True
            )
            _thread.start()
    if not _ready.wait(5.0):
        raise OSError("hidapi binding timed out")
    if _error is not None:
        raise OSError(f"hidapi binding failed: {_error}") from _error


__all__ = ["ensure_hid_binding"]
