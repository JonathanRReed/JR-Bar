"""Native controller for explicit Creator Micro keymap setup."""

from __future__ import annotations

import threading
from collections.abc import Callable
from dataclasses import dataclass
from pathlib import Path

from AppKit import NSAlert, NSAlertFirstButtonReturn, NSButton, NSPopUpButton, NSSwitchButton, NSView

from .creator_micro_keymap import KeymapPlan, keymap_layers, plan_keymap


@dataclass(frozen=True, slots=True)
class SetupPreview:
    """A reviewed plan bound to the approved device identity."""

    approved_serial: str
    plan: KeymapPlan


@dataclass(frozen=True, slots=True)
class SetupResult:
    generation: object
    operation: str
    code: str
    preview: SetupPreview | None = None
    runtime_was_stopped: bool = False
    detail: str = ""


def _default_adapter_factory(approved_serial: str):
    from .creator_micro_adapter import CreatorMicro2Adapter
    from .creator_micro_hidapi import HidApiTransport

    transport = HidApiTransport(approved_serial=approved_serial)
    devices = transport.enumerate()
    if len(devices) != 1:
        raise OSError("approved Creator Micro 2 is unavailable")
    transport.enable_writes()
    return CreatorMicro2Adapter(transport, devices[0])


def _backup_path(approved_serial: str, backup_root: Path | None) -> Path:
    from .creator_micro_setup import device_backup_key
    from .integration_settings import default_integration_settings_path

    root = Path(backup_root) if backup_root is not None else default_integration_settings_path().parent
    return root / f"creator-micro-keymap-{device_backup_key(approved_serial)}.json"


def _current(target: object, generation: object) -> bool:
    return (
        getattr(target, "_creator_micro_setup_generation", None) is generation
        and getattr(target, "_deck_runtime_generation", None) is generation
        and not getattr(target, "_runtime_termination_started", False)
        and not getattr(target, "_deck_runtime_stopping", False)
    )


def _same_setup(target: object, generation: object) -> bool:
    return (
        getattr(target, "_creator_micro_setup_generation", None) is generation
        and not getattr(target, "_runtime_termination_started", False)
        and not getattr(target, "_deck_runtime_stopping", False)
    )


def _set_pending(target: object, pending: bool) -> None:
    pane = getattr(target, "deck_settings_pane", None)
    if pane is not None:
        pane.set_setup_pending(pending)


def _dispatch(target: object, result: SetupResult) -> None:
    if not _same_setup(target, result.generation):
        return
    target.performSelectorOnMainThread_withObject_waitUntilDone_(
        "applyCreatorMicroSetupResult:", result, False,
    )


def _validated_serial(settings_loader: Callable[[], object], expected_serial: str | None = None) -> tuple[str | None, str | None]:
    loaded = settings_loader()
    settings = loaded.settings
    serial = getattr(settings, "creator_micro_device_serial", None)
    if getattr(settings, "creator_micro_enabled", False) is not True or not isinstance(serial, str) or not serial.strip():
        return None, "connection_required"
    if expected_serial is not None and serial != expected_serial:
        return None, "approved_device_changed"
    return serial, None


