"""Pure builders for the core daemon's ``state``, ``lights``, ``settings``
and ``list_history`` documents (docs/CORE-PROTOCOL.md, protocol 1).

Nothing here imports AppKit or touches the controller. The runtime
(``core_runtime``) gathers the facts from the live controller into the
small dataclasses below and hands them here; tests build the same
dataclasses from fixtures. Every function returns plain JSON-ready dicts.
"""

from __future__ import annotations

import math
import re
from dataclasses import dataclass
from datetime import datetime
from typing import Any, Final

from .completion_visibility import (
    COMPLETED_VISIBLE_SECONDS,
    END_EVENT_NAMES,
    LIVE_VISIBLE_SECONDS,
    acknowledged_epoch_by_session,
    filter_visible_sessions,
)
from .models import AgentMode

PROTOCOL_VERSION: Final = 1
SETTINGS_SCHEMA: Final = 3

# The provider's own bundle ids, by the origin kinds ``origin.py`` emits.
ORIGIN_BUNDLE_IDS: Final = {
    "claude_app": "com.anthropic.claudefordesktop",
    "codex_app": "com.openai.codex",
    "grok_app": "com.x.grok",
    "claude_vscode": "com.microsoft.VSCode",
    "codex_vscode": "com.microsoft.VSCode",
    "devin_vscode": "com.microsoft.VSCode",
    "grok_vscode": "com.microsoft.VSCode",
    "claude_cursor": "com.todesktop.230313mzl4w4u92",
    "codex_cursor": "com.todesktop.230313mzl4w4u92",
    "devin_cursor": "com.todesktop.230313mzl4w4u92",
    "grok_cursor": "com.todesktop.230313mzl4w4u92",
    "claude_windsurf": "com.exafunction.windsurf",
    "codex_windsurf": "com.exafunction.windsurf",
    "devin_windsurf": "com.exafunction.windsurf",
    "grok_windsurf": "com.exafunction.windsurf",
}

# Terminal emulators, by the executable name ``ps`` reports, so a CLI
# session can say which app hosts it.
TERMINAL_APPS: Final = {
    "terminal": ("Terminal", "com.apple.Terminal"),
    "iterm2": ("iTerm", "com.googlecode.iterm2"),
    "iterm": ("iTerm", "com.googlecode.iterm2"),
    "ghostty": ("Ghostty", "com.mitchellh.ghostty"),
    "kitty": ("kitty", "net.kovidgoyal.kitty"),
    "alacritty": ("Alacritty", "org.alacritty"),
    "wezterm-gui": ("WezTerm", "com.github.wez.wezterm"),
    "wezterm": ("WezTerm", "com.github.wez.wezterm"),
    "warp": ("Warp", "dev.warp.Warp-Stable"),
    "hyper": ("Hyper", "co.zeit.hyper"),
    "tabby": ("Tabby", "org.tabby"),
    "rio": ("Rio", "com.raphaelamorim.rio"),
    "code": ("Visual Studio Code", "com.microsoft.VSCode"),
    "code helper": ("Visual Studio Code", "com.microsoft.VSCode"),
    "code helper (plugin)": ("Visual Studio Code", "com.microsoft.VSCode"),
    "cursor": ("Cursor", "com.todesktop.230313mzl4w4u92"),
    "cursor helper": ("Cursor", "com.todesktop.230313mzl4w4u92"),
    "cursor helper (plugin)": ("Cursor", "com.todesktop.230313mzl4w4u92"),
    "windsurf": ("Windsurf", "com.exafunction.windsurf"),
    "claude": ("Claude", "com.anthropic.claudefordesktop"),
    "codex": ("Codex", "com.openai.codex"),
}
TERMINAL_BUNDLE_IDS: Final = frozenset(bundle for _name, bundle in TERMINAL_APPS.values())

_WORKING_MODES: Final = frozenset(
    {AgentMode.WORKING, AgentMode.TOOL_RUNNING, AgentMode.LONG_TASK_PROGRESS}
)
_ESCALATION_STAGE_NAMES: Final = {0: "none", 1: "ramp", 2: "menu_bar", 3: "final"}
# ``lights.surfaces.*.why``: the documented vocabulary (docs/CORE-PROTOCOL.md).
WHY_VALUES: Final = (
    "idle",
    "working",
    "waiting",
    "completed",
    "failed",
    "capacity",
    "quiet",
    "sleep_dim",
    "idle_dim",
    "battery",
    "calendar",
    "reminder",
    "escalation",
    "preview",
    "studio",
    "unknown",
)
_GLANCE_WHY: Final = {
    "attention": "waiting",
    "fresh_completion": "completed",
    "active": "working",
    "rest": "idle",
    "fresh_failure": "failed",
    "unresolved_failure": "failed",
    "capacity": "capacity",
}
# Device display kinds (status_bar_legacy.LED_DISPLAY_*) that name the
# light's reason outright; ``agent`` and anything unlisted defer to the glance.
_DISPLAY_KIND_WHY: Final = {
    "battery": "battery",
    "low_battery": "battery",
    "calendar": "calendar",
    "reminders": "reminder",
    "escalation": "escalation",
    "studio": "studio",
    "dnd_dark": "quiet",
    "quota_alert": "capacity",
    "quota_runway": "capacity",
    "failure": "failed",
    "completion": "completed",
    "all_clear": "completed",
    "reset_celebration": "capacity",
    "signal_test": "preview",
    "peek": "preview",
}
# brightness_policy trace step names -> ``why_detail.dimming`` words.
_DIMMING_STEPS: Final = {
    "idle_dim": "idle_dim",
    "sleep_dim": "sleep",
    "dnd_dim": "quiet",
    "night_dim": "auto_dim",
}
# ``usage.providers[].windows[].name``: the short form the panel shows,
# keyed by the lane id the provider usage lanes carry.
USAGE_WINDOW_NAMES: Final = {
    "five-hour": "5h",
    "five_hour": "5h",
    "5h": "5h",
    "weekly": "7d",
    "seven-day": "7d",
    "seven_day": "7d",
    "7d": "7d",
    "daily": "Daily",
    "monthly": "Monthly",
    "credits": "Credits",
}
# Provider display names for the label fallback ("Claude fca1eb06").
PROVIDER_LABELS: Final = {
    "codex": "Codex",
    "claude": "Claude",
    "devin": "Devin",
    "grok": "Grok",
    "cursor": "Cursor",
    "hermes": "Hermes",
    "openclaw": "OpenClaw",
    "opencode": "OpenCode",
    "antigravity": "Antigravity",
    "kiro": "Kiro",
    "pi": "Pi",
    "gemini": "Gemini",
}
_LEDGER_KINDS: Final = {
    "completed": "completed",
    "asked": "asked",
    "blocked": "failed",
    "threshold_crossed": "quota_crossed",
}


