"""Thin native selector host for the Control Center deck callbacks."""

from __future__ import annotations


def install_deck_status_bar(base):
    class JRDeckStatusBarController(base):
        def applyCreatorMicroOutputReceipt_(self, receipt) -> None:
            self._creator_micro_output_receipt = receipt

        def applyCreatorMicroSettings_(self, payload) -> None:
            from .creator_micro_settings import apply_creator_micro_settings

            apply_creator_micro_settings(self, payload)

        def applyDeckInput_(self, payload) -> None:
            from .deck_controller import apply_deck_input

            apply_deck_input(self, payload)

        def applyDeckLayer_(self, payload) -> None:
            from .deck_controller import apply_deck_layer

            apply_deck_layer(self, payload)

        def applyDeckAutomationResult_(self, receipt) -> None:
            if not getattr(self, "_runtime_termination_started", False):
                self._deck_action_receipt = receipt

        def applyDeckSettingsResult_(self, payload) -> None:
            from .deck_settings_controller import apply_deck_settings_result

            apply_deck_settings_result(self, payload)

        def reconfigureDeckRuntime_(self, _sender) -> None:
            from .deck_controller import reconfigure_deck_runtime

            reconfigure_deck_runtime(self)

        def beginCreatorMicroSetupApply_(self, preview) -> None:
            from .creator_micro_setup_controller import begin_creator_micro_apply

            begin_creator_micro_apply(self, preview)

        def applyCreatorMicroSetupResult_(self, result) -> None:
            from .creator_micro_setup_controller import apply_creator_micro_setup_result

            apply_creator_micro_setup_result(self, result)

    return JRDeckStatusBarController
