"""Pure builders and vocabulary for ``state.deck`` (the Creator Micro 2) and
the ``deck_*`` commands (docs/CORE-PROTOCOL.md, "The Creator Micro 2 deck").

Nothing here imports AppKit or touches the controller: the runtime
(``core_runtime``) gathers the facts from the session board, the deck
control settings, the integration settings, the HID probe, the output
service receipts and the keymap backup files, and hands them here. The
user-facing sentences are the Python app's own, verbatim.
"""

from __future__ import annotations

import json
from dataclasses import dataclass
from pathlib import Path
from typing import Any, Final

from .creator_micro_keymap import KeymapPlan, keymap_digest, keymap_layers
from .deck_session_board import RAIL_EDGES, SLOTS_PER_BANK
from .private_io import read_private_text

DECK_NAME: Final = "Creator Micro 2"
AUX_LABELS: Final = {
    13: "Encoder 1 input 1",
    14: "Encoder 1 input 2",
    15: "Encoder 1 input 3",
    16: "Joystick sector 1",
    17: "Joystick sector 2",
    18: "Joystick sector 3",
    19: "Joystick sector 4",
}
ANALOG_FIRST_INDEX: Final = 20
CONTROL_COUNT: Final = 24
# Per-key lighting: the solid colour the lighting layer writes, the dark
# key while the pad is driven, and black when it is not.
DARK_COLOR: Final = "#020204"
OFF_COLOR: Final = "#000000"
SLOT_STATES: Final = (
    "input_required",
    "failure",
    "active",
    "completed",
    "idle",
    "stale",
    "unavailable",
    "unknown",
    "ended_unconfirmed",
)
KEYMAP_STATES: Final = ("stock", "applied", "recovering", "unknown")
INPUT_KINDS: Final = ("press", "dial", "joystick", "analog")

