"""Devin CLI sub-agents surface as synthetic worker sessions.

Devin emits no SubagentStart/SubagentStop hooks; a sub-agent only exists as
a ``run_subagent``/``sidekick`` tool call on the parent session. The adapter
maps those calls onto canonical subagent events with a stateless
``sub-<hash>`` work id so the matching PostToolUse lands on the same worker.
"""

from __future__ import annotations

import hashlib
import time
from datetime import UTC, datetime

from jrbar import _collector_legacy as collector_module
from jrbar.capacity_types import SourceKey
from jrbar.collector import LiveAgentMonitor
from jrbar.core_projection import build_state_document
from jrbar.models import HookEvent
from jrbar.operator_state import WorkLifecycle
from jrbar.provider_adapters import (
    InertProviderRecord,
    NormalizedProviderRecord,
    ProviderEventName,
    minimize_hook_event,
    normalized_provider_record_from_payload,
    normalized_provider_record_to_payload,
)
from jrbar.provider_contracts import negotiate_provider_contract
from jrbar.provider_facts import ObservationAuthority

_EPOCH = 1_800_000_000.0
_SESSION = "devin-session-01"


def _devin_event(
    event_name: str,
    *,
    epoch: float = _EPOCH,
    session_id: str = _SESSION,
    tool_name: str | None = None,
    tool_input: dict[str, object] | None = None,
    tool_response: dict[str, object] | None = None,
    prompt: str | None = None,
) -> HookEvent:
    raw: dict[str, object] = {
        "hook_event_name": event_name,
        "session_id": session_id,
        "event_id": f"event:{int(epoch * 1000)}",
    }
    if tool_name is not None:
        raw["tool_name"] = tool_name
    if tool_input is not None:
        raw["tool_input"] = tool_input
    if tool_response is not None:
        raw["tool_response"] = tool_response
    if prompt is not None:
        raw["prompt"] = prompt
    return HookEvent(
        provider="devin",
        logged_at=datetime.fromtimestamp(epoch, UTC),
        event_name=event_name,
        raw=raw,
        session_id=session_id,
        tool_name=tool_name,
    )


def _source() -> SourceKey:
    return SourceKey("devin", "hooks", "global", "live_agent_events")


def _contract():
    return negotiate_provider_contract(
        {
            "schema_version": {"major": 1, "minor": 0},
            "provider_id": "devin",
            "adapter_id": "hooks",
            "source_instance_id": "global",
            "capabilities": [
                {"id": "live_agent_events", "versions": [{"major": 1, "minor": 0}]},
                {"id": "actionable_requests", "versions": [{"major": 1, "minor": 0}]},
            ],
        }
    )


def _normalize(event: HookEvent) -> NormalizedProviderRecord | InertProviderRecord:
    return minimize_hook_event(
        event,
        source_key=_source(),
        contract=_contract(),
        observation_authority=ObservationAuthority.DIRECT_PROVIDER_OBSERVATION,
    )


def _expected_worker_id(session_id: str, handle: str) -> str:
    digest = hashlib.sha256(f"{session_id}:{handle}".encode()).hexdigest()
    return f"sub-{digest[:12]}"


