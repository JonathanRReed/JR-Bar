"""Which agent session is spending the battery.

Stats and iStat Menus show what the Mac draws; neither can say which agent
is drawing it, because neither knows which process is an agent. JR-Bar
does: the process registry maps every session to the pid its hook found
(``jrbar.process_registry``). This module samples the CPU time of that pid
and everything under it -- the agent, and the builds, test runs and
language servers its tools started -- and turns two samples into a share:
"claude:jr-bar is keeping 1.4 cores busy". CPU time is the load macOS
itself bills energy against, so the heaviest session by CPU is the one
draining the battery or warming the Mac.

One ``ps`` fork per sample and nothing in the background: the samples are
taken when someone asks (the ``session_energy`` command), and the rate is
measured over the time since the last ask, or over a short second sample
when there was none. Each process is billed to the NEAREST session above
it, so a session started from inside another's shell is never counted
twice. Shared-host providers (one long-lived host for every session) are
never billed: their pid says nothing about one session.

Nothing here reads a command line or an argument -- only pids, parents,
start times and CPU seconds.
"""

from __future__ import annotations

import subprocess
import threading
import time
from collections.abc import Callable, Iterable, Mapping
from dataclasses import dataclass, field
from typing import Final

from .process_registry import (
    SHARED_HOST_PROVIDERS,
    AgentProcessRecord,
    ProcessEntry,
    _parse_lstart,
    load_record,
    process_is_live,
)

PS_TIMEOUT_SECONDS: Final = 1.5
#: A rate needs two samples at least this far apart; a first ask waits
#: this long for its second.
MIN_WINDOW_SECONDS: Final = 1.5
#: An older previous sample is too stale to average over: the answer
#: would describe some other half hour.
MAX_WINDOW_SECONDS: Final = 15 * 60.0
#: Below this share a session is not "the heavy one", whatever the order.
HEAVY_PERCENT: Final = 5.0
MAX_SESSIONS: Final = 64


@dataclass(frozen=True, slots=True)
class CpuProcess:
    pid: int
    ppid: int
    started_at_epoch: float | None
    cpu_seconds: float


def parse_cpu_time(text: str) -> float | None:
    """ps' ``time`` column: ``MMM:SS.ss``, ``H:MM:SS.ss`` or ``D-HH:MM:SS``."""
    text = text.strip()
    if not text:
        return None
    days = 0
    if "-" in text:
        head, text = text.split("-", 1)
        if not head.isdigit():
            return None
        days = int(head)
    parts = text.split(":")
    if not 1 <= len(parts) <= 3:
        return None
    try:
        numbers = [float(part) for part in parts]
    except ValueError:
        return None
    if any(number < 0 or number != number for number in numbers):
        return None
    seconds = 0.0
    for number in numbers:
        seconds = seconds * 60.0 + number
    return days * 86_400.0 + seconds


def parse_cpu_table(stdout: str) -> dict[int, CpuProcess]:
    """``ps -axo pid=,ppid=,lstart=,time=`` as a table, skipping bad rows."""
    table: dict[int, CpuProcess] = {}
    for line in stdout.splitlines():
        tokens = line.split()
        # pid, ppid, five lstart tokens (Wed Sep  9 18:34:49 2026), time.
        if len(tokens) != 8:
            continue
        try:
            pid = int(tokens[0])
            ppid = int(tokens[1])
        except ValueError:
            continue
        cpu = parse_cpu_time(tokens[7])
        if cpu is None or pid <= 0:
            continue
        table[pid] = CpuProcess(pid, ppid, _parse_lstart(" ".join(tokens[2:7])), cpu)
    return table


def read_cpu_table(runner: Callable[..., object] = subprocess.run) -> dict[int, CpuProcess]:
    """One fork for the whole table; empty on any failure."""
    try:
        completed = runner(
            ["/bin/ps", "-axo", "pid=,ppid=,lstart=,time="],
            check=False,
            stdout=subprocess.PIPE,
            stderr=subprocess.DEVNULL,
            text=True,
            timeout=PS_TIMEOUT_SECONDS,
        )
    except Exception:
        return {}
    if getattr(completed, "returncode", 1) != 0:
        return {}
    return parse_cpu_table(str(getattr(completed, "stdout", "") or ""))


def bill_processes(roots: Mapping[str, int], table: Mapping[int, CpuProcess]) -> dict[str, tuple[float, int]]:
    """``{session: (cpu seconds, processes)}`` for each root pid's tree.

    Every process is billed to the nearest session root above it (itself
    included), so nested sessions are never counted twice. A root missing
    from the table bills nothing."""
    owner_of_root = {pid: session for session, pid in roots.items() if pid in table}
    billed: dict[str, list[float]] = {session: [0.0, 0] for session in owner_of_root.values()}
    for pid, process in table.items():
        seen: set[int] = set()
        current: int | None = pid
        while current is not None and current not in seen:
            seen.add(current)
            session = owner_of_root.get(current)
            if session is not None:
                billed[session][0] += process.cpu_seconds
                billed[session][1] += 1
                break
            parent = table.get(current)
            current = parent.ppid if parent is not None and parent.ppid != current else None
    return {session: (round(total, 2), int(count)) for session, (total, count) in billed.items()}


@dataclass(frozen=True, slots=True)
class EnergySample:
    at: float
    #: session -> (root pid, cpu seconds of its tree, processes in it)
    sessions: dict[str, tuple[int, float, int]] = field(default_factory=dict)


