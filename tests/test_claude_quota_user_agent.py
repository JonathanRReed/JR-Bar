"""The usage request names the Claude Code version that is installed.

A fixed old version string is the kind of thing a server starts refusing
(OpenUsage saw a stale ``claude-code/2.1.69`` answered "ineligible"). The
version is read from Claude's own ``sessions/<pid>.json`` files, no process
is started, and a missing or odd value falls back to the packaged one.
"""

from __future__ import annotations

import json
import os
from pathlib import Path

import pytest

from jrbar import claude_quota

PAYLOAD = json.dumps({"five_hour": {"utilization": 10, "resets_at": "2026-10-07T18:00:00Z"}}).encode()


def _session(home: Path, pid: int, version: object, *, age: float = 0.0) -> None:
    folder = home / "sessions"
    folder.mkdir(parents=True, exist_ok=True)
    path = folder / f"{pid}.json"
    path.write_text(json.dumps({"pid": pid, "sessionId": f"s-{pid}", "version": version}), encoding="utf-8")
    stamp = 1_790_000_000.0 - age
    os.utime(path, (stamp, stamp))


def _agent(monkeypatch, home: Path) -> str:
    monkeypatch.setenv("CLAUDE_CONFIG_DIR", str(home))
    claude_quota.forget_installed_claude_version()
    seen: dict = {}

    def requester(url, *, method, headers, timeout):
        seen.update(headers)
        return 200, PAYLOAD

    claude_quota.fetch_windows(access_token="synthetic-token", requester=requester)
    return seen["User-Agent"]


def test_the_installed_version_is_named(monkeypatch, tmp_path: Path) -> None:
    _session(tmp_path, 4101, "2.1.292")

    assert _agent(monkeypatch, tmp_path) == "claude-code/2.1.292"


def test_the_newest_session_file_decides(monkeypatch, tmp_path: Path) -> None:
    _session(tmp_path, 4101, "2.1.200", age=5000)
    _session(tmp_path, 4102, "2.1.292", age=10)

    assert _agent(monkeypatch, tmp_path) == "claude-code/2.1.292"


def test_with_no_session_file_the_packaged_version_is_used(monkeypatch, tmp_path: Path) -> None:
    assert _agent(monkeypatch, tmp_path) == f"claude-code/{claude_quota.CLAUDE_CODE_VERSION_FALLBACK}"


@pytest.mark.parametrize("odd", ("2.1.292; evil", "latest", "", 7, None, "9" * 40, "2.1", "2.1.292\r\nX-Injected: 1"))
def test_an_odd_version_never_reaches_the_header(monkeypatch, tmp_path: Path, odd) -> None:
    _session(tmp_path, 4101, odd)

    assert _agent(monkeypatch, tmp_path) == f"claude-code/{claude_quota.CLAUDE_CODE_VERSION_FALLBACK}"


def test_the_packaged_version_is_a_current_one() -> None:
    major, minor, patch = (int(part) for part in claude_quota.CLAUDE_CODE_VERSION_FALLBACK.split("."))

    assert (major, minor) >= (2, 1) and patch >= 290
