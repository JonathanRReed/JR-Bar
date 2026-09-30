"""A lapsed window stops driving the Screen Bar ember and the runway LED.

These sit apart from ``tests/test_jrbar.py`` on purpose: they need only a
stand-in controller, a fixed clock, and the pure selection code.
"""

from __future__ import annotations

from types import SimpleNamespace

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


def test_a_lapsed_empty_lane_no_longer_reaches_the_exhausted_signal() -> None:
    # 1.0 is what sends the "quota_exhausted" creator signal.
    lapsed_empty = _controller(
        _snapshot(0.0, reset_at=NOW - 60.0, state=ProviderSourceState.STALE)
    )
    live_empty = _controller(_snapshot(0.0, reset_at=NOW + 60.0))

    assert screen_bar_quota_ember_level(lapsed_empty, wall_clock=lambda: NOW) < 1.0
    assert screen_bar_quota_ember_level(live_empty, wall_clock=lambda: NOW) == 1.0


def test_the_runway_led_program_reads_its_state_once_and_survives_a_lapse() -> None:
    from jrbar import status_bar_legacy

    calls: list[int] = []
    states: list[tuple[float, str] | None] = [(0.6, "#D97757"), None]

    def runway_state():
        calls.append(1)
        return states[0]

    controller = SimpleNamespace(quota_runway_state=runway_state)
    entries = status_bar_legacy.StatusBarController.signal_display_entries(controller)
    factory = entries[status_bar_legacy.LED_DISPLAY_QUOTA_RUNWAY][0]

    program = factory(255, 8)

    assert isinstance(program, str) and "repeat" in program
    assert len(calls) == 1, "the runway state was read more than once for one frame"

    # A state that lapses to nothing between reads must not raise.
    calls.clear()
    states[0] = None
    assert factory(255, 8) is None
    assert len(calls) == 1
