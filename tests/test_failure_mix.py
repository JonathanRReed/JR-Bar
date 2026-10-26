"""Retained failure history must not own a provider's light share."""

from dataclasses import replace
from datetime import datetime, timedelta, timezone
from types import SimpleNamespace

import pytest

from jrbar import colors
from jrbar.attention import project_attention, settle_completed_for_lights
from jrbar.core_projection import aggregate_counts, session_document
from jrbar.deck_session_board import DeckSessionBoard, session_identity
from jrbar.failure_policy import signals_failure
from jrbar.led_status import LedDisplayState
from jrbar.light_mix import explain_what_plays
from jrbar.models import AgentMode, AgentStatus, ParentLink
from jrbar.provider_facts import SourceKey, WorkIdentifier, WorkKey
from jrbar.settings import AgentMonitorSettings

START = datetime(2026, 10, 1, tzinfo=timezone.utc)


@pytest.mark.parametrize("mix", colors.BLEND_MODE_CHOICES)
@pytest.mark.parametrize("surface,count", [("SidePulse", 8), ("Dot", 2), ("Screen Bar mirror", 8)])
@pytest.mark.parametrize("case,elapsed,visible", [
    ("root", 0, True), ("root", 4.999, True), ("root", 5, False),
    ("root", 60, False), ("linked worker", 0, False),
    ("unlinked worker", 0, False), ("ended", 0, False),
    ("interrupted", 0, False), ("resumed", 0, True),
])
@pytest.mark.parametrize("settled", [False, True])
def test_failure_share_matrix(monkeypatch, mix, surface, count, case, elapsed, visible, settled):
    now = START + timedelta(seconds=elapsed)

    class Clock(datetime):
        @classmethod
        def now(cls, tz=None):
            return now

    monkeypatch.setattr(colors, "datetime", Clock)
    working = AgentStatus("codex", "codex:session:root", "Fixture", AgentMode.WORKING, START, "Working")
    failed = AgentStatus("claude", "claude:session:root", "Fixture", AgentMode.BLOCKED_ERROR, START, "StopFailure")
    if "worker" in case:
        failed = replace(failed, agent_id="claude:agent:child")
        if case == "linked worker":
            failed = replace(failed, parent_links=(ParentLink(failed.agent_id, working.agent_id, "t3code", START.timestamp()),))
    elif case == "ended":
        failed = replace(failed, mode=AgentMode.ENDED_UNCONFIRMED, event_name="SessionEnd")
    elif case == "interrupted":
        failed = replace(failed, event_name="StopInterrupted")
    elif case == "resumed":
        failed = replace(failed, mode=AgentMode.TOOL_RUNNING, event_name="PreToolUse")
    # Reuse the initial projection past its deadline, as a mirror or an
    # explanation can do before the daemon publishes its next refresh.
    projection = project_attention(SimpleNamespace(statuses=(working, failed), collected_at=START), AgentMonitorSettings())
    if settled:
        projection = settle_completed_for_lights(projection, now=now)
    settings = replace(colors.ColorSettings.defaults().with_blend_mode(mix),
                       mix_effect={"effect_id": "marquee", "parameters": {}})
    settings = settings.with_session_color(failed.agent_id, "#33AACC")
    plan = explain_what_plays(projection, settings, led_count=count)
    expected = {"codex", "claude"} if visible else {"codex"}
    assert {row["provider"] for row in plan["providers"]} == expected, surface
    state, program = colors.program_for_projection(projection, colors=settings, led_count=count)
    assert state is LedDisplayState.WORKING
    assert plan["program"] == program
    if not visible:
        alone = project_attention(SimpleNamespace(statuses=(working,), collected_at=START), AgentMonitorSettings())
        assert program == colors.program_for_projection(alone, colors=settings, led_count=count)[1]
    assert len(program.encode()) <= 512
    assert len(program.splitlines()) <= 20


@pytest.mark.parametrize("elapsed", [0, 4.999, 5, 60])
@pytest.mark.parametrize("worker", [False, True])
def test_failure_consumers_share_the_deadline(elapsed, worker):
    now = START + timedelta(seconds=elapsed)
    failed = AgentStatus("claude", "claude:agent:child" if worker else "claude:session:root",
                         "Fixture", AgentMode.BLOCKED_ERROR, START, "StopFailure",
                         work_key=WorkKey(SourceKey("claude", "hooks", "fixture", "sessions"), WorkIdentifier("root")))
    expected = not worker and elapsed < 5
    assert signals_failure(failed, now=now) is expected
    row = session_document(failed, now=now.timestamp(), operator_state=None,
                           ask_ids=frozenset(), extras=None, workers=0)
    assert row["lifecycle"] == "failed"
    assert aggregate_counts([row], asks=[], ready_ids=frozenset())["failed"] == int(expected)
    board = DeckSessionBoard(clock=lambda: now)
    board.update((failed,))
    slots = board.snapshot().slots
    if worker:
        assert all(slot.identity is None for slot in slots)
    else:
        slot = next(slot for slot in slots if slot.identity == session_identity(failed))
        assert (slot.state == "failure") is expected
