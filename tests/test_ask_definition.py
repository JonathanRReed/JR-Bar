"""One definition of "this status is an ask".

Four places each decided what an ask is: ``attention.actionable_request``,
``AgentStatus.is_hard_ask``, the announcer's legacy priority table and its
``legacy_announcer_status_is_answerable``. They agreed on a permission
prompt and a notification and disagreed on an MCP elicitation (the
``Elicitation`` hook: a server asking through Claude's own dialog): escalation
counted it, the light and the panel did not. They now share
``jrbar.models.ASK_EVENT_NAMES``. An elicitation is an ask, but a dialog is
never answered in place, so it stays out of the answerable set.
"""

from __future__ import annotations

import itertools
import json
from datetime import datetime, timedelta, timezone

from jrbar.announcer_stack import (
    _LEGACY_PRIORITY_BY_EVENT,
    AnnouncerAlertPriority,
    legacy_announcer_status_is_answerable,
)
from jrbar.attention import LifecycleMode, actionable_request, project_attention
from jrbar.collector import LiveAgentMonitor
from jrbar.models import (
    ASK_EVENT_NAMES,
    DIALOG_ASK_EVENT_NAMES,
    AgentMode,
    AgentStatus,
    is_ask_status,
)
from jrbar.operator_state import BootIdentifier, ClockSample
from jrbar.providers import parse_log_line
from jrbar.settings import AgentMonitorSettings
from tests.test_claude_elicitation_asks import BASE, ELICIT, NOW

WHEN = datetime(2026, 9, 30, tzinfo=timezone.utc)
EVENTS = (
    "PermissionRequest",
    "Notification",
    "Elicitation",
    "ElicitationResult",
    "PlanApproval",
    "PlanApprovalRequest",
    "ReviewRequest",
    "ReviewRequested",
    "InputRequest",
    "AskUserQuestion",
    "PreToolUse",
    "PostToolUse",
    "Stop",
    "Waiting",
    "SessionStart",
)


def _status(
    *,
    mode: AgentMode = AgentMode.WAITING_FOR_INPUT,
    event: str = "PermissionRequest",
    agent_id: str = "claude:session:main",
    provider: str = "claude",
    session_id: str | None = "main",
    tool_name: str | None = None,
) -> AgentStatus:
    return AgentStatus(
        provider=provider,
        agent_id=agent_id,
        display_name="Claude",
        mode=mode,
        updated_at=WHEN,
        event_name=event,
        session_id=session_id,
        tool_name=tool_name,
    )


# -- the definitions as they were before the shared one ----------------------


def _old_is_hard_ask(status: AgentStatus) -> bool:
    return status.mode == AgentMode.WAITING_FOR_INPUT and status.event_name in (
        "PermissionRequest",
        "Notification",
        "Elicitation",
    )


def _old_actionable_request(status: AgentStatus, settings: AgentMonitorSettings) -> bool:
    if ":agent:" in status.agent_id and not settings.subagent_asks_alert:
        return False
    return status.mode == AgentMode.WAITING_FOR_INPUT and status.event_name in {
        "PermissionRequest",
        "Notification",
    }


_OLD_LEGACY_PRIORITY = {
    "PermissionRequest": AnnouncerAlertPriority.PERMISSION,
    "PlanApproval": AnnouncerAlertPriority.APPROVAL,
    "PlanApprovalRequest": AnnouncerAlertPriority.APPROVAL,
    "ReviewRequest": AnnouncerAlertPriority.REVIEW,
    "ReviewRequested": AnnouncerAlertPriority.REVIEW,
    "Notification": AnnouncerAlertPriority.INPUT,
    "InputRequest": AnnouncerAlertPriority.INPUT,
    "AskUserQuestion": AnnouncerAlertPriority.INPUT,
}


def _old_answerable(status: AgentStatus) -> bool:
    return (
        status.mode is AgentMode.WAITING_FOR_INPUT
        and (status.tool_name == "ExitPlanMode" or status.event_name in _OLD_LEGACY_PRIORITY)
    )


CASES = tuple(
    itertools.product(
        tuple(AgentMode),
        EVENTS,
        ("claude:session:main", "claude:agent:worker"),
        (None, "ExitPlanMode", "Bash"),
    )
)


