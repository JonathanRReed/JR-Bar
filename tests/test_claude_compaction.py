"""Compaction is maintenance: it never starts a Claude turn.

Claude Code compacts in the middle of a turn, and also on its own about an
hour after a turn ended: PreCompact, a summary SubagentStop, SessionStart
with source "compact", PostCompact, and then nothing until the next prompt.
Read as work, that left a finished session Working with no Stop to follow,
and the lights played "working" all night (SidePulse issue #82). A
compaction now keeps the state the session had: working in the middle of a
turn (the row says it is compacting), finished or idle after one, and an
open ask stays open. Synthetic data only.
"""

from __future__ import annotations

import json
from datetime import datetime, timedelta, timezone
from pathlib import Path

import pytest

from jrbar.collector import (
    LiveAgentMonitor,
    _registered_hook_source,
    is_compaction_record,
    should_ignore_status_transition,
    status_from_event,
)
from jrbar.hook import _normalized_hook_record, routed_hook_payload
from jrbar.models import AgentMode
from jrbar.operator_state import BootIdentifier, ClockSample
from jrbar.provider_adapters import (
    NormalizedProviderRecord,
    ProviderEventName,
    normalized_provider_record_from_payload,
    normalized_provider_record_to_payload,
    provider_facts_for_record,
)
from jrbar.provider_facts import WorkLifecycle
from jrbar.providers import parse_log_line

NOW = datetime.now(timezone.utc).replace(microsecond=0)
BASE = {"session_id": "s-compact", "cwd": "/work/demo", "transcript_path": "/tmp/t.jsonl"}
PROMPT = {**BASE, "hook_event_name": "UserPromptSubmit", "prompt": "go"}
STOP = {**BASE, "hook_event_name": "Stop", "last_assistant_message": "Done."}
NUDGE = {**BASE, "hook_event_name": "Notification", "notification_type": "idle_prompt",
         "message": "Claude is waiting for your input"}
PRE = {**BASE, "hook_event_name": "PreCompact", "trigger": "auto", "custom_instructions": None}
RESTART = {**BASE, "hook_event_name": "SessionStart", "source": "compact"}
POST = {**BASE, "hook_event_name": "PostCompact", "trigger": "auto", "compact_summary": "synthetic summary"}
TOOL = {**BASE, "hook_event_name": "PreToolUse", "tool_name": "Bash", "tool_input": {"command": "true"}}
ASK = {**BASE, "hook_event_name": "PermissionRequest", "tool_name": "Bash", "tool_input": {"command": "true"},
       "request_id": "request:compact"}


def _records(payload: dict, provider: str = "claude"):
    actual, _, line = routed_hook_payload(provider, Path(f"/tmp/{provider}.jsonl"), json.dumps(payload))
    return _normalized_hook_record(actual, line), parse_log_line(actual, json.dumps(line))


def _facts(normalized):
    source = _registered_hook_source("claude")
    return provider_facts_for_record(
        normalized, contract=source.contract,
        observation_authority=source.registration.observation_authority,
        observed_at_epoch=NOW.timestamp(),
    )


class _Run:
    """One Claude session fed to a monitor, a second apart."""

    def __init__(self) -> None:
        self.offset = 0.0
        self.monitor = LiveAgentMonitor(clock_sampler=self._clock)
        self.index = 0

    def _clock(self) -> ClockSample:
        return ClockSample(NOW.timestamp() + self.offset, 100.0 + self.offset, BootIdentifier("boot:compact"))

    def feed(self, *payloads: dict):
        status = None
        for payload in payloads:
            self.offset = float(self.index) + 0.5
            line = json.dumps({**payload, "logged_at": (NOW + timedelta(seconds=self.index)).isoformat()})
            self.monitor.ingest_record(parse_log_line("claude", line))
            self.index += 1
            mains = [row for row in self.monitor.snapshot().statuses if row.agent_id.endswith("s-compact")]
            status = mains[0] if mains else None
        return status

    def lifecycle(self) -> WorkLifecycle:
        (work,) = [work for work in self.monitor.snapshot().operator_state.works
                   if work.key.work_id.value.endswith("s-compact")]
        return work.lifecycle


@pytest.mark.parametrize("payload", (PRE, POST, RESTART))
def test_a_compaction_event_carries_no_lifecycle_of_its_own(payload: dict) -> None:
    normalized, event = _records(payload)
    assert type(normalized) is NormalizedProviderRecord
    assert is_compaction_record(event)
    batch = _facts(normalized)
    assert batch.work_facts == () and batch.request_facts == ()
    # And it replays the same way after a restart.
    replayed = normalized_provider_record_from_payload(normalized_provider_record_to_payload(normalized))
    assert _facts(replayed).work_facts == ()
    assert "synthetic summary" not in json.dumps(normalized_provider_record_to_payload(normalized))


