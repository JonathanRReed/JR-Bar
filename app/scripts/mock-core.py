#!/usr/bin/env python3
"""A mock jrbar-core daemon for exercising the native app without the real core.

Speaks protocol 1 (docs/CORE-PROTOCOL.md) over a Unix socket: on connect it
sends hello, a full state, lights and settings, then plays a scripted
timeline so every panel section has something to show:

  0. a Claude session starts working              (working relay on the lights)
  1. two key presses and a dial turn on the deck   (deck_input)
  2. a Codex permission ask opens                  (amber ask pulse, ask_opened)
  3. the ask escalates to stage 2                  (escalation_stage 2: menu-bar pulse)
  4. ...and to stage 3                             (escalation_stage 3: chime)
  5. the ask resolves (or you Approve/Deny it)     (ask_resolved)
  6. Codex completes                               (completed, done light)
  7. the SidePulse Pro disconnects                 (device_disconnected)
  8. ...and reconnects                             (device_connected)
  9. another app answers on the deck's stream      (device.conflict, deck_receipt device_conflict)
 10. ...and the deck reconnects                    (deck_receipt connection_changed)
 11. Gemini fails                                  (failed)
 12. Claude completes                              (completed)
 13. everything goes idle                          (idle breath)

then stops (`--loop` replays it forever; the timeline plays sounds, so a
dev run should not loop by accident). Usage numbers tick up every step (and cross the quota
thresholds, `quota_crossed`; the idle step resets them, `quota_reset`).
Every step is recorded in the history (`list_history`); rows seeded at
startup are marked `unseen` so the History window's away banner shows.
Commands are logged to stderr and answered with an ok reply; answer_ask,
set_brightness, clear_completed / undo_clear, quiet and snooze also change
the world so the UI round-trips.

App-proposed extensions (documented in app/README.md): `usage_history`
(deterministic daily/hourly token and cost rows per provider), `list_effects`
(the effect registry mirrored from src/jrbar/effect_registry.py plus a sample
data-only pack, each effect with a rendered 8-LED LEDS preview),
`render_effect` (the preview for chosen parameters), `list_assignments`
(the scoped assignments with their parameters and the active scene), and
`import_effect_pack` / `export_effect_pack` (JSON v2 packs by path).
Assignments are written through the protocol's own `apply_effect`
(`{effect, scope, target}`, effect null to remove) with an app-proposed
`parameters` argument.

The Creator Micro 2 deck (`state.deck`, `deck_*` commands, `deck_input` and
`deck_receipt` events) is an app-proposed extension too; see app/README.md.

Standard library only.

  mock-core.py                       # listen on $TMPDIR/jrbar-mock.sock (never the installed daemon's socket)
  mock-core.py --socket /tmp/x.sock  # elsewhere
  mock-core.py --step 1.5            # seconds between timeline steps
  mock-core.py --once                # hello/state/lights/settings, then exit
"""

from __future__ import annotations

import argparse
import hashlib
import json
import os
import signal
import socket
import sys
import threading
import time
from pathlib import Path

PROTOCOL_VERSION = 1
# The installed daemon's socket. The mock never binds it unless told so in
# so many words: the owner's app (a LaunchAgent) connects there, and a mock
# on that path drives the real menu bar, sounds and notifications.
REAL_SOCKET = Path(os.environ.get("XDG_STATE_HOME") or Path.home() / ".local" / "state") / "jrbar" / "core.sock"
DEFAULT_SOCKET = Path(os.environ.get("TMPDIR") or "/tmp") / "jrbar-mock.sock"

WORKING_RELAY = (
    "off 160ms cosine\n"
    "0:#00E5FF 1400ms pulse 0ms; 1:#00E5FF 1400ms pulse 170ms; 2:#00E5FF 1400ms pulse 340ms; "
    "3:#00E5FF 1400ms pulse 510ms; 4:#00E5FF 1400ms pulse 680ms; 5:#00E5FF 1400ms pulse 850ms; "
    "6:#00E5FF 1400ms pulse 1020ms; 7:#00E5FF 1400ms pulse 1190ms\n"
    "repeat"
)
ASK_PULSE = "off 160ms cosine\n#FF3A00 1.6s pulse\nrepeat"
COMPLETED_UNSEEN = "off 160ms cosine\n#00FF66 2200ms pulse\nrepeat"
IDLE_BREATH = "off 160ms cosine\n#2B2F36 1900ms cosine\noff 2550ms cosine\noff 850ms none\nrepeat"
DOT_WORKING = "off 160ms cosine\n0:#00E5FF 1400ms pulse 0ms; 1:#00E5FF 1400ms pulse 700ms\nrepeat"
DOT_ASK = ASK_PULSE
DOT_DONE = COMPLETED_UNSEEN
DOT_IDLE = IDLE_BREATH

# The `asks` beacon (docs/CORE-PROTOCOL.md, "The Dot's role"): dark until
# something needs the person, then a breath whose cadence tightens with the
# escalation stage. Both phases are cosine, every cadence at or under 1 Hz.
BEACON_CADENCE_MS = {0: 1200, 1: 900, 2: 600, 3: 500}


def beacon_program(color: str, stage: int) -> str:
    ms = BEACON_CADENCE_MS.get(stage, 1200)
    return f"{color} {ms}ms cosine\noff {ms}ms cosine\nrepeat"


BEACON_DARK = "off"
# What an unlinked Dot has always rendered for itself: the ambient
# dispatch's `dot_binary_heartbeat`.
DOT_BINARY_HEARTBEAT = "off 200ms none\n0:#3A3A3C 220ms cosine\n0:#000000 220ms cosine\n1:#3A3A3C 220ms cosine\n1:#000000 220ms cosine\noff 1200ms none\nrepeat"

HOME = str(Path.home())
CLAUDE_ID = "claude:session:fca1eb06-f6d1-413e-aa5f-dd19d8e05973"
CLAUDE_WORKER_ID = "claude:session:fca1eb06-f6d1-413e-aa5f-dd19d8e05973:worker:1"
CODEX_ID = "codex:session:0f3b2c9a-71d4-4e0e-9a8e-2c1d5f6a7b8c"
GEMINI_ID = "gemini:session:8a1c2e3f-5b6d-4c7e-9f0a-1b2c3d4e5f6a"
PRO_ID = "sidepulse:pro:B293A1"
DOT_ID = "sidepulse:dot:7F02C4"

# The Creator Micro 2 deck, mirrored from src/jrbar/deck_session_board.py,
# creator_micro_keymap.py and creator_micro_lighting.py (captured
# 2026-09-10): 13 session slots per bank on a key matrix of rows [2, 4, 4, 3]
# (vendor keycodes KV_OAI_AG00..AG12), seven auxiliary controls AG13..AG19
# (one encoder with three inputs, four joystick sectors), four calibrated
# analog sectors (indices 20..23), a compact edge rail of 14 cells, and a
# keymap the daemon applies to one profile/layer and restores from a backup.
DECK_SERIAL = "WL2-7C41-0F9E"
DECK_SLOTS = 13
DECK_ROWS = (2, 4, 4, 3)
DECK_AUX_LABELS = {13: "Encoder 1 input 1", 14: "Encoder 1 input 2", 15: "Encoder 1 input 3",
                   16: "Joystick sector 1", 17: "Joystick sector 2", 18: "Joystick sector 3", 19: "Joystick sector 4"}
DECK_ANALOG = 4
DECK_RAIL_EDGES = ("off", "left", "right", "top", "bottom")
DECK_STATES = ("input_required", "failure", "active", "completed", "idle", "stale", "unavailable", "unknown",
               "ended_unconfirmed")
# Per-key lighting is a solid colour: ask, working, done, else dark.
DECK_STATE_COLORS = {"input_required": "#FF3A00", "failure": "#FF3A00", "active": "#00E5FF", "completed": "#00FF66"}
DECK_DARK = "#020204"
# The stock keymap of the mock's pad: one profile with two layers.
DECK_STOCK_LAYERS = [
    {"profile": 0, "layer": 0, "name": "Base",
     "keys": [["KC_1", "KC_2"], ["KC_Q", "KC_W", "KC_E", "KC_R"], ["KC_A", "KC_S", "KC_D", "KC_F"], ["KC_Z", "KC_X", "KC_C"]],
     "encoders": [["KC_VOLD", "KC_VOLU", "KC_MUTE"]],
     "joystick": ["KC_UP", "KC_RIGHT", "KC_DOWN", "KC_LEFT"]},
    {"profile": 0, "layer": 1, "name": "Fn",
     "keys": [["KC_F1", "KC_F2"], ["KC_F3", "KC_F4", "KC_F5", "KC_F6"], ["KC_F7", "KC_F8", "KC_F9", "KC_F10"],
              ["KC_F11", "KC_F12", "KC_NO"]],
     "encoders": [["KC_BRID", "KC_BRIU", "KC_NO"]],
     "joystick": ["KC_NO", "KC_NO", "KC_NO", "KC_NO"]},
]
# User-facing receipt strings, verbatim from creator_micro_setup_controller.py.
DECK_RECEIPT_MESSAGES = {
    "keymap_verified": "Creator Micro 2 stored keymap verified. Reconnect if needed, then check inputs.",
    "recovery_required": "A transfer was interrupted. Backup retained. Choose Restore device keymap, not Apply again.",
    "unsupported_file_protocol": "This firmware does not support the verified file-transfer protocol. No keymap was written.",
    "connection_changed": "The device connection changed. Inspect again; pending input was discarded.",
    "device_conflict": "Close Input and other hardware controllers, then inspect again.",
    "already_configured": "Creator Micro 2 keymap is already configured.",
    "keymap_restored": "Creator Micro 2 keymap restored and verified.",
    "already_restored": "Creator Micro 2 keymap is already restored.",
    "connection_required": "Connect and approve Creator Micro 2 before setup.",
    "approved_device_changed": "The approved Creator Micro 2 changed. Inspect it again.",
    "previous_owner_stopping": "Creator Micro 2 is still stopping. Try again in a moment.",
    "keymap_changed": "The device keymap changed. Inspect it again before applying.",
    "backup_failed": "The private backup could not be verified. No keymap was written.",
    "backup_invalid": "No valid private backup is available. No keymap was written.",
    "readback_mismatch": "The device did not verify the keymap write. The backup was kept.",
    "cancelled": "Creator Micro 2 setup was cancelled.",
}


def deck_receipt_message(code: str) -> str:
    return DECK_RECEIPT_MESSAGES.get(code, f"Creator Micro 2: {code.replace('_', ' ')}.")


def deck_identity(session_id: str) -> str:
    """The board keys slots by a digest of the work key, never the raw id."""
    return hashlib.sha256(session_id.encode("utf-8")).hexdigest()[:24]


def deck_control_label(index: int) -> str:
    if 0 <= index < DECK_SLOTS:
        return f"Key {index + 1}"
    if index in DECK_AUX_LABELS:
        return DECK_AUX_LABELS[index]
    if 20 <= index < 20 + DECK_ANALOG:
        return f"Analog sector {index - 19}"
    return f"AG{index:02d}"

# --------------------------------------------------------------------------
# Effects: the registry mirrored from src/jrbar/effect_registry.py (captured
# 2026-09-09), a parametric LEDS renderer for previews, and data-only packs.
# --------------------------------------------------------------------------

import colorsys
import random

EFFECT_BASE_COLOR = "#00E5FF"
MIN_CYCLE_SECONDS = 0.3
MAX_CYCLE_SECONDS = 10.0
DEFAULT_CYCLE_SECONDS = 2.2
MIN_FLASH_CYCLE_MS = 500

BLINK_CADENCES = [
    {"id": "calm", "label": "Calm", "on_ms": 1100, "off_ms": 1100, "pulses": 1, "rest_ms": 0},
    {"id": "deliberate", "label": "Deliberate", "on_ms": 500, "off_ms": 500, "pulses": 1, "rest_ms": 0},
    {"id": "double", "label": "Deliberate double", "on_ms": 300, "off_ms": 300, "pulses": 2, "rest_ms": 1400},
]


def _num(name, default, description, minimum, maximum, unit=None):
    p = {"name": name, "type": "number", "default": float(default), "description": description,
         "minimum": float(minimum), "maximum": float(maximum)}
    if unit:
        p["unit"] = unit
    return p


def _int(name, default, description, minimum, maximum):
    return {"name": name, "type": "integer", "default": int(default), "description": description,
            "minimum": int(minimum), "maximum": int(maximum)}


def _choice(name, default, description, choices):
    return {"name": name, "type": "choice", "default": default, "description": description, "choices": list(choices)}


def _bool(name, default, description):
    return {"name": name, "type": "boolean", "default": bool(default), "description": description}


def _palette(name, description, maximum_items):
    return {"name": name, "type": "palette", "default": [], "description": description,
            "minimum_items": 2, "maximum_items": maximum_items, "allow_empty": True}


def _duration(minimum=None):
    return _num("duration_seconds", DEFAULT_CYCLE_SECONDS, "Length of one complete motion cycle.",
                MIN_CYCLE_SECONDS if minimum is None else minimum, MAX_CYCLE_SECONDS, unit="seconds")


_DIRECTIONS = ("forward", "reverse")
_PASS_MODES = ("continuous", "once", "twice")

PROVIDER_ANIMATIONS = [
    # id, label, description, role, energy, parameters
    ("auto", "Automatic", "Follows the state: breathe when idle, chase while working.", "adaptive", "low", [
        _choice("mapping_source", "state", "Choose the current state map or a Scene-specific map.", ("state", "scene")),
        _bool("urgent_overrides", True, "Keep reserved asking and failure motion overrides visible."),
    ]),
    ("breathe", "Breathe", "One slow swell, every LED together.", "ambient", "low", [
        _duration(), _num("amplitude", 1.0, "Relative distance between the luminous floor and crest.", 0.1, 1.0),
    ]),
    ("duotone", "Duotone", "A slow swell that alternates between two tones of the color. Cycle turns keep both tones; interleaved strips breathe.", "identity_state", "medium", [
        _duration(),
        _num("secondary_hue_offset_degrees", 40.0, "Hue offset used when no explicit two-color palette is supplied.", -180.0, 180.0, unit="degrees"),
        _palette("palette", "Optional validated identity and state colors; empty derives both tones.", 2),
    ]),
    ("chase", "Chase", "The same swell, staggered into a travelling wave.", "directional_flow", "medium", [
        _duration(), _choice("direction", "forward", "Direction of travel.", _DIRECTIONS),
        _int("spacing", 1, "LED spacing between wave crests.", 1, 6),
        _num("softness", 1.0, "Edge softness of the travelling wave.", 0.0, 1.0),
    ]),
    ("gradient", "Gradient", "The travelling wave, but each LED carries its own shade of the color — a gradient rolling by. Shared strips keep the flare; Cycle turns keep the shades.", "ambient", "medium", [
        _duration(), _choice("direction", "forward", "Direction of gradient travel.", _DIRECTIONS),
        _num("hue_span_degrees", 48.0, "Derived palette span when no explicit endpoints are supplied.", 0.0, 120.0, unit="degrees"),
        _palette("palette", "Optional bounded gradient endpoints; empty derives them from identity color.", 2),
        _bool("smooth_morph", True, "Morph smoothly when state colors change."),
    ]),
    ("heartbeat", "Heartbeat", "Two quick swells, then a long rest — a lub-dub.", "provider_identity", "medium", [
        _duration(0.5), _num("rest_ratio", 0.5, "Fraction of the cycle reserved after the decorative lub-dub.", 0.35, 0.8),
    ]),
    ("scanner", "Scanner", "A bright dot sweeps end to end and bounces back. Shared strips ride it as a narrow travelling flare.", "mechanical", "medium", [
        _duration(0.5), _int("beam_width", 1, "Width of the bright scanning beam in LEDs.", 1, 8),
        _num("trail", 0.35, "Relative length of the fading trail.", 0.0, 1.0),
    ]),
    ("kitt", "Knight Rider", "The classic scanner: a wide bright eye sweeps end to end and back, overlapping as it goes. Shared strips ride it as a narrow travelling flare.", "mechanical", "medium", [
        _duration(0.5), _int("beam_width", 3, "Width of the overlapping mechanical eye.", 2, 10),
        _num("overlap", 0.5, "Overlap between the eye's light bands.", 0.1, 1.0),
    ]),
    ("comet", "Comet", "A bright head sweeps one way, trailing off behind. Shared strips ride it as a narrow travelling flare.", "transition", "medium", [
        _duration(0.5), _int("head_width", 1, "Width of the bright comet head in LEDs.", 1, 6),
        _int("trail_length", 3, "Length of the fading trail in LEDs.", 1, 12),
        _choice("direction", "forward", "Direction of comet travel.", _DIRECTIONS),
        _choice("pass_mode", "continuous", "Continuous loop or a bounded transition pass count.", _PASS_MODES),
    ]),
    ("flicker", "Flicker", "A warm candle-like shimmer that never quite repeats.", "ambient", "medium", [
        _duration(0.5), _int("seed", 271, "Seed for deterministic luminance variation.", 0, 2_147_483_647),
        _num("luminance_floor", 0.35, "Lowest relative luminance.", 0.1, 0.8),
        _num("variation", 0.25, "Maximum deterministic luminance variation.", 0.0, 0.5),
    ]),
    ("stack", "Stack", "LEDs pile on one by one until full, then it all lets go. Keeps its hard pile-on in shared strips.", "progress", "medium", [
        _duration(0.5), _choice("fill_direction", "forward", "Direction in which LEDs accumulate.", _DIRECTIONS),
        _choice("release_behavior", "all_at_once", "How a completed stack returns to its luminous floor.", ("all_at_once", "hold", "decay")),
        _choice("data_mapping", "none", "Optional reliable count represented by the stack.", ("none", "queue", "milestone")),
    ]),
    ("twinkle", "Twinkle", "A dim base with single LEDs briefly sparking, scattered.", "ambient", "medium", [
        _duration(0.5), _num("density", 0.15, "Maximum fraction of LEDs sparkling at once.", 0.02, 0.3),
        _int("seed", 271, "Seed for deterministic sparkle placement.", 0, 2_147_483_647),
        _int("max_cluster", 1, "Largest allowed adjacent sparkle cluster.", 1, 2),
    ]),
    ("drift", "Drift", "Glacial detuned swells, like light on slow water.", "ambient", "low", [
        _duration(1.0), _num("detune", 0.08, "Phase variation between slow luminous swells.", 0.0, 0.25),
        _num("sample_interval_seconds", 0.25, "Minimum cadence for deterministic drift updates.", 0.1, 2.0, unit="seconds"),
    ]),
    ("converge", "Converge", "Two dots leave the ends and meet in the middle. In a Split block the fronts meet mid-block.", "handoff", "medium", [
        _duration(0.5), _choice("variant", "endpoints_to_center", "Convergence geometry used for merge or handoff meaning.", ("endpoints_to_center", "source_to_destination")),
    ]),
    ("aurora", "Aurora", "Rolling waves of light over a luminous base.", "ambient", "high", [
        _duration(1.0), _palette("palette", "Optional bounded aurora palette; empty derives tones from identity color.", 4),
        _int("wave_count", 2, "Number of slow layered waves.", 1, 4),
        _int("seed", 617, "Seed for deterministic wave phases.", 0, 2_147_483_647),
    ]),
    ("tide", "Tide", "The bar rises to full, then the water pulls back. Shared strips ride it as the full swell.", "capacity", "medium", [
        _duration(0.5), _num("fill_floor", 0.15, "Minimum filled fraction before the tide rises.", 0.0, 0.8),
        _num("fill_range", 0.85, "Additional filled fraction at full tide.", 0.1, 1.0),
    ]),
    ("marquee", "Marquee", "A palette seeded from the color, endlessly rotating around the bar. Shared strips ride it as a narrow travelling flare.", "identity", "medium", [
        _duration(0.5), _int("spacing", 1, "LED spacing between palette bands.", 1, 8),
        _choice("direction", "forward", "Direction of palette rotation.", _DIRECTIONS),
        _num("palette_rotation_degrees", 48.0, "Derived palette rotation when no explicit palette is supplied.", 0.0, 180.0, unit="degrees"),
        _choice("pass_mode", "continuous", "Continuous loop or a bounded transition pass count.", _PASS_MODES),
    ]),
    ("steady", "Steady", "Holds its color. Never moves.", "persistent", "low", [
        _num("luminance", 1.0, "Relative persistent luminance.", 0.05, 1.0),
    ]),
    ("blink", "Blink", "Hard-edged on/off, no easing.", "attention", "medium", [
        _choice("cadence", "calm", "Named cadence; arbitrary flash frequency is intentionally unsupported.", tuple(c["id"] for c in BLINK_CADENCES)),
        _bool("repeat", True, "Repeat the selected named cadence."),
    ]),
]

