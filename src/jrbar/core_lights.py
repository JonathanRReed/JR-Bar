"""The headless daemon's light commands that had no socket spelling: the
semantic cues by name (``list_cues``/``set_cue``), the INIT.LED burn
(``burn_init``), calibration profile slots (``calibration_profile``) and
the Focus roster the per-Focus rules are written against
(``list_focuses``).

Every one of these lived only in the retiring PyObjC settings window. The
commands let the Swift app reach them; ``core_runtime`` registers them and
hands in the controller.
"""

from __future__ import annotations

from typing import Any

from .ambient_cues import (
    SWITCHABLE_CUE_IDS,
    cue_documents,
    cue_for_id,
    normalize_disabled_cues,
)

#: The longest program ``burn_init`` accepts before any parsing: the
#: firmware's own budget is 512 bytes, and a request ten times that is a
#: mistake, not a program.
MAX_BURN_PROGRAM_CHARACTERS = 4096


def _command_error(code: str, message: str):
    from .core_server import CommandError

    return CommandError(code, message)


def _apply_settings(controller: Any, candidate: Any, *, touched: list[str]) -> int:
    """Validate, save and publish a settings object the way ``set_setting``
    does, through the runtime's one write path."""
    from . import core_runtime

    return core_runtime._apply_settings_document(controller, candidate.to_dict(), touched=touched)


# --- the cues -------------------------------------------------------------------


def _with_milestone_count(controller: Any, rows: list[dict[str, Any]]) -> list[dict[str, Any]]:
    """The odometer row says where it stands -- "37 finished, next at 50"
    -- so its cue arrives with a meaning you could see coming. The count is
    the exact completions this daemon has seen since it started."""
    state = getattr(controller, "_milestone_odometer_state", None)
    count = getattr(state, "completed_count", 0)
    count = count if type(count) is int and count >= 0 else 0
    steps = getattr(getattr(controller, "settings", None), "milestone_odometer_steps", ()) or ()
    upcoming = [step for step in steps if type(step) is int and step > count]
    for row in rows:
        if row["id"] == "milestone_odometer":
            row["count"] = count
            row["next_step"] = min(upcoming) if upcoming else None
    return rows


def list_cues(controller: Any, _args: dict[str, Any]) -> dict[str, Any]:
    return {
        "cues": _with_milestone_count(controller, cue_documents(getattr(controller, "settings", None)))
    }


def set_cue(controller: Any, args: dict[str, Any]) -> dict[str, Any]:
    cue = cue_for_id(args.get("id"))
    if cue is None:
        raise _command_error("invalid_args", "unknown cue id")
    enabled = args.get("enabled")
    if type(enabled) is not bool:
        raise _command_error("invalid_args", "enabled must be a boolean")
    settings = controller.settings
    document = settings.to_dict()
    if cue.setting is not None:
        document[cue.setting] = enabled
        touched = [cue.setting]
    else:
        disabled = set(normalize_disabled_cues(document.get("ambient_cues_disabled")))
        if enabled:
            disabled.discard(cue.id)
        else:
            disabled.add(cue.id)
        document["ambient_cues_disabled"] = sorted(disabled & SWITCHABLE_CUE_IDS)
        touched = ["ambient_cues_disabled"]
    from . import core_runtime

    generation = core_runtime._apply_settings_document(controller, document, touched=touched)
    return {
        "generation": generation,
        "cues": _with_milestone_count(controller, cue_documents(controller.settings)),
    }


#: The ambient dispatch's surfaces by their ``lights.surfaces`` names.
_CUE_SURFACE_NAMES = {
    "screen_bar": "screen_bar",
    "sidepulse_pro": "hardware",
    "sidepulse_dot": "dot",
}


