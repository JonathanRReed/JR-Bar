"""Bounded, read-only adapters for native delegation metadata.

Versioned fixtures in tests/fixtures/lineage describe the supported shapes.
Add a parser emitting ParentLink values, then register its local file pattern
in LocalLineageReader. Readers never open a network connection.
"""
from __future__ import annotations

import hashlib
import json
import math
import re
import sqlite3
import threading
import time
from contextlib import closing
from dataclasses import replace
from datetime import datetime, timezone
from functools import lru_cache
from pathlib import Path

from .models import AgentMode, AgentStatus, ParentLink

_ID = re.compile(r"[A-Za-z0-9][A-Za-z0-9._~:-]{0,255}\Z")
MAX_FILES = 512
MAX_HEADER_BYTES = 64 * 1024


# ACP registry IDs, not instance labels. Registry entries are documented at
# https://github.com/agentclientprotocol/registry/tree/main/factory-droid
# and https://github.com/agentclientprotocol/registry/tree/main/devin.
_ACP_REGISTRY_PROVIDERS = {"factory-droid": "factory", "devin": "devin"}


def t3_registry_providers(document: dict) -> dict[str, str]:
    instances = document.get("providerInstances")
    if type(instances) is not dict:
        return {}
    result = {}
    for instance, definition in instances.items():
        if type(definition) is not dict or definition.get("driver") != "acpRegistry" or definition.get("enabled") is not True:
            continue
        config = definition.get("config")
        agent_id = config.get("agentId") if type(config) is dict else None
        if type(agent_id) is str and agent_id in _ACP_REGISTRY_PROVIDERS:
            result[instance] = _ACP_REGISTRY_PROVIDERS[agent_id]
    return result


def read_t3_registry_providers(path: Path) -> dict[str, str]:
    try:
        stat = path.stat()
        return _read_t3_registry_providers(path, stat.st_mtime_ns, stat.st_size, stat.st_ino)
    except OSError:
        return {}


@lru_cache(maxsize=8)
def _read_t3_registry_providers(path: Path, modified: int, size: int, inode: int) -> dict[str, str]:
    try:
        with path.open("rb") as stream:
            raw = stream.read(512 * 1024 + 1)
        if len(raw) > 512 * 1024:
            return {}
        document = json.loads(raw)
        return t3_registry_providers(document) if type(document) is dict else {}
    except (OSError, ValueError, RecursionError):
        return {}


def _provider(driver, instance=None, registry_providers=None):
    from .t3_compat import _normalize_provider

    if driver == "acpRegistry":
        return (registry_providers or {}).get(instance, "other")
    return _normalize_provider(driver)


def member_key(provider: str, native_id: object, kind: str = "session") -> str | None:
    if type(native_id) is not str or not _ID.fullmatch(native_id):
        return None
    return f"{provider}:{kind}:{native_id}"


def _link(child, parent, harness, observed_at) -> tuple[ParentLink, ...]:
    return (ParentLink(child, parent, harness, observed_at),) if child else ()


def cursor_native_id(value: object) -> str | None:
    if type(value) is not str or not _ID.fullmatch(value) or len(value) > 128:
        return None
    return hashlib.sha256(b"sidepulse.cursor.conversation.v1\0" + value.encode("ascii")).hexdigest()


def cursor_parent_links(payload: dict, *, observed_at: float) -> tuple[ParentLink, ...]:
    child = cursor_native_id(payload.get("subagent_id"))
    parent = cursor_native_id(payload.get("parent_conversation_id"))
    return _link(member_key("cursor", child), member_key("cursor", parent), "cursor", observed_at)


def hermes_parent_links(payload: dict, *, observed_at: float) -> tuple[ParentLink, ...]:
    child = (member_key("hermes", payload.get("child_session_id"))
             or member_key("hermes", payload.get("child_subagent_id")))
    parent = (member_key("hermes", payload.get("parent_session_id"))
              or member_key("hermes", payload.get("parent_subagent_id")))
    return _link(child, parent, "hermes", observed_at)


