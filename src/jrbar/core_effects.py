"""Effect Studio over the socket: the ``list_effects`` / ``render_effect`` /
``list_assignments`` / ``set_assignment`` / ``clear_assignment`` /
``import_effect_pack`` / ``export_effect_pack`` documents.

Pure projections of the existing effect registry, pack store and assignment
store (``effect_registry.py``, ``effect_packs.py``, ``effect_pack_store.py``,
``effect_assignment_store.py``); ``core_runtime`` wires them to the
controller's ``_effect_assignment_cache``. Assignment parameters are not part
of the Python assignment document, so they live in a sidecar
(``effect-assignment-parameters.json`` in the state directory) keyed by
``scope|target``.
"""

from __future__ import annotations

import hashlib
import json
import os
import re
from collections.abc import Iterable, Mapping
from pathlib import Path
from typing import Any, Final

from . import colors as colors_module
from .effect_packs import (
    EffectPack,
    EffectPackError,
    export_pack,
    registry_with_pack,
    validate_pack,
)
from .effect_registry import (
    EFFECT_REGISTRY,
    SAFE_BLINK_CADENCES,
    BlinkCadence,
    EffectDefinition,
    EffectParameter,
    EffectRegistry,
    blink_cadence,
)
from .led_status import ERROR_RED
from .presentation_compiler import compile_presentation_program
from .state_paths import default_state_dir

PARAMETERS_SIDECAR_NAME: Final = "effect-assignment-parameters.json"
MAX_PARAMETERS_SIDECAR_BYTES: Final = 256_000
BASE_COLOR: Final = "#00E5FF"
SEMANTIC_COLORS: Final = {
    "working": "#00E5FF",
    "asking": "#FF3A00",
    "completion": "#00FF66",
    # Not "#FF3A00": an effect assigned to failure used to preview and
    # play in the Ask colour, so "it broke" and "it needs you" were one
    # light here too. colors.MODE_ERROR's shipped default.
    "failure": ERROR_RED,
    "recovery": "#12E3B0",
    "notification": "#A45CFF",
    "quota": "#36C5F0",
    "environment": "#FFB340",
    "idle": "#8B93A7",
    "transition": "#A45CFF",
}
#: Pack effects and the builtins that have no motion of their own render
#: through one registered primitive per declared meaning.
SEMANTIC_PRIMITIVES: Final = {
    "working": "pulse",
    "asking": "alert",
    "failure": "alert",
    "completion": "notification",
    "recovery": "notification",
    "notification": "notification",
    "transition": "pulse",
}
_PACK_ID_PATTERN: Final = re.compile(r"[^A-Za-z0-9._-]+")
_HEX: Final = re.compile(r"^#[0-9A-Fa-f]{6}$")


# --- documents ----------------------------------------------------------------


def pack_id_of(identifier: str) -> str | None:
    parts = identifier.split(":")
    return parts[1] if len(parts) >= 3 and parts[0] == "pack" else None


def parameter_document(parameter: EffectParameter) -> dict[str, Any]:
    document: dict[str, Any] = {
        "name": parameter.name,
        "type": parameter.value_type,
        "default": list(parameter.default) if isinstance(parameter.default, tuple) else parameter.default,
        "description": parameter.description,
    }
    if parameter.minimum is not None:
        document["minimum"] = parameter.minimum
    if parameter.maximum is not None:
        document["maximum"] = parameter.maximum
    if parameter.choices:
        document["choices"] = list(parameter.choices)
    if parameter.minimum_items is not None:
        document["minimum_items"] = parameter.minimum_items
    if parameter.maximum_items is not None:
        document["maximum_items"] = parameter.maximum_items
    if parameter.allow_empty:
        document["allow_empty"] = True
    if parameter.unit is not None:
        document["unit"] = parameter.unit
    return document


def cadence_document(cadence: BlinkCadence) -> dict[str, Any]:
    return {
        "id": cadence.identifier,
        "label": cadence.label,
        "on_ms": cadence.on_ms,
        "off_ms": cadence.off_ms,
        "pulses": cadence.pulses,
        "rest_ms": cadence.rest_ms,
    }


