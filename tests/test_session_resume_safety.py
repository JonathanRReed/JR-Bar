"""A session id comes from a hook payload, so it is data: never a flag."""

from __future__ import annotations

from datetime import datetime, timezone

import pytest

from jrbar.models import AgentMode, AgentStatus
from jrbar.session_actions import (
    session_resume_command,
    session_resume_parts,
    session_resume_parts_for,
)


def _status(provider: str, session_id: str) -> AgentStatus:
    return AgentStatus(
        provider=provider,
        agent_id=f"{provider}:session:x",
        display_name="Synthetic",
        mode=AgentMode.IDLE_READY,
        updated_at=datetime(2026, 10, 6, tzinfo=timezone.utc),
        event_name="Stop",
        session_id=session_id,
        cwd="/tmp/project",
    )


@pytest.mark.parametrize("provider", ["claude", "codex"])
@pytest.mark.parametrize("session_id", ["--dangerously-skip-permissions", "-p", "--yolo", "-"])
def test_a_session_id_that_opens_with_a_dash_never_reaches_a_resume_command(provider: str, session_id: str) -> None:
    status = _status(provider, session_id)
    assert session_resume_command(status) is None
    assert session_resume_parts(status) is None
    assert session_resume_parts_for(provider, session_id, "/tmp/project") is None


def test_an_ordinary_session_id_still_resumes() -> None:
    status = _status("claude", "019ee395-2f64-7cc3-b566-afcc1d626160")
    assert session_resume_command(status) == "cd /tmp/project && claude --resume 019ee395-2f64-7cc3-b566-afcc1d626160"
