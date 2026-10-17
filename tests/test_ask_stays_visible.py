"""An unanswered ask stays an ask on every surface until it is settled.

The reproduction the upstream review found: a question the agent was blocked
on read "Ask" at 59 minutes and idle at 61, although ``operator_state`` promised
a waiting ask never expires into invisibility. Four modules (the reducer's live
grace, the collector's presence horizon and stale window, the mailbox section
and the accessibility counts) each carried that one hour; the 24-hour work
retention then deleted the session outright. Here the whole chain runs with an
injected clock -- no test waits for anything -- and the ask is read at 59
minutes, 61 minutes, 6 hours, 3 days and 8 days.
"""

from __future__ import annotations

import json
from datetime import datetime, timedelta, timezone
from pathlib import Path

import pytest

from jrbar.attention import LifecycleMode, project_attention, regate_actionable_attention
from jrbar.collector import LiveAgentMonitor
from jrbar.hook import process_hook_payload
from jrbar.mailbox import MailboxSectionKind, project_canonical_mailbox
from jrbar.operator_accessibility import _present_primary_works
from jrbar.operator_state import BootIdentifier, ClockSample, RequestPhase
from jrbar.settings import AgentMonitorSettings

START = datetime(2026, 9, 30, 12, 0, 0, tzinfo=timezone.utc)
SESSION = "11111111-1111-4111-8111-111111111111"
NEIGHBOUR = "22222222-2222-4222-8222-222222222222"
MINUTE = 60.0
HOUR = 3_600.0
DAY = 86_400.0
AGES = [
    pytest.param(59 * MINUTE, id="59-minutes"),
    pytest.param(61 * MINUTE, id="61-minutes"),
    pytest.param(6 * HOUR, id="6-hours"),
    pytest.param(3 * DAY, id="3-days"),
    pytest.param(8 * DAY, id="8-days"),
]


class _Session:
    """One agent session driven through the real hook pipeline on a fake clock."""

    def __init__(self, tmp_path: Path, provider: str = "claude") -> None:
        self.provider = provider
        self.log = tmp_path / f"{provider}.jsonl"
        self.offset = 0.0
        self.monitor = LiveAgentMonitor(clock_sampler=self._clock)

    def _clock(self) -> ClockSample:
        return ClockSample(
            START.timestamp() + self.offset, 100.0 + self.offset, BootIdentifier("boot:ask-visible")
        )

    def at(self, seconds: float) -> None:
        self.offset = seconds

    def send(self, event: str, *, session: str = SESSION, **fields: object) -> None:
        payload = {"hook_event_name": event, "session_id": session, "cwd": "/tmp/project", **fields}
        stamp = (START + timedelta(seconds=self.offset)).strftime("%Y-%m-%dT%H:%M:%S.%fZ")
        process_hook_payload(
            self.provider,
            self.log,
            json.dumps(payload),
            logged_at=stamp,
            refresh_hint_handler=lambda hint: self.monitor.reconcile_refresh_hint(hint, log_path=self.log),
        )

    def ask(self, command: str = "rm -rf build") -> None:
        self.send("PermissionRequest", tool_name="Bash", tool_input={"command": command})

    def neighbour_speaks(self) -> None:
        # Another session talking is what makes the daemon reduce again in
        # real life; without it nothing would re-evaluate the old ask.
        self.send("UserPromptSubmit", session=NEIGHBOUR, prompt="hello")

    def snapshot(self):
        return self.monitor.snapshot()

    def asks(self) -> list:
        snapshot = self.snapshot()
        live = frozenset(
            request.key
            for request in snapshot.operator_state.requests
            if request.phase in {RequestPhase.LIVE_UNACKNOWLEDGED, RequestPhase.LIVE_ACKNOWLEDGED}
        )
        projection = regate_actionable_attention(
            project_attention(snapshot, AgentMonitorSettings()), live
        )
        return [row for row in projection.actionable_attention if row.agent_id.endswith(SESSION)]


def _asking_session(tmp_path: Path) -> _Session:
    session = _Session(tmp_path)
    session.at(1.0)
    session.send("SessionStart")
    session.at(2.0)
    session.send("UserPromptSubmit", prompt="build it")
    session.at(3.0)
    session.ask()
    return session


