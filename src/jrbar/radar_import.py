"""Bounded Agentic Radar report importer (S7.5/T38).

An imported report is DATA: a JSON workflow graph (agents, tools,
services, artifacts and the edges between them) produced by an external
static analyzer. Importing never executes the repository, its tools,
or its tests — this module parses a file, bounds it, normalizes the
graph, and stores it under the state dir.

Every imported edge is ``evidence: "static"`` — statically detected.
The importer cannot assert observed-in-run, configured, or inferred
edges; those classes belong to live monitoring. A static edge is a
label in the inspector, never a trigger: it must not feed fish, bump
tool counts, or widen anything.

The parser is deliberately shape-tolerant because report schemas vary
by analyzer version — nodes under ``nodes``/``entities``, edges under
``edges``/``relationships``/``links`` — but hard bounds apply:
4 MB, 1000 nodes, 2000 edges, and at least one node or the file is
not a report.
"""

from __future__ import annotations

import hashlib
import json
import re
import time
from pathlib import Path
from typing import Any, Final

from .state_paths import default_state_dir

RADAR_MAX_BYTES: Final = 4 * 1024 * 1024
RADAR_MAX_NODES: Final = 1000
RADAR_MAX_EDGES: Final = 2000
RADAR_MAX_NAME: Final = 200
REPORT_INDEX: Final = "index.json"

_NODE_LIST_KEYS: Final = ("nodes", "entities", "vertices")
_EDGE_LIST_KEYS: Final = ("edges", "relationships", "links")
_NODE_KINDS: Final = {"agent", "tool", "service", "artifact", "model", "other"}


class RadarImportError(ValueError):
    """A refused import; ``code`` is a wire-safe reason."""

    def __init__(self, code: str, message: str):
        super().__init__(message)
        self.code = code


def _string(value: object, *, bound: int = RADAR_MAX_NAME) -> str | None:
    if isinstance(value, str) and value.strip():
        return value.strip()[:bound]
    return None


def _node_kind(value: object) -> str:
    text = str(value or "").strip().lower()
    for kind in _NODE_KINDS:
        if kind in text:
            return kind
    return "other"


def _node_id(raw: Any, index: int) -> str | None:
    if isinstance(raw, str):
        return _string(raw)
    if not isinstance(raw, dict):
        return None
    for key in ("id", "name", "label", "key"):
        found = _string(raw.get(key))
        if found:
            return found
    return f"node-{index}" if raw else None


def _edge_endpoints(raw: Any) -> tuple[str | None, str | None]:
    if not isinstance(raw, dict):
        return None, None
    source = None
    target = None
    for key in ("source", "from", "src", "upstream"):
        source = source or _string(raw.get(key))
    for key in ("target", "to", "dst", "downstream"):
        target = target or _string(raw.get(key))
    return source, target


def validate_radar_document(raw: Any) -> dict[str, Any]:
    """Normalized `{meta, nodes, edges}` or a ``RadarImportError``.

    Nodes are ``{id, name, kind}`` (kind bucketed to agent/tool/
    service/artifact/model/other); edges are ``{source, target, kind?,
    evidence:"static"}``. Anything beyond the caps refuses the import —
    a truncated graph is a misleading graph.
    """
    if not isinstance(raw, dict):
        raise RadarImportError("invalid_report", "top level is not an object")

    raw_nodes: Any = None
    for key in _NODE_LIST_KEYS:
        if isinstance(raw.get(key), list):
            raw_nodes = raw[key]
            break
    if not raw_nodes:
        raise RadarImportError(
            "invalid_report", "no node list (nodes/entities/vertices) found"
        )
    if len(raw_nodes) > RADAR_MAX_NODES:
        raise RadarImportError(
            "too_large", f"{len(raw_nodes)} nodes exceeds the {RADAR_MAX_NODES} cap"
        )

    nodes: list[dict[str, Any]] = []
    for index, item in enumerate(raw_nodes):
        node_id = _node_id(item, index)
        if node_id is None:
            continue
        node = {"id": node_id, "name": node_id, "kind": "other"}
        if isinstance(item, dict):
            node["name"] = _string(item.get("name") or item.get("label")) or node_id
            node["kind"] = _node_kind(item.get("type") or item.get("kind"))
        nodes.append(node)

    raw_edges: list[Any] = []
    for key in _EDGE_LIST_KEYS:
        if isinstance(raw.get(key), list):
            raw_edges = raw[key]
            break
    if len(raw_edges) > RADAR_MAX_EDGES:
        raise RadarImportError(
            "too_large", f"{len(raw_edges)} edges exceeds the {RADAR_MAX_EDGES} cap"
        )
    known = {node["id"] for node in nodes} | {node["name"] for node in nodes}
    edges: list[dict[str, Any]] = []
    for item in raw_edges:
        source, target = _edge_endpoints(item)
        if not source or not target:
            continue
        edges.append(
            {
                "source": source,
                "target": target,
                "kind": _string(item.get("kind") or item.get("type")),
                # Imported topology is statically detected — never an
                # observed, configured, or inferred claim (T38).
                "evidence": "static",
                "dangling": source not in known or target not in known,
            }
        )

    meta = {
        "analyzer": _string(raw.get("analyzer") or raw.get("tool")) or "unknown",
        "analyzer_version": _string(
            raw.get("analyzer_version") or raw.get("version")
        ),
        "scanned_at": _string(
            raw.get("scanned_at") or raw.get("generated_at") or raw.get("timestamp")
        ),
        "repository": _string(
            raw.get("repository") or raw.get("repo") or raw.get("project")
        ),
        "revision": _string(raw.get("revision") or raw.get("commit")),
        "scope": _string(raw.get("scope") or raw.get("root")),
    }
    return {"meta": meta, "nodes": nodes, "edges": edges}