def test_run_subagent_pre_opens_worker_under_parent_session__and_2_more() -> None:
    # --- scenario: run_subagent_pre_opens_worker_under_parent_session
    record = _normalize(
        _devin_event(
            "PreToolUse",
            tool_name="run_subagent",
            tool_input={"title": "Explore the auth flow", "task": "read it"},
        )
    )

    assert type(record) is NormalizedProviderRecord
    assert record.event_name is ProviderEventName.SUBAGENT_START
    assert record.provider_work_id is not None
    assert record.provider_work_id.value == _expected_worker_id(
        _SESSION, "Explore the auth flow"
    )
    assert record.provider_work_id.value != _SESSION
    assert record.parent_work_id is not None
    assert record.parent_work_id.value == _SESSION
    assert record.safe_label == "Explore the auth flow"

    # --- scenario: run_subagent_post_foreground_stops_the_same_worker
    start = _normalize(
        _devin_event(
            "PreToolUse",
            tool_name="run_subagent",
            tool_input={"title": "Explore the auth flow"},
        )
    )
    stop = _normalize(
        _devin_event(
            "PostToolUse",
            epoch=_EPOCH + 30,
            tool_name="run_subagent",
            tool_input={"title": "Explore the auth flow"},
            tool_response={"success": True, "output": "agent_id=abc123 done"},
        )
    )

    assert type(start) is NormalizedProviderRecord
    assert type(stop) is NormalizedProviderRecord
    assert stop.event_name is ProviderEventName.SUBAGENT_STOP
    assert stop.provider_work_id is not None
    assert stop.provider_work_id == start.provider_work_id
    assert stop.parent_work_id is not None
    assert stop.parent_work_id.value == _SESSION

    # --- scenario: run_subagent_post_background_is_a_parent_tool_event
    record = _normalize(
        _devin_event(
            "PostToolUse",
            tool_name="run_subagent",
            tool_input={
                "title": "Long running sweep",
                "is_background": True,
            },
            tool_response={"success": True, "output": "agent_id=def456 launched"},
        )
    )

    assert type(record) is NormalizedProviderRecord
    assert record.event_name is ProviderEventName.POST_TOOL_USE
    assert record.provider_work_id is not None
    assert record.provider_work_id.value == _SESSION
    assert record.parent_work_id is None



def test_worker_ids_are_stable_per_title_and_distinct_across_titles__and_1_more() -> None:
    # --- scenario: worker_ids_are_stable_per_title_and_distinct_across_titles
    first = _normalize(
        _devin_event(
            "PreToolUse",
            tool_name="run_subagent",
            tool_input={"title": "Fix flaky test"},
        )
    )
    same = _normalize(
        _devin_event(
            "PreToolUse",
            epoch=_EPOCH + 1,
            tool_name="run_subagent",
            tool_input={"title": "Fix flaky test"},
        )
    )
    other = _normalize(
        _devin_event(
            "PreToolUse",
            epoch=_EPOCH + 2,
            tool_name="run_subagent",
            tool_input={"title": "Map the settings pages"},
        )
    )

    assert type(first) is NormalizedProviderRecord
    assert type(same) is NormalizedProviderRecord
    assert type(other) is NormalizedProviderRecord
    assert same.provider_work_id == first.provider_work_id
    assert other.provider_work_id != first.provider_work_id

    # --- scenario: resume_input_names_the_worker_instead_of_title
    record = _normalize(
        _devin_event(
            "PreToolUse",
            tool_name="run_subagent",
            tool_input={"title": "follow-up turn", "resume": "agent-77"},
        )
    )

    assert type(record) is NormalizedProviderRecord
    assert record.provider_work_id is not None
    assert record.provider_work_id.value == _expected_worker_id(_SESSION, "agent-77")



def _expected_sidekick_id(session_id: str) -> str:
    digest = hashlib.sha256(session_id.encode()).hexdigest()
    return f"sub-sidekick-{digest[:12]}"


