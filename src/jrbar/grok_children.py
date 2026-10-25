"""Which Grok session a sub-agent's session belongs to.

Grok runs a sub-agent in a child session of its own. The hooks that session
fires carry the child's own ``sessionId`` and a ``subagentType`` and name no
parent. The one place the two meet is ``SubagentStart``: it fires in the
PARENT's session and carries the child's session id as ``subagentId``. That
event is the only link Grok gives, so it is remembered here, and the child's
later events are stamped the way Claude stamps a worker's: ``agent_id`` the
child, ``session_id`` the ROOT session above it. The child then reads as a
sub-agent row under its session, its asks follow the Sub-agent asks setting
and it never counts toward keep-awake, exactly as an OpenCode child does (the
OpenCode plugin makes the same stamp at the source).

A child whose start was never observed stays unlinked. Normalized hook logs
preserve explicit parent links, and a fresh table recovers those links before
stamping a child's next event. Recovery reads a bounded log tail and keeps the
original observation time. It cannot reconstruct an event Grok never emitted.

"""

from __future__ import annotations

import re
import threading
import time
from collections import OrderedDict
from pathlib import Path
from typing import Any, Final

from .models import parse_datetime
from .providers import canonical_event_name

#: Links kept at once. A person runs a handful of sub-agents at a time; the
#: cap only stops a runaway stream from growing the table without end.
MAX_CHILD_LINKS: Final = 512
#: Nesting followed when looking for the root: a sub-agent's sub-agent, and so on.
MAX_LINK_DEPTH: Final = 8

_OPAQUE_ID: Final = re.compile(r"[A-Za-z0-9._:-]{1,128}")
_TOKEN_LIKE: Final = re.compile(r"(?:sk|token|secret|api[_-]?key)[._:-]", re.IGNORECASE)


def _opaque_id(value: object) -> str | None:
    """An id Grok minted, in a form that is safe to carry as an identity."""
    if type(value) is not str or _OPAQUE_ID.fullmatch(value) is None:
        return None
    return None if _TOKEN_LIKE.match(value) else value


def _first_id(line: dict[str, Any], *keys: str) -> str | None:
    for key in keys:
        value = _opaque_id(line.get(key))
        if value is not None:
            return value
    return None


