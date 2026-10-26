"""Read macOS process identities through libproc without starting a child."""
from __future__ import annotations

import ctypes
import errno
import os
import stat
from functools import lru_cache


class BsdInfo(ctypes.Structure):
    # sys/proc_info.h, PROC_PIDTBSDINFO. dev_t and uid_t are uint32 on Darwin.
    _fields_ = [(name, ctypes.c_uint32) for name in (
        "flags", "status", "xstatus", "pid", "ppid", "uid", "gid", "ruid",
        "rgid", "svuid", "svgid", "reserved",
    )] + [
        ("comm", ctypes.c_char * 16), ("name", ctypes.c_char * 32),
        ("nfiles", ctypes.c_uint32), ("pgid", ctypes.c_uint32),
        ("jobc", ctypes.c_uint32), ("ttydev", ctypes.c_uint32),
        ("tpgid", ctypes.c_uint32), ("nice", ctypes.c_int32),
        ("start_sec", ctypes.c_uint64), ("start_usec", ctypes.c_uint64),
    ]


@lru_cache(maxsize=1)
def _library():
    library = ctypes.CDLL("/usr/lib/libproc.dylib", use_errno=True)
    library.proc_listallpids.argtypes = [ctypes.c_void_p, ctypes.c_int]
    library.proc_listallpids.restype = ctypes.c_int
    library.proc_pidinfo.argtypes = [ctypes.c_int, ctypes.c_int, ctypes.c_uint64, ctypes.c_void_p, ctypes.c_int]
    library.proc_pidinfo.restype = ctypes.c_int
    library.proc_pidpath.argtypes = [ctypes.c_int, ctypes.c_void_p, ctypes.c_uint32]
    library.proc_pidpath.restype = ctypes.c_int
    return library


def identity(pid: int, *, library=None) -> BsdInfo | None:
    lib = _library() if library is None else library
    info = BsdInfo()
    size = ctypes.sizeof(info)
    if lib.proc_pidinfo(pid, 3, 0, ctypes.byref(info), size) != size:
        return None
    return info


@lru_cache(maxsize=1)
def _sysctl():
    call = ctypes.CDLL(None, use_errno=True).sysctl
    call.argtypes = [ctypes.POINTER(ctypes.c_int), ctypes.c_uint, ctypes.c_void_p,
                     ctypes.POINTER(ctypes.c_size_t), ctypes.c_void_p, ctypes.c_size_t]
    call.restype = ctypes.c_int
    return call


def launch_path(pid: int, *, sysctl=None) -> str | None:
    # Darwin returns the TOP of the argument area for a short buffer, which
    # can omit the launch path. Query its size before reading, then decode
    # only the saved path and erase the transient argument/environment area.
    call = _sysctl() if sysctl is None else sysctl
    mib = (ctypes.c_int * 3)(1, 49, pid)  # CTL_KERN, KERN_PROCARGS2
    size = ctypes.c_size_t()
    if call(mib, 3, None, ctypes.byref(size), None, 0) != 0 or not 4 < size.value <= 1024 * 1024:
        return None
    buffer = ctypes.create_string_buffer(size.value)
    try:
        if call(mib, 3, buffer, ctypes.byref(size), None, 0) != 0:
            return None
        if not 4 < size.value <= len(buffer):
            return None
        raw = ctypes.string_at(ctypes.addressof(buffer) + 4, min(4096, size.value - 4))
        end = raw.find(b"\0")
        return os.fsdecode(raw[:end]) if end > 0 else None
    finally:
        ctypes.memset(buffer, 0, len(buffer))



def _terminals() -> dict[int, str]:
    result = {}
    with os.scandir("/dev") as entries:
        for entry in entries:
            if entry.name == "console" or entry.name.startswith("tty"):
                try:
                    info = entry.stat(follow_symlinks=False)
                    if stat.S_ISCHR(info.st_mode):
                        result[info.st_rdev] = entry.path
                except OSError:
                    continue
    return result


def read_process_table(*, library=None, terminals=None, launch_reader=launch_path) -> dict:
    from .process_registry import ProcessEntry

    lib = _library() if library is None else library
    # The process count may grow between calls. Retry a full buffer rather
    # than silently publishing a truncated table as proof of process death.
    count = lib.proc_listallpids(None, 0)
    if count <= 0:
        return {}
    for _ in range(3):
        capacity = count + max(64, count // 4)
        pids = (ctypes.c_int * capacity)()
        count = lib.proc_listallpids(pids, ctypes.sizeof(pids))
        if count <= 0:
            return {}
        if count < capacity:
            break
    else:
        return {}
    ttys = _terminals() if terminals is None else terminals
    table = {}
    for pid in pids[:count]:
        if pid <= 0:
            continue
        ctypes.set_errno(0)
        info = identity(pid, library=lib)
        if info is None and ctypes.get_errno() in (errno.EPERM, errno.EACCES):
            table[pid] = ProcessEntry(pid, 0, None, "")
            continue  # permission denied is not evidence of process death
        if info is None or info.pid != pid or info.status == 5:
            continue  # exited or inaccessible during this read
        path = ctypes.create_string_buffer(4096)
        path_size = lib.proc_pidpath(pid, path, len(path))
        executable = os.fsdecode(path.value) if path_size > 0 else None
        command = launch_reader(pid) or executable or os.fsdecode(info.comm)
        # A pid can be recycled while proc_pidpath runs. Do not join the
        # first owner's parent/start time to the new owner's executable.
        ctypes.set_errno(0)
        after = identity(pid, library=lib)
        if after is None and ctypes.get_errno() in (errno.EPERM, errno.EACCES):
            table[pid] = ProcessEntry(pid, 0, None, "")
            continue
        if after is None or (after.start_sec, after.start_usec) != (info.start_sec, info.start_usec):
            continue
        started = info.start_sec + info.start_usec / 1_000_000
        table[pid] = ProcessEntry(pid, info.ppid, started, command, ttys.get(info.ttydev), executable)
    return table
