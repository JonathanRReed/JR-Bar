"""A Grok sub-agent groups under its session and follows the sub-agent rules.

Grok runs a sub-agent in a child session of its own. Every hook the child
fires arrives with the CHILD's session id and a ``subagentType``, and nothing
in those payloads names the session that spawned it. The only link is on the
parent's side: ``SubagentStart`` fires in the parent session and carries the
child's session id as ``subagentId``. JR-Bar remembers that link and stamps the
child's later events the way Claude stamps a worker (``agent_id`` the child,
``session_id`` the ROOT session; OpenCode's plugin does the same), so the child
is a sub-agent row under its session, its asks follow the Sub-agent asks
setting, and it never counts toward keep-awake. Before this, a Grok
sub-agent's ask was an ordinary main-session ask whatever that setting said.

The event sequence below was captured from one real ``grok -p`` run (grok
1.0.44, one sub-agent, a throwaway directory, the JR-Bar shim spooling into a
throwaway state folder) and reduced to synthetic values: ids, paths, prompt and
answer text are made up, and the key names and shapes are kept. The sub-agent's
ask is not from the capture (the run asked for nothing); it uses the
``Notification`` / ``notificationType`` shape of Grok's own hook guide.
"""

from __future__ import annotations

import json
from dataclasses import replace
from datetime import datetime, timedelta, timezone
from pathlib import Path

import pytest

from jrbar import core_power
from jrbar._collector_legacy import LiveAgentMonitor
from jrbar.attention import LifecycleMode, actionable_request, project_attention
from jrbar.hook import HookProcessingOutcome, process_hook_payload, routed_hook_payload
from jrbar.models import AgentMode, AgentStatus
from jrbar.settings import AgentMonitorSettings

PARENT = "11111111-1111-4111-8111-111111111111"
CHILD = "22222222-2222-4222-8222-222222222222"
GRANDCHILD = "33333333-3333-4333-8333-333333333333"
STAMP = "2026-10-01T16:00:00.000000000Z"


def _transcript(session: str) -> dict[str, object]:
    path = f"/tmp/work/.grok/sessions/{session}/updates.json"
    return {"transcriptPath": path, "transcript_path": path}


def _event(name: str, snake: str, session: str, **extra: object) -> dict[str, object]:
    """One Grok hook payload: the common envelope, then the event's own keys."""
    return {
        "hookEventName": snake,
        "hook_event_name": name,
        "sessionId": session,
        "session_id": session,
        "cwd": "/tmp/work",
        "workspaceRoot": "/tmp/work",
        "timestamp": STAMP,
        "permissionMode": "bypassPermissions",
        "permission_mode": "bypassPermissions",
        **extra,
    }


def _spawn_input() -> dict[str, object]:
    return {"background": False, "description": "synthetic task", "prompt": "synthetic prompt"}


def _tool(session: str, name: str, **extra: object) -> dict[str, object]:
    return {
        **_transcript(session),
        "toolName": "spawn_subagent",
        "tool_name": "spawn_subagent",
        "toolUseId": "call_synthetic0001",
        "tool_use_id": "call_synthetic0001",
        "toolInput": _spawn_input(),
        "tool_input": _spawn_input(),
        "toolInputTruncated": False,
        **extra,
    }


def start(session: str = PARENT) -> dict[str, object]:
    return _event("SessionStart", "session_start", session, source="new")


def prompt(session: str = PARENT, **extra: object) -> dict[str, object]:
    return _event("UserPromptSubmit", "user_prompt_submit", session, promptId="prompt-0001", prompt="synthetic prompt", **extra)


def pre_tool(session: str = PARENT) -> dict[str, object]:
    return _event("PreToolUse", "pre_tool_use", session, **_tool(session, "spawn_subagent"))


def subagent_start(session: str = PARENT, child: str = CHILD) -> dict[str, object]:
    return _event(
        "SubagentStart",
        "subagent_start",
        session,
        **_transcript(session),
        subagentId=child,
        subagentType="general-purpose",
        description="synthetic task",
    )