def radar_store_dir(state_dir: Path | None = None) -> Path:
    return (state_dir or default_state_dir()) / "radar"


def _report_id(document: dict[str, Any], source: str) -> str:
    digest = hashlib.sha256(
        json.dumps(document, sort_keys=True).encode("utf-8")
    ).hexdigest()[:12]
    base = document["meta"].get("repository") or Path(source).stem or "report"
    slug = re.sub(r"[^A-Za-z0-9._-]+", "-", base).strip("-.")[:40] or "report"
    return f"{slug}-{digest}"


def import_radar_report(
    path: Path,
    *,
    state_dir: Path | None = None,
) -> dict[str, Any]:
    """Read, bound, normalize, and store a report. Returns the stored
    record's summary. Raises ``RadarImportError`` on any refusal."""
    path = Path(path).expanduser()
    try:
        size = path.stat().st_size
    except OSError:
        raise RadarImportError("not_found", f"no file at {path}") from None
    if size > RADAR_MAX_BYTES:
        raise RadarImportError(
            "too_large", f"{size} bytes exceeds the {RADAR_MAX_BYTES} cap"
        )
    try:
        raw = json.loads(path.read_text(encoding="utf-8", errors="replace"))
    except (OSError, json.JSONDecodeError) as error:
        raise RadarImportError("invalid_report", f"unreadable JSON: {error}") from error

    document = validate_radar_document(raw)
    document["meta"]["imported_at"] = time.time()
    document["meta"]["source_file"] = path.name
    report_id = _report_id(document, str(path))

    store = radar_store_dir(state_dir)
    store.mkdir(parents=True, exist_ok=True)
    record = {"id": report_id, **document}
    (store / f"{report_id}.json").write_text(
        json.dumps(record, indent=1, sort_keys=True) + "\n", encoding="utf-8"
    )

    index = _load_index(store)
    index = [entry for entry in index if entry.get("id") != report_id]
    index.append(_summary(record))
    index.sort(key=lambda entry: entry.get("imported_at") or 0, reverse=True)
    (store / REPORT_INDEX).write_text(
        json.dumps(index, indent=1, sort_keys=True) + "\n", encoding="utf-8"
    )
    return _summary(record)


def _summary(record: dict[str, Any]) -> dict[str, Any]:
    meta = record.get("meta") or {}
    return {
        "id": record.get("id"),
        "analyzer": meta.get("analyzer"),
        "analyzer_version": meta.get("analyzer_version"),
        "scanned_at": meta.get("scanned_at"),
        "repository": meta.get("repository"),
        "revision": meta.get("revision"),
        "scope": meta.get("scope"),
        "imported_at": meta.get("imported_at"),
        "source_file": meta.get("source_file"),
        "nodes": len(record.get("nodes") or ()),
        "edges": len(record.get("edges") or ()),
    }


def _load_index(store: Path) -> list[dict[str, Any]]:
    try:
        raw = json.loads((store / REPORT_INDEX).read_text(encoding="utf-8"))
    except (OSError, json.JSONDecodeError):
        return []
    return raw if isinstance(raw, list) else []


def list_radar_reports(*, state_dir: Path | None = None) -> list[dict[str, Any]]:
    return _load_index(radar_store_dir(state_dir))


def load_radar_report(
    report_id: str,
    *,
    state_dir: Path | None = None,
) -> dict[str, Any] | None:
    """The stored record for ``report_id`` — ids are path-cleaned so the
    lookup cannot walk out of the store."""
    clean = re.sub(r"[^A-Za-z0-9._-]+", "", report_id)
    if not clean or clean != report_id or ".." in clean:
        return None
    try:
        raw = json.loads(
            (radar_store_dir(state_dir) / f"{clean}.json").read_text(
                encoding="utf-8"
            )
        )
    except (OSError, json.JSONDecodeError):
        return None
    return raw if isinstance(raw, dict) else None