# --- facts the runtime gathers ---------------------------------------------


@dataclass(frozen=True, slots=True)
class DeviceFacts:
    """One row of ``state.devices``: a strip, a Dot, or the Screen Bar."""

    id: str
    kind: str
    name: str | None = None
    path: str | None = None
    leds: int | None = None
    connected: bool | None = None
    enabled: bool | None = None
    brightness: int | None = None
    linked: bool | None = None
    last_write: float | None = None
    error: str | None = None


@dataclass(frozen=True, slots=True)
class SurfaceFacts:
    """One ``lights.surfaces`` entry."""

    program: str
    led_count: int | None = None
    anchor: float | None = None
    motion: str | None = None
    static_fallback: str | None = None
    brightness: float | None = None
    why: str | None = None
    override: str | None = None
    #: Only the ``dot`` surface carries this: what a linked Dot is FOR
    #: (``jrbar.dot_role`` -- ``extend`` / ``asks`` / ``status``). Absent
    #: means the surface has no role to have, or the Dot is rendering its
    #: own display.
    role: str | None = None
    why_detail: dict[str, Any] | None = None


@dataclass(frozen=True, slots=True)
class SessionExtras:
    """What the process registry and the hook origin know about a session."""

    pid: int | None = None
    origin: dict[str, Any] | None = None
    terminal: dict[str, Any] | None = None
    # Tri-state, because "no pid" has two very different meanings: ``False``
    # is "the process registry knew this session and its process is gone",
    # ``None`` is "nobody looked, or there was never a record". Only the
    # first one turns a completion into ``ended``.
    process_alive: bool | None = None
    # What the process registry recorded from the hook payload.
    cwd: str | None = None
    # The provider's own session title: Claude's ``name`` from
    # ``~/.claude/sessions/<pid>.json``, Codex's ``thread_name`` from
    # ``~/.codex/session_index.jsonl``.
    name: str | None = None


@dataclass(frozen=True, slots=True)
class LightFacts:
    """What the runtime knows about the light beyond the glance: the
    device display kind, the DND projection, the brightness dimming that
    applied, and the session that explains the state."""

    display_kind: str | None = None
    preview: bool = False
    dnd_display_admission: str | None = None
    dnd_brightness_factor: float | None = None
    dimming: tuple[str, ...] = ()
    brightness_factor: float | None = None


@dataclass(frozen=True, slots=True)
class PowerFacts:
    keep_awake: bool
    closed_lid_policy: str
    closed_lid_holding: bool
    helper_installed: bool


@dataclass(frozen=True, slots=True)
class EscalationFacts:
    stage: int = 0
    since: float | None = None


# --- small pure helpers -------------------------------------------------------


def epoch(value: object) -> float | None:
    """A datetime, an epoch number or None as an epoch float (or None)."""
    if value is None:
        return None
    if isinstance(value, datetime):
        try:
            return float(value.timestamp())
        except (OverflowError, ValueError):
            return None
    if isinstance(value, bool):
        return None
    if isinstance(value, (int, float)) and math.isfinite(float(value)):
        return float(value)
    return None


def strip_session_short_id(display_name: str, session_id: str | None) -> str:
    """The menu's own title rule: the display name without its short id."""
    text = str(display_name or "").strip()
    if session_id:
        suffix = f" ({str(session_id)[:8]})"
        if text.endswith(suffix):
            return text[: -len(suffix)].strip()
    if text.endswith(")") and " (" in text:
        prefix, suffix = text.rsplit(" (", 1)
        token = suffix[:-1]
        if 6 <= len(token) <= 12 and all(char.isalnum() or char == "-" for char in token):
            return prefix.strip()
    return text


def short_session_id(session_id: str | None, agent_id: str | None = None) -> str | None:
    """The first 8 characters of the session id (or of a worker's agent id)."""
    for candidate in (session_id, agent_id):
        if isinstance(candidate, str) and candidate:
            token = candidate.rsplit(":", 1)[-1] if candidate.count(":") >= 2 else candidate
            token = token.strip()
            if token:
                return token[:8]
    return None