def augment_lights_cues(controller: Any, document: dict[str, Any]) -> None:
    """Name the cue staged on each surface -- "Handoff baton" instead of an
    unexplained sweep -- as ``lights.surfaces.<name>.cue``."""
    from .ambient_effect_dispatch import AmbientEffectSurface
    from .ambient_effect_runtime import active_ambient_surface_output

    surfaces = document.get("surfaces")
    if not isinstance(surfaces, dict):
        return
    for surface in AmbientEffectSurface:
        name = _CUE_SURFACE_NAMES.get(surface.value)
        entry = surfaces.get(name) if name else None
        if not isinstance(entry, dict):
            continue
        active = active_ambient_surface_output(controller, surface)
        if active is None:
            continue
        family = getattr(getattr(active[0], "family", None), "value", None)
        cue = cue_for_id(family)
        if cue is not None:
            entry["cue"] = {"id": cue.id, "name": cue.name}


# --- INIT.LED -------------------------------------------------------------------------


def _burn_targets(controller: Any, device: object) -> list[Any]:
    from . import status_bar_legacy as legacy

    # The command runs off the main thread (an SD write can take seconds);
    # the device inventory is the controller's, so it is read there.
    on_main = getattr(controller, "_core_on_main", None) or (lambda fn: fn())
    inventory = on_main(lambda: list(controller.status_bar_devices(remember=False) or []))
    targets = [
        candidate
        for candidate in inventory
        if getattr(candidate, "connected", False)
        and getattr(candidate, "device_id", None) != legacy.VIRTUAL_DEVICE_ID
    ]
    if device in (None, "", "all"):
        return targets
    return [candidate for candidate in targets if candidate.device_id == device]


def burn_init(controller: Any, args: dict[str, Any]) -> dict[str, Any]:
    """Plan -- and only with ``confirm: true``, write -- a power-up program.

    Each device is judged at its OWN LED count through the four gates of
    ``animation.plan_power_up_burn`` (model, compile, device limits, the real
    firmware parser, refusing when that parser is unavailable). Without
    ``confirm`` nothing is written and the reply is the exact plan: the bytes
    each device would get and every warning. INIT.LED replays at every boot,
    so the write is the one thing here a person cannot undo by looking away.
    """
    from ._led_status_legacy import led_count_for_target
    from .animation import (
        AnimationValidationError,
        burn_power_up_animation,
        parse_animation,
    )

    program = args.get("program")
    if type(program) is not str or not program.strip():
        raise _command_error("invalid_args", "program is required")
    if len(program) > MAX_BURN_PROGRAM_CHARACTERS:
        raise _command_error("invalid_args", "program is far past the device budget")
    confirm = args.get("confirm", False)
    if type(confirm) is not bool:
        raise _command_error("invalid_args", "confirm must be a boolean")
    targets = _burn_targets(controller, args.get("device"))
    if not targets:
        raise _command_error("not_found", "No connected SidePulse Pro or Dot to burn.")
    rows: list[dict[str, Any]] = []
    for target in targets:
        row: dict[str, Any] = {
            "device": target.device_id,
            "name": getattr(target, "name", target.device_id),
            "written": False,
        }
        try:
            led_count = int(led_count_for_target(target.target))
        except Exception:
            led_count = 8
        row["led_count"] = led_count
        try:
            animation = parse_animation(program.strip(), led_count=led_count)
            plan = burn_power_up_animation(
                animation,
                device_path=getattr(target, "root", None),
                led_count=led_count,
                dry_run=not confirm,
            )
        except AnimationValidationError as error:
            row["error"] = "invalid_program"
            row["problems"] = [
                {
                    "severity": getattr(problem, "severity", None),
                    "code": getattr(problem, "code", None),
                    "message": getattr(problem, "message", str(problem)),
                    "step": getattr(problem, "step", None),
                }
                for problem in getattr(error, "problems", ()) or ()
            ] or [{"severity": "error", "code": None, "message": str(error), "step": None}]
        except Exception as error:
            row["error"] = str(error) or error.__class__.__name__
        else:
            row.update(
                {
                    "bytes": plan.byte_count,
                    "firmware_checked": plan.firmware_checked,
                    "warnings": [problem.message for problem in plan.warnings],
                    "written": bool(plan.written),
                    "target": None if plan.target is None else str(plan.target),
                    "error": None,
                }
            )
        rows.append(row)
    return {
        "confirmed": confirm,
        "written": any(row["written"] for row in rows),
        "devices": rows,
    }


