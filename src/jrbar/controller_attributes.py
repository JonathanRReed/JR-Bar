"""Names the daemon's controller declares on its own class, so reading them
is cheap.

The controller is an NSObject subclass four Python classes deep. Every
``self.x`` walks those classes, asking the Objective-C runtime at each one
for a matching selector, before the instance dict answers: about 5.5 us a
read, against 0.02 us on a plain Python object. A ``getattr(self, "x",
default)`` for a name nothing has set yet fails that whole walk and raises
inside PyObjC: about 228 us. One refresh made some 80 of those misses, and
PyObjC's attribute lookup was about half of the refresh's CPU.

A name declared on the final class is found at the first step of the walk.
Two kinds are declared:

* ``DEFAULTS``: names the controller reads with ``getattr(self, name,
  default)`` before, or without, anything setting them, each with the
  default its call sites use. Only immutable defaults, only names that
  every call site reads with the same default, and none that anything asks
  ``hasattr`` about -- so every read answers exactly what it did before.
  ``tests/test_controller_attributes.py`` fails when a new
  ``getattr(self, ...)`` on the controller names something undeclared.
* every instance attribute the first controller's ``init`` set, declared
  with the default its ``getattr`` reads use (``None`` when none do). The
  instance's own value still wins; the class entry only ends the walk
  early, and answers a later controller's ``init`` exactly as the missing
  attribute's default did.

A name any class in the chain already defines (a method, a property, a
selector) is never shadowed.
"""

from __future__ import annotations

from collections.abc import Mapping
from types import MappingProxyType
from typing import Final

_IMMUTABLE: Final = (type(None), bool, int, float, str, tuple, frozenset)

