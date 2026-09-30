from __future__ import annotations

from jrbar.provider_usage_platform import (
    ProviderSourceState,
    ProviderUsageSnapshot,
    UsageLane,
    most_constrained_lane,
    normalize_dynamic_lane,
    provider_descriptors,
    provider_status_line,
    select_authoritative_snapshot,
)


def _lane(
    *,
    provider: str = "claude",
    lane_id: str = "weekly",
    label: str = "Weekly",
    remaining: float = 40.0,
    reset: float = 2000.0,
    bindable: bool = True,
) -> UsageLane:
    return UsageLane(
        provider_id=provider,
        lane_id=lane_id,
        label=label,
        remaining_percent=remaining,
        reset_at=reset,
        scope="all",
        model=None,
        feature=None,
        bindable=bindable,
        source_id="official",
    )


def _snapshot(
    *,
    provider: str = "claude",
    state: ProviderSourceState = ProviderSourceState.READY,
    lanes: tuple[UsageLane, ...] = (),
    reason: str | None = None,
    action: str | None = None,
    observed: float = 1000.0,
    source_instance_id: str = "default",
) -> ProviderUsageSnapshot:
    return ProviderUsageSnapshot(
        provider_id=provider,
        account_label=None,
        observed_at=observed,
        state=state,
        reason_code=reason,
        action_label=action,
        lanes=lanes,
        input_tokens=0,
        cached_input_tokens=0,
        output_tokens=0,
        model_count=0,
        estimated_cost_usd=None,
        cache_savings_usd=None,
        credits_remaining=None,
        incident=None,
        source_instance_id=source_instance_id,
    )


def test_snapshot_preserves_source_instance_identity__and_2_more() -> None:
    # --- scenario: snapshot_preserves_source_instance_identity
    result = _snapshot(source_instance_id="personal")
    assert result.source_instance_id == "personal"

    # --- scenario: registry_has_all_native_providers_and_no_codexbar
    ids = tuple(descriptor.provider_id for descriptor in provider_descriptors())
    assert ids == (
        "codex",
        "claude",
        "cursor",
        "devin",
        "grok",
        "gemini",
        "antigravity",
        "opencode",
        "openai-api",
    )
    assert "codexbar" not in ids

    # --- scenario: registry_declares_ordered_source_ladders
    by_id = {descriptor.provider_id: descriptor for descriptor in provider_descriptors()}
    assert by_id["codex"].source_order[:2] == ("codex-auth", "codex-rollouts")
    assert by_id["claude"].source_order[:2] == ("claude-keychain", "claude-oauth")
    assert by_id["cursor"].supports_browser_sources is True
    assert by_id["devin"].supports_browser_sources is True



def test_dynamic_provider_lane_is_preserved_but_not_bindable__and_2_more() -> None:
    # --- scenario: dynamic_provider_lane_is_preserved_but_not_bindable
    result = normalize_dynamic_lane(
        provider_id="claude",
        lane_id="fable-weekly",
        label="Fable Weekly",
        remaining_percent=18,
        reset_at=5000,
        source_id="claude-oauth",
        known_lane_ids={"five-hour", "weekly"},
    )
    assert result.label == "Fable Weekly"
    assert result.bindable is False
    assert result.model == "fable"

    # --- scenario: actionable_failure_requires_action
    try:
        _snapshot(
            state=ProviderSourceState.NEEDS_CONSENT,
            reason="browser_consent_required",
            action=None,
        )
    except ValueError as exc:
        assert "action" in str(exc)
    else:
        raise AssertionError("permission-required snapshot accepted without an action")

    # --- scenario: first_ready_source_wins
    missing = _snapshot(
        state=ProviderSourceState.SOURCE_NOT_FOUND,
        reason="missing",
        action="Sign in",
    )
    ready = _snapshot(lanes=(_lane(),), observed=1100)
    later = _snapshot(lanes=(_lane(remaining=80),), observed=1200)

    merged = select_authoritative_snapshot((missing, ready, later))
    assert merged is ready