ALL_SURFACES = ["status_bar", "screen_bar", "sidepulse_pro", "sidepulse_dot", "glance_light", "settings_preview"]

BUILTIN_EFFECTS = [
    {"id": "none", "label": "No effect", "description": "Hold the selected color steady.", "meaning": "steady color",
     "surfaces": ALL_SURFACES, "safety": "safe", "energy": "low", "reduce_motion_fallback": None, "role": "general", "catalog": "general", "parameters": []},
    {"id": "pulse", "label": "Pulse", "description": "A restrained brightness pulse.", "meaning": "periodic activity",
     "surfaces": ALL_SURFACES, "safety": "safe", "energy": "medium", "reduce_motion_fallback": "none", "role": "general", "catalog": "general", "parameters": []},
    {"id": "rainbow", "label": "Rainbow", "description": "Cycle through the selected palette.", "meaning": "cycling color activity",
     "surfaces": ["status_bar", "screen_bar", "sidepulse_pro", "settings_preview"], "safety": "safe", "energy": "medium", "reduce_motion_fallback": "none", "role": "general", "catalog": "general", "parameters": []},
    {"id": "alert", "label": "Alert", "description": "A high-visibility attention signal.", "meaning": "attention required",
     "surfaces": ALL_SURFACES, "safety": "attention", "energy": "high", "reduce_motion_fallback": "pulse", "role": "general", "catalog": "general", "parameters": [], "cadence": "deliberate"},
    {"id": "notification", "label": "Notification", "description": "A short notification flash.", "meaning": "new event",
     "surfaces": ALL_SURFACES, "safety": "attention", "energy": "low", "reduce_motion_fallback": "none", "role": "general", "catalog": "general", "parameters": [], "cadence": "double"},
]

# A data-only pack (JSON v2, effect_packs.py) the mock ships loaded, so the
# library shows pack badges and Export has something namespaced to write.
SAMPLE_PACK = {
    "id": "nightlab",
    "name": "Night Lab",
    "version": 2,
    "safety": {"data_only": True, "network": False},
    "accessibility": {"reduced_motion": True, "high_contrast": True},
    "license": {"spdx_id": "CC0-1.0", "label": "Creative Commons Zero", "source_url": "https://example.org/nightlab"},
    "effects": [
        {"id": "ember", "label": "Ember", "description": "A low warm shimmer for late sessions.", "meaning": "quiet presence",
         "surfaces": ["screen_bar", "sidepulse_pro", "settings_preview"], "safety": "safe", "energy": "low",
         "reduce_motion_fallback": "coal", "motion": "flicker", "color": "#FF7A1A", "duration_seconds": 3.0, "luminance_floor": 0.25},
        {"id": "coal", "label": "Coal", "description": "The ember at rest.", "meaning": "quiet presence",
         "surfaces": ["screen_bar", "sidepulse_pro", "sidepulse_dot", "settings_preview"], "safety": "safe", "energy": "low",
         "motion": "steady", "color": "#8A2E00", "luminance": 0.6},
        {"id": "lighthouse", "label": "Lighthouse", "description": "A slow beam that sweeps past every few seconds.", "meaning": "periodic activity",
         "surfaces": ["screen_bar", "sidepulse_pro", "settings_preview"], "safety": "safe", "energy": "medium",
         "reduce_motion_fallback": "coal", "motion": "scanner", "color": "#FFE9B0", "duration_seconds": 4.0, "beam_width": 2},
        {"id": "beacon", "label": "Beacon", "description": "A hard red beacon for things that cannot wait.", "meaning": "critical alert",
         "surfaces": ["screen_bar", "sidepulse_pro", "sidepulse_dot", "settings_preview"], "safety": "critical", "energy": "high",
         "reduce_motion_fallback": "coal", "motion": "blink", "color": "#FF2D1A", "cadence": "deliberate"},
    ],
}

_PACK_METADATA_KEYS = {"id", "label", "description", "meaning", "surfaces", "safety", "energy", "reduce_motion_fallback"}
_PACK_CODE_KEYS = {"callback", "code", "command", "entrypoint", "executable", "handler", "hook", "import", "module", "plugin", "script"}
_MOTION_IDS = {row[0] for row in PROVIDER_ANIMATIONS}


def _is_hex(value) -> bool:
    return isinstance(value, str) and len(value) == 7 and value[0] == "#" and all(c in "0123456789abcdefABCDEF" for c in value[1:])


def _infer_parameter(name: str, value):
    """Pack effects carry untyped data; type them for the studio's controls."""
    if isinstance(value, bool):
        return _bool(name, value, f"{name.replace('_', ' ').capitalize()} (pack value).")
    if isinstance(value, int):
        return _int(name, value, f"{name.replace('_', ' ').capitalize()} (pack value).", 0, max(10, value * 2))
    if isinstance(value, float):
        return _num(name, value, f"{name.replace('_', ' ').capitalize()} (pack value).", 0.0, max(10.0, value * 2))
    if _is_hex(value):
        return {"name": name, "type": "color", "default": value.upper(), "description": f"{name.replace('_', ' ').capitalize()} (pack value)."}
    if isinstance(value, list) and value and all(_is_hex(v) for v in value):
        return {"name": name, "type": "palette", "default": [v.upper() for v in value], "description": f"{name.replace('_', ' ').capitalize()} (pack value).",
                "minimum_items": 2, "maximum_items": max(len(value), 4), "allow_empty": False}
    if name == "motion" and isinstance(value, str):
        return _choice(name, value if value in _MOTION_IDS else "breathe", "Base motion the pack effect is rendered with.", sorted(_MOTION_IDS))
    if name == "cadence" and isinstance(value, str):
        return _choice(name, value, "Named blink cadence.", tuple(c["id"] for c in BLINK_CADENCES))
    return _choice(name, str(value), f"{name.replace('_', ' ').capitalize()} (pack value).", (str(value),))


def validate_pack(payload) -> dict:
    """Mirror effect_packs.validate_pack: bounded, data-only, v1 migrated to v2."""
    if not isinstance(payload, dict):
        raise ValueError("pack must be an object")
    pack = json.loads(json.dumps(payload))
    version = pack.get("version", pack.get("schema_version", 1))
    if version == 1:
        pack["version"] = 2
        pack.setdefault("safety", {"data_only": True, "network": False})
        pack.setdefault("accessibility", {"reduced_motion": True, "high_contrast": True})
    if pack.get("version") != 2:
        raise ValueError("unsupported pack version")
    if len(json.dumps(pack)) > 256_000:
        raise ValueError("pack exceeds size limit")

    def reject_code(value, path="pack"):
        if isinstance(value, dict):
            for key, child in value.items():
                if not isinstance(key, str) or key.lower() in _PACK_CODE_KEYS:
                    raise ValueError(f"{path} contains executable content")
                reject_code(child, f"{path}.{key}")
        elif isinstance(value, list):
            for index, child in enumerate(value):
                reject_code(child, f"{path}[{index}]")
        elif isinstance(value, str):
            lowered = value.lower()
            if any(marker in lowered for marker in ("python", "subprocess", "/bin/", "eval(", "exec(")):
                raise ValueError(f"{path} contains executable content")

    reject_code(pack)
    pack_id = pack.get("id", pack.get("pack_id"))
    if not isinstance(pack_id, str) or not pack_id or not all(c.islower() or c.isdigit() or c in "._-" for c in pack_id):
        raise ValueError("id must be a lowercase data identifier")
    pack["id"] = pack_id
    if not isinstance(pack.get("name"), str) or not pack["name"].strip():
        raise ValueError("name must be a non-empty bounded string")
    effects = pack.get("effects")
    if not isinstance(effects, list) or len(effects) > 128:
        raise ValueError("effects must be a bounded list")
    seen = set()
    for index, effect in enumerate(effects):
        if not isinstance(effect, dict) or not isinstance(effect.get("id"), str) or not effect["id"]:
            raise ValueError(f"effects[{index}] needs an id")
        if effect["id"] in seen:
            raise ValueError(f"duplicate effect identifier: {effect['id']}")
        seen.add(effect["id"])
        effect.setdefault("label", effect["id"])
        fallback = effect.get("reduce_motion_fallback")
        if fallback is not None and fallback not in {e.get("id") for e in effects if isinstance(e, dict)}:
            raise ValueError(f"effect {effect['id']} has an unknown reduced-motion fallback")
    safety = pack.get("safety")
    if not isinstance(safety, dict) or safety.get("data_only") is not True or safety.get("network", False) is not False:
        raise ValueError("safety metadata must declare data_only and no network")
    accessibility = pack.get("accessibility")
    if not isinstance(accessibility, dict) or any(accessibility.get(k) is not True for k in ("reduced_motion", "high_contrast")):
        raise ValueError("accessibility metadata must support reduced motion and high contrast")
    return pack


def pack_effect_definitions(pack: dict) -> list[dict]:
    definitions = []
    for effect in pack["effects"]:
        parameters = [_infer_parameter(key, value) for key, value in sorted(effect.items()) if key not in _PACK_METADATA_KEYS]
        fallback = effect.get("reduce_motion_fallback")
        definitions.append({
            "id": f"pack:{pack['id']}:{effect['id']}",
            "label": str(effect["label"]),
            "description": str(effect.get("description", effect["label"])),
            "meaning": str(effect.get("meaning", f"{pack['name']}: {effect['label']}")),
            "surfaces": list(effect.get("surfaces", ["settings_preview"])),
            "safety": str(effect.get("safety", "safe")),
            "energy": str(effect.get("energy", "low")),
            "reduce_motion_fallback": f"pack:{pack['id']}:{fallback}" if fallback else None,
            "version": pack["version"],
            "catalog": f"pack:{pack['id']}",
            "role": "general",
            "pack": pack["id"],
            "parameters": parameters,
        })
    return definitions


def registry_effects() -> list[dict]:
    effects = []
    for identifier, label, description, role, energy, parameters in PROVIDER_ANIMATIONS:
        effects.append({
            "id": identifier, "label": label, "description": description, "meaning": f"provider animation: {identifier}",
            "surfaces": ["screen_bar", "settings_preview"], "safety": "safe", "energy": energy,
            "reduce_motion_fallback": "steady", "version": 1, "catalog": "provider_animation", "role": role,
            "parameters": parameters,
        })
    for effect in BUILTIN_EFFECTS:
        row = dict(effect)
        row["version"] = 1
        effects.append(row)
    return effects


# -- colour helpers -----------------------------------------------------------

def _rgb(hex_color: str) -> tuple[float, float, float]:
    value = int(hex_color[1:], 16)
    return ((value >> 16 & 255) / 255.0, (value >> 8 & 255) / 255.0, (value & 255) / 255.0)


def _hex(rgb: tuple[float, float, float]) -> str:
    return "#%02X%02X%02X" % tuple(max(0, min(255, int(round(c * 255)))) for c in rgb)


def _scale(hex_color: str, factor: float) -> str:
    r, g, b = _rgb(hex_color)
    return _hex((r * factor, g * factor, b * factor))


def _mix(a: str, b: str, t: float) -> str:
    ra, ga, ba = _rgb(a)
    rb, gb, bb = _rgb(b)
    return _hex((ra + (rb - ra) * t, ga + (gb - ga) * t, ba + (bb - ba) * t))


def _hue_shift(hex_color: str, degrees: float) -> str:
    h, s, v = colorsys.rgb_to_hsv(*_rgb(hex_color))
    return _hex(colorsys.hsv_to_rgb((h + degrees / 360.0) % 1.0, s, v))


def _ms(seconds: float) -> int:
    return max(17, int(round(seconds * 1000)))


def _stagger(colors_by_led: list[str], duration_ms: int, delays_ms: list[int], easing: str = "pulse") -> str:
    return "; ".join(f"{i}:{c} {duration_ms}ms {easing} {delays_ms[i]}ms" for i, c in enumerate(colors_by_led))


def normalize_effect_parameters(effect: dict, values) -> dict:
    """Defaults for anything missing, bounds and choices enforced."""
    values = values if isinstance(values, dict) else {}
    result = {}
    for parameter in effect.get("parameters", []):
        name = parameter["name"]
        kind = parameter["type"]
        value = values.get(name, parameter["default"])
        try:
            if kind == "boolean":
                value = bool(value)
            elif kind == "integer":
                value = int(round(float(value)))
                value = max(parameter.get("minimum", value), min(parameter.get("maximum", value), value))
            elif kind == "number":
                value = float(value)
                value = max(parameter.get("minimum", value), min(parameter.get("maximum", value), value))
            elif kind == "choice":
                value = value if value in parameter["choices"] else parameter["default"]
            elif kind == "color":
                value = value.upper() if _is_hex(value) else parameter["default"]
            elif kind == "palette":
                value = [v.upper() for v in value if _is_hex(v)] if isinstance(value, list) else list(parameter["default"])
                if len(value) < parameter.get("minimum_items", 0) and not (parameter.get("allow_empty") and not value):
                    value = list(parameter["default"])
                value = value[: parameter.get("maximum_items", 8)]
        except (TypeError, ValueError, AttributeError):
            value = parameter["default"]
        result[name] = value
    return result


