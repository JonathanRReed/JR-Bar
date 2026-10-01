"""A worker is told from a main session by its kind, not by a substring.

An agent key is ``<provider>:<kind>:<id>``. A main session is ``session`` and a
worker is ``agent``, but the id is the provider's own and may hold anything,
``:agent:`` included, so ``claude:session:abc:agent:def`` is a main session.
``AgentStatus.is_subagent`` has always read it that way; the liveness sweep
and the mailbox's retained order tested the substring instead, so a main
session with such an id was sent a worker's ``SubagentStop`` when its process
died and lost its place in the mailbox on the next refresh.
"""

from __future__ import annotations

import json

import pytest

from jrbar import models
from jrbar import process_registry as pr
from jrbar.attention import LifecycleMode
from jrbar.liveness_sweep import synthetic_end_payloads
from jrbar.mailbox import MailboxSectionKind, project_mailbox
from tests.test_liveness_sweep import _status
from tests.test_mailbox import _projection, _row, _section

TRICKY_SESSION = "abc:agent:def"


def _dead(provider: str, session_id: str) -> pr.DeadAgentProcess:
    record = pr.AgentProcessRecord(provider, session_id, 10, 1.0, provider, "/w", 0.0)
    return pr.DeadAgentProcess(record, "process_exited")


def _events(provider: str, session_id: str, *statuses) -> list[dict]:
    return [json.loads(p) for p in synthetic_end_payloads(_dead(provider, session_id), statuses, now=5.0)]


def test_a_main_session_whose_id_holds_agent_is_ended_as_a_session_not_a_worker() -> None:
    main = _status("claude", f"claude:session:{TRICKY_SESSION}", TRICKY_SESSION)
    events = _events("claude", TRICKY_SESSION, main)
    assert [event["hook_event_name"] for event in events] == ["SessionEnd"]
    assert events[0]["session_id"] == TRICKY_SESSION


def test_the_workers_of_such_a_session_are_still_ended_first() -> None:
    main = _status("claude", f"claude:session:{TRICKY_SESSION}", TRICKY_SESSION)
    worker = _status("claude", "claude:agent:worker-1", TRICKY_SESSION)
    events = _events("claude", TRICKY_SESSION, main, worker)
    assert [event["hook_event_name"] for event in events] == ["SubagentStop", "SessionEnd"]
    assert events[0]["agent_id"] == "worker-1"


def test_a_peers_worker_is_ended_by_its_own_id_and_a_worker_id_may_hold_agent() -> None:
    peer = _status("claude", "remote:mac-mini:claude:agent:w1", "s")
    nested = _status("claude", "claude:agent:a:agent:b", "s")
    events = _events("claude", "s", peer, nested)
    assert [(event["hook_event_name"], event.get("agent_id")) for event in events] == [
        ("SubagentStop", "w1"),
        ("SubagentStop", "a:agent:b"),
        ("SessionEnd", None),
    ]


@pytest.mark.parametrize(
    ("provider", "agent_id", "expected"),
    [
        ("claude", "claude:agent:w1", "w1"),
        ("claude", "claude:agent:a:agent:b", "a:agent:b"),
        ("claude", "remote:mac-mini:claude:agent:w1", "w1"),
        ("claude", f"claude:session:{TRICKY_SESSION}", None),
        ("claude", f"remote:mac-mini:claude:session:{TRICKY_SESSION}", None),
        ("claude", "claude:agent:", ""),  # a worker kind with no id: still a worker
        ("claude", "claude:agent", None),
        ("claude", "codex:agent:w1", None),
        ("claude", "claude:unknown", None),
        ("claude", "", None),
        ("claude", "remote:", None),
        ("claude", "remote:mac-mini", None),
    ],
)
def test_worker_id_is_the_id_after_the_kind_when_the_kind_is_agent(
    provider: str, agent_id: str, expected: str | None
) -> None:
    assert models.worker_id(provider, agent_id) == expected


def test_a_main_sessions_place_in_the_mailbox_survives_an_agent_in_its_id() -> None:
    main = _row(f"claude:session:{TRICKY_SESSION}", LifecycleMode.ACTIVE, provider="claude")
    previous = {main.agent_id: 5}
    projected = project_mailbox(_projection(main), previous_order=previous)
    rows = _section(projected, MailboxSectionKind.IN_PROGRESS).rows
    assert [row.stable_order for row in rows] == [5]
    assert dict(projected.retained_order) == previous


def test_a_workers_place_is_still_not_retained() -> None:
    main = _row("claude:session:main", LifecycleMode.ACTIVE, provider="claude")
    previous = {"claude:session:main": 1, "claude:agent:old-worker": 2, "remote:mac:claude:agent:old": 3}
    projected = project_mailbox(_projection(main), previous_order=previous)
    assert dict(projected.retained_order) == {"claude:session:main": 1}



def _earlier_is_subagent(provider: str, agent_id: str) -> bool:
    """``AgentStatus.is_subagent`` before ``worker_id`` was split out of it."""
    if agent_id.startswith("remote:"):
        _namespace, separator, local = agent_id[len("remote:") :].partition(":")
        if separator:
            agent_id = local
    return agent_id.startswith(f"{provider}:agent:")


@pytest.mark.parametrize("provider", ["claude", "codex", "grok", ""])
@pytest.mark.parametrize(
    "agent_id",
    [
        "claude:agent:w1",
        "codex:agent:w1",
        "grok:agent:w1",
        ":agent:w1",
        "claude:agent:",
        "claude:agent",
        "claude:session:abc",
        f"claude:session:{TRICKY_SESSION}",
        "claude:agent:a:agent:b",
        "remote:mac:claude:agent:w1",
        "remote:mac:claude:session:abc",
        "remote:mac:",
        "remote:mac",
        "remote:",
        "remote",
        "claude:unknown",
        "claude",
        "",
    ],
)
def test_is_subagent_reads_every_key_as_it_did_before(provider: str, agent_id: str) -> None:
    status = _status(provider, agent_id, "s")
    assert status.is_subagent is _earlier_is_subagent(provider, agent_id)
