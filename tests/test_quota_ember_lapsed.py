"""A lapsed window stops driving the Screen Bar ember and the runway LED.

These sit apart from ``tests/test_jrbar.py`` on purpose: they need only a
stand-in controller, a fixed clock, and the pure selection code.
"""

from __future__ import annotations

from dataclasses import replace
from datetime import datetime, timezone
from types import SimpleNamespace

import pytest

from jrbar.capacity_limit_feedback import update_capacity_limit_alert
from jrbar.dot_role import DotBeaconFacts, beacon_program
from jrbar.models import AgentMode, AgentStatus
from jrbar.provider_facts import ProviderTerminalCause
from jrbar.provider_usage_platform import (
    ProviderSourceState,
    ProviderUsageSnapshot,
    UsageLane,
)
from jrbar.provider_usage_status_projection import screen_bar_quota_ember_level

NOW = 1_787_000_000.0


def _snapshot(
    remaining: float,
    *,
    reset_at: float | None,
    state: ProviderSourceState = ProviderSourceState.READY,
) -> ProviderUsageSnapshot:
    return ProviderUsageSnapshot(
        provider_id="claude",
        account_label=None,
        observed_at=NOW,
        state=state,
        reason_code=None,
        action_label=None,
        lanes=(
            UsageLane(
                provider_id="claude",
                lane_id="five_hour",
                label="5h",
                remaining_percent=remaining,
                reset_at=reset_at,
                scope="all",
                model=None,
                feature=None,
                bindable=True,
                source_id="official",
            ),
        ),
        input_tokens=0,
        cached_input_tokens=0,
        output_tokens=0,
        model_count=0,
        estimated_cost_usd=None,
        cache_savings_usd=None,
        credits_remaining=None,
        incident=None,
    )


def _controller(snapshot: ProviderUsageSnapshot, *, threshold: float = 20.0):
    settings = SimpleNamespace(
        hidden_menu_providers=lambda: frozenset(),
        hidden_menu_instances=lambda: frozenset(),
        providers=(
            SimpleNamespace(identity=snapshot.identity, threshold_remaining=threshold),
        ),
    )
    return SimpleNamespace(
        _usage_menu_settings=lambda: settings,
        provider_usage_state=SimpleNamespace(snapshots=(snapshot,)),
    )


def test_a_live_low_lane_lights_the_ember() -> None:
    controller = _controller(_snapshot(5.0, reset_at=NOW + 3_600.0))

    level = screen_bar_quota_ember_level(controller, wall_clock=lambda: NOW)

    assert 0.7 < level < 0.8


def test_a_lapsed_low_lane_leaves_the_ember_dark() -> None:
    controller = _controller(_snapshot(5.0, reset_at=NOW - 3_600.0))

    assert screen_bar_quota_ember_level(controller, wall_clock=lambda: NOW) == 0.0


def test_an_empty_lane_never_keeps_a_standing_exhaustion_light() -> None:
    # Exhaustion has a finite notice; the standing gauge must stay dark.
    lapsed_empty = _controller(
        _snapshot(0.0, reset_at=NOW - 60.0, state=ProviderSourceState.STALE)
    )
    live_empty = _controller(_snapshot(0.0, reset_at=NOW + 60.0))

    assert screen_bar_quota_ember_level(lapsed_empty, wall_clock=lambda: NOW) < 1.0
    assert screen_bar_quota_ember_level(live_empty, wall_clock=lambda: NOW) == 0.0


def test_the_runway_led_program_reads_its_state_once_and_survives_a_lapse() -> None:
    from jrbar import daemon_controller

    calls: list[int] = []
    states: list[tuple[float, str] | None] = [(0.6, "#D97757"), None]

    def runway_state():
        calls.append(1)
        return states[0]

    controller = SimpleNamespace(quota_runway_state=runway_state)
    entries = daemon_controller.StatusBarController.signal_display_entries(controller)
    factory = entries[daemon_controller.LED_DISPLAY_QUOTA_RUNWAY][0]

    program = factory(255, 8)

    assert isinstance(program, str) and "repeat" in program
    assert len(calls) == 1, "the runway state was read more than once for one frame"

    # A state that lapses to nothing between reads must not raise.
    calls.clear()
    states[0] = None
    assert factory(255, 8) is None
    assert len(calls) == 1


def test_a_reported_limit_silences_the_gauge_even_when_cached_quota_still_has_headroom():
    snapshot = _snapshot(5.0, reset_at=NOW + 3600)
    controller = _controller(snapshot)
    controller._capacity_limit_seen = {snapshot.identity: NOW + 1}
    assert screen_bar_quota_ember_level(controller, wall_clock=lambda: NOW + 2) == 0


@pytest.mark.parametrize("state", [ProviderSourceState.READY, ProviderSourceState.STALE])
def test_spent_weekly_lane_stays_quiet_beside_healthy_short_and_model_lanes(state):
    weekly = _snapshot(0, reset_at=NOW + 158_572, state=state)
    short = replace(weekly.lanes[0], lane_id="five_hour", label="5h", remaining_percent=100, reset_at=None)
    model = replace(weekly.lanes[0], lane_id="seven_day_model", label="7d model",
                    remaining_percent=100, model="fixture-model")
    snapshot = replace(weekly, lanes=(short, replace(weekly.lanes[0], lane_id="seven_day", label="7d"), model))
    controller = _controller(snapshot)
    notices = []
    controller.settings = SimpleNamespace(quota_alerts_enabled=True)
    controller.quota_blink_until = 0
    controller.may_interrupt = lambda _: True
    controller.quiet_active = lambda: False
    controller.schedule_event_refresh = lambda: None
    controller._core_publish_event = lambda kind, **_: notices.append(kind)
    empty = SimpleNamespace(all_rows=())
    update_capacity_limit_alert(controller, empty, wall_now=NOW, monotonic_now=20, signal_kind="quota")
    for offset in (1, 10, 100):
        controller.provider_usage_state.snapshots = (replace(snapshot, observed_at=NOW + offset),)
        retry = AgentStatus("claude", "claude:fixture", "Claude", AgentMode.BLOCKED_ERROR,
                            datetime.fromtimestamp(NOW + offset, timezone.utc), "StopFailure",
                            terminal_cause=ProviderTerminalCause.CLAUDE_RATE_LIMIT)
        projection = SimpleNamespace(all_rows=(SimpleNamespace(source_status=retry),))
        update_capacity_limit_alert(controller, projection, wall_now=NOW + offset,
                                    monotonic_now=20 + offset, signal_kind="quota")
        assert controller.quota_blink_until == 0 and notices == []
        assert screen_bar_quota_ember_level(controller, wall_clock=lambda: NOW + offset) == 0
        active = 20 + offset < controller.quota_blink_until
        assert beacon_program(DotBeaconFacts(capacity_active=active)) == ("off", "idle", False)