def test_the_session_restarted_after_compacting_is_not_a_new_idle_session() -> None:
    normalized, _event = _records(RESTART)
    assert normalized.event_name is ProviderEventName.POST_COMPACT
    # An ordinary start is still a start.
    fresh, event = _records({**BASE, "hook_event_name": "SessionStart", "source": "startup"})
    assert fresh.event_name is ProviderEventName.SESSION_START
    assert not is_compaction_record(event)
    assert _facts(fresh).work_facts[0].lifecycle is WorkLifecycle.IDLE


def test_idle_compaction_leaves_a_finished_session_finished() -> None:
    """The sequence from the report: Stop, the idle nudge, then compaction alone."""
    run = _Run()
    done = run.feed(PROMPT, STOP, NUDGE)
    assert done.mode is AgentMode.COMPLETED and run.lifecycle() is WorkLifecycle.COMPLETED
    summary = {**BASE, "hook_event_name": "SubagentStop", "agent_id": "compaction-summary",
               "last_assistant_message": "synthetic summary"}
    for payload in (PRE, summary, RESTART, POST):
        after = run.feed(payload)
        assert after.mode is AgentMode.COMPLETED, payload["hook_event_name"]
        assert after.event_name == "Stop"
        assert run.lifecycle() is WorkLifecycle.COMPLETED
    # The next prompt starts a real turn.
    assert run.feed(PROMPT).mode is AgentMode.WORKING


def test_compaction_in_the_middle_of_a_turn_keeps_the_turn_working_and_says_so() -> None:
    run = _Run()
    assert run.feed(PROMPT, TOOL).mode is AgentMode.TOOL_RUNNING
    compacting = run.feed(PRE)
    assert compacting.mode is AgentMode.WORKING and compacting.event_name == "PreCompact"
    restarted = run.feed(RESTART)
    assert restarted.mode is AgentMode.WORKING, "the restart after compacting is not an idle session"
    assert restarted.event_name == "PreCompact"
    after = run.feed(POST)
    assert after.mode is AgentMode.WORKING and after.event_name == "PostCompact"
    assert run.lifecycle() is WorkLifecycle.ACTIVE
    assert run.feed(STOP).mode is AgentMode.COMPLETED


def test_compaction_never_hides_an_open_ask() -> None:
    run = _Run()
    asking = run.feed(PROMPT, ASK)
    assert asking.mode is AgentMode.WAITING_FOR_INPUT and asking.is_hard_ask
    for payload in (PRE, RESTART, POST):
        still = run.feed(payload)
        assert still.mode is AgentMode.WAITING_FOR_INPUT and still.is_hard_ask, payload["hook_event_name"]


def test_a_compaction_seen_before_anything_else_makes_no_working_session() -> None:
    """JR-Bar started after the session went quiet: the first thing it hears is a compaction."""
    run = _Run()
    for payload in (PRE, RESTART, POST):
        status = run.feed(payload)
        quiet = status is None or status.mode not in {AgentMode.WORKING, AgentMode.TOOL_RUNNING}
        assert quiet, payload["hook_event_name"]


def test_the_transition_rule_reads_only_what_it_is_given() -> None:
    working = status_from_event(_records(TOOL)[1])
    finished = status_from_event(_records(STOP)[1])
    compact = status_from_event(_records(PRE)[1])
    restart = status_from_event(_records(RESTART)[1])
    assert not should_ignore_status_transition(working, compact, set(), maintenance=True)
    assert should_ignore_status_transition(finished, compact, set(), maintenance=True)
    assert should_ignore_status_transition(None, compact, set(), maintenance=True)
    assert should_ignore_status_transition(working, restart, set(), maintenance=True)
    # Without the flag the rule is the old one.
    assert not should_ignore_status_transition(finished, compact, set())


def test_other_agents_compaction_is_left_as_it_was() -> None:
    normalized, event = _records({"session_id": "c-1", "cwd": "/work/demo", "hook_event_name": "PreCompact"},
                                 provider="codex")
    assert not is_compaction_record(event)
    source = _registered_hook_source("codex")
    batch = provider_facts_for_record(
        normalized, contract=source.contract,
        observation_authority=source.registration.observation_authority, observed_at_epoch=NOW.timestamp(),
    )
    assert batch.work_facts[0].lifecycle is WorkLifecycle.ACTIVE