def _looks_like_safe_label(text: str, provider: str) -> bool:
    """True for the collector's content-free fallback ("Claude <work id>",
    "Claude agent <id>"): a provider word, optionally "agent", then one
    id-shaped token. Those carry nothing a person can read."""
    parts = text.split()
    if len(parts) not in (2, 3):
        return False
    head = parts[0].lower()
    if head != provider.lower() and head != PROVIDER_LABELS.get(provider, "").lower():
        return False
    if len(parts) == 3 and parts[1].lower() not in ("agent", "worker", "session"):
        return False
    token = parts[-1]
    return len(token) >= 8 and all(char.isalnum() or char == "-" for char in token)


def session_label(
    *,
    provider: str,
    session_id: str | None,
    agent_id: str,
    display_name: str | None,
    cwd: str | None,
    extras: SessionExtras | None,
    is_worker: bool = False,
    parent_label: str | None = None,
) -> str:
    """A human label: the provider's own session title, else the display
    name the collector derived (project/prompt), else the working
    directory's last path component, else provider plus short id."""
    short = short_session_id(agent_id if is_worker else session_id, agent_id) or "?"
    provider_label = PROVIDER_LABELS.get(provider, provider.title() if provider else "Agent")
    if is_worker:
        base = parent_label or provider_label
        return f"{base} worker {short}"
    if extras is not None and isinstance(extras.name, str) and extras.name.strip():
        return extras.name.strip()
    stripped = strip_session_short_id(display_name or "", session_id)
    if stripped and not _looks_like_safe_label(stripped, provider):
        return stripped
    for candidate in ((extras.cwd if extras is not None else None), cwd):
        if isinstance(candidate, str) and candidate.strip():
            tail = candidate.rstrip("/").rsplit("/", 1)[-1]
            if tail:
                return tail
    return f"{provider_label} {short}"


def usage_window_name(lane_id: str | None, label: str | None, model: str | None = None) -> str:
    """``5h`` / ``7d`` / ``Daily`` / ``Weekly`` / ``Monthly`` / ``Credits``;
    a model-scoped lane keeps the model word ("7d Fable")."""
    key = str(lane_id or "").strip().lower()
    name = USAGE_WINDOW_NAMES.get(key)
    if name is None:
        text = str(label or "").strip()
        lowered = text.lower().replace("_", "-")
        if lowered in ("5-hour", "five-hour", "5 hour", "5h"):
            name = "5h"
        elif lowered in ("weekly", "7-day", "seven-day", "7 day", "7d"):
            name = "7d"
        else:
            name = text or (lane_id or "?")
    if model and name in ("5h", "7d", "Daily", "Monthly"):
        word = str(model).strip()
        if word and word.lower() not in name.lower():
            name = f"{name} {word[:1].upper()}{word[1:]}"
    return name


def origin_kind(label: str | None) -> str | None:
    if not label:
        return None
    normalized = re.sub(r"[^a-z0-9]+", "_", label.strip().lower()).strip("_")
    return normalized or None


def origin_document(label: str | None, kind: str | None = None) -> dict[str, Any] | None:
    """``{"kind", "label", "bundle_id"}`` from the hook's origin annotation."""
    if not label:
        return None
    resolved_kind = kind or origin_kind(label)
    return {
        "kind": resolved_kind,
        "label": label,
        "bundle_id": ORIGIN_BUNDLE_IDS.get(resolved_kind or ""),
    }


def terminal_from_command(command: str | None) -> tuple[str, str] | None:
    """(app name, bundle id) when ``command`` is a known terminal or IDE."""
    if not command:
        return None
    base = command.rsplit("/", 1)[-1].strip().lower()
    for key, value in TERMINAL_APPS.items():
        if base == key:
            return value
    lowered = command.lower()
    for token, value in (
        ("terminal.app", ("Terminal", "com.apple.Terminal")),
        ("iterm.app", ("iTerm", "com.googlecode.iterm2")),
        ("ghostty.app", ("Ghostty", "com.mitchellh.ghostty")),
        ("kitty.app", ("kitty", "net.kovidgoyal.kitty")),
        ("alacritty.app", ("Alacritty", "org.alacritty")),
        ("wezterm.app", ("WezTerm", "com.github.wez.wezterm")),
        ("warp.app", ("Warp", "dev.warp.Warp-Stable")),
        ("visual studio code.app", ("Visual Studio Code", "com.microsoft.VSCode")),
        ("cursor.app", ("Cursor", "com.todesktop.230313mzl4w4u92")),
        ("windsurf.app", ("Windsurf", "com.exafunction.windsurf")),
        ("claude.app", ("Claude", "com.anthropic.claudefordesktop")),
        ("codex.app", ("Codex", "com.openai.codex")),
    ):
        if token in lowered:
            return value
    return None


def lifecycle_for_mode(
    mode: AgentMode,
    *,
    stale: bool,
    event_name: str | None = None,
    process_alive: bool | None = None,
) -> str:
    """The app's five words: ``active``, ``completed``, ``failed``,
    ``ended``, ``stale``.

    ``completed`` is a claim -- the green check, "Done" -- and only a
    provider's own end event earns it. A run whose process died, or one the
    collector merely *inferred* was finished (a notification that read as
    done, an explicit status message), reads ``ended``: grey, no check.
    ``event_name`` of ``None`` means the caller has no event to judge by and
    keeps the older, looser reading.
    """

    if mode is AgentMode.BLOCKED_ERROR:
        return "failed"
    if mode is AgentMode.ENDED_UNCONFIRMED:
        return "ended"
    if mode is AgentMode.COMPLETED:
        if process_alive is False:
            return "ended"
        if event_name is not None and event_name not in END_EVENT_NAMES:
            return "ended"
        return "completed"
    if stale:
        return "stale"
    return "active"


