"""A Claude turn that ends with background work in flight is not done.

Claude Code's Stop hook lists the tasks still running when a turn ends
(``background_tasks``: a shell job, a monitor, a background subagent). The
session is then paused until that work wakes it. Reading that Stop as
Completed put the lights on Done and let Keep Awake go in the middle of a
long test run (SidePulse issue #73). The work stays active, the idle nudge
that follows is not an ask, the session file going idle is what waiting
looks like, and the next Stop with nothing in flight completes the turn
once. Only the count of tasks is read: never a description or a command.
Synthetic data only.
"""

from __future__ import annotations

import json
from datetime import datetime, timedelta, timezone
from pathlib import Path

import pytest

from jrbar import process_registry as pr
from jrbar.collector import (
    LiveAgentMonitor,
    _registered_hook_source,
    is_background_wait,
    mode_for_event,
    notification_requests_input,
    should_ignore_status_transition,
    status_from_event,
)
from jrbar.completions import detect_completion_batch
from jrbar.hook import _normalized_hook_record, routed_hook_payload
from jrbar.liveness_sweep import BACKGROUND_WAIT_MAX_SECONDS, reap_dead_agents
from jrbar.models import AgentMode, AgentStatus
from jrbar.operator_state import BootIdentifier, ClockSample
from jrbar.provider_adapters import (
    MAX_BACKGROUND_TASKS_READ,
    NormalizedProviderRecord,
    ProviderEventName,
    normalized_provider_record_from_payload,
    normalized_provider_record_to_payload,
    provider_facts_for_record,
    running_background_tasks,
)
from jrbar.provider_facts import NextActor, WorkLifecycle
from jrbar.providers import parse_log_line

NOW = datetime.now(timezone.utc).replace(microsecond=0)
SESSION = "11111111-2222-3333-4444-555555555555"
BASE = {"session_id": SESSION, "cwd": "/work/demo", "transcript_path": "/tmp/t.jsonl"}
SECRET = "synthetic-private-command --token abc"
SHELL = {"id": "task-001", "type": "shell", "status": "running", "description": SECRET, "command": SECRET}
STOP = {**BASE, "hook_event_name": "Stop", "last_assistant_message": "Started the long test run."}


def _stop(tasks: object = (), **changes) -> dict:
    payload = {**STOP, **changes}
    if tasks != ():
        payload["background_tasks"] = tasks
    return payload


def _records(payload: dict, provider: str = "claude"):
    actual, _, line = routed_hook_payload(provider, Path(f"/tmp/{provider}.jsonl"), json.dumps(payload))
    return _normalized_hook_record(actual, line), parse_log_line(actual, json.dumps(line))


def _work(normalized):
    source = _registered_hook_source("claude")
    batch = provider_facts_for_record(
        normalized,
        contract=source.contract,
        observation_authority=source.registration.observation_authority,
        observed_at_epoch=NOW.timestamp(),
    )
    (work,) = batch.work_facts
    return work


@pytest.mark.parametrize(
    ("tasks", "running"),
    (
        ([SHELL], 1),
        ([SHELL, {"id": "m", "type": "monitor", "status": "running"}, {"id": "s", "type": "subagent", "status": "pending"}], 3),
        ([{"id": "t", "type": "shell", "status": "completed"}], 0),
        ([{"id": "t", "type": "shell", "status": "Failed"}, {"id": "u", "type": "shell", "status": "killed"}], 0),
        ([], 0),
        (None, 0),
        ("running", 0),
        ({"status": "running"}, 0),
        (["running", 7, None, {"status": 1}, {"status": ""}, {"type": "shell"}], 0),
        ([SHELL] * (MAX_BACKGROUND_TASKS_READ + 50), MAX_BACKGROUND_TASKS_READ),
    ),
)
def test_only_tasks_still_in_flight_are_counted(tasks: object, running: int) -> None:
    assert running_background_tasks({"background_tasks": tasks}) == running
    assert running_background_tasks({}) == 0
    assert running_background_tasks(None) == 0


def test_a_stop_with_work_in_flight_keeps_the_work_active() -> None:
    normalized, event = _records(_stop([SHELL]))
    assert type(normalized) is NormalizedProviderRecord
    assert normalized.event_name is ProviderEventName.STOP_BACKGROUND
    work = _work(normalized)
    assert work.lifecycle is WorkLifecycle.ACTIVE and work.next_actor is NextActor.PROVIDER
    assert mode_for_event(event) is AgentMode.LONG_TASK_PROGRESS
    status = status_from_event(event)
    assert status.mode is AgentMode.LONG_TASK_PROGRESS and status.event_name == "Stop"
    assert is_background_wait(status)


