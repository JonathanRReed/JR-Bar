"""Open a proven T3 host before considering a provider's own route."""
from __future__ import annotations

from dataclasses import dataclass
from urllib.parse import quote, unquote, urlsplit

from .agent_groups import resolve_agent_groups
from .models import AgentStatus

T3_BUNDLE_ID = "com.t3tools.t3code"


@dataclass(frozen=True)
class SessionOpenTarget:
    kind: str
    value: str
    reason: str

    def to_dict(self) -> dict[str, str]:
        return {"kind": self.kind, "value": self.value, "reason": self.reason}


def valid_t3_url(value: str) -> bool:
    try:
        parsed = urlsplit(value)
    except ValueError:
        return False
    parts = parsed.path.split("/")
    if (parsed.scheme != "t3code" or parsed.netloc != "threads" or parsed.query
            or parsed.fragment or len(parts) != 3 or parts[0]):
        return False
    decoded = [unquote(part) for part in parts[1:]]
    return all(part and len(part) <= 256 and part.isprintable() for part in decoded) and value == (
        f"t3code://threads/{quote(decoded[0], safe='')}/{quote(decoded[1], safe='')}"
    )


def t3_open_targets(statuses, *, now: float, resolution=None) -> dict[str, SessionOpenTarget]:
    """Use exact native bindings or accepted parent links, never an origin or cwd."""
    statuses = tuple(statuses)
    rows = {row.agent_id: row for row in statuses if isinstance(row, AgentStatus) and not row.agent_id.startswith("remote:")}
    resolution = resolution or resolve_agent_groups(rows.values(), now=now)
    parents = {link.child: link.parent for group in resolution.groups for link in group.lineage_evidence}
    targets = {}
    for identity in rows:
        cursor = identity
        seen = set()
        while cursor in rows and cursor not in seen:
            seen.add(cursor)
            row = rows[cursor]
            if row.t3_thread_id:
                url = row.t3_open_url
                if url and valid_t3_url(url) and unquote(urlsplit(url).path.split("/")[2]) == row.t3_thread_id:
                    targets[identity] = SessionOpenTarget("url", url, "t3_thread")
                else:
                    targets[identity] = SessionOpenTarget("app", T3_BUNDLE_ID, "t3_environment_missing")
                break
            cursor = parents.get(cursor)
    return targets


def controller_t3_target(controller, status) -> SessionOpenTarget | None:
    if not isinstance(status, AgentStatus) or status.agent_id.startswith("remote:"):
        return None
    snapshot = getattr(controller, "last_snapshot", None)
    rows = {row.agent_id: row for row in (
        status, *getattr(snapshot, "stale_statuses", ()), *getattr(snapshot, "statuses", ())
    ) if isinstance(row, AgentStatus)}
    collected = getattr(snapshot, "collected_at", status.updated_at)
    return t3_open_targets(rows.values(), now=collected.timestamp()).get(status.agent_id)


def controller_t3_targets_by_work(controller):
    snapshot = getattr(controller, "last_snapshot", None)
    rows = (*getattr(snapshot, "statuses", ()), *getattr(snapshot, "stale_statuses", ()))
    collected = getattr(snapshot, "collected_at", None)
    now = collected.timestamp() if collected is not None else max(
        (row.updated_at.timestamp() for row in rows), default=0)
    targets = t3_open_targets(rows, now=now)
    return {row.work_key: targets[row.agent_id] for row in rows
            if getattr(row, "work_key", None) is not None and row.agent_id in targets}


def resolve_open_navigation(controller, work_key, *, targets_by_work=None, expected_source_generation=None):
    """The operator menu and Stream Deck share the session command's host rule."""
    from .navigation_policy import NavigationCandidate, resolve_navigation
    from .provider_facts import SourceFreshness

    if targets_by_work is None:
        targets_by_work = controller_t3_targets_by_work(controller)
    target = targets_by_work.get(work_key)
    candidates = getattr(controller, "navigation_candidates_by_work_key", {}).get(work_key, ())
    if target is not None:
        state = getattr(controller, "current_operator_state", None)
        generation = int(getattr(state, "generation", 0))
        candidates = (NavigationCandidate(work_key, generation, "open:primary", target.kind, target.value,
                                          SourceFreshness.FRESH, True),)
    return resolve_navigation(work_key, "open:primary", candidates,
                              expected_source_generation=expected_source_generation)
