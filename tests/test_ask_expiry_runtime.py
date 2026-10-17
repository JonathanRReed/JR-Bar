"""What the daemon does with an ask that expired, and with one that is stale.

The sweep (``test_ask_expiry``) ends the session; the controller then says so
in History, remembers that the end was the Mac's own, and keeps the stale ask
from earning escalation. The controller is the headless one the daemon runs.
"""

from __future__ import annotations

import time
from datetime import datetime, timedelta, timezone
from pathlib import Path
from types import SimpleNamespace

import pytest

from jrbar import process_registry
from jrbar.activity_ledger import ActivityKind
from jrbar.attention import AttentionProjection, LifecycleMode, ProjectedAgentRow
from jrbar.models import AgentMode, AgentStatus
from tests.test_core_runtime import cleared, headless  # noqa: F401


def _ask(agent_id: str, *, hours_ago: float) -> AgentStatus:
    return AgentStatus(
        provider="claude",
        agent_id=agent_id,
        display_name=agent_id.rsplit(":", 1)[-1],
        mode=AgentMode.WAITING_FOR_INPUT,
        updated_at=datetime.fromtimestamp(time.time(), timezone.utc) - timedelta(hours=hours_ago),
        event_name="PermissionRequest",
        session_id=agent_id.rsplit(":", 1)[-1],
    )


def test_an_expired_ask_is_written_to_history_and_remembered_as_the_macs_own_end(
    cleared,  # noqa: F811
    tmp_path: Path,
) -> None:
    controller = cleared
    controller.ask_dismissals_path = tmp_path / "dismissed-asks.json"
    expired = _ask("claude:session:forgotten", hours_ago=24 * 9)

    controller._record_expired_asks(SimpleNamespace(expired_asks=(expired,)))

    kinds = [entry.kind for entry in controller.activity_ledger.entries]
    assert kinds == [ActivityKind.EXPIRED]
    entry = controller.activity_ledger.entries[0]
    assert entry.subject_id == "claude:session:forgotten"
    # The row is dated when it expired, not when the ask was made.
    assert abs(entry.occurred_at_epoch - time.time()) < 60
    # What the app reads: a History row of kind ask_expired.
    reply = controller._core_dispatch("list_history", {})
    assert [row["kind"] for row in reply["rows"]] == ["ask_expired"]
    # Remembered, so its row reads ended and never the green check.
    assert controller.ask_dismissals.was_expired("claude", "forgotten")
    assert controller.ask_dismissals_path.exists()


def test_nothing_is_recorded_when_nothing_expired(cleared) -> None:  # noqa: F811
    controller = cleared
    controller._record_expired_asks(SimpleNamespace(expired_asks=()))
    assert controller.activity_ledger.entries == ()
    assert len(controller.ask_dismissals) == 0


def test_an_expired_session_row_reads_ended_not_done(cleared, monkeypatch: pytest.MonkeyPatch) -> None:  # noqa: F811
    controller = cleared
    monkeypatch.setattr(process_registry, "load_record", lambda provider, session_id: None)
    monkeypatch.setattr(process_registry, "pid_exists", lambda pid: False)
    controller._core_extras.clear()
    status = SimpleNamespace(
        agent_id="claude:session:forgotten",
        provider="claude",
        session_id="forgotten",
        event_name="SessionEnd",
        origin=None,
        updated_at=datetime.fromtimestamp(time.time(), timezone.utc),
    )
    assert controller._core_extras_for(status).provider_ended is None

    controller._core_extras.clear()
    controller._record_expired_asks(SimpleNamespace(expired_asks=(_ask("claude:session:forgotten", hours_ago=24 * 9),)))
    assert controller._core_extras_for(status).provider_ended is False


def _projection(*rows: ProjectedAgentRow) -> AttentionProjection:
    actionable = tuple(row for row in rows if row.actionable)
    return AttentionProjection(
        lifecycle_mode=LifecycleMode.WAITING,
        actionable_attention=actionable,
        visible_rows=rows,
        transient_signals=(),
        dominant_provider="claude",
        click_target_agent_id=actionable[0].agent_id if actionable else None,
    )


def _row(status: AgentStatus, *, stale: bool) -> ProjectedAgentRow:
    return ProjectedAgentRow(
        agent_id=status.agent_id,
        provider=status.provider,
        display_name=status.display_name,
        lifecycle_mode=LifecycleMode.WAITING,
        actionable=True,
        is_subagent=False,
        updated_at=status.updated_at,
        source_status=status,
        ask_may_be_stale=stale,
    )


def test_a_stale_ask_earns_no_escalation_and_a_fresh_one_does(cleared) -> None:  # noqa: F811
    controller = cleared
    old = _ask("claude:session:old", hours_ago=9)
    new = _ask("claude:session:new", hours_ago=0.01)

    controller.track_ask_blocked(_projection(_row(old, stale=True)))
    assert controller.ask_blocked_since is None  # no ramp, no chime, no webhook

    controller.track_ask_blocked(_projection(_row(old, stale=True), _row(new, stale=False)))
    assert controller.ask_blocked_since is not None
    assert set(controller.ask_blocked_by_agent) == {"claude:session:new"}
