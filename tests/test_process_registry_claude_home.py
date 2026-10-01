"""Claude's own pid files are read from the Claude home the person actually uses.

Claude Code writes ``<config home>/sessions/<pid>.json`` for each live
session. ``CLAUDE_CONFIG_DIR`` moves that home, and install and detect already
follow it (provider_homes); the process registry used to read
``~/.claude/sessions`` regardless, so on a moved home no session was ever
vouched alive by its pid file and every one fell back to the silence clock.
"""

from __future__ import annotations

import json
from pathlib import Path

import pytest

from jrbar import process_registry as pr


def _write_session(home: Path, pid: int, session_id: str, *, name: str = "named", cwd: str = "/work/demo") -> None:
    folder = home / "sessions"
    folder.mkdir(parents=True, exist_ok=True)
    (folder / f"{pid}.json").write_text(
        json.dumps({"pid": pid, "sessionId": session_id, "startedAt": 1788978889983, "name": name, "cwd": cwd}),
        encoding="utf-8",
    )


@pytest.fixture
def homes(tmp_path: Path, monkeypatch: pytest.MonkeyPatch) -> tuple[Path, Path]:
    """A user's home with a default ``.claude`` and a moved Claude home, both with a session."""
    user_home = tmp_path / "user"
    moved = tmp_path / "moved-claude"
    monkeypatch.setenv("HOME", str(user_home))
    monkeypatch.delenv("CLAUDE_CONFIG_DIR", raising=False)
    _write_session(user_home / ".claude", 4101, "default-home-session", name="default")
    _write_session(moved, 4202, "moved-home-session", name="moved")
    return user_home / ".claude", moved


def test_the_session_index_follows_a_moved_claude_home(homes: tuple[Path, Path], monkeypatch: pytest.MonkeyPatch) -> None:
    _, moved = homes
    monkeypatch.setenv("CLAUDE_CONFIG_DIR", str(moved))
    index = pr.claude_session_index()
    assert set(index) == {"moved-home-session"}
    assert index["moved-home-session"].pid == 4202


def test_the_session_details_follow_a_moved_claude_home(homes: tuple[Path, Path], monkeypatch: pytest.MonkeyPatch) -> None:
    _, moved = homes
    monkeypatch.setenv("CLAUDE_CONFIG_DIR", str(moved))
    assert pr.claude_session_details("moved-home-session", 4202) == {"name": "moved", "cwd": "/work/demo"}
    assert pr.claude_session_details("default-home-session", 4101) is None


def test_with_no_moved_home_the_default_claude_home_is_read(homes: tuple[Path, Path]) -> None:
    assert set(pr.claude_session_index()) == {"default-home-session"}
    assert pr.claude_session_details("default-home-session")["name"] == "default"


def test_a_stale_variable_naming_no_folder_falls_back_to_the_default_home(
    homes: tuple[Path, Path], monkeypatch: pytest.MonkeyPatch, tmp_path: Path
) -> None:
    monkeypatch.setenv("CLAUDE_CONFIG_DIR", str(tmp_path / "gone"))
    assert set(pr.claude_session_index()) == {"default-home-session"}


def test_an_explicit_sessions_folder_still_wins_over_the_environment(
    homes: tuple[Path, Path], monkeypatch: pytest.MonkeyPatch
) -> None:
    default_home, moved = homes
    monkeypatch.setenv("CLAUDE_CONFIG_DIR", str(moved))
    assert set(pr.claude_session_index(default_home / "sessions")) == {"default-home-session"}
    assert pr.claude_session_details("default-home-session", 4101, default_home / "sessions") is not None
    assert pr.claude_session_details("moved-home-session", 4202, default_home / "sessions") is None