def _pack_parameters(pack_effect: Mapping[str, Any] | None) -> list[dict[str, Any]]:
    """Pack effects carry untyped data; type it the way the mock did so the
    Studio's controls know what to draw."""
    if not pack_effect:
        return []
    from .effect_packs import _EFFECT_METADATA_KEYS

    documents: list[dict[str, Any]] = []
    motion_ids = sorted(colors_module.PROVIDER_ANIMATION_CHOICES)
    for name in sorted(str(key) for key in pack_effect if key not in _EFFECT_METADATA_KEYS):
        value = pack_effect[name]
        title = name.replace("_", " ").capitalize()
        row: dict[str, Any] = {"name": name, "description": f"{title} (pack value)."}
        if isinstance(value, bool):
            row.update(type="boolean", default=value)
        elif isinstance(value, int):
            row.update(type="integer", default=value, minimum=0, maximum=max(10, value * 2))
        elif isinstance(value, float):
            row.update(type="number", default=value, minimum=0.0, maximum=max(10.0, value * 2))
        elif isinstance(value, str) and _HEX.match(value):
            row.update(type="color", default=value.upper())
        elif isinstance(value, (list, tuple)) and value and all(isinstance(v, str) and _HEX.match(v) for v in value):
            row.update(
                type="palette",
                default=[v.upper() for v in value],
                minimum_items=2,
                maximum_items=max(len(value), 4),
                allow_empty=False,
            )
        elif name == "motion" and isinstance(value, str):
            row.update(
                type="choice",
                default=value if value in motion_ids else colors_module.MOTION_BREATHE,
                choices=motion_ids,
                description="Base motion the pack effect is rendered with.",
            )
        elif name == "cadence" and isinstance(value, str):
            row.update(
                type="choice",
                default=value,
                choices=[c.identifier for c in SAFE_BLINK_CADENCES],
                description="Named blink cadence.",
            )
        else:
            row.update(type="choice", default=str(value), choices=[str(value)])
        documents.append(row)
    return documents


def effect_document(
    effect: EffectDefinition,
    *,
    pack_effect: Mapping[str, Any] | None = None,
    preview: dict[str, Any] | None = None,
    cadence: dict[str, Any] | None = None,
) -> dict[str, Any]:
    document: dict[str, Any] = {
        "id": effect.identifier,
        "label": effect.label,
        "description": effect.description,
        "meaning": effect.meaning,
        "surfaces": list(effect.surfaces),
        "parameters": (
            [parameter_document(parameter) for parameter in effect.parameter_metadata]
            if effect.parameter_metadata
            else _pack_parameters(pack_effect)
        ),
        "safety": effect.safety,
        "energy": effect.energy,
        "reduce_motion_fallback": effect.reduce_motion_fallback,
        "version": effect.version,
        "catalog": effect.catalog,
        "role": effect.role,
    }
    pack = pack_id_of(effect.identifier)
    if pack is not None:
        document["pack"] = pack
    if preview is not None:
        document["preview"] = preview
    if cadence is not None:
        document["cadence"] = cadence
    return document


def pack_document(pack: EffectPack, *, path: str | None = None) -> dict[str, Any]:
    document: dict[str, Any] = {
        "id": pack.pack_id,
        "name": pack.name,
        "version": pack.version,
        "effects": [f"pack:{pack.pack_id}:{effect['id']}" for effect in pack.effects],
    }
    if pack.license is not None:
        license_document: dict[str, Any] = {"spdx_id": pack.license.spdx_id, "label": pack.license.label}
        if pack.license.source_url:
            license_document["source_url"] = pack.license.source_url
        document["license"] = license_document
    if path is not None:
        document["path"] = path
    return document


