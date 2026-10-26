from types import SimpleNamespace

import pytest

from jrbar import core_environment as environment
from jrbar.core_server import CommandError


def test_workspace_reports_preserve_sleep_edges_and_accessibility_policy():
    edges = []
    target = SimpleNamespace(
        dndWorkspaceDidWake_=lambda _: edges.append("wake"),
        dndWorkspaceWillSleep_=lambda _: edges.append("sleep"),
        _apply_accessibility_display_preferences=lambda value: edges.append(value),
    )
    flags = {key: False for key in environment.AccessibilityDisplayPreferences.__dataclass_fields__}
    flags["reduce_motion"] = True
    environment.report(target, {"event": "sleep", "accessibility": flags})
    environment.report(target, {"event": "wake"})
    assert edges[0].reduce_motion is True
    assert edges[1:] == ["sleep", "wake"]
    with pytest.raises(CommandError):
        environment.report(target, {"event": "wake", "accessibility": {"reduce_motion": "true"}})
    assert edges[1:] == ["sleep", "wake"]


@pytest.mark.parametrize("old_client", [False, True], ids=["no-app", "old-app"])
def test_native_fallback_keeps_real_preferences_and_wake_reassertion(monkeypatch, old_client):
    from jrbar import daemon_loop
    from jrbar.core_server import CoreServer, _Client
    from jrbar.daemon_controller import StatusBarController

    server = CoreServer(dispatch=lambda *_: {}, initial_documents=lambda: [])
    if old_client:
        server._clients = [_Client(SimpleNamespace(sendall=lambda _: None), 1)]
    flags = environment.AccessibilityDisplayPreferences()
    led = SimpleNamespace(last_attempt_monotonic=42.0)
    edges = []
    controller = SimpleNamespace(
        agent_led_controllers_by_device={"synthetic": led},
        _refresh_dnd_environment=edges.append,
        refresh_=lambda _: edges.append("refresh"),
        _apply_accessibility_display_preferences=lambda value: edges.append(value),
    )
    class Native:
        def __init__(self, target):
            self.target = target
            self.closed = False
            target._apply_accessibility_display_preferences(flags)
        def poll(self):
            StatusBarController.dndWorkspaceDidWake_(self.target, None)
        def close(self):
            self.closed = True

    monkeypatch.setattr(daemon_loop, "_application", daemon_loop.DaemonLoop())
    now = [0.0]
    fallback = environment.EnvironmentFallback(controller, clock=lambda: now[0], factory=Native)
    # Connecting an old client is not an environment capability report.
    fallback.tick(server.environment_reporter_connected)
    assert fallback.native is None
    now[0] = 2.0
    fallback.tick(server.environment_reporter_connected)
    assert edges == [flags]
    assert not edges[0].reduce_motion
    fallback.poll_(None)
    assert led.last_attempt_monotonic == 0.0
    assert edges[1:] == ["handle_wake", "refresh"]
    native = fallback.native
    fallback.app_reported()
    assert native.closed and fallback.native is None
    fallback.tick(True)
    assert fallback.native is None
    fallback.tick(False)  # reporting socket disconnected
    assert fallback.native is not None
    fallback.close()


def test_only_a_successful_report_on_a_live_socket_replaces_native_observation():
    import json

    from jrbar.core_server import CoreServer, _Client

    target = SimpleNamespace(_apply_accessibility_display_preferences=lambda _: None)
    server = CoreServer(dispatch=lambda name, args: environment.report(target, args) if name == "environment" else {},
                        initial_documents=lambda: [])
    client = _Client(SimpleNamespace(sendall=lambda _: None), 1)
    server._clients = [client]
    assert not server.environment_reporter_connected
    server._handle_line(client, json.dumps({"t": "command", "id": "old", "name": "ping"}).encode())
    assert not server.environment_reporter_connected
    server._handle_line(client, json.dumps({"t": "command", "id": "invalid", "name": "environment",
                        "args": {"accessibility": {"reduce_motion": "false"}}}).encode())
    assert not server.environment_reporter_connected
    server._handle_line(client, json.dumps({"t": "command", "id": "new", "name": "environment",
                        "args": {"accessibility": {key: False for key in environment.AccessibilityDisplayPreferences.__dataclass_fields__}}}).encode())
    assert server.environment_reporter_connected
    client.alive = False
    assert not server.environment_reporter_connected


def test_a_capable_app_reporting_during_startup_avoids_native_loading(monkeypatch):
    from jrbar import daemon_loop

    monkeypatch.setattr(daemon_loop, "_application", daemon_loop.DaemonLoop())
    def forbidden(_):
        raise AssertionError("a capable app already supplies native readings")
    target = SimpleNamespace(_apply_accessibility_display_preferences=lambda _: None)
    fallback = environment.EnvironmentFallback(target, factory=forbidden, clock=lambda: 0.0, grace=0)
    target._core_environment_fallback = fallback
    environment.report(target, {"accessibility": {
        key: False for key in environment.AccessibilityDisplayPreferences.__dataclass_fields__}})
    fallback.tick(True)
    assert fallback.native is None
