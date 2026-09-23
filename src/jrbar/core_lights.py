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


# --- a blend mode against a fleet --------------------------------------------------------

#: The largest strip a preview renders for: the Pro's eight and the Dot's
#: two are the devices; the band renders the strip's program.
_PREVIEW_LED_COUNTS = (2, 8)


def preview_fleet(controller: Any, args: dict[str, Any]) -> dict[str, Any]:
    """A blend mode played against a synthetic fleet, before choosing it.

    People pick a blend mode on a single swatch, but the real decision is
    how a mixed desk reads: three agents in three colours turn to mud under
    Smooth on eight LEDs, and read at a glance under Everyone. This renders
    the person's own colours for a canned scenario (``fleet`` by default:
    two working, one done) under any blend mode and cycle speed, compiled
    exactly as the device would play it. A scenario with an ask in it shows
    the same strip under every blend, because an ask takes the strip --
    that is the answer, not a bug. Nothing is written to a device."""
    from . import colors as colors_module
    from .animation import normalize_led_count
    from .presentation_compiler import compile_presentation_program

    scenario = args.get("scenario", colors_module.PREVIEW_SCENARIO_FLEET)
    if scenario not in colors_module.FLEET_PREVIEW_SCENARIOS or scenario == colors_module.PREVIEW_SCENARIO_LIVE:
        raise _command_error("invalid_args", "scenario must name a preview scenario (fleet, pair, busy_team, ...)")
    led_count = args.get("led_count", 8)
    if isinstance(led_count, bool) or led_count not in _PREVIEW_LED_COUNTS:
        raise _command_error("invalid_args", "led_count must be 2 or 8")
    led_count = normalize_led_count(led_count)
    settings = getattr(controller, "settings", None)
    palette = getattr(settings, "colors", None)
    if not isinstance(palette, colors_module.ColorSettings):
        palette = colors_module.ColorSettings.defaults()
    device = args.get("device")
    if device is not None and (type(device) is not str or not device.strip()):
        raise _command_error("invalid_args", "device must be a nonempty string")
    blend = args.get("blend_mode")
    if blend is None and device is not None:
        lookup = getattr(settings, "device_blend_mode", None)
        blend = lookup(device.strip()) if callable(lookup) else None
    if blend is not None:
        if blend not in colors_module.BLEND_MODE_CHOICES:
            raise _command_error("invalid_args", "unknown blend mode")
        palette = palette.with_blend_mode(blend)
    speed = args.get("cycle_speed_seconds")
    if speed is not None:
        if isinstance(speed, bool) or not isinstance(speed, (int, float)):
            raise _command_error("invalid_args", "cycle_speed_seconds must be a number")
        # The speed asked for is the speed this mode plays at, even where
        # the person gave the mode its own override.
        palette = palette.with_cycle_speed(float(speed))
        if palette.blend_mode in colors_module.SPEED_OVERRIDE_MODES:
            palette = palette.with_global_speed_for_mode(palette.blend_mode)
    statuses = colors_module.preview_statuses_for_scenario(scenario)
    _state, source = colors_module.program_for_snapshot(statuses, led_count=led_count, colors=palette)
    compiled = compile_presentation_program(source, led_count=led_count)
    return {
        "scenario": scenario,
        "label": colors_module.PREVIEW_SCENARIO_LABELS[scenario],
        "blend_mode": palette.blend_mode,
        "cycle_speed_seconds": palette.effective_speed_seconds(palette.blend_mode),
        "led_count": led_count,
        "program": compiled.program,
        "transformed": bool(compiled.transformed),
        "agents": [{"provider": status.provider, "mode": status.mode.value} for status in statuses],
    }


# --- auto-dim that learns from the slider ------------------------------------------------


def note_brightness_nudge(controller: Any, value: float, *, now: float | None = None) -> None:
    """A panel slider move is a vote for how bright the lights should be
    at the light the sensor reads right now -- counted only while auto-dim
    follows the ambient sensor and the sensor answered (jrbar.auto_dim)."""
    import time

    from .auto_dim import BrightnessVote, record_vote

    base = max(0.0, min(1.0, float(value)))
    controller._core_brightness_base = base
    reader = getattr(controller, "auto_dim_result", None)
    if not callable(reader):
        return
    result = reader()
    if (
        getattr(result, "mode", None) != "ambient"
        or getattr(result, "source", None) != "ambient"
        or not getattr(result, "available", False)
        or not isinstance(getattr(result, "reading", None), (int, float))
    ):
        return
    vote = BrightnessVote(
        lux=float(result.reading),
        level=base * float(getattr(result, "factor", 1.0)),
        at=time.time() if now is None else float(now),
    )
    controller._core_brightness_votes = record_vote(tuple(getattr(controller, "_core_brightness_votes", ())), vote)


