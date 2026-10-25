"""Detect the T3 desktop host without starting a process or opening its data."""
from __future__ import annotations

import ctypes
import sys
import time
from functools import lru_cache


@lru_cache(maxsize=1)
def _libproc():
    if sys.platform != "darwin":
        return None
    try:
        lib = ctypes.CDLL("/usr/lib/libproc.dylib")
        lib.proc_listpids.argtypes = [ctypes.c_uint32, ctypes.c_uint32, ctypes.c_void_p, ctypes.c_int]
        lib.proc_listpids.restype = ctypes.c_int
        lib.proc_name.argtypes = [ctypes.c_int, ctypes.c_void_p, ctypes.c_uint32]
        lib.proc_name.restype = ctypes.c_int
        lib.proc_pidpath.argtypes = [ctypes.c_int, ctypes.c_void_p, ctypes.c_uint32]
        lib.proc_pidpath.restype = ctypes.c_int
        return lib
    except OSError:
        return None


_cached = (0.0, False)


def t3_code_running() -> bool:
    global _cached
    now = time.monotonic()
    if now < _cached[0]:
        return _cached[1]
    lib = _libproc()
    running = False
    if lib is not None:
        size = lib.proc_listpids(1, 0, None, 0)
        pids = (ctypes.c_int * (max(0, size) // ctypes.sizeof(ctypes.c_int) + 256))()
        count = lib.proc_listpids(1, 0, pids, ctypes.sizeof(pids)) // ctypes.sizeof(ctypes.c_int)
        name = ctypes.create_string_buffer(256)
        path = ctypes.create_string_buffer(4096)
        for pid in pids[:max(0, count)]:
            if pid <= 0 or lib.proc_name(pid, name, len(name)) <= 0:
                continue
            if not name.value.lower().startswith((b"t3 code", b"t3-code", b"t3code")):
                continue
            if lib.proc_pidpath(pid, path, len(path)) <= 0:
                continue
            executable = path.value.lower()
            if any(bundle in executable for bundle in (b"/t3 code.app/contents/macos/", b"/t3 code nightly.app/contents/macos/", b"/t3 code (nightly).app/contents/macos/")):
                running = True
                break
    _cached = (now + 2.0, running)
    return running
