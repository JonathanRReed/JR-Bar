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
from collections import OrderedDict
from contextlib import closing
from dataclasses import replace
from datetime import datetime, timezone
from functools import lru_cache
from itertools import islice
from pathlib import Path

from .models import AgentMode, AgentStatus, ParentLink
from .provider_ids import PROVIDER_ALIASES, canonical_provider_id

_ID = re.compile(r"[A-Za-z0-9][A-Za-z0-9._~:-]{0,255}\Z")
MAX_FILES = 512
MAX_HEADER_BYTES = 64 * 1024




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
        if type(agent_id) is str and canonical_provider_id(agent_id) in PROVIDER_ALIASES:
            result[instance] = canonical_provider_id(agent_id)
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


_HERMES_ALIASES: OrderedDict[str, str | None] = OrderedDict()
_HERMES_ALIAS_LOCK = threading.Lock()


def persisted_identity_aliases(payload: object, provider: str) -> tuple[tuple[str, str], ...]:
    if provider != "hermes" or type(payload) is not list or not 1 <= len(payload) <= 2:
        raise ValueError("invalid identity aliases")
    result = []
    for pair in payload:
        if (type(pair) is not list or len(pair) != 2
                or any(type(value) is not str or member_key(provider, value) is None for value in pair)):
            raise ValueError("invalid identity alias")
        result.append(tuple(pair))
    return tuple(result)


def remember_hermes_aliases(pairs) -> None:
    with _HERMES_ALIAS_LOCK:
        for alias, session in pairs:
            previous = _HERMES_ALIASES.get(alias, session)
            _HERMES_ALIASES[alias] = session if previous == session else None
            _HERMES_ALIASES.move_to_end(alias)
        while len(_HERMES_ALIASES) > MAX_FILES:
            _HERMES_ALIASES.popitem(last=False)


def hermes_identity_aliases(raw: dict) -> tuple[tuple[str, str], ...]:
    pairs = []
    for prefix in ("child", "parent"):
        alias, session = raw.get(prefix + "_subagent_id"), raw.get(prefix + "_session_id")
        if member_key("hermes", alias) and member_key("hermes", session):
            pairs.append((alias, session))
    remember_hermes_aliases(pairs)
    return tuple(pairs)


def resolve_hermes_key(key):
    if type(key) is not str or not key.startswith(("hermes:session:", "hermes:agent:")):
        return key
    native = key.split(":", 2)[2]
    with _HERMES_ALIAS_LOCK:
        mapped = _HERMES_ALIASES.get(native, native)
        known = native in _HERMES_ALIASES
    # Agent keys here identify an explicitly named subagent alias.
    kind = "session" if known or key.startswith("hermes:session:") else "agent"
    return member_key("hermes", mapped, kind)


def hermes_parent_links(payload: dict, *, observed_at: float) -> tuple[ParentLink, ...]:
    child = (member_key("hermes", payload.get("child_session_id"))
             or member_key("hermes", payload.get("child_subagent_id")))
    hermes_identity_aliases(payload)
    child = resolve_hermes_key(child) or child
    parent = (member_key("hermes", payload.get("parent_session_id"))
              or resolve_hermes_key(member_key("hermes", payload.get("parent_subagent_id"), "agent")))
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
    if raw.get("record_kind") == "normalized" and "parent_links" in raw:
        try:
            return persisted_parent_links(raw["parent_links"], record.provider)
        except ValueError:
            return ()
    if record.provider == "cursor":
        return cursor_parent_links(raw, observed_at=record.logged_at.timestamp())
    if record.provider == "hermes":
        return hermes_parent_links(raw, observed_at=record.logged_at.timestamp())
    if record.provider == "openclaw":
        return openclaw_parent_links(raw, observed_at=record.logged_at.timestamp())
    if record.provider == "grok":
        return grok_parent_links(raw, observed_at=record.logged_at.timestamp())
    return ()


def read_hermes_links(database: Path, *, observed_at: float, active_ids=None) -> tuple[ParentLink, ...]:
    """Read identities and creation times only, never session content."""
    if active_ids is not None and not active_ids:
        return ()
    if not database.is_file():
        return ()
    try:
        with closing(sqlite3.connect(database.as_uri() + "?mode=ro", uri=True, timeout=0.1)) as connection:
            connection.execute("PRAGMA query_only=ON")
            ids = tuple(sorted(active_ids))[:MAX_FILES] if active_ids is not None else ()
            selected = " AND id IN (" + ",".join("?" for _ in ids) + ")" if ids else ""
            rows = connection.execute(
                "SELECT id, parent_session_id, started_at FROM sessions WHERE parent_session_id IS NOT NULL "
                "AND started_at >= ? AND started_at <= ?" + selected + " ORDER BY started_at DESC LIMIT ?",
                (observed_at - 86_400, observed_at + 5, *ids, MAX_FILES)).fetchall()
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