def child_prompt(child: str = CHILD) -> dict[str, object]:
    return prompt(child, subagentType="general-purpose")


def subagent_stop(child: str = CHILD) -> dict[str, object]:
    return _event(
        "SubagentStop",
        "subagent_stop",
        child,
        **_transcript(child),
        promptId="prompt-0002",
        phase="gate",
        subagentId=child,
        subagentType="general-purpose",
        stopHookActive=False,
        lastAssistantMessage="OK",
    )


def child_end(child: str = CHILD) -> dict[str, object]:
    return _event(
        "SessionEnd", "session_end", child, **_transcript(child), reason="shutdown", subagentType="general-purpose"
    )


def post_tool(session: str = PARENT) -> dict[str, object]:
    return _event(
        "PostToolUse",
        "post_tool_use",
        session,
        **_tool(session, "spawn_subagent"),
        durationMs=1200,
        duration_ms=1200,
        isBackgrounded=False,
        toolResult="synthetic result",
        tool_response="synthetic result",
        toolResultTruncated=False,
    )


def stop(session: str = PARENT) -> dict[str, object]:
    return _event(
        "Stop",
        "stop",
        session,
        **_transcript(session),
        promptId="prompt-0001",
        reason="end_turn",
        stopHookActive=False,
        lastAssistantMessage="DONE",
        backgroundTasks=[],
        sessionCrons=[],
    )


def end(session: str = PARENT) -> dict[str, object]:
    return _event("SessionEnd", "session_end", session, **_transcript(session), reason="shutdown")


def child_ask(child: str = CHILD) -> dict[str, object]:
    return _event(
        "Notification",
        "notification",
        child,
        notificationType="permission_prompt",
        message="synthetic permission prompt",
        subagentType="general-purpose",
    )


#: The whole captured run, in the order its hooks fired.
CAPTURED_RUN = (
    start(),
    prompt(),
    pre_tool(),
    subagent_start(),
    child_prompt(),
    subagent_stop(),
    child_end(),
    post_tool(),
    stop(),
    end(),
)


def _ago(seconds: float) -> str:
    moment = datetime.now(timezone.utc) - timedelta(seconds=seconds)
    return moment.strftime("%Y-%m-%dT%H:%M:%S.%fZ")


def _feed(tmp_path: Path, payloads: list[dict[str, object]], *, provider: str = "grok") -> LiveAgentMonitor:
    """Run payloads through the product's own hook path, oldest first, into a monitor."""
    log = tmp_path / "grok.jsonl"
    monitor = LiveAgentMonitor()
    for index, payload in enumerate(payloads):
        outcome = process_hook_payload(
            provider,
            log,
            json.dumps(payload),
            logged_at=_ago(60.0 - index),
            refresh_hint_handler=lambda hint: monitor.reconcile_refresh_hint(hint, log_path=log),
        )
        assert outcome is HookProcessingOutcome.WRITTEN, (index, payload["hook_event_name"])
    return monitor


def _rows(monitor: LiveAgentMonitor) -> dict[str, AgentStatus]:
    return {status.agent_id: status for status in monitor.snapshot().statuses}


def test_a_child_session_is_a_worker_row_under_its_parent(tmp_path: Path) -> None:
    # --- scenario: every event the child fires after SubagentStart lands on the worker
    monitor = _feed(tmp_path, [start(), prompt(), pre_tool(), subagent_start(), child_prompt()])
    rows = _rows(monitor)

    assert set(rows) == {f"grok:session:{PARENT}", f"grok:agent:{CHILD}"}, sorted(rows)
    child = rows[f"grok:agent:{CHILD}"]
    assert child.is_subagent
    assert child.parent_agent_id == f"grok:session:{PARENT}"
    assert child.mode is AgentMode.WORKING
    parent = rows[f"grok:session:{PARENT}"]
    assert not parent.is_subagent and parent.parent_agent_id is None