def persisted_parent_links(payload: object, provider: str) -> tuple[ParentLink, ...]:
    """Validate the optional content-free hook lineage extension."""
    if type(payload) is not list or not 1 <= len(payload) <= 4:
        raise ValueError("invalid parent links")
    links = []
    for row in payload:
        if type(row) is not dict or set(row) != {"child", "parent", "harness", "observed_at"}:
            raise ValueError("invalid parent link")
        def key(value):
            if type(value) is not str:
                return False
            prefix, _, native = value.partition(":")
            kind, _, native = native.partition(":")
            return prefix == provider and kind in {"session", "agent"} and member_key(provider, native, kind) == value
        stamp = row["observed_at"]
        if (not key(row["child"]) or (row["parent"] is not None and not key(row["parent"]))
                or row["harness"] != provider or type(stamp) not in {float, int}
                or not math.isfinite(stamp) or stamp < 0):
            raise ValueError("invalid parent link")
        links.append(ParentLink(row["child"], row["parent"], provider, float(stamp)))
    return tuple(links)


def hook_parent_links(record) -> tuple[ParentLink, ...]:
    raw = record.raw
    if "parent_links" in raw:
        return persisted_parent_links(raw["parent_links"], record.provider)
    if record.provider == "cursor":
        return cursor_parent_links(raw, observed_at=record.logged_at.timestamp())
    if record.provider == "hermes":
        return hermes_parent_links(raw, observed_at=record.logged_at.timestamp())
    if record.provider == "openclaw":
        # Newer native IDs need the local registry's session-key mapping.
        if "spawnedBy" not in raw:
            return ()
        return openclaw_parent_links(raw, observed_at=record.logged_at.timestamp())
    if record.provider == "grok":
        return grok_parent_links(raw, observed_at=record.logged_at.timestamp())
    return ()


def read_hermes_links(database: Path, *, observed_at: float) -> tuple[ParentLink, ...]:
    """Read identities and creation times only, never session content."""
    if not database.is_file():
        return ()
    try:
        with closing(sqlite3.connect(database.as_uri() + "?mode=ro", uri=True, timeout=0.1)) as connection:
            connection.execute("PRAGMA query_only=ON")
            rows = connection.execute(
                "SELECT id, parent_session_id, started_at FROM sessions WHERE parent_session_id IS NOT NULL "
                "ORDER BY started_at DESC LIMIT ?", (MAX_FILES,)).fetchall()
            return tuple(link for child, parent, stamp in rows
                         for link in hermes_parent_links({"child_session_id": child, "parent_session_id": parent},
                             observed_at=float(stamp) if type(stamp) in {int, float} else 0.0))
    except (OSError, sqlite3.Error):
        return ()


def opencode_parent_links(info: dict, *, observed_at: float) -> tuple[ParentLink, ...]:
    if "parentID" not in info:
        return ()
    return _link(member_key("opencode", info.get("id")), member_key("opencode", info.get("parentID")),
                 "opencode", observed_at)


def read_opencode_links(database: Path, *, observed_at: float) -> tuple[ParentLink, ...]:
    if not database.is_file():
        return ()
    try:
        with closing(sqlite3.connect(database.as_uri() + "?mode=ro", uri=True, timeout=0.1)) as connection:
            connection.execute("PRAGMA query_only=ON")
            rows = connection.execute(
                "SELECT id, parent_id, time_updated FROM session WHERE parent_id IS NOT NULL "
                "ORDER BY time_updated DESC LIMIT ?", (MAX_FILES,)).fetchall()
            return tuple(link for child, parent, stamp in rows
                         for link in opencode_parent_links({"id": child, "parentID": parent},
                             observed_at=float(stamp) / 1000 if type(stamp) in {int, float} else 0.0))
    except (OSError, sqlite3.Error):
        return ()