def read_opencode_links(database: Path, *, observed_at: float, active_ids=None) -> tuple[ParentLink, ...]:
    if active_ids is not None and not active_ids:
        return ()
    if not database.is_file():
        return ()
    try:
        with closing(sqlite3.connect(database.as_uri() + "?mode=ro", uri=True, timeout=0.1)) as connection:
            connection.execute("PRAGMA query_only=ON")
            ids = tuple(sorted(active_ids))[:MAX_FILES] if active_ids is not None else ()
            selected = " AND id IN (" + ",".join("?" for _ in ids) + ")" if ids else ""
            rows = connection.execute(
                "SELECT id, parent_id, time_updated FROM session WHERE parent_id IS NOT NULL "
                "AND time_updated >= ? AND time_updated <= ?" + selected + " ORDER BY time_updated DESC LIMIT ?",
                ((observed_at - 86_400) * 1000, (observed_at + 5) * 1000, *ids, MAX_FILES)).fetchall()
            return tuple(link for child, parent, stamp in rows
                         for link in opencode_parent_links({"id": child, "parentID": parent},
                             observed_at=float(stamp) / 1000 if type(stamp) in {int, float} else 0.0))
    except (OSError, sqlite3.Error):
        return ()


def openclaw_parent_links(payload: dict, *, observed_at: float, session_keys=None) -> tuple[ParentLink, ...]:
    parents = []
    if payload.get("spawnedBy"):
        parents.append(member_key("openclaw", payload["spawnedBy"],
                                  "agent" if ":subagent:" in str(payload["spawnedBy"]) else "session"))
    native = payload.get("spawnedBySessionId")
    if native and (session_keys is not None or not parents):
        parent = session_keys.get(native) if session_keys is not None and type(native) is str else native
        parents.append(member_key("openclaw", parent,
                                  "agent" if type(parent) is str and ":subagent:" in parent else "session"))
    native_child = payload.get("session_id")
    kind = "agent" if type(native_child) is str and ":subagent:" in native_child else "session"
    child = member_key("openclaw", native_child, kind)
    return tuple(link for parent in dict.fromkeys(parents)
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


class HookLineageReader:
    """Keep parsed evidence and consume only complete appended records."""
    def __init__(self):
        self._files = {}
        self._lock = threading.Lock()

    def read(self, path: Path, provider: str, *, now: float) -> tuple[ParentLink, ...]:
        with self._lock:
            try:
                stat = path.stat()
                identity = (stat.st_dev, stat.st_ino)
                key = (path, provider)
                cached = self._files.get(key)
                if cached and cached[0] == identity and stat.st_size >= cached[1]:
                    _, offset, signature, newest = cached
                    newest = dict(newest)
                    if signature == (stat.st_mtime_ns, stat.st_size):
                        return tuple(link for link in newest.values() if 0 <= now - link.observed_at <= 86_400)
                    # An equal-size rewrite is not an append.
                    if stat.st_size == signature[1]:
                        offset, newest = 0, {}
                else:
                    offset, newest = 0, {}
                with path.open("rb") as stream:
                    start = max(offset, stat.st_size - 2 * 1024 * 1024)
                    stream.seek(start)
                    if start > offset:
                        stream.readline(MAX_HEADER_BYTES + 1)
                    raw = stream.read(2 * 1024 * 1024)
                    complete = raw.rfind(b"\n") + 1
                    offset = stream.tell() - len(raw) + complete
                for line in raw[:complete].splitlines():
                    if len(line) > MAX_HEADER_BYTES:
                        continue
                    try:
                        payload = json.loads(line)
                        if (type(payload) is not dict or payload.get("record_kind") != "normalized"
                                or payload.get("provider_id") != provider):
                            continue
                        if "identity_aliases" in payload:
                            remember_hermes_aliases(persisted_identity_aliases(payload["identity_aliases"], provider))
                        if "parent_links" in payload:
                            evidence = persisted_parent_links(payload["parent_links"], provider)
                        elif provider == "grok" and payload.get("parent_work_id"):
                            evidence = _link(member_key("grok", payload.get("provider_work_id"), "agent"),
                                member_key("grok", payload.get("parent_work_id")), "grok", payload.get("occurred_at_epoch", 0))
                        else:
                            continue
                        for link in evidence:
                            if type(link.observed_at) not in {int, float} or not 0 <= now - link.observed_at <= 86_400:
                                continue
                            pair = (link.child, link.parent)
                            if pair not in newest or newest[pair].observed_at < link.observed_at:
                                newest[pair] = link
                    except (ValueError, RecursionError):
                        continue
                result = tuple(sorted((link for link in newest.values() if 0 <= now - link.observed_at <= 86_400),
                    key=lambda link: (-link.observed_at, link.child, link.parent or ""))[:MAX_FILES])
                self._files.pop(key, None)
                self._files[key] = (identity, offset, (stat.st_mtime_ns, stat.st_size),
                                    {(link.child, link.parent): link for link in result})
                if len(self._files) > 16:
                    self._files.pop(next(iter(self._files)))
                return result
            except OSError:
                return ()


_HOOK_LINEAGE_READER = HookLineageReader()


def read_hook_links(path: Path, provider: str, *, now: float) -> tuple[ParentLink, ...]:
    return _HOOK_LINEAGE_READER.read(path, provider, now=now)


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


@lru_cache(maxsize=32)
def _openclaw_entries(path: Path, identity: tuple) -> tuple:
    try:
        with path.open("rb") as stream:
            raw = stream.read(16 * 1024 * 1024 + 1)
        if len(raw) > 16 * 1024 * 1024:
            return (), {}
        rows = json.loads(raw)
        if type(rows) is not dict:
            return (), {}
        entries = []
        keys = {}
        for key, entry in rows.items():
            if type(entry) is not dict:
                continue
            stamp = entry.get("updatedAt")
            stamp = float(stamp) / 1000 if type(stamp) in {int, float} and math.isfinite(stamp) else 0.0
            metadata = {field: entry[field] for field in ("sessionId", "spawnedBy", "spawnedBySessionId") if field in entry}
            entries.append((key, metadata, stamp))
            native = entry.get("sessionId")
            if type(native) is str:
                keys[native] = key if native not in keys else None
        entries = tuple(sorted(entries, key=lambda item: item[2], reverse=True)[:MAX_FILES])
        needed = {entry.get("spawnedBySessionId") for _, entry, _ in entries
                  if type(entry.get("spawnedBySessionId")) is str}
        needed.update(entry.get("sessionId") for _, entry, _ in entries if type(entry.get("sessionId")) is str)
        return entries, {native: keys[native] for native in needed if native in keys}
    except (OSError, ValueError, RecursionError):
        return (), {}


_OPENCLAW_NATIVE_KEYS: dict[str, str | None] = {}


def read_openclaw_links(home: Path, *, active_ids=None) -> tuple[ParentLink, ...]:
    """Read changed registries on the background worker, keeping newest entries."""
    entries = []
    keys = {}
    for path in islice((home / ".openclaw/agents").glob("*/sessions/sessions.json"), 32):
        try:
            stat = path.stat()
            found, native_keys = _openclaw_entries(path, (stat.st_dev, stat.st_ino, stat.st_mtime_ns, stat.st_size))
            entries.extend(found)
            for native, key in native_keys.items():
                keys[native] = key if native not in keys else None
        except OSError:
            continue
    global _OPENCLAW_NATIVE_KEYS
    _OPENCLAW_NATIVE_KEYS = keys
    entries = sorted(entries, key=lambda item: item[2], reverse=True)[:MAX_FILES]
    return tuple(link for key, entry, stamp in entries if active_ids is None or key in active_ids
                 for link in openclaw_parent_links(dict(entry, session_id=key), observed_at=stamp, session_keys=keys))


def resolve_openclaw_key(key):
    if type(key) is not str or not key.startswith("openclaw:session:"):
        return key
    native = key.split(":", 2)[2]
    mapped = _OPENCLAW_NATIVE_KEYS.get(native, native)
    return member_key("openclaw", mapped, "agent" if type(mapped) is str and ":subagent:" in mapped else "session")


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
        # Closed bindings still prove identity after the child's run ends.
        candidates = [b for b in candidates if not b.get("status") or b["status"] not in {"archived", "deleted"}]
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
            if len(valid) > 1:
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
        child = t3_subagent_key(worker, keys, registry_providers=registry_providers)
        if child:
            parent = keys.get(parent_tid) if child_tid not in ambiguous and parent_tid not in ambiguous else None
            links.append(ParentLink(child, parent, "t3code", observed_at))
    return keys, tuple(links)


def t3_subagent_key(worker: dict, keys: dict, *, registry_providers=None) -> str | None:
    child = keys.get(worker.get("child_thread_id"))
    if child:
        return child
    native = worker.get("native_task_ref")
    if type(native) is str:
        try:
            native = json.loads(native)
        except ValueError:
            return None
    if type(native) is not dict:
        return None
    provider = _provider(native.get("driver"), worker.get("provider_instance_id"), registry_providers)
    kind = "agent" if provider in {"claude", "devin", "opencode", "grok"} else "session"
    native_id = native.get("nativeId")
    return member_key(provider, cursor_native_id(native_id) if provider == "cursor" else native_id, kind)


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
        self.home = home
        self.state_dir = state_dir
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

    def read(self, providers: frozenset[str], *, now: float, active_paths=None, active_keys=None) -> tuple[AgentStatus, ...]:
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
            changed = list(self._changed_paths(base, pattern, now=now)) if active_paths is None else []
            known = set(active_paths or ())
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
                 if (active_paths is None or path in active_paths) and any(path.is_relative_to(self.home / root) and provider in providers
                        for provider, root, _, _ in formats) for link in evidence]
        if "devin" in providers:
            links.extend(read_devin_links(self.home / ".local/share/devin/cli/sessions.db", observed_at=now))
        def native_ids(provider):
            return None if active_keys is None else {key.split(":", 2)[2] for key in active_keys
                                                     if key.startswith(provider + ":") and key.count(":") >= 2}
        if "hermes" in providers:
            links.extend(read_hermes_links(self.home / ".hermes/state.db", observed_at=now, active_ids=native_ids("hermes")))
        if "opencode" in providers:
            links.extend(read_opencode_links(self.home / ".local/share/opencode/opencode.db", observed_at=now, active_ids=native_ids("opencode")))
        if "openclaw" in providers:
            links.extend(read_openclaw_links(self.home, active_ids=native_ids("openclaw")))
        for provider in sorted(providers & {"cursor", "hermes", "openclaw", "grok"}):
            from .providers import detect_log_path
            path = self.state_dir / f"{provider}.jsonl" if self.state_dir is not None else detect_log_path(provider, self.home)
            links.extend(read_hook_links(path, provider, now=now))
            if provider == "grok":
                from .grok_children import GROK_CHILD_LINKS
                GROK_CHILD_LINKS.recover(path, now=now)
        by_child: dict[str, list[ParentLink]] = {}
        for link in links:
            if active_keys is not None and link.child not in active_keys and link.child.replace(":agent:", ":session:", 1) not in active_keys:
                continue
            by_child.setdefault(link.child, []).append(link)
        return tuple(AgentStatus(
            provider=child.split(":", 1)[0], agent_id=child,
            display_name="Worker", mode=AgentMode.UNKNOWN,
            updated_at=datetime.fromtimestamp(max(link.observed_at for link in evidence), timezone.utc),
            event_name="LineageObserved", parent_links=tuple(evidence),
        ) for child, evidence in sorted(by_child.items())[:MAX_FILES])

    def request(self, providers: frozenset[str], *, active_paths=(), active_keys=()) -> tuple[AgentStatus, ...]:
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
                updated = self.read(providers, now=time.time(), active_paths=active_paths, active_keys=active_keys)
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
    # Lineage belongs to the retained roster, not just its live activity.
    # Reading metadata must not promote a finished or stale child to a main.
    retained = (*getattr(snapshot, "statuses", ()), *getattr(snapshot, "stale_statuses", ()))
    providers = frozenset(s.provider for s in retained if s.event_name != "LineageObserved")
    reader = getattr(target, "_local_lineage_reader", None)
    if not providers:
        publish("lineage", ())
        return
    if reader is None:
        reader = LocalLineageReader(Path.home())
        target._local_lineage_reader = reader
    paths = getattr(monitor, "lineage_paths_by_session", {})
    active_paths = tuple(Path(path) for status in retained
                         for key in (status.agent_id, status.parent_agent_id)
                         if (path := paths.get(key)))
    active_keys = frozenset(s.agent_id for s in retained if s.event_name != "LineageObserved")
    rows = tuple(row for row in reader.request(providers, active_paths=active_paths, active_keys=active_keys) if row.provider in providers)
    publish("lineage", match_opencode_roster(rows, active_keys))