def test_sidekick_round_trip_uses_the_stable_sidekick_worker__and_2_more() -> None:
    # --- scenario: sidekick_round_trip_uses_the_stable_sidekick_worker
    start = _normalize(
        _devin_event(
            "PreToolUse",
            tool_name="sidekick",
            tool_input={"message": "check the fold renderer"},
        )
    )
    stop = _normalize(
        _devin_event(
            "PostToolUse",
            epoch=_EPOCH + 5,
            tool_name="sidekick",
            tool_input={"message": "check the fold renderer"},
            tool_response={"success": True, "output": "done"},
        )
    )

    assert type(start) is NormalizedProviderRecord
    assert type(stop) is NormalizedProviderRecord
    assert start.event_name is ProviderEventName.SUBAGENT_START
    assert stop.event_name is ProviderEventName.SUBAGENT_STOP
    assert start.provider_work_id is not None
    assert start.provider_work_id.value == _expected_sidekick_id(_SESSION)
    assert stop.provider_work_id == start.provider_work_id
    assert start.parent_work_id is not None
    assert start.parent_work_id.value == _SESSION
    assert stop.parent_work_id == start.parent_work_id
    assert start.safe_label == "Sidekick"

    # --- scenario: sidekick_workers_are_scoped_to_their_session
    """Two sessions' sidekick calls must not share a WorkKey -- one
    session's PostToolUse would otherwise complete the other's worker."""
    first = _normalize(
        _devin_event(
            "PreToolUse",
            session_id="session-a",
            tool_name="sidekick",
            tool_input={"message": "hi"},
        )
    )
    second = _normalize(
        _devin_event(
            "PreToolUse",
            session_id="session-b",
            tool_name="sidekick",
            tool_input={"message": "hi"},
        )
    )

    assert type(first) is NormalizedProviderRecord
    assert type(second) is NormalizedProviderRecord
    assert first.provider_work_id != second.provider_work_id
    assert first.provider_work_id is not None
    assert first.provider_work_id.value == _expected_sidekick_id("session-a")
    assert second.provider_work_id is not None
    assert second.provider_work_id.value == _expected_sidekick_id("session-b")
    assert first.parent_work_id is not None
    assert first.parent_work_id.value == "session-a"
    assert second.parent_work_id is not None
    assert second.parent_work_id.value == "session-b"

    # --- scenario: ordinary_tool_events_keep_parent_identity
    record = _normalize(
        _devin_event(
            "PreToolUse",
            tool_name="exec",
            tool_input={"command": "make fast"},
        )
    )

    assert type(record) is NormalizedProviderRecord
    assert record.event_name is ProviderEventName.PRE_TOOL_USE
    assert record.provider_work_id is not None
    assert record.provider_work_id.value == _SESSION
    assert record.parent_work_id is None



def test_title_label_survives_the_normalized_payload_round_trip() -> None:
    record = _normalize(
        _devin_event(
            "PreToolUse",
            tool_name="run_subagent",
            tool_input={"title": "Audit the usage lanes"},
        )
    )
    assert type(record) is NormalizedProviderRecord

    decoded = normalized_provider_record_from_payload(
        normalized_provider_record_to_payload(record)
    )

    assert type(decoded) is NormalizedProviderRecord
    assert decoded.safe_label == "Audit the usage lanes"
    assert decoded.parent_work_id == record.parent_work_id


def _monitor_with_worker() -> tuple[LiveAgentMonitor, float]:
    # The monitor's clock is wall time, so the replayed events have to be
    # too -- a fixed fixture epoch ages every row past the presence horizon.
    base = time.time() - 60
    monitor = LiveAgentMonitor(stale_after_seconds=3600)
    monitor.ingest_record(_devin_event("SessionStart", epoch=base))
    monitor.ingest_record(
        _devin_event(
            "PreToolUse",
            epoch=base + 1,
            tool_name="run_subagent",
            tool_input={
                "title": "Background sweep",
                "is_background": True,
            },
        )
    )
    monitor.ingest_record(
        _devin_event(
            "PostToolUse",
            epoch=base + 2,
            tool_name="run_subagent",
            tool_input={
                "title": "Background sweep",
                "is_background": True,
            },
            tool_response={"success": True, "output": "launched"},
        )
    )
    return monitor, base