@pytest.mark.parametrize("age", AGES)
def test_the_ask_is_still_an_ask_for_the_strip_the_panel_the_mailbox_and_the_icon(
    age: float, tmp_path: Path, monkeypatch: pytest.MonkeyPatch
) -> None:
    session = _asking_session(tmp_path)
    session.at(3.0 + age)
    session.neighbour_speaks()
    # The mailbox ages rows against "now" from the reducer's own clock helper,
    # which reads the real wall clock; pin it to this test's clock.
    monkeypatch.setattr(
        "jrbar.mailbox.projection_now_epoch", lambda state: START.timestamp() + session.offset
    )

    snapshot = session.snapshot()
    (status,) = [s for s in snapshot.statuses if s.agent_id.endswith(SESSION)]
    assert status.is_hard_ask and not status.stale
    assert not any(s.agent_id.endswith(SESSION) for s in snapshot.stale_statuses)

    # The strip, the Screen Bar, the deck and the panel read this projection.
    (row,) = session.asks()
    assert row.actionable and row.lifecycle_mode is LifecycleMode.WAITING

    # The request is live in canonical state, not held.
    (request,) = snapshot.operator_state.requests
    assert request.phase is RequestPhase.LIVE_UNACKNOWLEDGED

    # The mailbox keeps it under Needs You, and the menu-bar counts keep the
    # session as present, however long it has been quiet.
    mailbox = project_canonical_mailbox(snapshot.operator_state)
    assert mailbox.needs_you_count == 1
    needs_you = next(s for s in mailbox.sections if s.kind is MailboxSectionKind.NEEDS_YOU)
    assert len(needs_you.rows) == 1
    present = _present_primary_works(snapshot.operator_state)
    assert any(work.key == request.key.work_key for work in present)


def test_the_neighbour_does_not_borrow_the_ask(tmp_path: Path) -> None:
    session = _asking_session(tmp_path)
    session.at(3.0 + 8 * DAY)
    session.neighbour_speaks()
    snapshot = session.snapshot()
    neighbour = [s for s in snapshot.statuses if s.agent_id.endswith(NEIGHBOUR)]
    assert neighbour and not any(s.is_hard_ask for s in neighbour)


@pytest.mark.parametrize("age", [61 * MINUTE, 6 * HOUR, 3 * DAY, 8 * DAY])
def test_the_agent_settling_the_ask_itself_ends_it_however_old(age: float, tmp_path: Path) -> None:
    # The tool ran (PostToolUse): the person answered in the terminal.
    session = _asking_session(tmp_path)
    session.at(3.0 + age)
    session.send(
        "PostToolUse",
        tool_name="Bash",
        tool_input={"command": "rm -rf build"},
        tool_response={},
    )
    assert session.asks() == []
    snapshot = session.snapshot()
    assert [r.phase for r in snapshot.operator_state.requests] == [RequestPhase.RESOLVED]


@pytest.mark.parametrize("age", [61 * MINUTE, 3 * DAY])
def test_a_new_prompt_closes_the_open_ask__the_ghost_ask_rule_still_holds(
    age: float, tmp_path: Path
) -> None:
    session = _asking_session(tmp_path)
    session.at(3.0 + age)
    session.send("UserPromptSubmit", prompt="no, run the tests instead")
    assert session.asks() == []


@pytest.mark.parametrize("event", ["Stop", "SessionEnd"])
@pytest.mark.parametrize("age", [61 * MINUTE, 3 * DAY])
def test_the_turn_or_the_session_ending_closes_the_ask(event: str, age: float, tmp_path: Path) -> None:
    session = _asking_session(tmp_path)
    session.at(3.0 + age)
    session.send(event)
    assert session.asks() == []
    assert all(
        request.phase is RequestPhase.RESOLVED for request in session.snapshot().operator_state.requests
    )


def test_a_decide_lane_hold_that_lapses_leaves_the_ask_and_the_agent_continuing_closes_it(
    tmp_path: Path,
) -> None:
    # The lane holds the agent's hook for DECISION_HOLD_SECONDS (45 s). When
    # nobody answers, the hook lets go and the agent shows its own prompt: the
    # ask is still the person's to answer, hours later, until the agent moves.
    from jrbar.answer_decisions import DECISION_HOLD_SECONDS

    session = _asking_session(tmp_path)
    session.at(3.0 + DECISION_HOLD_SECONDS + 1.0)
    assert len(session.asks()) == 1
    session.at(3.0 + 2 * HOUR)
    session.neighbour_speaks()
    assert len(session.asks()) == 1
    session.at(3.0 + 2 * HOUR + 5.0)
    session.send(
        "PostToolUse",
        tool_name="Bash",
        tool_input={"command": "rm -rf build"},
        tool_response={},
    )
    assert session.asks() == []


def test_a_second_ask_in_the_same_turn_does_not_close_the_first_even_a_day_later(
    tmp_path: Path,
) -> None:
    session = _asking_session(tmp_path)
    session.at(10.0)
    session.ask("pwd")
    session.at(10.0 + DAY)
    session.neighbour_speaks()
    live = [
        request
        for request in session.snapshot().operator_state.requests
        if request.phase is RequestPhase.LIVE_UNACKNOWLEDGED
    ]
    assert len(live) == 2


def test_the_ask_outlives_the_day_old_work_retention(tmp_path: Path) -> None:
    # The catalog retires work whose newest event is a day old; a session
    # still waiting on the person is not history.
    session = _asking_session(tmp_path)
    session.at(3.0 + 2 * DAY)
    session.neighbour_speaks()
    (row,) = session.asks()
    assert row.actionable
