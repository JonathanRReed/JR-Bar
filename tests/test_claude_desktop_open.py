"""Opening a session Claude.app runs lands on that session, not on whichever
one the app showed last (session_actions.claude_desktop_link)."""

from __future__ import annotations

import json
import os
from datetime import datetime, timezone
from pathlib import Path

from jrbar.capacity_types import SourceKey
from jrbar.models import AgentMode, AgentStatus
from jrbar.navigation_policy import navigation_target_allowed
from jrbar.provider_facts import WorkIdentifier, WorkKey
from jrbar.session_actions import (
    ClaudeDesktopSessions,
    claude_desktop_link,
    session_open_target,
)

CLI_ID = "10095578-e911-4aa0-b668-c962688d3042"
LOCAL_ID = "local_0b4cb2d9-5d1e-4c6f-9d0a-6b3f1e2a7c44"


def _status(origin: str | None = "Claude App", session_id: str = CLI_ID) -> AgentStatus:
    return AgentStatus(
        provider="claude",
        agent_id=f"claude:session:{session_id}",
        display_name="Claude",
        mode=AgentMode.WAITING_FOR_INPUT,
        updated_at=datetime.now(timezone.utc),
        event_name="Notification",
        session_id=session_id,
        cwd="/Users/me/repo",
        origin=origin,
    )


def _store(tmp_path: Path) -> Path:
    root = tmp_path / "claude-code-sessions"
    org = root / "acct-1" / "org-1"
    org.mkdir(parents=True)
    (org / f"{LOCAL_ID}.json").write_text(
        json.dumps({"sessionId": LOCAL_ID, "cliSessionId": CLI_ID, "title": "Scaling LLC project setup"})
    )
    return root


def test_an_app_session_opens_by_its_local_id__and_3_more(tmp_path: Path) -> None:
    root = _store(tmp_path)
    sessions = ClaudeDesktopSessions(root)

    # --- scenario: the store's cliSessionId names the local_ id the app opens by
    assert claude_desktop_link(_status(), sessions) == f"claude://code/continue?session={LOCAL_ID}"
    assert claude_desktop_link(_status(origin=None), sessions) == f"claude://code/continue?session={LOCAL_ID}"

    # --- scenario: a session the store does not know, or a CLI row, is no match
    assert claude_desktop_link(_status(session_id="someone-else"), sessions) is None
    assert claude_desktop_link(_status(origin="Claude Code CLI"), sessions) is None
    assert claude_desktop_link(_status(origin="Claude in VS Code"), sessions) is None

    # --- scenario: a new session is found once its directory changes, unchanged files are not reread
    org = root / "acct-1" / "org-1"
    later = "local_7a7a7a7a-0000-4000-8000-000000000001"
    (org / f"{later}.json").write_text(json.dumps({"sessionId": later, "cliSessionId": "second-cli"}))
    stamp = os.stat(org).st_mtime_ns + 1_000_000_000
    os.utime(org, ns=(stamp, stamp))
    reads: list[str] = []
    import jrbar.session_actions as module

    original = module._read_claude_session

    def counting(path: str, size: int):
        reads.append(Path(path).name)
        return original(path, size)

    module._read_claude_session = counting
    try:
        assert claude_desktop_link(_status(session_id="second-cli"), sessions) == (
            f"claude://code/continue?session={later}"
        )
        assert reads == [f"{later}.json"]
        reads.clear()
        assert claude_desktop_link(_status(), sessions) == f"claude://code/continue?session={LOCAL_ID}"
        assert reads == []
    finally:
        module._read_claude_session = original

    # --- scenario: a missing store, a malformed file or a foreign id shape falls back
    assert claude_desktop_link(_status(), ClaudeDesktopSessions(tmp_path / "absent")) is None
    bad = tmp_path / "bad-store"
    (bad / "a" / "b").mkdir(parents=True)
    (bad / "a" / "b" / "local_1.json").write_text("{not json")
    (bad / "a" / "b" / "local_2.json").write_text(
        json.dumps({"sessionId": "local_../../etc", "cliSessionId": CLI_ID})
    )
    (bad / "a" / "b" / "local_3.json").write_text(json.dumps(["sessionId", LOCAL_ID]))
    assert claude_desktop_link(_status(), ClaudeDesktopSessions(bad)) is None


def test_only_claude_apps_own_url_shapes_are_allowed() -> None:
    key = WorkKey(SourceKey("claude", "hooks", "local:01", "live_agent_events"), WorkIdentifier("work:01"))
    for allowed in (
        "claude://",
        "claude://code/needs-input",
        f"claude://code/continue?session={LOCAL_ID}",
    ):
        assert navigation_target_allowed(key, "url", allowed), allowed
    for refused in (
        f"claude://code/continue?session={CLI_ID}",
        "claude://code/continue?session=local_x&then=1",
        "claude://code/continue?session=local_../x",
        f"claude://code/continue?session={LOCAL_ID}#frag",
        "claude://code/needs-input?session=local_a",
        "claude://settings",
    ):
        assert not navigation_target_allowed(key, "url", refused), refused
    codex = WorkKey(SourceKey("codex", "hooks", "local:01", "live_agent_events"), WorkIdentifier("work:01"))
    assert not navigation_target_allowed(codex, "url", f"claude://code/continue?session={LOCAL_ID}")


def test_the_app_open_target_passes_its_own_allowlist(tmp_path: Path, monkeypatch) -> None:
    import jrbar.session_actions as module

    monkeypatch.setattr(module, "_CLAUDE_DESKTOP_SESSIONS", ClaudeDesktopSessions(_store(tmp_path)))
    kind, value = session_open_target(_status(), "app")
    key = WorkKey(SourceKey("claude", "hooks", "local:01", "live_agent_events"), WorkIdentifier("work:01"))
    assert (kind, value) == ("url", f"claude://code/continue?session={LOCAL_ID}")
    assert navigation_target_allowed(key, kind, value)
