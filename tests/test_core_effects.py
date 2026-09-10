"""The Effect Studio documents the daemon serves (core_effects.py)."""

from __future__ import annotations

import json
from pathlib import Path

import pytest

from jrbar import core_effects
from jrbar.effect_assignment_store import EffectAssignmentDocument, EffectAssignmentRecord
from jrbar.effect_packs import effect_definitions_from_pack, validate_pack
from jrbar.effect_registry import EFFECT_REGISTRY
from jrbar.effect_studio import AssignmentScope
from jrbar.presentation_compiler import compile_presentation_program

SAMPLE_PACK = {
    "id": "nightlab",
    "name": "Night Lab",
    "version": 2,
    "safety": {"data_only": True, "network": False},
    "accessibility": {"reduced_motion": True, "high_contrast": True},
    "license": {"spdx_id": "CC0-1.0", "label": "Creative Commons Zero"},
    "effects": [
        {
            "id": "ember",
            "label": "Ember",
            "description": "A low warm shimmer.",
            "meaning": "quiet presence",
            "surfaces": ["screen_bar", "settings_preview"],
            "safety": "safe",
            "energy": "low",
            "reduce_motion_fallback": "coal",
            "motion": "flicker",
            "color": "#FF7A1A",
            "duration_seconds": 3.0,
        },
        {
            "id": "coal",
            "label": "Coal",
            "meaning": "quiet presence",
            "surfaces": ["screen_bar"],
            "motion": "steady",
            "color": "#8A2E00",
        },
        {
            "id": "beacon",
            "label": "Beacon",
            "meaning": "critical alert",
            "surfaces": ["screen_bar"],
            "safety": "critical",
            "energy": "high",
            "motion": "blink",
            "color": "#FF2D1A",
            "cadence": "deliberate",
        },
    ],
}


@pytest.fixture
def pack():
    return validate_pack(SAMPLE_PACK)


@pytest.fixture
def registry(pack):
    return core_effects.registry_with_packs((pack,))


def test_catalog_document_carries_every_effect_with_a_safe_preview(registry, pack) -> None:
    document = core_effects.catalog_document(registry, (pack,), generation=3, pack_paths={"nightlab": "/tmp/nightlab.json"})
    ids = {effect["id"] for effect in document["effects"]}
    assert {"none", "pulse", "alert", "blink", "aurora", "pack:nightlab:ember"} <= ids
    for effect in document["effects"]:
        assert effect["preview"]["led_count"] == 8
        compiled = compile_presentation_program(effect["preview"]["program"], led_count=8)
        assert compiled.accepted, effect["id"]
        for parameter in effect["parameters"]:
            assert parameter["type"] in {"number", "integer", "boolean", "choice", "color", "palette"}
            assert "default" in parameter
    ember = next(effect for effect in document["effects"] if effect["id"] == "pack:nightlab:ember")
    assert ember["pack"] == "nightlab"
    assert ember["reduce_motion_fallback"] == "pack:nightlab:coal"
    assert {p["name"] for p in ember["parameters"]} == {"motion", "color", "duration_seconds"}
    motion = next(p for p in ember["parameters"] if p["name"] == "motion")
    assert motion["type"] == "choice" and "flicker" in motion["choices"]
    blink = next(effect for effect in document["effects"] if effect["id"] == "blink")
    assert blink["cadence"]["id"] == "calm"
    beacon = next(effect for effect in document["effects"] if effect["id"] == "pack:nightlab:beacon")
    assert beacon["cadence"]["id"] == "deliberate"
    assert document["packs"] == [
        {
            "id": "nightlab",
            "name": "Night Lab",
            "version": 2,
            "effects": ["pack:nightlab:ember", "pack:nightlab:coal", "pack:nightlab:beacon"],
            "license": {"spdx_id": "CC0-1.0", "label": "Creative Commons Zero"},
            "path": "/tmp/nightlab.json",
        }
    ]
    assert [c["id"] for c in document["cadences"]] == ["calm", "deliberate", "double"]
    assert document["generation"] == 3
    json.dumps(document)


def test_render_uses_the_chosen_color_cadence_and_motion(registry, pack) -> None:
    alert = registry.require("alert")
    assert core_effects.render_effect(alert, {}, color="#123456") == "#123456 500ms none\noff 500ms none\nrepeat"
    blink = registry.require("blink")
    parameters = core_effects.normalize_parameters(blink, {"cadence": "double", "repeat": False, "bogus": 1})
    assert parameters == {"cadence": "double", "repeat": False}
    program = core_effects.render_effect(blink, parameters, color="#00FF00")
    assert program.count("#00FF00 300ms none") == 2 and "repeat" not in program
    aurora = registry.require("aurora")
    slow = core_effects.render_effect(aurora, core_effects.normalize_parameters(aurora, {"duration_seconds": 4.0}))
    fast = core_effects.render_effect(aurora, core_effects.normalize_parameters(aurora, {"duration_seconds": 1.0}))
    assert slow != fast
    ember = registry.require("pack:nightlab:ember")
    pack_effect = core_effects.pack_effect_for((pack,), ember.identifier)
    parameters = core_effects.normalize_parameters(ember, {"color": "#ff0000"}, pack_effect=pack_effect)
    assert parameters["color"] == "#FF0000" and parameters["motion"] == "flicker"
    program = core_effects.render_effect(ember, parameters, led_count=2)
    assert compile_presentation_program(program, led_count=2).accepted
    beacon = registry.require("pack:nightlab:beacon")
    parameters = core_effects.normalize_parameters(beacon, {}, pack_effect=core_effects.pack_effect_for((pack,), beacon.identifier))
    assert "#FF2D1A 500ms none" in core_effects.render_effect(beacon, parameters)


