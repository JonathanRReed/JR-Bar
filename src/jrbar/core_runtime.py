"""``python -m jrbar core``: the production controller, headless, behind
the protocol-1 socket (docs/CORE-PROTOCOL.md).

The controller class is the same one the menu-bar app runs
(``application_composition.compose_status_bar_application``); this module
subclasses its final form and

* skips every AppKit surface in ``applicationDidFinishLaunching_`` (status
  item, menus, hotkeys, windows, the Screen Bar window) while keeping the
  timers, hook ingress, event and cloud sockets, device writers, power
  holds, calendar and remote peers;
* taps the emission seams (``refresh_``, ``record_activity_entries``,
  ``apply_escalation``, ``_dnd_projection_changed``,
  ``sync_virtual_status_device``, ``_apply_hardware_write_result``) to
  publish ``state`` / ``lights`` / ``event`` frames;
* turns ``settings`` into a property with a generation so every save,
  from any code path, republishes the ``settings`` document;
* answers protocol commands on the main thread (the socket thread hands
  each one over with ``performSelectorOnMainThread``).

Everything AppKit is imported lazily so importing this module stays inert.
"""

from __future__ import annotations

import argparse
import json
import os
import signal
import subprocess
import sys
import threading
import time
import traceback
from collections.abc import Callable
from dataclasses import dataclass
from pathlib import Path
from typing import Any, Final

from .core_projection import (
    TERMINAL_BUNDLE_IDS,
    DeviceFacts,
    EscalationFacts,
    LightFacts,
    PowerFacts,
    SessionExtras,
    SurfaceFacts,
    build_lights_document,
    build_settings_document,
    build_state_document,
    history_rows,
    light_why,
    origin_document,
    terminal_from_command,
    why_detail,
    why_for_glance,
)
from .core_server import CommandError, CoreServer, default_core_socket_path
from .hook_pending import PendingHookDrainer, pending_hook_files
from .state_paths import default_state_dir

CORE_VERSION: Final = "0.8.0"
HOUSEKEEPING_SECONDS: Final = 1.0
SUPERVISION_SECONDS: Final = 2.0
EXTRAS_TTL_SECONDS: Final = 30.0
MAX_EXTRA_LOOKUPS_PER_BUILD: Final = 6
PREVIEW_MAX_SECONDS: Final = 30.0
LEGACY_WINDOWS: Final = {
    "settings": "show_settings_window",
    "setup": "show_setup_window",
    "agent_browser": "openAgentBrowser_",
    "effect_studio": "openEffectStudio_",
    "usage_center": "openProviderUsageCenter_",
    "control_center": "openDeckControlCenter_",
    "why": "openWhyPanel_",
}
_APP_OWNED_DIAGNOSTICS: Final = frozenset({"alcove_follow_state"})
_HEALTHY_DIAGNOSTIC_CODES: Final = frozenset(
    {
        "source_checkout",
        "installed_package",
        "packaged_bundle",
        "not_applicable",
        "verified",
        "installed",
        "private",
        "configured",
        "healthy",
        "bounded",
        "connected",
    }
)


def _running_commit() -> str | None:
    """The commit this daemon runs: ``JRBAR_COMMIT`` from an installed
    deployment (scripts/install-agents.sh), else the checkout's HEAD."""
    explicit = os.environ.get("JRBAR_COMMIT")
    if explicit:
        return explicit
    root = Path(__file__).resolve().parents[2]
    if not (root / ".git").exists():
        return None
    try:
        completed = subprocess.run(
            ["git", "-C", str(root), "rev-parse", "HEAD"],
            check=False, stdout=subprocess.PIPE, stderr=subprocess.DEVNULL, text=True, timeout=2.0,
        )
    except (OSError, subprocess.SubprocessError):
        return None
    value = completed.stdout.strip()
    return value or None


def mono_to_epoch(value: object) -> float | None:
    """A ``time.monotonic()`` reading as wall-clock epoch seconds."""
    if value is None or isinstance(value, bool) or not isinstance(value, (int, float)):
        return None
    return time.time() + (float(value) - time.monotonic())


def split_path(path: str) -> list[str | int]:
    parts: list[str | int] = []
    for piece in str(path).split("."):
        if not piece:
            continue
        parts.append(int(piece) if piece.isdigit() else piece)
    return parts


def get_path(root: Any, path: str) -> tuple[Any, bool]:
    node = root
    for part in split_path(path):
        if isinstance(part, int):
            if not isinstance(node, list) or not 0 <= part < len(node):
                return None, False
            node = node[part]
        else:
            if not isinstance(node, dict) or part not in node:
                return None, False
            node = node[part]
    return node, True


def set_path(root: Any, path: str, value: Any) -> bool:
    parts = split_path(path)
    if not parts:
        return False
    node = root
    for part in parts[:-1]:
        if isinstance(part, int):
            if not isinstance(node, list) or not 0 <= part < len(node):
                return False
            node = node[part]
        else:
            if not isinstance(node, dict):
                return False
            node = node.setdefault(part, {})
    leaf = parts[-1]
    if isinstance(leaf, int):
        if not isinstance(node, list) or not 0 <= leaf < len(node):
            return False
        node[leaf] = value
        return True
    if not isinstance(node, dict):
        return False
    node[leaf] = value
    return True


def screen_bar_anchor(own: float | None, hardware: float | None, *, linked: bool) -> float | None:
    """The Screen Bar's playback anchor. Linked to a strip it follows the
    strip's write-completion moment: the strip loops from there and never
    re-anchors on a Screen Bar re-sync, so the bar must not either."""
    if linked and hardware is not None:
        return hardware
    return own


def device_transitions(
    previous: dict[str, bool] | None, devices: list[Any]
) -> tuple[dict[str, bool], list[tuple[str, str, str]]]:
    """(connected-by-name, [(event kind, name, device id)]) for one refresh.

    Keyed by name: a device's id moves from its mount path to its firmware
    serial once STATUS.TXT is read, and that is not a disconnect/connect
    pair. The first refresh (``previous`` None) reports nothing.
    """
    connected: dict[str, bool] = {}
    ids: dict[str, str] = {}
    for device in devices:
        name = str(getattr(device, "name", "") or getattr(device, "device_id", ""))
        connected[name] = connected.get(name, False) or bool(getattr(device, "connected", False))
        if getattr(device, "connected", False) or name not in ids:
            ids[name] = str(getattr(device, "device_id", name))
    events: list[tuple[str, str, str]] = []
    if previous is not None:
        for name, is_connected in connected.items():
            if is_connected and not previous.get(name, False):
                events.append(("device_connected", name, ids.get(name, name)))
        for name, was_connected in previous.items():
            if was_connected and not connected.get(name, False):
                events.append(("device_disconnected", name, ids.get(name, name)))
    return connected, events


def settings_from_document(document: dict[str, Any], *, scratch_dir: Path | None = None):
    """Round a settings dict through the real loader (validation, defaults)."""
    from . import _settings_legacy as settings_legacy

    scratch = (scratch_dir or default_state_dir()) / "core-tmp"
    scratch.mkdir(parents=True, exist_ok=True, mode=0o700)
    try:
        os.chmod(scratch, 0o700)
    except OSError:
        pass
    target = scratch / f"settings-{os.getpid()}-{threading.get_ident()}.json"
    fd = os.open(target, os.O_WRONLY | os.O_CREAT | os.O_TRUNC, 0o600)
    try:
        with os.fdopen(fd, "w", encoding="utf-8") as handle:
            json.dump(document, handle)
        return settings_legacy.load_settings(target)
    finally:
        try:
            target.unlink()
        except OSError:
            pass


class HeadlessNotificationClient:
    """Stands in for ``MacOSNotificationClient``: the app delivers banners."""

    available = False
    last_diagnostic = "headless"

    def authorization_state(self):
        from .macos_notifications import NotificationAuthorizationState

        return NotificationAuthorizationState.UNAVAILABLE

    def set_delegate(self, _delegate) -> bool:
        return False

    def request_authorization(self, _completed) -> bool:
        return False

    def deliver(self, _identifier, _title, _body, _user_info) -> bool:
        return False

    def wait_idle(self, *, timeout_seconds: float) -> bool:
        return True

    def close(self, *, timeout_seconds: float) -> bool:
        return True


class CoreCommandBox:
    """One command crossing from the socket thread to the main thread."""

    __slots__ = ("args", "error", "name", "result")

    def __init__(self, name: str, args: dict[str, Any]) -> None:
        self.name = name
        self.args = args
        self.result: Any = None
        self.error: CommandError | None = None


@dataclass(slots=True)
class _Preview:
    program: str
    until_monotonic: float
    started_epoch: float
    device_ids: tuple[str, ...]


@dataclass(frozen=True, slots=True)
class CommandSpec:
    handler: Callable[[Any, dict[str, Any]], Any]
    main_thread: bool = True


_CLASS_CACHE: dict[type, type] = {}
_MAIN_THREAD_COMMANDS: dict[str, CommandSpec] = {}
# Tests replace these; production resolves them lazily from Foundation/AppKit.
NSTimer: Any = None
NSApp: Any = None


