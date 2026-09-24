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
from jrbar.global_action_controller import (
    GlobalActionChangeResult,
    GlobalActionLifecycleCoordinator,
)
from jrbar.global_actions import (
    GlobalActionID,
    PersistedShortcutRefusal,
    ShortcutChord,
    ShortcutModifier,
    ShortcutValidationCode,
)
from jrbar.global_hotkeys import HotkeyCleanupError, HotkeyRegistrationRefusal
from jrbar.settings import (
    SettingsConcurrentWriteError,
    SettingsWriteRefusedError,
)

ACTION = GlobalActionID.REVEAL_CURRENT_ASK
COMMAND_K = ShortcutChord(
    key_code=40,
    key_label="K",
    modifiers=frozenset({ShortcutModifier.COMMAND}),
)
CONTROL_SHIFT_K = ShortcutChord(
    key_code=40,
    key_label="K",
    modifiers=frozenset({ShortcutModifier.CONTROL, ShortcutModifier.SHIFT}),
)

ROOT = Path(__file__).resolve().parents[1]
STATUS_BAR_LEGACY = ROOT / "src" / "jrbar" / "status_bar_legacy.py"


class _Registry:
    def __init__(self, events) -> None:
        self.events = events
        self.active_bindings = {}
        self.closed = False
        self.pending = None
        self.prepare_refusals: list[HotkeyRegistrationRefusal] = []
        self.commit_errors: list[HotkeyCleanupError] = []
        self.rollback_errors: list[HotkeyCleanupError] = []

    def prepare(self, bindings):
        if self.pending is not None:
            raise RuntimeError("a global hotkey change is already prepared")
        self.pending = dict(bindings)
        self.events.append(("prepare", dict(bindings)))
        if self.prepare_refusals:
            self.pending = None
            return SimpleNamespace(
                preparation=None,
                refusal=self.prepare_refusals.pop(0),
            )
        return SimpleNamespace(preparation="transaction", refusal=None)

    def commit(self, preparation) -> None:
        assert preparation == "transaction"
        self.events.append(("commit",))
        if self.commit_errors:
            raise self.commit_errors.pop(0)
        self.active_bindings = self.pending
        self.pending = None

    def rollback(self, preparation) -> None:
        assert preparation == "transaction"
        self.events.append(("rollback",))
        if self.rollback_errors:
            raise self.rollback_errors.pop(0)
        self.pending = None

    def close(self) -> None:
        if self.closed:
            return
        self.events.append(("close",))
        self.closed = True


def _lifecycle(settings, events, *, save_error=None, save_errors=None):
    holder = {"settings": settings}
    registry = _Registry(events)
    queued_save_errors = list(save_errors or ())

    def save(candidate) -> None:
        events.append(("save", candidate.global_action_shortcuts))
        if queued_save_errors:
            queued_error = queued_save_errors.pop(0)
            if queued_error is not None:
                raise queued_error("injected bounded refusal")
        if save_error is not None:
            raise save_error("injected bounded refusal")

    lifecycle = GlobalActionLifecycleCoordinator(
        registry_factory=lambda _on_action: registry,
        settings_getter=lambda: holder["settings"],
        settings_setter=lambda candidate: holder.__setitem__("settings", candidate),
        settings_saver=save,
        action_handler=lambda _action: None,
    )
    return lifecycle, registry, holder


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


