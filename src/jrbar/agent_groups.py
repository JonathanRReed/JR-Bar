"""Explicit delegation links shared by the daemon, lights and panel.

Adapters emit ParentLink values. They must not infer parents from cwd,
processes, titles, or copied history. Resolution uses only the current roster.
"""
from __future__ import annotations

import math
from collections import defaultdict
from collections.abc import Iterable
from dataclasses import dataclass

from .models import AgentMode, AgentStatus, ParentLink

LINEAGE_MAX_AGE_SECONDS = 86_400.0
LINEAGE_CLOCK_SKEW_SECONDS = 5.0
_RUNNING = {AgentMode.WORKING, AgentMode.TOOL_RUNNING, AgentMode.LONG_TASK_PROGRESS}


@dataclass(frozen=True)
class AgentGroup:
    id: str
    root_work_key: str
    root_provider: str
    members: tuple[str, ...]
    lineage_evidence: tuple[ParentLink, ...] = ()

    def to_dict(self) -> dict:
        return {
            "id": self.id,
            "root_work_key": self.root_work_key,
            "root_provider": self.root_provider,
            "members": list(self.members),
            "lineage_evidence": [link.to_dict() for link in self.lineage_evidence],
        }


@dataclass(frozen=True)
class AgentGroupResolution:
    groups: tuple[AgentGroup, ...]
    unlinked_workers: frozenset[str]
    rejected: tuple[tuple[str, str, str], ...] = ()


def resolve_agent_groups(
    statuses: Iterable[AgentStatus],
    links: Iterable[ParentLink] = (),
    *,
    now: float,
    max_age_seconds: float = LINEAGE_MAX_AGE_SECONDS,
) -> AgentGroupResolution:
    """Resolve provider-qualified member IDs to roots; never pick a conflicting link.

    A link with parent=None marks a known worker whose binding is unproved.
    It blocks same-provider and Devin fallback. Missing/expired links never
    turn a known worker into an independent main agent.
    """
    rows: dict[str, AgentStatus] = {}
    ambiguous = set()
    for status in statuses:
        if not getattr(status, "agent_id", None):
            continue
        previous = rows.get(status.agent_id)
        if previous and getattr(previous, "work_key", None) and getattr(status, "work_key", None) and previous.work_key != status.work_key:
            ambiguous.add(status.agent_id)
        rows[status.agent_id] = status
    by_child: dict[str, list[ParentLink]] = defaultdict(list)
    for link in (*tuple(links), *(link for row in rows.values() for link in getattr(row, "parent_links", ()))):
        if link.child in rows:
            by_child[link.child].append(link)
    own_links = set()
    devin_roots = [row.agent_id for row in rows.values()
                   if getattr(row, "provider", "") == "devin" and not getattr(row, "is_subagent", False)
                   and not getattr(row, "stale", False) and getattr(row, "mode", None) in _RUNNING]
    for row in rows.values():
        if row.agent_id in by_child or not getattr(row, "is_subagent", False):
            continue
        parent = getattr(row, "parent_agent_id", None)
        # A nested canonical worker's parent id may itself name a worker.
        if parent and parent not in rows:
            prefix, _, native_id = parent.partition(":session:")
            candidate = f"{prefix}:agent:{native_id}"
            if candidate in rows:
                parent = candidate
        if parent is None and getattr(row, "provider", "") == "devin":
            if len(devin_roots) == 1:
                parent = devin_roots[0]
        # A row owns its native relationship for as long as that row exists.
        own_links.add(row.agent_id)
        by_child[row.agent_id].append(ParentLink(
            row.agent_id, parent, getattr(row, "provider", row.agent_id.split(":", 1)[0]),
            row.updated_at.timestamp() if hasattr(row, "updated_at") else now,
        ))
    parents: dict[str, str] = {}
    rejected: dict[str, tuple[str, str]] = {}
    accepted: dict[str, tuple[ParentLink, ...]] = {}
    for child, evidence in by_child.items():
        harness = evidence[0].harness
        targets = {link.parent for link in evidence}
        if child in ambiguous or len(targets) != 1:
            rejected[child] = (harness, "ambiguous_binding")
        elif any(not math.isfinite(link.observed_at)
                 or (child not in own_links and (link.observed_at > now + LINEAGE_CLOCK_SKEW_SECONDS
                     or now - link.observed_at > max_age_seconds))
                 for link in evidence):
            rejected[child] = (harness, "stale_evidence")
        elif None in targets or next(iter(targets)) not in rows:
            rejected[child] = (harness, "missing_parent")
        elif next(iter(targets)) in ambiguous:
            rejected[child] = (harness, "ambiguous_binding")
        else:
            parents[child] = next(iter(targets))
            accepted[child] = tuple(sorted(set(evidence), key=lambda e: (e.harness, e.parent or "", e.observed_at)))
    roots: dict[str, str | None] = {}
    for member in rows:
        path = []
        path_ids = set()
        cursor = member
        while cursor not in roots:
            if cursor in path_ids:
                for cyclic in path[path.index(cursor):]:
                    rejected[cyclic] = (by_child[cyclic][0].harness, "cycle")
                root = None
                break
            path.append(cursor)
            path_ids.add(cursor)
            if cursor in rejected:
                root = None
                break
            if cursor not in parents:
                root = None if getattr(rows[cursor], "is_subagent", False) else cursor
                break
            cursor = parents[cursor]
        else:
            root = roots[cursor]
        for item in path:
            roots[item] = root
    grouped: dict[str, list[str]] = defaultdict(list)
    for member, root in roots.items():
        if root is not None:
            grouped[root].append(member)
    groups = tuple(AgentGroup(
        id=f"group:{root}", root_work_key=root, root_provider=getattr(rows[root], "provider", root.split(":", 1)[0]),
        members=tuple(sorted(members)),
        lineage_evidence=tuple(link for member in sorted(members) for link in accepted.get(member, ())),
    ) for root, members in sorted(grouped.items()))
    unlinked = frozenset(member for member, root in roots.items() if root is None)
    return AgentGroupResolution(groups, unlinked, tuple(
        (child, *rejected.get(child, (getattr(rows[child], "provider", child.split(":", 1)[0]), "unresolved_ancestor")))
        for child in sorted(unlinked)
    ))


def active_agent_groups(state) -> tuple[AgentGroup, ...]:
    """Return groups containing current work, one share per group for lights.

    Accepts a MonitorSnapshot or AttentionProjection. Asks are intentionally
    separate: callers use the existing actionable_attention/asks collection.
    No I/O. Read group.root_provider for the provider animation and colour.
    """
    if hasattr(state, "all_rows"):
        rows = tuple(state.all_rows)
        statuses = tuple((getattr(row, "source_status", None) or row) for row in rows)
        active = {row.agent_id for row in rows if row.lifecycle_mode.value == "active"}
        now = max((s.updated_at.timestamp() for s in statuses), default=0)
    else:
        statuses = (*state.statuses, *getattr(state, "stale_statuses", ()))
        active = {s.agent_id for s in state.statuses if not s.stale and s.mode in _RUNNING}
        now = state.collected_at.timestamp()
    resolution = getattr(state, "agent_group_resolution", None)
    if resolution is None:
        resolution = resolve_agent_groups(statuses, now=now)
    return tuple(g for g in resolution.groups if active.intersection(g.members))
