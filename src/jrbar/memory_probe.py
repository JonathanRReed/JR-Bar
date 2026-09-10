"""Where the daemon's memory goes.

``JRBAR_TRACEMALLOC=1`` (or a number of seconds, default 60) makes the core
start ``tracemalloc`` at launch and log the largest retained allocations,
grouped by source file, that many seconds later and on every following
interval. ``doctor`` always carries a ``memory`` field: the process RSS
and, when tracing is on, the current traced size and the top files.

Content-free: file names, line numbers and byte counts only.
"""

from __future__ import annotations

import os
import resource
import sys
import threading
import time
import tracemalloc
from collections.abc import Callable
from typing import Any

ENV_VAR = "JRBAR_TRACEMALLOC"
DEFAULT_INTERVAL_SECONDS = 60.0
TOP_FILES = 25
FRAMES = 12

_rss_probe: Callable[[], int | None] | None = None


def requested_interval(environ: dict[str, str] | None = None) -> float | None:
    """Seconds between reports when tracing was requested, else ``None``."""
    raw = (environ if environ is not None else os.environ).get(ENV_VAR, "").strip()
    if not raw or raw in ("0", "false", "no", "off"):
        return None
    try:
        seconds = float(raw)
    except ValueError:
        return DEFAULT_INTERVAL_SECONDS
    return seconds if seconds > 0 else DEFAULT_INTERVAL_SECONDS


def resident_bytes() -> int | None:
    """Current resident set size, from libproc on macOS; ``None`` elsewhere."""
    global _rss_probe
    if _rss_probe is None:
        _rss_probe = _build_rss_probe()
    try:
        return _rss_probe()
    except Exception:
        return None


def _build_rss_probe() -> Callable[[], int | None]:
    if sys.platform != "darwin":
        return lambda: None
    try:
        import ctypes
        import ctypes.util

        libproc = ctypes.CDLL(ctypes.util.find_library("proc") or "/usr/lib/libproc.dylib")

        class ProcTaskInfo(ctypes.Structure):
            _fields_ = [
                ("pti_virtual_size", ctypes.c_uint64),
                ("pti_resident_size", ctypes.c_uint64),
                ("pti_total_user", ctypes.c_uint64),
                ("pti_total_system", ctypes.c_uint64),
                ("pti_threads_user", ctypes.c_uint64),
                ("pti_threads_system", ctypes.c_uint64),
                ("pti_policy", ctypes.c_int32),
                ("pti_faults", ctypes.c_int32),
                ("pti_pageins", ctypes.c_int32),
                ("pti_cow_faults", ctypes.c_int32),
                ("pti_messages_sent", ctypes.c_int32),
                ("pti_messages_received", ctypes.c_int32),
                ("pti_syscalls_mach", ctypes.c_int32),
                ("pti_syscalls_unix", ctypes.c_int32),
                ("pti_csw", ctypes.c_int32),
                ("pti_threadnum", ctypes.c_int32),
                ("pti_numrunning", ctypes.c_int32),
                ("pti_priority", ctypes.c_int32),
            ]

        proc_pidinfo = libproc.proc_pidinfo
        proc_pidinfo.restype = ctypes.c_int
        proc_pidinfo.argtypes = [ctypes.c_int, ctypes.c_int, ctypes.c_uint64, ctypes.c_void_p, ctypes.c_int]
        proc_pidtaskinfo = 4

        def probe() -> int | None:
            info = ProcTaskInfo()
            size = proc_pidinfo(os.getpid(), proc_pidtaskinfo, 0, ctypes.byref(info), ctypes.sizeof(info))
            if size != ctypes.sizeof(info):
                return None
            return int(info.pti_resident_size)

        return probe
    except Exception:
        return lambda: None


def peak_resident_bytes() -> int:
    return int(resource.getrusage(resource.RUSAGE_SELF).ru_maxrss)


def _mb(value: int | float) -> float:
    return round(value / (1024 * 1024), 1)


