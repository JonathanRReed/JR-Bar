"""Owner-private, versioned mappings from logical device keys to local actions."""

from __future__ import annotations

import json
import threading
from dataclasses import dataclass, replace
from pathlib import Path

from .deck_actions import DeckAction
from .integration_settings import default_integration_settings_path
from .private_io import atomic_private_write, read_private_text

_WRITE_LOCK = threading.Lock()

# Auxiliary inputs 13..19 do something useful out of the box: the encoder
# pages banks, its press reveals the current ask, and the joystick's side
# sectors cycle the board scope. Explicit aux bindings replace this whole set.
DEFAULT_AUX_BINDINGS: tuple[tuple[int, str], ...] = (
    (13, "next_bank"),
    (14, "previous_bank"),
    (15, "reveal_current_ask"),
    (16, "previous_scope"),
    (18, "next_scope"),
)

# Fresh installs map the Creator Micro 2's three hardware layers to sensible
# scopes; documents written before layer maps existed keep every layer
# automatic instead.
DEFAULT_LAYER_MAP: tuple[tuple[int, str], ...] = ((1, "codex"), (2, "claude"))


def _valid_scope(value) -> bool:
    return (type(value) is str and 0 < len(value) <= 64
            and value.isprintable() and bool(value.strip()))


@dataclass(frozen=True, slots=True)
class DeckControlSettings:
    enabled: bool = False
    bindings: tuple[tuple[int, DeckAction], ...] = ()
    session_mode: bool = False
    analog_enabled: bool = False
    layer_map: tuple[tuple[int, str], ...] = DEFAULT_LAYER_MAP
    scopes: tuple[str, ...] = ()

    def __post_init__(self) -> None:
        if type(self.enabled) is not bool or type(self.bindings) is not tuple or len(self.bindings) > 24:
            raise ValueError("invalid deck control settings")
        if type(self.session_mode) is not bool or type(self.analog_enabled) is not bool:
            raise ValueError("invalid control-center options")
        seen = set()
        for binding in self.bindings:
            if type(binding) is not tuple or len(binding) != 2:
                raise ValueError("invalid deck binding")
            key, action = binding
            if type(key) is not int or not 0 <= key <= 23 or key in seen or type(action) is not DeckAction:
                raise ValueError("invalid deck binding")
            seen.add(key)
        if type(self.layer_map) is not tuple or len(self.layer_map) > 24:
            raise ValueError("invalid deck layer map")
        mapped_layers = set()
        mapped_scopes = set()
        for entry in self.layer_map:
            if type(entry) is not tuple or len(entry) != 2:
                raise ValueError("invalid deck layer map")
            layer, scope = entry
            if (type(layer) is not int or layer < 0 or layer in mapped_layers
                    or not _valid_scope(scope)):
                raise ValueError("invalid deck layer map")
            mapped_layers.add(layer)
            if scope != "automatic":
                mapped_scopes.add(scope)
        if type(self.scopes) is not tuple:
            raise ValueError("invalid deck scopes")
        seen_scopes = set(mapped_scopes)
        for scope in self.scopes:
            if not _valid_scope(scope) or scope == "automatic" or scope in seen_scopes:
                raise ValueError("invalid deck scopes")
            seen_scopes.add(scope)

    def action_for(self, key: int) -> DeckAction | None:
        if not self.enabled or type(key) is not int:
            return None
        action = next((action for index, action in self.bindings if index == key), None)
        if action is None and not any(13 <= index < 20 for index, _ in self.bindings):
            default = next((kind for index, kind in DEFAULT_AUX_BINDINGS if index == key), None)
            if default is not None:
                return DeckAction(default)
        return action

    def effective_bindings(self) -> tuple[tuple[int, DeckAction], ...]:
        """Explicit bindings, plus the aux defaults when no aux input is bound."""
        if any(13 <= index < 20 for index, _ in self.bindings):
            return self.bindings
        return tuple(sorted((*self.bindings,
                             *((index, DeckAction(kind)) for index, kind in DEFAULT_AUX_BINDINGS))))

    def scope_for_layer(self, layer: int | None) -> str | None:
        """The board scope a hardware layer selects; None means automatic."""
        if type(layer) is not int:
            return None
        return next((scope for index, scope in self.layer_map if index == layer), None)

    def all_scopes(self) -> tuple[str, ...]:
        """Provider scopes in cycle order: mapped layers first, then extras."""
        ordered = []
        for _layer, scope in sorted(self.layer_map):
            if scope != "automatic" and scope not in ordered:
                ordered.append(scope)
        for scope in self.scopes:
            if scope not in ordered:
                ordered.append(scope)
        return tuple(ordered)

    def with_binding(self, key: int, action: DeckAction | None) -> DeckControlSettings:
        if type(key) is not int or not 0 <= key <= 23:
            raise ValueError("invalid deck key")
        bindings = tuple((index, value) for index, value in self.bindings if index != key)
        if action is not None:
            bindings += ((key, action),)
        return replace(self, bindings=tuple(sorted(bindings)))

    def to_dict(self) -> dict[str, object]:
        return {
            "version": 3, "enabled": self.enabled,
            "session_mode": self.session_mode, "analog_enabled": self.analog_enabled,
            "bindings": [{"key": key, "action": action.to_dict()} for key, action in self.bindings],
            "layer_map": [{"layer": layer, "scope": scope} for layer, scope in self.layer_map],
            "scopes": list(self.scopes),
        }