def _start_operation(
    target: object,
    operation: str,
    *,
    preview: SetupPreview | None = None,
    settings_loader: Callable[[], object] | None = None,
    adapter_factory: Callable[[str], object] | None = None,
    setup_factory: Callable[..., object] | None = None,
    backup_root: Path | None = None,
) -> threading.Thread | None:
    if getattr(target, "_creator_micro_setup_busy", False):
        return None
    from .creator_micro_setup import CreatorMicroSetup
    from .integration_settings import load_integration_settings

    settings_loader = settings_loader or load_integration_settings
    adapter_factory = adapter_factory or _default_adapter_factory
    setup_factory = setup_factory or CreatorMicroSetup
    restart_owed = (
        getattr(target, "_jrbar_optional_integration_runtime", None) is None
        and getattr(target, "_deck_runtime_generation", None) is not None
    )
    generation = object()
    target._creator_micro_setup_generation = generation
    target._deck_runtime_generation = generation
    target._creator_micro_setup_busy = True
    _set_pending(target, True)

    lock = getattr(target, "_deck_runtime_restart_lock", None)
    if lock is None:
        lock = threading.Lock()
        target._deck_runtime_restart_lock = lock

    def run() -> None:
        stopped_runtime = restart_owed
        result = SetupResult(generation, operation, "setup_failed", runtime_was_stopped=stopped_runtime)
        try:
            with lock:
                if not _current(target, generation):
                    return
                serial, error = _validated_serial(
                    settings_loader,
                    preview.approved_serial if preview is not None else None,
                )
                if error is not None:
                    result = SetupResult(generation, operation, error, runtime_was_stopped=stopped_runtime)
                    return
                current_runtime = getattr(target, "_jrbar_optional_integration_runtime", None)
                if current_runtime is not None:
                    current_runtime.revoke_deck_input()
                    current_runtime.close()
                    if not current_runtime.wait_until_stopped(17.0):
                        result = SetupResult(generation, operation, "previous_owner_stopping")
                        return
                    if getattr(target, "_jrbar_optional_integration_runtime", None) is current_runtime:
                        target._jrbar_optional_integration_runtime = None
                # Setup also owns the gap before a queued normal runtime has
                # started. Cancelling its preview must resume that runtime.
                stopped_runtime = True
                if not _current(target, generation):
                    return
                adapter = adapter_factory(serial)
                try:
                    if not _current(target, generation):
                        return
                    receipt = adapter.connect()
                    if receipt.code != "connected":
                        result = SetupResult(generation, operation, receipt.code, runtime_was_stopped=stopped_runtime, detail=receipt.detail)
                        return
                    if not _current(target, generation):
                        return

                    def consent_is_current() -> bool:
                        if not _current(target, generation):
                            return False
                        try:
                            current_serial, current_error = _validated_serial(settings_loader, serial)
                        except Exception:
                            return False
                        return current_error is None and current_serial == serial

                    setup = setup_factory(
                        adapter,
                        serial,
                        _backup_path(serial, backup_root),
                        is_current=consent_is_current,
                    )
                    if operation == "inspect":
                        if not _current(target, generation):
                            return
                        plan = setup.inspect()
                        result = SetupResult(
                            generation,
                            operation,
                            "inspection_ready",
                            SetupPreview(serial, plan),
                            stopped_runtime,
                        )
                    elif operation == "apply":
                        receipt = setup.apply(preview.plan)
                        result = SetupResult(generation, operation, receipt.code, runtime_was_stopped=stopped_runtime, detail=receipt.detail)
                    else:
                        receipt = setup.restore()
                        result = SetupResult(generation, operation, receipt.code, runtime_was_stopped=stopped_runtime, detail=receipt.detail)
                finally:
                    try:
                        adapter.close()
                    except OSError:
                        pass
        except Exception as exc:
            result = SetupResult(generation, operation, getattr(exc, "code", "setup_failed"),
                                 runtime_was_stopped=stopped_runtime)
        finally:
            if _same_setup(target, generation):
                _dispatch(target, result)

    thread = threading.Thread(target=run, name=f"JRBarCreatorMicroSetup-{operation}", daemon=True)
    thread.start()
    return thread


def begin_creator_micro_inspection(target: object, **dependencies) -> threading.Thread | None:
    return _start_operation(target, "inspect", **dependencies)


def begin_creator_micro_apply(target: object, preview: SetupPreview, **dependencies) -> threading.Thread | None:
    if type(preview) is not SetupPreview:
        return None
    return _start_operation(target, "apply", preview=preview, **dependencies)


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
    if getattr(target, "_creator_micro_setup_busy", False):
        return None
    if not confirm():
        return None
    return _start_operation(target, "restore", **dependencies)


def _preview_text(plan: KeymapPlan) -> str:
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
    _set_pending(target, False)
    if getattr(target, "_deck_runtime_generation", None) is not result.generation:
        return

    pane = getattr(target, "deck_settings_pane", None)
    code = result.code
    messages = {
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
    if code != "inspection_ready":
        if getattr(result, "runtime_was_stopped", False) or getattr(
            target, "_creator_micro_setup_runtime_needs_restart", False
        ):
            target._creator_micro_setup_runtime_needs_restart = False
            target.reconfigureDeckRuntime_(None)
        if pane is not None:
            pane.set_status(messages.get(code, f"Creator Micro 2: {code.replace('_', ' ')}."))
        if code == "keymap_verified":
            from .deck_control_center import open_control_center
            open_control_center(target, input_check=True)
        return

    preview = result.preview
    if type(preview) is not SetupPreview:
        if getattr(result, "runtime_was_stopped", False):
            target.reconfigureDeckRuntime_(None)
        if pane is not None:
            pane.set_status("Creator Micro 2 inspection did not return a valid preview.")
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
        except (ValueError, IndexError) as exc:
            if result.runtime_was_stopped:
                target.reconfigureDeckRuntime_(None)
            if pane is not None:
                pane.set_status(str(exc))
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
        if pane is not None:
            pane.set_status("No keymap was written.")


__all__ = [
    "SetupPreview",
    "SetupResult",
    "apply_creator_micro_setup_result",
    "begin_creator_micro_apply",
    "begin_creator_micro_inspection",
    "begin_creator_micro_restore",
]
