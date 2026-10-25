"""One reset rule, with confirmation, shared by every consumer.

The celebrations and the ``quota_reset`` wire event used to fire on a
single odd reading, and the usage hook had its own jump rule, so a hook
could report a reset the confetti never saw and the other way round.
Now TIMING resets (the boundary passed on our clock) fire at once, and a
JUMP waits for a confirming read 60-1800 s later whose reset time matches
within two minutes.
"""

from __future__ import annotations

import json
from dataclasses import replace
from types import SimpleNamespace

import pytest

from jrbar.provider_reset_events import (
    ResetDeliverySettings,
    ResetDeliveryState,
    begin_reset_delivery,
    decode_reset_delivery_state,
    encode_reset_delivery_state,
    with_reset_candidates,
)
from jrbar.provider_usage_platform import (
    ProviderSourceState,
    ProviderUsageSnapshot,
    UsageLane,
)
from jrbar.provider_usage_qol import (
    RESET_TRIGGER_JUMP,
    RESET_TRIGGER_LAPSED,
    RESET_TRIGGER_TIMING,
    confirm_reset_events,
    detect_reset_events,
)
from jrbar.usage_event_hooks import detect_usage_hook_events

pytestmark = pytest.mark.usefixtures("fake_keychain_metadata")


WEEK = 7 * 86400.0
T0 = 1_790_000_000.0
ACCOUNT = "claude-account-reset-fixture"


def lane(
    remaining: float,
    reset_at: float,
    *,
    lane_id: str = "weekly",
    source_id: str = "claude-oauth",
) -> UsageLane:
    return UsageLane(
        provider_id="claude",
        lane_id=lane_id,
        label="Weekly",
        remaining_percent=remaining,
        reset_at=reset_at,
        scope="all",
        model=None,
        feature=None,
        bindable=True,
        source_id=source_id,
    )


def read(
    observed_at: float,
    *lanes: UsageLane,
    state=ProviderSourceState.READY,
    account_label: str | None = None,
    account_discriminator: str | None = ACCOUNT,
) -> ProviderUsageSnapshot:
    return ProviderUsageSnapshot(
        provider_id="claude",
        account_label=account_label,
        observed_at=observed_at,
        state=state,
        reason_code=None if state is ProviderSourceState.READY else "network_unavailable",
        action_label=None if state is ProviderSourceState.READY else "Retry",
        lanes=tuple(lanes),
        input_tokens=0,
        cached_input_tokens=0,
        output_tokens=0,
        model_count=0,
        estimated_cost_usd=None,
        cache_savings_usd=None,
        credits_remaining=None,
        incident=None,
        account_discriminator=account_discriminator,
    )


def step(before, after, *, candidates=(), seen=frozenset()):
    detected = detect_reset_events((before,), (after,), seen_event_ids=seen)
    return confirm_reset_events(detected, (after,), candidates=candidates, seen_event_ids=seen)


@pytest.mark.parametrize("before,peak,resumed", [(95, 100, 99), (80, 100, 97),
                                                (50, 100, 97), (80, 99, 97)])
def test_refill_survives_immediate_consumption(before, peak, resumed):
    initial = read(T0, lane(before, T0 + 3 * 86400))
    refill = read(T0 + 120, lane(peak, T0 + 120 + WEEK))
    first = step(initial, refill)
    assert len(first.candidates) == 1
    result = step(refill, read(T0 + 240, lane(resumed, T0 + 120 + WEEK)),
                  candidates=first.candidates)
    assert len(result.events) == 1
    assert result.candidates == ()


def test_a_timing_reset_fires_at_once() -> None:
    boundary = T0 + 100
    before = read(T0, lane(12.0, boundary))
    after = read(T0 + 200, lane(96.0, boundary + WEEK))

    result = step(before, after)

    assert [event.trigger for event in result.events] == [RESET_TRIGGER_TIMING]
    assert result.candidates == ()


@pytest.mark.parametrize("old_delay,new_delay", [(0.0, 15.0), (0.25, 15.25), (15.0, 30.0)])
@pytest.mark.parametrize("remaining", [96.0, 100.0])
def test_provider_boundary_lag_is_timing(old_delay, new_delay, remaining):
    boundary = T0 + 100
    before = read(boundary + old_delay, lane(12.0, boundary))
    after = read(boundary + new_delay, lane(remaining, boundary + WEEK))
    result = step(before, after)
    assert [event.trigger for event in result.events] == [RESET_TRIGGER_TIMING]
    assert result.candidates == ()


