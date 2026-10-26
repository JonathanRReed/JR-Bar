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
#: How long the pump sleeps in its run loop between looks at ``_stop``.
#: Nothing sets ``_stop`` while the daemon lives, and a device arriving wakes
#: the loop at once, so a short beat here only woke an idle thread twice a
#: second for the life of the process.
PUMP_WAKE_SECONDS = 3600.0


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
        from .native_run_loop import Pump

        pump = Pump()

        import hid  # type: ignore[import-not-found]

        # First hidapi call on THIS thread: hid_init -> init_hid_manager
        # schedules the global manager on this run loop.
        hid.enumerate()
    except BaseException as error:  # surfaced to callers
        _error = error
        _ready.set()
        return
    _ready.set()
    try:
        while not _stop.is_set():
            pump.run(PUMP_WAKE_SECONDS)
    finally:
        pump.close()


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
