"""The independent agent roster — ``list_roster``'s pure half.

``state.sessions`` answers "what should the panel show". This answers
"what does the daemon know" — a question panel aging must not be allowed
to corrupt: ``filter_visible_sessions`` drops a finished main after
twenty unacknowledged minutes and a quiet live one after ten, drops a
worker whose parent left the list, and drops anything acknowledged.
Those are *panel* decisions. An audit, a fish's existence, an unresolved
request's record cannot depend on them.

So the roster is the same projection without the filter: every status the
collector retains — ``snapshot.statuses`` and ``snapshot.stale_statuses``
— projected through the identical ``session_document``, then marked with
what the panel *would* do (``visibility``) rather than done to. Rows keep
their provider-namespaced ids, parent links and native session ids;
nothing merges by title or path (``agent_id`` is already source-bound:
``provider:session:<work id>`` / ``provider:agent:<work id>``).

Each row also carries the separated axes from ``activity_model`` —
``outcome``, ``review``, ``freshness`` beside the row's existing
``lifecycle`` and ``mode`` (activity) — so a consumer never has to fold
"ended without a report" and "failed" into one colour.

Deeper-than-collector history is the activity ledger's job
(``list_history``); ``coverage`` says so rather than pretending the
roster remembers more than it does.
"""

from __future__ import annotations

from collections.abc import Collection, Iterable, Mapping
from typing import Any, Final

from .activity_model import RECORD_SCHEMA_VERSION, row_has_open_ask, session_axes
from .completion_visibility import (
    FINISHED_LIFECYCLES,
    HIDDEN,
    session_visibility,
)

#: The scopes ``list_roster`` accepts. Each is a named cut over the full
#: retained set; ``all`` is the unscoped answer.
ROSTER_SCOPES: Final = ("all", "live", "workers", "attention", "finished", "hidden")

#: Bound on rows per answer — the roster is a query surface, not a dump.
ROSTER_DEFAULT_LIMIT: Final = 500
ROSTER_MAX_LIMIT: Final = 2000


def roster_rows(
    projected: Iterable[Mapping[str, Any]],
    *,
    ask_ids: Collection[str] = (),
    acknowledged_at_by_id: Mapping[str, float] | None = None,
    now: float,
    live_visible_seconds: float | None = None,
    completed_visible_seconds: float | None = None,
) -> list[dict[str, Any]]:
    """The unfiltered roster: one canonical record per retained session.

    ``projected`` is ``project_session_rows``' output — the same rows
    ``state.sessions`` filters. Each record gains:

    * ``schema`` -- ``RECORD_SCHEMA_VERSION``;
    * ``axes``   -- ``session_axes`` (outcome/review/freshness);
    * ``visibility`` -- the verdict ``session_visibility`` would give
      the panel (``live``/``completion``/``hidden``), so consumers can
      see panel aging as a fact about the row, not a removal of it;
    * ``pinned`` -- the row carries a live ask.

    Order is the projection's own (collector order, mains before workers
    resolved by parent labels) — stable for a fixed snapshot.
    """
    pinned = {str(identifier) for identifier in ask_ids}
    acknowledged = acknowledged_at_by_id or {}
    kwargs: dict[str, Any] = {}
    if live_visible_seconds is not None:
        kwargs["live_visible_seconds"] = live_visible_seconds
    if completed_visible_seconds is not None:
        kwargs["completed_visible_seconds"] = completed_visible_seconds
    rows: list[dict[str, Any]] = []
    for row in projected:
        agent_id = str(row.get("id") or "")
        record = dict(row)
        record["schema"] = RECORD_SCHEMA_VERSION
        record["pinned"] = agent_id in pinned
        record["axes"] = session_axes(
            lifecycle=row.get("lifecycle"),
            stale=row.get("stale"),
            updated_at=row.get("updated_at"),
            acknowledged=agent_id in acknowledged
            and _acknowledged(row, acknowledged[agent_id]),
        )
        record["visibility"] = session_visibility(
            row,
            now=now,
            acknowledged_at_by_id=acknowledged,
            pinned_ids=pinned,
            **kwargs,
        )
        rows.append(record)
    return rows


def _acknowledged(row: Mapping[str, Any], acknowledged_at: float) -> bool:
    """``acknowledged_at`` covers the row's own clock — an ack before the
    row last spoke acknowledges nothing."""
    updated_at = row.get("updated_at")
    if type(updated_at) not in {int, float}:
        return True
    return float(acknowledged_at) >= float(updated_at) - 0.001


