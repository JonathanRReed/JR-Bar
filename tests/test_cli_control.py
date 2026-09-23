"""The control verbs over a fake core socket and a recording link opener:
no daemon, no ``open``, no network."""

from __future__ import annotations

import json
import shutil
import socket
import tempfile
import threading
import time
from pathlib import Path

import pytest

from jrbar import cli_control, cli_entry
from jrbar.cli_control import ControlError, parse_duration, render_status, seconds_until


class FakeCore:
    """Accepts one client at a time: sends hello, state and settings the
    way the daemon does on connect, then answers each command from
    ``replies`` (a name -> reply-body map) and records what it was sent."""

    def __init__(self, path: Path, *, state: dict, settings: dict, replies: dict[str, dict]) -> None:
        self.path = path
        self.state = state
        self.settings = settings
        self.replies = replies
        self.commands: list[dict] = []
        self.server = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
        self.server.bind(str(path))
        self.server.listen(1)
        self.server.settimeout(5)
        self.thread = threading.Thread(target=self._serve, daemon=True)
        self.thread.start()

    def _send(self, connection: socket.socket, frame: dict) -> None:
        connection.sendall((json.dumps(frame) + "\n").encode())

    def _serve(self) -> None:
        while True:
            try:
                connection, _ = self.server.accept()
            except OSError:
                return
            with connection:
                self._send(connection, {"t": "hello", "v": 1, "core_version": "0.9.9"})
                self._send(connection, {"t": "state", "v": 1, **self.state})
                self._send(connection, {"t": "settings", "v": 1, "generation": 3, "document": self.settings})
                buffer = b""
                connection.settimeout(5)
                while True:
                    try:
                        chunk = connection.recv(65536)
                    except OSError:
                        break
                    if not chunk:
                        break
                    buffer += chunk
                    while b"\n" in buffer:
                        line, buffer = buffer.split(b"\n", 1)
                        command = json.loads(line)
                        self.commands.append(command)
                        reply = self.replies.get(command["name"], {"ok": True, "result": {}})
                        self._send(connection, {"t": "reply", "v": 1, "id": command["id"], **reply})

    def close(self) -> None:
        self.server.close()


STATE = {
    "generation": 7,
    "aggregate": {"mode": "needs_you", "needs_you": 1, "active": 1, "total": 2},
    "sessions": [
        {"id": "codex:session:1", "provider": "codex", "label": "sidepulse-core", "mode": "tool_running"},
        {"id": "claude:session:2", "provider": "claude", "label": "jr-bar-b7", "mode": "waiting"},
    ],
    "asks": [{"session": "claude:session:2", "kind": "permission", "summary": "Run: rm -rf build"}],
    "focus": {"mode": "dim", "summary": "Dim until 07:00"},
    "power": {"keep_awake": True},
}
SETTINGS = {"global_brightness_scale": 0.8, "colors": {"agent_colors": {"claude": "#D97757"}}}


@pytest.fixture
def core():
    directory = Path(tempfile.mkdtemp(prefix="jrc-", dir=tempfile.gettempdir()))
    fake = FakeCore(
        directory / "core.sock",
        state=STATE,
        settings=SETTINGS,
        replies={
            "set_setting": {"ok": True, "result": {"generation": 4, "path": "global_brightness_scale", "value": 1.0}},
            "snooze": {"ok": True, "result": {"sessions": ["claude:session:2"], "until": 1.0}},
        },
    )
    try:
        yield fake
    finally:
        fake.close()
        shutil.rmtree(directory, ignore_errors=True)


def run(argv: list[str], core: FakeCore | None = None, opened: list[str] | None = None,
        socket_path: Path | None = None) -> int:
    return cli_control.main(
        argv,
        socket_path=socket_path or (core.path if core else None),
        opener=(opened.append if opened is not None else None),
    )


def test_durations_take_the_links_grammar_and_refuse_typos() -> None:
    assert parse_duration("90") == 90
    assert parse_duration("15m") == 900
    assert parse_duration("1h30m") == 5400
    assert parse_duration("off") == 0
    for bad in ("", "m", "2x", "1h 3", "-5", "h2"):
        with pytest.raises(ControlError):
            parse_duration(bad)


