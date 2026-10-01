"""The outcome of a saved Control Center settings change, applied on the main thread."""

from __future__ import annotations

from dataclasses import dataclass

from .deck_control_settings import DeckControlSettings


@dataclass(frozen=True, slots=True)
class DeckSettingsApplyResult:
    generation: int
    previous: DeckControlSettings
    candidate: DeckControlSettings
    error: str | None = None
    paused_on_failure: bool = False

    def __post_init__(self) -> None:
        if type(self.generation) is not int or self.generation < 1:
            raise ValueError("invalid deck settings result")
        if type(self.previous) is not DeckControlSettings or type(self.candidate) is not DeckControlSettings:
            raise ValueError("invalid deck settings result")
        if self.error is not None and (type(self.error) is not str or not self.error):
            raise ValueError("invalid deck settings error")
        if type(self.paused_on_failure) is not bool or (self.paused_on_failure and self.error is None):
            raise ValueError("invalid deck settings pause state")


def apply_deck_settings_result(controller: object, payload: DeckSettingsApplyResult) -> None:
    if type(payload) is not DeckSettingsApplyResult:
        raise ValueError("invalid deck settings apply result")
    if payload.generation != getattr(controller, "_deck_settings_save_generation", None):
        return
    controller._deck_settings_save_in_flight = False
    if payload.error is not None:
        return
    controller._deck_control_settings = payload.candidate
    if not getattr(controller, "_runtime_termination_started", False):
        # A saved layer map or scope list re-scopes the board for the layer
        # the pad is on right now.
        from .deck_controller import refresh_deck_scope
        refresh_deck_scope(controller)
        controller.reconfigureDeckRuntime_(payload.candidate)


__all__ = [
    "DeckSettingsApplyResult",
    "apply_deck_settings_result",
]
