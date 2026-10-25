"""Disposable Utility process for cold and full token-history rebuilds."""
from __future__ import annotations

import json
import os
import resource
import sys
import time
from pathlib import Path


def main():
    from .token_history_index import _acquire_build_lock

    # Windowed frozen helpers can expose None for the Python stream objects
    # even though Popen supplied pipes on descriptors 0 and 1.
    incoming = sys.stdin if sys.stdin is not None else os.fdopen(0, "r", encoding="utf-8", closefd=False)
    outgoing = sys.stdout if sys.stdout is not None else os.fdopen(1, "w", encoding="utf-8", closefd=False)
    request = json.load(incoming)
    lock_fd = request.get("lock_fd")
    if lock_fd is None:
        lock_fd = _acquire_build_lock(Path(request["path"]))
        if lock_fd is None:
            return 0
    try:
        return _build(request, outgoing)
    finally:
        os.close(lock_fd)


def _build(request, outgoing):
    from .token_history_index import TokenHistoryIndex

    qos = None
    if sys.platform == "darwin":
        import ctypes
        library = ctypes.CDLL(None)
        if library.pthread_set_qos_class_self_np(0x11, 0) != 0:
            raise RuntimeError("cannot set history builder Utility QoS")
        qos = library.qos_class_self()
    committed = 0
    def report(row):
        nonlocal committed
        if row.get("phase") == "reading":
            committed += row["records"]
            row["records_committed"] = committed
        print(json.dumps(row), file=outgoing, flush=True)
    index = TokenHistoryIndex(Path(request["path"]), background_build=False, progress=report, builder=True,
                              parent_pid=request.get("parent_pid", os.getppid()))
    roots = {p: tuple(Path(r) for r in paths) for p, paths in request["roots"].items()}
    cpu, wall = time.process_time(), time.monotonic()
    try:
        while not index._stopped():
            totals = index.scan(roots, source_bindings=request.get("source_bindings"))
            if index.error or not any(c.pending_files for c in totals.source_coverage.values()):
                break
        if index._stopped():
            return 0
        index.close()
        report({"phase": "done", "error": index.error, "cpu_seconds": time.process_time() - cpu,
                "wall_seconds": time.monotonic() - wall, "peak_rss_bytes": resource.getrusage(resource.RUSAGE_SELF).ru_maxrss,
                "qos": qos, "pending": sum(c.pending_files for c in totals.source_coverage.values())})
        return 1 if index.error else 0
    finally:
        index.close()


if __name__ == "__main__":
    raise SystemExit(main())
