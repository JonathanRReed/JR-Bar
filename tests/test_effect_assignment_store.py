from __future__ import annotations

from jrbar.effect_assignment_store import (
    AssignmentRestoreHealth,
    EffectAssignmentCache,
    EffectAssignmentContext,
    EffectAssignmentDocument,
    EffectAssignmentRecord,
    load_effect_assignments,
    resolve_effect_assignment,
    save_effect_assignments,
)
from jrbar.effect_studio import AssignmentScope
from jrbar.scenes import Scene
from jrbar.semantic_effect_router import SemanticEventKind


def _record(
    effect_id: str,
    scope: AssignmentScope,
    target_id: str | None,
) -> EffectAssignmentRecord:
    return EffectAssignmentRecord.create(effect_id, scope, target_id)


def test_owner_private_assignment_store_round_trips_typed_records(tmp_path) -> None:
    path = tmp_path / "effect-assignments.json"
    document = EffectAssignmentDocument(
        (
            _record("pulse", AssignmentScope.PROVIDER, "claude"),
            _record("notification", AssignmentScope.SCENE, Scene.NIGHT.value),
        )
    )

    save_effect_assignments(path, document)
    restored = load_effect_assignments(path)

    assert restored.health is AssignmentRestoreHealth.HEALTHY
    assert restored.document == document
    assert path.stat().st_mode & 0o077 == 0


def test_assignment_resolution_uses_most_specific_matching_scope__and_2_more() -> None:
    # --- scenario: assignment_resolution_uses_most_specific_matching_scope
    document = EffectAssignmentDocument(
        (
            _record("none", AssignmentScope.GLOBAL, None),
            _record("pulse", AssignmentScope.SEMANTIC, "notification"),
            _record("rainbow", AssignmentScope.PROVIDER, "claude"),
            _record(
                "notification",
                AssignmentScope.PROVIDER_INSTANCE,
                "claude:work",
            ),
            _record("pulse", AssignmentScope.PROJECT, "jr-bar"),
            _record("rainbow", AssignmentScope.DEVICE, "device-1"),
            _record("notification", AssignmentScope.SCENE, Scene.NIGHT.value),
        )
    )
    base = dict(
        semantic=SemanticEventKind.NOTIFICATION,
        scene=Scene.NIGHT,
        provider_id="claude",
        provider_instance_id="claude:work",
        project_id="jr-bar",
    )

    assert resolve_effect_assignment(
        document,
        EffectAssignmentContext(**base, device_id="device-1"),
    ).effect_id == "rainbow"
    assert resolve_effect_assignment(
        document,
        EffectAssignmentContext(**base),
    ).effect_id == "pulse"
    assert resolve_effect_assignment(
        document,
        EffectAssignmentContext(**{**base, "project_id": None}),
    ).effect_id == "notification"

    # --- scenario: urgent_semantics_keep_the_alert_safeguard
    document = EffectAssignmentDocument(
        (
            _record("none", AssignmentScope.GLOBAL, None),
            _record("alert", AssignmentScope.SEMANTIC, "asking"),
            _record("rainbow", AssignmentScope.DEVICE, "device-1"),
        )
    )

    asking = resolve_effect_assignment(
        document,
        EffectAssignmentContext(
            semantic=SemanticEventKind.ASK,
            scene=Scene.FOCUS,
            device_id="device-1",
        ),
    )
    failure = resolve_effect_assignment(
        document,
        EffectAssignmentContext(
            semantic=SemanticEventKind.FAILURE,
            scene=Scene.FOCUS,
            device_id="device-1",
        ),
    )

    assert asking is not None and asking.effect_id == "alert"
    assert failure is None

    # --- scenario: assignment_cache_replaces_snapshots_without_disk_access
    original = EffectAssignmentDocument(
        (_record("pulse", AssignmentScope.PROVIDER, "claude"),)
    )
    updated = EffectAssignmentDocument(
        (_record("rainbow", AssignmentScope.PROVIDER, "claude"),)
    )
    cache = EffectAssignmentCache(original)

    assert cache.generation == 0
    assert cache.snapshot() == original
    cache.replace(updated)

    assert cache.generation == 1
    assert cache.snapshot() == updated



# --- an unreadable file or row never costs the person their assignments ---


def _write_rows(path, rows, *, version=1) -> bytes:
    import json

    payload = (json.dumps({"assignments": rows, "version": version}) + "\n").encode()
    path.write_bytes(payload)
    return payload


def _row(effect_id: str, scope: AssignmentScope, target_id: str | None) -> dict:
    return {"effect_id": effect_id, "scope": scope.value, "target_id": target_id}


def _kept_copies(path) -> list:
    return sorted(path.parent.glob(f"{path.name}.corrupt-*"))


