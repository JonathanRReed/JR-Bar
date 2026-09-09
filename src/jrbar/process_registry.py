"""Which OS process backs which agent session, and whether it is still alive.

Hooks tell us when an agent starts, works, asks, and stops. They cannot
tell us when the agent is killed: a Ctrl-C, a closed terminal tab, or a
crash fires no hook at all, and the session sat "Working" until a silence
window expired. This module closes that gap.

The hook process records its agent ancestor once per session under the
state dir (``processes/<provider>/<session>.json``). The app sweeps those
records against the live process table and ends any session whose process
is gone. Pid reuse is defeated by remembering the process start time.

Claude Code also publishes ``~/.claude/sessions/<pid>.json``; that index is
read as a second source so sessions started before the hooks were
installed still get a pid.
"""

from __future__ import annotations

import errno
import json
import os
import re
import subprocess
import time
from collections.abc import Iterable, Mapping
from dataclasses import dataclass, replace
from pathlib import Path
from typing import Any

from .private_io import atomic_private_write, ensure_private_directory, read_private_text
from .state_paths import default_state_dir

REGISTRY_DIR_NAME = "processes"
MAX_RECORD_BYTES = 8 * 1024
MAX_SESSION_ID_LENGTH = 200
PS_TIMEOUT_SECONDS = 1.5
# The process table is cheap to list but not free; the sweep reads it at
# most this often even when the app refreshes faster.
SWEEP_MIN_INTERVAL_SECONDS = 2.0
# lstart has one-second resolution; allow drift between sources that
# report milliseconds (Claude's session index) and ps.
START_TOLERANCE_SECONDS = 5.0

_SHELL_NAMES = frozenset(
    {"sh", "bash", "zsh", "fish", "env", "python", "python3", "node", "caffeinate"}
)
# Executable basenames that identify a provider's agent process. The first
# ancestor with one of these names is the session's process; anything else
# (shells, node wrappers) is skipped.
PROVIDER_PROCESS_NAMES: Mapping[str, frozenset[str]] = {
    "claude": frozenset({"claude"}),
    "codex": frozenset({"codex"}),
    "pi": frozenset({"pi"}),
    "gemini": frozenset({"gemini"}),
    "grok": frozenset({"grok"}),
    "opencode": frozenset({"opencode"}),
    "openclaw": frozenset({"openclaw"}),
    "cursor": frozenset({"cursor-agent", "cursor"}),
    "hermes": frozenset({"hermes"}),
    "kiro": frozenset({"kiro", "kiro-cli"}),
    "devin": frozenset({"devin"}),
    "antigravity": frozenset({"agy", "antigravity"}),
}

_SESSION_ID_SAFE = re.compile(r"[^A-Za-z0-9._-]+")


@dataclass(frozen=True, slots=True)
class AgentProcessRecord:
    provider: str
    session_id: str
    pid: int
    started_at_epoch: float | None
    command: str
    cwd: str | None
    recorded_at_epoch: float
    ended_at_epoch: float | None = None
    end_reason: str | None = None

    def to_payload(self) -> dict[str, Any]:
        return {
            "version": 1,
            "provider": self.provider,
            "session_id": self.session_id,
            "pid": self.pid,
            "started_at_epoch": self.started_at_epoch,
            "command": self.command,
            "cwd": self.cwd,
            "recorded_at_epoch": self.recorded_at_epoch,
            "ended_at_epoch": self.ended_at_epoch,
            "end_reason": self.end_reason,
        }

    @classmethod
    def from_payload(cls, payload: Mapping[str, Any]) -> AgentProcessRecord | None:
        try:
            pid = int(payload["pid"])
            provider = str(payload["provider"])
            session_id = str(payload["session_id"])
        except (KeyError, TypeError, ValueError):
            return None
        if pid <= 1 or not provider or not session_id:
            return None
        started = payload.get("started_at_epoch")
        ended = payload.get("ended_at_epoch")
        return cls(
            provider=provider,
            session_id=session_id,
            pid=pid,
            started_at_epoch=float(started) if isinstance(started, (int, float)) else None,
            command=str(payload.get("command") or ""),
            cwd=str(payload["cwd"]) if payload.get("cwd") else None,
            recorded_at_epoch=float(payload.get("recorded_at_epoch") or 0.0),
            ended_at_epoch=float(ended) if isinstance(ended, (int, float)) else None,
            end_reason=str(payload["end_reason"]) if payload.get("end_reason") else None,
        )