def _timer_api():
    if NSTimer is not None:
        return NSTimer
    from Foundation import NSTimer as timer

    return timer


def _application():
    if NSApp is not None:
        return NSApp
    from AppKit import NSApp as application

    return application


def _schedule_timer(interval: float, target, selector: str, repeats: bool):
    return _timer_api().scheduledTimerWithTimeInterval_target_selector_userInfo_repeats_(
        interval, target, selector, None, repeats
    )


def command(name: str, *, main_thread: bool = True):
    def register(function):
        _MAIN_THREAD_COMMANDS[name] = CommandSpec(function, main_thread)
        return function

    return register


def command_names() -> tuple[str, ...]:
    return tuple(sorted(_MAIN_THREAD_COMMANDS))


# --- command handlers (self is the headless controller) ----------------------


def _find_status(self, session: object):
    if not isinstance(session, str) or not session:
        raise CommandError("invalid_args", "session is required")
    snapshot = getattr(self, "last_snapshot", None)
    if snapshot is None:
        raise CommandError("not_found", "no snapshot yet")
    for status in (*snapshot.statuses, *getattr(snapshot, "stale_statuses", ())):
        if status.agent_id == session:
            return status
    raise CommandError("not_found", "no such session")


@command("open_session")
def _cmd_open_session(self, args):
    status = _find_status(self, args.get("session"))
    self.open_session(status, args.get("action") if isinstance(args.get("action"), str) else None, remember=False)
    extras = self._core_extras_for(status)
    return {
        "session": status.agent_id,
        "activated": (extras.terminal or {}).get("app") if extras is not None else None,
        "origin": extras.origin if extras is not None else None,
    }


@command("answer_ask")
def _cmd_answer_ask(self, args):
    from .announcer_stack import announcer_alert_identity
    from .answer_controller import AnswerBrowserCommand
    from .answer_in_place import AnswerActionKind

    status = _find_status(self, args.get("session"))
    decision = str(args.get("decision") or "approve").lower()
    if decision not in ("approve", "deny"):
        raise CommandError("invalid_args", "decision must be approve or deny")
    state = getattr(self, "current_operator_state", None)
    work_key = getattr(status, "work_key", None)
    request = None
    if state is not None and work_key is not None:
        for candidate in state.requests:
            if candidate.key.work_key == work_key and candidate.phase.value.startswith("live"):
                request = candidate
                break
    if request is None:
        raise CommandError("not_found", "no live ask for that session")
    if bool(args.get("only_if_frontmost", True)):
        frontmost = self._core_frontmost_bundle_id()
        expected = self._core_session_bundle_ids(status)
        if frontmost is None or (expected and frontmost not in expected) or (
            not expected and frontmost not in TERMINAL_BUNDLE_IDS
        ):
            raise CommandError("not_frontmost", "the session's terminal is not in front")
    command_payload = AnswerBrowserCommand(
        work_key=work_key,
        generation=state.generation,
        request_identity=announcer_alert_identity(request.key),
        action=AnswerActionKind.APPROVE if decision == "approve" else AnswerActionKind.DENY,
        reply_text=None,
    )
    snapshot = self.last_snapshot
    accepted = self.answer_controller.perform_browser_answer(
        command_payload, state, tuple(snapshot.statuses)
    )
    if not accepted:
        raise CommandError("unsupported", "this ask cannot be answered from here")
    self.refresh_(None)
    return {"session": status.agent_id, "decision": decision, "answered": True}


@command("snooze")
def _cmd_snooze(self, args):
    from .agent_browser_window import AgentBrowserActionPayload
    from .navigation_policy import OperatorActionKind

    seconds = float(args.get("seconds") or 0)
    session = args.get("session") or "all"
    state = getattr(self, "current_operator_state", None)
    if state is None:
        raise CommandError("not_found", "no operator state yet")
    if session == "all":
        targets = list(self._core_ask_statuses())
    else:
        targets = [_find_status(self, session)]
    applied: list[str] = []
    for status in targets:
        work_key = getattr(status, "work_key", None)
        if work_key is None:
            continue
        if seconds <= 0:
            payload = AgentBrowserActionPayload(work_key, state.generation, OperatorActionKind.UNSNOOZE)
        else:
            preset = "15-minutes" if seconds <= 900 else "1-hour" if seconds <= 3600 else "tomorrow"
            payload = AgentBrowserActionPayload(
                work_key, state.generation, OperatorActionKind.SNOOZE, snooze_preset=preset
            )
        try:
            if self._apply_preference_action(payload):
                applied.append(status.agent_id)
        except Exception as exc:
            self._core_log(f"snooze failed for {status.agent_id}: {exc}")
    self.refresh_(None)
    return {"sessions": applied, "until": (time.time() + seconds) if seconds > 0 else None}


@command("clear_completed")
def _cmd_clear_completed(self, args):
    import secrets

    from .clear_agents import ClearAgentsPlanError, plan_clear_agents_commit

    legacy = self._core_legacy()
    snapshot = getattr(self, "last_snapshot", None)
    if snapshot is None:
        raise CommandError("not_found", "no snapshot yet")
    if getattr(self, "_clear_agents_operation_pending", False):
        raise CommandError("busy", "a clear is already in flight")
    try:
        preview = legacy.clear_agents_preview(snapshot, self)
        if preview.clearable_count <= 0:
            return {"batch": None, "cleared": []}
        plan = plan_clear_agents_commit(
            preview,
            preview,
            self.clear_agents_state,
            batch_id=secrets.token_hex(16),
            committed_at_epoch=time.time(),
        )
    except ClearAgentsPlanError as error:
        raise CommandError("refused", str(getattr(error, "reason", error))) from error
    except (TypeError, ValueError) as error:
        raise CommandError("internal", str(error)) from error
    self._clear_agents_preview = preview
    self._submit_clear_agents_plan("commit", plan)
    cleared = [
        getattr(getattr(item, "key", None), "agent_id", None) or getattr(item, "label", None)
        for item in getattr(preview, "items", ())
    ]
    self._core_last_clear_batch = plan.batch_receipt.batch_id
    return {"batch": plan.batch_receipt.batch_id, "cleared": [item for item in cleared if item]}


@command("undo_clear")
def _cmd_undo_clear(self, args):
    from .clear_agents import ClearAgentsCommitPlan, ClearAgentsPlanError, plan_clear_agents_undo

    batch = str(args.get("batch") or getattr(self, "_core_last_clear_batch", "") or "")
    commit_plan = getattr(self, "_clear_agents_commit_plan", None)
    if type(commit_plan) is not ClearAgentsCommitPlan or commit_plan.batch_receipt.batch_id != batch:
        raise CommandError("not_found", "no such batch")
    try:
        plan = plan_clear_agents_undo(self.clear_agents_state, batch_id=batch, now_epoch=time.time())
    except ClearAgentsPlanError as error:
        reason = getattr(getattr(error, "reason", None), "value", "refused")
        raise CommandError("expired" if reason == "expired" else "refused", str(reason)) from error
    self._submit_clear_agents_plan("undo", plan)
    return {"batch": batch, "restored": []}


def _apply_settings_document(self, document: dict[str, Any], *, touched: list[str]) -> int:
    legacy = self._core_legacy()
    try:
        candidate = settings_from_document(document)
    except Exception as error:
        raise CommandError("invalid_value", f"settings did not validate: {error}") from error
    self.settings = candidate
    try:
        legacy.save_settings(self.settings)
    except Exception as error:
        self.settings = legacy.load_settings()
        raise CommandError("refused", f"could not save settings: {error}") from error
    self._core_after_settings_change(touched)
    return self._core_settings_generation


@command("set_setting")
def _cmd_set_setting(self, args):
    path = str(args.get("path") or "")
    if not path:
        raise CommandError("invalid_path", "path is required")
    document = self.settings.to_dict()
    _current, exists = get_path(document, path)
    if not exists and not isinstance(get_path(document, ".".join(str(p) for p in split_path(path)[:-1]))[0], dict):
        raise CommandError("invalid_path", f"cannot write {path!r}")
    if not set_path(document, path, args.get("value")):
        raise CommandError("invalid_path", f"cannot write {path!r}")
    generation = _apply_settings_document(self, document, touched=[path])
    value, _ = get_path(self.settings.to_dict(), path)
    return {"generation": generation, "path": path, "value": value}


@command("reset_settings")
def _cmd_reset_settings(self, args):
    from ._settings_legacy import AgentMonitorSettings

    paths = [str(path) for path in (args.get("paths") or []) if isinstance(path, str)]
    defaults = AgentMonitorSettings().to_dict()
    document = self.settings.to_dict()
    reset: list[str] = []
    for path in paths:
        value, found = get_path(defaults, path)
        if found and set_path(document, path, json.loads(json.dumps(value))):
            reset.append(path)
    generation = _apply_settings_document(self, document, touched=reset) if reset else self._core_settings_generation
    return {"generation": generation, "reset": reset}


