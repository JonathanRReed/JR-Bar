#!/usr/bin/env python3
"""Measure how light the running JR-Bar app and core daemon are at idle.

Read-only: it asks the kernel for each process's resource usage twice, a
window apart (``proc_pid_rusage``, ``proc_pidinfo``), and with ``--spawns``
lists the programs the two processes start in that window. It never signals,
attaches to or writes to either process.

    python3 scripts/measure_idle.py                 # 60 s window
    python3 scripts/measure_idle.py --seconds 300 --spawns

Prints, per process: CPU percent of one core, interrupt wakeups per second,
resident memory, thread count, and each thread's share of the window's CPU.
Leave the Mac alone while it runs: a moving pointer is wakeups too.
"""

from __future__ import annotations

import argparse
import collections
import ctypes
import ctypes.util
import subprocess
import time

_RUSAGE_NAMES = (
    "ri_user_time ri_system_time ri_pkg_idle_wkups ri_interrupt_wkups ri_pageins ri_wired_size "
    "ri_resident_size ri_phys_footprint ri_proc_start_abstime ri_proc_exit_abstime ri_child_user_time "
    "ri_child_system_time ri_child_pkg_idle_wkups ri_child_interrupt_wkups ri_child_pageins "
    "ri_child_elapsed_abstime ri_diskio_bytesread ri_diskio_byteswritten ri_cpu_time_qos_default "
    "ri_cpu_time_qos_maintenance ri_cpu_time_qos_background ri_cpu_time_qos_utility ri_cpu_time_qos_legacy "
    "ri_cpu_time_qos_user_initiated ri_cpu_time_qos_user_interactive ri_billed_system_time "
    "ri_serviced_system_time"
).split()
_RUSAGE_V2 = 2
_PROC_PIDLISTTHREADIDS = 28
_PROC_PIDTHREADID64INFO = 15


class _Rusage(ctypes.Structure):
    _fields_ = [("ri_uuid", ctypes.c_uint8 * 16), *[(name, ctypes.c_uint64) for name in _RUSAGE_NAMES]]


class _ThreadInfo(ctypes.Structure):
    _fields_ = [
        ("pth_user_time", ctypes.c_uint64),
        ("pth_system_time", ctypes.c_uint64),
        ("pth_cpu_usage", ctypes.c_int32),
        ("pth_policy", ctypes.c_int32),
        ("pth_run_state", ctypes.c_int32),
        ("pth_flags", ctypes.c_int32),
        ("pth_sleep_time", ctypes.c_int32),
        ("pth_curpri", ctypes.c_int32),
        ("pth_priority", ctypes.c_int32),
        ("pth_maxpriority", ctypes.c_int32),
        ("pth_name", ctypes.c_char * 64),
    ]


class _Timebase(ctypes.Structure):
    _fields_ = [("numer", ctypes.c_uint32), ("denom", ctypes.c_uint32)]


_libproc = ctypes.CDLL(ctypes.util.find_library("proc"), use_errno=True)
_libproc.proc_pidinfo.argtypes = [ctypes.c_int, ctypes.c_int, ctypes.c_uint64, ctypes.c_void_p, ctypes.c_int]


def _abstime_seconds() -> float:
    base = _Timebase()
    ctypes.CDLL(None).mach_timebase_info(ctypes.byref(base))
    return base.numer / base.denom / 1e9


def _pids(pattern: str) -> list[int]:
    out = subprocess.run(["pgrep", "-f", pattern], capture_output=True, text=True, check=False).stdout
    return [int(token) for token in out.split()]


def _find_app() -> int | None:
    out = subprocess.run(["pgrep", "-x", "JR-Bar"], capture_output=True, text=True, check=False).stdout.split()
    return int(out[0]) if out else None


def _find_core() -> int | None:
    pids = _pids("jrbar-core.app/Contents/MacOS/jrbar-core core")
    return pids[0] if pids else None


def _rusage(pid: int) -> _Rusage:
    usage = _Rusage()
    if _libproc.proc_pid_rusage(pid, _RUSAGE_V2, ctypes.byref(usage)) != 0:
        raise SystemExit(f"cannot read process {pid}")
    return usage


def _thread_times(pid: int) -> dict[int, tuple[int, str]]:
    ids = (ctypes.c_uint64 * 1024)()
    count = _libproc.proc_pidinfo(pid, _PROC_PIDLISTTHREADIDS, 0, ids, ctypes.sizeof(ids))
    out: dict[int, tuple[int, str]] = {}
    for index in range(max(0, count) // 8):
        info = _ThreadInfo()
        if _libproc.proc_pidinfo(pid, _PROC_PIDTHREADID64INFO, ids[index], ctypes.byref(info), ctypes.sizeof(info)) > 0:
            out[ids[index]] = (info.pth_user_time + info.pth_system_time, info.pth_name.decode(errors="replace"))
    return out


def _spawns(seconds: float, pids: set[int]) -> collections.Counter:
    seen: dict[str, str] = {}
    end = time.time() + seconds
    while time.time() < end:
        out = subprocess.run(["ps", "-A", "-o", "pid=,ppid=,command="], capture_output=True, text=True, check=False).stdout
        for line in out.splitlines():
            parts = line.split(None, 2)
            if len(parts) == 3 and parts[1].isdigit() and int(parts[1]) in pids:
                seen.setdefault(parts[0], parts[2][:100])
    return collections.Counter(seen.values())


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--seconds", type=float, default=60.0, help="window length (default 60)")
    parser.add_argument("--spawns", action="store_true", help="also list the programs the two start in the window")
    args = parser.parse_args()
    targets = {"app": _find_app(), "core": _find_core()}
    targets = {name: pid for name, pid in targets.items() if pid}
    if not targets:
        raise SystemExit("neither the JR-Bar app nor its core daemon is running")
    scale = _abstime_seconds()
    before = {name: (_rusage(pid), _thread_times(pid)) for name, pid in targets.items()}
    started = time.time()
    spawned = _spawns(args.seconds, set(targets.values())) if args.spawns else None
    if spawned is None:
        time.sleep(args.seconds)
    window = time.time() - started
    for name, pid in targets.items():
        usage_before, threads_before = before[name]
        usage = _rusage(pid)
        threads = _thread_times(pid)
        cpu = ((usage.ri_user_time - usage_before.ri_user_time) + (usage.ri_system_time - usage_before.ri_system_time)) * scale
        wakeups = usage.ri_interrupt_wkups - usage_before.ri_interrupt_wkups
        print(
            f"{name} pid {pid}: cpu {cpu / window * 100:.2f}%  wakeups {wakeups / window:.1f}/s  "
            f"resident {usage.ri_resident_size / 1e6:.0f} MB  threads {len(threads)}"
        )
        deltas = [
            (threads[tid][0] - threads_before.get(tid, (0, ""))[0], tid, threads[tid][1]) for tid in threads
        ]
        total = sum(max(0, delta) for delta, _tid, _label in deltas) or 1
        for delta, tid, label in sorted(deltas, reverse=True)[:5]:
            if delta > 0:
                print(f"    thread {tid} {label or '-'}: {delta / total * 100:.0f}% of the window's CPU")
    if spawned is not None:
        print("started in the window:")
        for command, count in spawned.most_common(12):
            print(f"    {count} x {command}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