def test_the_one_definition_names_the_three_events_that_ask() -> None:
    assert ASK_EVENT_NAMES == {"PermissionRequest", "Notification", "Elicitation"}
    # An MCP dialog is an ask, and the one kind that is not answered in place.
    assert DIALOG_ASK_EVENT_NAMES == {"Elicitation"}
    assert DIALOG_ASK_EVENT_NAMES <= ASK_EVENT_NAMES


def test_is_hard_ask_and_the_shared_predicate_agree_on_every_case() -> None:
    for mode, event, agent_id, tool in CASES:
        status = _status(mode=mode, event=event, agent_id=agent_id, tool_name=tool)
        assert status.is_hard_ask is _old_is_hard_ask(status), (mode, event)
        assert is_ask_status(mode, event) is status.is_hard_ask


def test_actionable_request_is_unchanged_for_every_case_the_old_definitions_agreed_on() -> None:
    for allow_workers in (False, True):
        settings = AgentMonitorSettings(subagent_asks_alert=allow_workers)
        for mode, event, agent_id, tool in CASES:
            status = _status(mode=mode, event=event, agent_id=agent_id, tool_name=tool)
            expected = _old_actionable_request(status, settings)
            if event == "Elicitation" and mode is AgentMode.WAITING_FOR_INPUT:
                # The one deliberate change: an elicitation is an ask here too.
                expected = allow_workers or ":agent:" not in agent_id
            assert actionable_request(status, settings) is expected, (allow_workers, mode, event, agent_id)


def test_the_announcers_legacy_priority_table_gains_only_the_elicitation_dialog() -> None:
    assert _LEGACY_PRIORITY_BY_EVENT == {**_OLD_LEGACY_PRIORITY, "Elicitation": AnnouncerAlertPriority.INPUT}
    # Every event the shared definition calls an ask has a priority, so a new
    # one cannot be added to the definition and forgotten here.
    assert ASK_EVENT_NAMES <= set(_LEGACY_PRIORITY_BY_EVENT)


def test_answerable_is_unchanged_for_every_case__a_dialog_is_still_never_answered_in_place() -> None:
    for mode, event, agent_id, tool in CASES:
        status = _status(mode=mode, event=event, agent_id=agent_id, tool_name=tool)
        assert legacy_announcer_status_is_answerable(status) is _old_answerable(status), (mode, event, tool)
    waiting_dialog = _status(event="Elicitation")
    assert waiting_dialog.is_hard_ask
    assert not legacy_announcer_status_is_answerable(waiting_dialog)


def test_a_keyless_elicitation_is_an_ask_for_the_light_and_the_panel_as_it_is_for_escalation() -> None:
    """The case the old definitions split on: an Elicitation hook with no
    ``elicitation_id`` has no request to key on, so the status keeps the raw
    ``Elicitation`` event. Escalation counted it; the light read it as unknown."""
    payload = {key: value for key, value in ELICIT.items() if key != "elicitation_id"}
    offset = [0.0]

    def clock() -> ClockSample:
        return ClockSample(NOW.timestamp() + offset[0], 100.0 + offset[0], BootIdentifier("boot:keyless"))

    monitor = LiveAgentMonitor(clock_sampler=clock)
    for index, record in enumerate(({**BASE, "hook_event_name": "UserPromptSubmit", "prompt": "go"}, payload)):
        line = json.dumps({**record, "logged_at": (NOW + timedelta(seconds=index)).isoformat()})
        offset[0] = float(index) + 0.5
        monitor.ingest_record(parse_log_line("claude", line))
    snapshot = monitor.snapshot()
    (status,) = snapshot.statuses
    assert status.event_name == "Elicitation" and status.request_key is None
    assert status.is_hard_ask

    projection = project_attention(snapshot, AgentMonitorSettings())

    (row,) = projection.visible_rows
    assert row.actionable is True
    assert row.lifecycle_mode is LifecycleMode.WAITING
    assert projection.lifecycle_mode is LifecycleMode.WAITING
    assert [asking.agent_id for asking in projection.actionable_attention] == [status.agent_id]
    assert not legacy_announcer_status_is_answerable(status)
