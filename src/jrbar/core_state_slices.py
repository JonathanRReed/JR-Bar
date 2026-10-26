"""State slices compared against the last transmitted state, after coalescing."""
from __future__ import annotations

import json
from typing import Any

ENVELOPE = frozenset({"t", "v", "generation", "now"})


def object_changes(previous, current, path=(), *, root):
    from .core_runtime import _VOLATILE_DOC_PATHS, _path_is_volatile

    edits = []
    for key in previous.keys() - current.keys():
        edits.append({"path": [*path, key], "remove": True})
    for key, value in current.items():
        if _path_is_volatile((root, *path, key), _VOLATILE_DOC_PATHS["state"]):
            continue
        before = previous.get(key)
        if key in previous and type(before) is type(value) and before == value:
            continue
        location = (*path, key)
        if isinstance(before, dict) and isinstance(value, dict):
            edits.extend(object_changes(before, value, location, root=root))
        else:
            edits.append({"path": list(location), "value": value})
    return edits


def session_changes(previous, current):
    if not isinstance(previous, list) or not isinstance(current, list):
        return None
    if any(not isinstance(row, dict) or not isinstance(row.get("id"), str) for row in [*previous, *current]):
        return None
    old = {row["id"]: row for row in previous}
    new = {row["id"]: row for row in current}
    if len(old) != len(previous) or len(new) != len(current):
        return None
    changes = {}
    for identity, row in new.items():
        if identity not in old:
            changes[identity] = row
            continue
        before = old[identity]
        fields = {key: row.get(key) for key in row.keys() | before.keys()
                  if key not in row or key not in before or row[key] != before[key]}
        if fields:
            changes[identity] = fields
    return {"changes": changes, "removed": sorted(old.keys() - new.keys()),
            "order": [row["id"] for row in current]}


def without_write_health(state: dict) -> dict:
    if not isinstance(state.get("devices", []), list) or any(not isinstance(row, dict) for row in state.get("devices", [])):
        return state
    return {**state, "devices": [
        {key: value for key, value in device.items() if key != "write_health"}
        for device in state.get("devices", [])
    ]}


class StateSlices:
    def __init__(self):
        self.previous: dict[str, Any] | None = None
        self.generations: dict[str, int] = {}

    def delta(self, state: dict) -> dict:
        from .core_runtime import doc_significant_equal

        current = without_write_health(state)
        previous = self.previous or {}
        slices = {}
        for key in (current.keys() | previous.keys()) - ENVELOPE:
            value = current.get(key)
            if key in previous and key in current and doc_significant_equal("state", {key: previous[key]}, {key: value}):
                continue
            generation = self.generations.get(key, 0) + 1
            self.generations[key] = generation
            changes = session_changes(previous.get(key), value) if key == "sessions" else None
            if changes is not None:
                payload = changes
            elif isinstance(previous.get(key), dict) and isinstance(value, dict):
                patch = {"patch": object_changes(previous[key], value, root=key)}
                complete = {"value": value}
                payload = patch if len(json.dumps(patch)) < len(json.dumps(complete)) else complete
            else:
                payload = {"value": value}
            slices[key] = {"generation": generation, **payload}
        self.previous = current
        return {"t": "state_delta", "v": 1, "generation": state.get("generation", 0),
                "now": state.get("now"), "slices": slices}