def openclaw_parent_links(payload: dict, *, observed_at: float, session_keys=None) -> tuple[ParentLink, ...]:
    if "spawnedBy" not in payload and "spawnedBySessionId" not in payload:
        key = payload.get("session_id")
        if type(key) is not str or ":subagent:" not in key:
            return ()
    parents = []
    if payload.get("spawnedBy"):
        parents.append(member_key("openclaw", payload["spawnedBy"]))
    if session_keys is not None and payload.get("spawnedBySessionId"):
        native = payload.get("spawnedBySessionId")
        parent = session_keys.get(native) if type(native) is str else None
        parents.append(member_key("openclaw", parent))
    child = member_key("openclaw", payload.get("session_id"))
    return tuple(link for parent in dict.fromkeys(parents or [None])
                 for link in _link(child, parent, "openclaw", observed_at))


def gemini_parent_links(header: dict, *, observed_at: float, parent_session_id=None) -> tuple[ParentLink, ...]:
    if header.get("kind") != "subagent":
        return ()
    return _link(member_key("gemini", header.get("sessionId")), member_key("gemini", parent_session_id),
                 "gemini", observed_at)


def grok_parent_links(payload: dict, *, observed_at: float) -> tuple[ParentLink, ...]:
    stamp = payload.get("lineage_observed_at")
    if type(stamp) in {int, float} and math.isfinite(stamp) and stamp >= 0:
        observed_at = float(stamp)
    child = member_key("grok", payload.get("agent_id"), "agent")
    if child:
        parent_agent = payload.get("parent_agent_id")
        parent = (member_key("grok", parent_agent, "agent") if parent_agent
                  else member_key("grok", payload.get("parent_session_id") or payload.get("session_id")))
        return _link(child, parent, "grok", observed_at)
    event = payload.get("hook_event_name") or payload.get("hookEventName")
    if event not in {"SubagentStart", "subagent_start"} and (payload.get("subagentType") or payload.get("subagent_type")):
        return _link(member_key("grok", payload.get("session_id") or payload.get("sessionId")), None,
                     "grok", observed_at)
    return ()


def read_hook_links(path: Path, provider: str, *, now: float) -> tuple[ParentLink, ...]:
    """Recover bounded content-free evidence from normalized logs only."""
    try:
        with path.open("rb") as stream:
            size = stream.seek(0, 2)
            start = max(0, size - 2 * 1024 * 1024)
            stream.seek(start)
            if start:
                stream.readline(MAX_HEADER_BYTES + 1)
            raw = stream.read(2 * 1024 * 1024)
        links = set()
        for line in raw.splitlines()[-MAX_FILES * 8:]:
            if len(line) > MAX_HEADER_BYTES:
                continue
            try:
                payload = json.loads(line)
                if (type(payload) is not dict or payload.get("record_kind") != "normalized"
                        or payload.get("provider_id") != provider):
                    continue
                if "parent_links" in payload:
                    evidence = persisted_parent_links(payload["parent_links"], provider)
                elif provider == "grok" and payload.get("parent_work_id"):
                    evidence = _link(member_key("grok", payload.get("provider_work_id"), "agent"),
                        member_key("grok", payload.get("parent_work_id")), "grok", payload.get("occurred_at_epoch", 0))
                else:
                    continue
                for link in evidence:
                    if type(link.observed_at) not in {int, float}:
                        continue
                    if 0 <= now - link.observed_at <= 86_400:
                        links.add(link)
            except (ValueError, RecursionError):
                continue
        # Preserve conflicting parents for the resolver, but not every repeat
        # of one parent from a busy stream.
        newest = {}
        for link in links:
            key = (link.child, link.parent)
            if key not in newest or newest[key].observed_at < link.observed_at:
                newest[key] = link
        return tuple(sorted(newest.values(), key=lambda link: (-link.observed_at, link.child, link.parent or ""))[:MAX_FILES])
    except OSError:
        return ()