@command("set_brightness")
def _cmd_set_brightness(self, args):
    target = args.get("device") or "all"
    try:
        value = float(args.get("value"))
    except (TypeError, ValueError) as error:
        raise CommandError("invalid_args", "value must be a number") from error
    value = max(0.0, min(1.0, value))
    devices = [
        device
        for device in self.status_bar_devices(remember=False)
        if target == "all" or device.device_id == target
    ]
    if not devices:
        raise CommandError("not_found", "no such device")
    for device in devices:
        self.set_device_brightness(device.device_id, value * 255.0)
    self._core_publish_lights()
    return {"value": value, "devices": [device.device_id for device in devices]}


@command("set_device_display")
def _cmd_set_device_display(self, args):
    legacy = self._core_legacy()
    device = args.get("device")
    mode = str(args.get("mode") or "agent")
    if mode not in legacy.LED_DISPLAY_CHOICES:
        raise CommandError("invalid_args", f"unknown display mode {mode!r}")
    if not isinstance(device, str) or not device:
        raise CommandError("invalid_args", "device is required")
    self.set_device_display(device, mode)
    return {"device": device, "mode": mode}


@command("apply_calibration")
def _cmd_apply_calibration(self, args):
    device = args.get("device")
    profile = args.get("profile") or {}
    if not isinstance(device, str) or not device or not isinstance(profile, dict):
        raise CommandError("invalid_args", "device and profile are required")
    known = {entry.device_id for entry in self.settings.devices} | {
        entry.device_id for entry in self.status_bar_devices(remember=False)
    }
    if device not in known:
        raise CommandError("not_found", "no such device")
    settings = self.settings
    applied: dict[str, float] = {}
    for channel in ("red", "green", "blue"):
        key = f"{channel}_gain"
        if key in profile:
            settings = settings.with_device_channel_gain(device, channel, float(profile[key]))
            applied[key] = float(profile[key])
    if "resting_glow" in profile:
        settings = settings.with_device_resting_glow(device, float(profile["resting_glow"]))
        applied["resting_glow"] = float(profile["resting_glow"])
    self.settings = settings
    self._core_legacy().save_settings(self.settings)
    self._core_after_settings_change(["devices"])
    return {"device": device, "profile": applied, "generation": self._core_settings_generation}


@command("preview_program")
def _cmd_preview_program(self, args):
    from ._led_status_legacy import LedDisplayState, led_count_for_target

    legacy = self._core_legacy()
    surface = str(args.get("surface") or "screen_bar")
    program = args.get("program")
    if not isinstance(program, str) or not program.strip():
        raise CommandError("invalid_args", "program is required")
    try:
        seconds = float(args.get("seconds", 3.0))
    except (TypeError, ValueError) as error:
        raise CommandError("invalid_args", "seconds must be a number") from error
    seconds = max(0.2, min(PREVIEW_MAX_SECONDS, seconds))
    wanted_leds = {"hardware": 8, "dot": 2}.get(surface)
    device_ids: list[str] = []
    for device in self.status_bar_devices(remember=False):
        if not device.connected or device.device_id == legacy.VIRTUAL_DEVICE_ID:
            continue
        leds = led_count_for_target(device.target)
        if surface == device.device_id or (wanted_leds is not None and leds == wanted_leds):
            controller = self.agent_controller_for_device(device)
            try:
                controller.sync_program(legacy.apply_brightness(program, controller.brightness), LedDisplayState.ASK)
            except Exception as exc:
                raise CommandError("refused", f"device refused the program: {exc}") from exc
            device_ids.append(device.device_id)
    if surface not in ("screen_bar",) and not device_ids:
        raise CommandError("not_found", "no such surface")
    self._core_previews[surface] = _Preview(program, time.monotonic() + seconds, time.time(), tuple(device_ids))
    self._core_publish_lights()
    return {"surface": surface, "until": time.time() + seconds, "devices": device_ids}


@command("apply_effect")
def _cmd_apply_effect(self, args):
    from .effect_assignment_store import (
        EffectAssignmentRecord,
        EffectAssignmentStoreError,
        default_effect_assignment_path,
        save_effect_assignments,
    )

    cache = getattr(type(self), "_effect_assignment_cache", None)
    if cache is None:
        raise CommandError("unsupported", "effect assignments are unavailable")
    effect = args.get("effect")
    scope = args.get("scope") or "global"
    target = args.get("target")
    try:
        document = cache.snapshot()
        if effect in (None, "", "none"):
            from .effect_studio import AssignmentScope

            document = document.without_assignment(AssignmentScope(str(scope)), target)
        else:
            record = EffectAssignmentRecord.create(effect, scope, target, registry=cache.registry())
            document = document.with_assignment(record)
        save_effect_assignments(default_effect_assignment_path(), document)
        cache.replace(document)
    except (EffectAssignmentStoreError, TypeError, ValueError) as error:
        raise CommandError("invalid_args", str(error)) from error
    self.refresh_(None)
    return {
        "effect": effect,
        "scope": scope,
        "target": target,
        "assignments": [
            {"effect": item.effect_id, "scope": item.scope.value, "target": item.target_id}
            for item in document.assignments
        ],
    }


def _jsonable(value: Any) -> Any:
    if isinstance(value, tuple):
        return [_jsonable(item) for item in value]
    if isinstance(value, list):
        return [_jsonable(item) for item in value]
    if isinstance(value, dict):
        return {str(key): _jsonable(item) for key, item in value.items()}
    return value


def _effects_cache(self):
    cache = getattr(type(self), "_effect_assignment_cache", None)
    if cache is None:
        raise CommandError("unsupported", "effect assignments are unavailable")
    return cache


def _effect_packs(self) -> tuple:
    from .effect_pack_store import EffectPackStore

    try:
        return tuple(EffectPackStore().list())
    except Exception as exc:
        self._core_log(f"core: effect packs unavailable: {exc.__class__.__name__}")
        return ()


def _effect_catalog(self) -> dict[str, Any]:
    from . import core_effects

    cache = _effects_cache(self)
    packs = _effect_packs(self)
    paths = {pack.pack_id: str(getattr(self, "_core_pack_paths", {}).get(pack.pack_id, "")) or None for pack in packs}
    return _jsonable(
        core_effects.catalog_document(
            cache.registry(),
            packs,
            generation=cache.generation,
            pack_paths={key: value for key, value in paths.items() if value},
        )
    )


def _assignments_document(self) -> dict[str, Any]:
    from . import core_effects

    cache = _effects_cache(self)
    return core_effects.assignment_document(
        cache.snapshot(),
        parameters=core_effects.load_assignment_parameters(),
        active_scene=getattr(self.settings, "active_scene", None),
        generation=cache.generation,
    )


def _require_effect(self, effect_id: object):
    cache = _effects_cache(self)
    if not isinstance(effect_id, str) or not effect_id:
        raise CommandError("unknown_effect", "effect_id is required")
    effect = cache.registry().get(effect_id)
    if effect is None:
        raise CommandError("unknown_effect", f"no such effect: {effect_id}")
    return effect


@command("list_effects", main_thread=False)
def _cmd_list_effects(self, args):
    return _effect_catalog(self)


@command("render_effect", main_thread=False)
def _cmd_render_effect(self, args):
    from . import core_effects

    effect = _require_effect(self, args.get("effect_id"))
    try:
        led_count = int(args.get("led_count") or 8)
    except (TypeError, ValueError) as error:
        raise CommandError("invalid_args", "led_count must be a number") from error
    pack_effect = core_effects.pack_effect_for(_effect_packs(self), effect.identifier)
    parameters = core_effects.normalize_parameters(effect, args.get("parameters"), pack_effect=pack_effect)
    color = args.get("color") if isinstance(args.get("color"), str) else None
    try:
        program = core_effects.render_effect(effect, parameters, led_count=led_count, color=color)
    except Exception as error:
        raise CommandError("internal", f"render failed: {error.__class__.__name__}") from error
    return {
        "effect_id": effect.identifier,
        "program": program,
        "led_count": max(2, min(8, led_count)),
        "parameters": _jsonable(parameters),
        "cadence": core_effects.effect_cadence(effect, parameters),
    }


@command("list_assignments", main_thread=False)
def _cmd_list_assignments(self, args):
    return _assignments_document(self)


def _assignment_scope(value: object):
    from .effect_studio import AssignmentScope

    try:
        return AssignmentScope(str(value or ""))
    except ValueError as error:
        raise CommandError("invalid_scope", "unknown assignment scope") from error


def _save_assignments(self, document) -> None:
    from .effect_assignment_store import (
        EffectAssignmentStoreError,
        default_effect_assignment_path,
        save_effect_assignments,
    )

    cache = _effects_cache(self)
    try:
        save_effect_assignments(default_effect_assignment_path(), document)
    except (EffectAssignmentStoreError, OSError) as error:
        raise CommandError("refused", f"could not save assignments: {error}") from error
    cache.replace(document)
    self.refresh_(None)