@pytest.mark.parametrize("tasks", ((), [], [{"id": "t", "type": "shell", "status": "completed"}], "oops", None))
def test_a_stop_with_nothing_in_flight_completes_as_before(tasks: object) -> None:
    normalized, event = _records(_stop(tasks))
    assert normalized.event_name is ProviderEventName.STOP
    assert _work(normalized).lifecycle is WorkLifecycle.COMPLETED
    assert mode_for_event(event) is AgentMode.COMPLETED
    assert not is_background_wait(status_from_event(event))


def test_a_question_at_the_end_of_the_turn_still_asks() -> None:
    _normalized, event = _records(_stop([SHELL], last_assistant_message="Which branch should I use?"))
    assert mode_for_event(event) is AgentMode.WAITING_FOR_INPUT


def test_a_finished_subagent_is_still_finished_and_other_agents_are_untouched() -> None:
    # SubagentStop carries the parent's task list; a finished worker is finished.
    _normalized, event = _records({**BASE, "hook_event_name": "SubagentStop", "agent_id": "worker-1",
                                   "background_tasks": [SHELL]})
    assert mode_for_event(event) is AgentMode.COMPLETED
    # The array means nothing on another provider's Stop.
    _normalized, other = _records({"session_id": "c-1", "cwd": "/work/demo", "hook_event_name": "Stop",
                                   "background_tasks": [SHELL]}, provider="codex")
    assert mode_for_event(other) is AgentMode.COMPLETED


def test_nothing_about_a_task_but_its_count_is_kept() -> None:
    normalized, event = _records(_stop([SHELL]))
    stored = normalized_provider_record_to_payload(normalized)
    assert SECRET not in json.dumps(stored)
    # What is stored replays to the same event, so a restart keeps the wait.
    replayed = normalized_provider_record_from_payload(stored)
    assert replayed.event_name is ProviderEventName.STOP_BACKGROUND
    assert _work(replayed).lifecycle is WorkLifecycle.ACTIVE
    status = status_from_event(event)
    assert SECRET not in repr(status)


def test_the_idle_nudge_after_a_background_stop_is_not_news_but_a_real_ask_is() -> None:
    waiting = status_from_event(_records(_stop([SHELL]))[1])
    _normalized, nudge = _records(
        {**BASE, "hook_event_name": "Notification", "notification_type": "idle_prompt",
         "message": "Claude is waiting for your input"}
    )
    assert should_ignore_status_transition(
        waiting, status_from_event(nudge), set(), requests_input=notification_requests_input(nudge)
    )
    _normalized, blocked = _records(
        {**BASE, "hook_event_name": "Notification", "notification_type": "agent_needs_input",
         "message": "Explore needs your input: choose a branch"}
    )
    assert not should_ignore_status_transition(
        waiting, status_from_event(blocked), set(), requests_input=notification_requests_input(blocked)
    )


def test_the_monitor_keeps_working_until_the_stop_with_nothing_in_flight() -> None:
    offset = [0.0]

    def clock() -> ClockSample:
        return ClockSample(NOW.timestamp() + offset[0], 100.0 + offset[0], BootIdentifier("boot:background"))

    monitor = LiveAgentMonitor(clock_sampler=clock)

    def feed(index: int, payload: dict) -> AgentStatus:
        offset[0] = float(index) + 0.5
        line = json.dumps({**payload, "logged_at": (NOW + timedelta(seconds=index)).isoformat()})
        monitor.ingest_record(parse_log_line("claude", line))
        (status,) = monitor.snapshot().statuses
        return status

    working = feed(0, {**BASE, "hook_event_name": "UserPromptSubmit", "prompt": "run the suite"})
    assert working.mode is AgentMode.WORKING
    paused = feed(1, _stop([SHELL]))
    assert paused.mode in {AgentMode.LONG_TASK_PROGRESS, AgentMode.WORKING}
    assert paused.mode is not AgentMode.COMPLETED
    (work,) = monitor.snapshot().operator_state.works
    assert work.lifecycle is WorkLifecycle.ACTIVE

    # No celebration while the job runs.
    quiet = detect_completion_batch({working.agent_id: AgentMode.WORKING}, [paused], NOW)
    assert quiet.statuses == ()

    # The job finishes, Claude wakes for a turn of its own, and that turn ends clean.
    woken = feed(2, {**BASE, "hook_event_name": "UserPromptSubmit", "prompt": "(background task finished)"})
    assert woken.mode is AgentMode.WORKING
    done = feed(3, _stop([]))
    assert done.mode is AgentMode.COMPLETED
    (work,) = monitor.snapshot().operator_state.works
    assert work.lifecycle is WorkLifecycle.COMPLETED
    batch = detect_completion_batch({paused.agent_id: paused.mode}, [done], NOW)
    assert [status.agent_id for status in batch.statuses] == [done.agent_id]