def hook_lineage_statuses(links, previous=(), *, now: float) -> tuple[AgentStatus, ...]:
    """Keep hook evidence beside work truth without inventing activity."""
    by_child = {}
    retained = tuple(link for row in previous for link in row.parent_links if 0 <= now - link.observed_at <= 86_400)
    for link in (*tuple(links), *retained):
        parents = by_child.setdefault(link.child, {})
        before = parents.get(link.parent)
        if before is None or before.observed_at < link.observed_at:
            parents[link.parent] = link
    # A later explicit Grok link replaces the earlier unknown-child marker.
    for child, parents in list(by_child.items()):
        if child.startswith("grok:agent:") and any(parent is not None for parent in parents):
            unknown = child.replace(":agent:", ":session:", 1)
            if set(by_child.get(unknown, {})) == {None}:
                by_child.pop(unknown)
    result = []
    for child, parents in by_child.items():
        evidence = tuple(sorted(parents.values(), key=lambda link: (link.parent or "", link.observed_at)))
        stamp = max(link.observed_at for link in evidence)
        if len(evidence) > 4:
            evidence = (ParentLink(child, None, child.split(":", 1)[0], stamp),)
        result.append(AgentStatus(child.split(":", 1)[0], child, "Worker", AgentMode.UNKNOWN,
                      datetime.fromtimestamp(stamp, timezone.utc), "LineageObserved", parent_links=evidence))
    return tuple(sorted(result, key=lambda row: (-row.updated_at.timestamp(), row.agent_id))[:MAX_FILES])


def read_openclaw_links(home: Path) -> tuple[ParentLink, ...]:
    """The session registry maps native session IDs to hook session keys."""
    entries = []
    for path in islice((home / ".openclaw/agents").glob("*/sessions/sessions.json"), 32):
        try:
            with path.open("rb") as stream:
                raw = stream.read(512 * 1024 + 1)
            if len(raw) > 512 * 1024:
                continue
            rows = json.loads(raw)
            if type(rows) is not dict or len(rows) > MAX_FILES:
                continue
            for key, entry in rows.items():
                if type(entry) is not dict:
                    continue
                stamp = entry.get("updatedAt")
                stamp = float(stamp) / 1000 if type(stamp) in {int, float} and math.isfinite(stamp) else 0.0
                entries.append((key, entry, stamp))
        except (OSError, ValueError, RecursionError):
            continue
    entries = sorted(entries, key=lambda item: item[2], reverse=True)[:MAX_FILES]
    keys = {}
    for key, entry, _ in entries:
        native = entry.get("sessionId")
        if type(native) is str:
            keys[native] = key if native not in keys else None
    return tuple(link for key, entry, stamp in entries for link in openclaw_parent_links(
        dict(entry, session_id=key), observed_at=stamp, session_keys=keys))


def match_opencode_roster(rows: tuple[AgentStatus, ...], observed: frozenset[str]) -> tuple[AgentStatus, ...]:
    """A hook's agent key and the DB's session ID name the same native session.

    Match only an observed identity. If both forms exist, retain an unlinked
    marker instead of guessing which live row owns the database entry.
    """
    def match(key):
        if key is None or not key.startswith("opencode:session:"):
            return key
        agent = key.replace("opencode:session:", "opencode:agent:", 1)
        return agent if agent in observed and key not in observed else key
    result = []
    for row in rows:
        alias = row.agent_id.replace("opencode:session:", "opencode:agent:", 1)
        if row.provider == "opencode" and row.agent_id in observed and alias in observed:
            for key in (row.agent_id, alias):
                result.append(replace(row, agent_id=key, parent_links=tuple(
                    replace(link, child=key, parent=None) for link in row.parent_links)))
            continue
        key = match(row.agent_id)
        evidence = []
        for link in row.parent_links:
            child, parent = match(link.child), match(link.parent)
            for native in (link.child, link.parent):
                if native and native in observed and native.replace(":session:", ":agent:", 1) in observed:
                    parent = None
            evidence.append(replace(link, child=child, parent=parent))
        result.append(replace(row, agent_id=key, parent_links=tuple(evidence)))
    return tuple(result)


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
    declared_worker = type(source) is dict and isinstance(source.get("subagent"), (dict, str))
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


