"""A worker is told by the kind that follows its provider.

``claude:agent:<id>`` is a worker and ``claude:session:<id>`` is a main
session. The id after the kind is the provider's own and may hold a colon and
anything past it, so ``:agent:`` appearing somewhere inside it proves nothing.
A peer's rows carry ``remote:<machine>:`` in front of the same form.
"""

from __future__ import annotations

from datetime import datetime, timezone

import pytest

from jrbar.attention import actionable_request
from jrbar.models import AgentMode, AgentStatus
from jrbar.settings import AgentMonitorSettings

WHEN = datetime(2026, 9, 30, tzinfo=timezone.utc)


def _status(*, agent_id: str, provider: str = "claude", session_id: str | None = "main") -> AgentStatus:
    return AgentStatus(
        provider=provider,
        agent_id=agent_id,
        display_name="Claude",
        mode=AgentMode.WAITING_FOR_INPUT,
        updated_at=WHEN,
        event_name="PermissionRequest",
        session_id=session_id,
    )


@pytest.mark.parametrize(
    ("provider", "agent_id", "worker"),
    (
        ("claude", "claude:agent:a70f42924b7bb211d", True),
        ("claude", "claude:session:fca1eb06", False),
        ("devin", "devin:agent:sub-1", True),
        # A provider's own work id may hold a colon and anything after it.
        ("claude", "claude:session:abc:agent:def", False),
        ("claude", "claude:agent:abc:agent:def", True),
        ("opencode", "opencode:session:ses:agent:x", False),
        # A peer's rows carry its machine in front; machine names hold no colon.
        ("claude", "remote:mac-b:claude:agent:worker", True),
        ("claude", "remote:mac-b:claude:session:aaa", False),
        ("claude", "remote:mac-b:claude:session:aaa:agent:bbb", False),
        # No kind, no provider prefix, or another provider's: not a worker.
        ("claude", "claude:unknown", False),
        ("claude", "agent:worker", False),
        ("claude", "codex:agent:worker", False),
        ("claude", "", False),
    ),
)
def test_a_worker_is_the_kind_that_follows_its_provider(provider: str, agent_id: str, worker: bool) -> None:
    status = _status(provider=provider, agent_id=agent_id, session_id="main")

    assert status.is_subagent is worker
    assert status.parent_agent_id == (f"{provider}:session:main" if worker else None)


def test_a_main_session_whose_id_holds_agent_is_not_its_own_child() -> None:
    status = _status(agent_id="claude:session:abc:agent:def", session_id="abc:agent:def")

    assert not status.is_subagent
    assert status.parent_agent_id is None
    settings = AgentMonitorSettings(subagent_asks_alert=False)
    # The ask is a main session's, so the quiet-workers setting never mutes it.
    assert actionable_request(status, settings) is True
