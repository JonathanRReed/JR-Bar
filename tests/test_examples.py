"""The examples run and print numbers and words, never a block meter."""

from __future__ import annotations

import json
import os
import subprocess
import sys
import time
from pathlib import Path

import pytest

ROOT = Path(__file__).resolve().parents[1]
EXAMPLES = ROOT / "examples"
BLOCKS = "▰▱█░▓▒"


@pytest.mark.parametrize(
    "script", ["usage-hooks/notify.sh", "xbar/jrbar.30s.sh", "raycast/jrbar-status.sh"]
)
def test_the_shell_examples_parse_and_are_executable(script: str) -> None:
    path = EXAMPLES / script
    assert os.access(path, os.X_OK)
    assert subprocess.run(["/bin/bash", "-n", str(path)], capture_output=True, timeout=30).returncode == 0


def test_the_jsonl_hook_appends_each_event(tmp_path: Path) -> None:
    target = tmp_path / "events.jsonl"
    event = {"v": 1, "event": "quota_low", "provider": "claude", "remaining_percent": 18.0}
    for _ in range(2):
        subprocess.run(
            [sys.executable, str(EXAMPLES / "usage-hooks" / "log-jsonl.py"), str(target)],
            input=json.dumps(event), text=True, check=True, timeout=30,
        )
    assert [json.loads(line)["event"] for line in target.read_text().splitlines()] == ["quota_low", "quota_low"]


@pytest.mark.skipif(not Path("/usr/bin/plutil").exists(), reason="plutil is macOS's")
def test_the_xbar_plugin_reads_the_status_endpoint(tmp_path: Path) -> None:
    now = int(time.time())
    status = {
        "schema_version": 2,
        "agents": {"lifecycle_counts": {"active": 2, "waiting": 1, "completed": 4, "failed": 0}},
        "usage": {"providers": [
            {"provider_id": "claude", "state": "ready",
             "quota": {"remaining_percent": 58.0, "next_reset_at": now + 2 * 3600 + 15 * 60 + 30, "window_count": 2}},
            {"provider_id": "grok", "state": "needs_sign_in",
             "quota": {"remaining_percent": None, "next_reset_at": None, "window_count": 0}},
        ]},
    }
    bin_dir = tmp_path / "bin"
    bin_dir.mkdir()
    fake_curl = bin_dir / "curl"
    fake_curl.write_text(f"#!/bin/sh\ncat <<'JSON'\n{json.dumps(status)}\nJSON\n")
    fake_curl.chmod(0o755)
    env = {"PATH": f"{bin_dir}:/usr/bin:/bin", "HOME": str(tmp_path), "JRBAR_SERVE_TOKEN": "t"}

    output = subprocess.run(
        ["/bin/bash", str(EXAMPLES / "xbar" / "jrbar.30s.sh")], env=env, capture_output=True, text=True, timeout=30
    ).stdout

    lines = output.splitlines()
    assert lines[0] == "JR 1 waiting 2 working"
    assert "claude 58% left · resets in 2h 15m" in lines
    assert "grok needs sign in" in lines
    assert not any(char in output for char in BLOCKS)


@pytest.mark.skipif(not Path("/usr/bin/plutil").exists(), reason="plutil is macOS's")
def test_the_xbar_plugin_says_when_the_endpoint_is_off(tmp_path: Path) -> None:
    bin_dir = tmp_path / "bin"
    bin_dir.mkdir()
    (bin_dir / "curl").write_text("#!/bin/sh\nexit 7\n")
    (bin_dir / "curl").chmod(0o755)
    env = {"PATH": f"{bin_dir}:/usr/bin:/bin", "HOME": str(tmp_path)}
    output = subprocess.run(
        ["/bin/bash", str(EXAMPLES / "xbar" / "jrbar.30s.sh")], env=env, capture_output=True, text=True, timeout=30
    ).stdout
    assert "not answering" in output
