"""A person who moves on from a permission prompt has closed it.

Pressing Esc at a prompt, or answering it in the terminal, fires no hook of
its own for the tool that was refused. The next thing the agent reports is a
new prompt from the person, and that is proof the old ask is gone: the
decide lane already reads it so (answer_decisions._TURN_OVER_EVENTS). The
canonical state must agree, or the session keeps asking for a person who
answered and a click lands on a ghost.
"""

from __future__ import annotations

import json
from datetime import datetime, timedelta, timezone
from pathlib import Path

import pytest

from jrbar.attention import project_attention
from jrbar.collector import LiveAgentMonitor
from jrbar.hook import process_hook_payload
from jrbar.settings import AgentMonitorSettings

SESSION = "11111111-1111-4111-8111-111111111111"


def _stamp(seconds_ago: float) -> str:
    moment = datetime.now(timezone.utc) - timedelta(seconds=seconds_ago)
    return moment.strftime("%Y-%m-%dT%H:%M:%S.%fZ")


class _Session:
    def __init__(self, provider: str, tmp_path: Path) -> None:
        self.provider = provider
        self.log = tmp_path / f"{provider}.jsonl"
        self.monitor = LiveAgentMonitor()
        self.step = 0

    def send(self, event: str, **fields: object) -> None:
        self.step += 1
        payload = {"hook_event_name": event, "session_id": SESSION, "cwd": "/tmp/project", **fields}
        process_hook_payload(
            self.provider,
            self.log,
            json.dumps(payload),
            logged_at=_stamp(120.0 - 5.0 * self.step),
            refresh_hint_handler=lambda hint: self.monitor.reconcile_refresh_hint(hint, log_path=self.log),
        )

    def live_asks(self) -> list[str]:
        return [
            request.key.request_id.value
            for request in self.monitor.operator_state.requests
            if request.phase.value.startswith("live")
        ]

    def actionable(self) -> list[str]:
        projection = project_attention(self.monitor.snapshot(), AgentMonitorSettings())
        return [item.agent_id for item in projection.actionable_attention]


@pytest.mark.parametrize("provider", ["claude", "codex"])
def test_a_new_prompt_closes_the_ask_the_person_walked_away_from(provider: str, tmp_path: Path) -> None:
    session = _Session(provider, tmp_path)
    session.send("SessionStart")
    session.send("UserPromptSubmit", prompt="build it", turn_id="t1")
    session.send("PermissionRequest", tool_name="Bash", tool_input={"command": "rm -rf build"}, turn_id="t1")
    assert len(session.live_asks()) == 1
    assert session.actionable()

    session.send("UserPromptSubmit", prompt="no, run the tests instead", turn_id="t2")

    assert session.live_asks() == []
    assert session.actionable() == []


@pytest.mark.parametrize("provider", ["claude", "codex"])
def test_the_card_and_the_answer_name_the_same_ask(provider: str, tmp_path: Path) -> None:
    session = _Session(provider, tmp_path)
    session.send("SessionStart")
    session.send("UserPromptSubmit", prompt="build it", turn_id="t1")
    session.send("PermissionRequest", tool_name="Bash", tool_input={"command": "rm -rf build"}, turn_id="t1")
    session.send("UserPromptSubmit", prompt="instead run the tests", turn_id="t2")
    session.send("PermissionRequest", tool_name="Bash", tool_input={"command": "npm test"}, turn_id="t2")

    [status] = session.monitor.snapshot().statuses
    assert status.request_key is not None
    assert session.live_asks() == [status.request_key.request_id.value]


def test_a_second_ask_in_one_turn_does_not_close_the_first(tmp_path: Path) -> None:
    # Two tools can wait at once inside one turn; only a new prompt, a stop or
    # the tool's own result closes an ask.
    session = _Session("claude", tmp_path)
    session.send("SessionStart")
    session.send("UserPromptSubmit", prompt="do both")
    session.send("PermissionRequest", tool_name="Bash", tool_input={"command": "ls"})
    session.send("PermissionRequest", tool_name="Bash", tool_input={"command": "pwd"})
    assert len(session.live_asks()) == 2


def test_a_later_ask_is_not_gated_out_by_an_earlier_resolved_one(tmp_path: Path) -> None:
    # The first ask is approved and its own PostToolUse resolves it; the
    # resolved record stays linked to the session. Whichever of the two ids
    # sorts first, the row must name the ask that is open and stay actionable
    # when the state's live asks are checked.
    from jrbar.attention import regate_actionable_attention
    from jrbar.operator_state import RequestPhase

    for index in range(8):
        session = _Session("claude", tmp_path / f"s{index}")
        (tmp_path / f"s{index}").mkdir()
        session.send("SessionStart")
        session.send("UserPromptSubmit", prompt="go")
        first = {"command": f"first-{index}"}
        session.send("PermissionRequest", tool_name="Bash", tool_input=first)
        session.send("PostToolUse", tool_name="Bash", tool_input=first, tool_response={})
        session.send("PermissionRequest", tool_name="Bash", tool_input={"command": f"second-{index}"})

        snapshot = session.monitor.snapshot()
        live = frozenset(
            request.key
            for request in snapshot.operator_state.requests
            if request.phase in {RequestPhase.LIVE_UNACKNOWLEDGED, RequestPhase.LIVE_ACKNOWLEDGED}
        )
        assert len(live) == 1
        [status] = snapshot.statuses
        assert status.request_key in live, index
        projection = regate_actionable_attention(project_attention(snapshot, AgentMonitorSettings()), live)
        assert projection.actionable_attention, index