# --- calibration profiles ------------------------------------------------------------


def calibration_profile(controller: Any, args: dict[str, Any]) -> dict[str, Any]:
    """Save the current calibration into a slot, apply one, or delete one."""
    from ._settings_legacy import CALIBRATION_PROFILE_SLOTS

    action = args.get("action")
    slot = args.get("slot")
    if action not in ("save", "apply", "delete"):
        raise _command_error("invalid_args", "action must be save, apply or delete")
    if slot not in CALIBRATION_PROFILE_SLOTS:
        raise _command_error(
            "invalid_args", f"slot must be one of {', '.join(CALIBRATION_PROFILE_SLOTS)}"
        )
    settings = controller.settings
    matched = None
    if action == "save":
        candidate = settings.with_saved_calibration_profile(slot)
    elif action == "apply":
        profile = settings.calibration_profiles.get(slot)
        if not isinstance(profile, dict):
            raise _command_error("not_found", f"no {slot} profile is saved")
        known = {device.device_id for device in settings.devices}
        matched = sum(1 for device_id in profile if device_id in known)
        candidate = settings.with_applied_calibration_profile(slot)
    else:
        document = settings.to_dict()
        profiles = dict(document.get("calibration_profiles") or {})
        removed = profiles.pop(slot, None) is not None
        if not removed:
            return {"slot": slot, "removed": False, "slots": sorted(settings.calibration_profiles)}
        document["calibration_profiles"] = profiles
        from . import core_runtime

        generation = core_runtime._apply_settings_document(
            controller, document, touched=["calibration_profiles"]
        )
        return {
            "slot": slot,
            "removed": True,
            "generation": generation,
            "slots": sorted(controller.settings.calibration_profiles),
        }
    generation = _apply_settings(
        controller, candidate, touched=["calibration_profiles", "devices"]
    )
    reply: dict[str, Any] = {
        "slot": slot,
        "action": action,
        "generation": generation,
        "slots": sorted(controller.settings.calibration_profiles),
    }
    if matched is not None:
        reply["matched"] = matched
    return reply


# --- situation preview -------------------------------------------------------------------