def test_status_lists_the_waiting_ask_first(core, capsys) -> None:
    assert run(["status"], core) == 0
    out = capsys.readouterr().out.splitlines()
    assert out[0] == "JR-Bar core 0.9.9 -- 2 sessions, 1 needs you"
    assert out[1].startswith("  ! needs you  claude") and "Run: rm -rf build" in out[1]
    assert "sidepulse-core" in out[2]
    assert "quiet: Dim until 07:00" in out
    assert "keep awake: held while agents work" in out


def test_status_json_is_the_state_document(core, capsys) -> None:
    assert run(["status", "--json"], core) == 0
    body = json.loads(capsys.readouterr().out)
    assert body["generation"] == 7
    assert "t" not in body and "v" not in body


def test_quiet_sends_the_daemons_command(core, capsys) -> None:
    assert run(["quiet", "1h", "--mode", "asks-only"], core) == 0
    assert core.commands[-1]["name"] == "quiet"
    assert core.commands[-1]["args"] == {"mode": "asks_only", "seconds": 3600}
    assert "quiet (asks_only) for 1 h" in capsys.readouterr().out
    assert run(["quiet", "off"], core) == 0
    assert core.commands[-1]["args"]["seconds"] == 0


def test_quiet_refuses_a_mode_or_length_it_does_not_know(core, capsys) -> None:
    assert run(["quiet", "1h", "--mode", "loud"], core) == 2
    assert run(["quiet", "3d"], core) == 2
    assert core.commands == []
    assert "unknown quiet mode" in capsys.readouterr().err


def _local(hour: int, minute: int) -> float:
    return time.mktime((2026, 9, 23, hour, minute, 0, 0, 0, -1))


def test_a_time_of_day_counts_to_its_next_occurrence() -> None:
    now = _local(22, 15)
    assert seconds_until("8am", now) == 9 * 3600 + 45 * 60
    assert seconds_until("08:00", now) == 9 * 3600 + 45 * 60
    assert seconds_until("8:00 A.M.", now) == 9 * 3600 + 45 * 60
    assert seconds_until("11:30pm", now) == 75 * 60
    assert seconds_until("23:30", now) == 75 * 60
    assert seconds_until("12am", now) == 105 * 60
    assert seconds_until("22:15", now) == 24 * 3600, "now itself is tomorrow's"
    for bad in ("8", "25:00", "13pm", "8:75", "soon", "", "0am"):
        with pytest.raises(ControlError):
            seconds_until(bad, now)


def test_quiet_and_awake_take_a_time_of_day(core, capsys, monkeypatch) -> None:
    monkeypatch.setattr(cli_control, "seconds_until", lambda raw, now=None: 4500)
    assert run(["quiet", "--until", "11:30pm", "--mode", "dim"], core) == 0
    assert core.commands[-1]["args"] == {"mode": "dim", "seconds": 4500}
    opened: list[str] = []
    assert run(["awake", "--until", "11:30pm"], opened=opened) == 0
    assert opened == ["jrbar://awake?for=4500"]
    assert run(["quiet", "1h", "--until", "8am"], core) == 2
    assert run(["quiet"], core) == 2
    assert run(["awake", "2h", "--until", "8am"], opened=opened) == 2
    assert "not both" in capsys.readouterr().err


def test_deepwork_hands_the_app_a_stretch(capsys, monkeypatch) -> None:
    opened: list[str] = []
    assert run(["deepwork"], opened=opened) == 0
    assert run(["deepwork", "50m"], opened=opened) == 0
    assert run(["deepwork", "off"], opened=opened) == 0
    monkeypatch.setattr(cli_control, "seconds_until", lambda raw, now=None: 5400)
    assert run(["deepwork", "--until", "11am"], opened=opened) == 0
    assert opened == [
        "jrbar://deepwork",
        "jrbar://deepwork?for=3000",
        "jrbar://deepwork/end",
        "jrbar://deepwork?for=5400",
    ]
    assert run(["deepwork", "30s"], opened=opened) == 2
    assert "between a minute and a day" in capsys.readouterr().err