def test_global_action_launch_and_refresh_register_persisted_binding_once__and_2_more(controller,) -> None:
    # --- scenario: global_action_launch_and_refresh_register_persisted_binding_once
    target, _status_bar = controller
    settings = replace(
        target.settings,
        global_action_shortcuts={ACTION.value: COMMAND_K.to_dict()},
    )
    events = []
    lifecycle, registry, _holder = _lifecycle(settings, events)

    lifecycle.launch()
    lifecycle.launch()
    lifecycle.refresh_from_settings()

    assert events == [
        ("prepare", {ACTION: COMMAND_K}),
        ("commit",),
    ]
    assert registry.active_bindings == {ACTION: COMMAND_K}

    # --- scenario: global_action_refresh_retries_after_transient_registration_refusal
    target, _status_bar = controller
    settings = replace(
        target.settings,
        global_action_shortcuts={ACTION.value: COMMAND_K.to_dict()},
    )
    events = []
    lifecycle, registry, _holder = _lifecycle(settings, events)
    refusal = HotkeyRegistrationRefusal.from_os_status(-9878)
    registry.prepare_refusals.append(refusal)

    first = lifecycle.launch()
    second = lifecycle.refresh_from_settings()

    assert first.applied is False
    assert first.refusal == refusal
    assert second.applied is True
    assert [event[0] for event in events] == ["prepare", "prepare", "commit"]
    assert registry.active_bindings == {ACTION: COMMAND_K}

    # --- scenario: launch_reports_persisted_refusal_and_keeps_valid_binding_operational
    target, _status_bar = controller
    raw = {
        ACTION.value: COMMAND_K.to_dict(),
        "future_action": {"unexpected": True},
    }
    settings = replace(target.settings, global_action_shortcuts=raw)
    events = []
    lifecycle, registry, holder = _lifecycle(settings, events)

    result = lifecycle.launch()

    assert result.applied is True
    assert result.persisted_refusals == (
        PersistedShortcutRefusal(
            "future_action",
            ShortcutValidationCode.UNKNOWN_ACTION,
        ),
    )
    assert registry.active_bindings == {ACTION: COMMAND_K}
    assert holder["settings"].global_action_shortcuts == raw
    assert [event[0] for event in events] == ["prepare", "commit"]


def test_global_action_edit_is_prepare_save_commit_and_updates_settings(
    controller,
) -> None:
    target, _status_bar = controller
    events = []
    lifecycle, registry, holder = _lifecycle(target.settings, events)
    lifecycle.launch()
    events.clear()

    result = lifecycle.set_shortcut(ACTION, COMMAND_K)

    assert result.applied is True
    assert [event[0] for event in events] == ["prepare", "save", "commit"]
    assert registry.active_bindings == {ACTION: COMMAND_K}
    assert holder["settings"].global_action_shortcuts == {
        ACTION.value: COMMAND_K.to_dict()
    }


@pytest.mark.parametrize(
    "error_type",
    (SettingsConcurrentWriteError, SettingsWriteRefusedError),
)
def test_global_action_save_refusal_rolls_back_runtime_and_durable_binding(
    controller,
    error_type,
) -> None:
    target, _status_bar = controller
    initial = replace(
        target.settings,
        global_action_shortcuts={ACTION.value: COMMAND_K.to_dict()},
    )
    events = []
    lifecycle, registry, holder = _lifecycle(
        initial,
        events,
        save_error=error_type,
    )
    lifecycle.launch()
    events.clear()

    result = lifecycle.set_shortcut(ACTION, CONTROL_SHIFT_K)

    assert result.applied is False
    assert [event[0] for event in events] == ["prepare", "save", "rollback"]
    assert registry.active_bindings == {ACTION: COMMAND_K}
    assert holder["settings"] is initial


def test_failed_global_action_clear_keeps_previous_live_and_durable_binding(
    controller,
) -> None:
    target, _status_bar = controller
    initial = replace(
        target.settings,
        global_action_shortcuts={ACTION.value: COMMAND_K.to_dict()},
    )
    events = []
    lifecycle, registry, holder = _lifecycle(
        initial,
        events,
        save_error=SettingsWriteRefusedError,
    )
    lifecycle.launch()
    events.clear()

    result = lifecycle.clear_shortcut(ACTION)

    assert result.applied is False
    assert [event[0] for event in events] == ["prepare", "save", "rollback"]
    assert registry.active_bindings == {ACTION: COMMAND_K}
    assert holder["settings"] is initial


