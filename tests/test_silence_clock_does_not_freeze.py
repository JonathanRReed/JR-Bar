"""Silence must be measured against a clock that keeps running.

Every age window here used ``state.last_clock.wall_epoch`` -- the moment
of the last observed event -- as "now". That reads like the real clock
while an agent is chattering, and FREEZES the instant everything goes
quiet: the window is measured against a clock that stops advancing
exactly when silence begins, so nothing can ever age out. Reported live
as "you ended, yet it still says agents are active and it's showing the
claude colors going across" -- a finished turn held its completion sweep
forever, because the only clock that could retire it was that turn's own
last event.

The existing silence tests all advanced the clock to simulate silence,
which is the one thing real silence never does. These pin the quiet case
for EVERY provider, since the freeze was provider-independent, and they
run the daemon's own path: the monitor's snapshot of the canonical state
at the monitor's clock, then project_attention.
"""

from __future__ import annotations

from datetime import datetime, timezone

from jrbar._collector_legacy import (
    COMPLETED_VISIBLE_SECONDS,
    IDLE_VISIBLE_SECONDS,
    POST_TOOL_WORKING_VISIBLE_SECONDS,
    RestoreHealth,
    _snapshot_from_operator_state,
)
from jrbar._settings_legacy import AgentMonitorSettings
from jrbar.attention import project_attention
from jrbar.capacity_types import SourceKey
from jrbar.mailbox import project_canonical_mailbox
from jrbar.operator_state import (
    ACTIVE_SILENCE_SECONDS,
    BootIdentifier,
    ClockSample,
    active_silence_seconds_for,
    empty_operator_state,
    reduce_operator_state,
)
from jrbar.provider_facts import (
    EventToken,
    NextActor,
    ObservationAuthority,
    ProviderFactBatch,
    ProviderWatermark,
    ProviderWorkFact,
    SourceFreshness,
    SourceHealth,
    WatermarkBasis,
    WorkIdentifier,
    WorkKey,
    WorkLifecycle,
    _expected_safe_label,
)
from jrbar.providers import PROVIDER_SPECS

LAST_EVENT_AT = 1_800_000_000.0

# Every registered provider, so this can never be a claude-only guarantee.
ALL_PROVIDERS = tuple(spec.provider for spec in PROVIDER_SPECS)


def state_that_went_quiet(provider: str, lifecycle: WorkLifecycle):
    """A work heard from at LAST_EVENT_AT, then total silence -- so the
    canonical clock never advances past that moment."""
    source = SourceKey(provider, "hooks", "global", "live_agent_events")
    watermark = ProviderWatermark(
        source_key=source,
        basis=WatermarkBasis.PROVIDER_EVENT_ID,
        occurred_at_epoch=LAST_EVENT_AT,
        event_token=EventToken("tok"),
        sequence=None,
        tie_break_rank=10,
    )
    batch = ProviderFactBatch(
        source_key=source,
        observation_authority=ObservationAuthority.DIRECT_PROVIDER_OBSERVATION,
        source_health=SourceHealth.HEALTHY,
        source_freshness=SourceFreshness.FRESH,
        observed_at_epoch=LAST_EVENT_AT,
        watermark=watermark,
        work_facts=(
            ProviderWorkFact(
                key=WorkKey(source, WorkIdentifier("session:x")),
                lifecycle=lifecycle,
                watermark=watermark,
                safe_label=_expected_safe_label(WorkKey(source, WorkIdentifier("session:x"))),
                parent_key=None,
                next_actor=(
                    NextActor.PROVIDER
                    if lifecycle is WorkLifecycle.ACTIVE
                    else NextActor.NONE
                ),
            ),
        ),
        request_facts=(),
        diagnostics=(),
    )
    return reduce_operator_state(
        empty_operator_state(),
        batch,
        # The clock stops here. Nothing arrives after this, which is
        # precisely what "the agent finished" looks like.
        clock=ClockSample(LAST_EVENT_AT, 100.0, BootIdentifier("boot:01")),
    ).state


def live_projection(state, seconds_after_last_event: float):
    """What the daemon's lights read: the monitor's snapshot of this
    canonical state, taken at the monitor's own clock (which keeps running
    through the silence), then project_attention."""
    snapshot = _snapshot_from_operator_state(
        state,
        events=(),
        sources=(),
        collected_at=datetime.fromtimestamp(
            LAST_EVENT_AT + seconds_after_last_event, timezone.utc
        ),
        restore_health=RestoreHealth.NOT_ATTEMPTED,
        stale_after_seconds=3600.0,
        tool_running_timeout_seconds=0.0,
        completed_visible_seconds=COMPLETED_VISIBLE_SECONDS,
        idle_visible_seconds=IDLE_VISIBLE_SECONDS,
        post_tool_working_visible_seconds=POST_TOOL_WORKING_VISIBLE_SECONDS,
        canonical_projected_uses_age_windows=True,
    )
    return project_attention(snapshot, AgentMonitorSettings())


def freeze_wall_clock(monkeypatch, seconds_after_last_event: float) -> None:
    monkeypatch.setattr(
        "jrbar.operator_state.time.time",
        lambda: LAST_EVENT_AT + seconds_after_last_event,
    )


def test_a_silent_active_work_stops_claiming_the_lights_and_being_counted(
    monkeypatch,
) -> None:
    for provider in ALL_PROVIDERS:
        state = state_that_went_quiet(provider, WorkLifecycle.ACTIVE)
        silent_for = active_silence_seconds_for(provider) + 60.0
        freeze_wall_clock(monkeypatch, silent_for)

        projection = live_projection(state, silent_for)
        assert all(
            row.lifecycle_mode.value != "active" for row in projection.visible_rows
        ), f"{provider}: the lights still claim a session that went quiet"
        assert project_canonical_mailbox(state).active_count == 0, (
            f"{provider}: still counted as working after going quiet"
        )


def test_a_finished_turn_does_not_hold_its_completion_forever__and_2_more(monkeypatch) -> None:
    # --- scenario: a_finished_turn_does_not_hold_its_completion_forever
    """The exact reported symptom: the completion sweep never retiring."""
    for provider in ALL_PROVIDERS:
        state = state_that_went_quiet(provider, WorkLifecycle.COMPLETED)

        projection = live_projection(state, 3_600.0)
        assert all(
            row.lifecycle_mode.value != "completed_recently"
            for row in projection.visible_rows
        ), f"{provider}: still showing 'just finished' an hour later"

    # --- scenario: work_still_inside_its_window_is_left_alone
    monkeypatch.undo()
    """The fix must not retire work that is merely between tool calls."""
    state = state_that_went_quiet("claude", WorkLifecycle.ACTIVE)

    projection = live_projection(state, ACTIVE_SILENCE_SECONDS - 30.0)
    assert any(row.lifecycle_mode.value == "active" for row in projection.visible_rows)

    # --- scenario: a_wall_clock_behind_the_evidence_cannot_rejuvenate_work
    monkeypatch.undo()
    """A machine whose clock sits behind the events (restore after sleep,
    a clock stepped backwards) must not make silent work look young."""
    state = state_that_went_quiet("claude", WorkLifecycle.COMPLETED)

    projection = live_projection(state, -86_400.0)
    # Evidence from a day "ahead" of the clock is implausible, so nothing
    # claims a fresh completion from it.
    assert all(row.lifecycle_mode.value != "completed_recently" for row in projection.visible_rows)
