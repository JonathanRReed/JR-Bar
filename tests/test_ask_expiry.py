"""An ask nobody answered for a very long time is archived, out loud.

Much later than "may be stale" (7 days by default), an ask from a session that
no running process vouches for is closed: the session is ended through the
ordinary hook pipeline with a reason that names the cause, History gets an
"expired unanswered" row, and the row reads "ended" rather than the green
check a real finish earns. An ask whose process is still running is never
closed by age. The sweep takes its clock as an argument, so no test waits.
"""

from __future__ import annotations

import json
from pathlib import Path

import pytest

from jrbar.activity_ledger import ACTIVITY_PHRASES, ActivityKind
from jrbar.ask_lifetime import ASK_EXPIRED_REASON, ASK_EXPIRES_UNANSWERED_SECONDS
from jrbar.core_projection import lifecycle_for_mode
from jrbar.liveness_sweep import expired_ask_payloads, reap_dead_agents
from jrbar.models import AgentMode
from jrbar.operator_state import RequestPhase
from tests.test_ask_stays_visible import DAY, HOUR, MINUTE, SESSION, START, _asking_session

ASKED_AT = START.timestamp() + 3.0


class _Sweeper:
    """The process table's answer: nothing is dead; some sessions are alive."""

    def __init__(self, alive: bool) -> None:
        self.alive = alive

    def classify(self, sessions):
        live = frozenset(sessions) if self.alive else frozenset()
        return [], live


def _sweep(session, age: float, *, alive: bool, **kwargs):
    session.at(3.0 + age)
    snapshot = session.snapshot()
    (status,) = [s for s in snapshot.statuses if s.agent_id.endswith(SESSION)]
    sent: list[tuple[str, str]] = []

    def process_payload(provider, log_path, payload, *, refresh_hint_handler=None):
        sent.append((provider, payload))
        # The real pipeline: the same function the hooks use.
        from jrbar.hook import process_hook_payload

        stamp = json.loads(payload)["occurred_at_epoch"]
        from datetime import datetime, timezone

        process_hook_payload(
            provider,
            log_path,
            payload,
            logged_at=datetime.fromtimestamp(stamp, timezone.utc).strftime("%Y-%m-%dT%H:%M:%S.%fZ"),
            refresh_hint_handler=lambda hint: session.monitor.reconcile_refresh_hint(
                hint, log_path=log_path
            ),
        )

    result = reap_dead_agents(
        [status],
        sweeper=_Sweeper(alive),
        refresh_hint_handler=None,
        process_payload=process_payload,
        log_path_for=lambda _provider: session.log,
        claude_activity_loader=lambda: {},
        now=ASKED_AT + age,
        **kwargs,
    )
    return result, sent, status


@pytest.mark.parametrize("alive", [True, False])
@pytest.mark.parametrize("age", [59 * MINUTE, 61 * MINUTE, 6 * HOUR, 3 * DAY, 7 * DAY - 60])
def test_nothing_is_closed_before_the_outer_clock_whatever_the_process_says(
    age: float, alive: bool, tmp_path: Path
) -> None:
    session = _asking_session(tmp_path)
    result, sent, _status = _sweep(session, age, alive=alive)
    assert result.expired_asks == () and sent == []
    assert [r.phase for r in session.snapshot().operator_state.requests] == [
        RequestPhase.LIVE_UNACKNOWLEDGED
    ]


def test_a_running_process_keeps_its_ask_at_eight_days_and_more(tmp_path: Path) -> None:
    session = _asking_session(tmp_path)
    for age in (8 * DAY, 30 * DAY):
        result, sent, _status = _sweep(session, age, alive=True)
        assert result.expired_asks == () and sent == []
    assert [r.phase for r in session.snapshot().operator_state.requests] == [
        RequestPhase.LIVE_UNACKNOWLEDGED
    ]


def test_no_process_and_eight_days_closes_the_ask_through_the_hook_pipeline(tmp_path: Path) -> None:
    session = _asking_session(tmp_path)
    result, sent, status = _sweep(session, 8 * DAY, alive=False)

    assert [s.agent_id for s in result.expired_asks] == [status.agent_id]
    ((provider, payload),) = sent
    event = json.loads(payload)
    assert provider == "claude"
    assert event["hook_event_name"] == "SessionEnd"
    assert event["reason"] == ASK_EXPIRED_REASON and event["jrbar_synthetic"] is True
    # The ask is gone from every surface.
    session.at(3.0 + 8 * DAY + 1)
    assert [r.phase for r in session.snapshot().operator_state.requests] == [RequestPhase.RESOLVED]
    assert session.asks() == []


def test_a_workers_ask_ends_that_worker_only() -> None:
    from datetime import datetime, timezone

    from jrbar.models import AgentStatus

    worker = AgentStatus(
        provider="claude",
        agent_id="claude:agent:worker-1",
        display_name="worker",
        mode=AgentMode.WAITING_FOR_INPUT,
        updated_at=datetime(2026, 9, 1, tzinfo=timezone.utc),
        event_name="PermissionRequest",
        session_id="parent-session",
    )
    (payload,) = expired_ask_payloads(worker, now=ASKED_AT)
    event = json.loads(payload)
    assert event["hook_event_name"] == "SubagentStop"
    assert event["agent_id"] == "worker-1" and event["session_id"] == "parent-session"


def test_the_outer_clock_is_configurable(tmp_path: Path) -> None:
    session = _asking_session(tmp_path)
    result, _sent, _status = _sweep(
        session, 2 * DAY, alive=False, ask_stale_after_seconds=HOUR, ask_expire_after_seconds=DAY
    )
    assert len(result.expired_asks) == 1


def test_only_asks_expire_not_other_quiet_sessions(tmp_path: Path) -> None:
    session = _asking_session(tmp_path)
    session.at(10.0)
    session.send(
        "PostToolUse", tool_name="Bash", tool_input={"command": "rm -rf build"}, tool_response={}
    )
    session.at(3.0 + 9 * DAY)
    snapshot = session.snapshot()
    statuses = [s for s in (*snapshot.statuses, *snapshot.stale_statuses) if s.agent_id.endswith(SESSION)]
    result = reap_dead_agents(
        statuses,
        sweeper=_Sweeper(False),
        refresh_hint_handler=None,
        process_payload=lambda *a, **k: pytest.fail("a settled session must not be touched"),
        log_path_for=lambda _provider: session.log,
        claude_activity_loader=lambda: {},
        now=ASKED_AT + 9 * DAY,
    )
    assert result.expired_asks == ()


def test_a_session_ended_by_age_reads_ended_never_the_green_check() -> None:
    # The Mac's own record says the end was not the agent's.
    ended = lifecycle_for_mode(
        AgentMode.COMPLETED, stale=False, event_name="Stop", process_alive=None, provider_ended=False
    )
    assert ended == "ended"
    finished = lifecycle_for_mode(
        AgentMode.COMPLETED, stale=False, event_name="Stop", process_alive=None, provider_ended=None
    )
    assert finished == "completed"


def test_history_names_an_expiry_in_words() -> None:
    from jrbar.core_projection import _LEDGER_KINDS

    assert ActivityKind.EXPIRED.value == "expired"
    assert _LEDGER_KINDS["expired"] == "ask_expired"
    assert ACTIVITY_PHRASES[ActivityKind.EXPIRED] == "ask expired unanswered"
    assert ASK_EXPIRES_UNANSWERED_SECONDS == 7 * DAY
