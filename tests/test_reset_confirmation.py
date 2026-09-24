"""One reset rule, with confirmation, shared by every consumer.

The celebrations and the ``quota_reset`` wire event used to fire on a
single odd reading, and the usage hook had its own jump rule, so a hook
could report a reset the confetti never saw and the other way round.
Now TIMING resets (the boundary passed on our clock) fire at once, and a
JUMP waits for a confirming read 60-1800 s later whose reset time matches
within two minutes.
"""

from __future__ import annotations

from types import SimpleNamespace

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
    RESET_TRIGGER_TIMING,
    confirm_reset_events,
    detect_reset_events,
)
from jrbar.usage_event_hooks import detect_usage_hook_events

WEEK = 7 * 86400.0
T0 = 1_790_000_000.0


def lane(remaining: float, reset_at: float, *, lane_id: str = "weekly") -> UsageLane:
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
        source_id="claude-oauth",
    )


def read(observed_at: float, *lanes: UsageLane, state=ProviderSourceState.READY) -> ProviderUsageSnapshot:
    return ProviderUsageSnapshot(
        provider_id="claude",
        account_label=None,
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
    )


def step(before, after, *, candidates=(), seen=frozenset()):
    detected = detect_reset_events((before,), (after,), seen_event_ids=seen)
    return confirm_reset_events(detected, (after,), candidates=candidates, seen_event_ids=seen)


def test_a_timing_reset_fires_at_once() -> None:
    boundary = T0 + 100
    before = read(T0, lane(12.0, boundary))
    after = read(T0 + 200, lane(96.0, boundary + WEEK))

    result = step(before, after)

    assert [event.trigger for event in result.events] == [RESET_TRIGGER_TIMING]
    assert result.candidates == ()


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


def test_a_confirmation_more_than_thirty_minutes_later_is_dropped() -> None:
    before = read(T0, lane(10.0, T0 + 3 * 86400))
    jumped = read(T0 + 120, lane(100.0, T0 + 120 + WEEK))
    first = step(before, jumped)

    stale = read(T0 + 120 + 1801, lane(98.0, T0 + 120 + WEEK))
    result = step(jumped, stale, candidates=first.candidates)

    assert result.events == ()
    assert result.candidates == ()


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