@dataclass(frozen=True, slots=True)
class ProcessEntry:
    pid: int
    ppid: int
    started_at_epoch: float | None
    command: str

    @property
    def basename(self) -> str:
        # ``command`` holds the executable path from ps' comm column, so a
        # path containing spaces is still one token.
        return Path(self.command.strip()).name.lower() if self.command else ""


@dataclass(frozen=True, slots=True)
class DeadAgentProcess:
    record: AgentProcessRecord
    reason: str


# --------------------------------------------------------------------------
# Paths


def registry_dir(state_dir: Path | None = None) -> Path:
    base = state_dir if state_dir is not None else default_state_dir()
    return Path(base) / REGISTRY_DIR_NAME


def _safe_session_name(session_id: str) -> str:
    trimmed = session_id[:MAX_SESSION_ID_LENGTH]
    return _SESSION_ID_SAFE.sub("_", trimmed) or "_"


def record_path(provider: str, session_id: str, state_dir: Path | None = None) -> Path:
    return registry_dir(state_dir) / _safe_session_name(provider) / (
        _safe_session_name(session_id) + ".json"
    )


# --------------------------------------------------------------------------
# Process table


def _parse_lstart(text: str) -> float | None:
    """Parse ps' lstart column (``Wed Sep  9 18:34:49 2026``) to epoch."""
    text = text.strip()
    if not text:
        return None
    for pattern in ("%a %b %d %H:%M:%S %Y", "%c"):
        try:
            return time.mktime(time.strptime(text, pattern))
        except ValueError:
            continue
    return None


def list_processes(runner=subprocess.run) -> dict[int, ProcessEntry]:
    """One ``ps`` fork for the whole table; empty on any failure."""
    # comm= is the executable path (no arguments), placed last so that a
    # path with spaces ("Application Support") stays intact.
    try:
        completed = runner(
            ["/bin/ps", "-axo", "pid=,ppid=,lstart=,comm="],
            check=False,
            stdout=subprocess.PIPE,
            stderr=subprocess.DEVNULL,
            text=True,
            timeout=PS_TIMEOUT_SECONDS,
        )
    except Exception:
        return {}
    if completed.returncode != 0:
        return {}
    table: dict[int, ProcessEntry] = {}
    for line in completed.stdout.splitlines():
        parts = line.split(None, 2)
        if len(parts) < 3:
            continue
        try:
            pid = int(parts[0])
            ppid = int(parts[1])
        except ValueError:
            continue
        rest = parts[2]
        # lstart is five whitespace-separated tokens: Wed Sep  9 18:34:49 2026
        tokens = rest.split(None, 5)
        if len(tokens) < 6:
            started, command = None, rest
        else:
            started = _parse_lstart(" ".join(tokens[:5]))
            command = tokens[5]
        table[pid] = ProcessEntry(pid, ppid, started, command)
    return table


def process_start_epoch(pid: int, runner=subprocess.run) -> float | None:
    try:
        completed = runner(
            ["/bin/ps", "-p", str(pid), "-o", "lstart="],
            check=False,
            stdout=subprocess.PIPE,
            stderr=subprocess.DEVNULL,
            text=True,
            timeout=PS_TIMEOUT_SECONDS,
        )
    except Exception:
        return None
    if completed.returncode != 0:
        return None
    return _parse_lstart(completed.stdout)


def pid_exists(pid: int) -> bool:
    if pid <= 1:
        return False
    try:
        os.kill(pid, 0)
    except OSError as exc:
        if exc.errno == errno.ESRCH:
            return False
        # EPERM: exists but not ours.
        return exc.errno == errno.EPERM
    return True