# The user-facing strings of creator_micro_setup_controller.py, verbatim.
SETUP_RECEIPT_MESSAGES: Final = {
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
# The output service's receipts as deck_status_bar.py words them.
OUTPUT_RECEIPT_MESSAGES: Final = {
    "ready": "Creator Micro 2 ready.",
    "unsupported_firmware": "Creator Micro 2 firmware does not expose agent-status output.",
    "device_conflict": "Creator Micro 2 stopped after detecting conflicting device traffic.",
    # Over Bluetooth the pad's keyboard and vendor collections share one macOS
    # HID device, so opening it needs Input Monitoring. Without this sentence
    # the refusal reads as a pad that keeps disconnecting.
    "input_monitoring_denied": "Allow JR-Bar in macOS Input Monitoring settings to use Creator Micro 2.",
    "transport_unavailable": "Creator Micro 2 could not be opened.",
    "no_device": "No Creator Micro 2 is connected.",
    "per_key_output_unsupported": "Creator Micro 2 firmware does not light single keys.",
    "aggregate_preview": "Creator Micro 2 lights the whole pad, not one key per session.",
}
# Device-action receipts as deck_controller.py words them.
ACTION_RECEIPT_MESSAGES: Final = {
    "accessibility_not_trusted": "Allow JR-Bar in macOS Accessibility settings to use app shortcuts.",
    "target_not_frontmost": "Switch to the mapped app before using its shortcut.",
    "target_not_running": "Open the mapped app before using its shortcut.",
    "app_not_found": "The mapped app is not installed. Choose it again in Devices settings.",
}
INPUT_CHECK_MESSAGE: Final = "Input check is on: device actions are paused."
NO_SESSION_MESSAGE: Final = "No session assigned."
RESERVED_MESSAGE: Final = "Reserved: session not observed."
AUXILIARY_MESSAGE: Final = "Configure this auxiliary control in Settings > Devices."
NO_DEVICE_MESSAGE: Final = "No Creator Micro 2 is connected."


def receipt_message(code: str, *, source: str = "setup") -> str:
    """The Python app's sentence for a receipt code: the setup table for
    keymap work, the Devices pane's words for the output service, the
    deck controller's for device actions; a generic sentence otherwise."""
    table = {"setup": SETUP_RECEIPT_MESSAGES, "output": OUTPUT_RECEIPT_MESSAGES, "action": ACTION_RECEIPT_MESSAGES}.get(
        source, SETUP_RECEIPT_MESSAGES
    )
    # Opening the pad can be refused the same way during keymap setup as
    # during lighting, so a device-access code keeps its sentence whichever
    # operation ran into it.
    text = table.get(code) or SETUP_RECEIPT_MESSAGES.get(code) or OUTPUT_RECEIPT_MESSAGES.get(code)
    if text is not None:
        return text
    if source == "action":
        return f"Device action: {code.replace('_', ' ')}."
    return f"{DECK_NAME}: {code.replace('_', ' ')}."


def control_label(index: int, labels: dict[int, str] | None = None) -> str:
    """"Key N" for the matrix, the encoder / joystick names for AG13..AG19
    (the inspected keymap's own labels when known), "Analog sector N"."""
    if 0 <= index < SLOTS_PER_BANK:
        return f"Key {index + 1}"
    if labels and index in labels:
        return str(labels[index])
    if index in AUX_LABELS:
        return AUX_LABELS[index]
    if ANALOG_FIRST_INDEX <= index < CONTROL_COUNT:
        return f"Analog sector {index - ANALOG_FIRST_INDEX + 1}"
    return f"AG{index:02d}"


def input_kind(index: int, kind: str) -> str:
    """The app's input word for a normalised Python input (``press``,
    ``rotate``, ``axis_sector``, optionally ``virtual_``-prefixed)."""
    word = str(kind or "press")
    if word.startswith("virtual_"):
        word = word[len("virtual_"):]
    if word == "axis_sector" or ANALOG_FIRST_INDEX <= index < CONTROL_COUNT:
        return "analog"
    if word == "rotate" or 13 <= index <= 15:
        return "dial"
    if 16 <= index <= 19:
        return "joystick"
    return "press"


def transport_word(bus_type: object) -> str | None:
    """hidapi's ``bus_type``: 1 is USB, 2 is Bluetooth."""
    return {1: "usb", 2: "bluetooth"}.get(bus_type) if isinstance(bus_type, int) else None


def preview_text(plan: KeymapPlan) -> str:
    """The review alert's text, as creator_micro_setup_controller shows it."""
    changed = "\n".join(plan.changes) if plan.changes else "No device keys need to change."
    return (
        f"Selected profile {plan.profile_index + 1}, layer {plan.layer_index + 1}:\n\n"
        f"{changed}\n\n"
        "The listed keys will replace their normal keystrokes with JR-Bar device inputs. "
        + ("Supported dial/joystick mappings listed above also change. " if plan.include_auxiliary
           else "Dial and joystick mappings stay unchanged. ")
        + "Thread colors are device-wide, not layer-specific. Stored mappings may require reconnecting to activate. "
        "JR-Bar does not switch the device profile or layer through an undocumented RPC."
    )


def plan_document(plan: KeymapPlan) -> dict[str, Any]:
    """``deck_plan_keymap``'s reply."""
    return {
        "profile": plan.profile_index,
        "layer": plan.layer_index,
        "include_auxiliary": bool(plan.include_auxiliary),
        "changes": list(plan.changes),
        "preview": preview_text(plan),
        "controls": [{"index": index, "label": label} for index, label in plan.control_labels],
    }


def keymap_layer_rows(raw: str | None) -> list[dict[str, Any]]:
    """``keymap.layers`` from a keymap JSON text (the inspected original or
    the backup's); empty when there is none or it does not parse."""
    if not isinstance(raw, str) or not raw:
        return []
    try:
        return [
            {"profile": profile, "layer": layer, "label": label}
            for profile, layer, label in keymap_layers(raw)
        ]
    except (ValueError, TypeError):
        return []


@dataclass(frozen=True, slots=True)
class KeymapFacts:
    state: str = "stock"
    backup_at: float | None = None
    original_json: str | None = None


def keymap_facts(backup_path: Path | None) -> KeymapFacts:
    """What the private backup and its recovery journal say about the pad:
    ``stock`` (no backup, or the journal says the original is back on the
    device), ``applied`` (a verified JR-Bar write), ``recovering`` (an
    interrupted transfer), ``unknown`` (files that do not parse)."""
    if backup_path is None:
        return KeymapFacts()
    try:
        raw = read_private_text(backup_path, max_bytes=266_240)
    except FileNotFoundError:
        return KeymapFacts()
    except (OSError, ValueError):
        return KeymapFacts("unknown")
    try:
        backup_at = float(backup_path.stat().st_mtime)
    except OSError:
        backup_at = None
    try:
        backup = json.loads(raw)
        original_digest = backup["original_digest"]
        original_json = backup["original_json"]
        if not isinstance(original_digest, str) or not isinstance(original_json, str):
            raise ValueError("backup shape")
    except (ValueError, TypeError, KeyError):
        return KeymapFacts("unknown", backup_at)
    try:
        journal_raw = read_private_text(backup_path.with_suffix(".recovery.json"), max_bytes=800_000)
    except FileNotFoundError:
        # A backup is saved before the first byte is written; without a
        # journal nothing reached the device.
        return KeymapFacts("stock", backup_at, original_json)
    except (OSError, ValueError):
        return KeymapFacts("unknown", backup_at, original_json)
    try:
        journal = json.loads(journal_raw)
        state = journal["state"]
        after = journal["after_json"]
    except (ValueError, TypeError, KeyError):
        return KeymapFacts("unknown", backup_at, original_json)
    if state == "pending":
        return KeymapFacts("recovering", backup_at, original_json)
    try:
        restored = keymap_digest(after) == original_digest
    except (ValueError, TypeError):
        return KeymapFacts("unknown", backup_at, original_json)
    return KeymapFacts("stock" if restored else "applied", backup_at, original_json)


def slot_color(state: str, *, colors: object = None, brightness: float = 0.4, driven: bool = True) -> str:
    """The solid per-key colour the lighting layer writes for a slot state
    (``creator_micro_lighting.creator_micro_light_frame``): ``#000000``
    when the pad is not driven, the dark key for idle-like states."""
    if not driven:
        return OFF_COLOR
    from .creator_micro_lighting import creator_micro_light_frame

    word = state if state in ("input_required", "failure", "active", "completed") else "idle"
    try:
        frame = creator_micro_light_frame(word, colors=colors, brightness=max(0.0, min(1.0, float(brightness))))
    except (ValueError, TypeError):
        return DARK_COLOR
    if frame.brightness <= 0.0 or frame.effect == 0:
        return DARK_COLOR
    return f"#{frame.color:06X}"


@dataclass(frozen=True, slots=True)
class DeckSlotFacts:
    """One slot of the current bank, before it becomes a document row."""

    index: int
    identity: str | None = None
    session: str | None = None
    label: str | None = None
    provider: str | None = None
    state: str = "unavailable"
    pinned: bool = False
    navigable: bool = False


def slot_document(slot: DeckSlotFacts, *, colors: object = None, brightness: float = 0.4, driven: bool = True) -> dict[str, Any]:
    state = slot.state if slot.state in SLOT_STATES else "unknown"
    return {
        "index": int(slot.index),
        "identity": slot.identity,
        "session": slot.session,
        "label": slot.label,
        "provider": slot.provider,
        "state": state,
        "pinned": bool(slot.pinned),
        "navigable": bool(slot.navigable),
        "color": slot_color(state, colors=colors, brightness=brightness, driven=driven),
    }


def aux_documents(bindings: dict[int, str] | None = None, labels: dict[int, str] | None = None) -> list[dict[str, Any]]:
    bindings = bindings or {}
    return [
        {"index": index, "label": control_label(index, labels), "mapping": bindings.get(index)}
        for index in sorted(AUX_LABELS)
    ]


def build_deck_document(
    *,
    device: dict[str, Any] | None,
    slots: list[DeckSlotFacts] | tuple[DeckSlotFacts, ...],
    bank: int,
    bank_count: int,
    rail_edge: str,
    keymap_state: str,
    backup_at: float | None,
    keymap_generation: int,
    layers: list[dict[str, Any]],
    input_check: bool,
    last_input: dict[str, Any] | None,
    settings: dict[str, Any],
    bindings: dict[int, str] | None = None,
    control_labels: dict[int, str] | None = None,
    colors: object = None,
    brightness: float = 0.4,
    driven: bool = False,
) -> dict[str, Any]:
    """``state.deck``: the shape the Control Center and the Rail decode."""
    return {
        "device": dict(device) if device is not None else None,
        "slots": [slot_document(slot, colors=colors, brightness=brightness, driven=driven) for slot in slots],
        "aux": aux_documents(bindings, control_labels),
        "banks": {"index": int(bank), "count": max(1, int(bank_count))},
        "rail": {"edge": rail_edge if rail_edge in RAIL_EDGES else "off"},
        "keymap": {
            "state": keymap_state if keymap_state in KEYMAP_STATES else "unknown",
            "backup_at": backup_at,
            "generation": int(keymap_generation),
            "layers": list(layers),
        },
        "input_check": bool(input_check),
        "last_input": dict(last_input) if last_input else None,
        "settings": {
            "enabled": bool(settings.get("enabled", False)),
            "session_mode": bool(settings.get("session_mode", False)),
            "analog_enabled": bool(settings.get("analog_enabled", False)),
        },
    }


def device_document(
    *,
    serial: str | None,
    transport: str | None,
    connected: bool,
    approved: bool,
    firmware: str | None = None,
    layer: int | None = None,
    profile: int | None = None,
    conflict: str | None = None,
    receipt: dict[str, Any] | None = None,
) -> dict[str, Any]:
    return {
        "serial": serial,
        "name": DECK_NAME,
        "transport": transport,
        "connected": bool(connected),
        "approved": bool(approved),
        "firmware": firmware,
        "layer": layer,
        "profile": profile,
        "conflict": conflict,
        "receipt": dict(receipt) if receipt else None,
    }


__all__ = [
    "ACTION_RECEIPT_MESSAGES",
    "AUXILIARY_MESSAGE",
    "AUX_LABELS",
    "CONTROL_COUNT",
    "DARK_COLOR",
    "DECK_NAME",
    "INPUT_CHECK_MESSAGE",
    "INPUT_KINDS",
    "KEYMAP_STATES",
    "NO_DEVICE_MESSAGE",
    "NO_SESSION_MESSAGE",
    "OFF_COLOR",
    "OUTPUT_RECEIPT_MESSAGES",
    "RESERVED_MESSAGE",
    "SETUP_RECEIPT_MESSAGES",
    "SLOT_STATES",
    "DeckSlotFacts",
    "KeymapFacts",
    "aux_documents",
    "build_deck_document",
    "control_label",
    "device_document",
    "input_kind",
    "keymap_facts",
    "keymap_layer_rows",
    "plan_document",
    "preview_text",
    "receipt_message",
    "slot_color",
    "slot_document",
    "transport_word",
]