def test_worker_row_reaches_the_state_document__and_2_more() -> None:
    # --- scenario: worker_row_reaches_the_state_document
    monitor, base = _monitor_with_worker()
    snapshot = monitor.snapshot()

    document = build_state_document(
        now=base + 3,
        generation=1,
        snapshot=snapshot,
        ask_statuses=(),
        unseen_completion_ids=frozenset(),
        operator_state=snapshot.operator_state,
    )

    workers = [row for row in document["sessions"] if row["kind"] == "worker"]
    assert len(workers) == 1
    worker = workers[0]
    assert worker["parent"] == f"devin:session:{_SESSION}"
    assert worker["id"] == (
        f"devin:agent:{_expected_worker_id(_SESSION, 'Background sweep')}"
    )
    assert worker["label"] == "Background sweep"
    mains = [row for row in document["sessions"] if row["kind"] == "main"]
    assert any(row["workers"] >= 1 for row in mains)

    # --- scenario: parent_stop_does_not_retire_background_workers
    """Devin's Stop fires at the end of a TURN, and a backgrounded helper
    exists precisely to outlive the turn that launched it."""
    monitor, base = _monitor_with_worker()
    worker_key = f"devin:agent:{_expected_worker_id(_SESSION, 'Background sweep')}"

    monitor.ingest_record(_devin_event("Stop", epoch=base + 10))
    after = monitor.snapshot()

    worker = next(
        status for status in after.statuses if status.agent_id == worker_key
    )
    assert worker.mode.name != "COMPLETED"
    work = next(
        work
        for work in after.operator_state.works
        if work.key.work_id.value.startswith("sub-")
    )
    assert work.lifecycle is WorkLifecycle.ACTIVE

    # --- scenario: session_end_retires_background_workers
    monitor, base = _monitor_with_worker()
    worker_key = f"devin:agent:{_expected_worker_id(_SESSION, 'Background sweep')}"

    before = monitor.snapshot()
    live_worker = next(
        status for status in before.statuses if status.agent_id == worker_key
    )
    assert live_worker.mode.name in {"WORKING", "TOOL_RUNNING"}

    monitor.ingest_record(_devin_event("SessionEnd", epoch=base + 10))
    after = monitor.snapshot()

    worker = next(
        status for status in after.statuses if status.agent_id == worker_key
    )
    assert worker.mode.name == "COMPLETED"
    parent = next(
        status
        for status in after.statuses
        if status.agent_id == f"devin:session:{_SESSION}"
    )
    assert parent.mode.name == "COMPLETED"
    work = next(
        work
        for work in after.operator_state.works
        if work.key.work_id.value.startswith("sub-")
    )
    assert work.lifecycle is WorkLifecycle.COMPLETED



