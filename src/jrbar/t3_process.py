"""Detect T3 desktop and CLI hosts without starting a process or opening data."""
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


T3_MISSING_POLL_SECONDS = 60.0
T3_STOPPED_POLL_SECONDS = 30.0

_cached = (0.0, False)
_cached_base = None


def t3_code_running(*, base_dir=None) -> bool:
    global _cached, _cached_base
    now = time.monotonic()
    if now < _cached[0] and base_dir == _cached_base:
        return _cached[1]
    from .t3_compat import T3_DATABASE_RELATIVE_PATH, T3_V2_DATABASE_RELATIVE_PATH, _t3_root

    root = _t3_root(base_dir)
    _cached_base = base_dir
    if not any((root / relative).is_file() for relative in (T3_DATABASE_RELATIVE_PATH, T3_V2_DATABASE_RELATIVE_PATH)):
        _cached = (now + T3_MISSING_POLL_SECONDS, False)
        return False
    lib = _libproc()
    running = False
    if lib is not None:
        size = lib.proc_listpids(1, 0, None, 0)
        pids = (ctypes.c_int * (max(0, size) // ctypes.sizeof(ctypes.c_int) + 256))()
        count = lib.proc_listpids(1, 0, pids, ctypes.sizeof(pids)) // ctypes.sizeof(ctypes.c_int)
        name = ctypes.create_string_buffer(256)
        path = ctypes.create_string_buffer(4096)
        headless = []
        for pid in pids[:max(0, count)]:
            if pid <= 0 or lib.proc_name(pid, name, len(name)) <= 0:
                continue
            process_name = name.value.lower()
            t3_named = process_name.startswith((b"t3 code", b"t3-code", b"t3code"))
            if not t3_named and process_name not in {b"node", b"bun"}:
                continue
            if lib.proc_pidpath(pid, path, len(path)) <= 0:
                continue
            executable = path.value.lower()
            if t3_named and any(bundle in executable for bundle in (b"/t3 code.app/contents/macos/", b"/t3 code nightly.app/contents/macos/", b"/t3 code (nightly).app/contents/macos/")):
                running = True
                break
            headless.append(pid)
        if not running:
            for pid in headless:
                uses_database = (_uses_t3_database(lib, pid) if base_dir is None
                                 else _uses_t3_database(lib, pid, base_dir=base_dir))
                if uses_database:
                    running = True
                    break
    _cached_base = base_dir
    _cached = (now + (2.0 if running else T3_STOPPED_POLL_SECONDS), running)
    return running


def _uses_t3_database(lib, pid: int, *, base_dir=None) -> bool:
    """A CLI host must hold this integration's database, not just a T3 name."""
    from .t3_compat import T3_DATABASE_RELATIVE_PATH, T3_V2_DATABASE_RELATIVE_PATH, _t3_root

    root = _t3_root(base_dir).resolve()
    paths = {str(root / relative).encode() for relative in (T3_DATABASE_RELATIVE_PATH, T3_V2_DATABASE_RELATIVE_PATH)}
    try:
        list_fds = lib.proc_pidinfo
        list_fds.argtypes = [ctypes.c_int, ctypes.c_int, ctypes.c_uint64, ctypes.c_void_p, ctypes.c_int]
        list_fds.restype = ctypes.c_int
        fd_info = lib.proc_pidfdinfo
        fd_info.argtypes = [ctypes.c_int, ctypes.c_int, ctypes.c_int, ctypes.c_void_p, ctypes.c_int]
        fd_info.restype = ctypes.c_int
        descriptors = (ctypes.c_int * (4096 * 2))()
        size = list_fds(pid, 1, 0, descriptors, ctypes.sizeof(descriptors))
        vnode = ctypes.create_string_buffer(4096)
        # proc_fdinfo is a pair of 32-bit fd/type fields. A vnode path is
        # the final MAXPATHLEN bytes of vnode_fdinfowithpath in proc_info.h.
        for offset in range(0, max(0, size) // ctypes.sizeof(ctypes.c_int) - 1, 2):
            if descriptors[offset + 1] != 1:  # PROX_FDTYPE_VNODE
                continue
            length = fd_info(pid, descriptors[offset], 2, vnode, len(vnode))
            if 1024 <= length <= len(vnode):
                path = vnode.raw[length - 1024:length].split(b'\0', 1)[0]
                if path in paths:
                    return True
    except (AttributeError, OSError):
        return False
    return False
