"""AppKit coordinator for explicit device actions, using existing JR-Bar routes."""

from __future__ import annotations

import threading

from .deck_control_center import deck_executor
from .deck_input_dispatch import DeckInputBatch


def apply_deck_input(target, batch: object) -> None:
    if type(batch) is not DeckInputBatch or getattr(target, "_runtime_termination_started", False):
        return
    executor = deck_executor(target)
    receipts = batch.owner.deliver(batch, executor)
    if not receipts:
        return
    target._deck_action_receipt = receipts[-1]
    if getattr(target, "current_settings_pane", None) == "devices":
        code = receipts[-1].code
        message = {
            "accessibility_not_trusted": "Allow JR-Bar in macOS Accessibility settings to use app shortcuts.",
            "target_not_frontmost": "Switch to the mapped app before using its shortcut.",
            "target_not_running": "Open the mapped app before using its shortcut.",
            "app_not_found": "The mapped app is not installed. Choose it again in Devices settings.",
        }.get(code, f"Device action: {code.replace('_', ' ')}.")
        target.set_settings_message(message)


def cycle_deck_scope(target, delta: int) -> None:
    """Step the board scope through automatic plus the configured providers."""
    from .deck_control_center import ensure_deck_board, publish_deck_frame, revoke_deck_context
    board = ensure_deck_board(target)
    revoke_deck_context(target)
    controls = getattr(target, "_deck_control_settings", None)
    scopes = controls.all_scopes() if controls is not None else ()
    if not board.cycle_scope(delta, scopes):
        return
    store = getattr(target, "_deck_board_store", None)
    if store is not None:
        store.submit(board)
    publish_deck_frame(target)
    publish = getattr(target, "_core_publish_state_soon", None)
    if callable(publish):
        publish()


def refresh_deck_scope(target) -> None:
    """Re-resolve the board scope after the layer map or live layer changed."""
    from .deck_control_center import ensure_deck_board, publish_deck_frame, revoke_deck_context
    controls = getattr(target, "_deck_control_settings", None)
    layer = getattr(target, "_deck_active_layer", None)
    scope = controls.scope_for_layer(layer) if controls is not None else None
    board = ensure_deck_board(target)
    if not board.set_scope(scope):
        return
    revoke_deck_context(target)
    store = getattr(target, "_deck_board_store", None)
    if store is not None:
        store.submit(board)
    publish_deck_frame(target)


def apply_deck_layer(target, payload) -> None:
    """A ``device.status`` answer: the pad's own layer/profile selection.

    Input reports carry no layer information, so the output owner polls the
    status RPC and lands the answer here; the layer map turns it into the
    board scope.
    """
    if getattr(target, "_runtime_termination_started", False) or type(payload) is not dict:
        return
    layer = payload.get("layer")
    profile = payload.get("profile")
    layer = layer if type(layer) is int else None
    profile = profile if type(profile) is int else None
    if (layer == getattr(target, "_deck_active_layer", None)
            and profile == getattr(target, "_deck_active_profile", None)):
        return
    target._deck_active_layer = layer
    target._deck_active_profile = profile
    refresh_deck_scope(target)
    publish = getattr(target, "_core_publish_state_soon", None)
    if callable(publish):
        publish()


def reconfigure_deck_runtime(target, *, runtime_factory=None) -> threading.Thread:
    """Revoke input now; replace a stopped HID owner from a background worker."""
    from .optional_integration_runtime import CreatorMicroOutputReceipt, start_optional_integration_runtime

    factory = runtime_factory or start_optional_integration_runtime
    generation = object()
    target._deck_runtime_generation = generation
    lifecycle = _lifecycle_lock(target)
    lock = getattr(target, "_deck_runtime_restart_lock", None)
    if lock is None:
        lock = threading.Lock()
        target._deck_runtime_restart_lock = lock
    old = getattr(target, "_jrbar_optional_integration_runtime", None)
    if old is not None:
        old.revoke_deck_input()

    def restart() -> None:
        with lock:
            if target._deck_runtime_generation is not generation:
                return
            current = getattr(target, "_jrbar_optional_integration_runtime", None)
            if current is not None:
                current.close()
                if not current.wait_until_stopped(17.0):
                    target.performSelectorOnMainThread_withObject_waitUntilDone_(
                        "applyCreatorMicroOutputReceipt:",
                        CreatorMicroOutputReceipt(False, "previous_owner_stopping"), False,
                    )
                    return
            with lifecycle:
                if (
                    target._deck_runtime_generation is not generation
                    or getattr(target, "_runtime_termination_started", False)
                    or getattr(target, "_deck_runtime_stopping", False)
                ):
                    return
                target._jrbar_optional_integration_runtime = factory(target)

    thread = threading.Thread(target=restart, name="JRBarDeckReconfigure", daemon=True)
    thread.start()
    return thread


def _lifecycle_lock(target):
    lock = getattr(target, "_deck_runtime_lifecycle_lock", None)
    if lock is None:
        lock = threading.RLock()
        target._deck_runtime_lifecycle_lock = lock
    return lock


def stop_deck_runtime_reconfiguration(target) -> None:
    store = getattr(target, "_deck_board_store", None)
    if store is not None:
        store.close()
    runner = getattr(target, "_deck_automation_runner", None)
    if runner is not None:
        runner.close()
    window = getattr(target, "_deck_control_center_window", None)
    if window is not None:
        window.shutdown()
    with _lifecycle_lock(target):
        target._deck_runtime_stopping = True
        target._deck_runtime_generation = object()
        runtime = getattr(target, "_jrbar_optional_integration_runtime", None)
    if runtime is not None:
        runtime.revoke_deck_input()