def test_the_childs_ask_follows_the_sub_agent_asks_setting(tmp_path: Path) -> None:
    # --- scenario: muted by default, alerting when Sub-agent asks is on
    # Grok's own notification names no request, so it is a Waiting row for a
    # main session and a child alike; an ask that carries a request id is a
    # live request, and that is the one the setting gates.
    ask = {**child_ask(), "requestId": "request-0001"}
    monitor = _feed(tmp_path, [start(), prompt(), subagent_start(), child_prompt(), ask])
    child = _rows(monitor)[f"grok:agent:{CHILD}"]
    snapshot = monitor.snapshot()

    assert child.mode is AgentMode.WAITING_FOR_INPUT
    assert actionable_request(child, AgentMonitorSettings()) is False
    assert actionable_request(child, replace(AgentMonitorSettings(), subagent_asks_alert=True)) is True
    assert project_attention(snapshot, AgentMonitorSettings()).actionable_attention == ()
    alerting = project_attention(snapshot, replace(AgentMonitorSettings(), subagent_asks_alert=True))
    assert [row.agent_id for row in alerting.actionable_attention] == [f"grok:agent:{CHILD}"]


def test_a_childs_waiting_is_not_its_sessions(tmp_path: Path) -> None:
    # --- scenario: the parent keeps reading Working while the child waits
    monitor = _feed(tmp_path, [start(), prompt(), subagent_start(), child_prompt(), child_ask()])
    projection = project_attention(monitor.snapshot(), AgentMonitorSettings())

    assert [row.agent_id for row in projection.visible_rows] == [f"grok:session:{PARENT}"]
    assert projection.lifecycle_mode is LifecycleMode.ACTIVE
    assert _rows(monitor)[f"grok:session:{PARENT}"].mode is AgentMode.WORKING


def test_the_child_never_counts_toward_keep_awake(tmp_path: Path) -> None:
    # --- scenario: only the parent session counts as running or waiting
    monitor = _feed(tmp_path, [start(), prompt(), subagent_start(), child_prompt(), child_ask()])
    pending, working = core_power.session_facts(monitor.snapshot())

    assert pending == frozenset({f"grok:session:{PARENT}"})
    assert working == 1


def test_the_whole_captured_run_never_shows_the_child_as_a_session(tmp_path: Path) -> None:
    # --- scenario: the child's stop and end finish the worker, and the parent ends as one session
    seen: list[set[str]] = []
    log = tmp_path / "grok.jsonl"
    monitor = LiveAgentMonitor()
    for index, payload in enumerate(CAPTURED_RUN):
        process_hook_payload(
            "grok",
            log,
            json.dumps(payload),
            logged_at=_ago(60.0 - index),
            refresh_hint_handler=lambda hint: monitor.reconcile_refresh_hint(hint, log_path=log),
        )
        seen.append({status.agent_id for status in monitor.snapshot().statuses})

    assert all(f"grok:session:{CHILD}" not in ids for ids in seen)
    assert f"grok:agent:{CHILD}" in seen[4]
    works = {work.key.work_id.value: work for work in monitor.snapshot().operator_state.works}
    assert works[CHILD].parent_key is not None and works[CHILD].parent_key.work_id.value == PARENT
    assert works[PARENT].parent_key is None


def test_the_claude_hook_slot_carries_the_same_events_to_the_same_rows() -> None:
    # --- scenario: Grok loads Claude's hooks too, so the shim also runs as --provider claude
    for payload in (start(), prompt(), subagent_start()):
        routed_hook_payload("claude", Path("/tmp/claude.jsonl"), json.dumps(payload))
    provider, _log, line = routed_hook_payload("claude", Path("/tmp/claude.jsonl"), json.dumps(child_prompt()))

    assert provider == "grok"
    assert line["agent_id"] == CHILD and line["session_id"] == PARENT