def t3_parent_links(threads: list[dict], bindings: list[dict], *, observed_at: float, subagents=(), registry_providers=None) -> tuple[dict[str, str], tuple[ParentLink, ...]]:
    """Bind each app thread to exactly one provider-qualified native identity.

    Only each thread's selected provider thread is eligible. Several app
    threads or provider instances claiming one native ID make it ambiguous.
    Unbound workers retain a T3-qualified identity and a rejected link.
    """
    def unbound_key(thread, provider):
        identifier = "t3-" + thread
        if not _ID.fullmatch(identifier):
            identifier = "t3-" + hashlib.sha256(thread.encode("utf-8")).hexdigest()[:32]
        return f"{provider}:session:{identifier}"

    keys: dict[str, str] = {}
    ambiguous = set()
    owners: dict[str, set[tuple[str, str]]] = {}
    bindings_by_thread = {}
    for binding in bindings:
        bindings_by_thread.setdefault((binding.get("thread_id"), binding.get("provider_thread_id")), []).append(binding)
    for thread in threads:
        tid = thread["thread_id"]
        candidates = bindings_by_thread.get((tid, thread.get("active_provider_thread_id")), ())
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
            provider = _provider(binding.get("driver"), binding.get("provider_instance_id"), registry_providers)
            native_id = native.get("nativeId")
            key = member_key(provider, cursor_native_id(native_id) if provider == "cursor" else native_id)
            if key:
                valid.append(key)
                owners.setdefault(key, set()).add((tid, binding.get("provider_instance_id") or ""))
        if len(valid) == 1:
            keys[tid] = valid[0]
        else:
            ambiguous.add(tid)
            provider = _provider(thread.get("default_provider"))
            keys[tid] = unbound_key(tid, provider)
    ambiguous.update(tid for tid, key in keys.items() if len(owners.get(key, ())) > 1)
    for tid in ambiguous:
        provider = keys[tid].split(":", 1)[0]
        keys[tid] = unbound_key(tid, provider)
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
                provider = _provider(native.get("driver"), worker.get("provider_instance_id"), registry_providers)
                kind = "session" if provider in {"codex", "factory", "cursor", "hermes", "opencode", "openclaw", "gemini", "grok"} else "agent"
                native_id = native.get("nativeId")
                child = member_key(provider, cursor_native_id(native_id) if provider == "cursor" else native_id, kind)
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
    def __init__(self, home: Path, *, state_dir: Path | None = None):
        from .state_paths import default_state_dir

        self.home = home
        self.state_dir = state_dir if state_dir is not None else default_state_dir(home)
        self._cache: dict[Path, tuple[tuple[int, int], tuple[ParentLink, ...]]] = {}
        self._directories: dict[Path, tuple[int, tuple[Path, ...]]] = {}
        self._lock = threading.Lock()
        self._rows: tuple[AgentStatus, ...] = ()
        self._running = False
        self._next_scan = 0.0

    def _changed_paths(self, root: Path, pattern: str, *, now: float):
        """List a directory again only when its entries changed."""
        pending = [root]
        while pending:
            directory = pending.pop()
            try:
                modified = directory.stat().st_mtime_ns
                cached = self._directories.get(directory)
                if cached and cached[0] == modified:
                    pending.extend(cached[1])
                    continue
                children = []
                for path in directory.iterdir():
                    if path.is_symlink():
                        continue
                    if path.is_dir():
                        children.append(path)
                    elif path.match(pattern):
                        stamp = path.stat().st_mtime
                        if -5 <= now - stamp <= 86_400:
                            yield stamp, path
                self._directories[directory] = (modified, tuple(children))
                pending.extend(children)
            except OSError:
                self._directories.pop(directory, None)

    def read(self, providers: frozenset[str], *, now: float, active_paths=()) -> tuple[AgentStatus, ...]:
        formats = (
            ("claude", ".claude/projects", "agent-*.meta.json", claude_parent_links),
            ("codex", ".codex/sessions", "*.jsonl", codex_parent_links),
            ("factory", ".factory/sessions", "*.jsonl", factory_parent_links),
            ("gemini", ".gemini/tmp", "*.jsonl", gemini_parent_links),
        )
        for provider, root, pattern, parser in formats:
            if provider not in providers:
                continue
            base = self.home / root
            changed = list(self._changed_paths(base, pattern, now=now))
            known = set(active_paths)
            for path in known:
                if path.is_relative_to(base) and path.match(pattern):
                    try:
                        changed.append((path.stat().st_mtime, path))
                    except OSError:
                        self._cache.pop(path, None)
            paths = sorted(set(changed), key=lambda item: (item[0], str(item[1])), reverse=True)
            for modified, path in paths[:MAX_FILES]:
                if not -5 <= now - modified <= 86_400:
                    self._cache.pop(path, None)
                    continue
                try:
                    stat = path.stat()
                    signature = (stat.st_mtime_ns, stat.st_size)
                    cached = self._cache.get(path)
                    if cached and cached[0] == signature:
                        continue
                    with path.open("rb") as stream:
                        raw = stream.readline(MAX_HEADER_BYTES + 1)
                    self._cache.pop(path, None)
                    if len(raw) > MAX_HEADER_BYTES:
                        continue
                    payload = json.loads(raw)
                    if type(payload) is not dict:
                        continue
                    kwargs = {"observed_at": stat.st_mtime}
                    if provider == "claude":
                        kwargs["agent_id"] = path.name[len("agent-"):-len(".meta.json")]
                    if provider == "gemini":
                        kwargs["parent_session_id"] = (path.parent.name if path.parent.parent.name == "chats"
                            and path.stem == payload.get("sessionId") else None)
                    parsed = parser(payload, **kwargs)
                    # Roots supply identity only. A header proves no live work.
                    self._cache[path] = (signature, parsed)
                except (OSError, ValueError, RecursionError):
                    continue
        self._cache = dict(sorted(
            ((path, value) for path, value in self._cache.items()
             if -5 <= now - value[0][0] / 1_000_000_000 <= 86_400),
            key=lambda item: item[1][0][0], reverse=True,
        )[:MAX_FILES])
        links = [link for path, (_, evidence) in self._cache.items()
                 if any(path.is_relative_to(self.home / root) and provider in providers
                        for provider, root, _, _ in formats) for link in evidence]
        if "devin" in providers:
            links.extend(read_devin_links(self.home / ".local/share/devin/cli/sessions.db", observed_at=now))
        if "hermes" in providers:
            links.extend(read_hermes_links(self.home / ".hermes/state.db", observed_at=now))
        if "opencode" in providers:
            links.extend(read_opencode_links(self.home / ".local/share/opencode/opencode.db", observed_at=now))
        if "openclaw" in providers:
            links.extend(read_openclaw_links(self.home))
        for provider in sorted(providers & {"cursor", "hermes", "openclaw", "grok"}):
            links.extend(read_hook_links(self.state_dir / f"{provider}.jsonl", provider, now=now))
        by_child: dict[str, list[ParentLink]] = {}
        for link in links:
            by_child.setdefault(link.child, []).append(link)
        return tuple(AgentStatus(
            provider=child.split(":", 1)[0], agent_id=child,
            display_name="Worker", mode=AgentMode.UNKNOWN,
            updated_at=datetime.fromtimestamp(max(link.observed_at for link in evidence), timezone.utc),
            event_name="LineageObserved", parent_links=tuple(evidence),
        ) for child, evidence in sorted(by_child.items())[:MAX_FILES])

    def request(self, providers: frozenset[str], *, active_paths=()) -> tuple[AgentStatus, ...]:
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
                updated = self.read(providers, now=time.time(), active_paths=active_paths)
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
        from .state_paths import default_state_dir
        reader = LocalLineageReader(Path.home(), state_dir=default_state_dir())
        target._local_lineage_reader = reader
    paths = getattr(monitor, "lineage_paths_by_session", {})
    active_paths = tuple(Path(path) for status in getattr(snapshot, "statuses", ()) if not status.stale
                         for key in (status.agent_id, status.parent_agent_id)
                         if (path := paths.get(key)))
    rows = tuple(row for row in reader.request(providers, active_paths=active_paths) if row.provider in providers)
    observed = frozenset(s.agent_id for s in (*getattr(snapshot, "statuses", ()), *getattr(snapshot, "stale_statuses", ()))
                         if s.event_name != "LineageObserved")
    publish("lineage", match_opencode_roster(rows, observed))