def auto_dim_learning(controller: Any, args: dict[str, Any]) -> dict[str, Any]:
    """What the slider has taught the ambient curve: the votes kept since
    the daemon started and, once there are enough across enough light, the
    floor, ceiling, minimum and slider level that explain them -- offered,
    never applied (the app applies it with set_setting and set_brightness
    when the person says so). ``clear: true`` forgets the votes."""
    from .auto_dim import AutoDimSettings, learn_ambient_curve

    clear = args.get("clear", False)
    if type(clear) is not bool:
        raise _command_error("invalid_args", "clear must be a boolean")
    if clear:
        controller._core_brightness_votes = ()
    votes = tuple(getattr(controller, "_core_brightness_votes", ()))
    current = getattr(getattr(controller, "settings", None), "auto_dim", None)
    if not isinstance(current, AutoDimSettings):
        current = AutoDimSettings()
    document = learn_ambient_curve(
        votes,
        current,
        current_base=float(getattr(controller, "_core_brightness_base", 1.0)),
    )
    document["mode"] = current.mode
    document["samples"] = [
        {"lux": round(vote.lux, 1), "level": round(vote.level, 3), "at": vote.at} for vote in votes
    ]
    return document


# --- write health --------------------------------------------------------------------------


def augment_device_health(document: dict[str, Any]) -> None:
    """``state.devices[].write_health`` for every device with a volume:
    the last write's latency, how many programs the safety compiler had to
    change, how many never reached the device and why (jrbar.write_health)."""
    from . import write_health

    for device in document.get("devices") or ():
        if isinstance(device, dict) and isinstance(device.get("path"), str):
            health = write_health.health_document(device["path"])
            if health is not None:
                device["write_health"] = health


# --- colour vision ---------------------------------------------------------------------------

_MAX_CANDIDATE_COLORS = 64


def check_palette(controller: Any, args: dict[str, Any]) -> dict[str, Any]:
    """Which of the person's colours read as one light for a colourblind
    viewer, and the smallest nudge that pulls each pair apart
    (``colors.check_palette``). ``colors`` previews an edit before it is
    saved: ``{"agent:claude": "#hex", "state:ask": "#hex"}`` on top of the
    saved palette. Nothing is written."""
    from . import colors as colors_module
    from .providers import PROVIDER_SPECS

    settings = getattr(controller, "settings", None)
    saved = getattr(settings, "colors", None)
    if not isinstance(saved, colors_module.ColorSettings):
        saved = colors_module.ColorSettings.defaults()
    providers = tuple(spec.provider for spec in PROVIDER_SPECS)
    palette = colors_module.palette_colors(saved, providers)
    shipped = colors_module.palette_colors(colors_module.ColorSettings.defaults(), providers)
    candidate = args.get("colors") or {}
    if not isinstance(candidate, dict) or len(candidate) > _MAX_CANDIDATE_COLORS:
        raise _command_error("invalid_args", "colors must map agent:<id> or state:<key> to a hex colour")
    for key, value in candidate.items():
        if key not in palette:
            raise _command_error("invalid_args", f"unknown colour {str(key)[:64]!r}")
        if not isinstance(value, str) or colors_module.normalize_hex(value, "") != value.upper():
            raise _command_error("invalid_args", f"{key} must be a #RRGGBB colour")
        palette[key] = value.upper()
    visions = args.get("visions", list(colors_module.DICHROMACY_VISIONS))
    if (
        not isinstance(visions, list)
        or not visions
        or any(vision not in colors_module.VISION_MODELS for vision in visions)
    ):
        raise _command_error("invalid_args", "visions must list normal, deuteranopia, protanopia or tritanopia")
    pairs = colors_module.check_palette(palette, shipped=shipped, visions=tuple(dict.fromkeys(visions)))
    return {
        "min_separation": colors_module.MIN_VISION_SEPARATION_DE,
        "visions": list(dict.fromkeys(visions)),
        "checked": len(palette),
        "pairs": pairs,
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
    "augment_device_health",
    "augment_lights_cues",
    "auto_dim_learning",
    "burn_init",
    "calibration_profile",
    "check_palette",
    "list_cues",
    "list_focuses",
    "list_light_log",
    "note_brightness_nudge",
    "preview_fleet",
    "set_cue",
]