def pack_effect_for(packs: Iterable[EffectPack], identifier: str) -> Mapping[str, Any] | None:
    parts = identifier.split(":")
    if len(parts) < 3 or parts[0] != "pack":
        return None
    pack_id, local = parts[1], ":".join(parts[2:])
    for pack in packs:
        if pack.pack_id != pack_id:
            continue
        for effect in pack.effects:
            if str(effect.get("id")) == local:
                return effect
    return None


def registry_with_packs(packs: Iterable[EffectPack], base: EffectRegistry = EFFECT_REGISTRY) -> EffectRegistry:
    registry = base
    for pack in packs:
        try:
            registry = registry_with_pack(registry, pack)
        except EffectPackError:
            continue
    return registry


# --- parameters ---------------------------------------------------------------


def normalize_parameters(
    effect: EffectDefinition,
    values: Mapping[str, Any] | None,
    *,
    pack_effect: Mapping[str, Any] | None = None,
) -> dict[str, Any]:
    """Defaults for anything missing, unknown names dropped, bounds kept."""
    values = dict(values) if isinstance(values, Mapping) else {}
    if effect.parameter_metadata:
        known = {parameter.name for parameter in effect.parameter_metadata}
        cleaned = {str(k): v for k, v in values.items() if str(k) in known}
        try:
            return effect.normalize_parameters(cleaned)
        except Exception:
            result: dict[str, Any] = {}
            for parameter in effect.parameter_metadata:
                try:
                    result[parameter.name] = parameter.normalize(cleaned.get(parameter.name, parameter.default))
                except Exception:
                    result[parameter.name] = parameter.default
            return result
    result = {}
    for row in _pack_parameters(pack_effect):
        name = row["name"]
        kind = row["type"]
        value = values.get(name, row["default"])
        try:
            if kind == "boolean":
                value = bool(value)
            elif kind == "integer":
                value = max(row["minimum"], min(row["maximum"], int(round(float(value)))))
            elif kind == "number":
                value = max(row["minimum"], min(row["maximum"], float(value)))
            elif kind == "choice":
                value = value if value in row["choices"] else row["default"]
            elif kind == "color":
                value = value.upper() if isinstance(value, str) and _HEX.match(value) else row["default"]
            elif kind == "palette":
                value = [v.upper() for v in value if isinstance(v, str) and _HEX.match(v)] if isinstance(value, list) else list(row["default"])
                if len(value) < row["minimum_items"]:
                    value = list(row["default"])
                value = value[: row["maximum_items"]]
        except (TypeError, ValueError, AttributeError):
            value = row["default"]
        result[name] = value
    return result


def effect_cadence(effect: EffectDefinition, parameters: Mapping[str, Any]) -> dict[str, Any] | None:
    cadence_id = parameters.get("cadence")
    if not isinstance(cadence_id, str):
        if effect.identifier == "alert":
            cadence_id = "deliberate"
        elif effect.identifier == "notification":
            cadence_id = "double"
        else:
            return None
    try:
        return cadence_document(blink_cadence(cadence_id))
    except KeyError:
        return None


# --- rendering ----------------------------------------------------------------


def _builtin_program(identifier: str, color: str) -> str | None:
    if identifier == "none":
        return color
    if identifier == "pulse":
        return f"off 400ms cosine\n{color} 1600ms pulse\nrepeat"
    if identifier == "rainbow":
        return (
            "#FF3B30 600ms cosine\n#FF9500 600ms cosine\n#34C759 600ms cosine\n"
            "#0A84FF 600ms cosine\n#AF52DE 600ms cosine\nrepeat"
        )
    if identifier == "alert":
        return f"{color} 500ms none\noff 500ms none\nrepeat"
    if identifier == "notification":
        return f"off 300ms cosine\n{color} 900ms pulse\n{color}"
    return None