@command("set_assignment")
def _cmd_set_assignment(self, args):
    from . import core_effects
    from .effect_assignment_store import EffectAssignmentRecord, EffectAssignmentStoreError
    from .effect_studio import AssignmentScope, EffectStudioError, plan_assignment

    effect = _require_effect(self, args.get("effect_id"))
    scope = _assignment_scope(args.get("scope"))
    target = args.get("target_id")
    target = str(target).strip() if target is not None else None
    if target == "":
        target = None
    if scope is AssignmentScope.SEMANTIC and target in ("asking", "failure") and effect.identifier != "alert":
        raise CommandError("reserved_semantic", "asking and failure keep their reserved effects")
    cache = _effects_cache(self)
    try:
        plan = plan_assignment(effect.identifier, scope, target, cache.registry())
        record = EffectAssignmentRecord(plan.effect_id, plan.scope, plan.target_id)
        document = cache.snapshot().with_assignment(record)
    except (EffectStudioError, EffectAssignmentStoreError, TypeError, ValueError) as error:
        raise CommandError("invalid_target", str(error)) from error
    _save_assignments(self, document)
    pack_effect = core_effects.pack_effect_for(_effect_packs(self), effect.identifier)
    parameters = _jsonable(core_effects.normalize_parameters(effect, args.get("parameters"), pack_effect=pack_effect))
    table = core_effects.load_assignment_parameters()
    key = core_effects.assignment_key(plan.scope.value, plan.target_id)
    if parameters:
        table[key] = parameters
    else:
        table.pop(key, None)
    try:
        core_effects.save_assignment_parameters(table)
    except OSError as error:
        self._core_log(f"core: assignment parameters not saved: {error}")
    result = _assignments_document(self)
    result["assignment"] = {
        "effect_id": plan.effect_id,
        "scope": plan.scope.value,
        "target_id": plan.target_id,
        "parameters": parameters,
    }
    return result


@command("clear_assignment")
def _cmd_clear_assignment(self, args):
    from . import core_effects

    scope = _assignment_scope(args.get("scope"))
    target = args.get("target_id")
    target = str(target).strip() if target is not None else None
    if target == "":
        target = None
    cache = _effects_cache(self)
    current = cache.snapshot()
    document = current.without_assignment(scope, target)
    removed = len(document.assignments) < len(current.assignments)
    if removed:
        _save_assignments(self, document)
        table = core_effects.load_assignment_parameters()
        if table.pop(core_effects.assignment_key(scope.value, target), None) is not None:
            try:
                core_effects.save_assignment_parameters(table)
            except OSError:
                pass
    result = _assignments_document(self)
    result["removed"] = removed
    return result


def _reload_effect_registry(self) -> None:
    from . import core_effects

    cache = _effects_cache(self)
    cache.replace(cache.snapshot(), registry=core_effects.registry_with_packs(_effect_packs(self)))


@command("import_effect_pack")
def _cmd_import_effect_pack(self, args):
    from .effect_pack_store import EffectPackStore, EffectPackStoreError, PackMutationStatus

    raw = args.get("path")
    if not isinstance(raw, str) or not raw.strip():
        raise CommandError("invalid_args", "path is required")
    path = Path(raw).expanduser()
    try:
        receipt = EffectPackStore().install(path)
    except EffectPackStoreError as error:
        raise CommandError("invalid_pack", str(error)) from error
    except OSError as error:
        raise CommandError("invalid_pack", f"cannot read pack: {error.__class__.__name__}") from error
    if receipt.status is PackMutationStatus.REFUSED:
        code = "conflict" if receipt.reason == "already_installed" else "refused"
        raise CommandError(code, f"pack {receipt.pack_id} refused: {receipt.reason}")
    if not hasattr(self, "_core_pack_paths"):
        self._core_pack_paths = {}
    self._core_pack_paths[receipt.pack_id] = str(path)
    _reload_effect_registry(self)
    self.refresh_(None)
    catalog = _effect_catalog(self)
    pack = next((entry for entry in catalog["packs"] if entry["id"] == receipt.pack_id), None)
    catalog["imported"] = {
        "id": receipt.pack_id,
        "name": pack["name"] if pack else receipt.pack_id,
        "effects": len(pack["effects"]) if pack else 0,
    }
    return catalog


@command("export_effect_pack", main_thread=False)
def _cmd_export_effect_pack(self, args):
    from . import core_effects
    from .effect_packs import MAX_PACK_BYTES, EffectPackError
    from .private_export import write_private_export

    raw = args.get("path")
    if not isinstance(raw, str) or not raw.strip():
        raise CommandError("invalid_args", "path is required")
    path = Path(raw).expanduser()
    ids = [str(item) for item in (args.get("ids") or []) if isinstance(item, str)]
    if not ids:
        raise CommandError("invalid_args", "ids[] is empty")
    name = args.get("name") if isinstance(args.get("name"), str) else None
    cache = _effects_cache(self)
    try:
        payload, encoded = core_effects.build_export_pack(cache.registry(), _effect_packs(self), ids, name=name, path=path)
    except KeyError as error:
        raise CommandError("unknown_effect", f"no such effect: {error.args[0]}") from error
    except (EffectPackError, ValueError) as error:
        raise CommandError("export_failed", str(error)) from error
    try:
        path.parent.mkdir(parents=True, exist_ok=True)
        written = write_private_export(path, encoded, max_bytes=MAX_PACK_BYTES)
    except (OSError, ValueError) as error:
        raise CommandError("export_failed", f"could not write {path}: {error.__class__.__name__}") from error
    return {"path": str(written), "effects": len(payload["effects"]), "bytes": len(encoded), "id": payload["id"]}


_USAGE_SCAN_LOCK = threading.Lock()


@command("usage_history", main_thread=False)
def _cmd_usage_history(self, args):
    from . import core_usage_history

    provider = str(args.get("provider") or "").strip()
    if not provider:
        raise CommandError("not_found", "provider is required")
    range_name = str(args.get("range") or "30d")
    days = core_usage_history.range_days(range_name)
    if days is None:
        raise CommandError("invalid_range", "range must be 7d, 30d, 90d or 365d")
    with self._core_lock:
        state = self._core_documents.get("state") or {}
    account = None
    source_state = None
    for entry in ((state.get("usage") or {}).get("providers") or []):
        if entry.get("id") == provider:
            account = entry.get("account")
            source_state = entry.get("state")
            break
    if account is None and source_state is None and provider not in core_usage_history.SCANNED_PROVIDERS:
        raise CommandError("not_found", f"no usage source for {provider}")
    with _USAGE_SCAN_LOCK:
        try:
            records = core_usage_history.scan_provider_records(provider, days=days)
        except Exception as error:
            self._core_log(f"core: usage history scan failed: {error.__class__.__name__}")
            records = []
    return core_usage_history.usage_history_document(
        records, provider=provider, range_name=range_name, account=account, state=source_state
    )


@command("refresh_usage")
def _cmd_refresh_usage(self, args):
    providers = tuple(p for p in (args.get("providers") or []) if isinstance(p, str))
    self._request_provider_usage(force=True, providers=providers or None)
    return {"requested_at": time.time(), "providers": list(providers)}


def _hooks_command(self, args, *, install: bool):
    from .install import install_provider_hooks, uninstall_provider_hooks

    providers = [p for p in (args.get("providers") or []) if isinstance(p, str) and p]
    if not providers:
        raise CommandError("invalid_args", "providers[] is required")
    results: dict[str, Any] = {}
    changed = False
    for provider in providers:
        try:
            result = install_provider_hooks(provider) if install else uninstall_provider_hooks(provider)
            changed = changed or bool(result.changed)
            results[provider] = {"ok": True, **result.to_dict()}
        except Exception as exc:
            results[provider] = {"ok": False, "error": str(exc)[:500]}
    self.performSelectorOnMainThread_withObject_waitUntilDone_(
        "hooksUpdated:",
        {"ok": True, "changed": changed, "provider": ",".join(providers), "install": install},
        False,
    )
    return {"providers": providers, "results": results}


@command("install_hooks", main_thread=False)
def _cmd_install_hooks(self, args):
    return _hooks_command(self, args, install=True)


@command("uninstall_hooks", main_thread=False)
def _cmd_uninstall_hooks(self, args):
    return _hooks_command(self, args, install=False)


@command("set_closed_lid_policy")
def _cmd_set_closed_lid_policy(self, args):
    legacy = self._core_legacy()
    policy = str(args.get("policy") or "")
    if policy not in legacy.CLOSED_LID_AWAKE_CHOICES:
        raise CommandError("invalid_args", f"unknown policy {policy!r}")
    self.set_closed_lid_awake_policy(policy)
    return {"policy": self.settings.closed_lid_awake_policy}


@command("quiet")
def _cmd_quiet(self, args):
    from .dnd_policy import DndMode

    raw = str(args.get("mode") or "dnd").lower()
    mode = {
        "dnd": DndMode.PAUSE,
        "pause": DndMode.PAUSE,
        "dim": DndMode.DIM,
        "mute": DndMode.MUTE,
        "dark": DndMode.DARK,
        "asks_only": DndMode.ASKS_ONLY,
    }.get(raw)
    if mode is None:
        raise CommandError("invalid_args", f"unknown quiet mode {raw!r}")
    try:
        seconds = float(args.get("seconds", 1800))
    except (TypeError, ValueError) as error:
        raise CommandError("invalid_args", "seconds must be a number") from error
    if seconds <= 0:
        self.endDndOverride_(None)
        self._core_publish_state()
        return {"until": None}
    if not self._set_dnd_for_duration(mode, seconds):
        raise CommandError("refused", "DND override was not applied")
    self._core_publish_state()
    until = getattr(getattr(self.settings, "dnd_override", None), "until_epoch", None)
    return {"until": until if until is not None else time.time() + max(60.0, seconds), "mode": mode.value}


