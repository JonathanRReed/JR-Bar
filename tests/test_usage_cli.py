"""``jrbar usage``: text, a brief table, JSON with schema 1, and the exit code.

The CLI reads the running monitor's ``state.usage`` over core.sock; a fake
socket here plays the monitor, and a store reader plays the saved readings
for the offline case.
"""

from __future__ import annotations

import io
import json
import socket
import tempfile
import threading
from pathlib import Path

from jrbar.usage_cli import main, reset_words

NOW = 1_790_000_000.0

USAGE = {
    "refreshed_at": NOW - 45,
    "providers": [
        {
            "id": "claude",
            "instance": "default",
            "state": "ready",
            "quota_source": True,
            "windows": [
                {"id": "five-hour", "name": "5h", "used_pct": 42.0, "resets_at": NOW + 2 * 3600 + 14 * 60, "bindable": True},
                {"id": "weekly", "name": "7d", "used_pct": 61.0, "resets_at": NOW + 3 * 86400 + 5 * 3600, "bindable": True},
            ],
        },
        {
            "id": "opencode",
            "instance": "default",
            "state": "unsupported",
            "quota_source": False,
            "reason": "opencode_no_quota_source",
            "windows": [],
        },
        {
            "id": "grok",
            "instance": "default",
            "state": "needs_sign_in",
            "quota_source": True,
            "action": "Run grok login",
            "windows": [],
        },
    ],
}


class FakeCore:
    """A Unix socket that answers like the monitor: hello, then state."""

    def __init__(self, usage: dict) -> None:
        self.path = Path(tempfile.mkdtemp(prefix="jrbar-usage-cli-")) / "core.sock"
        self.server = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
        self.server.bind(str(self.path))
        self.server.listen(1)
        self.usage = usage
        self.served = threading.Event()
        self.thread = threading.Thread(target=self._serve, daemon=True)
        self.thread.start()

    def _serve(self) -> None:
        connection, _ = self.server.accept()
        with connection:
            for frame in (
                {"t": "hello", "v": 1, "core_version": "test"},
                {"t": "state", "v": 1, "usage": self.usage},
            ):
                connection.sendall((json.dumps(frame) + "\n").encode())
            self.served.set()
            connection.recv(1)

    def close(self) -> None:
        self.server.close()
        self.thread.join(timeout=5.0)


def run(*args: str, usage: dict | None = None, store: dict | None = None) -> tuple[int, str, str]:
    out, err = io.StringIO(), io.StringIO()
    if usage is not None:
        core = FakeCore(usage)
        try:
            code = main([*args, "--socket", str(core.path)], stdout=out, stderr=err, now=NOW)
        finally:
            core.close()
    else:
        code = main(
            list(args),
            stdout=out,
            stderr=err,
            now=NOW,
            core_reader=lambda _path: None,
            store_reader=lambda: store or {"refreshed_at": None, "providers": []},
        )
    return code, out.getvalue(), err.getvalue()


def test_text_is_one_line_per_window_in_words() -> None:
    code, out, _ = run(usage=USAGE)

    assert code == 0
    assert out.splitlines() == [
        "Claude    5h 58% left · resets 2h14m",
        "Claude    7d 39% left · resets 3d5h",
        "OpenCode  no quota source",
        "Grok      sign-in required: Run grok login",
    ]
    # Numbers and words: never a meter made of block characters.
    assert not any(char in out for char in "▰▱█░")


def test_brief_is_a_table() -> None:
    code, out, _ = run("--brief", usage=USAGE)

    assert code == 0
    lines = out.splitlines()
    assert lines[0].split() == ["Provider", "Window", "Left", "Resets"]
    assert lines[1].split() == ["Claude", "5h", "58%", "2h14m"]
    assert "OpenCode" in lines[3] and "no quota source" in lines[3]


def test_json_is_the_usage_block_with_schema_one() -> None:
    code, out, _ = run("--json", "--provider", "claude", usage=USAGE)

    document = json.loads(out)
    assert code == 0
    assert document["schema"] == 1
    assert document["source"] == "core"
    assert document["refreshed_at"] == NOW - 45
    assert [row["id"] for row in document["providers"]] == ["claude"]
    assert document["providers"][0]["windows"][0]["used_pct"] == 42.0


def test_an_enabled_provider_in_error_exits_one() -> None:
    broken = {
        "refreshed_at": NOW,
        "providers": [
            {"id": "codex", "state": "error", "quota_source": True, "action": "Retry", "windows": []},
            {"id": "devin", "state": "disabled", "quota_source": True, "windows": []},
        ],
    }
    code, out, _ = run(usage=broken)
    assert code == 1
    assert "Codex" in out and "error: Retry" in out

    # A disabled provider alone is not a failure.
    code, _, _ = run(usage={"refreshed_at": NOW, "providers": [broken["providers"][1]]})
    assert code == 0


def test_without_a_monitor_it_reads_the_saved_readings_and_says_so() -> None:
    code, out, err = run(store=USAGE)

    assert code == 0
    assert out.startswith("Claude")
    assert "last saved readings" in err

    code, out, _ = run("--json", store=USAGE)
    assert json.loads(out)["source"] == "store"


def test_reset_words() -> None:
    assert reset_words(None, NOW) is None
    assert reset_words(NOW + 45 * 60, NOW) == "resets 45m"
    assert reset_words(NOW + 30, NOW) == "resetting now"
    assert reset_words(NOW - 3600, NOW) == "reset passed, the reading is older"


def test_the_router_reaches_it(monkeypatch) -> None:
    from jrbar import cli_entry, usage_cli

    seen = []
    monkeypatch.setattr(usage_cli, "main", lambda argv: seen.append(argv) or 0)
    assert cli_entry.jrbar_main(["usage", "--brief"]) == 0
    assert seen == [["--brief"]]


def test_reset_credits_are_counted_in_words() -> None:
    usage = {"refreshed_at": NOW, "providers": [
        {"id": "codex", "state": "ready", "quota_source": True, "reset_credits": 2,
         "windows": [{"id": "weekly", "name": "7d", "used_pct": 30.0, "resets_at": NOW + 3600}]},
    ]}
    code, out, _ = run(usage=usage)
    assert code == 0
    assert out.strip() == "Codex  7d 70% left · resets 1h00m · 2 reset credits"


def test_only_a_reference_only_window_is_called_detail() -> None:
    from jrbar.usage_cli import render_lines

    now = 1_790_000_000.0
    document = {"providers": [
        {"id": "claude", "state": "ready", "windows": [
            {"id": "fable-only", "name": "7d Fable", "used_pct": 30.0, "bindable": False, "detail": False},
        ]},
        {"id": "opencode", "state": "ready", "windows": [
            {"id": "go-monthly", "name": "Monthly", "used_pct": 7.0, "bindable": False, "detail": True},
        ]},
    ]}
    fable, monthly = render_lines(document, now=now)
    assert "detail" not in fable, "a model's own cap is a real limit on that model"
    assert monthly.endswith("detail")
