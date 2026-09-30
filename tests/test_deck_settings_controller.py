from __future__ import annotations

from types import SimpleNamespace

from jrbar.deck_actions import DeckAction
from jrbar.deck_control_settings import DeckControlSettings
from jrbar.deck_settings_controller import (
    DeckSettingsApplyResult,
    apply_deck_settings_result,
)


class _Controller:
    def __init__(self, settings):
        self._deck_control_settings = settings
        self.reconfigured = []
        self._runtime_termination_started = False
        self.deck_runtime = SimpleNamespace(revoke_deck_input=lambda: None)

    def reconfigureDeckRuntime_(self, settings):
        self.reconfigured.append(settings)


def test_apply_success_adopts_settings_and_reconfigures_runtime__and_1_more() -> None:
    # --- scenario: apply_success_adopts_settings_and_reconfigures_runtime
    previous = DeckControlSettings()
    candidate = DeckControlSettings(True, ((0, DeckAction("open_agent_browser")),))
    controller = _Controller(previous)

    controller._deck_settings_save_generation = 1
    controller._deck_settings_save_in_flight = True
    apply_deck_settings_result(
        controller, DeckSettingsApplyResult(1, previous, candidate)
    )

    assert controller._deck_control_settings == candidate
    assert controller._deck_settings_save_in_flight is False
    assert controller.reconfigured == [candidate]

    # --- scenario: apply_failure_preserves_cached_settings_and_does_not_reconfigure
    previous = DeckControlSettings(True)
    controller = _Controller(previous)
    controller._deck_settings_save_generation = 1
    controller._deck_settings_save_in_flight = True

    apply_deck_settings_result(
        controller,
        DeckSettingsApplyResult(
            1,
            previous,
            DeckControlSettings(False),
            error="Deck settings changed. Reload before saving. Device actions remain paused.",
            paused_on_failure=True,
        ),
    )

    assert controller._deck_control_settings == previous
    assert controller._deck_settings_save_in_flight is False
    assert controller.reconfigured == []


def test_stale_result_does_not_replace_a_newer_save__and_1_more() -> None:
    # --- scenario: stale_result_does_not_replace_a_newer_save
    previous = DeckControlSettings()
    current = DeckControlSettings(True)
    controller = _Controller(current)
    controller._deck_settings_save_generation = 2
    controller._deck_settings_save_in_flight = True

    apply_deck_settings_result(
        controller,
        DeckSettingsApplyResult(1, previous, DeckControlSettings(False)),
    )

    assert controller._deck_control_settings == current
    assert controller._deck_settings_save_in_flight is True
    assert controller.reconfigured == []

    # --- scenario: termination_updates_the_cache_but_skips_the_restart
    previous = DeckControlSettings()
    candidate = DeckControlSettings(True)
    controller = _Controller(previous)
    controller._deck_settings_save_generation = 1
    controller._deck_settings_save_in_flight = True
    controller._runtime_termination_started = True

    apply_deck_settings_result(
        controller, DeckSettingsApplyResult(1, previous, candidate)
    )

    assert controller._deck_control_settings == candidate
    assert controller.reconfigured == []