@command("list_history")
def _cmd_list_history(self, args):
    since = args.get("since")
    try:
        limit = int(args.get("limit") or 500)
    except (TypeError, ValueError):
        limit = 500
    ledger = self.ensure_activity_ledger()
    rows = history_rows(ledger, since=float(since) if isinstance(since, (int, float)) else None, limit=limit)
    return {"rows": rows, "total": len(ledger.entries), "last_seen": ledger.last_seen_epoch}


@command("doctor")
def _cmd_doctor(self, args):
    return self._core_doctor_document()


@command("open_legacy_window")
def _cmd_open_legacy_window(self, args):
    name = str(args.get("name") or "")
    selector = LEGACY_WINDOWS.get(name)
    if selector is None:
        raise CommandError("not_found", f"no legacy window named {name!r}")
    method = getattr(self, selector, None)
    if not callable(method):
        raise CommandError("unsupported", f"{name} is unavailable in this build")
    if selector.endswith("_"):
        method(None)
    else:
        method()
    from .window_presentation import activate_app

    try:
        activate_app()
    except Exception:
        pass
    return {"window": name}


@command("quit")
def _cmd_quit(self, args):
    self.performSelector_withObject_afterDelay_("coreQuit:", None, 0.15)
    return {"bye": True}


@command("ping")
def _cmd_ping(self, args):
    return {"pong": True, "now": time.time()}


# --- the headless controller ---------------------------------------------------


