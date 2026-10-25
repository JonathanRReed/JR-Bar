"""Bounded, read-only adapters for native delegation metadata.

Versioned fixtures in tests/fixtures/lineage describe the supported shapes.
Add a parser emitting ParentLink values, then register its local file pattern
in LocalLineageReader. Readers never open a network connection.
"""
from __future__ import annotations

import json
import re
import sqlite3
import threading
import time
from contextlib import closing
from datetime import datetime, timezone
from itertools import islice
from pathlib import Path

from .models import AgentMode, AgentStatus, ParentLink

_ID = re.compile(r"[A-Za-z0-9][A-Za-z0-9._~:-]{0,255}\Z")
MAX_FILES = 512
MAX_HEADER_BYTES = 64 * 1024


def _provider(driver):
    from .t3_compat import _normalize_provider

    return _normalize_provider(driver)


def member_key(provider: str, native_id: object, kind: str = "session") -> str | None:
    if type(native_id) is not str or not _ID.fullmatch(native_id):
        return None
    return f"{provider}:{kind}:{native_id}"


def _link(child, parent, harness, observed_at) -> tuple[ParentLink, ...]:
    return (ParentLink(child, parent, harness, observed_at),) if child else ()


def claude_parent_links(payload: dict, *, observed_at: float, agent_id: str | None = None) -> tuple[ParentLink, ...]:
    child = member_key("claude", payload.get("agent_id") or agent_id, "agent")
    if not child:
        return ()
    parent_agent = payload.get("parentAgentId") or payload.get("parent_agent_id")
    parent = (member_key("claude", parent_agent, "agent") if parent_agent
              else member_key("claude", payload.get("session_id")))
    return _link(child, parent, "claude", observed_at)


def codex_parent_links(row: dict, *, observed_at: float) -> tuple[ParentLink, ...]:
    if row.get("type") != "session_meta" or type(row.get("payload")) is not dict:
        return ()
    payload = row["payload"]
    source = payload.get("source")
    spawn = source.get("subagent", {}) if type(source) is dict else {}
    spawn = spawn.get("thread_spawn", {}) if type(spawn) is dict else {}
    nested_parent = spawn.get("parent_thread_id") if type(spawn) is dict else None
    explicit_parent = payload.get("parent_thread_id")
    # forked_from_id is copied history, never delegation.
    declared_worker = type(source) is dict and type(source.get("subagent")) is dict
    if not explicit_parent and not nested_parent and not declared_worker:
        return ()
    child = member_key("codex", payload.get("id"))
    parents = tuple(parent for parent in (explicit_parent, nested_parent) if parent is not None)
    return tuple(ParentLink(child, member_key("codex", parent), "codex", observed_at)
                 for parent in parents or (None,) if child)


def factory_parent_links(header: dict, *, observed_at: float) -> tuple[ParentLink, ...]:
    if not header.get("callingSessionId") and not header.get("callingToolUseId"):
        return ()
    return _link(member_key("factory", header.get("id")),
                 member_key("factory", header.get("callingSessionId")), "factory", observed_at)


def devin_parent_links(rows, *, observed_at: float) -> tuple[ParentLink, ...]:
    links = []
    for raw_row in rows:
        row = dict(raw_row)
        stamp = row.get("updated_at", observed_at)
        if type(stamp) is str:
            try:
                parsed = datetime.fromisoformat(stamp.replace("Z", "+00:00"))
                stamp = parsed.replace(tzinfo=timezone.utc).timestamp() if parsed.tzinfo is None else parsed.timestamp()
            except ValueError:
                stamp = 0.0
        if type(stamp) not in {int, float}:
            stamp = 0.0
        links.extend(_link(member_key("devin", row["agent_id"], "agent"),
                           member_key("devin", row["session_id"]), "devin", float(stamp)))
    return tuple(links)