def _motion_program(motion: str, color: str, parameters: Mapping[str, Any], *, led_count: int) -> str:
    """The whole-strip shape one provider motion plays for ``color``: the
    same renderer the Settings thumbnails and the solo live render use."""
    from ._settings_legacy import AgentMonitorSettings

    colors = AgentMonitorSettings().colors
    if motion == colors_module.MOTION_BLINK:
        cadence_id = parameters.get("cadence", "calm")
        try:
            cadence = blink_cadence(str(cadence_id))
        except KeyError:
            cadence = blink_cadence("calm")
        lines = []
        for _ in range(cadence.pulses):
            lines.append(f"{color} {cadence.on_ms}ms none")
            lines.append(f"off {cadence.off_ms}ms none")
        if cadence.rest_ms:
            lines.append(f"off {cadence.rest_ms}ms none")
        if parameters.get("repeat", True):
            lines.append("repeat")
        return "\n".join(lines)
    duration = parameters.get("duration_seconds")
    if isinstance(duration, (int, float)) and not isinstance(duration, bool):
        colors = colors.with_cycle_speed(float(duration))
    if motion in colors_module.PROVIDER_ANIMATION_CHOICES:
        colors = colors.with_agent_animation("claude", motion)
    return colors_module.provider_motion_preview_program("claude", color, colors, led_count=led_count)


def render_effect(
    effect: EffectDefinition,
    parameters: Mapping[str, Any],
    *,
    led_count: int = 8,
    color: str | None = None,
    semantic: str | None = None,
) -> str:
    """One safe LEDS program for an effect and its normalised parameters."""
    led_count = max(2, min(8, int(led_count)))
    chosen = parameters.get("color")
    if not (isinstance(chosen, str) and _HEX.match(chosen)):
        chosen = color if isinstance(color, str) and _HEX.match(color) else None
    if chosen is None:
        chosen = SEMANTIC_COLORS.get(semantic or "", BASE_COLOR)
    chosen = chosen.upper()
    candidate = _builtin_program(effect.identifier, chosen)
    if candidate is None and effect.catalog == "provider_animation":
        motion = effect.identifier
        if motion == colors_module.PROVIDER_ANIMATION_AUTO:
            motion = colors_module.MOTION_BREATHE
        candidate = _motion_program(motion, chosen, parameters, led_count=led_count)
    if candidate is None:
        motion = parameters.get("motion")
        if isinstance(motion, str) and motion in colors_module.PROVIDER_ANIMATION_CHOICES:
            if motion == colors_module.PROVIDER_ANIMATION_AUTO:
                motion = colors_module.MOTION_BREATHE
            candidate = _motion_program(motion, chosen, parameters, led_count=led_count)
        else:
            primitive = SEMANTIC_PRIMITIVES.get(semantic or _semantic_of(effect), "none")
            candidate = _builtin_program(primitive, chosen) or chosen
    compiled = compile_presentation_program(candidate, led_count=led_count, fallback=chosen)
    return compiled.program


def _semantic_of(effect: EffectDefinition) -> str:
    meaning = effect.meaning.lower()
    for family in SEMANTIC_COLORS:
        if family in meaning:
            return family
    if "attention" in meaning or "alert" in meaning:
        return "asking"
    if "new event" in meaning:
        return "notification"
    if "activity" in meaning or "provider animation" in meaning:
        return "working"
    return "idle"


def _fingerprint(parts: Iterable[Any]) -> int:
    """A stable positive int for a canonical description of some content.

    ``blake2b`` because it is stable across processes and interpreter runs
    -- ``hash()`` is not, and a generation that changed on every daemon
    restart would be as useless as one that never changed. Folded to 31
    bits so it fits every consumer's plain signed ``Int``; ``0`` is
    reserved for "nothing here", so real content never lands on it.
    """

    encoded = json.dumps(list(parts), sort_keys=True, separators=(",", ":"), default=str)
    digest = hashlib.blake2b(encoded.encode("utf-8"), digest_size=8).digest()
    return (int.from_bytes(digest, "big") % 0x7FFFFFFE) + 1