def test_an_unreadable_assignment_file_is_set_aside_not_overwritten_by_the_next_save(
    tmp_path,
) -> None:
    path = tmp_path / "effect-assignments.json"
    path.write_bytes(b'{"assignments": [{"effect_id": "pulse"')

    restored = load_effect_assignments(path)

    assert restored.health is AssignmentRestoreHealth.CORRUPT
    assert restored.document == EffectAssignmentDocument()
    save_effect_assignments(
        path,
        EffectAssignmentDocument((_record("pulse", AssignmentScope.PROVIDER, "claude"),)),
    )
    (kept,) = _kept_copies(path)
    assert kept.read_bytes() == b'{"assignments": [{"effect_id": "pulse"'
    assert kept.stat().st_mode & 0o777 == 0o600
    assert load_effect_assignments(path).document.assignments[0].target_id == "claude"


def test_a_file_from_a_newer_version_is_kept_rather_than_wiped_by_the_next_save(
    tmp_path,
) -> None:
    path = tmp_path / "effect-assignments.json"
    original = _write_rows(
        path, [_row("pulse", AssignmentScope.PROVIDER, "claude")], version=2
    )

    restored = load_effect_assignments(path)
    save_effect_assignments(path, EffectAssignmentDocument())

    assert restored.document == EffectAssignmentDocument()
    (kept,) = _kept_copies(path)
    assert kept.read_bytes() == original


def test_an_oversized_assignment_file_is_set_aside_unread(tmp_path) -> None:
    from jrbar.effect_assignment_store import MAX_EFFECT_ASSIGNMENT_STORE_BYTES

    path = tmp_path / "effect-assignments.json"
    path.write_bytes(b" " * (MAX_EFFECT_ASSIGNMENT_STORE_BYTES + 1))

    restored = load_effect_assignments(path)

    assert restored.health is AssignmentRestoreHealth.OVERSIZED
    assert not path.exists()
    assert len(_kept_copies(path)) == 1


def test_one_bad_assignment_row_does_not_cost_the_good_ones(tmp_path) -> None:
    path = tmp_path / "effect-assignments.json"
    original = _write_rows(
        path,
        [
            _row("pulse", AssignmentScope.PROVIDER, "claude"),
            {"effect_id": "pulse", "scope": "no-such-scope", "target_id": "x"},
            _row("notification", AssignmentScope.SCENE, Scene.NIGHT.value),
            {"effect_id": "pulse", "scope": "provider"},
            "not a row",
        ],
    )

    restored = load_effect_assignments(path)

    assert [row.target_id for row in restored.document.assignments] == [
        "claude",
        Scene.NIGHT.value,
    ]
    assert restored.dropped == 3
    assert restored.health is AssignmentRestoreHealth.PARTIAL
    # The file stays until the next save; a copy of what was dropped is kept.
    assert path.read_bytes() == original
    (kept,) = _kept_copies(path)
    assert kept.read_bytes() == original
    # Loading the same file again does not make a second copy.
    load_effect_assignments(path)
    assert len(_kept_copies(path)) == 1


def test_a_safeguard_breaking_row_is_dropped_and_the_rest_survive(tmp_path) -> None:
    path = tmp_path / "effect-assignments.json"
    _write_rows(
        path,
        [
            _row("rainbow", AssignmentScope.SEMANTIC, "asking"),
            _row("pulse", AssignmentScope.PROVIDER, "claude"),
        ],
    )

    restored = load_effect_assignments(path)

    assert [row.effect_id for row in restored.document.assignments] == ["pulse"]
    assert restored.dropped == 1


def test_a_healthy_assignment_file_is_never_moved(tmp_path) -> None:
    path = tmp_path / "effect-assignments.json"
    save_effect_assignments(
        path, EffectAssignmentDocument((_record("pulse", AssignmentScope.PROVIDER, "claude"),))
    )
    before = path.read_bytes()

    restored = load_effect_assignments(path)

    assert restored.health is AssignmentRestoreHealth.HEALTHY and restored.dropped == 0
    assert path.read_bytes() == before and _kept_copies(path) == []


def test_a_missing_or_unavailable_assignment_file_is_left_alone(tmp_path, monkeypatch) -> None:
    from jrbar import effect_assignment_store as module

    path = tmp_path / "effect-assignments.json"
    assert load_effect_assignments(path).health is AssignmentRestoreHealth.MISSING

    path.write_text("{}")

    def refuse(*_args, **_kwargs):
        raise PermissionError("permission denied")

    monkeypatch.setattr(module, "read_private_text", refuse)
    assert load_effect_assignments(path).health is AssignmentRestoreHealth.UNAVAILABLE
    assert path.read_text() == "{}" and _kept_copies(path) == []