def test_a_child_whose_start_was_never_seen_is_a_top_level_row_as_before(tmp_path: Path) -> None:
    # --- scenario: no link means no guess; an unlinked child keeps today's behaviour
    monitor = _feed(tmp_path, [start(), prompt(), child_prompt()])

    assert set(_rows(monitor)) == {f"grok:session:{PARENT}", f"grok:session:{CHILD}"}


def test_a_grandchild_groups_under_the_root_session(tmp_path: Path) -> None:
    # --- scenario: a sub-agent's own sub-agent is a worker of the same root
    monitor = _feed(
        tmp_path,
        [
            start(),
            prompt(),
            subagent_start(PARENT, CHILD),
            child_prompt(CHILD),
            subagent_start(CHILD, GRANDCHILD),
            child_prompt(GRANDCHILD),
        ],
    )
    rows = _rows(monitor)

    assert set(rows) == {f"grok:session:{PARENT}", f"grok:agent:{CHILD}", f"grok:agent:{GRANDCHILD}"}
    assert rows[f"grok:agent:{GRANDCHILD}"].parent_agent_id == f"grok:session:{PARENT}"
    assert rows[f"grok:agent:{CHILD}"].parent_agent_id == f"grok:session:{PARENT}"


def test_a_subagents_own_cancel_is_still_dropped_when_it_is_linked(tmp_path: Path) -> None:
    # --- scenario: StopCancelled with a subagentType never reaches the row, linked or not
    cancelled = _event(
        "StopCancelled", "stop_cancelled", CHILD, reason="max_turns", cancelledBy="agent", subagentType="general-purpose"
    )
    log = tmp_path / "grok.jsonl"
    monitor = LiveAgentMonitor()
    for index, payload in enumerate([start(), prompt(), subagent_start(), child_prompt()]):
        process_hook_payload(
            "grok", log, json.dumps(payload), logged_at=_ago(60.0 - index),
            refresh_hint_handler=lambda hint: monitor.reconcile_refresh_hint(hint, log_path=log),
        )
    outcome = process_hook_payload("grok", log, json.dumps(cancelled), logged_at=_ago(5.0))

    assert outcome is HookProcessingOutcome.IGNORED
    assert _rows(monitor)[f"grok:agent:{CHILD}"].mode is AgentMode.WORKING


def test_routing_stamps_only_grok_lines() -> None:
    # --- scenario: the stamp is Grok's; another provider's subagentId means nothing here
    remembered = routed_hook_payload("grok", Path("/tmp/grok.jsonl"), json.dumps(subagent_start()))[2]
    assert remembered["agent_id"] == CHILD and remembered["session_id"] == PARENT

    child = routed_hook_payload("grok", Path("/tmp/grok.jsonl"), json.dumps(child_prompt()))[2]
    assert child["agent_id"] == CHILD and child["session_id"] == PARENT

    other = routed_hook_payload("devin", Path("/tmp/devin.jsonl"), json.dumps(child_prompt()))[2]
    assert "agent_id" not in other and other["session_id"] == CHILD
    main = routed_hook_payload("grok", Path("/tmp/grok.jsonl"), json.dumps(prompt()))[2]
    assert "agent_id" not in main and main["session_id"] == PARENT


@pytest.fixture(autouse=True)
def _fresh_links():
    """The link table is process-wide; every test starts without links."""
    from jrbar import hook

    links = getattr(hook, "GROK_CHILD_LINKS", None)
    if links is not None:
        links.clear()
    yield
    if links is not None:
        links.clear()


# --- the link table ------------------------------------------------------------


def test_the_table_finds_the_root_through_nested_children() -> None:
    from jrbar.grok_children import GrokChildLinks

    links = GrokChildLinks()
    assert links.remember(CHILD, PARENT) and links.remember(GRANDCHILD, CHILD)

    assert links.root_of(GRANDCHILD) == PARENT
    assert links.root_of(CHILD) == PARENT
    # A main session, and a session nobody linked, are not children.
    assert links.root_of(PARENT) is None
    assert links.root_of("unlinked") is None


