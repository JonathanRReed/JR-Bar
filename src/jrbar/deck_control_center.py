"""Compose the session workspace using existing navigation and observation owners."""
from __future__ import annotations

import threading

from .deck_actions_macos import DeckActionReceipt, MacDeckActionExecutor
from .deck_board_store import DeckBoardStore
from .deck_session_board import DeckSessionBoard

_BOARD_LOCK = threading.RLock()


def ensure_deck_board(target) -> DeckSessionBoard:
    with _BOARD_LOCK:
        board = getattr(target, "_deck_session_board", None)
        if board is None:
            board = DeckSessionBoard()
            target._deck_session_board = board
            target._deck_board_store = DeckBoardStore()
            target._deck_board_ready = False

            def load() -> None:
                try:
                    target._deck_board_store.load(board)
                except (OSError, ValueError):
                    target._deck_board_store.error = "Saved session slots could not be loaded; the file was preserved."
                finally:
                    target._deck_board_ready = True

            threading.Thread(target=load, name="JRBarDeckSlotRestore", daemon=True).start()
        return board


def refresh_deck_board(target):
    board = ensure_deck_board(target)
    if not getattr(target, "_deck_board_ready", False):
        return board.snapshot()
    monitor = getattr(target, "monitor", None)
    current = getattr(monitor, "current_statuses_by_key", None)
    if callable(current):
        statuses = tuple(current().values())
    else:
        statuses = tuple(getattr(getattr(target, "last_snapshot", None), "statuses", ()))
    from .deck_session_board import session_identity
    from .navigation_policy import NavigationResolutionKind, resolve_navigation
    candidates = getattr(target, "navigation_candidates_by_work_key", {})
    navigable = set()
    for status in statuses[:520]:
        if getattr(status, "work_key", None) is None:
            continue
        resolution = resolve_navigation(status.work_key, "open:primary", candidates.get(status.work_key, ()))
        if resolution.kind is NavigationResolutionKind.READY:
            navigable.add(session_identity(status))
    board.update(statuses, navigation_keys=navigable)
    target._deck_board_store.submit(board)
    return board.snapshot()


def reveal_deck_session(target, identity: str, revision: int | None) -> DeckActionReceipt:
    if getattr(target, "_runtime_termination_started", False):
        return DeckActionReceipt("shutting_down", False)
    board = ensure_deck_board(target)
    status = board.navigation_target(identity, revision)
    state = getattr(target, "current_operator_state", None)
    perform = getattr(target, "performAgentBrowserPayload_", None)
    if status is None or state is None or not callable(perform):
        return DeckActionReceipt("session_target_changed", False)
    # This path reuses the canonical capability check, source generation check
    # and allowlisted navigation resolver. It does not call the legacy fallback
    # that might start a new terminal merely from a display name or working path.
    from .agent_browser_window import AgentBrowserActionPayload
    from .navigation_policy import OperatorActionKind
    success = bool(perform(AgentBrowserActionPayload(status.work_key, state.generation, OperatorActionKind.OPEN)))
    return DeckActionReceipt("navigation_requested" if success else "navigation_unavailable", success)


def revoke_deck_context(target) -> None:
    """Invalidate queued input and automation before changing its meaning."""
    runner = getattr(target, "_deck_automation_runner", None)
    if runner is not None:
        target._deck_automation_runner = None
        runner.close()
    runtime = getattr(target, "_jrbar_optional_integration_runtime", None)
    dispatch = getattr(runtime, "_deck_dispatch", None)
    if dispatch is not None:
        dispatch.reset_connection()


def change_deck_bank(target, delta: int) -> None:
    board = ensure_deck_board(target)
    revoke_deck_context(target)
    board.change_bank(delta)
    target._deck_board_store.submit(board)
    publish_deck_frame(target)


def publish_deck_frame(target) -> None:
    runtime = getattr(target, "_jrbar_optional_integration_runtime", None)
    snapshot = getattr(target, "last_snapshot", None)
    if runtime is not None and snapshot is not None:
        runtime.publish_creator_output(target.display_aggregate_mode(snapshot))
    window = getattr(target, "_deck_control_center_window", None)
    if window is not None:
        window.refresh_(None)


def open_control_center(target, *, input_check: bool = False) -> None:
    from .deck_control_center_window import DeckControlCenterWindow
    if getattr(target, "_runtime_termination_started", False):
        return
    ensure_deck_board(target)
    window = getattr(target, "_deck_control_center_window", None)
    if window is None:
        window = DeckControlCenterWindow.alloc().initWithTarget_(target)
        target._deck_control_center_window = window
    if input_check:
        runner = getattr(target, "_deck_automation_runner", None)
        if runner is not None:
            target._deck_automation_runner = None
            runner.close()
        target._deck_input_check_active = True
        runtime = getattr(target, "_jrbar_optional_integration_runtime", None)
        dispatch = getattr(runtime, "_deck_dispatch", None)
        if dispatch is not None:
            dispatch.reset_connection()
    window.show()


def deck_executor(target) -> MacDeckActionExecutor:
    def submit_shortcut(name):
        from .deck_automation import DeckAutomationRunner
        runner = getattr(target, "_deck_automation_runner", None)
        if runner is None:
            def completed(receipt):
                if (not getattr(target, "_runtime_termination_started", False)
                        and getattr(target, "_deck_automation_runner", None) is runner):
                    target.performSelectorOnMainThread_withObject_waitUntilDone_(
                        "applyDeckAutomationResult:", receipt, False)
            runner = DeckAutomationRunner(completed)
            target._deck_automation_runner = runner
        return runner.submit(name)
    return MacDeckActionExecutor(
        reveal_current_ask=lambda: target.performRevealCurrentAsk_(None),
        open_agent_browser=lambda: target.openAgentBrowser_(None),
        open_usage=lambda: target.openProviderUsageCenter_(None),
        open_control_center=lambda: open_control_center(target),
        next_bank=lambda: change_deck_bank(target, 1),
        previous_bank=lambda: change_deck_bank(target, -1),
        session_revealer=lambda identity, revision: reveal_deck_session(target, identity, revision),
        shortcut_runner=submit_shortcut,
    )