def aggregate_mode(mode: AgentMode | None, *, asks: int, failed: int, working: int, ready: int) -> str:
    if asks or mode is AgentMode.WAITING_FOR_INPUT:
        return "needs_you"
    if failed or mode is AgentMode.BLOCKED_ERROR:
        return "failed"
    if working or (mode in _WORKING_MODES):
        return "working"
    if ready or mode is AgentMode.COMPLETED:
        return "done"
    return "idle"


def why_for_glance(glance: object) -> tuple[str | None, str | None]:
    """``(why, override)`` from a ResolvedGlance-shaped object."""
    if glance is None:
        return None, None
    semantic = getattr(getattr(glance, "semantic", None), "value", None)
    override = getattr(getattr(glance, "override_reason", None), "value", None)
    why = _GLANCE_WHY.get(str(semantic)) if semantic is not None else None
    if override in (None, "none"):
        override = None
    return why, override


def light_why(glance: object, facts: LightFacts | None = None) -> str:
    """The documented ``why`` for a surface (``WHY_VALUES``).

    Precedence: a preview, then a device display kind that names the
    reason (battery, calendar, reminder, escalation, studio, quota), then
    a DND state that shows nothing (``quiet``), then the glance semantic;
    an idle light that is dimmed says why it is dim (``idle_dim`` /
    ``sleep_dim``).
    """
    facts = facts or LightFacts()
    if facts.preview:
        return "preview"
    kind = (facts.display_kind or "").strip().lower()
    if kind and kind != "agent":
        mapped = _DISPLAY_KIND_WHY.get(kind)
        if mapped is not None:
            return mapped
    if facts.dnd_display_admission == "none" or (
        facts.dnd_brightness_factor is not None and float(facts.dnd_brightness_factor) <= 0.0
    ):
        return "quiet"
    why, _override = why_for_glance(glance)
    if why is None:
        return "unknown"
    if why == "idle":
        if "idle_dim" in facts.dimming:
            return "idle_dim"
        if "sleep" in facts.dimming:
            return "sleep_dim"
        if "quiet" in facts.dimming:
            return "quiet"
    return why


def why_detail(
    why: str,
    *,
    sessions: list[dict[str, Any]] | tuple[dict[str, Any], ...],
    asks: list[dict[str, Any]] | tuple[dict[str, Any], ...],
    unseen_completion_ids: frozenset[str] | set[str] | tuple[str, ...] = (),
    now: float,
    facts: LightFacts | None = None,
    glance: object = None,
) -> dict[str, Any]:
    """``why_detail`` for a surface: the session the light is about (when
    there is one), how long it has been in that state, and the dimming
    that shaped its brightness."""
    facts = facts or LightFacts()
    session: dict[str, Any] | None = None
    mains = [row for row in sessions if row.get("kind") == "main"]
    if why in ("waiting", "escalation") and asks:
        oldest = min(asks, key=lambda ask: ask.get("opened_at") or float("inf"))
        session = next((row for row in mains if row.get("id") == oldest.get("session")), None)
    elif why == "working":
        working = [row for row in mains if row.get("mode") in {mode.value for mode in _WORKING_MODES} and not row.get("stale")]
        session = max(working, key=lambda row: row.get("since") or 0.0, default=None)
    elif why == "completed":
        unseen = set(unseen_completion_ids)
        done = [row for row in mains if row.get("lifecycle") == "completed" and (not unseen or row.get("id") in unseen)]
        session = max(done, key=lambda row: row.get("updated_at") or 0.0, default=None)
    elif why == "failed":
        failed = [row for row in mains if row.get("lifecycle") == "failed"]
        session = max(failed, key=lambda row: row.get("updated_at") or 0.0, default=None)
    since = None
    if session is not None:
        since = session.get("since")
        if why in ("waiting", "escalation") and session.get("ask"):
            since = session["ask"].get("opened_at") or since
    if since is None and glance is not None:
        since = epoch(getattr(glance, "relay_epoch", None))
    seconds = max(0.0, round(float(now) - float(since), 1)) if since is not None else None
    return {
        "session": session.get("id") if session is not None else None,
        "label": session.get("label") if session is not None else None,
        "provider": session.get("provider") if session is not None else None,
        "seconds_in_state": seconds,
        "brightness_factor": facts.brightness_factor,
        "dimming": list(facts.dimming),
    }


def escalation_stage_name(stage: int) -> str:
    return _ESCALATION_STAGE_NAMES.get(int(stage), "none")


def hook_health(intake_report: object) -> dict[str, str]:
    """``state.health.hooks``: ok / missing / stale per provider."""
    result: dict[str, str] = {}
    providers = getattr(intake_report, "providers", ()) or ()
    for intake in providers:
        provider = getattr(intake, "provider", None)
        if not isinstance(provider, str):
            continue
        if not getattr(intake, "installed", False):
            result[provider] = "missing"
        elif getattr(intake, "stuck", False):
            result[provider] = "stale"
        else:
            result[provider] = "ok"
    return result


