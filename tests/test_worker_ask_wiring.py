"""The daemon hands the hook ingress its live sub-agent ask setting."""

from __future__ import annotations

from dataclasses import replace
from types import SimpleNamespace

import pytest

from jrbar.settings import AgentMonitorSettings


def test_the_ingress_reads_the_live_sub_agent_ask_setting(monkeypatch) -> None:
    try:
        from jrbar import status_bar_legacy
    except SystemExit as exit_:
        pytest.skip(str(exit_))

    built: list[dict] = []

    class _Service:
        def __init__(self, **kwargs) -> None:
            built.append(kwargs)

        def start(self):
            return "socket"

    monkeypatch.setattr(status_bar_legacy, "HookIngressService", _Service)
    monkeypatch.setattr(
        status_bar_legacy,
        "AppOwnedHookIngressProcessor",
        lambda *args, **kwargs: object(),
    )
    controller = SimpleNamespace(
        settings=AgentMonitorSettings(),
        hook_ingress_service=None,
        stop_hook_ingress=lambda: None,
        handle_hook_event_message=lambda *args: None,
        handle_appended_hook_line=lambda *args: None,
        resident_hook_deduplicators=lambda: None,
        _record_hook_ingress_receipt=lambda receipt: None,
    )

    status_bar_legacy.StatusBarController.start_hook_ingress(controller)

    reader = built[0]["subagent_asks_alert"]
    assert reader() is False
    # The reader follows the settings the controller holds now, not the ones
    # it held when the service was built.
    controller.settings = replace(controller.settings, subagent_asks_alert=True)
    assert reader() is True