def build_headless_controller_class() -> type:
    """Subclass the composed production controller for headless service."""
    import objc
    from AppKit import NSApplicationActivationPolicyAccessory, NSWorkspace

    from . import status_bar_legacy as legacy

    base = legacy.StatusBarController
    cached = _CLASS_CACHE.get(base)
    if cached is not None:
        return cached

    class JRCoreHeadlessController(base):
        headless = True

        # -- settings with a generation --------------------------------------

        @property
        def settings(self):
            return getattr(self, "_core_settings_value", None)

        @settings.setter
        def settings(self, value) -> None:
            self._core_settings_value = value
            self._core_settings_generation = getattr(self, "_core_settings_generation", 0) + 1
            if getattr(self, "_core", None) is not None:
                self._core_publish_settings()

        # -- construction ----------------------------------------------------

        def init(self):
            self = objc.super(JRCoreHeadlessController, self).init()
            if self is None:
                return None
            self.notification_client = HeadlessNotificationClient()
            device = getattr(self, "virtual_status_device", None)
            if device is not None:
                device.headless = True
                device._enabled = False
            self._core = None
            self._core_socket_path = None
            self._core_lock = threading.RLock()
            self._core_documents: dict[str, dict[str, Any]] = {}
            self._core_state_generation = 0
            self._core_hardware_anchor: dict[str, float] = {}
            self._core_previews: dict[str, _Preview] = {}
            self._core_prev_asks: dict[str, Any] | None = None
            self._core_prev_devices: dict[str, bool] | None = None
            self._core_extras: dict[str, tuple[float, SessionExtras]] = {}
            self._core_tty_by_pid: dict[int, str | None] = {}
            self._core_terminal_by_pid: dict[int, dict[str, Any] | None] = {}
            self._core_started_at = time.time()
            self._core_pending_drainer = None
            self._core_last_clear_batch = None
            self._core_housekeeping_timer = None
            self._core_supervision_timer = None
            self._core_last_stage_event = 0
            return self

        # -- launch (the non-hostile half of the production launch) ---------

        def applicationDidFinishLaunching_(self, _notification):
            if getattr(self, "_runtime_started", False) or getattr(self, "_runtime_termination_started", False):
                return None
            try:
                self._core_launch()
            except Exception:
                # AppKit swallows exceptions raised in delegate callbacks; a
                # daemon that came up half-way must say so and stop.
                legacy.log_status_bar(f"core: launch failed: {traceback.format_exc(limit=8)}")
                self._core_stop_server()
                _application().terminate_(self)
                raise

        def _core_launch(self) -> None:
            _application().setActivationPolicy_(NSApplicationActivationPolicyAccessory)
            self.load_operator_local_state()
            self.trim_oversized_state_logs()
            legacy.log_status_bar("core: launching headless")
            self.start_event_server()
            self.start_cloud_ingest_server()
            self.replay_debug_logs()
            self._runtime_started = True
            self._install_dnd_environment_observers()
            self._refresh_dnd_environment("start")
            sys.setswitchinterval(0.001)
            self.refresh_installed_agent_inventory()
            self._install_accessibility_display_observer()
            self.reconcile_lid_observation()
            self._core_start_server()
            self.refresh_(None)
            self.timer = _schedule_timer(legacy.STATUS_BAR_REFRESH_SECONDS, self, "refresh:", True)
            if not hasattr(self.virtual_status_device, "presentation_scheduler_inputs"):
                self.lid_timer = _schedule_timer(legacy.LID_POLL_SECONDS, self, "pollLid:", True)
            self.liveness_timer = _schedule_timer(legacy.LIVENESS_POLL_SECONDS, self, "pollLiveness:", True)
            self.start_remote_peer_timer()
            if self.settings.remote_peers.enabled:
                self.start_remote_peer_refresh()
            threading.Thread(
                target=lambda: legacy.trim_oversized_logs(default_state_dir()), daemon=True
            ).start()
            # The Screen Bar is the app's; the daemon only computes its program.
            self.virtual_status_device.hide()
            self._core_pending_drainer = PendingHookDrainer(
                self._core_submit_pending, log=legacy.log_status_bar
            )
            self._core_pending_drainer.start()
            self._core_housekeeping_timer = _schedule_timer(HOUSEKEEPING_SECONDS, self, "coreHousekeepingTick:", True)
            if os.environ.get("JRBAR_SUPERVISED") == "1":
                self._core_supervision_timer = _schedule_timer(SUPERVISION_SECONDS, self, "coreSupervisionTick:", True)
            legacy.log_status_bar(f"core: ready pid={os.getpid()} socket={self._core.socket_path}")

        def applicationWillTerminate_(self, notification):
            if getattr(self, "_runtime_termination_started", False):
                return None
            self._core_stop_server()
            return objc.super(JRCoreHeadlessController, self).applicationWillTerminate_(notification)

        @objc.IBAction
        def quit_(self, _sender):
            self.closed_lid_awake.release()
            self.keep_awake.release()
            _application().terminate_(self)

        @objc.IBAction
        def coreQuit_(self, _sender):
            self.quit_(None)

        @objc.IBAction
        def coreSupervisionTick_(self, _timer):
            if os.getppid() == 1:
                legacy.log_status_bar("core: supervisor vanished; exiting")
                self.quit_(None)

        @objc.IBAction
        def coreHousekeepingTick_(self, _timer):
            now = time.monotonic()
            expired = [name for name, preview in self._core_previews.items() if preview.until_monotonic <= now]
            for name in expired:
                self._core_previews.pop(name, None)
            if expired:
                self.refresh_(None)
                self._core_publish_lights()

        @objc.IBAction
        def coreClientsChanged_(self, count):
            try:
                clients = int(count)
            except (TypeError, ValueError):
                clients = 0
            legacy.log_status_bar(f"core: clients={clients}")
            if clients == 0:
                # The app went away: from here on, what happens is "while you
                # were away" until it comes back and looks.
                self.mark_activity_seen_now()
            else:
                self._core_publish_state()
                self._core_publish_lights()

        # -- surfaces this controller never has --------------------------------

        def update_status_menu(self, snapshot, state) -> None:
            self._menu_rebuild_pending = None

        def show_setup_window_if_needed(self) -> None:
            return None

        def set_settings_message(self, message: str) -> None:
            if isinstance(message, str) and message:
                legacy.log_status_bar(f"core: {message}")

        def _deliver_semantic_notification(self, event_key, interruption_class, **kwargs) -> bool:
            # Banners are the app's: the ledger and ask events carry the facts.
            return False

        @objc.IBAction
        def hooksUpdated_(self, payload):
            self.hooks_update_in_flight = False
            if not payload.get("ok"):
                legacy.log_status_bar(f"core: hooks failed: {payload.get('error')}")
                return
            self.refresh_intake_report(force=True)
            self.reload_monitor()
            self.refresh_(None)

        # -- emission seams ----------------------------------------------------

        @objc.IBAction
        def refresh_(self, sender):
            previous_asks = self._core_prev_asks
            previous_devices = self._core_prev_devices
            result = objc.super(JRCoreHeadlessController, self).refresh_(sender)
            if getattr(self, "_core", None) is None:
                return result
            asks = {status.agent_id: status for status in self._core_ask_statuses()}
            if previous_asks is not None:
                for agent_id, status in asks.items():
                    if agent_id not in previous_asks:
                        self._core_publish_event(
                            "ask_opened",
                            session=agent_id,
                            provider=status.provider,
                            label=self._core_label(status),
                            detail=status.message or status.tool_name,
                        )
                for agent_id, status in previous_asks.items():
                    if agent_id not in asks:
                        self._core_publish_event(
                            "ask_resolved",
                            session=agent_id,
                            provider=status.provider,
                            label=self._core_label(status),
                        )
            self._core_prev_asks = asks
            devices, transitions = device_transitions(
                previous_devices,
                [d for d in self.status_bar_devices(remember=False) if d.device_id != legacy.VIRTUAL_DEVICE_ID],
            )
            for kind, name, device_id in transitions:
                self._core_publish_event(kind, label=name, detail=device_id)
            self._core_prev_devices = devices
            self._core_publish_state()
            self._core_publish_lights()
            return result

        def record_activity_entries(self, entries) -> None:
            objc.super(JRCoreHeadlessController, self).record_activity_entries(entries)
            if getattr(self, "_core", None) is None:
                return
            for entry in entries or ():
                kind = getattr(getattr(entry, "kind", None), "value", "")
                mapped = {"completed": "completed", "blocked": "failed", "threshold_crossed": "quota_crossed"}.get(kind)
                if mapped is None:
                    continue
                self._core_publish_event(
                    mapped,
                    session=entry.subject_id,
                    provider=entry.provider,
                    label=entry.label,
                    detail=entry.detail,
                    at=entry.occurred_at_epoch,
                )

        def apply_escalation(self, *, allow_refresh: bool = False) -> None:
            previous_stage = getattr(self, "escalation_last_stage", 0)
            previous_chimed = getattr(self, "escalation_chimed", False)
            objc.super(JRCoreHeadlessController, self).apply_escalation(allow_refresh=allow_refresh)
            if getattr(self, "_core", None) is None:
                return
            stage = getattr(self, "escalation_last_stage", 0)
            chimed_now = getattr(self, "escalation_chimed", False) and not previous_chimed
            if stage != previous_stage or chimed_now:
                oldest = self._core_oldest_ask()
                self._core_publish_event(
                    "escalation_stage",
                    session=oldest.agent_id if oldest is not None else None,
                    provider=oldest.provider if oldest is not None else None,
                    label=self._core_label(oldest) if oldest is not None else None,
                    stage=int(stage),
                    sound="glass" if chimed_now else None,
                )
                self._core_publish_state()

        def _dnd_projection_changed(self, projection) -> None:
            objc.super(JRCoreHeadlessController, self)._dnd_projection_changed(projection)
            self._core_publish_state()

        def sync_virtual_status_device(self, *args, **kwargs) -> None:
            objc.super(JRCoreHeadlessController, self).sync_virtual_status_device(*args, **kwargs)
            self._core_publish_lights()

        def _apply_hardware_write_result(self, command, result) -> None:
            objc.super(JRCoreHeadlessController, self)._apply_hardware_write_result(command, result)
            try:
                request = getattr(result, "request", None)
                write = getattr(result, "write", None)
                if request is not None and write is not None and write.changed and write.error is None:
                    anchor = mono_to_epoch(getattr(result, "completed_at", None))
                    if anchor is not None:
                        self._core_hardware_anchor[request.device.device_id] = anchor
            except Exception:
                pass
            self._core_publish_lights()

        # -- server plumbing ---------------------------------------------------

        def _core_legacy(self):
            return legacy

        def _core_log(self, message: str) -> None:
            legacy.log_status_bar(message)

        def _core_start_server(self) -> None:
            server = CoreServer(
                dispatch=self._core_dispatch,
                initial_documents=self._core_initial_documents,
                socket_path=self._core_socket_path or default_core_socket_path(),
                core_version=CORE_VERSION,
                on_client_change=self._core_client_change,
                log=legacy.log_status_bar,
            )
            server.start()
            self._core = server
            self._core_publish_settings()

        def _core_stop_server(self) -> None:
            drainer = self._core_pending_drainer
            self._core_pending_drainer = None
            if drainer is not None:
                drainer.stop()
            for name in ("_core_housekeeping_timer", "_core_supervision_timer"):
                timer = getattr(self, name, None)
                setattr(self, name, None)
                if timer is not None:
                    timer.invalidate()
            server = self._core
            self._core = None
            if server is not None:
                server.stop()

        def _core_client_change(self, count: int) -> None:
            self.performSelectorOnMainThread_withObject_waitUntilDone_("coreClientsChanged:", int(count), False)

        def _core_submit_pending(self, request) -> object:
            from .hook_ingress import AppOwnedHookIngressProcessor

            processor = AppOwnedHookIngressProcessor(self.handle_hook_event_message)
            return processor(request)

        def _core_dispatch(self, name: str, args: dict[str, Any]) -> Any:
            spec = _MAIN_THREAD_COMMANDS.get(name)
            if spec is None:
                raise CommandError("unknown_command", f"no such command: {name}")
            if not spec.main_thread:
                return spec.handler(self, args)
            box = CoreCommandBox(name, args)
            self.performSelectorOnMainThread_withObject_waitUntilDone_("runCoreCommand:", box, True)
            if box.error is not None:
                raise box.error
            return box.result

        @objc.IBAction
        def runCoreCommand_(self, box):
            spec = _MAIN_THREAD_COMMANDS.get(box.name)
            try:
                if spec is None:
                    raise CommandError("unknown_command", f"no such command: {box.name}")
                box.result = spec.handler(self, box.args)
            except CommandError as error:
                box.error = error
            except Exception as error:
                legacy.log_status_bar(f"core: command {box.name} failed: {traceback.format_exc(limit=6)}")
                box.error = CommandError("internal", f"{error.__class__.__name__}: {error}"[:500])

        def _core_initial_documents(self):
            with self._core_lock:
                documents = dict(self._core_documents)
            return [documents[kind] for kind in ("state", "lights", "settings") if kind in documents]

        # -- publishing --------------------------------------------------------

        def _core_publish_state(self) -> None:
            server = getattr(self, "_core", None)
            if server is None:
                return
            try:
                document = self._core_build_state()
            except Exception:
                legacy.log_status_bar(f"core: state projection failed: {traceback.format_exc(limit=6)}")
                return
            with self._core_lock:
                self._core_documents["state"] = document
            server.publish_state(document)

        def _core_publish_lights(self) -> None:
            server = getattr(self, "_core", None)
            if server is None:
                return
            try:
                document = self._core_build_lights()
            except Exception:
                legacy.log_status_bar(f"core: lights projection failed: {traceback.format_exc(limit=6)}")
                return
            with self._core_lock:
                self._core_documents["lights"] = document
            server.publish_lights(document)

        def _core_publish_settings(self) -> None:
            server = getattr(self, "_core", None)
            settings = self.settings
            if server is None or settings is None:
                return
            try:
                document = build_settings_document(settings.to_dict(), generation=self._core_settings_generation)
            except Exception:
                legacy.log_status_bar(f"core: settings projection failed: {traceback.format_exc(limit=6)}")
                return
            with self._core_lock:
                self._core_documents["settings"] = document
            server.publish_settings(document)

        def _core_publish_event(self, kind: str, **fields: Any) -> None:
            server = getattr(self, "_core", None)
            if server is None:
                return
            document = {"kind": kind}
            document.update({key: value for key, value in fields.items() if value is not None})
            server.publish_event(document)

        def _core_after_settings_change(self, touched: list[str]) -> None:
            joined = " ".join(touched)
            try:
                if "closed_lid" in joined:
                    self.sync_closed_lid_awake()
                if "cloud_ingest" in joined:
                    self.start_cloud_ingest_server()
                if "transcript_monitoring" in joined:
                    self.reload_monitor()
                if "remote_peers" in joined and self.settings.remote_peers.enabled:
                    self.start_remote_peer_refresh()
                if "virtual_status_device" in joined or "screen_bar" in joined:
                    self.virtual_status_device.hide()
            except Exception as exc:
                legacy.log_status_bar(f"core: settings side effect failed: {exc}")
            self.refresh_(None)

        # -- facts -------------------------------------------------------------

        def _core_ask_statuses(self):
            projection = getattr(self, "current_attention_projection", None)
            if projection is None:
                return []
            try:
                return legacy.ask_statuses(projection, self.settings)
            except Exception:
                return []

        def _core_oldest_ask(self):
            tracked = getattr(self, "ask_blocked_by_agent", {}) or {}
            if not tracked:
                return None
            oldest_id = min(tracked, key=tracked.get)
            for status in self._core_ask_statuses():
                if status.agent_id == oldest_id:
                    return status
            return None

        @staticmethod
        def _core_label(status) -> str | None:
            if status is None:
                return None
            from .core_projection import strip_session_short_id

            return strip_session_short_id(status.display_name, status.session_id) or status.agent_id

        def _core_frontmost_bundle_id(self) -> str | None:
            try:
                application = NSWorkspace.sharedWorkspace().frontmostApplication()
                value = application.bundleIdentifier() if application is not None else None
            except Exception:
                return None
            return value.strip() if isinstance(value, str) and value.strip() else None

        def _core_session_bundle_ids(self, status) -> frozenset[str]:
            extras = self._core_extras_for(status)
            ids: set[str] = set()
            if extras is not None:
                for block in (extras.terminal, extras.origin):
                    bundle = (block or {}).get("bundle_id")
                    if isinstance(bundle, str) and bundle:
                        ids.add(bundle)
            return frozenset(ids)

        def _core_extras_for(self, status) -> SessionExtras | None:
            cached = self._core_extras.get(status.agent_id)
            if cached is not None and time.monotonic() - cached[0] < EXTRAS_TTL_SECONDS:
                return cached[1]
            extras = self._core_lookup_extras(status)
            self._core_extras[status.agent_id] = (time.monotonic(), extras)
            return extras

        def _core_lookup_extras(self, status) -> SessionExtras:
            from .process_registry import load_record, pid_exists

            pid = None
            record = None
            cwd = None
            name = None
            session_id = getattr(status, "session_id", None)
            if session_id:
                try:
                    record = load_record(status.provider, session_id)
                except Exception:
                    record = None
                if record is not None:
                    cwd = record.cwd or None
                    if record.ended_at_epoch is None and pid_exists(record.pid):
                        pid = record.pid
                name, cwd = self._core_session_title(status.provider, session_id, pid or (record.pid if record else None), cwd)
            origin_label = getattr(status, "origin", None)
            origin = origin_document(origin_label if isinstance(origin_label, str) else None)
            terminal = None
            if pid is not None:
                terminal = dict(self._core_terminal_for_pid(pid) or {})
                tty = self._core_tty_for_pid(pid)
                if tty:
                    terminal["tty"] = tty
                if not terminal:
                    terminal = None
            return SessionExtras(pid=pid, origin=origin, terminal=terminal, cwd=cwd, name=name)

        def _core_session_title(self, provider: str, session_id: str, pid: int | None, cwd: str | None):
            """(name, cwd) from the provider's own session record: Claude's
            ``~/.claude/sessions/<pid>.json`` name, Codex's session index
            title; ``cwd`` is filled from the same file when the registry
            had none."""
            name = None
            try:
                if provider == "claude":
                    from .process_registry import claude_session_details

                    details = claude_session_details(session_id, pid)
                    if details:
                        name = details.get("name")
                        cwd = cwd or details.get("cwd")
                elif provider == "codex":
                    from ._collector_legacy import codex_session_title

                    name = codex_session_title(session_id)
            except Exception:
                name = None
            return name, cwd

        def _core_tty_for_pid(self, pid: int) -> str | None:
            if pid in self._core_tty_by_pid:
                return self._core_tty_by_pid[pid]
            tty = None
            try:
                completed = subprocess.run(
                    ["/bin/ps", "-o", "tty=", "-p", str(pid)],
                    check=False,
                    stdout=subprocess.PIPE,
                    stderr=subprocess.DEVNULL,
                    text=True,
                    timeout=1.5,
                )
                text = completed.stdout.strip()
                if text and text not in ("??", "-"):
                    tty = text if text.startswith("/dev/") else f"/dev/{text}"
            except Exception:
                tty = None
            self._core_tty_by_pid[pid] = tty
            return tty

        def _core_terminal_for_pid(self, pid: int) -> dict[str, Any] | None:
            if pid in self._core_terminal_by_pid:
                return self._core_terminal_by_pid[pid]
            from .process_registry import list_processes

            terminal = None
            try:
                table = list_processes()
                current = pid
                for _ in range(12):
                    entry = table.get(current)
                    if entry is None or current <= 1:
                        break
                    match = terminal_from_command(entry.command)
                    if match is not None:
                        terminal = {"app": match[0], "bundle_id": match[1]}
                        break
                    current = entry.ppid
            except Exception:
                terminal = None
            self._core_terminal_by_pid[pid] = terminal
            return terminal

        def _core_device_facts(self) -> tuple[DeviceFacts, ...]:
            from ._led_status_legacy import led_count_for_target

            facts: list[DeviceFacts] = []
            linked = bool(getattr(self.settings, "link_screen_bar_to_hardware", False))
            for device in self.status_bar_devices(remember=False):
                if device.device_id == legacy.VIRTUAL_DEVICE_ID:
                    facts.append(
                        DeviceFacts(
                            id="screen-bar",
                            kind="screen_bar",
                            name=legacy.VIRTUAL_DEVICE_NAME,
                            leds=legacy.LED_COUNT,
                            enabled=bool(self.settings.virtual_status_device_enabled),
                            brightness=self._core_brightness_percent(device),
                            linked=linked,
                        )
                    )
                    continue
                leds = led_count_for_target(device.target)
                facts.append(
                    DeviceFacts(
                        id=device.device_id,
                        kind="dot" if leds == 2 else "pro",
                        name=device.name,
                        path=str(device.root),
                        leds=leds,
                        connected=bool(device.connected),
                        brightness=self._core_brightness_percent(device),
                        linked=linked,
                        last_write=self._core_hardware_anchor.get(device.device_id),
                        error=self.device_errors.get(device.device_id),
                    )
                )
            return tuple(facts)

        def _core_brightness_percent(self, device) -> int | None:
            try:
                return int(round(self.effective_brightness_for_device(device) / 255.0 * 100.0))
            except Exception:
                return int(round(float(device.brightness) / 255.0 * 100.0)) if device.brightness is not None else None

        def _core_build_state(self) -> dict[str, Any]:
            from .lid_sleep import sleep_helper_installed

            self._core_state_generation += 1
            snapshot = getattr(self, "last_snapshot", None)
            ask_statuses = self._core_ask_statuses()
            try:
                unseen = frozenset(status.agent_id for status in legacy.unseen_completions(snapshot, self)) if snapshot else frozenset()
            except Exception:
                unseen = frozenset()
            extras: dict[str, SessionExtras] = {}
            lookups = 0
            if snapshot is not None:
                for status in (*snapshot.statuses, *getattr(snapshot, "stale_statuses", ())):
                    cached = self._core_extras.get(status.agent_id)
                    if cached is not None and time.monotonic() - cached[0] < EXTRAS_TTL_SECONDS:
                        extras[status.agent_id] = cached[1]
                    elif lookups < MAX_EXTRA_LOOKUPS_PER_BUILD and not status.stale:
                        lookups += 1
                        extras[status.agent_id] = self._core_extras_for(status)
                    elif cached is not None:
                        extras[status.agent_id] = cached[1]
            try:
                intake = self.refresh_intake_report()
            except Exception:
                intake = getattr(self, "current_intake_report", None)
            try:
                helper = sleep_helper_installed()
            except Exception:
                helper = False
            return build_state_document(
                now=time.time(),
                generation=self._core_state_generation,
                snapshot=snapshot,
                ask_statuses=ask_statuses,
                unseen_completion_ids=unseen,
                operator_state=getattr(self, "current_operator_state", None),
                devices=self._core_device_facts(),
                usage_state=getattr(self, "provider_usage_state", None),
                power=PowerFacts(
                    keep_awake=bool(getattr(self.keep_awake, "holding_requested", False)),
                    closed_lid_policy=str(self.settings.closed_lid_awake_policy),
                    closed_lid_holding=bool(self.closed_lid_awake.active()),
                    helper_installed=bool(helper),
                ),
                dnd_projection=self.current_dnd_projection(),
                escalation=EscalationFacts(
                    stage=int(self.current_escalation_stage()),
                    since=mono_to_epoch(getattr(self, "ask_blocked_since", None)),
                ),
                intake_report=intake,
                settings_generation=self._core_settings_generation,
                extras_by_id=extras,
            )

        def _core_light_facts(self, device, *, preview: bool, display_kind: str | None) -> LightFacts:
            """The dimming and DND facts behind one surface's ``why``."""
            dimming: list[str] = []
            factor: float | None = None
            try:
                plan = self.ambient_brightness_plan_for_device(device) if device is not None else None
            except Exception:
                plan = None
            if plan is not None:
                product = 1.0
                for step in getattr(plan, "trace", ()) or ():
                    word = {"idle_dim": "idle_dim", "sleep_dim": "sleep", "dnd_dim": "quiet", "night_dim": "night"}.get(
                        getattr(step, "name", "")
                    )
                    step_factor = getattr(step, "factor", None)
                    if word is None or step_factor is None:
                        continue
                    if float(step_factor) < 1.0:
                        dimming.append(word)
                        product *= float(step_factor)
                factor = round(product, 3)
            try:
                dnd = self.current_dnd_projection()
            except Exception:
                dnd = None
            admission = getattr(getattr(dnd, "display_admission", None), "value", None)
            return LightFacts(
                display_kind=display_kind,
                preview=preview,
                dnd_display_admission=admission,
                dnd_brightness_factor=getattr(dnd, "brightness_factor", None),
                dimming=tuple(dimming),
                brightness_factor=factor,
            )

        def _core_why_detail(self, why: str, facts: LightFacts, glance) -> dict[str, Any]:
            with self._core_lock:
                state = self._core_documents.get("state") or {}
            return why_detail(
                why,
                sessions=state.get("sessions") or [],
                asks=state.get("asks") or [],
                unseen_completion_ids=tuple(state.get("unseen_completions") or ()),
                now=time.time(),
                facts=facts,
                glance=glance,
            )

        def _core_build_lights(self) -> dict[str, Any]:
            from ._led_status_legacy import led_count_for_target
            from .presentation_policy import MotionClass

            glance = getattr(self, "_current_resolved_glance", None)
            _why, override = why_for_glance(glance)
            linked = bool(getattr(self.settings, "link_screen_bar_to_hardware", False))
            devices_linked = bool(getattr(self.settings, "devices_linked", True))
            surfaces: dict[str, SurfaceFacts] = {}
            hardware_anchor: float | None = None
            first_strip = True
            display_kinds = getattr(self, "last_led_display_kind_by_device", {}) or {}
            for device in self.status_bar_devices(remember=False):
                if device.device_id == legacy.VIRTUAL_DEVICE_ID or not device.connected:
                    continue
                controller = self.agent_led_controllers_by_device.get(device.device_id)
                program = getattr(controller, "last_program", None)
                if not isinstance(program, str) or not program:
                    continue
                leds = led_count_for_target(device.target)
                anchor = self._core_hardware_anchor.get(device.device_id)
                preview = self._core_previews.get("hardware" if leds != 2 else "dot") or self._core_previews.get(device.device_id)
                previewing = preview is not None and device.device_id in preview.device_ids
                if previewing:
                    program, anchor = preview.program, preview.started_epoch
                facts = self._core_light_facts(
                    device, preview=previewing, display_kind=display_kinds.get(device.device_id)
                )
                surface_why = light_why(glance, facts)
                name = "dot" if leds == 2 else ("hardware" if first_strip else f"hardware:{device.device_id}")
                if leds != 2 and first_strip:
                    first_strip = False
                    hardware_anchor = anchor
                surfaces[name] = SurfaceFacts(
                    program=program,
                    led_count=leds,
                    anchor=anchor,
                    motion=None,
                    static_fallback=None,
                    brightness=(self._core_brightness_percent(device) or 0) / 100.0,
                    why=surface_why,
                    override=override,
                    why_detail=self._core_why_detail(surface_why, facts, glance),
                )
            if devices_linked and "dot" in surfaces and "hardware" in surfaces:
                # Linked Pro + Dot: the Dot carries the strip's anchor so the
                # app reads both as one unit (core_runtime linked writes).
                dot = surfaces["dot"]
                if surfaces["dot"].why != "preview":
                    surfaces["dot"] = SurfaceFacts(
                        program=dot.program,
                        led_count=dot.led_count,
                        anchor=hardware_anchor if hardware_anchor is not None else dot.anchor,
                        brightness=dot.brightness,
                        why=dot.why,
                        override=dot.override,
                        why_detail=dot.why_detail,
                    )
            virtual = self.virtual_status_device
            call = getattr(virtual, "_live_program_call", None)
            virtual_device = next(
                (d for d in self.status_bar_devices(remember=False) if d.device_id == legacy.VIRTUAL_DEVICE_ID),
                None,
            )
            bar_brightness = (
                (self._core_brightness_percent(virtual_device) or 0) / 100.0
                if virtual_device is not None
                else (self.settings.brightness_for_device(legacy.VIRTUAL_DEVICE_ID) / 255.0)
            )
            preview = self._core_previews.get("screen_bar")
            bar_facts = self._core_light_facts(
                virtual_device, preview=preview is not None, display_kind=display_kinds.get(legacy.VIRTUAL_DEVICE_ID)
            )
            bar_why = light_why(glance, bar_facts)
            if preview is not None:
                surfaces["screen_bar"] = SurfaceFacts(
                    program=preview.program,
                    led_count=legacy.LED_COUNT,
                    anchor=preview.started_epoch,
                    motion="continuous",
                    static_fallback="off",
                    brightness=bar_brightness,
                    why="preview",
                    why_detail=self._core_why_detail("preview", bar_facts, glance),
                )
            elif call is not None:
                program, kwargs = call
                motion = kwargs.get("motion")
                anchor = mono_to_epoch(kwargs.get("started_at"))
                anchor = screen_bar_anchor(anchor, hardware_anchor, linked=linked)
                surfaces["screen_bar"] = SurfaceFacts(
                    program=str(program),
                    led_count=legacy.LED_COUNT,
                    anchor=anchor,
                    motion=motion.value if isinstance(motion, MotionClass) else None,
                    static_fallback=kwargs.get("static_fallback_program"),
                    brightness=bar_brightness,
                    why=bar_why,
                    override=override,
                    why_detail=self._core_why_detail(bar_why, bar_facts, glance),
                )
            elif "hardware" in surfaces:
                hardware = surfaces["hardware"]
                surfaces["screen_bar"] = SurfaceFacts(
                    program=hardware.program,
                    led_count=hardware.led_count,
                    anchor=hardware.anchor,
                    brightness=bar_brightness,
                    why=hardware.why,
                    override=override,
                    why_detail=hardware.why_detail,
                )
            return build_lights_document(
                surfaces,
                linked=linked,
                devices_linked=devices_linked and "dot" in surfaces and "hardware" in surfaces,
            )

        def _core_doctor_document(self) -> dict[str, Any]:
            from .doctor import collect_diagnostics
            from .install import hook_shim_path

            checks: list[dict[str, Any]] = []
            try:
                result = collect_diagnostics()
                for finding in result.findings:
                    healthy = finding.code.value in _HEALTHY_DIAGNOSTIC_CODES
                    if finding.check.value in _APP_OWNED_DIAGNOSTICS:
                        # Alcove following is the app's job now; the daemon
                        # not running it is the design, not a fault.
                        healthy = True
                    checks.append(
                        {
                            "name": finding.check.value,
                            "ok": healthy,
                            "detail": f"{finding.code.value} ({finding.count}/{finding.limit})",
                        }
                    )
            except Exception as exc:
                checks.append({"name": "diagnostics", "ok": False, "detail": f"unavailable: {exc.__class__.__name__}"})
            shim = hook_shim_path()
            checks.append(
                {
                    "name": "hook shim",
                    "ok": shim is not None,
                    "detail": str(shim) if shim is not None else "python -m jrbar.hook_client",
                }
            )
            pending = pending_hook_files()
            checks.append({"name": "pending hook lines", "ok": not pending, "detail": f"{len(pending)} files"})
            server = self._core
            with self._core_lock:
                state = self._core_documents.get("state") or {}
            hooks = ((state.get("health") or {}).get("hooks")) or {}
            devices = {device.get("id"): ("connected" if device.get("connected", device.get("enabled")) else "absent") for device in state.get("devices") or []}
            return {
                "ok": all(check["ok"] for check in checks),
                "core_version": CORE_VERSION,
                "commit": _running_commit(),
                "python": sys.executable,
                "pid": os.getpid(),
                "socket": str(server.socket_path) if server is not None else None,
                "uptime_seconds": round(time.time() - self._core_started_at, 1),
                "clients": server.client_count if server is not None else 0,
                "hooks": hooks,
                "devices": devices,
                "settings_generation": self._core_settings_generation,
                "state_generation": self._core_state_generation,
                "commands": list(command_names()),
                "checks": checks,
            }

    _CLASS_CACHE[base] = JRCoreHeadlessController
    return JRCoreHeadlessController