# --- documents ----------------------------------------------------------------


def _request_for_status(operator_state: object, status: object):
    work_key = getattr(status, "work_key", None)
    if operator_state is None or work_key is None:
        return None
    for request in getattr(operator_state, "requests", ()) or ():
        key = getattr(request, "key", None)
        if getattr(key, "work_key", None) != work_key:
            continue
        phase = getattr(getattr(request, "phase", None), "value", "")
        if phase.startswith("live"):
            return request
    return None


def _work_for_status(operator_state: object, status: object):
    work_key = getattr(status, "work_key", None)
    if operator_state is None or work_key is None:
        return None
    for work in getattr(operator_state, "works", ()) or ():
        if getattr(work, "key", None) == work_key:
            return work
    return None


def ask_document(status: object, operator_state: object, *, with_session: bool) -> dict[str, Any]:
    request = _request_for_status(operator_state, status)
    kind = getattr(getattr(request, "request_kind", None), "value", None)
    if kind in (None, "unknown"):
        event_name = getattr(status, "event_name", "")
        if event_name == "PermissionRequest":
            kind = "permission"
        elif getattr(status, "tool_name", None) == "ExitPlanMode":
            kind = "approval"
        else:
            kind = "input"
    opened_at = epoch(getattr(request, "opened_at_epoch", None)) or epoch(
        getattr(status, "updated_at", None)
    )
    summary = getattr(status, "message", None) or getattr(status, "tool_name", None)
    document: dict[str, Any] = {
        "kind": kind,
        "opened_at": opened_at,
        "summary": summary if isinstance(summary, str) else None,
    }
    if with_session:
        document = {"session": getattr(status, "agent_id", None), **document}
    return document


def session_document(
    status: object,
    *,
    operator_state: object,
    ask_ids: frozenset[str],
    extras: SessionExtras | None,
    workers: int,
    parent_label: str | None = None,
) -> dict[str, Any]:
    mode = getattr(status, "mode", AgentMode.UNKNOWN)
    if not isinstance(mode, AgentMode):
        mode = AgentMode.UNKNOWN
    agent_id = str(getattr(status, "agent_id", ""))
    stale = bool(getattr(status, "stale", False))
    is_subagent = bool(getattr(status, "is_subagent", False))
    work = _work_for_status(operator_state, status)
    next_actor = getattr(getattr(work, "next_actor", None), "value", None)
    if next_actor in (None, "unknown", "none"):
        next_actor = (
            "user"
            if mode in (AgentMode.WAITING_FOR_INPUT, AgentMode.COMPLETED, AgentMode.BLOCKED_ERROR)
            else "provider"
        )
    updated_at = epoch(getattr(status, "updated_at", None))
    origin_label = getattr(status, "origin", None)
    origin = (extras.origin if extras is not None and extras.origin else None) or origin_document(
        origin_label if isinstance(origin_label, str) else None
    )
    provider = str(getattr(status, "provider", "unknown"))
    session_id = getattr(status, "session_id", None)
    cwd = getattr(status, "cwd", None) or (extras.cwd if extras is not None else None)
    event_name = getattr(status, "event_name", None)
    process_alive = extras.process_alive if extras is not None else None
    lifecycle = lifecycle_for_mode(
        mode,
        stale=stale,
        event_name=event_name if isinstance(event_name, str) else None,
        process_alive=process_alive,
    )
    # A dead process without an end event is a session that stopped being
    # delivered, whatever its last mode said.
    if process_alive is False and event_name not in END_EVENT_NAMES:
        stale = True
    # ``mode`` travels beside ``lifecycle`` and the app reads whichever is
    # more definite; a run demoted to ``ended`` must not still say
    # ``completed`` or it renders as Done with a green check.
    if lifecycle == "ended" and mode is AgentMode.COMPLETED:
        mode = AgentMode.ENDED_UNCONFIRMED
    return {
        "id": agent_id,
        "provider": provider,
        "kind": "worker" if is_subagent else "main",
        "parent": getattr(status, "parent_agent_id", None) if is_subagent else None,
        "label": session_label(
            provider=provider,
            session_id=session_id,
            agent_id=agent_id,
            display_name=getattr(status, "display_name", None),
            cwd=cwd,
            extras=extras,
            is_worker=is_subagent,
            parent_label=parent_label,
        ),
        "short_id": short_session_id(
            agent_id if is_subagent else session_id, agent_id
        ),
        "cwd": cwd,
        "mode": mode.value,
        "lifecycle": lifecycle,
        "next_actor": next_actor,
        "since": updated_at,
        "updated_at": updated_at,
        "stale": stale,
        "pid": extras.pid if extras is not None else None,
        "origin": origin,
        "ask": ask_document(status, operator_state, with_session=False) if agent_id in ask_ids else None,
        "terminal": extras.terminal if extras is not None else None,
        "workers": workers,
        "event": getattr(status, "event_name", None),
        "tool": getattr(status, "tool_name", None),
        "message": getattr(status, "message", None),
    }


def primary_window(windows: list[dict[str, Any]]) -> dict[str, Any] | None:
    """The window a provider's forecast is about: the 5h one when reported,
    else the first (the app's ``UsageCenterStore.primaryWindow`` rule)."""
    for window in windows:
        if str(window.get("name") or "").lower() == "5h":
            return window
    return windows[0] if windows else None