def test_the_table_refuses_a_loop_a_self_link_and_an_id_that_is_not_opaque() -> None:
    from jrbar.grok_children import MAX_LINK_DEPTH, GrokChildLinks

    links = GrokChildLinks()
    assert links.remember(CHILD, PARENT)
    assert not links.remember(PARENT, CHILD), "a parent made the child's child"
    assert not links.remember(CHILD, CHILD)
    for bad in ("", "has space", "a/b", "x" * 129, "sk-live-123", "token:abc", "api_key.abc", "é"):
        assert not links.remember(bad, PARENT), bad
        assert not links.remember(CHILD, bad), bad
    assert links.root_of(CHILD) == PARENT

    deep = GrokChildLinks()
    names = [f"session-{index}" for index in range(MAX_LINK_DEPTH + 2)]
    results = [deep.remember(child, parent) for child, parent in zip(names[1:], names, strict=False)]
    # The cap is on links: a chain at it still finds its root, one link past it is refused.
    assert results == [True] * MAX_LINK_DEPTH + [False]
    assert deep.root_of(names[MAX_LINK_DEPTH]) == names[0]
    assert deep.root_of(names[MAX_LINK_DEPTH + 1]) is None


def test_the_table_is_bounded_and_keeps_the_child_that_keeps_talking() -> None:
    from jrbar.grok_children import GrokChildLinks

    links = GrokChildLinks(limit=3)
    for index in range(3):
        links.remember(f"child-{index}", PARENT)
    links.remember("child-0", PARENT)  # child-0 spoke again: now the newest
    links.remember("child-3", PARENT)

    assert len(links) == 3
    assert links.root_of("child-1") is None, "the quietest link is the one evicted"
    assert links.root_of("child-0") == PARENT and links.root_of("child-3") == PARENT
    with pytest.raises(ValueError):
        GrokChildLinks(limit=0)


def test_a_child_that_only_sends_events_is_not_evicted_before_a_quiet_one() -> None:
    """Only SubagentStart creates a link, so recency must also follow the
    child's own later events (root_of), or the busiest child goes first."""
    from jrbar.grok_children import GrokChildLinks

    links = GrokChildLinks(limit=3)
    for index in range(3):
        links.remember(f"child-{index}", PARENT)
    for _ in range(5):
        assert links.root_of("child-0") == PARENT  # events from child-0, no new link
    links.remember("child-3", PARENT)

    assert links.root_of("child-0") == PARENT, "the busy child stays"
    assert links.root_of("child-1") is None, "the quietest link is the one evicted"


def test_stamping_copies_the_line_and_leaves_everything_else_alone() -> None:
    from jrbar.grok_children import GrokChildLinks, stamp_child_identity

    links = GrokChildLinks()
    main = prompt()
    assert stamp_child_identity(main, links) is main

    start_line = subagent_start()
    stamped = stamp_child_identity(start_line, links)
    assert stamped is not start_line
    assert start_line["session_id"] == PARENT and "agent_id" not in start_line
    assert (stamped["agent_id"], stamped["session_id"], stamped["sessionId"]) == (CHILD, PARENT, PARENT)

    # An event with neither id, an id that is not opaque, or a start that
    # names no child changes nothing.
    for odd in (
        {"hook_event_name": "SubagentStart"},
        {**subagent_start(), "subagentId": "not opaque!"},
        {**subagent_start(), "subagentId": PARENT},
        {**subagent_start(), "subagentId": None},
    ):
        assert stamp_child_identity(odd, GrokChildLinks()) == odd


def test_a_start_in_snake_case_keys_links_too() -> None:
    from jrbar.grok_children import GrokChildLinks, stamp_child_identity

    links = GrokChildLinks()
    start_line = {"hook_event_name": "SubagentStart", "session_id": PARENT, "subagent_id": CHILD}
    assert stamp_child_identity(start_line, links)["agent_id"] == CHILD
    later = stamp_child_identity({"hook_event_name": "Stop", "session_id": CHILD}, links)
    assert (later["agent_id"], later["session_id"]) == (CHILD, PARENT)