def load_deck_controls(path: Path | None = None) -> DeckControlSettings:
    target = path or default_integration_settings_path().with_name("deck-controls.json")
    try:
        raw = read_private_text(target, max_bytes=32 * 1024)
    except FileNotFoundError:
        return DeckControlSettings()
    return decode_deck_controls(raw)


def decode_deck_controls(raw: str) -> DeckControlSettings:
    """Parse an exported mapping; importing never enables execution implicitly."""
    if type(raw) is not str or len(raw.encode("utf-8")) > 32 * 1024:
        raise ValueError("deck settings exceed the size limit")
    def unique(pairs):
        result = {}
        for key, value in pairs:
            if key in result:
                raise ValueError("duplicate settings field")
            result[key] = value
        return result
    document = json.loads(raw, object_pairs_hook=unique)
    base = {"version", "enabled", "bindings"}
    if type(document) is not dict or type(document.get("version")) is not int:
        raise ValueError("unsupported deck settings document")
    version = document["version"]
    if version == 1:
        fields = base
    elif version == 2:
        fields = base | {"session_mode", "analog_enabled"}
    else:
        fields = base | {"session_mode", "analog_enabled", "layer_map", "scopes"}
    if (version not in (1, 2, 3) or set(document) != fields
            or type(document["bindings"]) is not list or len(document["bindings"]) > (20 if version == 1 else 24)):
        raise ValueError("unsupported deck settings document")
    bindings = []
    for binding in document["bindings"]:
        if type(binding) is not dict or set(binding) != {"key", "action"}:
            raise ValueError("invalid deck binding")
        bindings.append((binding["key"], DeckAction.from_dict(binding["action"])))
    layer_map = []
    for entry in document.get("layer_map", []):
        if type(entry) is not dict or set(entry) != {"layer", "scope"}:
            raise ValueError("invalid deck layer map")
        layer_map.append((entry["layer"], entry["scope"]))
    scopes = document.get("scopes", [])
    if type(scopes) is not list:
        raise ValueError("invalid deck scopes")
    # v1/v2 documents predate scopes: every layer stays automatic rather than
    # silently inheriting the fresh-install map.
    return DeckControlSettings(document["enabled"], tuple(bindings),
                               document.get("session_mode", False), document.get("analog_enabled", False),
                               tuple(layer_map), tuple(scopes))


def save_deck_controls(
    settings: DeckControlSettings, path: Path | None = None, *, expected: DeckControlSettings,
) -> Path:
    if type(settings) is not DeckControlSettings or type(expected) is not DeckControlSettings:
        raise ValueError("invalid deck settings")
    target = path or default_integration_settings_path().with_name("deck-controls.json")
    with _WRITE_LOCK:
        if load_deck_controls(target) != expected:
            raise ValueError("deck settings changed; reload before saving")
        return atomic_private_write(target, json.dumps(settings.to_dict(), indent=2) + "\n")