def usage_document(
    usage_state: object,
    *,
    usage_samples: object = None,
    now: float | None = None,
) -> dict[str, Any] | None:
    """``state.usage``. With a ``UsageSampleBuffer`` the primary window of
    each provider gets a ``forecast``; without one it stays null."""
    if usage_state is None:
        return None
    providers = []
    for snapshot in getattr(usage_state, "snapshots", ()) or ():
        windows = []
        lanes = list(getattr(snapshot, "lanes", ()) or ())
        # A model-scoped lane with its own id ("fable-only") shares its
        # reset with the account-wide window of the same horizon; that
        # sibling names the horizon ("7d Fable").
        horizon_by_reset: dict[float, str] = {}
        for lane in lanes:
            if getattr(lane, "model", None):
                continue
            base = usage_window_name(getattr(lane, "lane_id", None), getattr(lane, "label", None))
            reset = epoch(getattr(lane, "reset_at", None))
            if base in ("5h", "7d", "Daily", "Monthly") and reset is not None:
                horizon_by_reset.setdefault(round(reset), base)
        for lane in lanes:
            remaining = getattr(lane, "remaining_percent", None)
            lane_id = getattr(lane, "lane_id", None)
            model = getattr(lane, "model", None)
            reset = epoch(getattr(lane, "reset_at", None))
            sibling = horizon_by_reset.get(round(reset)) if reset is not None else None
            if model and sibling is not None and str(lane_id or "").lower() not in USAGE_WINDOW_NAMES:
                lane_id = sibling
            windows.append(
                {
                    "name": usage_window_name(lane_id, getattr(lane, "label", None), model),
                    "id": getattr(lane, "lane_id", None),
                    "used_pct": (
                        round(100.0 - float(remaining), 1) if remaining is not None else None
                    ),
                    "resets_at": epoch(getattr(lane, "reset_at", None)),
                    "scope": getattr(lane, "scope", None),
                    "model": getattr(lane, "model", None),
                }
            )
        state = getattr(getattr(snapshot, "state", None), "value", None)
        account_label = getattr(snapshot, "account_label", None)
        provider_id = getattr(snapshot, "provider_id", "unknown")
        forecast = None
        primary = primary_window(windows)
        if usage_samples is not None and primary is not None and now is not None:
            try:
                forecast = usage_samples.forecast(
                    provider_id,
                    primary.get("id"),
                    used_pct=primary.get("used_pct"),
                    resets_at=primary.get("resets_at"),
                    now=now,
                )
            except Exception:
                forecast = None
        providers.append(
            {
                "id": provider_id,
                "instance": getattr(snapshot, "source_instance_id", "default"),
                # The app's UsageAccount block: {plan, label, fidelity}.
                "account": (
                    {"plan": None, "label": account_label, "fidelity": "stale" if state == "stale" else "official"}
                    if isinstance(account_label, str) and account_label
                    else None
                ),
                "windows": windows,
                "fidelity": "stale" if state == "stale" else "official",
                "state": state,
                "reason": getattr(snapshot, "reason_code", None),
                "action": getattr(snapshot, "action_label", None),
                "observed_at": epoch(getattr(snapshot, "observed_at", None)),
                "tokens": {
                    "input": getattr(snapshot, "input_tokens", 0),
                    "cached_input": getattr(snapshot, "cached_input_tokens", 0),
                    "output": getattr(snapshot, "output_tokens", 0),
                },
                "estimated_cost_usd": getattr(snapshot, "estimated_cost_usd", None),
                "credits_remaining": getattr(snapshot, "credits_remaining", None),
                "forecast": forecast,
            }
        )
    return {
        "refreshed_at": epoch(getattr(usage_state, "refreshed_at", None)),
        "next_refresh_at": epoch(getattr(usage_state, "next_refresh_at", None)),
        "refreshing": bool(getattr(usage_state, "refreshing", False)),
        "providers": providers,
    }


def focus_document(dnd_projection: object) -> dict[str, Any]:
    contributions = getattr(dnd_projection, "contributions", ()) or ()
    mode = "normal"
    source = "default"
    for contribution in contributions:
        contribution_mode = getattr(getattr(contribution, "mode", None), "value", None)
        if contribution_mode:
            mode = contribution_mode
            source = getattr(getattr(contribution, "source", None), "value", source)
            break
    else:
        sources = getattr(dnd_projection, "active_sources", ()) or ()
        if sources:
            source = getattr(sources[0], "value", source)
    return {
        "mode": mode,
        "source": source,
        "until": epoch(getattr(dnd_projection, "next_transition_epoch", None)),
        "display": getattr(getattr(dnd_projection, "display_admission", None), "value", None),
        "brightness_factor": getattr(dnd_projection, "brightness_factor", None),
        "banner_allowed": getattr(dnd_projection, "banner_allowed", None),
        "audible_allowed": getattr(dnd_projection, "audible_allowed", None),
        "summary": getattr(dnd_projection, "summary", None),
    }


def device_document(device: DeviceFacts) -> dict[str, Any]:
    document: dict[str, Any] = {"id": device.id, "kind": device.kind}
    for key in ("name", "path", "leds", "connected", "enabled", "brightness", "linked", "last_write", "error"):
        value = getattr(device, key)
        if value is not None or key in ("error",):
            document[key] = value
    return document