def catalog_generation(
    registry: EffectRegistry,
    packs: Iterable[EffectPack],
    *,
    revision: int = 0,
) -> int:
    """``list_effects.generation``: what this catalog IS, not how often it
    was replaced.

    The assignment cache's counter starts at 0 and only moves when
    something calls ``replace()``, so a daemon that had never saved an
    assignment published ``generation: 0`` for ever and the Effect Studio
    badge read "gen 0". This is derived from the catalog's own content:
    every effect id and version in the registry, every installed pack's id
    and version and effect list, plus ``revision`` (the cache's counter) so
    an assignment save moves it too. Change any of those and the number
    changes; change none of them and it does not.
    """

    packs = tuple(packs)
    effects = sorted(
        (effect.identifier, str(effect.version), effect.role, effect.catalog)
        for effect in registry.as_mapping().values()
    )
    installed = sorted(
        (
            pack.pack_id,
            str(pack.version),
            sorted(str(entry.get("id", "")) for entry in pack.effects),
        )
        for pack in packs
    )
    return _fingerprint(["effects", effects, "packs", installed, "revision", int(revision)])


def assignments_generation(document: Any, *, active_scene: str | None = None) -> int:
    """``list_assignments.generation``, derived from the assignments the
    document actually carries (and the scene they run under)."""

    rows = sorted(
        (
            str(getattr(record, "effect_id", "")),
            str(getattr(getattr(record, "scope", None), "value", getattr(record, "scope", ""))),
            str(getattr(record, "target_id", "") or ""),
        )
        for record in getattr(document, "assignments", ()) or ()
    )
    return _fingerprint(["assignments", rows, "scene", active_scene or ""])


def catalog_document(
    registry: EffectRegistry,
    packs: Iterable[EffectPack],
    *,
    generation: int | None = None,
    pack_paths: Mapping[str, str] | None = None,
) -> dict[str, Any]:
    packs = tuple(packs)
    if generation is None:
        generation = catalog_generation(registry, packs)
    effects: list[dict[str, Any]] = []
    for effect in registry.as_mapping().values():
        pack_effect = pack_effect_for(packs, effect.identifier)
        parameters = normalize_parameters(effect, {}, pack_effect=pack_effect)
        try:
            program = render_effect(effect, parameters, led_count=8)
        except Exception:
            program = BASE_COLOR
        effects.append(
            effect_document(
                effect,
                pack_effect=pack_effect,
                preview={"program": program, "led_count": 8},
                cadence=effect_cadence(effect, parameters),
            )
        )
    return {
        "effects": effects,
        "packs": [pack_document(pack, path=(pack_paths or {}).get(pack.pack_id)) for pack in packs],
        "cadences": [cadence_document(cadence) for cadence in SAFE_BLINK_CADENCES],
        "generation": int(generation),
    }


# --- assignments --------------------------------------------------------------


def assignment_key(scope: str, target_id: str | None) -> str:
    return f"{scope}|{target_id or ''}"


def parameters_sidecar_path(state_dir: Path | None = None) -> Path:
    return (state_dir or default_state_dir()) / PARAMETERS_SIDECAR_NAME


def load_assignment_parameters(path: Path | None = None) -> dict[str, dict[str, Any]]:
    target = path or parameters_sidecar_path()
    try:
        if target.stat().st_size > MAX_PARAMETERS_SIDECAR_BYTES:
            return {}
        payload = json.loads(target.read_text(encoding="utf-8"))
    except (OSError, ValueError):
        return {}
    if not isinstance(payload, dict):
        return {}
    return {str(key): dict(value) for key, value in payload.items() if isinstance(value, dict)}


def save_assignment_parameters(table: Mapping[str, Mapping[str, Any]], path: Path | None = None) -> Path:
    target = path or parameters_sidecar_path()
    target.parent.mkdir(parents=True, exist_ok=True, mode=0o700)
    encoded = json.dumps({key: dict(value) for key, value in table.items()}, sort_keys=True, indent=1)
    temporary = target.with_name(target.name + f".{os.getpid()}.tmp")
    descriptor = os.open(temporary, os.O_WRONLY | os.O_CREAT | os.O_TRUNC, 0o600)
    try:
        with os.fdopen(descriptor, "w", encoding="utf-8") as handle:
            handle.write(encoded + "\n")
        os.replace(temporary, target)
    finally:
        try:
            temporary.unlink()
        except OSError:
            pass
    return target