def test_set_writes_json_values_and_says_what_the_monitor_kept(core, capsys) -> None:
    assert run(["set", "global_brightness_scale", "1.4"], core) == 0
    assert core.commands[-1]["args"] == {"path": "global_brightness_scale", "value": 1.4}
    captured = capsys.readouterr()
    assert "global_brightness_scale = 1.0" in captured.out
    assert "kept 1.0 instead of 1.4" in captured.err


def test_get_reads_a_dot_path_from_the_settings_document(core, capsys) -> None:
    assert run(["get", "colors.agent_colors.claude"], core) == 0
    assert json.loads(capsys.readouterr().out) == "#D97757"
    assert run(["get", "colors.nope"], core) == 1


def test_a_refused_reply_carries_the_daemons_words(core, capsys) -> None:
    core.replies["snooze"] = {"ok": False, "error": {"code": "not_found", "message": "no such session"}}
    assert run(["snooze", "claude:session:9", "15m"], core) == 1
    assert "no such session" in capsys.readouterr().err


def test_snooze_all_names_what_it_snoozed(core, capsys) -> None:
    assert run(["snooze", "all", "1h"], core) == 0
    assert core.commands[-1]["args"] == {"session": "all", "seconds": 3600}
    assert "snoozed 1 session" in capsys.readouterr().out


def test_no_daemon_is_said_plainly(capsys) -> None:
    missing = Path(tempfile.gettempdir()) / "jrc-missing" / "core.sock"
    assert run(["status"], socket_path=missing) == cli_control.EXIT_NO_CORE
    assert "not running" in capsys.readouterr().err


def test_app_verbs_become_links() -> None:
    opened: list[str] = []
    assert run(["toggle", "dark"], opened=opened) == 0
    assert run(["toggle", "mic", "on"], opened=opened) == 0
    assert run(["awake", "2h"], opened=opened) == 0
    assert run(["awake", "off"], opened=opened) == 0
    assert run(["awake"], opened=opened) == 0
    assert run(["open", "panel/toggle"], opened=opened) == 0
    assert run(["open", "jrbar://settings/shortcuts"], opened=opened) == 0
    assert opened == [
        "jrbar://toggle/dark",
        "jrbar://toggle/mic?on=1",
        "jrbar://awake?for=7200",
        "jrbar://awake?for=off",
        "jrbar://awake",
        "jrbar://panel/toggle",
        "jrbar://settings/shortcuts",
    ]


def test_the_opener_hands_links_to_launch_services_in_the_background() -> None:
    calls: list[list[str]] = []

    class Result:
        returncode = 0
        stderr = ""

    cli_control.open_link("jrbar://panel", runner=lambda argv, **_: calls.append(argv) or Result())
    assert calls == [["/usr/bin/open", "-g", "jrbar://panel"]]

    class Refused:
        returncode = 1
        stderr = "LSOpenURLsWithRole() failed"

    with pytest.raises(ControlError, match="did not take"):
        cli_control.open_link("jrbar://panel", runner=lambda argv, **_: Refused())


def test_the_public_router_sends_the_verbs_here(monkeypatch) -> None:
    calls = []
    monkeypatch.setattr(cli_control, "main", lambda argv: calls.append(argv) or 41)
    monkeypatch.setattr(cli_entry, "_legacy_jrbar_main", lambda argv: calls.append(("legacy", argv)) or 7)
    assert cli_entry.jrbar_main(["quiet", "1h"]) == 41
    assert cli_entry.jrbar_main(["status", "--json"]) == 41
    assert cli_entry.jrbar_main(["doctor"]) == 7
    assert calls == [["quiet", "1h"], ["status", "--json"], ("legacy", ["doctor"])]


def test_render_status_survives_a_sparse_state() -> None:
    assert render_status({}) == "JR-Bar core -- 0 sessions"
