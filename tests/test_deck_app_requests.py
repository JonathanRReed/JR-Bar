"""A Creator Micro key's window and ask requests go to the app.

The daemon has no windows of its own. The deck's Agent Browser, Usage and
Control Center keys ask the connected app for its Overview, Usage and
Control Center windows (`open_window {window}`), and its ask key asks for
the waiting ask on the panel (`reveal_ask`). The app runs both the way it
runs a `jrbar://` link; revealing an ask never answers it. With no app
connected the key's receipt says so.
"""

from __future__ import annotations

from types import SimpleNamespace

from jrbar.deck_actions import DeckAction
from jrbar.deck_actions_macos import DeckActionReceipt, MacDeckActionExecutor
from jrbar.deck_control_center import APP_WINDOW_FOR_ACTION, deck_executor


class _Target:
    def __init__(self, *, connected: bool) -> None:
        self.connected = connected
        self.requests: list[tuple[str, dict]] = []

    def _core_request_app(self, kind: str, **fields) -> bool:
        self.requests.append((kind, fields))
        return self.connected


def test_window_keys_ask_the_app_for_its_windows__and_1_more() -> None:
    # --- scenario: window_keys_ask_the_app_for_its_windows
    target = _Target(connected=True)
    executor = deck_executor(target)

    receipts = {
        kind: executor.execute(DeckAction(kind=kind))
        for kind in ("open_agent_browser", "open_usage", "open_control_center")
    }

    assert target.requests == [
        ("open_window", {"window": "overview"}),
        ("open_window", {"window": "usage"}),
        ("open_window", {"window": "control-center"}),
    ]
    assert receipts == {
        "open_agent_browser": DeckActionReceipt("opened_agent_browser", True),
        "open_usage": DeckActionReceipt("opened_usage", True),
        "open_control_center": DeckActionReceipt("opened_control_center", True),
    }
    # Link names the app's AppCommand.AppWindow knows.
    assert set(APP_WINDOW_FOR_ACTION.values()) <= {"overview", "usage", "control-center"}

    # --- scenario: the_ask_key_asks_for_the_waiting_ask
    target = _Target(connected=True)

    receipt = deck_executor(target).execute(DeckAction(kind="reveal_current_ask"))

    assert target.requests == [("reveal_ask", {})]
    assert receipt == DeckActionReceipt("revealed_current_ask", True)


def test_with_no_app_connected_the_receipt_says_so__and_1_more() -> None:
    # --- scenario: with_no_app_connected_the_receipt_says_so
    target = _Target(connected=False)
    executor = deck_executor(target)

    for kind in ("open_agent_browser", "open_usage", "open_control_center", "reveal_current_ask"):
        assert executor.execute(DeckAction(kind=kind)) == DeckActionReceipt("app_not_connected", False)

    # --- scenario: a_target_without_the_hook_is_not_connected_either
    receipt = deck_executor(SimpleNamespace()).execute(DeckAction(kind="open_usage"))

    assert receipt == DeckActionReceipt("app_not_connected", False)


def test_a_callback_may_name_its_own_receipt() -> None:
    refused = DeckActionReceipt("app_not_connected", False)
    executor = MacDeckActionExecutor(open_usage=lambda: refused, reveal_current_ask=lambda: None)

    assert executor.execute(DeckAction(kind="open_usage")) is refused
    assert executor.execute(DeckAction(kind="reveal_current_ask")) == DeckActionReceipt(
        "revealed_current_ask", True
    )


def test_the_daemon_publishes_a_request_only_to_a_connected_app() -> None:
    from jrbar import core_runtime

    request = core_runtime.build_headless_controller_class()._core_request_app
    request = getattr(request, "callable", request)
    published: list[tuple[str, dict]] = []

    def controller(clients: int, server: bool = True) -> SimpleNamespace:
        core = SimpleNamespace(client_count=lambda: clients) if server else None
        return SimpleNamespace(
            _core=core,
            _core_publish_event=lambda kind, **fields: published.append((kind, fields)),
        )

    assert request(controller(1), "open_window", window="usage") is True
    assert request(controller(0), "open_window", window="usage") is False
    assert request(controller(0, server=False), "reveal_ask") is False
    assert published == [("open_window", {"window": "usage"})]