@pytest.mark.parametrize("old_delay,new_delay", [(0.0, 30.001), (31.0, 45.0), (15.0, 14.0)])
def test_provider_boundary_lag_is_bounded_and_ordered(old_delay, new_delay):
    boundary = T0 + 100
    result = step(read(boundary + old_delay, lane(12.0, boundary)),
                  read(boundary + new_delay, lane(96.0, boundary + WEEK)))
    assert result.events == ()


@pytest.mark.parametrize("remaining,new_boundary", [(12.0, T0 + WEEK), (96.0, T0 + 100), (100.0, T0 + WEEK)])
def test_boundary_lag_keeps_replenishment_and_unused_guards(remaining, new_boundary):
    boundary = T0 + 100
    old_remaining = 100.0 if remaining == 100.0 else 12.0
    result = step(read(boundary, lane(old_remaining, boundary)),
                  read(boundary + 15, lane(remaining, new_boundary)))
    assert result.events == ()
    assert result.candidates == ()


@pytest.mark.parametrize("provider", ["claude", "grok"])
@pytest.mark.parametrize("account", [None, "another-account"])
def test_boundary_lag_requires_same_known_account(provider, account):
    boundary = T0 + 100
    before = replace(read(boundary), provider_id=provider,
                     lanes=(replace(lane(12.0, boundary), provider_id=provider),))
    after = replace(read(boundary + 15, account_discriminator=account), provider_id=provider,
                    lanes=(replace(lane(96.0, boundary + WEEK), provider_id=provider),))
    result = step(before, after)
    assert result.events == ()
    assert result.candidates == ()


@pytest.mark.parametrize("change", ["source", "instance"])
def test_boundary_lag_requires_same_source_and_instance(change):
    boundary = T0 + 100
    before = read(boundary, lane(12.0, boundary))
    after = read(boundary + 15, lane(96.0, boundary + WEEK,
                                   source_id="other-source" if change == "source" else "claude-oauth"))
    if change == "instance":
        after = replace(after, source_instance_id="other-instance")
    result = step(before, after)
    assert result.events == ()
    assert result.candidates == ()


def test_boundary_lag_accepts_small_full_refill():
    boundary = T0 + 100
    result = step(read(boundary, lane(97.0, boundary)),
                  read(boundary + 15, lane(100.0, boundary + WEEK)))
    assert [event.trigger for event in result.events] == [RESET_TRIGGER_TIMING]
    assert result.candidates == ()


def test_boundary_lag_does_not_promote_an_advanced_but_expired_window():
    boundary = T0 + 100
    result = step(read(boundary, lane(12.0, boundary)),
                  read(boundary + 15, lane(96.0, boundary + 1)))
    assert result.events == ()


def test_a_jump_then_a_confirming_read_gives_exactly_one_event() -> None:
    # The boundary is still in the future on our clock: a jump, not timing.
    before = read(T0, lane(10.0, T0 + 3 * 86400))
    jumped = read(T0 + 120, lane(100.0, T0 + 120 + WEEK - 30))

    first = step(before, jumped)
    assert first.events == ()
    assert len(first.candidates) == 1

    # Too soon to confirm: still waiting, still no event.
    early = read(T0 + 150, lane(99.0, T0 + 120 + WEEK - 30))
    waiting = step(jumped, early, candidates=first.candidates)
    assert waiting.events == ()
    assert waiting.candidates == first.candidates

    confirm = read(T0 + 120 + 300, lane(97.0, T0 + 120 + WEEK - 30))
    second = step(early, confirm, candidates=waiting.candidates)
    assert [event.trigger for event in second.events] == [RESET_TRIGGER_JUMP]
    assert second.events[0].event_id == first.candidates[0].event_id
    assert second.candidates == ()

    # And never again.
    later = read(T0 + 900, lane(95.0, T0 + 120 + WEEK - 30))
    assert step(confirm, later, candidates=second.candidates).events == ()