def top_files(limit: int = TOP_FILES) -> list[dict[str, Any]]:
    """The largest retained allocations grouped by file (tracing must be on)."""
    if not tracemalloc.is_tracing():
        return []
    snapshot = tracemalloc.take_snapshot().filter_traces(
        (
            tracemalloc.Filter(False, tracemalloc.__file__),
            tracemalloc.Filter(False, "<frozen importlib._bootstrap>"),
            tracemalloc.Filter(False, "<frozen importlib._bootstrap_external>"),
        )
    )
    rows: list[dict[str, Any]] = []
    for stat in snapshot.statistics("filename")[:limit]:
        frame = stat.traceback[0]
        rows.append({"file": _short(frame.filename), "bytes": stat.size, "mb": _mb(stat.size), "count": stat.count})
    return rows


def top_lines(limit: int = TOP_FILES) -> list[dict[str, Any]]:
    if not tracemalloc.is_tracing():
        return []
    snapshot = tracemalloc.take_snapshot()
    rows: list[dict[str, Any]] = []
    for stat in snapshot.statistics("lineno")[:limit]:
        frame = stat.traceback[0]
        rows.append({"where": f"{_short(frame.filename)}:{frame.lineno}", "mb": _mb(stat.size), "count": stat.count})
    return rows


def _short(filename: str) -> str:
    for marker in ("/site-packages/", "/lib/python3.12/", "/lib/python3.13/"):
        index = filename.rfind(marker)
        if index >= 0:
            return filename[index + len(marker) :]
    index = filename.rfind("/jrbar/")
    if index >= 0:
        return "jrbar/" + filename[index + len("/jrbar/") :]
    return filename


def memory_report(include_top: bool = True) -> dict[str, Any]:
    """The ``doctor`` reply's ``memory`` field."""
    rss = resident_bytes()
    report: dict[str, Any] = {
        "rss_mb": _mb(rss) if rss is not None else None,
        "peak_rss_mb": _mb(peak_resident_bytes()),
        "tracing": tracemalloc.is_tracing(),
    }
    if tracemalloc.is_tracing():
        current, peak = tracemalloc.get_traced_memory()
        report["traced_mb"] = _mb(current)
        report["traced_peak_mb"] = _mb(peak)
        if include_top:
            report["top_files"] = top_files()
    return report


def render_report(report: dict[str, Any], lines: list[dict[str, Any]] | None = None) -> str:
    parts = [
        f"memory: rss={report.get('rss_mb')} MB peak={report.get('peak_rss_mb')} MB"
        + (f" traced={report.get('traced_mb')} MB (peak {report.get('traced_peak_mb')} MB)" if report.get("tracing") else "")
    ]
    for row in report.get("top_files") or []:
        parts.append(f"  {row['mb']:>8.1f} MB  {row['count']:>7} blocks  {row['file']}")
    for row in lines or []:
        parts.append(f"  {row['mb']:>8.1f} MB  {row['count']:>7} blocks  {row['where']}")
    return "\n".join(parts)


def start_if_requested(log: Callable[[str], None], environ: dict[str, str] | None = None) -> threading.Thread | None:
    """Start tracing and a daemon thread that logs the report every interval."""
    interval = requested_interval(environ)
    if interval is None:
        return None
    if not tracemalloc.is_tracing():
        tracemalloc.start(FRAMES)
    log(f"memory: tracemalloc on, first report in {interval:g} s")

    def worker() -> None:
        while True:
            time.sleep(interval)
            try:
                log(render_report(memory_report(), top_lines(15)))
            except Exception as exc:  # the probe must never take the daemon down
                log(f"memory: report failed: {exc.__class__.__name__}: {exc}")

    thread = threading.Thread(target=worker, name="jrbar-memory-probe", daemon=True)
    thread.start()
    return thread


__all__ = [
    "ENV_VAR",
    "memory_report",
    "peak_resident_bytes",
    "render_report",
    "requested_interval",
    "resident_bytes",
    "start_if_requested",
    "top_files",
    "top_lines",
]
