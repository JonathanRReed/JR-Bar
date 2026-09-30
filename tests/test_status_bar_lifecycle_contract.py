from __future__ import annotations

import ast
from contextlib import nullcontext
from dataclasses import replace
from pathlib import Path
from types import SimpleNamespace
from unittest.mock import MagicMock

import pytest

from jrbar import status_bar
from jrbar.announcer_stack import empty_announcer_stack_state

ROOT = Path(__file__).resolve().parents[1]
STATUS_BAR_LEGACY = ROOT / "src" / "jrbar" / "status_bar_legacy.py"


@pytest.fixture
def controller(monkeypatch: pytest.MonkeyPatch, tmp_path):
    monkeypatch.setattr(
        status_bar,
        "default_settings_path",
        lambda: tmp_path / "settings.json",
    )
    monkeypatch.setattr(
        status_bar,
        "default_latest_state_path",
        lambda: tmp_path / "latest.json",
    )
    monkeypatch.setattr(
        status_bar,
        "default_activity_ledger_path",
        lambda: tmp_path / "activity-ledger.json",
    )
    monkeypatch.setattr(status_bar, "discover_devices", lambda: [])
    monkeypatch.setattr(
        status_bar.focus_sync,
        "active_focus_mode_identifiers",
        lambda: [],
    )
    monkeypatch.setattr(
        status_bar,
        "runtime_render_environment",
        lambda *, visible, display_asleep=False, process_info=None: SimpleNamespace(
            visible=visible,
            display_asleep=display_asleep,
            process_info=process_info,
        ),
    )
    yield status_bar.StatusBarController.alloc().init(), status_bar


def _prepare_terminate_controller(controller, monkeypatch):
    controller.notification_client = SimpleNamespace(
        set_delegate=MagicMock(name="set_delegate"),
        close=MagicMock(name="close"),
    )
    controller._os_poll_worker = SimpleNamespace(
        cancel_generation=MagicMock(name="cancel_generation")
    )
    controller._runtime_timer_registry = SimpleNamespace(
        invalidate_all=MagicMock(name="invalidate_all")
    )
    controller._runtime_worker_registry = SimpleNamespace(
        close_all=MagicMock(name="close_all")
    )
    controller._usage_refresh_workers = SimpleNamespace(
        close_all=MagicMock(
            name="close_all_usage_refresh_workers",
            return_value=True,
        ),
    )
    controller._persistence_writer = SimpleNamespace(
        snapshot=lambda: SimpleNamespace(accepting=False),
        close=MagicMock(name="close", return_value=True),
    )
    controller._capacity_history_lock = nullcontext()
    controller._capacity_history_store = None
    controller._capacity_history_generation = 0
    controller._installed_agent_inventory_generation = 0
    controller._runtime_preview_fire_at = []
    controller.monitor = None
    controller.virtual_status_device = SimpleNamespace(
        terminate=MagicMock(name="terminate")
    )
    controller.closed_lid_awake = SimpleNamespace(
        release=MagicMock(name="release")
    )
    controller.keep_awake = SimpleNamespace(release=MagicMock(name="release"))
    controller.stop_remote_peer_timer = MagicMock(name="stop_remote_peer_timer")
    controller.release_preview_engines = MagicMock(name="release_preview_engines")
    controller.publish_local_ledger_now = MagicMock(name="publish_local_ledger_now")
    controller.stop_cloud_ingest_server = MagicMock(name="stop_cloud_ingest_server")
    controller.stop_hook_ingress = MagicMock(name="stop_hook_ingress")
    controller.stop_event_server = MagicMock(name="stop_event_server")
    controller._remove_accessibility_display_observer = MagicMock(
        name="_remove_accessibility_display_observer"
    )
    controller._set_lid_observation_active = MagicMock(
        name="_set_lid_observation_active"
    )
    controller._set_display_environment_active = MagicMock(
        name="_set_display_environment_active"
    )
    controller._set_calendar_observation_active = MagicMock(
        name="_set_calendar_observation_active"
    )
    controller._set_reminders_observation_active = MagicMock(
        name="_set_reminders_observation_active"
    )


