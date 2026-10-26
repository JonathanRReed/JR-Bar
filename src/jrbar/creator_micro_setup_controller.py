"""Native controller for explicit Creator Micro keymap setup."""

from __future__ import annotations

import threading
from collections.abc import Callable

from AppKit import NSAlert, NSAlertFirstButtonReturn, NSButton, NSPopUpButton, NSSwitchButton, NSView

from .creator_micro_keymap import KeymapPlan, keymap_layers, plan_keymap
from .creator_micro_setup_runtime import (
    SetupPreview,
    SetupResult,
    begin_creator_micro_apply,
    begin_creator_micro_inspection,
)
from .creator_micro_setup_runtime import (
    begin_creator_micro_restore as _begin_creator_micro_restore,
)


def _confirm_restore() -> bool:
    alert = NSAlert.alloc().init()
    alert.setMessageText_("Restore the Creator Micro 2 keymap?")
    alert.setInformativeText_(
        "Close Input and other device controllers first. JR-Bar restores the first private backup only from "
        "a recognized applied keymap or a verifiable interrupted JR-Bar transfer. Later unrelated edits are not overwritten."
    )
    alert.addButtonWithTitle_("Restore keymap")
    alert.addButtonWithTitle_("Cancel")
    return alert.runModal() == NSAlertFirstButtonReturn


def begin_creator_micro_restore(
    target: object,
    *,
    confirm: Callable[[], bool] = _confirm_restore,
    **dependencies,
) -> threading.Thread | None:
    return _begin_creator_micro_restore(target, confirm=confirm, **dependencies)


def _preview_text(plan: KeymapPlan) -> str:
    # One text for the review alert here and the daemon's deck_plan_keymap.
    from .core_deck import preview_text

    return preview_text(plan)


def apply_creator_micro_setup_result(
    target: object,
    result: object,
    *,
    alert_factory: Callable[[], object] | None = None,
) -> None:
    if (
        getattr(result, "generation", None) is not getattr(target, "_creator_micro_setup_generation", None)
        or getattr(target, "_runtime_termination_started", False)
        or getattr(target, "_deck_runtime_stopping", False)
    ):
        return
    target._creator_micro_setup_busy = False
    if getattr(target, "_deck_runtime_generation", None) is not result.generation:
        return

    code = result.code
    if code != "inspection_ready":
        if getattr(result, "runtime_was_stopped", False) or getattr(
            target, "_creator_micro_setup_runtime_needs_restart", False
        ):
            target._creator_micro_setup_runtime_needs_restart = False
            target.reconfigureDeckRuntime_(None)
        return

    preview = result.preview
    if type(preview) is not SetupPreview:
        if getattr(result, "runtime_was_stopped", False):
            target.reconfigureDeckRuntime_(None)
        return
    if alert_factory is None:
        choices = keymap_layers(preview.plan.original_json)
        selection = NSAlert.alloc().init()
        selection.setMessageText_("Choose the JR-Bar device layer")
        selection.setInformativeText_(
            "Close Input and other device controllers before continuing. Only the chosen layer is edited; "
            "macro definitions and other layers are preserved. Review the exact changes on the next screen.")
        accessory = NSView.alloc().initWithFrame_(((0, 0), (430, 76)))
        popup = NSPopUpButton.alloc().initWithFrame_pullsDown_(((0, 42), (430, 28)), False)
        selected = 0
        for index, (profile, layer, label) in enumerate(choices):
            popup.addItemWithTitle_(label)
            if (profile, layer) == (preview.plan.profile_index, preview.plan.layer_index):
                selected = index
        popup.selectItemAtIndex_(selected)
        popup.setAccessibilityLabel_("Profile and layer to configure")
        auxiliary = NSButton.alloc().initWithFrame_(((0, 6), (430, 28)))
        auxiliary.setButtonType_(NSSwitchButton)
        auxiliary.setTitle_("Also configure supported dial and joystick mappings")
        auxiliary.setState_(0)
        accessory.addSubview_(popup)
        accessory.addSubview_(auxiliary)
        selection.setAccessoryView_(accessory)
        selection.addButtonWithTitle_("Review changes")
        selection.addButtonWithTitle_("Cancel")
        if selection.runModal() != NSAlertFirstButtonReturn:
            if result.runtime_was_stopped:
                target.reconfigureDeckRuntime_(None)
            return
        try:
            profile, layer, _ = choices[int(popup.indexOfSelectedItem())]
            plan = plan_keymap(preview.plan.original_json,
                               {"profile_index": preview.plan.observed_profile,
                                "layer_index": preview.plan.observed_layer + 1},
                               profile_index=profile, layer_index=layer, include_auxiliary=bool(auxiliary.state()))
            preview = SetupPreview(preview.approved_serial, plan)
        except (ValueError, IndexError):
            if result.runtime_was_stopped:
                target.reconfigureDeckRuntime_(None)
            return
    alert = alert_factory() if alert_factory is not None else NSAlert.alloc().init()
    alert.setMessageText_("Review Creator Micro 2 key changes")
    alert.setInformativeText_(_preview_text(preview.plan))
    alert.addButtonWithTitle_("Apply keymap")
    alert.addButtonWithTitle_("Cancel")
    if alert.runModal() == NSAlertFirstButtonReturn:
        target._creator_micro_setup_runtime_needs_restart = bool(result.runtime_was_stopped)
        target._deck_control_labels = preview.plan.control_labels
        target.beginCreatorMicroSetupApply_(preview)
    else:
        if getattr(result, "runtime_was_stopped", False):
            target.reconfigureDeckRuntime_(None)


__all__ = [
    "SetupPreview",
    "SetupResult",
    "apply_creator_micro_setup_result",
    "begin_creator_micro_apply",
    "begin_creator_micro_inspection",
    "begin_creator_micro_restore",
]