def test_same_title_calls_share_one_worker__and_2_more() -> None:
    # --- scenario: same_title_calls_share_one_worker
    """Pinning the known limitation: Devin's payload has no per-call id,
    so two concurrent ``run_subagent`` calls with the same title alias
    onto one worker -- the second start is a no-op on the shared row and
    the first PostToolUse completes it."""
    base = time.time() - 60
    monitor = LiveAgentMonitor(stale_after_seconds=3600)
    monitor.ingest_record(_devin_event("SessionStart", epoch=base))
    same_input = {"title": "Shared sweep"}
    monitor.ingest_record(
        _devin_event(
            "PreToolUse",
            epoch=base + 1,
            tool_name="run_subagent",
            tool_input=same_input,
        )
    )
    monitor.ingest_record(
        _devin_event(
            "PreToolUse",
            epoch=base + 2,
            tool_name="run_subagent",
            tool_input=same_input,
        )
    )
    snapshot = monitor.snapshot()
    workers = [status for status in snapshot.statuses if status.is_subagent]
    assert len(workers) == 1
    work = next(
        work
        for work in snapshot.operator_state.works
        if work.key.work_id.value.startswith("sub-")
    )
    assert work.lifecycle is WorkLifecycle.ACTIVE

    monitor.ingest_record(
        _devin_event(
            "PostToolUse",
            epoch=base + 3,
            tool_name="run_subagent",
            tool_input=same_input,
            tool_response={"success": True},
        )
    )
    after = monitor.snapshot()
    worker = next(
        status
        for status in (*after.statuses, *after.stale_statuses)
        if status.is_subagent
    )
    assert worker.mode.name == "COMPLETED"

    # --- scenario: a_stop_without_the_title_keeps_the_worker_label
    """A SUBAGENT_STOP that reaches the reducer with only the fallback
    label (e.g. a replayed record whose persisted label was the default)
    must not erase the title the row already holds."""
    monitor, base = _monitor_with_worker()
    worker_id = _expected_worker_id(_SESSION, "Background sweep")
    monitor.ingest_record(
        HookEvent(
            provider="devin",
            logged_at=datetime.fromtimestamp(base + 5, UTC),
            event_name="SubagentStop",
            raw={
                "hook_event_name": "SubagentStop",
                "session_id": _SESSION,
                "provider_work_id": worker_id,
                "parent_work_id": _SESSION,
                "safe_label": f"Devin {worker_id}",
            },
            session_id=_SESSION,
            agent_id=worker_id,
        )
    )

    snapshot = monitor.snapshot()
    work = next(
        work
        for work in snapshot.operator_state.works
        if work.key.work_id.value == worker_id
    )
    assert work.lifecycle is WorkLifecycle.COMPLETED
    assert work.safe_label == "Background sweep"

    # --- scenario: worker_label_falls_back_when_title_is_missing
    base = time.time() - 60
    monitor = LiveAgentMonitor(stale_after_seconds=3600)
    monitor.ingest_record(_devin_event("SessionStart", epoch=base))
    monitor.ingest_record(
        _devin_event(
            "PreToolUse",
            epoch=base + 1,
            tool_name="run_subagent",
            tool_input={"title": "", "task": "no name given"},
        )
    )

    snapshot = monitor.snapshot()
    # No title and no resume handle means no stable worker id can exist:
    # the record stays an ordinary parent event and no worker row appears.
    worker_rows = [
        status for status in snapshot.statuses if status.is_subagent
    ]
    assert worker_rows == []



def test_resume_call_without_title_names_the_worker_by_its_handle__and_2_more() -> None:
    # --- scenario: resume_call_without_title_names_the_worker_by_its_handle
    record = _normalize(
        _devin_event(
            "PreToolUse",
            tool_name="run_subagent",
            tool_input={"resume": "agent-77"},
        )
    )

    assert type(record) is NormalizedProviderRecord
    assert record.provider_work_id is not None
    assert record.provider_work_id.value == _expected_worker_id(_SESSION, "agent-77")
    assert record.safe_label == "agent-77"

    # --- scenario: session_first_prompt_names_the_session_row
    record = _normalize(
        _devin_event(
            "UserPromptSubmit",
            prompt="Fix the tank names\nso the fish read right",
        )
    )

    assert type(record) is NormalizedProviderRecord
    assert record.provider_work_id is not None
    assert record.provider_work_id.value == _SESSION
    assert record.parent_work_id is None
    assert record.safe_label == "Fix the tank names so the fish read right"

    # --- scenario: session_title_field_beats_the_prompt
    record = _normalize(
        _devin_event(
            "SessionStart",
            prompt="ignored prompt text",
        )
    )
    assert type(record) is NormalizedProviderRecord
    assert record.safe_label == f"Devin {_SESSION}"

    titled = _normalize(
        HookEvent(
            provider="devin",
            logged_at=datetime.fromtimestamp(_EPOCH, UTC),
            event_name="SessionStart",
            raw={
                "hook_event_name": "SessionStart",
                "session_id": _SESSION,
                "event_id": "event:titled",
                "session_title": "Aquarium overhaul",
            },
            session_id=_SESSION,
        )
    )
    assert type(titled) is NormalizedProviderRecord
    assert titled.safe_label == "Aquarium overhaul"