def t3_parent_links(threads: list[dict], bindings: list[dict], *, observed_at: float, subagents=()) -> tuple[dict[str, str], tuple[ParentLink, ...]]:
    """Bind each app thread to exactly one provider-qualified native identity.

    Only each thread's selected provider thread is eligible. Several app
    threads or provider instances claiming one native ID make it ambiguous.
    Unbound workers retain a T3-qualified identity and a rejected link.
    """
    keys: dict[str, str] = {}
    ambiguous = set()
    owners: dict[str, set[tuple[str, str]]] = {}
    for thread in threads:
        tid = thread["thread_id"]
        candidates = [b for b in bindings if b.get("provider_thread_id") == thread.get("active_provider_thread_id")
                      and b.get("thread_id") == tid]
        candidates = [b for b in candidates if not b.get("status") or b["status"] not in {"closed", "archived", "deleted"}]
        valid = []
        for binding in candidates:
            payload = binding.get("payload_json", {})
            if type(payload) is str:
                try:
                    payload = json.loads(payload)
                except ValueError:
                    continue
            native = payload.get("nativeThreadRef") if type(payload) is dict else None
            if type(native) is not dict or native.get("driver") != binding.get("driver"):
                continue
            provider = _provider(binding.get("driver"))
            key = member_key(provider, native.get("nativeId"))
            if key:
                valid.append(key)
                owners.setdefault(key, set()).add((tid, binding.get("provider_instance_id") or ""))
        if len(valid) == 1:
            keys[tid] = valid[0]
        else:
            ambiguous.add(tid)
            provider = _provider(thread.get("default_provider"))
            keys[tid] = member_key(provider, "t3-" + tid) or f"other:session:t3-unbound-{len(keys)}"
    ambiguous.update(tid for tid, key in keys.items() if len(owners.get(key, ())) > 1)
    for tid in ambiguous:
        provider = keys[tid].split(":", 1)[0]
        keys[tid] = member_key(provider, "t3-" + tid) or f"other:session:t3-unbound-{len(keys)}"
    links = []
    for thread in threads:
        payload = thread.get("payload_json", {})
        if type(payload) is str:
            try:
                payload = json.loads(payload)
            except ValueError:
                continue
        lineage = payload.get("lineage", {}) if type(payload) is dict else {}
        if type(lineage) is not dict or lineage.get("relationshipToParent") != "subagent":
            continue
        tid = thread["thread_id"]
        parent_tid = lineage.get("parentThreadId")
        if type(parent_tid) is not str:
            parent_tid = None
        parent = keys.get(parent_tid) if tid not in ambiguous and parent_tid not in ambiguous else None
        links.append(ParentLink(keys[tid], parent, "t3code", observed_at))
    for worker in subagents:
        parent_tid = worker.get("thread_id")
        child_tid = worker.get("child_thread_id")
        child = keys.get(child_tid)
        if child is None:
            if worker.get("status") not in {"running", "starting", "active", "pending"}:
                continue
            native = worker.get("native_task_ref")
            if type(native) is str:
                try:
                    native = json.loads(native)
                except ValueError:
                    native = None
            if type(native) is dict:
                provider = _provider(native.get("driver"))
                child = member_key(provider, native.get("nativeId"), "agent")
        if child:
            parent = keys.get(parent_tid) if child_tid not in ambiguous and parent_tid not in ambiguous else None
            links.append(ParentLink(child, parent, "t3code", observed_at))
    return keys, tuple(links)


def read_devin_links(database: Path, *, observed_at: float) -> tuple[ParentLink, ...]:
    if not database.is_file():
        return ()
    try:
        with closing(sqlite3.connect(database.as_uri() + "?mode=ro", uri=True, timeout=0.1)) as connection:
            connection.execute("PRAGMA query_only=ON")
            connection.row_factory = sqlite3.Row
            columns = {row[1] for row in connection.execute("PRAGMA table_info(subagent_heads)")}
            stamp_column = ", updated_at" if "updated_at" in columns else ""
            ordering = " ORDER BY updated_at DESC" if stamp_column else ""
            rows = connection.execute(f"SELECT session_id, agent_id{stamp_column} FROM subagent_heads{ordering} LIMIT ?",
                                      (MAX_FILES,)).fetchall()
            return devin_parent_links(rows, observed_at=min(observed_at, database.stat().st_mtime))
    except (OSError, sqlite3.Error):
        return ()