def test_an_early_weekly_reset_with_a_smaller_refill_is_confirmed() -> None:
    scheduled = T0 + 3 * 86400
    before = read(T0, lane(40.0, scheduled))
    reset = read(T0 + 120, lane(75.0, T0 + 120 + WEEK))

    first = step(before, reset)
    assert first.events == ()
    assert len(first.candidates) == 1
    restored = decode_reset_delivery_state(
        encode_reset_delivery_state(
            with_reset_candidates(ResetDeliveryState(), first.candidates)
        )
    )

    confirm = read(T0 + 240, lane(73.0, T0 + 120 + WEEK))
    second = step(reset, confirm, candidates=restored.candidates)

    assert len(second.events) == 1
    assert second.events[0].lane_id == "weekly"
    assert second.candidates == ()


def test_an_early_weekly_full_refill_below_five_points_is_confirmed() -> None:
    scheduled = T0 + 3 * 86400
    before = read(T0, lane(97.0, scheduled))
    reset = read(T0 + 120, lane(100.0, T0 + 120 + WEEK))

    first = step(before, reset)
    assert first.events == ()
    assert len(first.candidates) == 1

    rolled = read(T0 + 240, lane(100.0, T0 + 240 + WEEK))
    rolling_result = step(reset, rolled, candidates=first.candidates)
    assert rolling_result.events == ()
    assert rolling_result.candidates == ()

    fell_back = read(T0 + 240, lane(97.5, scheduled))
    transient_result = step(reset, fell_back, candidates=first.candidates)
    assert transient_result.events == ()
    assert transient_result.candidates == ()

    confirm = read(T0 + 240, lane(99.5, T0 + 120 + WEEK))
    second = step(reset, confirm, candidates=first.candidates)

    assert len(second.events) == 1
    assert second.events[0].lane_id == "weekly"
    assert second.candidates == ()


def test_an_early_weekly_candidate_rejects_unrelated_changes() -> None:
    scheduled = T0 + 3 * 86400

    stale = read(T0, lane(40.0, scheduled), state=ProviderSourceState.STALE)
    ready = read(T0 + 120, lane(75.0, T0 + 120 + WEEK))
    assert step(stale, ready).candidates == ()

    changed_source = read(
        T0 + 120,
        lane(75.0, T0 + 120 + WEEK, source_id="replacement-source"),
    )
    before = read(T0, lane(40.0, scheduled), account_label="original-account")
    assert step(before, changed_source).candidates == ()

    changed_account = read(
        T0 + 120,
        lane(75.0, T0 + 120 + WEEK),
        account_label="replacement-account",
    )
    assert step(before, changed_account).candidates == ()

    short_window = read(
        T0 + 120,
        lane(75.0, T0 + 120 + WEEK, lane_id="five-hour"),
    )
    short_before = read(T0, lane(40.0, scheduled, lane_id="five-hour"))
    assert step(short_before, short_window).candidates == ()


def test_a_large_refill_rejects_account_and_source_switches() -> None:
    scheduled = T0 + 3 * 86400
    before = read(
        T0,
        lane(10.0, scheduled),
        account_label="original-account",
    )

    changed_source = read(
        T0 + 120,
        lane(100.0, T0 + 120 + WEEK, source_id="replacement-source"),
        account_label="original-account",
    )
    assert step(before, changed_source).candidates == ()

    changed_account = read(
        T0 + 120,
        lane(100.0, T0 + 120 + WEEK),
        account_label="replacement-account",
    )
    assert step(before, changed_account).candidates == ()

    unnamed = read(T0, lane(10.0, scheduled))
    newly_named = read(
        T0 + 120,
        lane(100.0, T0 + 120 + WEEK),
        account_label="named-account",
    )
    assert step(unnamed, newly_named).candidates == ()

    unidentified = read(
        T0 + 120,
        lane(100.0, T0 + 120 + WEEK),
        account_discriminator=None,
    )
    assert step(read(T0, lane(10.0, scheduled)), unidentified).candidates == ()

    switched_identity = read(
        T0 + 120,
        lane(100.0, T0 + 120 + WEEK),
        account_discriminator="claude-account-replacement",
    )
    assert step(read(T0, lane(10.0, scheduled)), switched_identity).candidates == ()


def test_a_transient_early_weekly_increase_is_not_confirmed() -> None:
    scheduled = T0 + 3 * 86400
    before = read(T0, lane(40.0, scheduled))
    raised = read(T0 + 120, lane(75.0, T0 + 120 + WEEK))
    first = step(before, raised)
    assert len(first.candidates) == 1

    fell_back = read(T0 + 240, lane(41.0, scheduled))
    result = step(raised, fell_back, candidates=first.candidates)

    assert result.events == ()
    assert result.candidates == ()


