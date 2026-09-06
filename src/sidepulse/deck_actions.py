"""Bounded, device-independent actions available to a JR-Bar macro pad."""

from __future__ import annotations

import re
from collections.abc import Mapping
from dataclasses import dataclass
from typing import Any, Literal

DeckActionKind = Literal[
    "open_app",
    "shortcut",
    "reveal_current_ask",
    "open_agent_browser",
    "open_usage",
    "open_control_center",
    "next_bank",
    "previous_bank",
    "run_system_shortcut",
    "reveal_session",
]

_KINDS = frozenset({"open_app", "shortcut", "reveal_current_ask", "open_agent_browser", "open_usage",
                    "open_control_center", "next_bank", "previous_bank", "run_system_shortcut", "reveal_session"})
_MODIFIERS = frozenset({"command", "control", "option", "shift"})
_SERIALIZED_FIELDS = frozenset({"kind", "bundle_id", "key_code", "modifiers"})
_BUNDLE_ID = re.compile(r"[A-Za-z0-9][A-Za-z0-9.-]*\.[A-Za-z0-9.-]*[A-Za-z0-9]$")


@dataclass(frozen=True, slots=True)
class DeckAction:
    """One validated action, with no script, text, URL, or shell escape hatch."""

    kind: DeckActionKind
    bundle_id: str | None = None
    key_code: int | None = None
    modifiers: tuple[str, ...] = ()
    shortcut_name: str | None = None

    def __post_init__(self) -> None:
        if type(self.kind) is not str or self.kind not in _KINDS:
            raise ValueError("unsupported deck action kind")
        if self.kind == "run_system_shortcut":
            if (type(self.shortcut_name) is not str or not self.shortcut_name.strip()
                    or self.shortcut_name != self.shortcut_name.strip() or len(self.shortcut_name) > 128
                    or not self.shortcut_name.isprintable() or self.shortcut_name.startswith("-")):
                raise ValueError("choose an exact, printable system Shortcut name")
        elif self.shortcut_name is not None:
            raise ValueError("only a system Shortcut action accepts shortcut_name")
        if type(self.modifiers) is not tuple:
            raise TypeError("modifiers must be a tuple")
        if any(type(modifier) is not str or modifier not in _MODIFIERS for modifier in self.modifiers):
            raise ValueError("unsupported shortcut modifier")
        if len(set(self.modifiers)) != len(self.modifiers):
            raise ValueError("shortcut modifiers must be unique")

        if self.kind in {"open_app", "shortcut"}:
            if (
                type(self.bundle_id) is not str
                or len(self.bundle_id) > 255
                or _BUNDLE_ID.fullmatch(self.bundle_id) is None
            ):
                raise ValueError("open_app and shortcut require a valid bundle identifier")
        elif self.bundle_id is not None:
            raise ValueError(f"{self.kind} does not accept a bundle identifier")

        if self.kind == "shortcut":
            if type(self.key_code) is not int or not 0 <= self.key_code <= 127:
                raise ValueError("shortcut key_code must be an integer from 0 through 127")
        elif self.key_code is not None:
            raise ValueError(f"{self.kind} does not accept a key code")

        if self.kind != "shortcut" and self.modifiers:
            raise ValueError(f"{self.kind} does not accept modifiers")

    def to_dict(self) -> dict[str, object]:
        value = {
            "kind": self.kind,
            "bundle_id": self.bundle_id,
            "key_code": self.key_code,
            "modifiers": list(self.modifiers),
        }
        if self.shortcut_name is not None:
            value["shortcut_name"] = self.shortcut_name
        return value

    @classmethod
    def from_dict(cls, value: Mapping[str, Any]) -> DeckAction:
        if not isinstance(value, Mapping):
            raise TypeError("deck action must be a mapping")
        if set(value) not in (_SERIALIZED_FIELDS, _SERIALIZED_FIELDS | {"shortcut_name"}):
            raise ValueError("deck action fields must exactly match the serialized contract")
        modifiers = value["modifiers"]
        if type(modifiers) is not list or any(type(item) is not str for item in modifiers):
            raise TypeError("serialized modifiers must be a list of strings")
        return cls(
            kind=value["kind"],
            bundle_id=value["bundle_id"],
            key_code=value["key_code"],
            modifiers=tuple(modifiers),
            shortcut_name=value.get("shortcut_name"),
        )


__all__ = ["DeckAction", "DeckActionKind"]