def resolve_effect(controller: Any, args: dict[str, Any]) -> dict[str, Any]:
    """Which assignment wins for a situation, before it happens: pick a
    meaning, a scene, a provider, a project and a device and see the scope
    ladder walked -- device, project, provider instance, provider, scene,
    meaning, everywhere -- with the winning rung marked. Answers "why is
    Codex purple in Night" without waiting for Codex at night. Asks and
    failures keep their reserved alert: only the meaning rung is consulted."""
    from . import core_runtime
    from .effect_assignment_store import (
        _SCOPE_PRECEDENCE,
        EffectAssignmentContext,
        EffectAssignmentStoreError,
        _target_for_scope,
        resolve_effect_assignment,
    )
    from .effect_studio import AssignmentScope
    from .scenes import DEFAULT_SCENE, scene_from_value
    from .semantic_effect_router import URGENT_SEMANTICS, SemanticEventKind

    try:
        semantic = SemanticEventKind(str(args.get("semantic") or ""))
    except ValueError as error:
        raise _command_error("invalid_args", "semantic must name a meaning (ask, work, completion, ...)") from error
    scene_word = args.get("scene")
    if scene_word is None:
        scene_word = getattr(getattr(controller, "settings", None), "active_scene", None)
    scene = scene_from_value(scene_word) or (None if args.get("scene") is not None else DEFAULT_SCENE)
    if scene is None:
        raise _command_error("invalid_args", "unknown scene")
    fields = {}
    for key, name in (
        ("provider", "provider_id"),
        ("instance", "provider_instance_id"),
        ("project", "project_id"),
        ("device", "device_id"),
    ):
        value = args.get(key)
        if value is not None and (type(value) is not str or not value.strip()):
            raise _command_error("invalid_args", f"{key} must be a nonempty string")
        fields[name] = value.strip() if isinstance(value, str) else None
    try:
        context = EffectAssignmentContext(semantic, scene, **fields)
    except EffectAssignmentStoreError as error:
        raise _command_error("invalid_args", str(error)) from error
    document = core_runtime._effects_cache(controller).snapshot()
    winner = resolve_effect_assignment(document, context)
    urgent = semantic in URGENT_SEMANTICS
    scopes = (AssignmentScope.SEMANTIC,) if urgent else _SCOPE_PRECEDENCE
    ladder = []
    for scope in scopes:
        target = _target_for_scope(context, scope)
        applicable = scope is AssignmentScope.GLOBAL or target is not None
        assignment = document.assignment_for(scope, target) if applicable else None
        ladder.append(
            {
                "scope": scope.value,
                "target_id": target,
                "applicable": applicable,
                "effect_id": None if assignment is None else assignment.effect_id,
                "wins": assignment is not None and assignment == winner,
            }
        )
    return {
        "semantic": semantic.value,
        "scene": scene.value,
        "urgent": urgent,
        "winner": None
        if winner is None
        else {"scope": winner.scope.value, "target_id": winner.target_id, "effect_id": winner.effect_id},
        "ladder": ladder,
    }


# --- the light log -------------------------------------------------------------------------


def list_light_log(controller: Any, args: dict[str, Any]) -> dict[str, Any]:
    """What JR-Bar tried to show, where, and what became of it -- the
    content-free effect history (200 events) nothing displayed: "14:02 shown
    on the Screen Bar for attention", "suppressed on the Dot by Do Not
    Disturb". Newest first, answering "what did I miss" for the lights."""
    from .ambient_effect_runtime import _history
    from .effect_history import project_effect_history

    limit = args.get("limit", 20)
    if isinstance(limit, bool) or not isinstance(limit, int) or limit < 1:
        raise _command_error("invalid_args", "limit must be a positive integer")
    history = _history(controller)
    rows = sorted(project_effect_history(history), key=lambda row: -row.occurred_at_epoch)
    return {
        "rows": [
            {
                "at": row.occurred_at_epoch,
                "effect": row.effect_id,
                "category": row.semantic_category.value,
                "surface": row.surface.value,
                "outcome": row.outcome.value,
                "explanation": row.explanation,
                "unseen": row.unseen,
            }
            for row in rows[: min(limit, 200)]
        ],
        "total": len(rows),
        "last_seen": history.last_seen_epoch,
    }


# --- Focus -------------------------------------------------------------------------------


def list_focuses(_controller: Any, _args: dict[str, Any]) -> dict[str, Any]:
    """The Focuses this Mac has configured, so a per-Focus rule can name a
    custom one and not only the four built-ins. The roster lives beside
    the assertions file macOS guards with Full Disk Access; ``available``
    false says so rather than pretending the Mac has no Focuses."""
    from . import focus_sync

    try:
        configured = focus_sync.configured_focus_modes()
    except focus_sync.FocusSyncUnavailableError as error:
        return {"available": False, "reason": str(error)[:200], "focuses": [], "active": []}
    try:
        active = sorted(focus_sync.active_focus_mode_identifiers())
    except focus_sync.FocusSyncUnavailableError:
        active = []
    return {
        "available": True,
        "reason": None,
        "focuses": [{"id": identifier, "name": name} for identifier, name in configured],
        "active": active,
    }


__all__ = [
    "MAX_BURN_PROGRAM_CHARACTERS",
    "augment_lights_cues",
    "burn_init",
    "calibration_profile",
    "list_cues",
    "list_focuses",
    "list_light_log",
    "set_cue",
]