def test_a_jump_that_the_next_read_contradicts_is_dropped() -> None:
    before = read(T0, lane(10.0, T0 + 3 * 86400))
    jumped = read(T0 + 120, lane(100.0, T0 + 120 + WEEK))
    first = step(before, jumped)

    # The odd read was wrong: the old window is back.
    back = read(T0 + 400, lane(11.0, T0 + 3 * 86400))
    result = step(jumped, back, candidates=first.candidates)

    assert result.events == ()
    assert result.candidates == ()


def test_a_confirmation_with_a_different_reset_time_is_dropped() -> None:
    before = read(T0, lane(10.0, T0 + 3 * 86400))
    jumped = read(T0 + 120, lane(100.0, T0 + 120 + WEEK))
    first = step(before, jumped)

    elsewhere = read(T0 + 400, lane(100.0, T0 + 120 + WEEK + 3600))
    result = step(jumped, elsewhere, candidates=first.candidates)

    assert result.events == ()
    assert result.candidates == ()


def test_a_confirmation_after_the_half_hour_still_counts_inside_the_day() -> None:
    """A laptop that slept through the half hour the confirming read is
    asked for must not lose the reset: the late read shows the same
    replenishment and the same boundary, so it confirms, stamped now."""
    before = read(T0, lane(10.0, T0 + 3 * 86400))
    jumped = read(T0 + 120, lane(100.0, T0 + 120 + WEEK))
    first = step(before, jumped)

    late = read(T0 + 120 + 1801, lane(98.0, T0 + 120 + WEEK))
    result = step(jumped, late, candidates=first.candidates)

    assert [event.trigger for event in result.events] == [RESET_TRIGGER_JUMP]
    assert result.events[0].event_id == first.candidates[0].event_id
    assert result.events[0].occurred_at == late.observed_at
    assert result.candidates == ()


def test_a_confirmation_after_a_day_is_dropped() -> None:
    from jrbar.provider_usage_qol import RESET_CANDIDATE_LIFETIME_S

    before = read(T0, lane(10.0, T0 + 3 * 86400))
    jumped = read(T0 + 120, lane(100.0, T0 + 120 + WEEK))
    first = step(before, jumped)

    ancient = read(
        T0 + 120 + RESET_CANDIDATE_LIFETIME_S + 1, lane(98.0, T0 + 120 + WEEK)
    )
    result = step(jumped, ancient, candidates=first.candidates)

    assert result.events == ()
    assert result.candidates == ()


def test_a_reset_seen_after_the_old_window_was_quoted_past_its_boundary_is_confirmed() -> None:
    """2026-10-06: Claude's weekly boundary passed at 11:00, but the source
    kept quoting the ended window (6% left, boundary in the past) until the
    next message opened a new one, seven hours later. The boundary was not
    BETWEEN the two reads, and a refill under 50 points is no jump, so a
    reset that did not start from near-empty was never seen at all."""
    boundary = T0 - 7 * 3600
    # The last read before the new window still quotes the ended one.
    quoted = read(T0, lane(60.0, boundary))
    refilled = read(T0 + 120, lane(100.0, T0 + 120 + WEEK - 30))

    first = step(quoted, refilled)
    assert first.events == ()
    assert [candidate.trigger for candidate in first.candidates] == [RESET_TRIGGER_LAPSED]

    confirm = read(T0 + 120 + 300, lane(97.0, T0 + 120 + WEEK - 30))
    second = step(refilled, confirm, candidates=first.candidates)
    assert [event.trigger for event in second.events] == [RESET_TRIGGER_LAPSED]
    assert second.events[0].reset_boundary == boundary
    assert second.candidates == ()

    # A stale read the daemon re-stamped as new is the same ended window.
    restamped = read(T0, lane(60.0, boundary), state=ProviderSourceState.STALE)
    assert len(step(restamped, refilled).candidates) == 1


