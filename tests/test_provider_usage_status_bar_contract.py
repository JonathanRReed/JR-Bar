from __future__ import annotations

import ast
import subprocess
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
MODULE = ROOT / "src" / "jrbar" / "provider_usage_status_bar.py"
STATUS_PROJECTION_MODULE = ROOT / "src" / "jrbar" / "provider_usage_status_projection.py"
FEEDBACK_ACTIONS_MODULE = ROOT / "src" / "jrbar" / "provider_usage_feedback_actions.py"


def _tree():
    return ast.parse(MODULE.read_text(encoding="utf-8"))


def _method(name: str):
    for node in ast.walk(_tree()):
        if isinstance(node, ast.FunctionDef) and node.name == name:
            return node
    raise AssertionError(f"missing method: {name}")


def _function(path: Path, name: str):
    tree = ast.parse(path.read_text(encoding="utf-8"))
    for node in ast.walk(tree):
        if isinstance(node, ast.FunctionDef) and node.name == name:
            return node
    raise AssertionError(f"missing function: {name}")


def _calls(node):
    result = []
    for call in ast.walk(node):
        if not isinstance(call, ast.Call):
            continue
        function = call.func
        if isinstance(function, ast.Name):
            result.append(function.id)
        elif isinstance(function, ast.Attribute):
            result.append(function.attr)
    return tuple(result)


def test_provider_usage_runs_through_background_service_and_main_thread_apply__and_1_more() -> None:
    # --- scenario: provider_usage_runs_through_background_service_and_main_thread_apply
    request_calls = _calls(_method("_request_provider_usage"))
    apply_calls = _calls(_method("applyProviderUsageState_"))
    refresh_calls = _calls(_method("refresh_"))

    assert "request" in request_calls
    assert "performSelectorOnMainThread_withObject_waitUntilDone_" not in request_calls
    assert "detect_reset_events" in apply_calls
    assert "begin_reset_delivery" in apply_calls
    assert "_deliver_pending_reset_events" in apply_calls
    assert "apply_provider_usage_settings_snapshot" in apply_calls
    assert "_persist_reset_delivery_state" in apply_calls
    assert "submit" in _calls(_method("_persist_reset_delivery_state"))
    assert "threading.Thread" not in MODULE.read_text(encoding="utf-8")
    assert "_request_provider_usage" in refresh_calls
    assert "_deliver_pending_reset_events" in refresh_calls
    assert "_deliver_pending_reset_events" in _calls(
        _method("retryPendingResetDeliveries_")
    )
    assert "_schedule_capacity_timer" in _calls(
        _method("_schedule_reset_delivery_retry")
    )
    assert "refresh_now" not in refresh_calls

    # --- scenario: usage_apply_does_not_reload_settings_on_the_ui_thread
    ready = _method("_provider_usage_ready")
    ready_calls = _calls(ready)
    apply_calls = _calls(_method("applyProviderUsageState_"))
    menu_settings_calls = _calls(_method("_usage_menu_settings"))

    assert "settings_snapshot" in ready_calls
    assert "refresh_cached_merged_sync" in ready_calls
    assert "ProviderUsageApply" in ready_calls
    refresh = next(
        node
        for node in ast.walk(ready)
        if isinstance(node, ast.Call)
        and isinstance(node.func, ast.Name)
        and node.func.id == "refresh_cached_merged_sync"
    )
    dispatch = next(
        node
        for node in ast.walk(ready)
        if isinstance(node, ast.Call)
        and isinstance(node.func, ast.Attribute)
        and node.func.attr
        == "performSelectorOnMainThread_withObject_waitUntilDone_"
    )
    assert refresh.lineno < dispatch.lineno
    assert "load_provider_usage_settings" not in apply_calls
    assert "load_provider_usage_settings" not in menu_settings_calls


def test_provider_feedback_dispatch_is_extracted_behind_controller_methods() -> None:
    delegates = {
        "_alert_new_critical_pace": "alert_new_critical_pace",
        "_report_reconnect_outcome": "report_reconnect_outcome",
        "_celebrate_quota_resets": "celebrate_quota_resets",
        "_alert_connection_loss": "alert_connection_loss",
    }

    for method_name, helper_name in delegates.items():
        assert _calls(_method(method_name)).count(helper_name) == 1
        _function(FEEDBACK_ACTIONS_MODULE, helper_name)


def test_why_panel_forwards_the_user_privacy_setting() -> None:
    why_method = _method("why_panel_body")
    why_helper = _function(STATUS_PROJECTION_MODULE, "provider_usage_why_panel_body")

    assert _calls(why_method).count("provider_usage_why_panel_body") == 1
    assert "privacy_mode=privacy_mode" in ast.unparse(why_helper)


def test_wrapper_does_not_rebind_objc_super_through_a_mutable_global__and_1_more() -> None:
    # --- scenario: wrapper_does_not_rebind_objc_super_through_a_mutable_global
    source = MODULE.read_text(encoding="utf-8")
    assert "def init(" not in source
    assert "objc.super(" not in source

    # --- scenario: termination_closes_provider_service
    calls = _calls(_method("applicationWillTerminate_"))
    assert "close" in calls


def test_session_opening_consults_exact_instance_policy_before_legacy_router__and_1_more() -> None:
    # --- scenario: session_opening_consults_exact_instance_policy_before_legacy_router
    calls = _calls(_method("open_session"))

    assert "profile_session_action" in calls
    assert "open_session" in calls

    # --- scenario: why_panel_override_preserves_the_base_context_keyword_contract
    method = _method("why_panel_body")
    kwonly = [argument.arg for argument in method.args.kwonlyargs]
    assert kwonly == ["why_context", "wall_clock"]

    base_call = next(
        node
        for node in ast.walk(method)
        if isinstance(node, ast.Call)
        and isinstance(node.func, ast.Attribute)
        and node.func.attr == "why_panel_body"
    )
    keywords = {keyword.arg for keyword in base_call.keywords}
    assert "why_context" in keywords


_STATUS_BAR_PROBE_PREAMBLE = """
from jrbar.provider_usage_status_bar import JRProviderUsageStatusBarController

class FakeController:
    def __init__(self):
        self.refreshes = []

    def _request_provider_usage(self, **kwargs):
        self.refreshes.append(kwargs)
"""


def _run_status_bar_probe(body: str) -> None:
    """Exercise the production wrapper without leaking its import installers."""
    completed = subprocess.run(
        [sys.executable, "-c", _STATUS_BAR_PROBE_PREAMBLE + body],
        cwd=ROOT,
        capture_output=True,
        text=True,
        timeout=10,
        check=False,
    )
    assert completed.returncode == 0, completed.stderr


def test_refresh_gate_is_fresh_before_two_minutes_and_due_at_two_minutes() -> None:
    _run_status_bar_probe(
        """
controller = FakeController()
clock = [1000.0]
JRProviderUsageStatusBarController.request_jr_usage_refresh(
    controller, ("claude",), monotonic=lambda: clock[0]
)
clock[0] = 1119.999
JRProviderUsageStatusBarController.request_jr_usage_refresh(
    controller, ("claude",), monotonic=lambda: clock[0]
)
assert len(controller.refreshes) == 1
clock[0] = 1120.0
JRProviderUsageStatusBarController.request_jr_usage_refresh(
    controller, ("claude",), monotonic=lambda: clock[0]
)
assert len(controller.refreshes) == 2
"""
    )