DEFAULTS: Final[Mapping[str, object]] = MappingProxyType(
    {
        # Read before, or without, anything setting them.
        "_active_calibration_preview_key": None,
        "_ambient_bar": None,
        "_ambient_low_power": False,
        "_ambient_serious_thermal": False,
        "_auto_dim_cache": None,
        "_claude_credential": None,
        "_claude_needs_sign_in": False,
        "_core_confetti_gate": None,
        "_core_detected_agents_cache": None,
        "_core_dot_plan_gap_logged": None,
        "_core_linked_dot_plan_seen": None,
        "_core_linked_sent_mark": None,
        "_core_pending_hints": None,
        "_core_presence": None,
        "_core_serve_server": None,
        "_core_serve_started": None,
        "_core_usage_history_service": None,
        "_creator_micro_output_receipt": None,
        "_creator_micro_setup_busy": False,
        "_creator_micro_setup_generation": None,
        "_creator_micro_setup_runtime_needs_restart": False,
        "_deck_automation_runner": None,
        "_deck_board_store": None,
        "_deck_control_labels": (),
        "_deck_control_settings": None,
        "_deck_input_check_active": False,
        "_deck_runtime_generation": None,
        "_deck_runtime_stopping": False,
        "_deck_session_board": None,
        "_emitted_brightness": None,
        "_glance_light_state": None,
        "_jr_usage_refresh_at": 0.0,
        "_jrbar_command_journal": None,
        "_jrbar_optional_integration_runtime": None,
        "_jrbar_provider_credential_store": None,
        "_jrbar_provider_presentation_settings": None,
        "_jrbar_provider_usage_service": None,
        "_jrbar_provider_usage_settings_snapshot": None,
        "_jrbar_provider_usage_window": None,
        "_jrbar_reset_delivery_timer": None,
        "_jrbar_usage_menu_boxes": None,
        "_keepalive_fresh_stamps": None,
        "_keychain_consent_ledger": None,
        "_last_claude_quota_log": None,
        "_ledger_publish_pending_signature": None,
        "_light_rows_logged": None,
        "_process_sweeper": None,
        "_production_battery_observation": None,
        "_production_battery_service": None,
        "_production_core_state": None,
        "_production_intake_service": None,
        "_production_ledger_publisher": None,
        "_production_local_health_monitor": None,
        "_production_performance_registry": None,
        "_production_transcript_service": None,
        "_production_webhook_service": None,
        "_published_ledger_path": None,
        "_quota_suffix_error_logged": False,
        "_remote_refresh_ever_applied": False,
        "_request_provider_usage": None,
        "_screen_bar_ask_latch": False,
        "_screen_bar_fleet_plan": None,
        "_studio_builder_duration_labels": None,
        "_studio_led_count_cache": None,
        "_t3_read_only_policy": None,
        "_t3_snapshot_service": None,
        "active_finite_cue": None,
        "active_signal": None,
        "canonical_operator_state": None,
        "claude_plan_text": None,
        "codex_summary_text": None,
        "completion_sweep": None,
        "connected_devices": None,
        "connection_notice_until": 0.0,
        "current_calendar_alert": None,
        "current_capacity_projection": None,
        "current_glance": None,
        "current_reminder_alert": None,
        "current_usage_view": None,
        "display_asleep": False,
        "last_refresh_hint": None,
        "provider_usage_state": None,
        "quota_reset_celebration_provider": None,
        "quota_reset_celebration_until": 0.0,
        "studio_builder_loop": True,
        "studio_problem_label": None,
        "usage_graph_model": None,
        # Set by ``init``, and read with a getattr default before that on a
        # later controller (tests build several).
        "_activity_tracking_warm": False,
        "_attempted_capacity_boundary_keys": (),
        "_clear_agents_operation_pending": False,
        "_completion_meniscus_plans": (),
        "_core_adapter_short": False,
        "_core_in_refresh": False,
        "_core_last_clear_batch": "",
        "_core_linked_dot_origin_ms": 0.0,
        "_core_linked_pro_leds": 8,
        "_core_settings_generation": 0,
        "_deck_board_ready": False,
        "_deck_deliver_inline": False,
        "_device_inventory_candidates": (),
        "_discovery_revalidating": False,
        "_dnd_refresh_in_progress": False,
        "_fleet_arrival_departure_decisions": (),
        "_hardware_write_active": False,
        "_intake_probed_at": 0.0,
        "_keepalive_poke_in_flight": False,
        "_last_event_refresh_at": 0.0,
        "_liveness_sweep_running": False,
        "_operator_history_operation_status": "",
        "_pane_transition_generation": 0,
        "_peek_hits": 0,
        "_production_force_refresh": False,
        "_production_last_full_refresh": 0.0,
        "_production_refresh_active": False,
        "_production_refresh_pending": False,
        "_production_why_panel_refresh_pending": False,
        "_provider_probe_at": 0.0,
        "_refresh_led_write_seconds": 0.0,
        "_runtime_started": False,
        "_runtime_termination_started": False,
        "_settings_window_closing": False,
        "_status_cue_candidates": (),
        "_usage_local_scan_complete": False,
        "all_clear_until": 0.0,
        "completion_sweep_until": 0.0,
        "escalation_chimed": False,
        "escalation_last_stage": 0,
        "escalation_webhook_fired": False,
        "escalation_webhooked": False,
        "hooks_update_in_flight": False,
        "leds_enabled": False,
        "mailbox_preferences": (),
        "operator_history_range_days": 1,
        "peek_until": 0.0,
        "quota_blink_until": 0.0,
        "semantic_text_scale_percent": 100,
        "status_menu_open": False,
        "studio_preview_program": "",
        "test_signal_until": 0.0,
    }
)