class GrokChildLinks:
    """Child session id -> the session that spawned it, bounded and thread-safe."""

    def __init__(self, limit: int = MAX_CHILD_LINKS) -> None:
        if type(limit) is not int or limit < 1:
            raise ValueError("invalid link limit")
        self._limit = limit
        self._parents: OrderedDict[str, str] = OrderedDict()
        self._observed: dict[str, float] = {}
        self._recovered: dict[Path, tuple[int, int]] = {}
        self._lock = threading.Lock()

    def __len__(self) -> int:
        with self._lock:
            return len(self._parents)

    def clear(self) -> None:
        with self._lock:
            self._parents.clear()
            self._observed.clear()
            self._recovered.clear()

    def parent_of(self, session_id: str) -> str | None:
        with self._lock:
            return self._parents.get(session_id)

    def observed_at(self, session_id: str) -> float:
        with self._lock:
            return self._observed.get(session_id, 0.0)

    def recover(self, path: Path, *, now: float) -> None:
        from .lineage_adapters import read_hook_links

        try:
            stat = path.stat()
        except OSError:
            return
        signature = (stat.st_mtime_ns, stat.st_size)
        with self._lock:
            if self._recovered.get(path) == signature:
                return
            if len(self._recovered) >= 16:
                self._recovered.clear()
            self._recovered[path] = signature
        candidates = {}
        for link in read_hook_links(path, "grok", now=now):
            if link.child.startswith("grok:agent:") and link.parent:
                child = link.child.split(":", 2)[2]
                parent = link.parent.split(":", 2)[2]
                candidates.setdefault(child, {})[parent] = link.observed_at
        for child, parents in candidates.items():
            if len(parents) == 1 and self.parent_of(child) is None:
                parent = next(iter(parents))
                self.remember(child, parent, observed_at=parents[parent])

    def remember(self, child: str, parent: str, *, observed_at: float | None = None) -> bool:
        """Record that ``parent`` spawned ``child``. False when the link is
        refused: an id that is not an opaque id, a session that is its own
        parent, a link that would close a loop, or one that would nest deeper
        than ``MAX_LINK_DEPTH``."""
        if _opaque_id(child) is None or _opaque_id(parent) is None or child == parent:
            return False
        with self._lock:
            above = self._ancestors(parent)
            if above is None or child in above or len(above) + 1 > MAX_LINK_DEPTH:
                return False
            # Re-inserting moves the link to the newest end; ``root_of`` does
            # the same on every event, so a child that keeps sending events is
            # never the one evicted.
            self._parents.pop(child, None)
            self._parents[child] = parent
            self._observed[child] = time.time() if observed_at is None else observed_at
            while len(self._parents) > self._limit:
                evicted, _ = self._parents.popitem(last=False)
                self._observed.pop(evicted, None)
        return True

    def _ancestors(self, session_id: str) -> list[str] | None:
        """The sessions above ``session_id``, nearest first; ``None`` when the
        chain loops or runs past ``MAX_LINK_DEPTH``. Call with the lock held."""
        chain: list[str] = []
        seen = {session_id}
        current = session_id
        while True:
            parent = self._parents.get(current)
            if parent is None:
                return chain
            if parent in seen or len(chain) >= MAX_LINK_DEPTH:
                return None
            chain.append(parent)
            seen.add(parent)
            current = parent

    def root_of(self, session_id: str) -> str | None:
        """The root session above ``session_id``, or ``None`` when it is not a
        known child (a main session, or a child whose start was never seen) or
        the chain is a loop or deeper than the cap."""
        with self._lock:
            above = self._ancestors(session_id)
            if above and session_id in self._parents:
                # A child that keeps sending events stays the newest link, so
                # the busiest children are the last to be evicted.
                self._parents.move_to_end(session_id)
        return above[-1] if above else None


#: The daemon's table: every Grok hook it takes goes through this one.
GROK_CHILD_LINKS: Final = GrokChildLinks()


def stamp_child_identity(line: dict[str, Any], links: GrokChildLinks) -> dict[str, Any]:
    """``line`` with a Grok child session's identity stamped as a worker's.

    ``SubagentStart`` (the parent's session, naming the child as
    ``subagentId``) is remembered and stamped; any later event from a session
    the table knows as a child gets ``agent_id`` the child and ``session_id``
    the root. Every other line comes back untouched. The line is copied, never
    changed in place.
    """
    session = _first_id(line, "session_id", "sessionId")
    if session is None:
        return line
    event = canonical_event_name(line.get("hook_event_name") or line.get("hookEventName"))
    child = session
    if event == "SubagentStart":
        spawned = _first_id(line, "subagent_id", "subagentId")
        stamp = parse_datetime(line.get("logged_at") or line.get("timestamp")).timestamp()
        if spawned is None or not links.remember(spawned, session, observed_at=stamp):
            return line
        child = spawned
    root = links.root_of(child)
    if root is None:
        return line
    stamped = dict(line)
    stamped["agent_id"] = child
    stamped["session_id"] = root
    parent = links.parent_of(child)
    stamped["parent_session_id"] = parent
    stamped["lineage_observed_at"] = links.observed_at(child)
    if parent and links.root_of(parent):
        stamped["parent_agent_id"] = parent
    if "sessionId" in stamped:
        stamped["sessionId"] = root
    return stamped


__all__ = [
    "GROK_CHILD_LINKS",
    "MAX_CHILD_LINKS",
    "MAX_LINK_DEPTH",
    "GrokChildLinks",
    "stamp_child_identity",
]