def build_state_document(
    *,
    now: float,
    generation: int,
    snapshot: object,
    ask_statuses: tuple[object, ...] | list[object],
    unseen_completion_ids: frozenset[str] | set[str] | tuple[str, ...],
    operator_state: object = None,
    devices: tuple[DeviceFacts, ...] | list[DeviceFacts] = (),
    usage_state: object = None,
    power: PowerFacts | None = None,
    dnd_projection: object = None,
    escalation: EscalationFacts | None = None,
    intake_report: object = None,
    settings_generation: int = 0,
    extras_by_id: dict[str, SessionExtras] | None = None,
    peers: tuple[dict[str, Any], ...] | list[dict[str, Any]] = (),
    deck: dict[str, Any] | None = None,
    usage_samples: object = None,
    acknowledged_keys: object = (),
) -> dict[str, Any]:
    """The full ``state`` frame. ``snapshot`` is a MonitorSnapshot-shaped
    object; ``deck`` is ``core_deck.build_deck_document``'s ``state.deck``;
    ``usage_samples`` is the daemon's ``UsageSampleBuffer`` for forecasts;
    ``acknowledged_keys`` are the Clear Agents receipts
    (``ClearAgentsState.acknowledged_keys``) that keep cleared rows out of
    the list.

    ``sessions`` holds only what the panel should be looking at: live
    sessions, plus finished ones nobody has acknowledged yet. Everything
    older is in ``list_history``, and ``hidden_count`` says how many main
    sessions that is (see ``completion_visibility``)."""
    extras_by_id = extras_by_id or {}
    statuses: list[object] = []
    seen: set[str] = set()
    for status in list(getattr(snapshot, "statuses", ()) or ()) + list(
        getattr(snapshot, "stale_statuses", ()) or ()
    ):
        agent_id = str(getattr(status, "agent_id", ""))
        if not agent_id or agent_id in seen:
            continue
        if str(getattr(status, "session_id", "") or agent_id).endswith("-install-probe"):
            # The installer's self-test hits the live daemon; it is not a session.
            continue
        seen.add(agent_id)
        statuses.append(status)
    ask_ids = frozenset(str(getattr(status, "agent_id", "")) for status in ask_statuses)
    workers_by_parent: dict[str, int] = {}
    for status in statuses:
        if getattr(status, "is_subagent", False) and not getattr(status, "stale", False):
            mode = getattr(status, "mode", None)
            if mode in _WORKING_MODES or mode is AgentMode.WAITING_FOR_INPUT:
                parent = getattr(status, "parent_agent_id", None)
                if parent:
                    workers_by_parent[parent] = workers_by_parent.get(parent, 0) + 1
    sessions: list[dict[str, Any]] = []
    labels_by_id: dict[str, str] = {}
    ordered = sorted(statuses, key=lambda status: bool(getattr(status, "is_subagent", False)))
    documents_by_id: dict[str, dict[str, Any]] = {}
    for status in ordered:
        agent_id = str(getattr(status, "agent_id", ""))
        parent = getattr(status, "parent_agent_id", None) if getattr(status, "is_subagent", False) else None
        document = session_document(
            status,
            operator_state=operator_state,
            ask_ids=ask_ids,
            extras=extras_by_id.get(agent_id),
            workers=workers_by_parent.get(agent_id, 0),
            parent_label=labels_by_id.get(str(parent)) if parent else None,
        )
        labels_by_id[agent_id] = document["label"]
        documents_by_id[agent_id] = document
    projected = [documents_by_id[str(getattr(status, "agent_id", ""))] for status in statuses]
    sessions, hidden_count, visible_completion_ids = filter_visible_sessions(
        projected,
        now=now,
        acknowledged_at_by_id=acknowledged_epoch_by_session(acknowledged_keys or ()),
    )
    asks = [
        ask_document(status, operator_state, with_session=True)
        for status in ask_statuses
    ]
    mains = [session for session in sessions if session["kind"] == "main"]
    working = sum(1 for session in mains if session["mode"] in {mode.value for mode in _WORKING_MODES} and not session["stale"])
    failed = sum(1 for session in mains if session["lifecycle"] == "failed" and not session["stale"])
    # News is only news while the row that carries it is on screen: a
    # completion that aged out or was cleared stops counting here too.
    unseen = sorted(set(unseen_completion_ids) & set(visible_completion_ids))
    ready = len(unseen)
    aggregate_source = getattr(getattr(snapshot, "aggregate", None), "mode", None)
    power = power or PowerFacts(False, "never", False, False)
    escalation = escalation or EscalationFacts()
    document = {
        "t": "state",
        "v": PROTOCOL_VERSION,
        "generation": int(generation),
        "now": float(now),
        "aggregate": {
            "mode": aggregate_mode(
                aggregate_source if isinstance(aggregate_source, AgentMode) else None,
                asks=len(asks),
                failed=failed,
                working=working,
                ready=ready,
            ),
            "needs_you": len(asks),
            "active": working,
            "ready": ready,
            "failed": failed,
            "total": len(mains),
        },
        "sessions": sessions,
        "hidden_count": int(hidden_count),
        "asks": asks,
        "devices": [device_document(device) for device in devices],
        "usage": usage_document(usage_state, usage_samples=usage_samples, now=now),
        "power": {
            "keep_awake": bool(power.keep_awake),
            "closed_lid": {
                "policy": power.closed_lid_policy,
                "holding": bool(power.closed_lid_holding),
                "helper_installed": bool(power.helper_installed),
            },
        },
        "focus": focus_document(dnd_projection),
        "escalation": {
            "stage": escalation_stage_name(escalation.stage),
            "since": epoch(escalation.since),
        },
        "health": {
            "hooks": hook_health(intake_report),
            "sources": {
                str(getattr(intake, "provider", "")): {
                    "fresh": bool(getattr(intake, "delivering", False)),
                    "heard_age_seconds": getattr(intake, "heard_age_seconds", None),
                }
                for intake in (getattr(intake_report, "providers", ()) or ())
            },
            "intake": (
                {
                    "hook_state": getattr(
                        getattr(getattr(intake_report, "hook_state", None), "code", None), "value", None
                    ),
                    "source_health": getattr(
                        getattr(getattr(intake_report, "source_health", None), "code", None), "value", None
                    ),
                    "silence_seconds": getattr(intake_report, "silence_seconds", None),
                }
                if intake_report is not None
                else None
            ),
        },
        "peers": list(peers),
        "unseen_completions": unseen,
        "settings_generation": int(settings_generation),
    }
    if deck is not None:
        document["deck"] = dict(deck)
    return document


