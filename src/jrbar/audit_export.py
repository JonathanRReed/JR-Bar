"""Redacted audit export: the roster + activity ledger as a portable
document, with the gaps named instead of papered over (spec S7.4/T36).

The export is an application audit, not a compliance record: it carries
only the already-projected fields (the same rows the Overview and History
surfaces show), never raw provider payloads, and it collapses the home
prefix and redacts secret-shaped strings so a bundle pasted into an
issue carries no credentials.
"""

from __future__ import annotations

import re
from typing import Any, Final

AUDIT_EXPORT_SCHEMA: Final = 1

# A token-shaped run: long enough that a real word or phrase cannot match
# (path segments, identifiers and prose all contain separators/spaces well
# inside this bound), so the redaction never eats a sentence.
_SECRET_RUN = re.compile(r"[A-Za-z0-9_\-+/=.]{24,}")
_REDACTED = "[redacted]"


def _redact_text(value: object, *, home: str) -> object:
    """Home-prefix collapse plus secret-run redaction on any string."""
    if not isinstance(value, str) or not value:
        return value
    if home and (value == home or value.startswith(home + "/")):
        value = "~" + value[len(home):]
    return _SECRET_RUN.sub(_REDACTED, value)


def _redact(value: object, *, home: str) -> object:
    if isinstance(value, dict):
        return {key: _redact(item, home=home) for key, item in value.items()}
    if isinstance(value, (list, tuple)):
        return [_redact(item, home=home) for item in value]
    return _redact_text(value, home=home)


#: Session-row fields that may hold a path or free text and therefore get
#: the redactor; ids, providers, modes, counts and axes are facts, not
#: prose, and pass through.
def _export_session_row(row: dict[str, Any], *, home: str) -> dict[str, Any]:
    keep = (
        "id", "provider", "kind", "parent", "mode", "lifecycle", "next_actor",
        "since", "updated_at", "stale", "remote", "workers", "pinned",
        "visibility", "axes",
    )
    out = {key: row.get(key) for key in keep if key in row}
    # Text fields are kept but redacted; the export still reads.
    for text_key in ("label", "cwd", "short_id", "event", "tool", "message"):
        if text_key in row:
            out[text_key] = _redact_text(row.get(text_key), home=home)
    ask = row.get("ask")
    if isinstance(ask, dict):
        out["ask"] = {
            "kind": ask.get("kind"),
            "opened_at": ask.get("opened_at"),
            "summary": _redact_text(ask.get("summary"), home=home),
        }
    return out


def _export_history_row(row: dict[str, Any], *, home: str) -> dict[str, Any]:
    keep = ("at", "kind", "provider", "session", "duration", "unseen")
    out = {key: row.get(key) for key in keep if key in row}
    for text_key in ("label", "detail"):
        if text_key in row:
            out[text_key] = _redact_text(row.get(text_key), home=home)
    return out


def audit_export_document(
    *,
    roster: dict[str, Any],
    history_rows: list[dict[str, Any]],
    pricing: dict[str, Any] | None = None,
    gaps: list[str] | None = None,
    scope: str = "all",
    since: float | None = None,
    generated_at: float,
    core_version: str,
    home: str = "",
) -> dict[str, Any]:
    """The audit document: schema, scope, the redacted rows, the named gaps.

    ``pricing`` is the usage document's own coverage block so an export
    never presents an estimated or unpriced total as a bill.
    """
    sessions = [
        _export_session_row(row, home=home)
        for row in roster.get("sessions") or []
        if isinstance(row, dict)
    ]
    activity = [
        _export_history_row(row, home=home)
        for row in history_rows
        if isinstance(row, dict)
    ]
    document: dict[str, Any] = {
        "t": "audit_export",
        "schema": AUDIT_EXPORT_SCHEMA,
        "core_version": core_version,
        "generated_at": float(generated_at),
        "scope": {"roster": scope, "since": since},
        "counts": roster.get("counts") or {},
        "coverage": roster.get("coverage") or {},
        "gaps": [str(gap) for gap in (gaps or [])],
        "sessions": sessions,
        "activity": activity,
        "redaction": {
            "home_prefix": "~",
            "secret_runs": _REDACTED,
            "note": "Projected fields only; no raw provider payloads.",
        },
        "audit_only": "An application audit, not a compliance or tamper-proof record.",
    }
    if pricing is not None:
        document["pricing"] = pricing
    return document


def audit_export_markdown(document: dict[str, Any]) -> str:
    """The human-readable half of the bundle: same facts, same gaps."""
    lines = [
        "# JR-Bar audit export",
        "",
        f"- Generated: {document.get('generated_at')}",
        f"- Core: {document.get('core_version')} · schema {document.get('schema')}",
        f"- Scope: {document.get('scope')}",
        f"- {document.get('audit_only')}",
        "",
    ]
    gaps = document.get("gaps") or []
    if gaps:
        lines.append("## Gaps")
        lines += [f"- {gap}" for gap in gaps]
        lines.append("")
    pricing = document.get("pricing")
    if isinstance(pricing, dict):
        lines.append("## Pricing coverage")
        if "range" in pricing:
            lines.append(f"- range: {pricing['range']}")
        providers = pricing.get("providers")
        if isinstance(providers, dict):
            for provider, row in sorted(providers.items()):
                if not isinstance(row, dict):
                    continue
                parts = [
                    f"{key}={row[key]}"
                    for key in ("records", "estimated_records", "unpriced_records")
                    if row.get(key)
                ]
                if row.get("unpriced_models"):
                    parts.append(
                        "unpriced_models=" + ",".join(str(m) for m in row["unpriced_models"])
                    )
                if row.get("pending"):
                    parts.append("pending")
                lines.append(f"- {provider}: {', '.join(parts) or 'no records'}")
        else:
            for key in ("records", "estimated_records", "unpriced_records"):
                if key in pricing:
                    lines.append(f"- {key}: {pricing[key]}")
        lines.append("")
    lines.append("## Sessions")
    counts = document.get("counts") or {}
    if counts:
        lines.append(
            f"{counts.get('total', 0)} retained "
            f"({counts.get('live', 0)} live, {counts.get('attention', 0)} attention, "
            f"{counts.get('hidden_from_panel', 0)} hidden from panel)"
        )
        lines.append("")
    for row in document.get("sessions") or []:
        axes = row.get("axes") or {}
        lines.append(
            f"- `{row.get('id')}` {row.get('provider')}/{row.get('kind')} "
            f"{row.get('label') or ''} — {row.get('lifecycle') or row.get('mode') or '?'}; "
            f"outcome {axes.get('outcome', '?')}, review {axes.get('review', '?')}, "
            f"freshness {axes.get('freshness', '?')}"
            + (f" · ask: {row['ask'].get('summary')}" if row.get("ask") else "")
        )
    lines.append("")
    activity = document.get("activity") or []
    if activity:
        lines.append("## Activity")
        for row in activity:
            lines.append(
                f"- {row.get('at')} {row.get('kind')} `{row.get('session') or '-'}` "
                f"{row.get('label') or ''}"
            )
        lines.append("")
    return "\n".join(lines)