def test_a_lapsed_window_that_barely_moves_or_comes_back_is_not_a_reset() -> None:
    boundary = T0 - 7 * 3600
    quoted = read(T0, lane(60.0, boundary))

    # A small rise is drift, and a window that opened full is nearly full.
    nudged = read(T0 + 120, lane(63.0, T0 + 120 + WEEK))
    assert step(quoted, nudged).candidates == ()
    halfway = read(T0 + 120, lane(85.0, T0 + 120 + WEEK))
    assert step(quoted, halfway).candidates == ()

    # A confirming read that gives the refill back contradicts it.
    refilled = read(T0 + 120, lane(100.0, T0 + 120 + WEEK))
    first = step(quoted, refilled)
    assert len(first.candidates) == 1
    back = read(T0 + 400, lane(61.0, boundary))
    result = step(refilled, back, candidates=first.candidates)
    assert result.events == () and result.candidates == ()


def test_a_rolling_unused_weekly_window_is_never_a_reset() -> None:
    """Nobody has started the week, so the provider quotes "now + 7 days"
    on every read: the reset time moves with the clock (CodexBar #3851)."""
    before = read(T0, lane(10.0, T0 + 3 * 86400))
    first_read = read(T0 + 120, lane(100.0, T0 + 120 + WEEK))
    first = step(before, first_read)
    assert len(first.candidates) == 1

    rolled = read(T0 + 220, lane(100.0, T0 + 220 + WEEK))
    result = step(first_read, rolled, candidates=first.candidates)

    assert result.events == ()
    assert result.candidates == ()
    # Two unused reads in a row never rise, so they never start a candidate.
    assert step(first_read, rolled).candidates == ()


def test_a_degraded_read_keeps_the_candidate_waiting() -> None:
    before = read(T0, lane(10.0, T0 + 3 * 86400))
    jumped = read(T0 + 120, lane(100.0, T0 + 120 + WEEK))
    first = step(before, jumped)

    offline = read(T0 + 200, state=ProviderSourceState.UNAVAILABLE)
    result = confirm_reset_events((), (offline,), candidates=first.candidates)

    assert result.events == ()
    assert result.candidates == first.candidates


def test_the_hook_the_celebration_and_the_wire_event_share_one_event_id() -> None:
    from jrbar.provider_usage_status_bar import _publish_reset_wire_events

    boundary = T0 + 100
    before = read(T0, lane(12.0, boundary))
    after = read(T0 + 200, lane(96.0, boundary + WEEK))
    [event] = step(before, after).events

    celebration = begin_reset_delivery(
        ResetDeliveryState(), event, ResetDeliverySettings(), now=T0 + 200
    )
    hooks = detect_usage_hook_events((before,), (after,), thresholds={}, reset_events=(event,))
    sent: list[tuple[str, dict]] = []
    _publish_reset_wire_events(
        SimpleNamespace(_core_publish_event=lambda kind, **fields: sent.append((kind, fields))),
        (event,),
    )

    assert celebration.events[0].event_id == event.event_id
    # The move from 12 % to 96 % is also a usage_updated; the one reset
    # the hooks see is the confirmed one, with its id.
    resets = [hook for hook in hooks if hook.name == "quota_reset"]
    assert [hook.event_id for hook in resets] == [event.event_id]
    assert sent[0][1]["event_id"] == event.event_id


def test_a_restart_mid_candidate_neither_drops_nor_repeats_it() -> None:
    before = read(T0, lane(10.0, T0 + 3 * 86400))
    jumped = read(T0 + 120, lane(100.0, T0 + 120 + WEEK))
    first = step(before, jumped)

    saved = encode_reset_delivery_state(with_reset_candidates(ResetDeliveryState(), first.candidates))
    restored = decode_reset_delivery_state(saved)
    assert restored.candidates == first.candidates

    # After the restart there is no edge baseline: the first read only
    # confirms the saved candidate.
    confirm = read(T0 + 500, lane(98.0, T0 + 120 + WEEK))
    result = confirm_reset_events((), (confirm,), candidates=restored.candidates)
    assert len(result.events) == 1
    delivered = begin_reset_delivery(restored, result.events[0], ResetDeliverySettings(), now=T0 + 500)
    delivered = with_reset_candidates(delivered, result.candidates)
    assert delivered.candidates == ()

    # Another restart, another read: the delivered event is seen, so no repeat.
    again = decode_reset_delivery_state(encode_reset_delivery_state(delivered))
    seen = frozenset(event.event_id for event in again.events)
    replay = confirm_reset_events((), (confirm,), candidates=again.candidates, seen_event_ids=seen)
    assert replay.events == ()