def _in_scope(row: Mapping[str, Any], scope: str) -> bool:
    if scope == "all":
        return True
    if scope == "live":
        return str(row.get("lifecycle") or "active") not in FINISHED_LIFECYCLES
    if scope == "workers":
        return str(row.get("kind") or "main") == "worker"
    if scope == "attention":
        return bool(row.get("pinned")) or row_has_open_ask(row)
    if scope == "finished":
        return str(row.get("lifecycle") or "") in FINISHED_LIFECYCLES
    if scope == "hidden":
        return row.get("visibility") == HIDDEN
    return False


def scope_rows(
    rows: Iterable[Mapping[str, Any]],
    *,
    scope: str = "all",
    provider: str | None = None,
    parent: str | None = None,
    since: float | None = None,
    limit: int = ROSTER_DEFAULT_LIMIT,
) -> list[dict[str, Any]]:
    """Apply the scope and the value filters. ``since`` cuts on the row's
    own ``updated_at``; ``parent`` lists one session's workers. Order is
    preserved — a scoped answer is a cut, never a re-sort."""
    scope = scope if scope in ROSTER_SCOPES else "all"
    limit = max(0, min(int(limit), ROSTER_MAX_LIMIT))
    out: list[dict[str, Any]] = []
    for row in rows:
        if not _in_scope(row, scope):
            continue
        if provider is not None and str(row.get("provider") or "") != provider:
            continue
        if parent is not None and str(row.get("parent") or "") != parent:
            continue
        if since is not None:
            updated_at = row.get("updated_at")
            if type(updated_at) not in {int, float} or float(updated_at) < float(since):
                continue
        out.append(dict(row))
        if len(out) >= limit:
            break
    return out


def roster_counts(rows: Iterable[Mapping[str, Any]]) -> dict[str, int]:
    """Totals over the FULL retained set — computed before scoping, so a
    scoped answer still reports what exists."""
    rows = list(rows)
    return {
        "total": len(rows),
        "workers": sum(1 for row in rows if str(row.get("kind") or "main") == "worker"),
        "attention": sum(1 for row in rows if row.get("pinned") or row_has_open_ask(row)),
        "live": sum(
            1
            for row in rows
            if str(row.get("lifecycle") or "active") not in FINISHED_LIFECYCLES
        ),
        "finished": sum(
            1 for row in rows if str(row.get("lifecycle") or "") in FINISHED_LIFECYCLES
        ),
        "hidden_from_panel": sum(1 for row in rows if row.get("visibility") == HIDDEN),
    }


def build_roster_document(
    rows: Iterable[Mapping[str, Any]],
    *,
    now: float,
    scope: str = "all",
    provider: str | None = None,
    parent: str | None = None,
    since: float | None = None,
    limit: int = ROSTER_DEFAULT_LIMIT,
) -> dict[str, Any]:
    """The ``list_roster`` answer. ``counts`` describes everything the
    daemon retains; ``sessions`` is the scoped cut; ``coverage`` is the
    honest bound — the collector's current+stale retention, with deeper
    history in ``list_history`` and none of it resurrected here."""
    all_rows = [dict(row) for row in rows]
    scope = scope if scope in ROSTER_SCOPES else "all"
    selected = scope_rows(
        all_rows, scope=scope, provider=provider, parent=parent, since=since, limit=limit
    )
    return {
        "t": "roster",
        "schema": RECORD_SCHEMA_VERSION,
        "now": float(now),
        "scope": scope,
        "filters": {
            "provider": provider,
            "parent": parent,
            "since": since,
            "limit": limit,
        },
        "sessions": selected,
        "counts": {**roster_counts(all_rows), "listed": len(selected)},
        "coverage": {
            "source": "collector_snapshot",
            "history": "list_history",
            "note": "Rows are the collector's retained statuses; panel "
            "aging never removes one. Older events are activity-ledger "
            "entries via list_history, not session records.",
        },
    }


__all__ = [
    "ROSTER_DEFAULT_LIMIT",
    "ROSTER_MAX_LIMIT",
    "ROSTER_SCOPES",
    "build_roster_document",
    "roster_counts",
    "roster_rows",
    "scope_rows",
]