def test_application_will_terminate_only_closes_once_when_called_twice(
    controller,
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    target, _status_bar = controller
    _prepare_terminate_controller(target, monkeypatch)
    target._announcer_stack_state = replace(
        empty_announcer_stack_state(),
        generation=4,
    )
    target._announcer_status_routes = {"request:one": object()}
    target._announcer_stack_context = (object(), (), ())
    state_at_device_close = []
    target.virtual_status_device.terminate.side_effect = lambda: state_at_device_close.append(
        target._announcer_stack_state.generation
    )

    target.applicationWillTerminate_(None)
    target.applicationWillTerminate_(None)

    target.notification_client.set_delegate.assert_called_once_with(None)
    target.notification_client.close.assert_called_once_with(timeout_seconds=1.0)
    target._os_poll_worker.cancel_generation.assert_called_once_with(0)
    target._remove_accessibility_display_observer.assert_called_once_with()
    target.virtual_status_device.terminate.assert_called_once_with()
    assert state_at_device_close == [4]
    assert target._announcer_stack_state == empty_announcer_stack_state()
    assert target._announcer_status_routes == {}
    assert target._announcer_stack_context is None
    target._set_lid_observation_active.assert_called_once_with(False)
    target._set_display_environment_active.assert_called_once_with(False)
    target._set_calendar_observation_active.assert_called_once_with(False)
    target._set_reminders_observation_active.assert_called_once_with(False)
    target._runtime_timer_registry.invalidate_all.assert_called_once_with()
    target._runtime_worker_registry.close_all.assert_called_once_with(
        timeout_seconds=1.0
    )
    target._usage_refresh_workers.close_all.assert_called_once_with(
        timeout_seconds=1.0
    )
    target.release_preview_engines.assert_called_once_with()
    target.stop_remote_peer_timer.assert_called_once_with()
    target.publish_local_ledger_now.assert_called_once_with(())
    target.stop_cloud_ingest_server.assert_called_once_with()
    target.stop_hook_ingress.assert_called_once_with()
    target.stop_event_server.assert_called_once_with()
    target.closed_lid_awake.release.assert_called_once_with()
    target.keep_awake.release.assert_called_once_with()
    target._persistence_writer.close.assert_called_once_with(timeout_seconds=3.0)


def test_application_closes_dnd_before_other_lifecycle_and_native_surfaces(
    controller,
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    target, _status_bar = controller
    _prepare_terminate_controller(target, monkeypatch)
    order: list[str] = []
    target.dnd_controller = SimpleNamespace(
        close=MagicMock(side_effect=lambda: order.append("dnd"))
    )
    target.virtual_status_device.terminate.side_effect = lambda: order.append(
        "virtual-device"
    )

    target.applicationWillTerminate_(None)
    target.applicationWillTerminate_(None)

    assert order[:2] == ["dnd", "virtual-device"]
    target.dnd_controller.close.assert_called_once_with()


def test_clear_agents_state_is_restored_at_launch() -> None:
    # The commit and undo paths are the daemon's (core_runtime
    # _apply_clear_agents_plan); the controller owns the state and its restore.
    source = STATUS_BAR_LEGACY.read_text(encoding="utf-8")
    tree = ast.parse(source, filename=str(STATUS_BAR_LEGACY))
    controller = next(
        node
        for node in tree.body
        if isinstance(node, ast.ClassDef) and node.name == "StatusBarController"
    )
    methods = {
        node.name: node
        for node in controller.body
        if isinstance(node, ast.FunctionDef)
    }

    init_source = ast.get_source_segment(source, methods["init"])
    restore_source = ast.get_source_segment(
        source,
        methods["load_operator_local_state"],
    )

    assert init_source is not None
    assert restore_source is not None
    for field in (
        "self.clear_agents_state = ClearAgentsState()",
        "self.clear_agents_path = default_clear_agents_path()",
        "self._clear_agents_preview",
        "self._clear_agents_commit_plan",
        "self._clear_agents_operation_pending = False",
    ):
        assert field in init_source
    assert "load_clear_agents_state(self.clear_agents_path)" in restore_source
    assert "self.clear_agents_state = clear_restore.state" in restore_source
