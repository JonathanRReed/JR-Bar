from __future__ import annotations

from types import SimpleNamespace

from jrbar.deck_status_bar import install_deck_status_bar


class _BaseController:
    pass


Controller = install_deck_status_bar(_BaseController)


def test_the_controller_keeps_the_latest_creator_micro_output_receipt() -> None:
    controller = Controller()

    controller.applyCreatorMicroOutputReceipt_(SimpleNamespace(reason="device_conflict"))
    assert controller._creator_micro_output_receipt.reason == "device_conflict"

    controller.applyCreatorMicroOutputReceipt_(SimpleNamespace(reason="ready"))
    assert controller._creator_micro_output_receipt.reason == "ready"


def test_the_deck_host_answers_the_selectors_the_daemon_dispatches_and_no_window_action() -> None:
    selectors = {
        name for name in vars(Controller) if name.endswith("_") and not name.startswith("_")
    }

    assert {
        "applyCreatorMicroOutputReceipt_",
        "applyCreatorMicroSettings_",
        "applyCreatorMicroSetupResult_",
        "applyDeckAutomationResult_",
        "applyDeckInput_",
        "applyDeckLayer_",
        "applyDeckSettingsResult_",
        "beginCreatorMicroSetupApply_",
        "reconfigureDeckRuntime_",
    } == selectors