def process_is_live(
    record: AgentProcessRecord,
    table: Mapping[int, ProcessEntry] | None = None,
) -> tuple[bool, str]:
    """Return (alive, reason). A reused pid counts as dead."""
    if table is not None:
        entry = table.get(record.pid)
        if entry is None:
            return False, "process_exited"
        if (
            record.started_at_epoch is not None
            and entry.started_at_epoch is not None
            and abs(entry.started_at_epoch - record.started_at_epoch) > START_TOLERANCE_SECONDS
        ):
            return False, "pid_reused"
        return True, "alive"
    if not pid_exists(record.pid):
        return False, "process_exited"
    if record.started_at_epoch is not None:
        started = process_start_epoch(record.pid)
        if started is not None and abs(started - record.started_at_epoch) > START_TOLERANCE_SECONDS:
            return False, "pid_reused"
    return True, "alive"


# --------------------------------------------------------------------------
# Discovery (runs in the hook process)


def discover_agent_process(
    provider: str,
    *,
    start_pid: int | None = None,
    table: Mapping[int, ProcessEntry] | None = None,
    limit: int = 12,
) -> ProcessEntry | None:
    """Walk up from the hook process to the agent that spawned it."""
    if table is None:
        table = list_processes()
    if not table:
        return None
    wanted = PROVIDER_PROCESS_NAMES.get(provider, frozenset())
    current = os.getppid() if start_pid is None else start_pid
    seen: set[int] = set()
    fallback: ProcessEntry | None = None
    while current > 1 and current not in seen and len(seen) < limit:
        seen.add(current)
        entry = table.get(current)
        if entry is None:
            break
        name = entry.basename
        if name in wanted:
            return entry
        if fallback is None and name and name not in _SHELL_NAMES:
            fallback = entry
        current = entry.ppid
    return fallback


def record_agent_process(
    provider: str,
    session_id: str,
    entry: ProcessEntry,
    *,
    cwd: str | None = None,
    state_dir: Path | None = None,
    now: float | None = None,
) -> AgentProcessRecord:
    record = AgentProcessRecord(
        provider=provider,
        session_id=session_id,
        pid=entry.pid,
        started_at_epoch=entry.started_at_epoch,
        command=entry.command[:512],
        cwd=cwd,
        recorded_at_epoch=time.time() if now is None else now,
    )
    write_record(record, state_dir=state_dir)
    return record


def write_record(record: AgentProcessRecord, *, state_dir: Path | None = None) -> None:
    path = record_path(record.provider, record.session_id, state_dir)
    ensure_private_directory(path.parent)
    atomic_private_write(path, json.dumps(record.to_payload(), separators=(",", ":")))


def load_record(
    provider: str, session_id: str, *, state_dir: Path | None = None
) -> AgentProcessRecord | None:
    path = record_path(provider, session_id, state_dir)
    try:
        if path.stat().st_size > MAX_RECORD_BYTES:
            return None
        payload = json.loads(read_private_text(path))
    except (OSError, ValueError):
        return None
    if not isinstance(payload, dict):
        return None
    return AgentProcessRecord.from_payload(payload)


def note_hook_payload(
    provider: str,
    payload_text: str,
    *,
    state_dir: Path | None = None,
    table_loader=list_processes,
) -> None:
    """Called once per hook invocation in the hook process. Cheap when the
    session is already registered: one stat, no forks."""
    try:
        payload = json.loads(payload_text or "{}")
    except ValueError:
        return
    if not isinstance(payload, dict):
        return
    session_id = payload.get("session_id") or payload.get("sessionId")
    if not isinstance(session_id, str) or not session_id:
        return
    if session_id.endswith("-install-probe"):
        # The installer's self-test is not a session.
        return
    event = str(payload.get("hook_event_name") or "")
    existing = load_record(provider, session_id, state_dir=state_dir)
    if event == "SessionEnd":
        if existing is not None and existing.ended_at_epoch is None:
            write_record(
                replace(existing, ended_at_epoch=time.time(), end_reason="hook"),
                state_dir=state_dir,
            )
        return
    if existing is not None and existing.ended_at_epoch is None and event != "SessionStart":
        return
    entry = discover_agent_process(provider, table=table_loader())
    if entry is None:
        return
    cwd = payload.get("cwd")
    record_agent_process(
        provider,
        session_id,
        entry,
        cwd=str(cwd) if isinstance(cwd, str) else None,
        state_dir=state_dir,
    )


# --------------------------------------------------------------------------
# Claude's own session index


