from __future__ import annotations

from datetime import datetime, timedelta, timezone

from jrbar.capacity_types import SourceKey
from jrbar.completions import completion_events, detect_completion_batch
from jrbar.models import AgentMode, AgentStatus
from jrbar.operator_state import (
    CanonicalOperatorEvent,
    InterruptionClass,
    SemanticEventKey,
    TransitionKind,
)
from jrbar.provider_facts import (
    EventToken,
    ProviderWatermark,
    SourceFreshness,
    WatermarkBasis,
    WorkIdentifier,
    WorkKey,
)


def _status(
    agent_id: str,
    *,
    mode: AgentMode = AgentMode.COMPLETED,
    updated_at: datetime,
    event_name: str = "Stop",
) -> AgentStatus:
    provider = agent_id.split(":", 1)[0]
    return AgentStatus(
        provider=provider,
        agent_id=agent_id,
        display_name=agent_id,
        mode=mode,
        updated_at=updated_at,
        event_name=event_name,
        session_id="session-1",
    )


def test_same_poll_completions_have_stable_agent_order__and_2_more() -> None:
    # --- scenario: same_poll_completions_have_stable_agent_order
    now = datetime(2026, 8, 12, 12, 0, tzinfo=timezone.utc)
    previous = {
        "codex:session:a": AgentMode.WORKING,
        "claude:session:b": AgentMode.WAITING_FOR_INPUT,
    }
    a = _status("codex:session:a", updated_at=now)
    b = _status("claude:session:b", updated_at=now)

    forward = detect_completion_batch(previous, (b, a), now)
    reverse = detect_completion_batch(previous, (a, b), now)

    assert [status.agent_id for status in forward.statuses] == [
        "claude:session:b",
        "codex:session:a",
    ]
    assert reverse.statuses == forward.statuses

    # --- scenario: stale_and_future_completions_are_rejected
    now = datetime(2026, 8, 12, 12, 0, tzinfo=timezone.utc)
    previous = {
        "codex:session:stale": AgentMode.WORKING,
        "codex:session:future": AgentMode.WORKING,
    }
    stale = _status(
        "codex:session:stale",
        updated_at=now - timedelta(seconds=121),
    )
    future = _status(
        "codex:session:future",
        updated_at=now + timedelta(seconds=121),
    )

    batch = detect_completion_batch(previous, (stale, future), now)

    assert batch.statuses == ()

    # --- scenario: session_end_and_subagent_completions_are_rejected
    now = datetime(2026, 8, 12, 12, 0, tzinfo=timezone.utc)
    previous = {
        "codex:session:closed": AgentMode.WORKING,
        "claude:agent:worker": AgentMode.WORKING,
    }
    session_end = _status(
        "codex:session:closed",
        updated_at=now,
        event_name="SessionEnd",
    )
    subagent = _status("claude:agent:worker", updated_at=now)

    batch = detect_completion_batch(previous, (session_end, subagent), now)

    assert batch.statuses == ()



def test_warm_and_repeated_completed_snapshots_do_not_replay__and_2_more() -> None:
    # --- scenario: warm_and_repeated_completed_snapshots_do_not_replay
    now = datetime(2026, 8, 12, 12, 0, tzinfo=timezone.utc)
    completed = _status("codex:session:a", updated_at=now)

    warm = detect_completion_batch({}, (completed,), now)
    repeated = detect_completion_batch(
        {completed.agent_id: AgentMode.COMPLETED},
        (completed,),
        now,
    )

    assert warm.statuses == ()
    assert repeated.statuses == ()

    # --- scenario: only_active_to_completed_transitions_are_eligible
    now = datetime(2026, 8, 12, 12, 0, tzinfo=timezone.utc)
    previous = {
        "codex:session:active": AgentMode.TOOL_RUNNING,
        "codex:session:idle": AgentMode.IDLE_READY,
    }
    active = _status("codex:session:active", updated_at=now)
    idle = _status("codex:session:idle", updated_at=now)

    batch = detect_completion_batch(previous, (idle, active), now)

    assert [status.agent_id for status in batch.statuses] == [
        "codex:session:active"
    ]

    # --- scenario: active_to_usage_limit_failure_is_not_a_completion_notification
    now = datetime(2026, 8, 13, 12, 0, tzinfo=timezone.utc)
    failed = _status(
        "codex:session:limited",
        mode=AgentMode.BLOCKED_ERROR,
        updated_at=now,
        event_name="StopFailure",
    )

    batch = detect_completion_batch(
        {failed.agent_id: AgentMode.TOOL_RUNNING},
        (failed,),
        now,
    )

    assert batch.statuses == ()



def test_duplicate_current_rows_deliver_one_completion_per_agent__and_2_more() -> None:
    # --- scenario: duplicate_current_rows_deliver_one_completion_per_agent
    now = datetime(2026, 8, 12, 12, 0, tzinfo=timezone.utc)
    completed = _status("codex:session:a", updated_at=now)

    batch = detect_completion_batch(
        {completed.agent_id: AgentMode.WORKING},
        (completed, completed),
        now,
    )

    assert batch.statuses == (completed,)

    # --- scenario: newer_duplicate_active_row_suppresses_older_completed_row
    now = datetime(2026, 8, 12, 12, 0, tzinfo=timezone.utc)
    completed = _status(
        "codex:session:a",
        updated_at=now - timedelta(seconds=1),
    )
    active = _status(
        "codex:session:a",
        mode=AgentMode.WORKING,
        updated_at=now,
        event_name="PreToolUse",
    )

    batch = detect_completion_batch(
        {completed.agent_id: AgentMode.WORKING},
        (completed, active),
        now,
    )

    assert batch.statuses == ()

    # --- scenario: equal_timestamp_session_end_suppresses_stop_completion
    now = datetime(2026, 8, 12, 12, 0, tzinfo=timezone.utc)
    completed = _status("codex:session:a", updated_at=now)
    session_end = _status(
        "codex:session:a",
        updated_at=now,
        event_name="SessionEnd",
    )

    batch = detect_completion_batch(
        {completed.agent_id: AgentMode.WORKING},
        (session_end, completed),
        now,
    )

    assert batch.statuses == ()



def test_canonical_completion_selector_filters_exact_semantic_edges() -> None:
    source = SourceKey("codex", "hooks", "global", "live_agent_events")
    key = WorkKey(source, WorkIdentifier("work:done"))

    def event(kind: TransitionKind, sequence: int) -> CanonicalOperatorEvent:
        watermark = ProviderWatermark(
            source,
            WatermarkBasis.PROVIDER_SEQUENCE,
            1_786_632_000.0,
            EventToken(f"event:{sequence}"),
            sequence,
            10,
        )
        semantic = SemanticEventKey(key, kind, watermark)
        return CanonicalOperatorEvent(
            semantic,
            key,
            kind,
            (
                InterruptionClass.COURTESY
                if kind is TransitionKind.COMPLETED
                else InterruptionClass.IMPORTANT_OUTCOME
            ),
            watermark.occurred_at_epoch,
            SourceFreshness.FRESH,
        )

    failed = event(TransitionKind.FAILED, 1)
    completed = event(TransitionKind.COMPLETED, 2)

    assert completion_events((failed, completed, completed)) == (completed,)