def build_lights_document(
    surfaces: dict[str, SurfaceFacts],
    *,
    linked: bool,
    devices_linked: bool | None = None,
    auto_dim: dict[str, Any] | None = None,
) -> dict[str, Any]:
    """``linked`` is the Screen Bar following the strip; ``devices_linked``
    (when given) says a Pro and a Dot are being written as one unit;
    ``auto_dim`` is the ``AutoDimResult`` document behind the ``auto_dim``
    dimming word (``{mode, source, factor, available, reading}``)."""
    document: dict[str, Any] = {"t": "lights", "v": PROTOCOL_VERSION, "surfaces": {}, "linked": bool(linked)}
    if devices_linked is not None:
        document["devices_linked"] = bool(devices_linked)
    if auto_dim is not None:
        document["auto_dim"] = dict(auto_dim)
    for name, facts in surfaces.items():
        entry: dict[str, Any] = {"program": facts.program}
        for key in ("led_count", "anchor", "motion", "static_fallback", "brightness", "why", "override", "role", "why_detail"):
            value = getattr(facts, key)
            if value is not None:
                entry[key] = value
        document["surfaces"][name] = entry
    return document


#: Keys the daemon adds to the settings document that no settings file
#: carries: facts about the daemon, not preferences. ``set_setting`` on one
#: replies ``read_only``; ``reset_settings`` ignores it.
READ_ONLY_SETTINGS: Final = frozenset({"cloud_ingest_token_path"})


def build_settings_document(
    settings_dict: dict[str, Any],
    *,
    generation: int,
    schema: int = SETTINGS_SCHEMA,
    read_only: dict[str, Any] | None = None,
) -> dict[str, Any]:
    document = dict(settings_dict)
    for key, value in (read_only or {}).items():
        if key in READ_ONLY_SETTINGS:
            document[key] = value
    return {
        "t": "settings",
        "v": PROTOCOL_VERSION,
        "generation": int(generation),
        "schema": int(schema),
        "document": document,
    }


def history_rows(ledger: object, *, since: float | None = None, limit: int = 500) -> list[dict[str, Any]]:
    """``list_history`` rows from an ActivityLedger-shaped object, newest first."""
    last_seen = float(getattr(ledger, "last_seen_epoch", 0.0) or 0.0)
    rows: list[dict[str, Any]] = []
    for entry in getattr(ledger, "entries", ()) or ():
        at = epoch(getattr(entry, "occurred_at_epoch", None))
        if at is None or (since is not None and at < float(since)):
            continue
        kind_value = getattr(getattr(entry, "kind", None), "value", None) or str(getattr(entry, "kind", ""))
        rows.append(
            {
                "at": at,
                "kind": _LEDGER_KINDS.get(kind_value, kind_value),
                "provider": getattr(entry, "provider", None),
                "session": getattr(entry, "subject_id", None),
                "label": getattr(entry, "label", None),
                "detail": getattr(entry, "detail", None),
                "duration": None,
                "unseen": at > last_seen,
            }
        )
    rows.sort(key=lambda row: row["at"], reverse=True)
    return rows[: max(0, int(limit))]


__all__ = [
    "COMPLETED_VISIBLE_SECONDS",
    "LIVE_VISIBLE_SECONDS",
    "ORIGIN_BUNDLE_IDS",
    "PROTOCOL_VERSION",
    "PROVIDER_LABELS",
    "READ_ONLY_SETTINGS",
    "SETTINGS_SCHEMA",
    "TERMINAL_APPS",
    "TERMINAL_BUNDLE_IDS",
    "USAGE_WINDOW_NAMES",
    "WHY_VALUES",
    "DeviceFacts",
    "EscalationFacts",
    "LightFacts",
    "PowerFacts",
    "SessionExtras",
    "SurfaceFacts",
    "aggregate_mode",
    "ask_document",
    "build_lights_document",
    "build_settings_document",
    "build_state_document",
    "epoch",
    "escalation_stage_name",
    "focus_document",
    "history_rows",
    "hook_health",
    "lifecycle_for_mode",
    "light_why",
    "origin_document",
    "origin_kind",
    "primary_window",
    "session_document",
    "session_label",
    "short_session_id",
    "strip_session_short_id",
    "terminal_from_command",
    "usage_document",
    "usage_window_name",
    "why_detail",
    "why_for_glance",
]
