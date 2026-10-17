#!/usr/bin/env python3
"""Track only the processes and socket created by run-dev.sh."""

from __future__ import annotations

import argparse
import ctypes
import json
import os
import signal
import stat
import subprocess
import sys
import tempfile
import time
from pathlib import Path


class BSDInfo(ctypes.Structure):
    _fields_ = [
        ("ids", ctypes.c_uint32 * 12),
        ("comm", ctypes.c_char * 16),
        ("name", ctypes.c_char * 32),
        ("details", ctypes.c_uint32 * 6),
        ("started_seconds", ctypes.c_uint64),
        ("started_microseconds", ctypes.c_uint64),
    ]


def process_identity(pid: int) -> str | None:
    if pid <= 1:
        return None
    if sys.platform == "darwin":
        info = BSDInfo()
        libproc = ctypes.CDLL("/usr/lib/libproc.dylib", use_errno=True)
        libproc.proc_pidinfo.argtypes = [ctypes.c_int, ctypes.c_int, ctypes.c_uint64,
                                        ctypes.c_void_p, ctypes.c_int]
        libproc.proc_pidinfo.restype = ctypes.c_int
        size = ctypes.sizeof(info)
        if libproc.proc_pidinfo(pid, 3, 0, ctypes.byref(info), size) != size:
            return None
        if info.ids[1] == 5:  # SZOMB
            return None
        return f"darwin:{info.started_seconds}:{info.started_microseconds}"
    try:
        fields = Path(f"/proc/{pid}/stat").read_text().rsplit(")", 1)[1].split()
        if fields[0] == "Z":
            return None
        return f"linux:{fields[19]}"
    except (OSError, IndexError):
        return None


def read_records(path: Path) -> list[dict]:
    try:
        data = json.loads(path.read_text())
    except (OSError, ValueError):
        return []  # Legacy bare PIDs cannot establish ownership.
    if not isinstance(data, dict) or data.get("version") != 1:
        return []
    records = data.get("processes")
    if not isinstance(records, list):
        return []
    return [record for record in records if isinstance(record, dict)
            and type(record.get("pid")) is int and record["pid"] > 1
            and isinstance(record.get("identity"), str) and record["identity"]]


def write_records(path: Path, records: list[dict]) -> None:
    with tempfile.NamedTemporaryFile(mode="w", dir=path.parent, delete=False) as output:
        temporary = Path(output.name)
        json.dump({"version": 1, "processes": records}, output)
    try:
        temporary.replace(path)
    finally:
        temporary.unlink(missing_ok=True)


def matches(record: dict, identity=process_identity) -> bool:
    return identity(record["pid"]) == record["identity"]


def socket_identity(path: Path) -> list[int] | None:
    try:
        entry = path.lstat()
    except OSError:
        return None
    if not stat.S_ISSOCK(entry.st_mode) or entry.st_uid != os.getuid():
        return None
    return [entry.st_dev, entry.st_ino, entry.st_uid]


def owns_socket(pid: int, path: Path) -> bool:
    try:
        result = subprocess.run(
            ["/usr/sbin/lsof", "-a", "-p", str(pid), "-U", "-Fn"],
            capture_output=True, text=True, timeout=0.5, check=False,
        )
    except (OSError, subprocess.TimeoutExpired):
        return False
    return result.returncode == 0 and any(
        line.startswith("n/") and Path(line[1:]).resolve() == path.resolve()
        for line in result.stdout.splitlines()
    )


def await_socket(record: dict, path: Path, *, identity=process_identity,
                 owner=owns_socket, socket_state=socket_identity,
                 clock=time.monotonic, pause=time.sleep, timeout=4.0) -> bool:
    deadline = clock() + timeout
    while clock() < deadline:
        if not matches(record, identity):
            return False
        before = socket_state(path)
        if before and owner(record["pid"], path):
            if matches(record, identity) and socket_state(path) == before:
                record["socket"] = {"path": str(path), "identity": before}
                return True
        pause(min(0.1, max(0, deadline - clock())))
    return False


def stop_records(records: list[dict], *, identity=process_identity,
                 send_signal=os.kill, clock=time.monotonic, pause=time.sleep,
                 socket_state=socket_identity, timeout=3.0) -> list[dict]:
    def send(record: dict, sig: int) -> None:
        if matches(record, identity):
            try:
                send_signal(record["pid"], sig)
            except ProcessLookupError:
                pass

    for record in records:
        send(record, signal.SIGTERM)
    deadline = clock() + timeout
    while any(matches(record, identity) for record in records) and clock() < deadline:
        pause(min(0.1, max(0, deadline - clock())))
    for record in records:
        send(record, signal.SIGKILL)
    deadline = clock() + 0.5
    while any(matches(record, identity) for record in records) and clock() < deadline:
        pause(min(0.1, max(0, deadline - clock())))
    # Preserve the path and record while its owner is still alive.
    for record in records:
        owned = record.get("socket")
        if not isinstance(owned, dict) or matches(record, identity):
            continue
        expected = owned.get("identity")
        if not isinstance(expected, list) or len(expected) != 3 or any(
            type(value) is not int for value in expected
        ):
            continue
        path = owned.get("path")
        if isinstance(path, str) and socket_state(Path(path)) == expected:
            Path(path).unlink(missing_ok=True)
    return [record for record in records if matches(record, identity)]


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("action", choices=("add", "stop", "wait"))
    parser.add_argument("records", type=Path)
    parser.add_argument("--pid", type=int)
    parser.add_argument("--socket", type=Path)
    args = parser.parse_args()
    records = read_records(args.records)
    if args.action == "stop":
        if args.records.exists() and not records:
            print("skipping dev PID records without process identities", file=sys.stderr)
        remaining = stop_records(records)
        if remaining:
            write_records(args.records, remaining)
            print("dev processes did not stop; keeping their identities", file=sys.stderr)
            return 1
        args.records.unlink(missing_ok=True)
        return 0
    if args.pid is None:
        parser.error("--pid is required")
    if args.action == "add":
        identity = process_identity(args.pid)
        if identity is None:
            print(f"cannot record dev process {args.pid}", file=sys.stderr)
            return 1
        records.append({"pid": args.pid, "identity": identity})
    else:
        if args.socket is None:
            parser.error("--socket is required")
        record = next((record for record in records if record["pid"] == args.pid), None)
        if record is None or not await_socket(record, args.socket.resolve()):
            print(f"mock process {args.pid} did not own {args.socket}", file=sys.stderr)
            return 1
    write_records(args.records, records)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