def test_a_file_from_before_candidates_still_decodes() -> None:
    legacy = '{"events":[],"version":1}'
    assert decode_reset_delivery_state(legacy) == ResetDeliveryState()
    broken = '{"events":[],"version":1,"candidates":[{"event_id":"x"}]}'
    assert decode_reset_delivery_state(broken).candidates == ()


# --- The confirming read has to happen (review fix) ---------------------------


def test_a_waiting_jump_brings_the_next_read_inside_the_confirmation_window() -> None:
    from jrbar.adaptive_refresh import (
        RESET_WATCH_INTERVAL_SECONDS,
        AdaptiveRefreshReason,
        plan_adaptive_refresh_cadence,
    )

    idle = plan_adaptive_refresh_cadence((), observed_at=T0)
    assert idle.interval_seconds == 1800.0
    waiting = plan_adaptive_refresh_cadence((), observed_at=T0, reset_confirm_until=T0 + 1800)
    assert waiting.reason is AdaptiveRefreshReason.RESET_CONFIRM
    assert waiting.interval_seconds == RESET_WATCH_INTERVAL_SECONDS
    # Low Power Mode still takes the one confirming read.
    constrained = plan_adaptive_refresh_cadence(
        (), observed_at=T0, constrained=True, reset_confirm_until=T0 + 1800
    )
    assert constrained.interval_seconds == RESET_WATCH_INTERVAL_SECONDS
    assert constrained.constrained is True
    # Once the window has closed there is nothing left to confirm.
    closed = plan_adaptive_refresh_cadence((), observed_at=T0 + 1801, reset_confirm_until=T0 + 1800)
    assert closed.reason is AdaptiveRefreshReason.IDLE


def test_a_jump_read_at_the_idle_cadence_is_still_confirmed(tmp_path) -> None:
    """The idle cadence and the confirmation window are both half an hour,
    so the read after a jump used to land just past the window and the
    reset was never announced. A waiting jump now asks for its read."""
    from jrbar.adaptive_refresh import AdaptiveRefreshReason
    from jrbar.provider_usage_qol import RESET_CONFIRM_MAX_S, reset_confirm_deadline
    from jrbar.provider_usage_runtime import ProviderUsageService
    from jrbar.provider_usage_settings import default_provider_usage_settings

    clock = [T0]
    current = {"read": read(T0, lane(10.0, T0 + 3 * 86400))}
    service = ProviderUsageService(
        settings_loader=default_provider_usage_settings,
        credentials=object(),
        home=tmp_path,
        clock=lambda: clock[0],
        collectors={"claude": lambda _preference, _home, _now, _credentials: current["read"]},
        incident_lookup=lambda _provider, _now: None,
    )
    service.refresh_now(providers=("claude",))
    before = current["read"]
    assert service.snapshot().next_refresh_at == T0 + 1800

    # The next read comes at the idle cadence and shows a jump.
    clock[0] = service.snapshot().next_refresh_at
    boundary = clock[0] + WEEK
    current["read"] = read(clock[0], lane(100.0, boundary))
    service.refresh_now(providers=("claude",))
    jumped = current["read"]
    first = step(before, jumped)
    assert first.events == () and len(first.candidates) == 1

    service.note_reset_candidates(reset_confirm_deadline(first.candidates))
    assert service.cadence_plan().reason is AdaptiveRefreshReason.RESET_CONFIRM
    due = service.snapshot().next_refresh_at
    assert 60.0 <= due - jumped.observed_at <= 120.0 < RESET_CONFIRM_MAX_S

    clock[0] = due
    confirm = read(clock[0], lane(99.0, boundary))
    second = step(jumped, confirm, candidates=first.candidates)
    assert [event.trigger for event in second.events] == [RESET_TRIGGER_JUMP]

    # Nothing waiting: the cadence goes back to idle on the next read.
    service.note_reset_candidates(reset_confirm_deadline(second.candidates))
    current["read"] = confirm
    service.refresh_now(providers=("claude",))
    assert service.cadence_plan().reason is AdaptiveRefreshReason.IDLE