def render_effect_program(effect: dict, values: dict, led_count: int = 8, color: str = EFFECT_BASE_COLOR) -> str:
    """One LEDS program (≤ 20 lines, ≤ 512 bytes) for an effect and its parameters."""
    params = normalize_effect_parameters(effect, values)
    identifier = effect["id"]
    n = max(2, min(8, led_count))
    motion = identifier
    if effect.get("pack"):
        motion = params.get("motion", "breathe")
        color = params.get("color", color) if _is_hex(params.get("color", "")) else color
    if motion == "auto":
        motion = "breathe"
    c = color.upper()
    d = _ms(float(params.get("duration_seconds", DEFAULT_CYCLE_SECONDS)))
    floor = _scale(c, 0.08)
    forward = params.get("direction", params.get("fill_direction", "forward")) == "forward"

    def order(i: int) -> int:
        return i if forward else n - 1 - i

    if motion == "steady":
        return _scale(c, float(params.get("luminance", 1.0)))
    if motion == "none":
        return c
    if motion == "pulse":
        return f"off 160ms cosine\n{c} 1600ms pulse\nrepeat"
    if motion == "rainbow":
        hues = " ".join(_hue_shift("#FF0044", i * 360.0 / n) for i in range(n))
        return f"{hues}\nroll 2s linear\nrepeat"
    if motion == "alert":
        return f"#FF3A00 500ms none\noff 500ms none\nrepeat"
    if motion == "notification":
        return f"{c} 300ms none\noff 300ms none\n{c} 300ms none\noff 1400ms cosine"
    if motion == "breathe":
        low = _scale(c, 1.0 - 0.92 * float(params.get("amplitude", 1.0)))
        return f"{low}\n{c} {d}ms pulse\nrepeat"
    if motion == "duotone":
        palette = params.get("palette") or []
        a = palette[0] if len(palette) > 0 else c
        b = palette[1] if len(palette) > 1 else _hue_shift(c, float(params.get("secondary_hue_offset_degrees", 40.0)))
        return f"{a}\n{b} {d // 2}ms cosine\n{a} {d // 2}ms cosine\nrepeat"
    if motion == "chase":
        spacing = int(params.get("spacing", 1))
        soft = float(params.get("softness", 1.0))
        step = max(40, d // n) * spacing
        delays = [order(i) * step for i in range(n)]
        easing = "pulse" if soft >= 0.5 else "cosine"
        return f"{floor}\n{_stagger([c] * n, d, delays, easing)}\nrepeat"
    if motion == "gradient":
        palette = params.get("palette") or []
        span = float(params.get("hue_span_degrees", 48.0))
        if len(palette) >= 2:
            shades = [_mix(palette[0], palette[1], i / (n - 1)) for i in range(n)]
        else:
            shades = [_hue_shift(c, -span / 2 + span * i / (n - 1)) for i in range(n)]
        step = max(40, d // n)
        delays = [order(i) * step for i in range(n)]
        return f"{floor}\n{_stagger(shades, d, delays)}\nrepeat"
    if motion == "heartbeat":
        rest = float(params.get("rest_ratio", 0.5))
        beat = max(120, int(d * (1 - rest) / 2))
        return f"{floor}\n{c} {beat}ms pulse\n{floor} {max(40, beat // 3)}ms none\n{c} {beat}ms pulse\n{floor} {max(100, int(d * rest))}ms cosine\nrepeat"
    if motion in ("scanner", "kitt"):
        width = int(params.get("beam_width", 1 if motion == "scanner" else 3))
        trail = float(params.get("trail", params.get("overlap", 0.35)))
        hold = max(40, d // (2 * n))
        dwell = int(hold * (1.5 + 2.5 * trail))
        lit = _scale(c, 0.55) if motion == "kitt" else c
        fwd = []
        back = []
        for i in range(n):
            delay = i * hold
            fwd.append(f"{i}:{c if width == 1 else lit} {dwell}ms pulse {delay}ms")
            back.append(f"{i}:{c if width == 1 else lit} {dwell}ms pulse {(n - 1 - i) * hold}ms")
        if width > 1:
            # Widen the beam: neighbours light on the same delay.
            fwd = [f"{i}:{c} {dwell}ms pulse {min(i, n - 1) * hold}ms" for i in range(n)]
            back = [f"{i}:{c} {dwell}ms pulse {(n - 1 - i) * hold}ms" for i in range(n)]
        return f"{floor}\n{'; '.join(fwd)}\n{'; '.join(back)}\nrepeat"
    if motion == "comet":
        head = int(params.get("head_width", 1))
        trail = int(params.get("trail_length", 3))
        hold = max(40, d // n)
        dwell = hold * (1 + trail)
        segments = [f"{i}:{c} {dwell}ms pulse {order(i) * hold}ms" for i in range(n)]
        if head > 1:
            segments = [f"{i}:{c} {dwell + hold * (head - 1)}ms pulse {order(i) * hold}ms" for i in range(n)]
        tail = {"continuous": "repeat", "once": "", "twice": "repeat 2"}[params.get("pass_mode", "continuous")]
        return f"{floor}\n{'; '.join(segments)}\n{tail}".rstrip()
    if motion == "flicker":
        rng = random.Random(int(params.get("seed", 271)))
        low = float(params.get("luminance_floor", 0.35))
        var = float(params.get("variation", 0.25))
        steps = 8
        lines = []
        for _ in range(steps):
            level = min(1.0, low + rng.random() * (1 - low) * (0.5 + var))
            lines.append(f"{_scale(c, level)} {max(40, d // steps)}ms cosine")
        return "\n".join(lines) + "\nrepeat"
    if motion == "stack":
        hold = max(40, d // (n + 2))
        fill = "; ".join(f"{order(i)}:{c} {hold}ms none {i * hold}ms" for i in range(n))
        release = params.get("release_behavior", "all_at_once")
        if release == "hold":
            tail = f"{c} {d // 2}ms none\n{floor} {hold}ms none"
        elif release == "decay":
            tail = f"{floor} {d // 2}ms cosine"
        else:
            tail = f"{floor} {hold}ms none"
        return f"{floor}\n{fill}\n{tail}\nrepeat"
    if motion == "twinkle":
        rng = random.Random(int(params.get("seed", 271)))
        base = _scale(c, 0.12)
        count = max(1, int(round(float(params.get("density", 0.15)) * n * 2)))
        lines = [base]
        for _ in range(4):
            picks = rng.sample(range(n), min(count, n))
            spark = "; ".join(f"{i}:{c} 260ms pulse {k * 90}ms" for k, i in enumerate(picks))
            lines.append(spark)
            lines.append(f"{base} {max(60, d // 5)}ms none")
        return "\n".join(lines) + "\nrepeat"
    if motion == "drift":
        rng = random.Random(97)
        detune = float(params.get("detune", 0.08))
        delays = [int(rng.random() * d * detune * 4) for _ in range(n)]
        return f"{_scale(c, 0.2)}\n{_stagger([c] * n, d, delays)}\nrepeat"
    if motion == "converge":
        hold = max(60, d // (n // 2 + 1))
        if params.get("variant") == "source_to_destination":
            segs = [f"{i}:{c} {hold * 2}ms pulse {i * hold}ms" for i in range(n)]
        else:
            segs = []
            for k in range(n // 2):
                segs.append(f"{k}:{c} {hold * 2}ms pulse {k * hold}ms")
                segs.append(f"{n - 1 - k}:{c} {hold * 2}ms pulse {k * hold}ms")
        return f"{floor}\n{'; '.join(segs)}\nrepeat"
    if motion == "aurora":
        palette = params.get("palette") or [c, _hue_shift(c, 35), _hue_shift(c, -30), _hue_shift(c, 70)]
        rng = random.Random(int(params.get("seed", 617)))
        waves = int(params.get("wave_count", 2))
        shades = [palette[i % len(palette)] for i in range(n)]
        base = " ".join(_scale(s, 0.25) for s in shades)
        lines = [base]
        waves = max(1, min(waves, 4))
        # Each wave owns every `waves`-th LED so the program stays under 512 bytes.
        for w in range(waves):
            segments = [f"{i}:{shades[(i + w) % n]} {d}ms pulse {int(rng.random() * d)}ms" for i in range(w, n, waves)]
            lines.append("; ".join(segments))
        return "\n".join(lines) + "\nrepeat"
    if motion == "tide":
        fill_floor = float(params.get("fill_floor", 0.15))
        fill_range = float(params.get("fill_range", 0.85))
        base_count = int(round(fill_floor * n))
        top = min(n, base_count + int(round(fill_range * n)))
        hold = max(40, d // (2 * max(1, top)))
        base = "; ".join(f"{i}:{_scale(c, 0.6)}" for i in range(base_count)) or floor
        rise = "; ".join(f"{i}:{c} {hold}ms cosine {(i - base_count) * hold}ms" for i in range(base_count, top))
        fall = "; ".join(f"{i}:{floor} {hold}ms cosine {(top - 1 - i) * hold}ms" for i in range(base_count, top))
        return f"{floor}\n{base}\n{rise}\n{fall}\nrepeat"
    if motion == "marquee":
        spacing = int(params.get("spacing", 1))
        b = _hue_shift(c, float(params.get("palette_rotation_degrees", 48.0)))
        bands = " ".join(c if (i // spacing) % 2 == 0 else b for i in range(n))
        direction = "roll-right" if forward else "roll-left"
        tail = {"continuous": "repeat", "once": "", "twice": "repeat 2"}[params.get("pass_mode", "continuous")]
        return f"{bands}\n{direction} {d}ms linear\n{tail}".rstrip()
    if motion == "blink":
        cadence = next((x for x in BLINK_CADENCES if x["id"] == params.get("cadence", "calm")), BLINK_CADENCES[0])
        lines = []
        for _ in range(cadence["pulses"]):
            lines.append(f"{c} {cadence['on_ms']}ms none")
            lines.append(f"off {cadence['off_ms']}ms none")
        if cadence["rest_ms"]:
            lines.append(f"off {cadence['rest_ms']}ms none")
        if params.get("repeat", True):
            lines.append("repeat")
        return "\n".join(lines)
    return f"{floor}\n{c} {d}ms pulse\nrepeat"


def effect_cadence(effect: dict, values: dict | None = None) -> dict | None:
    """The blink cadence an attention/critical (or blink) effect uses."""
    cadence_id = None
    if effect["id"] == "blink" or (effect.get("pack") and "cadence" in {p["name"] for p in effect.get("parameters", [])}):
        cadence_id = normalize_effect_parameters(effect, values or {}).get("cadence")
    elif effect.get("cadence"):
        cadence_id = effect["cadence"]
    if cadence_id is None:
        return None
    return next((dict(x) for x in BLINK_CADENCES if x["id"] == cadence_id), None)


# -- usage history ------------------------------------------------------------

USAGE_PRICING = {
    "claude": {"input_per_mtok": 3.0, "output_per_mtok": 15.0, "cache_read_per_mtok": 0.30, "as_of": "2026-09-01", "approximate": True, "currency": "USD"},
    "codex": {"input_per_mtok": 2.0, "output_per_mtok": 8.0, "cache_read_per_mtok": 0.50, "as_of": "2026-09-01", "approximate": True, "currency": "USD"},
    "gemini": {"input_per_mtok": 1.25, "output_per_mtok": 10.0, "cache_read_per_mtok": 0.31, "as_of": "2026-09-01", "approximate": True, "currency": "USD"},
}
USAGE_ACCOUNTS = {
    "devin": {"plan": "Team", "label": None, "fidelity": "official"},
    "claude": {"plan": "Max 20×", "label": "jonathan@…", "fidelity": "official"},
    "codex": {"plan": "Plus", "label": "ChatGPT", "fidelity": "derived"},
    "gemini": {"plan": "AI Pro", "label": None, "fidelity": "manual"},
    "cursor": {"plan": None, "label": None, "fidelity": None},
}
USAGE_SCALE = {"claude": 1.0, "codex": 0.45, "gemini": 0.12}


def usage_history(provider: str, range_name: str, now: float, *, partial: bool = False) -> dict:
    """Deterministic daily and hourly rows: a weekday rhythm, a busier
    recent fortnight, and per-provider scale; costs from USAGE_PRICING."""
    days_wanted = {"7d": 7, "30d": 30, "90d": 90, "365d": 365}.get(range_name, 30)
    pricing = USAGE_PRICING.get(provider)
    scale = USAGE_SCALE.get(provider, 0.0)
    rng = random.Random(f"{provider}:{range_name}")
    today = time.localtime(now)
    midnight = time.mktime((today.tm_year, today.tm_mon, today.tm_mday, 0, 0, 0, 0, 0, -1))

    def cost(tin: int, tout: int, cache: int) -> float:
        if not pricing:
            return 0.0
        return round((tin * pricing["input_per_mtok"] + tout * pricing["output_per_mtok"] + cache * pricing["cache_read_per_mtok"]) / 1_000_000, 4)

    days = []
    for back in range(days_wanted - 1, -1, -1):
        start = midnight - back * 86400
        lt = time.localtime(start)
        weekday = lt.tm_wday
        rhythm = 0.25 if weekday >= 5 else 1.0
        recent = 1.35 if back < 14 else 1.0
        wobble = 0.6 + rng.random() * 0.8
        base = 2_400_000 * scale * rhythm * recent * wobble
        tin = int(base * 0.62)
        tout = int(base * 0.11)
        cache = int(base * 1.9 * (0.7 + rng.random() * 0.6))
        days.append({"date": time.strftime("%Y-%m-%d", lt), "tokens_in": tin, "tokens_out": tout,
                     "cache_read": cache, "cost_usd": cost(tin, tout, cache)})
    hours = []
    hour_now = int(now // 3600) * 3600
    for back in range(7 * 24 - 1, -1, -1):
        start = hour_now - back * 3600
        lt = time.localtime(start)
        active = 1.0 if 8 <= lt.tm_hour <= 23 else 0.08
        if lt.tm_wday >= 5:
            active *= 0.3
        base = 110_000 * scale * active * (0.4 + rng.random() * 1.2)
        tin = int(base * 0.62)
        tout = int(base * 0.11)
        cache = int(base * 1.9)
        hours.append({"hour": time.strftime("%Y-%m-%dT%H:00", lt), "at": start, "tokens_in": tin, "tokens_out": tout,
                      "cache_read": cache, "cost_usd": cost(tin, tout, cache)})
    if scale == 0.0:
        days, hours = [], []
    # `records` is the transcript count the scan read: 0 means this Mac has
    # nothing local for the provider (the Usage Center says so rather than
    # drawing an empty axis).
    records = 0 if scale == 0.0 else sum(1 for d in days if d["tokens_in"]) * 7 + len(hours)
    document = {"provider": provider, "range": range_name, "days": days, "hours": hours,
                "pricing": pricing, "account": USAGE_ACCOUNTS.get(provider), "records": records,
                "partial": False}
    if partial:
        # What a scan that has not finished yet can answer with: the newest
        # couple of days, marked, with a `usage_history_ready` to follow.
        document["days"] = days[-2:]
        document["hours"] = hours[-24:] if hours else []
        document["records"] = records // 8
        document["partial"] = True
    return document


# The settings document, seeded from `AgentMonitorSettings().to_dict()` in
# src/jrbar/_settings_legacy.py (captured 2026-09-09) plus the handful of
# keys the native Settings window needs that the Python dataclass has no
# field for yet (menu_bar_icon_style, devices_linked, cloud_ingest_token_path,
# quota_alert_thresholds, devices[].resting_glow). `set_setting` writes into
# a deep copy of this by dot path; `reset_settings` restores from it.
def default_settings_document() -> dict:
    def device(device_id: str, name: str, path: str) -> dict:
        return {
            "id": device_id, "name": name, "path": path, "led_display": "agent", "brightness": 255,
            "auto_brightness_enabled": False, "red_gain": 1.0, "green_gain": 1.0, "blue_gain": 1.0,
            "resting_glow": 0.0, "blend_mode": None, "provider_pin": None, "signal_policy": None,
        }

    return {
        "settings_schema_version": 1,
        "active_scene": "calm",
        "agent_keep_awake_enabled": True,
        "alert_burst": 3,
        "auto_dim": {
            "mode": "off",
            "schedule": {"start_minutes": 1320, "end_minutes": 420, "fraction": 0.3},
            "display": {"min_fraction": 0.15},
            "ambient": {"min_fraction": 0.1, "lux_floor": 5.0, "lux_ceiling": 400.0},
        },
        "battery_monitoring": {
            "charging_idle_enabled": True, "full_charge_watts": None, "low_battery_alert_enabled": True,
            "low_battery_threshold_percent": 5.0, "power_change_preview_seconds": 7.0, "show_on_power_change": True,
        },
        "calendar_alerts_enabled": False,
        "calendar_lead_minutes": 5.0,
        "calibration_profiles": {},
        "capacity_history_enabled": False,
        "capacity_history_retention_days": 7,
        "claude_plan_limits_consent_version": 0,
        "claude_plan_limits_enabled": False,
        "closed_lid_awake_policy": "never",
        "closed_lid_grace_minutes": 5.0,
        "cloud_ingest_enabled": False,
        "cloud_ingest_token_path": f"{HOME}/.local/state/jrbar/cloud-ingest.token",
        "codex_percent_enabled": True,
        "colors": {
            "agent_colors": {
                "antigravity": "#ABE17E", "claude": "#D97757", "codex": "#2B8FFF", "cursor": "#FFCC00",
                "devin": "#5C84B0", "gemini": "#34C759", "grok": "#636366", "hermes": "#FF9500",
                "kiro": "#A00848", "openclaw": "#B23400", "opencode": "#AF52DE", "pi": "#007AFF",
            },
            "blend_mode": "round_robin",
            "color_by_project": False,
            "cycle_speed_seconds": 2.2,
            "done_celebration_enabled": True,
            "fade_ceiling": {"ask": 0.5, "idle": 0.5, "working": 0.5},
            "fade_floor": {"ask": 0.01, "idle": 0.01, "working": 0.01},
            "mode_animation": {"ask": "pulse", "idle": "pulse", "working": "roll"},
            "mode_colors": {"ask": "#FF3A00", "done": "#00FF66", "error": "#B00020", "idle": "#020204", "working": "#00E5FF"},
            "provider_animation": {},
            "round_robin_urgency_alert": True,
            "session_colors": {},
            "speed_overrides": {},
        },
        "completion_notification_enabled": False,
        "completion_sweep_enabled": True,
        "devices": [
            device(PRO_ID, "SidePulse", "/Volumes/SidePulse"),
            device(DOT_ID, "PulseDot", "/Volumes/PulseDot"),
        ],
        "devices_linked": True,
        "dismissed_tips": [],
        "dnd_dim_fraction": 0.15,
        "dnd_focus_mode": "pause",
        "dnd_override_created_epoch": None,
        "dnd_override_mode": None,
        "dnd_override_until_epoch": None,
        "dnd_schedule_enabled": False,
        "dnd_schedule_end_minutes": 420,
        "dnd_schedule_mode": "dark",
        "dnd_schedule_start_minutes": 1320,
        "dot_role": "extend",
        "dot_role_include_completions": False,
        "escalation_final_seconds": 300.0,
        "escalation_menu_bar_seconds": 120.0,
        "escalation_ramp_seconds": 30.0,
        "escalation_tier": "menu_bar",
        "escalation_webhook_url": "",
        "focus_dim_rules": {},
        "focus_profile_rules": {},
        "focus_signal_policy": {},
        "focus_sync_enabled": False,
        "global_action_shortcuts": {},
        "global_brightness_scale": 1.0,
        "idle_auto_off_after_minutes": 60.0,
        "idle_auto_off_enabled": False,
        "idle_dim_after_minutes": 10.0,
        "idle_dim_enabled": True,
        "idle_dim_fraction": 0.3,
        "keep_awake_on_battery": True,
        "keep_display_awake": False,
        "led_display": "agent",
        "lid_closed_active_animation": {
            "duration_seconds": 1.5,
            "program": "#FF9F0A 300ms pulse\n#FF9F0A 250ms cosine\n#5A3A00 350ms cosine\n#1A1200 600ms cosine",
        },
        "lid_closed_animation": {
            "duration_seconds": 0.9,
            "program": "off 90ms cosine\n0:#FF7A00 180ms ease; 7:#FF7A00 180ms ease; 1:#FF7A00 180ms ease 80ms; "
                       "6:#FF7A00 180ms ease 80ms\n2:#FF4A00 180ms ease; 5:#FF4A00 180ms ease; "
                       "3:#FF3000 180ms ease 80ms; 4:#FF3000 180ms ease 80ms\noff 360ms ease-out",
        },
        "lid_open_active_animation": {
            "duration_seconds": 1.2,
            "program": "#12E3B0 200ms pulse\n#00E5FF 300ms cosine\n#00E5FF 700ms pulse",
        },
        "lid_open_animation": {
            "duration_seconds": 1.0,
            "program": "off 90ms cosine\n3:#00E5FF 180ms ease; 4:#00E5FF 180ms ease; 2:#00E5FF 180ms ease 80ms; "
                       "5:#00E5FF 180ms ease 80ms\n1:#00FFB0 180ms ease; 6:#00FFB0 180ms ease; "
                       "0:#00FF66 180ms ease 80ms; 7:#00FF66 180ms ease 80ms\n#00FF66 220ms ease\noff 320ms ease-out",
        },
        "link_screen_bar_to_hardware": True,
        "linked_dot_scale": 0.3,
        "menu_bar_icon_style": "meters",
        "menu_bar_label_enabled": False,
        "notification_policy_version": 1,
        "operator_history_retention_days": 0,
        "quota_alert_thresholds": [90.0, 95.0],
        "quota_alerts_enabled": False,
        "reminder_alerts_enabled": False,
        "remote_peers": {
            "enabled": False, "include_messages": False, "max_peers": 8, "muted_machines": [],
            "per_peer_timeout_seconds": 4.0, "publish_enabled": False, "refresh_deadline_seconds": 8.0,
            "remote_interrupts_muted": True,
            "remote_ledger_path": "~/.local/state/sidepulse/agent-monitor/remote-ledger.json",
            "unmuted_machines": [],
        },
        "screen_bar_bracket_style": "auto",
        "screen_bar_follow_alcove": True,
        "screen_bar_gap_width": None,
        "screen_bar_gauges_enabled": False,
        "screen_bar_min_glow": 0.25,
        "screen_bar_phase_offset_ms": 0.0,
        "screen_bar_show_in_full_screen": False,
        "screen_bar_wing_length": None,
        "session_open_preferences": {},
        "setup_screen_completed": False,
        "signal_styles": {},
        "sleep_dim_enabled": True,
        "sleep_dim_fraction": 0.2,
        "studio_library": [],
        "studio_program": "",
        "subagent_asks_alert": False,
        "tips_enabled": True,
        "transcript_monitoring": {"claude": False, "codex": False, "gemini": False, "pi": False},
        "usage_display_mode": "tokens",
        "usage_event_hook_path": "",
        "usage_graph_days": 7,
        "usage_graph_providers": ["claude", "codex", "gemini"],
        "virtual_status_device_enabled": True,
        "virtual_status_device_wraps_menu_bar": False,
        "webhook_events": [],
        # Forward-compatibility bait: the Settings window must ignore this.
        "x_mock_future_setting": {"nested": [1, 2, 3]},
    }


HOOK_PROVIDERS = ("claude", "codex", "gemini", "pi", "grok", "devin", "opencode", "openclaw", "antigravity",
                  "cursor", "hermes", "kiro")


def split_path(path: str) -> list:
    """`colors.agent_colors.claude` -> keys; a numeric segment indexes a list."""
    parts = []
    for piece in str(path).split("."):
        if not piece:
            continue
        parts.append(int(piece) if piece.isdigit() else piece)
    return parts


def resolve_parent(root, parts: list, create: bool):
    node = root
    for part in parts[:-1]:
        if isinstance(part, int):
            if not isinstance(node, list) or not 0 <= part < len(node):
                return None
            node = node[part]
        else:
            if not isinstance(node, dict):
                return None
            if part not in node:
                if not create:
                    return None
                node[part] = {}
            node = node[part]
    return node


def get_path(root, path: str):
    parts = split_path(path)
    if not parts:
        return None, False
    parent = resolve_parent(root, parts, create=False)
    leaf = parts[-1]
    if isinstance(leaf, int):
        if isinstance(parent, list) and 0 <= leaf < len(parent):
            return parent[leaf], True
        return None, False
    if isinstance(parent, dict) and leaf in parent:
        return parent[leaf], True
    return None, False


def set_path(root, path: str, value) -> bool:
    parts = split_path(path)
    if not parts:
        return False
    parent = resolve_parent(root, parts, create=True)
    leaf = parts[-1]
    if isinstance(leaf, int):
        if not isinstance(parent, list) or not 0 <= leaf < len(parent):
            return False
        parent[leaf] = value
        return True
    if not isinstance(parent, dict):
        return False
    parent[leaf] = value
    return True


def log(message: str) -> None:
    sys.stderr.write(f"mock-core: {message}\n")
    sys.stderr.flush()


class World:
    """Everything the daemon knows, plus the timeline that mutates it."""

    def __init__(self, step_seconds: float, loop: bool) -> None:
        self.lock = threading.RLock()
        self.step_seconds = step_seconds
        self.loop = loop
        self.generation = 4800
        self.settings_generation = 17
        self.clients: list[Client] = []
        self.event_counter = 0
        self.start = time.time()
        now = self.start
        self.sessions: dict[str, dict] = {
            CLAUDE_ID: self._session(
                CLAUDE_ID, "claude", "jr-bar-b7", f"{HOME}/Downloads/JR-Bar", now - 3600,
                origin={"kind": "claude_desktop", "label": "Claude Desktop", "bundle_id": "com.anthropic.claudefordesktop"},
                terminal={"app": "Ghostty", "bundle_id": "com.mitchellh.ghostty", "tty": "/dev/ttys004"},
                pid=9170,
            ),
            CODEX_ID: self._session(
                CODEX_ID, "codex", "sidepulse-core", f"{HOME}/Downloads/JR-Bar/src", now - 1500,
                origin={"kind": "terminal", "label": "Terminal", "bundle_id": "com.apple.Terminal"},
                terminal={"app": "Terminal", "bundle_id": "com.apple.Terminal", "tty": "/dev/ttys007"},
                pid=9311,
            ),
            GEMINI_ID: self._session(
                GEMINI_ID, "gemini", "docs-sweep", f"{HOME}/Projects/notes", now - 9000,
                origin={"kind": "terminal", "label": "Ghostty", "bundle_id": "com.mitchellh.ghostty"},
                terminal={"app": "Ghostty", "bundle_id": "com.mitchellh.ghostty", "tty": "/dev/ttys009"},
                pid=8020, mode="idle", lifecycle="active", next_actor="user",
            ),
        }
        self.sessions[CLAUDE_WORKER_ID] = self._session(
            CLAUDE_WORKER_ID, "claude", "worker", f"{HOME}/Downloads/JR-Bar", now - 600,
            kind="worker", parent=CLAUDE_ID, pid=9188,
        )
        self.asks: list[dict] = []
        self.devices: dict[str, dict] = {
            PRO_ID: {"id": PRO_ID, "kind": "pro", "name": "SidePulse", "path": "/Volumes/SidePulse", "leds": 8,
                     "connected": True, "brightness": 79, "linked": True, "last_write": now, "error": None},
            DOT_ID: {"id": DOT_ID, "kind": "dot", "name": "PulseDot", "path": "/Volumes/PulseDot", "leds": 2,
                     "connected": True, "brightness": 60, "linked": True, "last_write": now, "error": None},
            "screen-bar": {"id": "screen-bar", "kind": "screen_bar", "leds": 8, "enabled": True},
        }
        # `rate` is the percent of the 5h window burned per hour; the forecast
        # extrapolates it. Gemini starts near its limit so the Usage Center has
        # a "runs out before the reset" card; Cursor is not signed in.
        # Order is the daemon's own: a comfortable provider with a real
        # graph first, then one that reports windows but keeps no local
        # transcripts, then the one that is about to run out.
        self.usage = {
            "claude": {"h5": 42.0, "d7": 61.0, "d30": 37.0, "fidelity": "official", "pace": "ahead", "rate": 12.0, "state": "ok"},
            # Signed in and reporting windows, but nothing to scan on this
            # Mac: `usage_history` answers `records: 0` and the Usage
            # Center says so instead of drawing a month of zero. Second, so
            # it is on the first screen next to a card with a real graph.
            # Devin's weekly window is the third state: present, and
            # reported without a number (`used_pct: null`). The app has to
            # draw it as unread -- not as a window at zero with plenty left.
            "devin": {"h5": 4.0, "d7": None, "d30": None, "fidelity": "official", "pace": "on_pace", "rate": 0.4, "state": "ok"},
            "gemini": {"h5": 91.0, "d7": 48.0, "d30": None, "fidelity": "derived", "pace": "ahead", "rate": 14.0, "state": "warning"},
            "codex": {"h5": 12.0, "d7": 30.0, "d30": 22.0, "fidelity": "derived", "pace": "on_pace", "rate": 6.0, "state": "ok"},
            "cursor": {"h5": None, "d7": None, "d30": None, "fidelity": "manual", "pace": None, "rate": 0.0, "state": "not_signed_in"},
        }
        self.usage_refreshed_at = now - 45
        self.effects_generation = 1
        self.effect_packs: dict[str, dict] = {SAMPLE_PACK["id"]: validate_pack(SAMPLE_PACK)}
        self.assignments: list[dict] = [
            {"effect_id": "breathe", "scope": "global", "target_id": None, "parameters": {}},
            {"effect_id": "chase", "scope": "semantic", "target_id": "working", "parameters": {"duration_seconds": 1.6}},
            {"effect_id": "steady", "scope": "scene", "target_id": "night", "parameters": {"luminance": 0.4}},
            {"effect_id": "heartbeat", "scope": "provider", "target_id": "claude", "parameters": {}},
            {"effect_id": "pack:nightlab:ember", "scope": "device", "target_id": DOT_ID, "parameters": {}},
        ]
        self.focus = {"mode": "normal", "source": "default", "until": None}
        self.escalation = {"stage": "none", "since": None}
        self.lights_semantic = "idle"
        self.anchor = now
        self.brightness = 0.79
        self.snoozed_until = 0.0
        self.document = json.loads(json.dumps(default_settings_document()))
        self.hooks = {"claude": "ok", "codex": "ok", "gemini": "ok", "pi": "missing", "grok": "missing",
                      "devin": "missing", "opencode": "stale", "openclaw": "missing", "antigravity": "missing",
                      "cursor": "ok", "hermes": "missing", "kiro": "missing"}
        self.previews: dict[str, float] = {}
        # Deck: the board's ordered identities (a digest per session; new ones
        # are appended, positions are stable, absent ones keep their slot as
        # "Reserved" until cleared), pins by identity, the bank, the rail
        # edge, the keymap, and the deck-controls settings.
        self.deck_present = True
        self.deck_transport = "bluetooth"
        self.deck_approved = True
        self.deck_conflict: str | None = None
        self.deck_receipt: dict | None = None
        # identity -> (session id or None, provider, label)
        self.deck_identities: dict[str, tuple[str | None, str, str]] = {}
        self.deck_order: list[str] = []
        for sid in (CLAUDE_ID, CODEX_ID, GEMINI_ID):
            self.deck_remember(sid)
        for provider, label in (("claude", "notes-refactor"), ("codex", "hook-shim"), ("gemini", "screenshots"),
                                ("cursor", "landing-page"), ("claude", "usage-center"), ("codex", "effect-studio"),
                                ("pi", "sweep-tests"), ("claude", "protocol-docs"), ("codex", "rail-geometry"),
                                ("gemini", "release-notes"), ("cursor", "icon-styles"), ("claude", "history-window"),
                                ("codex", "hook-doctor"), ("claude", "screen-bar"), ("gemini", "readme")):
            identity = deck_identity(f"{provider}:archived:{label}")
            self.deck_identities[identity] = (None, provider, label)
            self.deck_order.append(identity)
        self.deck_pinned: set[str] = {deck_identity(CODEX_ID)}
        self.deck_bank = 0
        self.deck_rail_edge = "off"
        self.deck_keymap = {"state": "stock", "backup_at": None, "generation": 3}
        self.deck_layers = json.loads(json.dumps(DECK_STOCK_LAYERS))
        self.deck_input_check = False
        self.deck_last_input: dict | None = None
        self.deck_settings = {"enabled": True, "session_mode": True, "analog_enabled": False}
        # Explicit mappings for the auxiliary controls (deck-controls.json bindings).
        self.deck_aux_mappings = {13: "previous_bank", 14: "next_bank", 15: "open_control_center", 16: "reveal_current_ask",
                                  17: "open_usage", 18: None, 19: None}
        self.history: list[dict] = []
        self.clear_batches: dict[str, dict] = {}
        self.batch_counter = 0
        # Sessions the daemon has stopped listing because they were
        # acknowledged; `list_history` still has them. The seed stands for
        # the runs that ended before this process started.
        self.hidden_count = 3
        # `usage_history` scans: the first ask per (provider, range) is
        # answered partially and finished by an event, like the daemon's.
        self.history_scanned: set[tuple[str, str]] = set()
        self.history_inflight: set[tuple[str, str]] = set()
        self.history_scan_seconds = 3.0
        self.hot_history = False
        self.quota_crossed: dict[str, set] = {}
        self.ask_opened_at: dict[str, float] = {}
        self._seed_history(now)

    def _seed_history(self, now: float) -> None:
        """Yesterday and earlier today, seen; the newest three happened while
        the Mac was asleep, so the History window opens on an away banner."""
        day = 86400.0
        rows = [
            (now - day - 7200, "started", "claude", CLAUDE_ID, "jr-bar-b7", "Claude Desktop · ~/Downloads/JR-Bar", None, False),
            (now - day - 5370, "completed", "claude", CLAUDE_ID, "jr-bar-b7", "Ported the LEDS sampler", 1830.0, False),
            (now - day - 4000, "started", "gemini", GEMINI_ID, "docs-sweep", "Ghostty · ~/Projects/notes", None, False),
            (now - day - 3600, "asked", "gemini", GEMINI_ID, "docs-sweep", "Overwrite README.md?", None, False),
            (now - day - 3540, "answered", "gemini", GEMINI_ID, "docs-sweep", "Approved from the panel", 60.0, False),
            (now - day - 2200, "failed", "codex", CODEX_ID, "sidepulse-core", "pytest: 3 failed", 420.0, False),
            (now - day - 1800, "ended", "gemini", GEMINI_ID, "docs-sweep", "Session closed", None, False),
            (now - 7200, "started", "codex", CODEX_ID, "sidepulse-core", "Terminal · ~/Downloads/JR-Bar/src", None, False),
            (now - 2700, "completed", "codex", CODEX_ID, "sidepulse-core", "Wrote the hook installer", 4500.0, True),
            (now - 1500, "asked", "claude", CLAUDE_ID, "jr-bar-b7", "Run: swift test", None, True),
            (now - 900, "completed", "gemini", GEMINI_ID, "docs-sweep", "Swept 14 documents", 610.0, True),
        ]
        for at, kind, provider, sid, label, detail, duration, unseen in rows:
            self.history.append({"at": at, "kind": kind, "provider": provider, "session": sid, "label": label,
                                 "detail": detail, "duration": duration, "unseen": unseen})

    def record(self, kind: str, provider: str | None, session: str | None, label: str | None,
               detail: str | None = None, duration: float | None = None) -> None:
        with self.lock:
            unseen = not any(c.alive for c in self.clients)
            self.history.append({"at": time.time(), "kind": kind, "provider": provider, "session": session,
                                 "label": label, "detail": detail, "duration": duration, "unseen": unseen})
            if len(self.history) > 2000:
                del self.history[: len(self.history) - 2000]

    # -- construction helpers ------------------------------------------------

    @staticmethod
    def _session(sid, provider, label, cwd, since, *, kind="main", parent=None, origin=None, terminal=None,
                 pid=None, mode="idle", lifecycle="active", next_actor="provider"):
        return {
            "id": sid, "provider": provider, "kind": kind, "parent": parent, "label": label,
            "short_id": sid.rsplit(":", 1)[-1][:8], "cwd": cwd,
            "mode": mode, "lifecycle": lifecycle, "next_actor": next_actor, "since": since,
            "updated_at": since, "stale": False, "pid": pid, "origin": origin, "ask": None,
            "terminal": terminal, "workers": 0,
        }

    # -- documents ------------------------------------------------------------

    def hello(self) -> dict:
        return {"t": "hello", "v": PROTOCOL_VERSION, "core_version": "0.8.0-mock", "pid": os.getpid(),
                "capabilities": ["sessions", "lights", "usage", "devices", "power", "effects", "calibration",
                                 "history", "peers", "ingest"]}

    def aggregate(self) -> dict:
        mains = [s for s in self.sessions.values() if s["kind"] == "main"]
        needs_you = len(self.asks) + sum(1 for s in mains if s["next_actor"] == "user" and s["lifecycle"] == "active" and not s["ask"])
        active = sum(1 for s in mains if s["lifecycle"] == "active" and s["mode"] in ("working", "tool_running", "thinking"))
        ready = sum(1 for s in mains if s["lifecycle"] == "completed")
        failed = sum(1 for s in mains if s["lifecycle"] == "failed")
        if self.asks:
            mode = "needs_you"
        elif failed:
            mode = "failed"
        elif active:
            mode = "working"
        elif ready:
            mode = "done"
        else:
            mode = "idle"
        return {"mode": mode, "needs_you": needs_you, "active": active, "ready": ready}

    def state(self) -> dict:
        now = time.time()
        for s in self.sessions.values():
            if s["kind"] == "main":
                s["workers"] = sum(1 for w in self.sessions.values() if w["parent"] == s["id"] and w["lifecycle"] == "active")
        providers = []
        for pid, u in self.usage.items():
            if u["h5"] is None:
                providers.append({"id": pid, "windows": [], "fidelity": u["fidelity"], "state": u["state"],
                                  "account": USAGE_ACCOUNTS.get(pid)})
                continue
            windows = [
                {"id": "five-hour", "name": "5h", "used_pct": round(u["h5"], 1), "resets_at": now + 2 * 3600 + 840},
                {"id": "weekly", "name": "7d",
                 "used_pct": None if u["d7"] is None else round(u["d7"], 1),
                 "resets_at": now + 3 * 86400 + 5 * 3600},
            ]
            if u.get("d30") is not None:
                windows.append({"name": "30d", "used_pct": round(u["d30"], 1), "resets_at": now + 19 * 86400 + 7 * 3600})
            rate = u["rate"]
            exhausts_at = now + (100.0 - u["h5"]) / rate * 3600 if rate > 0 and u["h5"] < 100 else None
            providers.append({
                "id": pid,
                "windows": windows,
                "fidelity": u["fidelity"],
                "state": "warning" if u["h5"] >= 85 else u["state"],
                "forecast": {"exhausts_at": exhausts_at, "pace": u["pace"]},
                "account": USAGE_ACCOUNTS.get(pid),
            })
        # `linked` means different things per kind: the Screen Bar's own
        # link setting on the bar, the Pro + Dot pairing on the hardware.
        devices = [dict(d) for d in self.devices.values()]
        for d in devices:
            if d.get("kind") in ("pro", "dot"):
                d["linked"] = bool(self.document.get("devices_linked", True)) and bool(d.get("connected"))
            elif d.get("kind") == "screen_bar":
                d["linked"] = bool(self.document.get("link_screen_bar_to_hardware", True))
        return {
            "t": "state", "v": PROTOCOL_VERSION, "generation": self.generation, "now": now,
            "aggregate": self.aggregate(),
            "sessions": list(self.sessions.values()),
            "asks": list(self.asks),
            "devices": devices,
            "usage": {"refreshed_at": self.usage_refreshed_at, "providers": providers},
            "power": {"keep_awake": True, "closed_lid": {"policy": "agents", "holding": False, "helper_installed": True}},
            "focus": self.focus,
            "escalation": self.escalation,
            "health": {"hooks": dict(self.hooks), "sources": {"codex": {"fresh": True}}},
            "settings_generation": self.settings_generation,
            "hidden_count": self.hidden_count,
            "deck": self.deck_state(),
            # Forward-compatibility bait: the app must ignore this.
            "x_mock_extra": {"note": "unknown keys are fine"},
        }

    # -- deck ------------------------------------------------------------------

    def deck_remember(self, sid: str) -> str:
        """A session seen for the first time is appended to the board (positions are stable)."""
        s = self.sessions.get(sid)
        if s is None:
            return deck_identity(sid)
        identity = deck_identity(sid)
        if identity not in self.deck_identities:
            self.deck_order.append(identity)
        self.deck_identities[identity] = (sid, s["provider"], s["label"])
        return identity

    def deck_slot_state(self, identity: str) -> str:
        """The board's state word for an identity (deck_session_board.py vocabulary)."""
        sid, _provider, _label = self.deck_identities[identity]
        s = self.sessions.get(sid) if sid else None
        if s is None:
            return "unavailable"
        if s.get("stale"):
            return "stale"
        if s["lifecycle"] == "failed":
            return "failure"
        if s["lifecycle"] == "completed":
            return "completed"
        if s["lifecycle"] == "ended":
            return "ended_unconfirmed"
        if s.get("ask") is not None or s["mode"] in ("waiting", "ask"):
            return "input_required"
        if s["mode"] in ("tool_running", "thinking", "working", "running", "long_task"):
            return "active"
        return "idle"

    def deck_driven(self) -> bool:
        """The daemon writes per-key colours only with an approved, unconflicted pad in session mode."""
        return (self.deck_present and self.deck_approved and not self.deck_conflict
                and self.deck_settings["enabled"] and self.deck_settings["session_mode"])

    def deck_bank_count(self) -> int:
        return max(1, (len(self.deck_order) + DECK_SLOTS - 1) // DECK_SLOTS)

    def deck_slots(self) -> list[dict]:
        driven = self.deck_driven()
        slots = []
        for index in range(DECK_SLOTS):
            offset = self.deck_bank * DECK_SLOTS + index
            identity = self.deck_order[offset] if offset < len(self.deck_order) else None
            if identity is None:
                slots.append({"index": index, "identity": None, "session": None, "label": None, "provider": None,
                              "state": "unavailable", "pinned": False, "navigable": False,
                              "color": DECK_DARK if driven else "#000000"})
                continue
            sid, provider, label = self.deck_identities[identity]
            state = self.deck_slot_state(identity)
            live = sid is not None and sid in self.sessions
            slots.append({"index": index, "identity": identity, "session": sid if live else None,
                          "label": label, "provider": provider, "state": state,
                          "pinned": identity in self.deck_pinned, "navigable": live,
                          "color": (DECK_STATE_COLORS.get(state, DECK_DARK) if driven else "#000000")})
        return slots

    def deck_aux(self) -> list[dict]:
        return [{"index": index, "label": label, "mapping": self.deck_aux_mappings.get(index)}
                for index, label in DECK_AUX_LABELS.items()]

    def deck_layer_rows(self) -> list[dict]:
        return [{"profile": layer["profile"], "layer": layer["layer"],
                 "label": f"Profile {layer['profile'] + 1} / Layer {layer['layer'] + 1}: {layer['name']}"}
                for layer in self.deck_layers]

    def deck_state(self) -> dict:
        with self.lock:
            device = None
            if self.deck_present:
                device = {"serial": DECK_SERIAL, "name": "Creator Micro 2", "transport": self.deck_transport,
                          "connected": True, "approved": self.deck_approved, "firmware": "v0.6.1",
                          "layer": 0, "profile": 0, "conflict": self.deck_conflict,
                          "receipt": dict(self.deck_receipt) if self.deck_receipt else None}
            return {
                "device": device,
                "slots": self.deck_slots(),
                "aux": self.deck_aux(),
                "banks": {"index": self.deck_bank, "count": self.deck_bank_count()},
                "rail": {"edge": self.deck_rail_edge},
                "keymap": dict(self.deck_keymap) | {"layers": self.deck_layer_rows()},
                "input_check": self.deck_input_check,
                "last_input": dict(self.deck_last_input) if self.deck_last_input else None,
                "settings": dict(self.deck_settings),
            }

    def deck_error(self, cid, code: str, message: str | None = None) -> dict:
        return {"t": "reply", "v": PROTOCOL_VERSION, "id": cid, "ok": False,
                "error": {"code": code, "message": message or deck_receipt_message(code)}}

    def deck_set_receipt(self, code: str) -> dict:
        receipt = {"code": code, "message": deck_receipt_message(code), "at": time.time()}
        with self.lock:
            self.deck_receipt = receipt
        return receipt

    def deck_push_receipt(self, code: str) -> dict:
        """Records a receipt on the device and tells every client about it."""
        receipt = self.deck_set_receipt(code)
        self.push_state()
        self.push_event("deck_receipt", None, "Creator Micro 2", code=code, message=receipt["message"], notify=False)
        return receipt

    def deck_input(self, index: int, kind: str) -> None:
        """A physical input observed on the pad: remembered on the state, sent as an event."""
        with self.lock:
            self.deck_last_input = {"index": index, "kind": kind, "at": time.time()}
        self.push_event("deck_input", None, deck_control_label(index), input=dict(self.deck_last_input), notify=False)

    def deck_input_burst(self) -> None:
        """Input check: pretend the user tries the first keys, the dial and the joystick."""
        def run():
            for index, kind in ((0, "press"), (1, "press"), (2, "press"), (13, "dial"), (16, "joystick")):
                if not self.deck_input_check or not self.deck_present:
                    return
                self.deck_input(index, kind)
                time.sleep(0.4)
        threading.Thread(target=run, name="deck-input", daemon=True).start()

    def deck_find_layer(self, profile: int, layer: int) -> dict | None:
        return next((row for row in self.deck_layers if row["profile"] == profile and row["layer"] == layer), None)

    def deck_plan(self, args: dict) -> dict | str:
        """The apply plan (creator_micro_keymap.plan_keymap) or an error message."""
        profile = args.get("profile", 0)
        layer = args.get("layer", 0)
        include_auxiliary = args.get("include_auxiliary", False)
        if type(profile) is not int or type(layer) is not int:
            return "invalid selected profile" if type(profile) is not int else "invalid selected layer"
        if type(include_auxiliary) is not bool:
            return "include_auxiliary must be a bool"
        row = self.deck_find_layer(profile, layer)
        if row is None:
            return "invalid selected layer"
        changes: list[str] = []
        key_index = 0
        for keys in row["keys"]:
            for old in keys:
                new = f"KV_OAI_AG{key_index:02d}"
                if old != new:
                    changes.append(f"Key {key_index}: {old} -> {new}; "
                                   "replaces its normal keystroke with a JR-Bar device input.")
                key_index += 1
        controls = [{"index": index, "label": f"Key {index + 1}"} for index in range(DECK_SLOTS)]
        if include_auxiliary:
            auxiliary: list[tuple[str, str]] = []
            for encoder, inputs in enumerate(row["encoders"]):
                for position, old in enumerate(inputs):
                    auxiliary.append((old, f"Encoder {encoder + 1} input {position + 1}"))
            for index, old in enumerate(row["joystick"]):
                auxiliary.append((old, f"Joystick sector {index + 1}"))
            for index, (old, label) in enumerate(auxiliary, DECK_SLOTS):
                code = f"KV_OAI_AG{index:02d}"
                controls.append({"index": index, "label": label})
                if old != code:
                    changes.append(f"{label}: {old} -> {code}; replaces its normal firmware action.")
        changed = "\n".join(changes) if changes else "No device keys need to change."
        preview = (
            f"Selected profile {profile + 1}, layer {layer + 1}:\n\n"
            f"{changed}\n\n"
            "The listed keys will replace their normal keystrokes with JR-Bar device inputs. "
            + ("Supported dial/joystick mappings listed above also change. " if include_auxiliary
               else "Dial and joystick mappings stay unchanged. ")
            + "Thread colors are device-wide, not layer-specific. Stored mappings may require reconnecting to activate. "
            "JR-Bar does not switch the device profile or layer through an undocumented RPC."
        )
        return {"profile": profile, "layer": layer, "include_auxiliary": include_auxiliary,
                "changes": changes, "preview": preview, "controls": controls}

    def deck_write_layer(self, profile: int, layer: int, include_auxiliary: bool, restore: bool) -> None:
        """Rewrites (or restores) the mock pad's layer so the next plan reads 'already configured'."""
        row = self.deck_find_layer(profile, layer)
        stock = next(r for r in DECK_STOCK_LAYERS if r["profile"] == profile and r["layer"] == layer)
        if row is None:
            return
        if restore:
            row["keys"] = json.loads(json.dumps(stock["keys"]))
            row["encoders"] = json.loads(json.dumps(stock["encoders"]))
            row["joystick"] = list(stock["joystick"])
            return
        index = 0
        for keys in row["keys"]:
            for column in range(len(keys)):
                keys[column] = f"KV_OAI_AG{index:02d}"
                index += 1
        if include_auxiliary:
            for inputs in row["encoders"]:
                for position in range(len(inputs)):
                    inputs[position] = f"KV_OAI_AG{index:02d}"
                    index += 1
            for sector in range(len(row["joystick"])):
                row["joystick"][sector] = f"KV_OAI_AG{index:02d}"
                index += 1

    def deck_press_action(self, index: int) -> tuple[str | None, str | None, str | None]:
        """(action, identity, session) for a control index; action None means nothing bound."""
        if 0 <= index < DECK_SLOTS:
            row = self.deck_slots()[index]
            if row["session"] is None:
                return None, row["identity"], None
            return "reveal_session", row["identity"], row["session"]
        mapping = self.deck_aux_mappings.get(index) if index < DECK_SLOTS + len(DECK_AUX_LABELS) else None
        return mapping, None, None

    def auto_dim(self) -> dict:
        """The daemon's `AutoDimResult.to_dict()` for the seeded `auto_dim`
        document: schedule against the wall clock; display follows a fixed
        62 % (this Mac's display is not read); ambient has no sensor here,
        so it falls back to display and says `available: false`, exactly as
        the daemon does without an ambient light sensor."""
        doc = self.document.get("auto_dim") if isinstance(self.document.get("auto_dim"), dict) else {}
        mode = doc.get("mode") if doc.get("mode") in ("off", "schedule", "display", "ambient") else "off"
        if mode == "off":
            return {"mode": "off", "source": "off", "factor": 1.0, "available": True, "reading": None}
        schedule = doc.get("schedule") if isinstance(doc.get("schedule"), dict) else {}
        display = doc.get("display") if isinstance(doc.get("display"), dict) else {}
        if mode == "schedule":
            now = time.localtime()
            minutes = now.tm_hour * 60 + now.tm_min
            start = int(schedule.get("start_minutes", 1320))
            end = int(schedule.get("end_minutes", 420))
            if start == end:
                active = False
            elif start < end:
                active = start <= minutes < end
            else:
                active = minutes >= start or minutes < end
            fraction = float(schedule.get("fraction", 0.3)) if active else 1.0
            return {"mode": "schedule", "source": "schedule", "factor": round(fraction, 4), "available": True,
                    "reading": float(minutes)}
        reading = 0.62
        floor = float(display.get("min_fraction", 0.15))
        return {"mode": mode, "source": "display", "factor": round(max(floor, reading), 4),
                "available": mode == "display", "reading": reading}

    def dot_surface(self, dot: str, motion: str, fallback: str, why: str) -> dict:
        """The `dot` surface under the role in the document.

        `extend` and `asks` are role-driven and carry `role`; `status` means
        the Dot renders its own two-LED display, and the frame carries no
        `role` at all (docs/CORE-PROTOCOL.md, "The Dot's role"). The role
        decides the Dot's `why` as well as its program."""
        role = self.document.get("dot_role")
        if role not in ("extend", "asks", "status"):
            role = "extend"
        # With `devices_linked` off the core plans nothing for the Dot: it
        # renders its own display, exactly as `status` does.
        if not bool(self.document.get("devices_linked", True)):
            role = "status"
        surface = {"program": dot, "led_count": 2, "anchor": self.anchor, "motion": motion,
                   "static_fallback": fallback, "brightness": self.brightness, "why": why,
                   "why_detail": self.why_detail(why)}
        if role == "status":
            # Nothing is driving the Dot but the Dot: its own heartbeat, no role.
            surface["program"] = DOT_BINARY_HEARTBEAT
            surface["motion"] = "beat"
            surface["static_fallback"] = "#3A3A3C"
            surface["why"] = "studio"
            surface["why_detail"] = self.why_detail("studio")
            return surface
        if role == "asks":
            stage = {"none": 0, "ramp": 1, "menu_bar": 2, "final": 3}.get(self.escalation.get("stage"), 0)
            aggregate = self.aggregate()
            if aggregate.get("failed"):
                surface.update(program=beacon_program("#FF0000", max(stage, 2)), motion="beat",
                               static_fallback="#FF0000", why="failed")
            elif aggregate.get("needs_you"):
                surface.update(program=beacon_program("#FF9F0A", stage), motion="beat",
                               static_fallback="#FF9F0A", why="waiting")
            elif aggregate.get("ready") and bool(self.document.get("dot_role_include_completions")):
                surface.update(program=beacon_program("#00FF66", 0), motion="beat",
                               static_fallback="#00FF66", why="completed")
            else:
                surface.update(program=BEACON_DARK, motion="static", static_fallback="#000000", why="idle")
            surface["why_detail"] = self.why_detail(surface["why"])
        surface["role"] = role
        return surface

    def lights(self) -> dict:
        programs = {
            "working": (WORKING_RELAY, DOT_WORKING, "working"),
            "ask": (ASK_PULSE, DOT_ASK, "needs_you"),
            "done": (COMPLETED_UNSEEN, DOT_DONE, "completed_unseen"),
            "idle": (IDLE_BREATH, DOT_IDLE, "idle"),
        }
        strip, dot, why = programs[self.lights_semantic]
        motion = {"working": "chase", "ask": "beat", "done": "pulse", "idle": "breathe"}[self.lights_semantic]
        fallback = {"working": "#00E5FF", "ask": "#FF3A00", "done": "#00FF66", "idle": "#020204"}[self.lights_semantic]
        surface = {"program": strip, "led_count": 8, "anchor": self.anchor, "motion": motion,
                   "static_fallback": fallback, "brightness": self.brightness, "why": why,
                   "why_detail": self.why_detail(why)}
        # `linked` is the Screen Bar's own link; while it is on the bar
        # carries the strip's anchor shifted by `screen_bar_phase_offset_ms`
        # (positive holds the bar back), exactly as the daemon does.
        linked = bool(self.document.get("link_screen_bar_to_hardware", True))
        screen_bar = dict(surface)
        if linked:
            screen_bar["anchor"] = self.anchor + float(self.document.get("screen_bar_phase_offset_ms", 0.0)) / 1000.0
        # `dot_link` is the daemon's word for the Pro + Dot link; the mock
        # never fails a write and always has both devices, so its states
        # are only off / linked / beacon / solo.
        devices_linked = bool(self.document.get("devices_linked", True))
        role = self.document.get("dot_role")
        role = role if role in ("extend", "asks", "status") else "extend"
        if not devices_linked:
            dot_link = {"state": "off", "role": None, "error": None}
        else:
            dot_link = {"state": {"extend": "linked", "asks": "beacon", "status": "solo"}[role],
                        "role": role, "error": None}
        return {
            "t": "lights", "v": PROTOCOL_VERSION,
            "surfaces": {
                "hardware": dict(surface),
                "screen_bar": screen_bar,
                "dot": self.dot_surface(dot, motion, fallback, why),
            },
            "linked": linked,
            "devices_linked": devices_linked,
            "linked_skew_ms": 11.0,
            "linked_skew_at": self.anchor,
            "dot_link": dot_link,
            "auto_dim": self.auto_dim(),
        }

    def why_detail(self, why: str) -> dict:
        """The daemon's `why_detail`: the session the light is about and how long it has been so."""
        wanted = {"working": ("working", "tool_running", "thinking"), "needs_you": ("waiting", "ask"),
                  "completed_unseen": ("completed",)}.get(why, ())
        session = next((s for s in self.sessions.values() if s.get("kind") == "main" and s.get("mode") in wanted), None)
        seconds = round(time.time() - self.anchor, 1) if self.anchor else 0.0
        auto_dim = self.auto_dim()
        dimming = ["auto_dim"] if auto_dim["factor"] < 1.0 else []
        return {"session": session["id"] if session else None, "label": session["label"] if session else None,
                "provider": session["provider"] if session else None, "seconds_in_state": max(0.0, seconds),
                "brightness_factor": auto_dim["factor"], "dimming": dimming}

    def settings(self) -> dict:
        return {
            "t": "settings", "v": PROTOCOL_VERSION, "generation": self.settings_generation, "schema": 3,
            "document": json.loads(json.dumps(self.document)),
        }

    def log_message(self, level: str, message: str) -> dict:
        return {"t": "log", "v": PROTOCOL_VERSION, "level": level, "message": message, "at": time.time()}

    def event(self, kind: str, session: str | None = None, label: str | None = None, **extra) -> dict:
        self.event_counter += 1
        payload = {"t": "event", "v": PROTOCOL_VERSION, "id": f"ev-{self.event_counter}", "kind": kind,
                   "session": session, "label": label, "at": time.time(), "sound": None, "notify": True}
        payload.update(extra)
        return payload

    # -- broadcasting ---------------------------------------------------------

    def broadcast(self, *documents: dict) -> None:
        with self.lock:
            clients = list(self.clients)
        for client in clients:
            for document in documents:
                client.send(document)

    def push_state(self) -> None:
        with self.lock:
            self.generation += 1
            document = self.state()
        self.broadcast(document)

    def push_lights(self, semantic: str) -> None:
        with self.lock:
            if semantic != self.lights_semantic:
                self.anchor = time.time()
            self.lights_semantic = semantic
            document = self.lights()
        self.broadcast(document)

    def push_settings(self) -> None:
        with self.lock:
            self.settings_generation += 1
            document = self.settings()
        self.broadcast(document)

    def push_event(self, kind: str, session: str | None = None, label: str | None = None, **extra) -> None:
        with self.lock:
            document = self.event(kind, session, label, **extra)
        self.broadcast(document)

    def push_log(self, level: str, message: str) -> None:
        self.broadcast(self.log_message(level, message))

    def finish_history_scan(self, provider: str, range_name: str) -> None:   # noqa: D401
        """The off-thread `usage_history` scan landed: tell every client so
        the one that got a partial answer can ask again. `notify: false`;
        an app that ignores the event still catches up on its own."""
        with self.lock:
            self.history_inflight.discard((provider, range_name))
        self.push_log("info", f"usage_history scan finished: {provider} {range_name}")
        self.push_event("usage_history_ready", None, None, provider=provider, range=range_name, notify=False)

    # -- mutations used by the timeline and commands ---------------------------

    def set_mode(self, sid: str, mode: str, lifecycle: str = "active", next_actor: str = "provider") -> None:
        with self.lock:
            # A session the client acknowledged is gone from the world; the
            # timeline must not resurrect it.
            s = self.sessions.get(sid)
            if s is None:
                return
            changed = (s["mode"], s["lifecycle"], s["next_actor"]) != (mode, lifecycle, next_actor)
            s["mode"], s["lifecycle"], s["next_actor"] = mode, lifecycle, next_actor
            s["updated_at"] = time.time()
            if changed:
                s["since"] = time.time()

    def open_ask(self, sid: str, summary: str, kind: str = "permission") -> None:
        with self.lock:
            ask = {"session": sid, "kind": kind, "opened_at": time.time(), "summary": summary}
            self.asks = [a for a in self.asks if a["session"] != sid] + [ask]
            if sid in self.sessions:
                self.sessions[sid]["ask"] = {"kind": kind, "opened_at": ask["opened_at"], "summary": summary}
            self.ask_opened_at[sid] = ask["opened_at"]
            self.set_mode(sid, "waiting", "active", "user")
            self.escalation = {"stage": "none", "since": None}
        s = self.sessions.get(sid)
        if s is not None:
            self.record("asked", s["provider"], sid, s["label"], summary)

    def resolve_ask(self, sid: str, decision: str, source: str = "timeout") -> bool:
        with self.lock:
            had = any(a["session"] == sid for a in self.asks)
            self.asks = [a for a in self.asks if a["session"] != sid]
            if sid in self.sessions:
                self.sessions[sid]["ask"] = None
                self.set_mode(sid, "tool_running" if decision == "approve" else "thinking", "active", "provider")
            if not self.asks:
                self.escalation = {"stage": "none", "since": None}
            opened = self.ask_opened_at.pop(sid, None)
        if had and sid in self.sessions:
            s = self.sessions[sid]
            self.record("answered", s["provider"], sid, s["label"], f"{decision.capitalize()} ({source})",
                        (time.time() - opened) if opened else None)
        return had

    def escalate(self, stage: int) -> None:
        """Move the open ask to `stage` (0 none, 1 ramp, 2 menu_bar, 3 final)."""
        names = {0: "none", 1: "ramp", 2: "menu_bar", 3: "final"}
        with self.lock:
            if not self.asks:
                return
            self.escalation = {"stage": names[stage], "since": self.asks[0]["opened_at"]}
            sid = self.asks[0]["session"]
            label = self.sessions.get(sid, {}).get("label")
        self.push_state()
        self.push_event("escalation_stage", sid, label, stage=stage, sound=None)

    def light_for_world(self) -> str:
        with self.lock:
            agg = self.aggregate()["mode"]
        return {"needs_you": "ask", "working": "working", "done": "done"}.get(agg, "idle")

    # -- timeline -------------------------------------------------------------

    def timeline_steps(self) -> list[tuple[str, float]]:
        """(name, pause multiplier) for every step; `--start-at N` begins at index N."""
        return [
            ("claude_working", 1.5),
            ("deck_keys", 1.0),
            ("codex_ask", 2.5),
            ("codex_ask_stage2", 1.5),
            ("codex_ask_stage3", 1.5),
            ("codex_ask_resolved", 1.0),
            ("codex_completed", 1.5),
            ("pro_disconnected", 1.0),
            ("pro_reconnected", 1.0),
            ("deck_conflict", 1.5),
            ("deck_conflict_cleared", 1.0),
            ("gemini_failed", 1.0),
            ("claude_completed", 1.5),
            ("idle", 2.0),
        ]

    def play_step(self, name: str) -> None:
        self.push_log("info", f"timeline step {name}")
        if name == "claude_working":
            log("timeline: claude starts working")
            self.set_mode(CLAUDE_ID, "tool_running")
            self.set_mode(CLAUDE_WORKER_ID, "tool_running")
            self.set_mode(CODEX_ID, "thinking")
            self.record("started", "claude", CLAUDE_ID, "jr-bar-b7", "Claude Desktop · ~/Downloads/JR-Bar")
            self.record("started", "codex", CODEX_ID, "sidepulse-core", "Terminal · ~/Downloads/JR-Bar/src")
            self.push_state()
            self.push_lights("working")
        elif name == "deck_keys":
            if self.deck_present:
                log("timeline: two presses and a dial turn on the deck")
                self.deck_input(0, "press")
                self.deck_input(1, "press")
                self.deck_input(14, "dial")
        elif name == "deck_conflict":
            if self.deck_present and self.deck_conflict is None:
                log("timeline: another app answers on the deck's stream")
                with self.lock:
                    self.deck_conflict = "foreign_responses"
                self.deck_push_receipt("device_conflict")
        elif name == "deck_conflict_cleared":
            if self.deck_present and self.deck_conflict is not None:
                log("timeline: the deck reconnects, conflict cleared")
                with self.lock:
                    self.deck_conflict = None
                    self.deck_keymap["generation"] += 1
                self.deck_push_receipt("connection_changed")
                self.push_event("device_connected", None, "Creator Micro 2", notify=False)
        elif name == "codex_ask":
            log("timeline: codex ask opens")
            self.open_ask(CODEX_ID, "Run: rm -rf build")
            self.push_state()
            self.push_lights("ask")
            self.push_event("ask_opened", CODEX_ID, "sidepulse-core", sound="funk", detail="Run: rm -rf build", provider="codex")
        elif name == "codex_ask_stage2":
            if self.asks:
                log("timeline: codex ask escalates to stage 2 (menu bar)")
                self.escalate(2)
        elif name == "codex_ask_stage3":
            if self.asks:
                log("timeline: codex ask escalates to stage 3 (chime)")
                self.escalate(3)
        elif name == "codex_ask_resolved":
            # Resolves on its own unless someone answered it already.
            if self.resolve_ask(CODEX_ID, "approve", "timeout"):
                log("timeline: codex ask times out as approved")
                self.push_event("ask_resolved", CODEX_ID, "sidepulse-core", provider="codex")
            self.push_state()
            self.push_lights(self.light_for_world())
        elif name == "codex_completed":
            log("timeline: codex completes")
            self.set_mode(CODEX_ID, "idle", "completed", "user")
            self.record("completed", "codex", CODEX_ID, "sidepulse-core", "Rebuilt build/ and ran the suite",
                        time.time() - self.sessions.get(CODEX_ID, {}).get("since", time.time()) + 1500)
            self.push_state()
            self.push_lights("done")
            self.push_event("completed", CODEX_ID, "sidepulse-core", sound="glass", provider="codex")
        elif name == "pro_disconnected":
            log("timeline: pro disconnects")
            with self.lock:
                self.devices[PRO_ID]["connected"] = False
                self.devices[PRO_ID]["error"] = "volume unmounted"
            self.push_state()
            self.push_event("device_disconnected", None, "SidePulse")
        elif name == "pro_reconnected":
            log("timeline: pro reconnects")
            with self.lock:
                self.devices[PRO_ID]["connected"] = True
                self.devices[PRO_ID]["error"] = None
                self.devices[PRO_ID]["last_write"] = time.time()
            self.push_state()
            self.push_lights(self.light_for_world())
            self.push_event("device_connected", None, "SidePulse")
        elif name == "gemini_failed":
            log("timeline: gemini fails")
            self.set_mode(GEMINI_ID, "failed", "failed", "user")
            self.record("failed", "gemini", GEMINI_ID, "docs-sweep", "Exit 1: rate limited", 95.0)
            self.push_state()
            self.push_event("failed", GEMINI_ID, "docs-sweep", sound="basso", provider="gemini", detail="Exit 1: rate limited")
        elif name == "claude_completed":
            log("timeline: claude completes")
            self.set_mode(CLAUDE_ID, "idle", "completed", "user")
            self.set_mode(CLAUDE_WORKER_ID, "idle", "completed", "user")
            self.record("completed", "claude", CLAUDE_ID, "jr-bar-b7", "Events, history and the Why row",
                        time.time() - self.sessions.get(CLAUDE_ID, {}).get("since", time.time()) + 3600)
            self.push_state()
            self.push_lights("done")
            self.push_event("completed", CLAUDE_ID, "jr-bar-b7", sound="glass", provider="claude")
        elif name == "idle":
            log("timeline: idle")
            with self.lock:
                for sid in (CLAUDE_ID, CODEX_ID, CLAUDE_WORKER_ID):
                    if self.sessions.get(sid, {}).get("lifecycle") == "completed":
                        self.set_mode(sid, "idle", "active", "provider")
                if self.sessions.get(GEMINI_ID, {}).get("lifecycle") == "failed":
                    # The process went away without a completion: "ended",
                    # which the panel greys rather than checking off.
                    self.set_mode(GEMINI_ID, "idle", "ended", "provider")
                reset = [pid for pid, crossed in self.quota_crossed.items() if crossed]
                for pid in reset:
                    self.usage[pid]["h5"] = 12.0
                    self.usage[pid]["state"] = "ok"
                    self.quota_crossed[pid] = set()
            self.record("ended", "gemini", GEMINI_ID, "docs-sweep", "Session closed")
            self.push_state()
            self.push_lights("idle")
            for pid in reset:
                self.push_event("quota_reset", None, pid.capitalize(), provider=pid, detail="5h window reset")

    def run_timeline(self, stop: threading.Event, start_at: int = 0) -> None:
        supervised = os.environ.get("JRBAR_SUPERVISED") == "1"

        def pause(mult: float = 1.0) -> bool:
            deadline = time.time() + self.step_seconds * mult
            while time.time() < deadline:
                if stop.is_set():
                    return False
                if supervised and os.getppid() == 1:
                    # The app that spawned us is gone: do not outlive it.
                    log("supervisor vanished; exiting")
                    stop.set()
                    return False
                self.tick_usage(0.35 / max(self.step_seconds, 0.1))
                stop.wait(0.5)
            return not stop.is_set()

        steps = self.timeline_steps()
        index = max(0, min(start_at, len(steps) - 1))
        if index:
            # Fast-forward through the earlier steps so the world is consistent.
            for name, _ in steps[:index]:
                self.play_step(name)
        while not stop.is_set():
            for name, mult in steps[index:]:
                self.play_step(name)
                if not pause(mult):
                    return
            index = 0
            if not self.loop:
                break

    def tick_usage(self, amount: float) -> None:
        changed = False
        crossed: list[tuple[str, float]] = []
        with self.lock:
            thresholds = [float(t) for t in (self.document.get("quota_alert_thresholds") or [90.0, 95.0])]
            for pid, u in self.usage.items():
                if u["h5"] is None:
                    continue
                before = u["h5"]
                u["h5"] = min(99.0, u["h5"] + amount)
                # A window with no reading stays unread: burning through
                # the 5h one cannot invent a number for it.
                if u["d7"] is not None:
                    u["d7"] = min(99.0, u["d7"] + amount * 0.3)
                if u.get("d30") is not None:
                    u["d30"] = min(99.0, u["d30"] + amount * 0.08)
                changed = True
                for threshold in thresholds:
                    if before < threshold <= u["h5"] and threshold not in self.quota_crossed.setdefault(pid, set()):
                        self.quota_crossed[pid].add(threshold)
                        crossed.append((pid, threshold))
        if changed:
            self.push_state()
        for pid, threshold in crossed:
            self.push_event("quota_crossed", None, f"5h window at {int(threshold)}%", provider=pid,
                            detail=f"crossed {int(threshold)}%", sound="pop")

    # -- effects ----------------------------------------------------------------

    @staticmethod
    def _error(cid, code: str, message: str) -> dict:
        return {"t": "reply", "v": PROTOCOL_VERSION, "id": cid, "ok": False, "error": {"code": code, "message": message}}

    def all_effects(self) -> list[dict]:
        effects = registry_effects()
        for pack in self.effect_packs.values():
            effects.extend(pack_effect_definitions(pack))
        return effects

    def find_effect(self, effect_id: str) -> dict | None:
        for effect in self.all_effects():
            if effect["id"] == effect_id:
                return effect
        return None

    def effect_catalog(self) -> dict:
        effects = []
        for effect in self.all_effects():
            row = dict(effect)
            row.pop("cadence", None)
            row["preview"] = {"program": render_effect_program(effect, {}, 8), "led_count": 8}
            cadence = effect_cadence(effect)
            if cadence:
                row["cadence"] = cadence
            effects.append(row)
        packs = []
        for pack in self.effect_packs.values():
            entry = {"id": pack["id"], "name": pack["name"], "version": pack["version"],
                     "effects": [f"pack:{pack['id']}:{e['id']}" for e in pack["effects"]]}
            if pack.get("license"):
                entry["license"] = pack["license"]
            if pack.get("_path"):
                entry["path"] = pack["_path"]
            packs.append(entry)
        return {"effects": effects, "packs": packs, "cadences": [dict(c) for c in BLINK_CADENCES],
                "generation": self.effects_generation}

    def assignment_document(self) -> dict:
        return {"assignments": [dict(a) for a in self.assignments], "active_scene": self.document.get("active_scene", "calm"),
                "generation": self.effects_generation}

    # -- commands -------------------------------------------------------------

    def handle_command(self, command: dict) -> dict:
        name = command.get("name")
        args = command.get("args") or {}
        cid = command.get("id")
        result: dict = {}
        if name == "answer_ask":
            sid = args.get("session")
            decision = args.get("decision", "approve")
            had = self.resolve_ask(sid, decision, "app")
            if had:
                self.push_event("ask_resolved", sid, self.sessions.get(sid, {}).get("label"))
            self.push_state()
            self.push_lights(self.light_for_world())
            result = {"answered": had, "decision": decision}
            if not had:
                return {"t": "reply", "v": PROTOCOL_VERSION, "id": cid, "ok": False,
                        "error": {"code": "not_found", "message": "no live ask for that session"}}
        elif name == "open_session":
            sid = args.get("session")
            s = self.sessions.get(sid)
            result = {"activated": (s or {}).get("terminal", {}).get("app") if s else None}
            if s is None:
                return {"t": "reply", "v": PROTOCOL_VERSION, "id": cid, "ok": False,
                        "error": {"code": "not_found", "message": "no such session"}}
        elif name == "set_brightness":
            value = float(args.get("value", 0.5))
            with self.lock:
                self.brightness = max(0.0, min(1.0, value))
                target = args.get("device", "all")
                for dev in self.devices.values():
                    if dev["kind"] in ("pro", "dot") and (target == "all" or dev["id"] == target):
                        dev["brightness"] = int(round(self.brightness * 100))
            self.push_state()
            self.broadcast(self.lights())
            result = {"value": self.brightness}
        elif name == "clear_completed":
            # Acknowledging a row takes it out of `state.sessions` for good
            # (it lives on in `list_history`) and counts it in
            # `hidden_count` — the daemon's behaviour since 0.8: a cleared
            # session must never come back on the next state.
            scope = args.get("sessions", "all")
            with self.lock:
                cleared = []
                snapshot = {}
                for s in list(self.sessions.values()):
                    done = s["lifecycle"] in ("completed", "ended", "stale") or s.get("stale")
                    if done and (scope == "all" or s["id"] in (scope or [])):
                        snapshot[s["id"]] = dict(s)
                        del self.sessions[s["id"]]
                        self.hidden_count += 1
                        cleared.append(s["id"])
                self.batch_counter += 1
                batch = f"b-{self.batch_counter}"
                self.clear_batches[batch] = {"at": time.time(), "sessions": snapshot}
            self.push_state()
            self.push_lights(self.light_for_world())
            self.push_log("info", f"cleared {len(cleared)} finished ({batch})")
            result = {"batch": batch, "cleared": cleared}
        elif name == "undo_clear":
            batch = str(args.get("batch", ""))
            with self.lock:
                entry = self.clear_batches.pop(batch, None)
                if entry is None or time.time() - entry["at"] > 300:
                    return {"t": "reply", "v": PROTOCOL_VERSION, "id": cid, "ok": False,
                            "error": {"code": "expired" if entry else "not_found",
                                      "message": "that batch can no longer be undone" if entry else "no such batch"}}
                restored = []
                for sid, snap in entry["sessions"].items():
                    self.sessions[sid] = dict(snap)
                    self.sessions[sid]["updated_at"] = time.time()
                    self.hidden_count = max(0, self.hidden_count - 1)
                    restored.append(sid)
            self.push_state()
            self.push_lights(self.light_for_world())
            self.push_log("info", f"undid clear {batch}: {len(restored)} restored")
            result = {"batch": batch, "restored": restored}
        elif name == "list_history":
            limit = int(args.get("limit") or 500)
            since = args.get("since")
            with self.lock:
                rows = [dict(r) for r in self.history if since is None or r["at"] >= float(since)]
            rows.sort(key=lambda r: r["at"], reverse=True)
            result = {"rows": rows[:limit], "total": len(rows)}
        elif name == "quiet":
            with self.lock:
                seconds = float(args.get("seconds", 1800))
                self.focus = {"mode": args.get("mode", "dnd"), "source": "manual", "until": time.time() + seconds}
            self.push_state()
            self.push_settings()
            result = {"until": self.focus["until"]}
        elif name == "snooze":
            with self.lock:
                self.snoozed_until = time.time() + float(args.get("seconds", 600))
            result = {"until": self.snoozed_until}
        elif name == "set_setting":
            path = str(args.get("path", ""))
            with self.lock:
                ok = set_path(self.document, path, args.get("value"))
            if not ok:
                return {"t": "reply", "v": PROTOCOL_VERSION, "id": cid, "ok": False,
                        "error": {"code": "invalid_path", "message": f"cannot write {path!r}"}}
            self.push_settings()
            if path == "auto_dim" or path.startswith("auto_dim.") or path in (
                    "dot_role", "dot_role_include_completions", "devices_linked", "linked_dot_scale",
                    "link_screen_bar_to_hardware", "screen_bar_phase_offset_ms"):
                self.push_lights(self.lights_semantic)
            self.push_log("info", f"setting {path} changed")
            result = {"generation": self.settings_generation, "path": path}
        elif name == "reset_settings":
            defaults = default_settings_document()
            reset = []
            with self.lock:
                for path in args.get("paths") or []:
                    value, found = get_path(defaults, str(path))
                    if found and set_path(self.document, str(path), json.loads(json.dumps(value))):
                        reset.append(str(path))
            self.push_settings()
            result = {"generation": self.settings_generation, "reset": reset}
        elif name in ("install_hooks", "uninstall_hooks"):
            providers = [p for p in (args.get("providers") or []) if p in HOOK_PROVIDERS]
            with self.lock:
                for p in providers:
                    self.hooks[p] = "ok" if name == "install_hooks" else "missing"
            self.push_state()
            self.push_log("info", f"{name} {','.join(providers)}")
            result = {"providers": providers}
        elif name == "apply_calibration":
            device = args.get("device")
            profile = args.get("profile") or {}
            applied = False
            with self.lock:
                for entry in self.document.get("devices", []):
                    if entry.get("id") == device:
                        for key in ("red_gain", "green_gain", "blue_gain", "resting_glow"):
                            if key in profile:
                                entry[key] = float(profile[key])
                        applied = True
            if not applied:
                return {"t": "reply", "v": PROTOCOL_VERSION, "id": cid, "ok": False,
                        "error": {"code": "not_found", "message": "no such device"}}
            self.push_settings()
            result = {"device": device, "profile": profile}
        elif name == "preview_program":
            surface = str(args.get("surface", "hardware"))
            seconds = float(args.get("seconds", 3))
            with self.lock:
                self.previews[surface] = time.time() + seconds
            result = {"surface": surface, "until": self.previews[surface]}
        elif name == "set_device_display":
            with self.lock:
                for entry in self.document.get("devices", []):
                    if entry.get("id") == args.get("device"):
                        entry["led_display"] = str(args.get("mode", "agent"))
            self.push_settings()
            result = {"device": args.get("device")}
        elif name == "set_closed_lid_policy":
            with self.lock:
                self.document["closed_lid_awake_policy"] = str(args.get("policy", "never"))
            self.push_settings()
            result = {"policy": self.document["closed_lid_awake_policy"]}
        elif name == "refresh_usage":
            providers = [p for p in (args.get("providers") or []) if isinstance(p, str)]
            with self.lock:
                self.usage_refreshed_at = time.time()
            self.tick_usage(0.0)
            # The daemon's reply shape; the new numbers ride the next `state`.
            result = {"requested_at": self.usage_refreshed_at, "providers": providers}
        elif name == "usage_history":
            provider = str(args.get("provider", ""))
            range_name = str(args.get("range", "30d"))
            if provider not in self.usage:
                return self._error(cid, "not_found", f"no usage source for {provider}")
            if range_name not in ("7d", "30d", "90d", "365d"):
                return self._error(cid, "invalid_range", "range must be 7d, 30d, 90d or 365d")
            # The daemon scans transcripts off-thread and answers inside a
            # budget: the first ask for a (provider, range) gets what the
            # scan has so far, marked `partial`, and a `usage_history_ready`
            # event lands when it finishes. --hot-history skips that.
            key = (provider, range_name)
            started = False
            with self.lock:
                if not self.hot_history and key not in self.history_scanned:
                    self.history_scanned.add(key)
                    self.history_inflight.add(key)
                    started = True
                inflight = key in self.history_inflight
            if started:
                threading.Timer(self.history_scan_seconds, self.finish_history_scan, (provider, range_name)).start()
            if started:
                # Nothing cached and the scan has just begun: the daemon's
                # `pending` answer — no rows, marked partial.
                result = usage_history(provider, range_name, time.time(), partial=True)
                result["days"], result["hours"], result["records"] = [], [], 0
            else:
                # Asked again while the scan runs: what memory holds, still
                # marked partial (the daemon's `stale` answer).
                result = usage_history(provider, range_name, time.time(), partial=inflight)
            result["state"] = self.usage[provider]["state"]
        elif name == "list_effects":
            with self.lock:
                result = self.effect_catalog()
        elif name == "render_effect":
            effect = self.find_effect(str(args.get("effect_id", "")))
            if effect is None:
                return self._error(cid, "unknown_effect", "no such effect")
            led_count = int(args.get("led_count", 8) or 8)
            color = args.get("color") if _is_hex(args.get("color")) else EFFECT_BASE_COLOR
            program = render_effect_program(effect, args.get("parameters") or {}, led_count, color)
            result = {"effect_id": effect["id"], "program": program, "led_count": led_count,
                      "parameters": normalize_effect_parameters(effect, args.get("parameters") or {}),
                      "cadence": effect_cadence(effect, args.get("parameters") or {})}
        elif name == "list_assignments":
            with self.lock:
                result = self.assignment_document()
        elif name == "apply_effect":
            # Protocol 1: {effect, scope, target}; `effect` null removes the
            # assignment. `parameters` is the app's extension (the daemon's
            # EffectAssignmentRecord has none yet). The reply carries the
            # assignment list the way the daemon shapes it, plus the fuller
            # rows and the active scene the studio renders.
            scope = str(args.get("scope") or "global")
            if scope not in ("global", "semantic", "scene", "provider", "provider_instance", "project", "device"):
                return self._error(cid, "invalid_args", "unknown assignment scope")
            target = args.get("target")
            target = str(target).strip() or None if target is not None else None
            effect_id = args.get("effect")
            if effect_id in (None, "", "none"):
                with self.lock:
                    before = len(self.assignments)
                    self.assignments = [a for a in self.assignments if (a["scope"], a["target_id"]) != (scope, target)]
                    removed = len(self.assignments) < before
                    if removed:
                        self.effects_generation += 1
                    result = self.assignment_document()
                    result.update({"effect": None, "scope": scope, "target": target, "removed": removed})
                if removed:
                    self.push_log("info", f"assignment {scope}:{target or '*'} removed")
            else:
                effect = self.find_effect(str(effect_id))
                if effect is None:
                    return self._error(cid, "invalid_args", f"unknown effect {effect_id!r}")
                if (scope == "global") != (not target):
                    return self._error(cid, "invalid_args", "global assignments take no target; every other scope needs one")
                if scope == "semantic" and target in ("asking", "failure"):
                    return self._error(cid, "invalid_args", "asking and failure keep their reserved effects")
                if scope == "scene" and target not in ("calm", "focus", "night", "demo", "travel", "dnd"):
                    return self._error(cid, "invalid_args", "unknown scene")
                if target is not None and len(target) > 160:
                    return self._error(cid, "invalid_args", "target too long")
                row = {"effect_id": effect["id"], "scope": scope, "target_id": target,
                       "parameters": normalize_effect_parameters(effect, args.get("parameters") or {})}
                with self.lock:
                    self.assignments = [a for a in self.assignments if (a["scope"], a["target_id"]) != (scope, target)]
                    self.assignments.append(row)
                    self.effects_generation += 1
                    result = self.assignment_document()
                    result.update({"effect": effect["id"], "scope": scope, "target": target, "assignment": row})
                self.push_log("info", f"assignment {scope}:{target or '*'} → {effect['id']}")
        elif name == "import_effect_pack":
            path = Path(str(args.get("path", ""))).expanduser()
            try:
                if path.stat().st_size > 256_000:
                    raise ValueError("pack exceeds size limit")
                pack = validate_pack(json.loads(path.read_text(encoding="utf-8")))
            except (OSError, ValueError, json.JSONDecodeError) as exc:
                return self._error(cid, "invalid_pack", str(exc))
            with self.lock:
                if pack["id"] in self.effect_packs and self.effect_packs[pack["id"]].get("_path") != str(path):
                    return self._error(cid, "conflict", f"pack {pack['id']} is already loaded")
                pack["_path"] = str(path)
                self.effect_packs[pack["id"]] = pack
                self.effects_generation += 1
                result = self.effect_catalog()
                result["imported"] = {"id": pack["id"], "name": pack["name"], "effects": len(pack["effects"])}
            self.push_log("info", f"imported effect pack {pack['id']} ({len(pack['effects'])} effects) from {path}")
        elif name == "export_effect_pack":
            ids = [str(x) for x in (args.get("ids") or [])]
            path = Path(str(args.get("path", ""))).expanduser()
            effects = []
            for effect_id in ids:
                effect = self.find_effect(effect_id)
                if effect is None:
                    return self._error(cid, "unknown_effect", f"no such effect: {effect_id}")
                row = {
                    "id": effect_id.split(":")[-1] if effect.get("pack") else effect_id,
                    "label": effect["label"], "description": effect["description"], "meaning": effect["meaning"],
                    "surfaces": list(effect["surfaces"]), "safety": effect["safety"], "energy": effect["energy"],
                }
                fallback = effect.get("reduce_motion_fallback")
                if fallback and fallback in ids:
                    row["reduce_motion_fallback"] = fallback.split(":")[-1] if fallback.startswith("pack:") else fallback
                elif fallback and effect.get("pack") is None:
                    row["reduce_motion_fallback"] = None
                    del row["reduce_motion_fallback"]
                row.update(normalize_effect_parameters(effect, {}))
                if not effect.get("pack"):
                    row["motion"] = effect_id if effect_id in _MOTION_IDS else "breathe"
                effects.append(row)
            if not effects:
                return self._error(cid, "invalid_args", "ids[] is empty")
            pack_id = "".join(c if c.isalnum() or c in "._-" else "-" for c in str(args.get("name") or path.stem).lower()) or "export"
            payload = {
                "id": pack_id, "name": str(args.get("name") or path.stem or "Export"), "version": 2,
                "safety": {"data_only": True, "network": False},
                "accessibility": {"reduced_motion": True, "high_contrast": True},
                "effects": effects,
            }
            try:
                validate_pack(payload)
                encoded = json.dumps(payload, ensure_ascii=False, sort_keys=True, separators=(",", ":"))
                path.parent.mkdir(parents=True, exist_ok=True)
                path.write_text(encoded + "\n", encoding="utf-8")
            except (OSError, ValueError) as exc:
                return self._error(cid, "export_failed", str(exc))
            result = {"path": str(path), "effects": len(effects), "bytes": len(encoded.encode("utf-8")), "id": pack_id}
            self.push_log("info", f"exported {len(effects)} effects to {path}")
        elif name == "deck_press":
            # What a physical press of that control does, from the screen: a
            # session key reveals its session (no approval is emulated), an
            # auxiliary control runs its explicit mapping.
            index = args.get("index")
            if type(index) is not int or not 0 <= index < 20 + DECK_ANALOG:
                return self.deck_error(cid, "invalid_args", "index must be 0..23")
            if self.deck_input_check:
                return self.deck_error(cid, "input_check", "Input check is on: device actions are paused.")
            with self.lock:
                action, identity, sid = self.deck_press_action(index)
            if action is None:
                if index < DECK_SLOTS:
                    return self.deck_error(cid, "not_found", "Reserved: session not observed." if identity else "No session assigned.")
                return self.deck_error(cid, "not_found", "Configure this auxiliary control in Settings > Devices.")
            result = {"index": index, "action": action, "identity": identity, "session": sid}
            if action == "reveal_session":
                s = self.sessions.get(sid) or {"label": "session", "terminal": {}}
                result["activated"] = s.get("terminal", {}).get("app")
                self.push_log("info", f"deck: key {index + 1} reveals {s['label']}")
            elif action in ("next_bank", "previous_bank"):
                with self.lock:
                    count = self.deck_bank_count()
                    self.deck_bank = (self.deck_bank + (1 if action == "next_bank" else -1)) % count
                    result["bank"] = {"index": self.deck_bank, "count": count}
                self.push_state()
            else:
                self.push_log("info", f"deck: {deck_control_label(index)} runs {action}")
        elif name == "deck_pin":
            # Pins are per identity, so they survive clear_absent and bank changes.
            index = args.get("index")
            if type(index) is not int or not 0 <= index < DECK_SLOTS:
                return self.deck_error(cid, "invalid_args", "index must be 0..12")
            with self.lock:
                offset = self.deck_bank * DECK_SLOTS + index
                identity = self.deck_order[offset] if offset < len(self.deck_order) else None
                if identity is None:
                    return self.deck_error(cid, "not_found", "No session assigned.")
                if identity in self.deck_pinned:
                    self.deck_pinned.discard(identity)
                else:
                    self.deck_pinned.add(identity)
                result = {"index": index, "identity": identity, "pinned": identity in self.deck_pinned}
            self.push_state()
        elif name == "deck_bank":
            delta = args.get("delta", 1)
            if type(delta) is not int:
                return self.deck_error(cid, "invalid_args", "delta must be an integer")
            with self.lock:
                count = self.deck_bank_count()
                self.deck_bank = (self.deck_bank + delta) % count
                result = {"index": self.deck_bank, "count": count}
            self.push_state()
        elif name == "deck_rail":
            edge = args.get("edge")
            if edge not in DECK_RAIL_EDGES:
                return self.deck_error(cid, "invalid_args", "edge must be off, left, right, top or bottom")
            with self.lock:
                self.deck_rail_edge = edge
                result = {"edge": edge}
            self.push_state()
        elif name == "deck_clear_absent":
            # Unpinned identities with no live session leave the board; later
            # keys may move, so the bank is clamped.
            with self.lock:
                before = len(self.deck_order)
                self.deck_order = [identity for identity in self.deck_order
                                   if identity in self.deck_pinned
                                   or (self.deck_identities[identity][0] in self.sessions)]
                removed = before - len(self.deck_order)
                self.deck_bank = min(self.deck_bank, self.deck_bank_count() - 1)
                result = {"removed": removed, "banks": {"index": self.deck_bank, "count": self.deck_bank_count()}}
            self.push_state()
            self.push_log("info", f"deck: cleared {removed} absent slots")
        elif name == "deck_plan_keymap":
            plan = self.deck_plan(args)
            if isinstance(plan, str):
                return self.deck_error(cid, "invalid_plan", plan)
            result = plan
        elif name == "deck_apply_keymap":
            if not self.deck_present or not self.deck_approved:
                return self.deck_error(cid, "connection_required")
            if self.deck_conflict:
                self.deck_set_receipt("device_conflict")
                return self.deck_error(cid, "device_conflict")
            if self.deck_keymap["state"] == "recovering":
                self.deck_set_receipt("recovery_required")
                return self.deck_error(cid, "recovery_required")
            plan = self.deck_plan(args)
            if isinstance(plan, str):
                self.deck_set_receipt("invalid_plan")
                return self.deck_error(cid, "invalid_plan", plan)
            if not plan["changes"]:
                receipt = self.deck_push_receipt("already_configured")
                result = {"code": "already_configured", "message": receipt["message"]} | dict(self.deck_keymap)
            else:
                with self.lock:
                    self.deck_write_layer(plan["profile"], plan["layer"], plan["include_auxiliary"], restore=False)
                    self.deck_keymap = {"state": "applied", "backup_at": self.deck_keymap.get("backup_at") or time.time(),
                                        "generation": self.deck_keymap["generation"] + 1}
                    self.deck_input_check = True
                receipt = self.deck_push_receipt("keymap_verified")
                result = {"code": "keymap_verified", "message": receipt["message"], "changes": plan["changes"]} | dict(self.deck_keymap)
                self.push_log("info", "deck: keymap applied, original backed up; input check on")
                self.deck_input_burst()
        elif name == "deck_restore_keymap":
            if not self.deck_present or not self.deck_approved:
                return self.deck_error(cid, "connection_required")
            if self.deck_conflict:
                self.deck_set_receipt("device_conflict")
                return self.deck_error(cid, "device_conflict")
            if self.deck_keymap["state"] == "stock":
                receipt = self.deck_push_receipt("already_restored")
                result = {"code": "already_restored", "message": receipt["message"]} | dict(self.deck_keymap)
            else:
                with self.lock:
                    for row in self.deck_layers:
                        self.deck_write_layer(row["profile"], row["layer"], True, restore=True)
                    self.deck_keymap = {"state": "stock", "backup_at": None, "generation": self.deck_keymap["generation"] + 1}
                receipt = self.deck_push_receipt("keymap_restored")
                result = {"code": "keymap_restored", "message": receipt["message"]} | dict(self.deck_keymap)
                self.push_log("info", "deck: original keymap restored and verified")
        elif name == "deck_approve_device":
            if not self.deck_present:
                return self.deck_error(cid, "no_device", "No Creator Micro 2 is connected.")
            with self.lock:
                self.deck_approved = True
                result = {"serial": DECK_SERIAL, "approved": True}
            self.push_state()
            self.push_event("device_connected", None, "Creator Micro 2", notify=False)
        elif name == "deck_check_input":
            enabled = args.get("enabled")
            if type(enabled) is not bool:
                return self.deck_error(cid, "invalid_args", "enabled must be a bool")
            with self.lock:
                self.deck_input_check = enabled
                result = {"enabled": enabled}
            self.push_state()
            if enabled and self.deck_present:
                self.deck_input_burst()
        elif name == "deck_set_settings":
            updates = {key: args[key] for key in ("enabled", "session_mode", "analog_enabled") if key in args}
            if not updates or any(type(value) is not bool for value in updates.values()):
                return self.deck_error(cid, "invalid_args", "enabled, session_mode and analog_enabled must be bools")
            with self.lock:
                self.deck_settings.update(updates)
                result = dict(self.deck_settings)
            self.push_state()
        elif name == "quit":
            result = {"bye": True}
        elif name == "doctor":
            with self.lock:
                result = {
                    "ok": True,
                    "core_version": "0.8.0-mock",
                    "socket": "mock",
                    "uptime_seconds": round(time.time() - self.start, 1),
                    "clients": len(self.clients),
                    "hooks": dict(self.hooks),
                    "devices": {d["id"]: ("connected" if d.get("connected", d.get("enabled")) else "absent")
                                for d in self.devices.values()},
                    "settings_generation": self.settings_generation,
                    "state_generation": self.generation,
                    "checks": [
                        {"name": "socket permissions", "ok": True, "detail": "0600, peer uid matches"},
                        {"name": "hook shim", "ok": True, "detail": "jrbar-hook 0.8.0 on PATH"},
                        {"name": "sleep helper", "ok": True, "detail": "installed"},
                        {"name": "closed-lid policy", "ok": True, "detail": self.document["closed_lid_awake_policy"]},
                        {"name": "pending hook lines", "ok": True, "detail": "0 files"},
                    ],
                }
        return {"t": "reply", "v": PROTOCOL_VERSION, "id": cid, "ok": True, "result": result}


class Client:
    def __init__(self, world: World, conn: socket.socket, once: bool, stop: threading.Event) -> None:
        self.world = world
        self.conn = conn
        self.once = once
        self.stop = stop
        self.write_lock = threading.Lock()
        self.alive = True

    def send(self, document: dict) -> None:
        if not self.alive:
            return
        line = json.dumps(document, separators=(",", ":")) + "\n"
        with self.write_lock:
            try:
                self.conn.sendall(line.encode("utf-8"))
            except OSError:
                self.alive = False

    def serve(self) -> None:
        world = self.world
        with world.lock:
            world.clients.append(self)
            documents = [world.hello(), world.state(), world.lights(), world.settings()]
        for document in documents:
            self.send(document)
        log("client connected; sent hello/state/lights/settings")
        if self.once:
            with world.lock:
                if self in world.clients:
                    world.clients.remove(self)
            try:
                self.conn.shutdown(socket.SHUT_WR)
                self.conn.settimeout(0.5)
                try:
                    self.conn.recv(1)
                except OSError:
                    pass
            finally:
                self.conn.close()
            self.alive = False
            self.stop.set()
            return
        buffer = b""
        try:
            while self.alive and not self.stop.is_set():
                chunk = self.conn.recv(65536)
                if not chunk:
                    break
                buffer += chunk
                while b"\n" in buffer:
                    line, buffer = buffer.split(b"\n", 1)
                    if not line.strip():
                        continue
                    try:
                        command = json.loads(line)
                    except json.JSONDecodeError as exc:
                        log(f"bad frame: {exc}")
                        continue
                    log(f"command {command.get('name')} {json.dumps(command.get('args') or {})} (id {command.get('id')})")
                    if command.get("t") != "command":
                        continue
                    self.send(world.handle_command(command))
        except OSError:
            pass
        finally:
            self.alive = False
            with world.lock:
                if self in world.clients:
                    world.clients.remove(self)
            try:
                self.conn.close()
            except OSError:
                pass
            log("client disconnected")


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--socket", default=str(DEFAULT_SOCKET),
                        help=f"socket path (default: {DEFAULT_SOCKET}; the installed daemon's socket is refused)")
    parser.add_argument("--i-know-this-is-the-real-socket", action="store_true",
                        help=f"allow binding {REAL_SOCKET}, which the installed JR-Bar.app connects to")
    parser.add_argument("--step", type=float, default=2.0, help="seconds between timeline steps")
    parser.add_argument("--once", action="store_true", help="send hello/state/lights/settings to the first client, then exit")
    parser.add_argument("--loop", action="store_true",
                        help="replay the timeline forever (default: once, so its sounds and banners stop)")
    parser.add_argument("--no-loop", action="store_true", help=argparse.SUPPRESS)
    parser.add_argument("--start-at", type=int, default=0, metavar="N",
                        help="begin the timeline at step N (0 claude working, 1 deck keys, 2 codex ask, "
                             "3 ask stage 2, 4 ask stage 3, 5 ask resolved, 6 codex completed, 7 pro disconnected, "
                             "8 pro reconnected, 9 deck conflict, 10 conflict cleared, 11 gemini failed, "
                             "12 claude completed, 13 idle)")
    parser.add_argument("--mode", default="0600", help="socket file mode (octal)")
    parser.add_argument("--hot-history", action="store_true",
                        help="answer usage_history in full at once (no partial first answer, no usage_history_ready)")
    parser.add_argument("--history-scan", type=float, default=3.0, metavar="SECONDS",
                        help="how long the simulated usage_history scan takes before usage_history_ready (default 3)")
    parser.add_argument("--hidden", type=int, default=3, metavar="N",
                        help="state.hidden_count to start with (acknowledged sessions History still has)")
    parser.add_argument("--deck", choices=("approved", "unapproved", "absent", "usb", "recovering"), default="approved",
                        help="how the Creator Micro 2 starts: approved over Bluetooth (default), connected but "
                             "not yet approved, not connected, approved over USB, or with an interrupted keymap "
                             "write that needs Restore")
    args = parser.parse_args()

    path = Path(args.socket).expanduser()
    if not args.i_know_this_is_the_real_socket and (
            path == REAL_SOCKET or path.resolve() == REAL_SOCKET.resolve()):
        log(f"refusing to bind {path}: that is the installed daemon's socket and the installed JR-Bar.app "
            f"would take this mock for the real core. Use the default ({DEFAULT_SOCKET}) or pass "
            "--i-know-this-is-the-real-socket.")
        return 2
    path.parent.mkdir(parents=True, exist_ok=True)
    if path.exists():
        probe = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
        try:
            probe.connect(str(path))
        except OSError:
            path.unlink()
        else:
            probe.close()
            log(f"another daemon is listening on {path}; refusing to replace it")
            return 2
        finally:
            probe.close()

    stop = threading.Event()
    world = World(step_seconds=args.step, loop=args.loop and not args.no_loop)
    world.hot_history = args.hot_history
    world.history_scan_seconds = max(0.0, args.history_scan)
    world.hidden_count = max(0, args.hidden)
    world.deck_present = args.deck != "absent"
    world.deck_approved = args.deck in ("approved", "usb", "recovering")
    world.deck_transport = "usb" if args.deck == "usb" else "bluetooth"
    if args.deck == "recovering":
        world.deck_keymap = {"state": "recovering", "backup_at": time.time() - 900, "generation": 3}
        world.deck_set_receipt("recovery_required")

    server = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
    server.bind(str(path))
    os.chmod(path, int(args.mode, 8))
    own_inode = os.stat(path).st_ino
    server.listen(8)
    server.settimeout(0.25)
    log(f"listening on {path}{' (once)' if args.once else ''}; step {args.step}s")

    def shutdown(*_):
        stop.set()

    signal.signal(signal.SIGINT, shutdown)
    signal.signal(signal.SIGTERM, shutdown)

    timeline = None
    if not args.once:
        timeline = threading.Thread(target=world.run_timeline, args=(stop, args.start_at), name="timeline", daemon=True)
        timeline.start()

    try:
        while not stop.is_set():
            try:
                conn, _ = server.accept()
            except socket.timeout:
                continue
            except OSError:
                break
            client = Client(world, conn, args.once, stop)
            threading.Thread(target=client.serve, name="client", daemon=True).start()
    finally:
        stop.set()
        server.close()
        try:
            # Only remove the socket if it is still ours (a newer daemon may
            # have replaced a stale file while we were being stopped).
            if os.stat(path).st_ino == own_inode:
                path.unlink()
        except OSError:
            pass
        log("stopped")
    return 0


if __name__ == "__main__":
    sys.exit(main())