@pytest.mark.parametrize(
    ("restore_error", "expected_failure"),
    (
        (
            SettingsConcurrentWriteError,
            "commit_cleanup_restore_concurrent_write",
        ),
        (
            SettingsWriteRefusedError,
            "commit_cleanup_restore_write_refused",
        ),
    ),
)
def test_commit_cleanup_always_rolls_back_after_compensating_save_refusal(
    controller,
    restore_error,
    expected_failure,
) -> None:
    target, _status_bar = controller
    initial = replace(
        target.settings,
        global_action_shortcuts={ACTION.value: COMMAND_K.to_dict()},
    )
    events = []
    lifecycle, registry, holder = _lifecycle(
        initial,
        events,
        save_errors=(None, restore_error),
    )
    lifecycle.launch()
    events.clear()
    registry.commit_errors.append(HotkeyCleanupError("commit", 1))

    result = lifecycle.set_shortcut(ACTION, CONTROL_SHIFT_K)

    assert result == GlobalActionChangeResult(
        False,
        save_failure=expected_failure,
    )
    assert [event[0] for event in events] == [
        "prepare",
        "save",
        "commit",
        "save",
        "rollback",
    ]
    assert registry.pending is None
    assert registry.active_bindings == {ACTION: COMMAND_K}
    assert holder["settings"] is initial


def test_commit_and_rollback_cleanup_failure_remains_bounded_and_retryable__and_1_more(controller,) -> None:
    # --- scenario: commit_and_rollback_cleanup_failure_remains_bounded_and_retryable
    target, _status_bar = controller
    initial = replace(
        target.settings,
        global_action_shortcuts={ACTION.value: COMMAND_K.to_dict()},
    )
    events = []
    lifecycle, registry, _holder = _lifecycle(initial, events)
    lifecycle.launch()
    events.clear()
    registry.commit_errors.append(HotkeyCleanupError("commit", 1))
    registry.rollback_errors.append(HotkeyCleanupError("rollback", 1))

    failed = lifecycle.set_shortcut(ACTION, CONTROL_SHIFT_K)

    assert failed == GlobalActionChangeResult(
        False,
        save_failure="commit_cleanup_rollback_cleanup",
    )
    assert [event[0] for event in events] == [
        "prepare",
        "save",
        "commit",
        "save",
        "rollback",
    ]
    assert registry.pending == {ACTION: CONTROL_SHIFT_K}
    assert registry.active_bindings == {ACTION: COMMAND_K}

    events.clear()
    retried = lifecycle.set_shortcut(ACTION, CONTROL_SHIFT_K)

    assert retried.applied is True
    assert [event[0] for event in events] == [
        "rollback",
        "prepare",
        "save",
        "commit",
    ]
    assert registry.pending is None
    assert registry.active_bindings == {ACTION: CONTROL_SHIFT_K}

    # --- scenario: global_action_close_is_idempotent_and_fences_late_actions
    target, _status_bar = controller
    events = []
    invoked = []
    holder = {"settings": target.settings}
    registry = _Registry(events)
    lifecycle = GlobalActionLifecycleCoordinator(
        registry_factory=lambda on_action: (
            setattr(registry, "on_action", on_action) or registry
        ),
        settings_getter=lambda: holder["settings"],
        settings_setter=lambda candidate: holder.__setitem__("settings", candidate),
        settings_saver=lambda _candidate: None,
        action_handler=invoked.append,
    )
    lifecycle.launch()

    lifecycle.close()
    lifecycle.close()
    registry.on_action(ACTION)

    assert events.count(("close",)) == 1
    assert invoked == []


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


def test_application_closes_global_actions_before_native_surface_teardown(
    controller,
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    target, _status_bar = controller
    _prepare_terminate_controller(target, monkeypatch)
    order = []
    target.global_action_lifecycle = SimpleNamespace(
        close=MagicMock(side_effect=lambda: order.append("global-actions"))
    )
    target.virtual_status_device.terminate.side_effect = lambda: order.append(
        "virtual-device"
    )

    target.applicationWillTerminate_(None)
    target.applicationWillTerminate_(None)

    assert order[:2] == ["global-actions", "virtual-device"]
    target.global_action_lifecycle.close.assert_called_once_with()


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
    target.global_action_lifecycle = SimpleNamespace(
        close=MagicMock(side_effect=lambda: order.append("global-actions"))
    )
    target.virtual_status_device.terminate.side_effect = lambda: order.append(
        "virtual-device"
    )

    target.applicationWillTerminate_(None)
    target.applicationWillTerminate_(None)

    assert order[:3] == ["dnd", "global-actions", "virtual-device"]
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