def sample_sessions(
    roots: Mapping[str, int],
    table: Mapping[int, CpuProcess],
    *,
    at: float,
) -> EnergySample:
    billed = bill_processes(roots, table)
    return EnergySample(
        at=at,
        sessions={
            session: (roots[session], seconds, count) for session, (seconds, count) in billed.items()
        },
    )


def energy_document(
    previous: EnergySample | None,
    current: EnergySample,
    *,
    providers: Mapping[str, str] | None = None,
) -> dict[str, object]:
    """The ``session_energy`` reply: each session's share, heaviest first.

    ``cpu_percent`` is Activity Monitor's convention (100 is one core fully
    busy), averaged over ``window_seconds``; null for a session the previous
    sample did not see under the same pid, or when there is no usable
    previous sample at all."""
    window = None
    if previous is not None:
        span = current.at - previous.at
        if MIN_WINDOW_SECONDS <= span <= MAX_WINDOW_SECONDS:
            window = span
    rows: list[dict[str, object]] = []
    for session, (pid, seconds, count) in current.sessions.items():
        percent = None
        before = previous.sessions.get(session) if window is not None and previous is not None else None
        if before is not None and before[0] == pid and seconds >= before[1]:
            percent = round((seconds - before[1]) / window * 100.0, 1)
        rows.append(
            {
                "session": session,
                "provider": (providers or {}).get(session),
                "cpu_percent": percent,
                "cpu_seconds": seconds,
                "processes": count,
            }
        )
    rows.sort(
        key=lambda row: (
            row["cpu_percent"] is None,
            -(row["cpu_percent"] or 0.0),
            -float(row["cpu_seconds"]),  # type: ignore[arg-type]
            str(row["session"]),
        )
    )
    rows = rows[:MAX_SESSIONS]
    measured = [float(row["cpu_percent"]) for row in rows if row["cpu_percent"] is not None]  # type: ignore[arg-type]
    heaviest = next(
        (
            row["session"]
            for row in rows
            if row["cpu_percent"] is not None and float(row["cpu_percent"]) >= HEAVY_PERCENT  # type: ignore[arg-type]
        ),
        None,
    )
    return {
        "sampled_at": round(current.at, 3),
        "window_seconds": None if window is None else round(window, 1),
        "sessions": rows,
        "total_percent": round(sum(measured), 1) if measured else None,
        "heaviest": heaviest,
    }


def live_roots(
    sessions: Iterable[tuple[str, str, str]],
    table: Mapping[int, CpuProcess],
    *,
    record_loader: Callable[[str, str], AgentProcessRecord | None] = load_record,
) -> tuple[dict[str, int], dict[str, str]]:
    """``(session -> root pid, session -> provider)`` for the sessions the
    registry can vouch for: a record, its pid in the table, and a start
    time that still matches (a reused pid bills nobody)."""
    entries = {pid: ProcessEntry(pid, p.ppid, p.started_at_epoch, "") for pid, p in table.items()}
    roots: dict[str, int] = {}
    providers: dict[str, str] = {}
    for key, provider, session_id in sessions:
        if provider in SHARED_HOST_PROVIDERS or key in roots:
            continue
        try:
            record = record_loader(provider, session_id)
        except Exception:
            record = None
        if record is None or record.ended_at_epoch is not None:
            continue
        alive, _reason = process_is_live(record, entries)
        if alive:
            roots[key] = record.pid
            providers[key] = provider
    return roots, providers


class SessionEnergySampler:
    """Holds the last sample between asks. Thread-safe: the command runs
    off the main thread, and two asks may overlap."""

    def __init__(
        self,
        *,
        table_reader: Callable[[], Mapping[int, CpuProcess]] = read_cpu_table,
        clock: Callable[[], float] = time.time,
        sleep: Callable[[float], None] = time.sleep,
        record_loader: Callable[[str, str], AgentProcessRecord | None] = load_record,
    ) -> None:
        self._table_reader = table_reader
        self._clock = clock
        self._sleep = sleep
        self._record_loader = record_loader
        self._lock = threading.Lock()
        self._last: EnergySample | None = None

    def _sample(self, sessions: list[tuple[str, str, str]]) -> tuple[EnergySample, dict[str, str]]:
        table = self._table_reader()
        roots, providers = live_roots(sessions, table, record_loader=self._record_loader)
        return sample_sessions(roots, table, at=self._clock()), providers

    def measure(self, sessions: Iterable[tuple[str, str, str]]) -> dict[str, object]:
        """``sessions`` is ``(state id, provider, provider session id)``."""
        wanted = list(dict.fromkeys(sessions))[:MAX_SESSIONS]
        with self._lock:
            previous = self._last
            if previous is None or not (
                MIN_WINDOW_SECONDS <= self._clock() - previous.at <= MAX_WINDOW_SECONDS
            ):
                # Nothing usable to average over: take a short window now.
                previous, _ = self._sample(wanted)
                self._sleep(MIN_WINDOW_SECONDS)
            current, providers = self._sample(wanted)
            self._last = current
        return energy_document(previous, current, providers=providers)


__all__ = [
    "HEAVY_PERCENT",
    "MAX_WINDOW_SECONDS",
    "MIN_WINDOW_SECONDS",
    "CpuProcess",
    "EnergySample",
    "SessionEnergySampler",
    "bill_processes",
    "energy_document",
    "live_roots",
    "parse_cpu_table",
    "parse_cpu_time",
    "read_cpu_table",
    "sample_sessions",
]