# --- the liveness sweep: an idle session file is what waiting looks like ---

LAST_HOOK = datetime(2026, 11, 14, 12, 0, 0, tzinfo=timezone.utc)


def _session_file(home: Path, *, idle_after_seconds: float) -> None:
    folder = home / "sessions"
    folder.mkdir(parents=True, exist_ok=True)
    (folder / "4101.json").write_text(json.dumps({
        "pid": 4101, "sessionId": SESSION,
        "startedAt": int((LAST_HOOK - timedelta(hours=1)).timestamp() * 1000),
        "status": "idle",
        "statusUpdatedAt": int((LAST_HOOK + timedelta(seconds=idle_after_seconds)).timestamp() * 1000),
        "cwd": "/work/demo",
    }), encoding="utf-8")


def _row(mode: AgentMode, event_name: str) -> AgentStatus:
    return AgentStatus(provider="claude", agent_id=f"claude:session:{SESSION}", display_name="demo", mode=mode,
                       updated_at=LAST_HOOK, event_name=event_name, session_id=SESSION, cwd="/work/demo")


def _reap(tmp_path: Path, row: AgentStatus, *, now: float) -> list:
    entry = pr.ProcessEntry(4101, 1, None, "claude")
    table = {4101: entry, 1: pr.ProcessEntry(1, 0, 0.0, "launchd")}
    sweeper = pr.ProcessSweeper(
        state_dir=tmp_path / "state", table_loader=lambda: table,
        claude_index_loader=lambda: pr.claude_session_index(tmp_path / "sessions"), clock=lambda: now,
    )
    sent: list = []
    reap_dead_agents(
        [row], sweeper=sweeper, refresh_hint_handler=None,
        process_payload=lambda provider, log, payload, **kw: sent.append(json.loads(payload)),
        log_path_for=lambda provider: Path("/x"),
        claude_activity_loader=lambda: pr.claude_session_activity(tmp_path / "sessions"),
        now=now,
    )
    return sent


def test_an_idle_session_file_does_not_end_a_background_wait(tmp_path: Path) -> None:
    _session_file(tmp_path, idle_after_seconds=30)
    soon = LAST_HOOK.timestamp() + 120
    assert _reap(tmp_path, _row(AgentMode.LONG_TASK_PROGRESS, "Stop"), now=soon) == []
    # The same file ends an ordinary working turn that went idle with no hook.
    (ended,) = _reap(tmp_path, _row(AgentMode.WORKING, "PostToolUse"), now=soon)
    assert ended["hook_event_name"] == "Interrupt"
    # Long task progress from anything but a Stop is not this wait.
    (ended,) = _reap(tmp_path, _row(AgentMode.LONG_TASK_PROGRESS, "ActivityProgress"), now=soon)
    assert ended["hook_event_name"] == "Interrupt"


def test_a_background_wait_is_believed_for_six_hours_not_for_ever(tmp_path: Path) -> None:
    _session_file(tmp_path, idle_after_seconds=30)
    row = _row(AgentMode.LONG_TASK_PROGRESS, "Stop")
    assert _reap(tmp_path, row, now=LAST_HOOK.timestamp() + BACKGROUND_WAIT_MAX_SECONDS - 1) == []
    (ended,) = _reap(tmp_path, row, now=LAST_HOOK.timestamp() + BACKGROUND_WAIT_MAX_SECONDS + 1)
    assert ended["hook_event_name"] == "Interrupt" and ended["session_id"] == SESSION


def test_the_wait_ends_even_when_the_file_went_idle_with_the_stop_itself(tmp_path: Path) -> None:
    """The usual sign of a stopped turn is a file that went idle after the last
    hook. A background Stop's file goes idle with the hook and never changes
    again, so past six hours an idle file alone has to be enough."""
    _session_file(tmp_path, idle_after_seconds=1)
    row = _row(AgentMode.LONG_TASK_PROGRESS, "Stop")
    assert _reap(tmp_path, row, now=LAST_HOOK.timestamp() + 3600) == []
    (ended,) = _reap(tmp_path, row, now=LAST_HOOK.timestamp() + BACKGROUND_WAIT_MAX_SECONDS + 1)
    assert ended["hook_event_name"] == "Interrupt"
    # An ordinary working turn whose file went idle inside the grace is still left alone.
    assert _reap(tmp_path, _row(AgentMode.WORKING, "PostToolUse"),
                 now=LAST_HOOK.timestamp() + BACKGROUND_WAIT_MAX_SECONDS + 1) == []