# --- entry point ------------------------------------------------------------


def _install_log_mirror(get_server: Callable[[], CoreServer | None]) -> None:
    from . import status_bar_legacy as legacy

    original = legacy.log_status_bar

    def log_status_bar(message: str) -> None:
        original(message)
        server = get_server()
        if server is not None:
            try:
                server.publish_log(str(message))
            except Exception:
                pass

    legacy.log_status_bar = log_status_bar


def build_core_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(prog="jrbar core", description="Run the JR-Bar core daemon (headless).")
    parser.add_argument("--socket", default=None, help="core socket path (default: ~/.local/state/jrbar/core.sock)")
    return parser


def run_core(argv: list[str] | None = None) -> int:
    args = build_core_parser().parse_args(argv)
    from .ipc import another_instance_alive

    if another_instance_alive():
        print("jrbar core: another JR-Bar (core or status bar) already owns the event socket; exiting.", file=sys.stderr)
        return 2

    from AppKit import NSApplication

    from .application_composition import compose_status_bar_application
    from .migration import run_startup_migration

    run_startup_migration()
    compose_status_bar_application()
    controller_class = build_headless_controller_class()
    application = NSApplication.sharedApplication()
    controller = controller_class.alloc().init()
    controller._core_socket_path = Path(args.socket).expanduser() if args.socket else None
    _install_log_mirror(lambda: getattr(controller, "_core", None))
    application.setDelegate_(controller)

    def _terminate(_signum, _frame) -> None:
        controller.performSelectorOnMainThread_withObject_waitUntilDone_("coreQuit:", None, False)

    signal.signal(signal.SIGTERM, _terminate)
    signal.signal(signal.SIGINT, _terminate)
    print(f"jrbar core {CORE_VERSION} starting (pid {os.getpid()})", flush=True)
    application.run()
    return 0


__all__ = [
    "CORE_VERSION",
    "CoreCommandBox",
    "HeadlessNotificationClient",
    "build_headless_controller_class",
    "command_names",
    "device_transitions",
    "get_path",
    "mono_to_epoch",
    "run_core",
    "screen_bar_anchor",
    "set_path",
    "settings_from_document",
    "split_path",
]