def test_assignment_document_merges_sidecar_parameters(tmp_path: Path) -> None:
    document = EffectAssignmentDocument(
        (
            EffectAssignmentRecord("pulse", AssignmentScope.GLOBAL, None),
            EffectAssignmentRecord("aurora", AssignmentScope.PROVIDER, "codex"),
        )
    )
    sidecar = tmp_path / "params.json"
    core_effects.save_assignment_parameters({"provider|codex": {"wave_count": 3}}, sidecar)
    assert oct(sidecar.stat().st_mode & 0o777) == "0o600"
    rows = core_effects.assignment_document(
        document, parameters=core_effects.load_assignment_parameters(sidecar), active_scene="calm", generation=2
    )
    assert rows == {
        "assignments": [
            {"effect_id": "pulse", "scope": "global", "target_id": None, "parameters": {}},
            {"effect_id": "aurora", "scope": "provider", "target_id": "codex", "parameters": {"wave_count": 3}},
        ],
        "active_scene": "calm",
        "generation": 2,
    }
    assert core_effects.load_assignment_parameters(tmp_path / "missing.json") == {}


def test_export_pack_round_trips_through_the_pack_validator(registry, pack, tmp_path: Path) -> None:
    payload, encoded = core_effects.build_export_pack(
        registry, (pack,), ["pulse", "aurora", "alert", "pack:nightlab:ember", "pack:nightlab:coal"],
        name="My Night", path=tmp_path / "my-night.json",
    )
    assert payload["id"] == "my-night" and payload["name"] == "My Night"
    rows = {row["id"]: row for row in payload["effects"]}
    assert rows["aurora"]["motion"] == "aurora" and rows["aurora"]["wave_count"] == 2
    assert rows["alert"]["reduce_motion_fallback"] == "pulse"
    assert "reduce_motion_fallback" not in rows["pulse"]  # its fallback (none) was not exported
    assert rows["ember"]["reduce_motion_fallback"] == "coal" and rows["ember"]["motion"] == "flicker"
    definitions = effect_definitions_from_pack(json.loads(encoded))
    assert {d.identifier for d in definitions} == {f"pack:my-night:{k}" for k in rows}
    with pytest.raises(KeyError):
        core_effects.build_export_pack(registry, (pack,), ["nope"], name=None, path=tmp_path / "x.json")
    with pytest.raises(ValueError):
        core_effects.build_export_pack(registry, (pack,), [], name=None, path=tmp_path / "x.json")
    assert core_effects.export_pack_id("Hello World!", Path("/tmp/z.json")) == "hello-world"
    assert core_effects.export_pack_id(None, Path("/tmp/Some Pack.json")) == "some-pack"


def test_builtin_registry_renders_without_packs() -> None:
    document = core_effects.catalog_document(EFFECT_REGISTRY, (), generation=0)
    assert document["packs"] == [] and len(document["effects"]) == len(EFFECT_REGISTRY.as_mapping())


def test_the_catalog_generation_describes_the_catalog_not_a_save_counter(registry, pack) -> None:
    """Live, ``list_effects.generation`` was 0 on a daemon serving 24
    effects, so the Effect Studio badge read "gen 0".

    The number came from the assignment cache's counter, which starts at
    zero and only moves when something calls ``replace()``: a daemon that
    had never saved an assignment published 0 for ever, and installing a
    pack did not move it either.
    """

    builtins = core_effects.catalog_generation(EFFECT_REGISTRY, ())
    assert builtins > 0

    # Same content, same number -- across calls and across processes.
    assert core_effects.catalog_generation(EFFECT_REGISTRY, ()) == builtins

    # An installed pack is a different catalog.
    with_pack = core_effects.catalog_generation(registry, (pack,))
    assert with_pack != builtins

    # The registry moving without the pack list is a change too.
    assert core_effects.catalog_generation(registry, ()) not in (builtins, with_pack)

    # And an assignment save still moves it: the cache's counter is folded in.
    assert core_effects.catalog_generation(registry, (pack,), revision=1) != with_pack

    # The document derives it when the caller does not supply one.
    document = core_effects.catalog_document(registry, (pack,))
    assert document["generation"] == with_pack
    assert core_effects.catalog_document(registry, (pack,), generation=7)["generation"] == 7


def test_the_assignments_generation_follows_the_assignments() -> None:
    empty = EffectAssignmentDocument(())
    one = EffectAssignmentDocument((EffectAssignmentRecord("pulse", AssignmentScope.GLOBAL, None),))
    two = EffectAssignmentDocument(
        (
            EffectAssignmentRecord("pulse", AssignmentScope.GLOBAL, None),
            EffectAssignmentRecord("aurora", AssignmentScope.PROVIDER, "codex"),
        )
    )

    generations = {
        core_effects.assignments_generation(empty),
        core_effects.assignments_generation(one),
        core_effects.assignments_generation(two),
        core_effects.assignments_generation(two, active_scene="calm"),
    }
    assert len(generations) == 4 and all(value > 0 for value in generations)
    assert core_effects.assignments_generation(one) == core_effects.assignments_generation(one)

    document = core_effects.assignment_document(two, active_scene="calm")
    assert document["generation"] == core_effects.assignments_generation(two, active_scene="calm")