# Read with ``getattr(self, ...)`` on the controller and deliberately left
# undeclared, each for the reason given: declaring them would change what a
# read answers.
UNDECLARED: Final[Mapping[str, str]] = MappingProxyType(
    {
        "_calibration_compare_baseline": "a fresh {} per read",
        "_calibration_compare_stash": "a fresh {} per read",
        "_core_pack_paths": "initialised behind hasattr",
        "_deck_settings_save_generation": "read with 0 here and None in deck_settings_controller",
        "_installed_agent_inventory_roots": "the default is computed per read",
        "_jrbar_provider_usage_edge_baseline": "the default is computed per read",
        "_keepalive_logged_targets": "a fresh set() per read",
        "_settings_category_children": "initialised behind hasattr",
        "studio_builder_steps": "read with a computed default in studio_builder",
        # Set by ``init``, but a getattr somewhere reads them with a mutable
        # or computed default, or with defaults that disagree.
        "_activity_quota_percents": "a fresh {} per read",
        "_ambient_effect_dispatch_started_at_by_surface": "a fresh {} per read",
        "_ambient_source_health": "a fresh {} per read",
        "_ambient_turn_starts": "a fresh {} per read",
        "_attended_prompt_monotonic": "read with None and with {}",
        "_capacity_detail_inputs": "a fresh {} per read",
        "_capacity_refresh_deadline_timers": "a fresh {} per read",
        "_capacity_refresh_retry_timers": "a fresh {} per read",
        "_capacity_reset_plan": "the default is computed per read",
        "_core_launch_started": "the default is computed per read",
        "_core_ready_at": "the default is computed per read",
        "_frozen_hardware_render_colors": "the default is computed per read",
        "_jrbar_provider_usage_state": "read with None and with a computed default",
        "_jrbar_reset_delivery_state": "read with None and with a computed default",
        "_notification_action_bindings": "a fresh {} per read",
        "_power_hold_account_bindings_by_work": "a fresh {} per read",
        "_usage_provider_models": "a fresh {} per read",
        "_usage_provider_states": "a fresh {} per read",
        "_usage_transcript_states": "a fresh {} per read",
        "ask_blocked_by_agent": "a fresh {} per read",
        "color_preview_enabled": "read with True and with False",
        "color_preview_scenario": "the default is computed per read",
        "colors_animation_thumbs": "a fresh {} per read",
        "current_settings_pane": "read with None and with ''",
        "last_agent_modes": "a fresh {} per read",
        "last_led_display_kind_by_device": "a fresh {} per read",
        "lid_animation_thumbs": "read with None and with {}",
        "local_triage_state": "read with None and with a computed default",
        "mailbox_retained_order": "read with None and with {}",
        "mailbox_seen_completion_ids": "a fresh set() per read",
        "navigation_candidates_by_work_key": "a fresh {} per read",
        "settings_buttons": "read with None and with {}",
        "settings_fields": "read with None and with {}",
        "settings_panes": "read with None and with {}",
        "tip_anchor_views": "tested with hasattr",
        "working_since_by_agent": "a fresh {} per read",
    }
)

# What ``declare`` put on each class, for the guard test.
_DECLARED: dict[type, set[str]] = {}


def _defined_in_chain(cls: type, name: str) -> bool:
    return any(name in klass.__dict__ for klass in cls.__mro__)


def _may_be_a_selector(cls: type, name: str) -> bool:
    # A bare lowercase word (``copy``, ``hash``, ``description``) can name
    # an inherited Objective-C method that is not in any Python __dict__.
    # Names with an inner underscore map to selectors with arguments.
    if "_" in name.strip("_"):
        return False
    try:
        return hasattr(cls, name)
    except Exception:
        return True


def declare(cls: type, names: Mapping[str, object]) -> int:
    """Set each name to its default on ``cls`` unless the class chain
    already defines it; returns how many were declared."""
    declared = 0
    for name, default in names.items():
        if (
            type(name) is not str
            or not name.isidentifier()
            or name.startswith("__")
            or name.endswith("_")
            or not isinstance(default, _IMMUTABLE)
            or _defined_in_chain(cls, name)
            or _may_be_a_selector(cls, name)
        ):
            continue
        setattr(cls, name, default)
        _DECLARED.setdefault(cls, set()).add(name)
        declared += 1
    return declared


def declare_instance_attributes(cls: type, instance: object) -> int:
    """Declare every attribute ``instance`` holds on ``cls``, with its
    getattr default from ``DEFAULTS`` or ``None``; ``UNDECLARED`` names are
    left alone."""
    names = getattr(instance, "__dict__", None) or {}
    return declare(
        cls,
        {name: DEFAULTS.get(name) for name in names if name not in UNDECLARED},
    )


def declared_names(cls: type) -> frozenset[str]:
    return frozenset(_DECLARED.get(cls, ()))


__all__ = ["DEFAULTS", "UNDECLARED", "declare", "declare_instance_attributes", "declared_names"]
