"""A capacity lease expiry crosses real admission and headless publication."""

import __future__

import ast
from datetime import datetime, timezone
from pathlib import Path
from types import SimpleNamespace

from jrbar import scene_leases
from jrbar.capacity_limit_feedback import update_capacity_limit_alert
from jrbar.core_runtime import device_transitions
from jrbar.core_state import CoreDomain, CoreStateStore
from jrbar.dot_role import DotBeaconFacts, beacon_program
from jrbar.models import AgentMode, AgentStatus
from jrbar.presentation_policy import ResolvedGlance
from jrbar.provider_facts import ProviderTerminalCause
from jrbar.refresh_admission import RefreshAdmission, admit_refresh

ROOT = Path(__file__).resolve().parents[1] / "src/jrbar"


def method(filename, name, scope):
    nodes = [node for node in ast.walk(ast.parse((ROOT / filename).read_text()))
             if isinstance(node, ast.FunctionDef) and node.name == name]
    assert len(nodes) == 1
    node = nodes[0]
    node.decorator_list = []
    exec(compile(ast.Module(body=[node], type_ignores=[]), filename, "exec",
                 flags=__future__.annotations.compiler_flag), scope)
    return scope[name]


def test_four_second_expiry_admits_unchanged_state_and_publishes_normal_lighting():
    clock = [20.0]
    frames, plans, notices, metrics = [], [], [], []
    status = AgentStatus("claude", "claude:session:fixture", "Claude", AgentMode.BLOCKED_ERROR,
                         datetime.fromtimestamp(1000, timezone.utc), "StopFailure",
                         terminal_cause=ProviderTerminalCause.CLAUDE_RATE_LIMIT)
    projection = SimpleNamespace(all_rows=(SimpleNamespace(source_status=status),))
    time = SimpleNamespace(monotonic=lambda: clock[0], perf_counter=lambda: clock[0])

    class Legacy:
        def refresh_(self, _sender):
            update_capacity_limit_alert(self, projection, wall_now=980 + clock[0],
                                        monotonic_now=clock[0], signal_kind="quota")
            plans.append(beacon_program(DotBeaconFacts(capacity_active=clock[0] < self._capacity_notice_until)))

    production_scope = {
        "time": time, "CoreDomain": CoreDomain, "RefreshAdmission": RefreshAdmission,
        "admit_refresh": admit_refresh, "FULL_REFRESH_HEARTBEAT_SECONDS": 15.0,
        "_LegacyStatusBarController": Legacy,
        "_legacy": SimpleNamespace(LED_DISPLAY_BATTERY="battery"),
    }
    observe = method("_status_bar_production.py", "_observe_refresh_state", production_scope)
    dynamic = method("_status_bar_production.py", "_dynamic_display_requires_refresh", production_scope)
    production_refresh = method("_status_bar_production.py", "refresh_", production_scope)
    expiry_scope = {"ResolvedGlance": ResolvedGlance}
    retire = method("status_bar_legacy.py", "_retire_elapsed_ui_deadlines", expiry_scope)
    expiry = method("status_bar_legacy.py", "_finite_ui_deadline_fired", expiry_scope)

    class Controller:
        settings = SimpleNamespace(devices=(), led_display="agent", quota_alerts_enabled=True)
        current_attention_projection = SimpleNamespace(actionable_attention=(), transient_signals=())
        current_escalation_stage = staticmethod(lambda: 0)
        _presentation_scheduler_inputs = SimpleNamespace(display_asleep=False, app_terminating=False)
        _current_resolved_glance = None
        _production_last_full_refresh = 20.0
        _runtime_started = False
        _core_prev_asks, _core_prev_devices = {}, {}
        _core_settings_conflict, _core_settings_dirty = None, False
        _core = object()
        provider_usage_state = SimpleNamespace(snapshots=())
        test_signal_until, test_signal_key = 0.0, None
        quota_blink_until = 0.0
        _capacity_notice_until = 0.0
        _observe_refresh_state, _dynamic_display_requires_refresh = observe, dynamic
        _finite_ui_deadline_fired, _retire_elapsed_ui_deadlines = expiry, retire

        def __init__(self):
            self.store = CoreStateStore()

        def _core_state_store(self):
            return self.store

        def _performance(self):
            return SimpleNamespace(record=lambda *args, **kwargs: metrics.append((args, kwargs)))

        def local_health_snapshot(self):
            pass

        def _presentation_monotonic(self):
            return clock[0]

        def _reconcile_current_presentation_inputs(self):
            pass

        def status_bar_devices(self, **_kwargs):
            return ()

        def _core_note_device_inventory(self, *_args):
            pass

        def _core_ask_statuses(self):
            return ()

        def _core_time_driven_state_live(self):
            return False

        def _core_publish_state(self):
            frames.append(("state", self._capacity_notice_until))

        def _core_publish_lights(self):
            frames.append(("lights", plans[-1]))

        def _core_publish_event(self, kind, **_kwargs):
            notices.append(kind)

        def may_interrupt(self, _kind):
            return True

        def quiet_active(self):
            return False

        def schedule_event_refresh(self):
            pass

    core_scope = {
        "scene_leases": scene_leases,
        "objc": SimpleNamespace(super=lambda _class, instance: SimpleNamespace(
            refresh_=lambda sender: production_refresh(instance, sender))),
        "JRCoreHeadlessController": Controller,
        "legacy": SimpleNamespace(VIRTUAL_DEVICE_ID="virtual", log_status_bar=lambda *_args: None),
        "_provider_updates_of": lambda *_args: SimpleNamespace(tick=lambda: None),
        "_diff_ask_episodes": lambda *_args: (), "device_transitions": device_transitions,
    }
    Controller.refresh_ = method("core_runtime.py", "refresh_", core_scope)
    controller = Controller()
    controller._observe_refresh_state()
    update_capacity_limit_alert(controller, SimpleNamespace(all_rows=()), wall_now=1000,
                                monotonic_now=20, signal_kind="quota")
    update_capacity_limit_alert(controller, projection, wall_now=1000, monotonic_now=20, signal_kind="quota")
    assert controller._capacity_notice_until == 24
    assert notices == ["quota_crossed"]
    # The warmed admission fingerprints omit the lease; no heartbeat or ask is due.
    assert not controller._observe_refresh_state().changed
    clock[0] = 24
    controller._finite_ui_deadline_fired()
    assert controller._production_last_refresh_admitted is True
    assert controller._capacity_notice_until == controller.quota_blink_until == 0
    assert plans == [("off", "idle", False)]
    assert frames == [("state", 0), ("lights", ("off", "idle", False))]
    assert notices == ["quota_crossed"]
    # A same-provider retry remains consumed; neither it nor a duplicate timer rearms.
    projection.all_rows = (SimpleNamespace(source_status=AgentStatus(
        "claude", "claude:session:fixture", "Claude", AgentMode.BLOCKED_ERROR,
        datetime.fromtimestamp(1005, timezone.utc), "StopFailure",
        terminal_cause=ProviderTerminalCause.CLAUDE_RATE_LIMIT)),)
    clock[0] = 25
    update_capacity_limit_alert(controller, projection, wall_now=1005, monotonic_now=25, signal_kind="quota")
    controller._finite_ui_deadline_fired()
    assert notices == ["quota_crossed"] and len(frames) == 2
