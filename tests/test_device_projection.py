from __future__ import annotations

from datetime import datetime, timedelta, timezone

from jrbar.attention import AttentionProjection, LifecycleMode, ProjectedAgentRow
from jrbar.device_projection import light_rows_for_provider, projection_for_provider
from jrbar.models import AgentMode, AgentStatus

_NOW = datetime(2026, 8, 15, 12, 0, tzinfo=timezone.utc)


def _row(
    agent_id: str,
    provider: str,
    lifecycle: LifecycleMode = LifecycleMode.ACTIVE,
    *,
    worker: bool = False,
    updated_at: datetime = _NOW,
) -> ProjectedAgentRow:
    return ProjectedAgentRow(
        agent_id=agent_id,
        provider=provider,
        display_name=agent_id,
        lifecycle_mode=lifecycle,
        actionable=False,
        is_subagent=worker,
        updated_at=updated_at,
        source_status=AgentStatus(provider, agent_id, agent_id, AgentMode.WORKING, updated_at, "PreToolUse"),
    )


def _projection() -> AttentionProjection:
    return AttentionProjection(
        lifecycle_mode=LifecycleMode.ACTIVE,
        actionable_attention=(),
        visible_rows=(
            _row("codex:session:main", "codex"),
            _row("claude:session:main", "claude", LifecycleMode.WAITING),
        ),
        worker_rows=(
            _row("codex:agent:worker", "codex", worker=True),
            _row("claude:agent:worker", "claude", worker=True),
        ),
        transient_signals=(),
        dominant_provider="codex",
        click_target_agent_id=None,
    )


def test_provider_pin_filters_main_and_worker_rows__and_2_more() -> None:
    # --- scenario: provider_pin_filters_main_and_worker_rows
    projection = projection_for_provider(_projection(), "claude")

    assert tuple(row.agent_id for row in projection.visible_rows) == ("claude:session:main",)
    assert tuple(row.agent_id for row in projection.worker_rows) == ("claude:agent:worker",)
    assert projection.lifecycle_mode is LifecycleMode.WAITING
    assert projection.dominant_provider == "claude"

    # --- scenario: unpinned_projection_preserves_the_canonical_projection
    original = _projection()

    assert projection_for_provider(original, None) is original

    # --- scenario: actionable_attention_bypasses_provider_pin
    row = _row("codex:session:ask", "codex", LifecycleMode.WAITING)
    original = AttentionProjection(
        lifecycle_mode=LifecycleMode.WAITING,
        actionable_attention=(row,),
        visible_rows=(row,),
        transient_signals=(),
        dominant_provider="codex",
        click_target_agent_id=row.agent_id,
    )

    assert projection_for_provider(original, "claude") is original



def test_pin_without_matching_rows_returns_idle_projection__and_2_more() -> None:
    # --- scenario: pin_without_matching_rows_returns_idle_projection
    projection = projection_for_provider(_projection(), "gemini")

    assert projection.lifecycle_mode is LifecycleMode.IDLE
    assert projection.visible_rows == ()
    assert projection.worker_rows == ()
    assert projection.dominant_provider is None
    assert projection.click_target_agent_id is None

    # --- scenario: a_provider_pin_never_grants_an_unlinked_worker_a_share
    projection = AttentionProjection(
        lifecycle_mode=LifecycleMode.WAITING,
        actionable_attention=(),
        visible_rows=(),
        worker_rows=(
            _row("codex:agent:worker", "codex", LifecycleMode.WAITING, worker=True),
            _row(
                "claude:agent:worker",
                "claude",
                LifecycleMode.ACTIVE,
                worker=True,
                updated_at=_NOW - timedelta(seconds=1),
            ),
        ),
        transient_signals=(),
        dominant_provider="codex",
        click_target_agent_id=None,
    )

    assert light_rows_for_provider(projection, "claude") == ()

    projected = projection_for_provider(projection, "claude")
    assert projected.visible_rows == ()
    assert tuple(row.agent_id for row in projected.worker_rows) == ("claude:agent:worker",)
    assert projected.light_rows == ()
    assert projected.lifecycle_mode is LifecycleMode.IDLE

    # --- scenario: projection_does_not_duplicate_orphan_worker_rows
    worker = _row("claude:agent:worker", "claude", worker=True)
    projection = AttentionProjection(
        lifecycle_mode=LifecycleMode.ACTIVE,
        actionable_attention=(),
        visible_rows=(),
        worker_rows=(worker,),
        transient_signals=(),
        dominant_provider="claude",
        click_target_agent_id=None,
    )

    projected = projection_for_provider(projection, "claude")

    assert projected.visible_rows == ()
    assert projected.worker_rows == (worker,)



def test_provider_pin_cannot_restore_a_retained_failure_signal():
    from dataclasses import replace
    row = _row('codex:session:root', 'codex', LifecycleMode.FAILED_VISIBLE)
    projected = replace(_projection(), visible_rows=(row,), worker_rows=())
    pinned = projection_for_provider(projected, 'codex')
    assert pinned.lifecycle_mode is LifecycleMode.IDLE
    assert all(item.lifecycle_mode is LifecycleMode.IDLE for item in pinned.light_rows)