def test_session_label_survives_the_normalized_round_trip__and_2_more() -> None:
    # --- scenario: session_label_survives_the_normalized_round_trip
    record = _normalize(
        _devin_event(
            "UserPromptSubmit",
            prompt="Review the naming pipeline",
        )
    )
    assert type(record) is NormalizedProviderRecord

    decoded = normalized_provider_record_from_payload(
        normalized_provider_record_to_payload(record)
    )

    assert type(decoded) is NormalizedProviderRecord
    assert decoded.safe_label == "Review the naming pipeline"

    # And a replayed record re-minimized from its persisted payload
    # keeps the label instead of regressing to the slug.
    replayed = HookEvent(
        provider="devin",
        logged_at=datetime.fromtimestamp(_EPOCH + 5, UTC),
        event_name="Stop",
        raw=normalized_provider_record_to_payload(decoded),
        session_id=_SESSION,
    )
    reminimized = _normalize(replayed)
    assert type(reminimized) is NormalizedProviderRecord
    assert reminimized.safe_label == "Review the naming pipeline"

    # --- scenario: first_prompt_wins_over_later_prompts
    base = time.time() - 60
    monitor = LiveAgentMonitor(stale_after_seconds=3600)
    monitor.ingest_record(
        _devin_event("UserPromptSubmit", epoch=base, prompt="First task")
    )
    monitor.ingest_record(
        _devin_event("UserPromptSubmit", epoch=base + 10, prompt="Second task")
    )

    snapshot = monitor.snapshot()
    work = next(
        work
        for work in snapshot.operator_state.works
        if work.key.work_id.value == _SESSION
    )
    assert work.safe_label == "First task"

    # --- scenario: session_prompt_label_reaches_the_state_document
    base = time.time() - 60
    monitor = LiveAgentMonitor(stale_after_seconds=3600)
    monitor.ingest_record(_devin_event("SessionStart", epoch=base))
    monitor.ingest_record(
        _devin_event("UserPromptSubmit", epoch=base + 1, prompt="Rename the fish")
    )

    document = build_state_document(
        now=base + 3,
        generation=1,
        snapshot=monitor.snapshot(),
        ask_statuses=(),
        unseen_completion_ids=frozenset(),
        operator_state=monitor.snapshot().operator_state,
    )

    mains = [row for row in document["sessions"] if row["kind"] == "main"]
    assert mains[0]["label"] == "Rename the fish"



def test_slug_session_id_is_shown_whole_not_truncated__and_2_more() -> None:
    # --- scenario: slug_session_id_is_shown_whole_not_truncated
    from jrbar.core_projection import session_label

    label = session_label(
        provider="devin",
        session_id="cubic-class",
        agent_id="devin:session:cubic-class",
        display_name="Devin cubic-class",
        cwd=None,
        extras=None,
    )
    assert label == "Devin cubic-class"
    # A UUID-shaped id still shortens.
    uuid_label = session_label(
        provider="claude",
        session_id="fca1eb06-1234-4abc-9def-0123456789ab",
        agent_id="claude:session:fca1eb06-1234-4abc-9def-0123456789ab",
        display_name="Claude fca1eb06-1234-4abc-9def-0123456789ab",
        cwd=None,
        extras=None,
    )
    assert uuid_label == "Claude fca1eb06"

    # --- scenario: unrelated_devin_events_still_normalize
    record = _normalize(_devin_event("UserPromptSubmit"))

    assert type(record) is NormalizedProviderRecord
    assert record.event_name is ProviderEventName.USER_PROMPT_SUBMIT

    # --- scenario: compatibility_status_for_subagent_call_lands_on_parent
    """The raw record names no agent, so the legacy status is the parent's;
    the worker only exists as a canonical work row."""
    record = _devin_event(
        "PreToolUse",
        tool_name="run_subagent",
        tool_input={"title": "Delegated task"},
    )
    status = collector_module.status_from_event(record)

    assert status is not None
    assert status.agent_id == f"devin:session:{_SESSION}"
    assert not status.is_subagent