def claude_session_index(sessions_dir: Path | None = None) -> dict[str, ProcessEntry]:
    """sessionId -> process from ``~/.claude/sessions/<pid>.json``."""
    base = sessions_dir if sessions_dir is not None else Path.home() / ".claude" / "sessions"
    result: dict[str, ProcessEntry] = {}
    try:
        candidates = sorted(base.glob("*.json"))
    except OSError:
        return result
    for path in candidates[:512]:
        try:
            if path.stat().st_size > MAX_RECORD_BYTES:
                continue
            payload = json.loads(path.read_text(encoding="utf-8"))
        except (OSError, ValueError):
            continue
        if not isinstance(payload, dict):
            continue
        session_id = payload.get("sessionId")
        pid = payload.get("pid")
        if not isinstance(session_id, str) or not isinstance(pid, int) or pid <= 1:
            continue
        started_ms = payload.get("startedAt")
        started = (
            float(started_ms) / 1000.0 if isinstance(started_ms, (int, float)) else None
        )
        result[session_id] = ProcessEntry(pid, 0, started, str(payload.get("entrypoint") or "claude"))
    return result


# --------------------------------------------------------------------------
# Sweep (runs in the app)


class ProcessSweeper:
    """Find registered sessions whose process is gone."""

    def __init__(
        self,
        *,
        state_dir: Path | None = None,
        table_loader=list_processes,
        claude_index_loader=claude_session_index,
        clock=time.time,
    ) -> None:
        self.state_dir = state_dir
        self._table_loader = table_loader
        self._claude_index_loader = claude_index_loader
        self._clock = clock
        self._last_sweep_at = 0.0
        self._table: dict[int, ProcessEntry] = {}

    def _refresh_table(self) -> dict[int, ProcessEntry]:
        now = self._clock()
        if now - self._last_sweep_at >= SWEEP_MIN_INTERVAL_SECONDS or not self._table:
            self._table = dict(self._table_loader())
            self._last_sweep_at = now
        return self._table

    def sweep(self, sessions: Iterable[tuple[str, str]]) -> list[DeadAgentProcess]:
        wanted = [(p, s) for p, s in dict.fromkeys(sessions) if p and s]
        if not wanted:
            return []
        table = self._refresh_table()
        if not table:
            # Cannot see the process table: never declare anything dead.
            return []
        claude_index: dict[str, ProcessEntry] | None = None
        dead: list[DeadAgentProcess] = []
        for provider, session_id in wanted:
            record = load_record(provider, session_id, state_dir=self.state_dir)
            if record is None and provider == "claude":
                if claude_index is None:
                    claude_index = self._claude_index_loader()
                entry = claude_index.get(session_id)
                if entry is not None:
                    record = record_agent_process(
                        provider, session_id, entry, state_dir=self.state_dir, now=self._clock()
                    )
            if record is None or record.ended_at_epoch is not None:
                continue
            alive, reason = process_is_live(record, table)
            if alive:
                continue
            ended = replace(record, ended_at_epoch=self._clock(), end_reason=reason)
            write_record(ended, state_dir=self.state_dir)
            dead.append(DeadAgentProcess(ended, reason))
        return dead


def prune_registry(
    *, state_dir: Path | None = None, max_age_seconds: float = 7 * 86400.0, now: float | None = None
) -> int:
    """Delete ended or ancient records. Returns the number removed."""
    base = registry_dir(state_dir)
    current = time.time() if now is None else now
    removed = 0
    try:
        files = list(base.glob("*/*.json"))
    except OSError:
        return 0
    for path in files[:4096]:
        try:
            age = current - path.stat().st_mtime
        except OSError:
            continue
        if age > max_age_seconds:
            try:
                path.unlink()
                removed += 1
            except OSError:
                pass
    return removed


__all__ = [
    "PROVIDER_PROCESS_NAMES",
    "AgentProcessRecord",
    "DeadAgentProcess",
    "ProcessEntry",
    "ProcessSweeper",
    "claude_session_index",
    "discover_agent_process",
    "list_processes",
    "load_record",
    "note_hook_payload",
    "process_is_live",
    "prune_registry",
    "record_agent_process",
    "record_path",
    "registry_dir",
    "write_record",
]