def test_last_known_good_is_retained_as_stale_when_sources_fail__and_2_more() -> None:
    # --- scenario: last_known_good_is_retained_as_stale_when_sources_fail
    previous = _snapshot(lanes=(_lane(remaining=21),), observed=900)
    failure = _snapshot(
        state=ProviderSourceState.UNAVAILABLE,
        reason="network",
        action="Retry",
        observed=1000,
    )
    merged = select_authoritative_snapshot((failure,), last_known_good=previous)
    assert merged.state is ProviderSourceState.STALE
    assert merged.lanes == previous.lanes
    assert merged.reason_code == "network"

    # --- scenario: a_retained_reading_keeps_the_time_it_was_read
    # The failed poll moves `observed_at` (the attempt), never `read_at`
    # (when the 21% was actually read), however many polls fail in a row.
    assert previous.read_at is None
    assert previous.effective_read_at == 900.0
    assert merged.observed_at == 1000.0
    assert merged.read_at == 900.0
    assert merged.effective_read_at == 900.0
    second_failure = _snapshot(
        state=ProviderSourceState.UNAVAILABLE,
        reason="network",
        action="Retry",
        observed=1100,
    )
    again = select_authoritative_snapshot((second_failure,), last_known_good=merged)
    assert again.state is ProviderSourceState.STALE
    assert again.observed_at == 1100.0
    assert again.read_at == 900.0

    # --- scenario: most_constrained_lane_ignores_detail_only_unknown_lanes
    known = _lane(lane_id="weekly", remaining=25, bindable=True)
    detail = _lane(lane_id="fable", remaining=5, bindable=False)
    result = most_constrained_lane(_snapshot(lanes=(known, detail)))
    assert result is known

    # --- scenario: source_failure_summary_is_specific
    result = _snapshot(
        provider="cursor",
        state=ProviderSourceState.NEEDS_CONSENT,
        reason="browser_consent_required",
        action="Enable Cursor browser access",
    )
    assert provider_status_line(result) == "Cursor · permission required"



def test_most_constrained_lane_skips_lapsed_lanes_only_when_given_a_clock() -> None:
    lapsed = _lane(lane_id="five_hour", remaining=3, reset=900.0)
    live = _lane(lane_id="weekly", remaining=60, reset=5000.0)
    snapshot = _snapshot(lanes=(lapsed, live))

    # No clock: the lapsed lane still answers, as it always did (the reset
    # watch needs it to time the next read).
    assert most_constrained_lane(snapshot) is lapsed
    # With a clock, a window that is already over is not a constraint.
    assert most_constrained_lane(snapshot, now=1000.0) is live
    # The boundary is strict: a lane resetting exactly now is over.
    assert most_constrained_lane(snapshot, now=900.0) is live
    assert most_constrained_lane(snapshot, now=899.0) is lapsed


def test_most_constrained_lane_is_none_when_every_lane_has_lapsed() -> None:
    first = _lane(lane_id="five_hour", remaining=3, reset=900.0)
    second = _lane(lane_id="weekly", remaining=60, reset=950.0)

    assert most_constrained_lane(_snapshot(lanes=(first, second)), now=1000.0) is None


def test_most_constrained_lane_treats_a_missing_reset_as_never_lapsed() -> None:
    open_ended = _lane(lane_id="credits", remaining=30, reset=None)  # type: ignore[arg-type]
    lapsed = _lane(lane_id="five_hour", remaining=3, reset=900.0)

    picked = most_constrained_lane(_snapshot(lanes=(open_ended, lapsed)), now=10**9)

    assert picked is open_ended


def test_most_constrained_lane_with_a_clock_still_ignores_detail_only_lanes() -> None:
    known = _lane(lane_id="weekly", remaining=25, bindable=True, reset=5000.0)
    detail = _lane(lane_id="fable", remaining=5, bindable=False, reset=5000.0)

    assert most_constrained_lane(_snapshot(lanes=(known, detail)), now=1000.0) is known


def test_read_at_is_a_finite_nonnegative_number_or_nothing() -> None:
    import dataclasses

    import pytest

    base = _snapshot(lanes=(_lane(),))
    assert dataclasses.replace(base, read_at=850).read_at == 850.0
    assert isinstance(dataclasses.replace(base, read_at=850).read_at, float)
    assert dataclasses.replace(base, read_at=0).read_at == 0.0
    # A clock step back must not make a snapshot unconstructible: a read
    # time after the attempt time is allowed here (the wire clamps it).
    assert dataclasses.replace(base, read_at=base.observed_at + 5).read_at == 1005.0
    for bad in (float("nan"), float("inf"), -1.0, True, "x"):
        with pytest.raises(ValueError):
            dataclasses.replace(base, read_at=bad)  # type: ignore[arg-type]


def test_a_live_reading_reports_its_own_time_as_the_read_time() -> None:
    live = _snapshot(lanes=(_lane(),), observed=1234.0)

    assert live.read_at is None
    assert live.effective_read_at == 1234.0