def test_a_tick_before_the_first_reading_keeps_the_saved_candidates(tmp_path, monkeypatch) -> None:
    """refresh_ delivers pending resets before the first usage reading
    lands. It must read the saved state, not start an empty one and save
    it over the candidates."""
    import jrbar.provider_usage_event_store as store
    from jrbar.provider_reset_settings_action import (
        deliver_pending_reset_events,
        reset_delivery_state,
    )

    path = tmp_path / "provider-reset-events.json"
    monkeypatch.setattr(store, "default_reset_event_store_path", lambda: path)
    before = read(T0, lane(10.0, T0 + 3 * 86400))
    jumped = read(T0 + 120, lane(100.0, T0 + 120 + WEEK))
    first = step(before, jumped)
    store.save_reset_delivery_state(with_reset_candidates(ResetDeliveryState(), first.candidates), path)

    persisted: list[bool] = []
    controller = SimpleNamespace(
        _persist_reset_delivery_state=lambda: persisted.append(True),
        _schedule_reset_delivery_retry=lambda _now: None,
    )
    deliver_pending_reset_events(controller, legacy=SimpleNamespace(log_status_bar=lambda _line: None))

    assert controller._jrbar_reset_delivery_state.candidates == first.candidates
    assert reset_delivery_state(controller) is controller._jrbar_reset_delivery_state
    assert persisted == [], "nothing changed, so nothing is saved over the file"
    assert store.load_reset_delivery_state(path).candidates == first.candidates


def test_the_usage_apply_reads_the_same_state_and_asks_for_the_confirming_read() -> None:
    import ast
    from pathlib import Path

    source = Path(__file__).resolve().parents[1] / "src" / "jrbar" / "provider_usage_status_bar.py"
    tree = ast.parse(source.read_text(encoding="utf-8"))
    apply = next(
        node for node in ast.walk(tree)
        if isinstance(node, ast.FunctionDef) and node.name == "applyProviderUsageState_"
    )
    called = {
        node.func.id if isinstance(node.func, ast.Name) else getattr(node.func, "attr", None)
        for node in ast.walk(apply)
        if isinstance(node, ast.Call)
    }
    assert {"reset_delivery_state", "note_reset_candidates", "confirm_reset_events"} <= called
    assert "load_reset_delivery_state" not in called


@pytest.mark.parametrize("change", ["source", "account_label"])
def test_confirmation_rejects_changed_source_or_account_label(change):
    scheduled = T0 + 3 * 86400
    before = read(T0, lane(10.0, scheduled), account_label="synthetic-original")
    raised = read(T0 + 120, lane(100.0, T0 + 120 + WEEK), account_label="synthetic-original")
    first = step(before, raised)
    assert len(first.candidates) == 1
    restored = decode_reset_delivery_state(encode_reset_delivery_state(
        with_reset_candidates(ResetDeliveryState(), first.candidates)))
    confirming = read(
        T0 + 240,
        lane(100.0, T0 + 120 + WEEK,
             source_id="synthetic-replacement" if change == "source" else "claude-oauth"),
        account_label="synthetic-replacement" if change == "account_label" else "synthetic-original",
    )
    result = step(raised, confirming, candidates=restored.candidates)
    assert result.events == ()
    assert result.candidates == ()


@pytest.mark.parametrize("provider", ["cursor", "devin", "gemini", "antigravity", "opencode", "factory", "kimi", "kilo"])
def test_every_provider_rejects_a_changed_account_discriminator(provider):
    def snapshot(at, remaining, boundary, account):
        return replace(read(at, lane(remaining, boundary)), provider_id=provider,
                       account_discriminator=account,
                       lanes=(replace(lane(remaining, boundary), provider_id=provider),))
    result = step(snapshot(T0, 10.0, T0 + 100, "synthetic-first"),
                  snapshot(T0 + 200, 100.0, T0 + WEEK, "synthetic-second"))
    assert result.events == ()
    assert result.candidates == ()


def test_persisted_candidate_without_source_evidence_is_discarded():
    first = step(read(T0, lane(10.0, T0 + 3 * 86400)),
                 read(T0 + 120, lane(100.0, T0 + 120 + WEEK)))
    raw = json.loads(encode_reset_delivery_state(with_reset_candidates(ResetDeliveryState(), first.candidates)))
    for item in raw["candidates"]:
        item.pop("source_id", None)
        item.pop("account_label", None)
    assert decode_reset_delivery_state(json.dumps(raw)).candidates == ()