def assignment_document(
    document: Any,
    *,
    parameters: Mapping[str, Mapping[str, Any]] | None = None,
    active_scene: str | None,
    generation: int | None = None,
) -> dict[str, Any]:
    if generation is None:
        generation = assignments_generation(document, active_scene=active_scene)
    rows = []
    for record in getattr(document, "assignments", ()):
        scope = getattr(record.scope, "value", str(record.scope))
        rows.append(
            {
                "effect_id": record.effect_id,
                "scope": scope,
                "target_id": record.target_id,
                "parameters": dict((parameters or {}).get(assignment_key(scope, record.target_id), {})),
            }
        )
    return {"assignments": rows, "active_scene": active_scene, "generation": int(generation)}


# --- packs ----------------------------------------------------------------------


def export_pack_id(name: str | None, path: Path) -> str:
    raw = str(name or path.stem or "export").lower()
    cleaned = _PACK_ID_PATTERN.sub("-", raw).strip("-.")
    return cleaned or "export"


def build_export_pack(
    registry: EffectRegistry,
    packs: Iterable[EffectPack],
    ids: list[str],
    *,
    name: str | None,
    path: Path,
) -> tuple[dict[str, Any], bytes]:
    """A data-only JSON v2 pack holding the chosen effects: pack effects
    keep their original data, builtins become their motion plus defaults."""
    packs = tuple(packs)
    wanted = [identifier for identifier in ids if isinstance(identifier, str) and identifier]
    if not wanted:
        raise ValueError("ids[] is empty")
    local_ids = {identifier: (identifier.split(":")[-1] if pack_id_of(identifier) else identifier) for identifier in wanted}
    effects: list[dict[str, Any]] = []
    for identifier in wanted:
        effect = registry.get(identifier)
        if effect is None:
            raise KeyError(identifier)
        source = pack_effect_for(packs, identifier)
        if source is not None:
            row = json.loads(json.dumps(dict(source)))
            row["id"] = local_ids[identifier]
        else:
            row = {
                "id": local_ids[identifier],
                "label": effect.label,
                "description": effect.description,
                "meaning": effect.meaning,
                "surfaces": list(effect.surfaces),
                "safety": effect.safety,
                "energy": effect.energy,
            }
            if effect.catalog == "provider_animation":
                row["motion"] = effect.identifier
            for parameter in effect.parameter_metadata:
                default = parameter.default
                row[parameter.name] = list(default) if isinstance(default, tuple) else default
        fallback = effect.reduce_motion_fallback
        if fallback and fallback in local_ids:
            row["reduce_motion_fallback"] = local_ids[fallback]
        else:
            row.pop("reduce_motion_fallback", None)
        effects.append(row)
    pack_id = export_pack_id(name, path)
    payload = {
        "id": pack_id,
        "name": str(name or path.stem or "Export")[:160],
        "version": 2,
        "safety": {"data_only": True, "network": False},
        "accessibility": {"reduced_motion": True, "high_contrast": True},
        "effects": effects,
    }
    validated = validate_pack(payload)
    return payload, export_pack(validated)


__all__ = [
    "BASE_COLOR",
    "PARAMETERS_SIDECAR_NAME",
    "SEMANTIC_COLORS",
    "assignment_document",
    "assignment_key",
    "assignments_generation",
    "build_export_pack",
    "cadence_document",
    "catalog_document",
    "catalog_generation",
    "effect_cadence",
    "effect_document",
    "export_pack_id",
    "load_assignment_parameters",
    "normalize_parameters",
    "pack_document",
    "pack_effect_for",
    "pack_id_of",
    "parameter_document",
    "parameters_sidecar_path",
    "registry_with_packs",
    "render_effect",
    "save_assignment_parameters",
]