class LocalLineageReader:
    """Read a bounded set of headers on a worker, cached by file identity.

    request() never waits for disk. Results contain no transcript content.
    A fresh instance reconstructs the same links after a daemon restart.
    """
    def __init__(self, home: Path):
        self.home = home
        self._cache: dict[Path, tuple[tuple[int, int], tuple[ParentLink, ...]]] = {}
        self._root_headers: dict[Path, str] = {}
        self._lock = threading.Lock()
        self._rows: tuple[AgentStatus, ...] = ()
        self._running = False
        self._next_scan = 0.0

    def read(self, providers: frozenset[str], *, now: float) -> tuple[AgentStatus, ...]:
        links = []
        eligible = set()
        formats = (
            ("claude", ".claude/projects", "*/**/agent-*.meta.json", claude_parent_links),
            ("codex", ".codex/sessions", "**/*.jsonl", codex_parent_links),
            ("factory", ".factory/sessions", "*/*.jsonl", factory_parent_links),
        )
        for provider, root, pattern, parser in formats:
            if provider not in providers:
                continue
            # Bound enumeration as well as reads. Missing coverage stays unlinked.
            candidates = []
            for path in islice((self.home / root).glob(pattern), MAX_FILES * 16):
                try:
                    modified = path.stat().st_mtime
                    if 0 <= now - modified <= 86_400:
                        candidates.append((modified, str(path), path))
                except OSError:
                    continue
            paths = [item[2] for item in sorted(candidates, reverse=True)[:MAX_FILES]]
            for path in paths:
                try:
                    stat = path.stat()
                    if not 0 <= now - stat.st_mtime <= 86_400:
                        continue
                    eligible.add(path)
                    signature = (stat.st_mtime_ns, stat.st_size)
                    cached = self._cache.get(path)
                    if cached and cached[0] == signature:
                        links.extend(cached[1])
                        continue
                    with path.open("rb") as stream:
                        raw = stream.readline(MAX_HEADER_BYTES + 1)
                    if len(raw) > MAX_HEADER_BYTES:
                        continue
                    payload = json.loads(raw)
                    if type(payload) is not dict:
                        continue
                    kwargs = {"observed_at": stat.st_mtime}
                    if provider == "claude":
                        kwargs["agent_id"] = path.name[len("agent-"):-len(".meta.json")]
                    parsed = parser(payload, **kwargs)
                    root_id = payload.get("id") if provider == "factory" else None
                    if provider == "codex" and payload.get("type") == "session_meta" and type(payload.get("payload")) is dict:
                        root_id = payload["payload"].get("id")
                    root_key = member_key(provider, root_id)
                    if root_key and not parsed:
                        self._root_headers[path] = root_key
                    else:
                        self._root_headers.pop(path, None)
                    self._cache[path] = (signature, parsed)
                    links.extend(parsed)
                except (OSError, ValueError, RecursionError):
                    continue
        self._cache = {path: value for path, value in self._cache.items() if path in eligible}
        self._root_headers = {path: key for path, key in self._root_headers.items() if path in eligible}
        if "devin" in providers:
            links.extend(read_devin_links(self.home / ".local/share/devin/cli/sessions.db", observed_at=now))
        by_child: dict[str, list[ParentLink]] = {}
        root_observed = {}
        for path, key in self._root_headers.items():
            by_child.setdefault(key, [])
            root_observed[key] = self._cache[path][0][0] / 1_000_000_000
        for link in links:
            by_child.setdefault(link.child, []).append(link)
        return tuple(AgentStatus(
            provider=child.split(":", 1)[0], agent_id=child,
            display_name="Worker", mode=AgentMode.UNKNOWN,
            updated_at=datetime.fromtimestamp(max((link.observed_at for link in evidence), default=root_observed.get(child, now)), timezone.utc),
            event_name="LineageObserved", parent_links=tuple(evidence),
        ) for child, evidence in sorted(by_child.items())[:MAX_FILES])

    def request(self, providers: frozenset[str]) -> tuple[AgentStatus, ...]:
        if not providers:
            return ()
        with self._lock:
            rows = self._rows
            if self._running or time.monotonic() < self._next_scan:
                return rows
            self._running = True
            self._next_scan = time.monotonic() + 10.0
        def scan():
            try:
                updated = self.read(providers, now=time.time())
                with self._lock:
                    self._rows = updated
            finally:
                with self._lock:
                    self._running = False
        threading.Thread(target=scan, name="jrbar-lineage", daemon=True).start()
        return rows


def update_lineage_runtime(target) -> None:
    monitor = getattr(target, "monitor", None)
    publish = getattr(monitor, "replace_external_statuses", None)
    if not callable(publish):
        return
    snapshot = getattr(target, "last_snapshot", None)
    providers = frozenset(s.provider for s in getattr(snapshot, "statuses", ()) if not s.stale)
    reader = getattr(target, "_local_lineage_reader", None)
    if not providers:
        publish("lineage", ())
        return
    if reader is None:
        reader = LocalLineageReader(Path.home())
        target._local_lineage_reader = reader
    publish("lineage", tuple(row for row in reader.request(providers) if row.provider in providers))
