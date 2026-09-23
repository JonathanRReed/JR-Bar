"""Opening a live session lands on its own window (answer_surfaces.py):
the tmux pane, the Terminal/iTerm tab, the Ghostty terminal -- never a
second ``--resume`` process."""

from __future__ import annotations

import json
from pathlib import Path
from types import SimpleNamespace

import pytest

from jrbar import answer_surfaces as surfaces
from jrbar.answer_surfaces import (
    GhosttyTerminal,
    SessionHost,
    SurfaceRecorder,
    SurfaceRunner,
    choose_ghostty_terminal,
    host_from_ancestry,
    open_live_session,
    parse_ghostty_terminals,
    parse_tmux_pane_for_tty,
    raise_session_host,
    tmux_clients,
)
from jrbar.core_server import CommandError

GHOSTTY = "/Applications/Ghostty.app/Contents/MacOS/ghostty"


def _entry(pid: int, ppid: int, command: str):
    return SimpleNamespace(pid=pid, ppid=ppid, command=command, started_at_epoch=1.0)


def _table(*rows):
    return {row.pid: row for row in rows}


GHOSTTY_CODEX = _table(
    _entry(500, 400, "/opt/homebrew/Caskroom/codex/0.155.1/bin/codex"),
    _entry(400, 300, "/bin/zsh"),
    _entry(300, 200, "/usr/bin/login"),
    _entry(200, 1, GHOSTTY),
)


class FakeRunner(SurfaceRunner):
    def __init__(
        self,
        *,
        ghostty_terminals: str = "",
        tab_found: bool = True,
        focused: str = "",
        tmux_panes: str = "",
        tmux_clients: str = "",
        activate: bool = True,
        permitted: bool | None = True,
        frontmost: str | None = "com.mitchellh.ghostty",
    ) -> None:
        self.ghostty_terminals = ghostty_terminals
        self.tab_found = tab_found
        self.focused = focused
        self.tmux_panes = tmux_panes
        self.tmux_client_rows = tmux_clients
        self.activate_result = activate
        self.permitted = permitted
        self.frontmost = frontmost
        self.calls: list[tuple] = []

    def osascript(self, script, *arguments):
        if script == surfaces._GHOSTTY_LIST_TERMINALS:
            self.calls.append(("ghostty-list",))
            return 0, self.ghostty_terminals
        if script == surfaces._GHOSTTY_FOCUS:
            self.calls.append(("ghostty-focus", *arguments))
            return 0, "terminal"
        if script == surfaces._GHOSTTY_FOCUSED_TERMINAL:
            self.calls.append(("ghostty-focused",))
            return 0, self.focused
        if script in (surfaces._TERMINAL_RAISE_BY_TTY, surfaces._ITERM_RAISE_BY_TTY):
            self.calls.append(("tab", "terminal" if script == surfaces._TERMINAL_RAISE_BY_TTY else "iterm", *arguments))
            return 0, "tab" if self.tab_found else "missing"
        raise AssertionError("unexpected script")

    def tmux(self, *arguments):
        self.calls.append(("tmux", *arguments))
        if arguments[0] == "list-panes":
            return 0, self.tmux_panes
        if arguments[0] == "list-clients":
            return 0, self.tmux_client_rows
        return 0, ""

    def activate(self, bundle_id):
        self.calls.append(("activate", bundle_id))
        return self.activate_result

    def frontmost_bundle(self):
        return self.frontmost

    def automation_permitted(self, bundle_id):
        self.calls.append(("permitted?", bundle_id))
        return self.permitted


def test_the_host_is_found_above_the_cli_itself__and_3_more() -> None:
    # --- scenario: Codex's own binary is not mistaken for the Codex app
    assert host_from_ancestry(500, GHOSTTY_CODEX) == ("Ghostty", "com.mitchellh.ghostty", False)

    # --- scenario: a tmux server stops the walk and says so
    table = _table(
        _entry(500, 400, "/Users/me/.local/share/claude/versions/2.1.280"),
        _entry(400, 350, "/bin/zsh"),
        _entry(350, 1, "/opt/homebrew/bin/tmux"),
    )
    assert host_from_ancestry(500, table) == (None, None, True)

    # --- scenario: a session run by the Claude desktop app is app-hosted
    table = _table(
        _entry(900, 800, "/Users/me/Library/Application Support/Claude/claude-code/2.1.280/claude.app/Contents/MacOS/claude"),
        _entry(800, 700, "/Applications/Claude.app/Contents/Helpers/disclaimer"),
        _entry(700, 1, "/Applications/Claude.app/Contents/MacOS/Claude"),
    )
    _app, bundle, _tmux = host_from_ancestry(900, table)
    assert bundle in surfaces.APP_HOSTED_BUNDLE_IDS

    # --- scenario: nothing known above it, or no pid at all
    assert host_from_ancestry(500, _table(_entry(500, 1, "/bin/codex"))) == (None, None, False)
    assert host_from_ancestry(None, GHOSTTY_CODEX) == (None, None, False)


def test_ghostty_picks_one_terminal_or_admits_a_tie__and_3_more() -> None:
    listing = (
        "T1\t/Users/me/repo\t✳ Fix the login bug\n"
        "T2\t/Users/me/repo\t✳ Write the changelog\n"
        "T3\t/Users/me/other\tzsh\n"
        "bad line\n"
    )
    terminals = parse_ghostty_terminals(listing)
    assert [terminal.id for terminal in terminals] == ["T1", "T2", "T3"]
    assert terminals[2] == GhosttyTerminal("T3", "/Users/me/other", "zsh")

    # --- scenario: the surface recorded at SessionStart wins
    assert choose_ghostty_terminal(terminals, recorded_id="T2", cwd="/Users/me/repo", title=None).id == "T2"

    # --- scenario: the only terminal in the session's directory
    assert choose_ghostty_terminal(terminals, recorded_id=None, cwd="/Users/me/other/", title=None).id == "T3"
    assert choose_ghostty_terminal(terminals, recorded_id="gone", cwd="/Users/me/other", title=None).id == "T3"

    # --- scenario: two in one directory: the title settles it, or nothing does
    assert choose_ghostty_terminal(terminals, recorded_id=None, cwd="/Users/me/repo", title="Fix the login").id == "T1"
    assert choose_ghostty_terminal(terminals, recorded_id=None, cwd="/Users/me/repo", title=None) is None
    assert choose_ghostty_terminal(terminals, recorded_id=None, cwd="/Users/me/repo", title="✳") is None
    assert choose_ghostty_terminal((), recorded_id=None, cwd="/x", title="y") is None


def test_tmux_rows_parse__and_1_more() -> None:
    # --- scenario: the pane is named by its tty
    panes = "/dev/ttys001\twork\t1\t0\n/dev/ttys007\twork\t2\t1\n"
    pane = parse_tmux_pane_for_tty(panes, "/dev/ttys007")
    assert (pane.target, pane.window_target) == ("work:2.1", "work:2")
    assert parse_tmux_pane_for_tty(panes, "/dev/ttys099") is None
    assert parse_tmux_pane_for_tty(panes, None) is None

    # --- scenario: clients and the session each one shows
    assert tmux_clients("/dev/ttys002\twork\n\n/dev/ttys003\t\n") == (("/dev/ttys002", "work"),)


def test_raising_lands_as_exactly_as_the_host_allows__and_5_more() -> None:
    # --- scenario: Terminal.app selects the tab by the session's tty
    runner = FakeRunner()
    host = SessionHost(pid=500, tty="/dev/ttys004", app_name="Terminal", bundle_id="com.apple.Terminal")
    outcome = raise_session_host(host, cwd=None, title=None, recorded_ghostty_id=None, runner=runner)
    assert (outcome.raised, outcome.detail) == ("tab", "/dev/ttys004")
    assert runner.calls == [("tab", "terminal", "/dev/ttys004")]

    # --- scenario: an iTerm2 tab it cannot find still brings iTerm2 forward
    runner = FakeRunner(tab_found=False)
    host = SessionHost(pid=500, tty="/dev/ttys004", app_name="iTerm", bundle_id="com.googlecode.iterm2")
    outcome = raise_session_host(host, cwd=None, title=None, recorded_ghostty_id=None, runner=runner)
    assert outcome.raised == "app"
    assert runner.calls[-1] == ("activate", "com.googlecode.iterm2")

    # --- scenario: a tty that is not a tty never reaches a script
    runner = FakeRunner()
    host = SessionHost(pid=500, tty='/dev/ttys004" & quit', app_name="Terminal", bundle_id="com.apple.Terminal")
    assert raise_session_host(host, cwd=None, title=None, recorded_ghostty_id=None, runner=runner).raised == "app"
    assert not [call for call in runner.calls if call[0] == "tab"]

    # --- scenario: Ghostty focuses the chosen terminal; a tie only activates
    listing = "T1\t/r\ta\nT2\t/r\tb\n"
    runner = FakeRunner(ghostty_terminals=listing)
    host = SessionHost(pid=500, tty="/dev/ttys004", app_name="Ghostty", bundle_id="com.mitchellh.ghostty")
    outcome = raise_session_host(host, cwd="/r", title=None, recorded_ghostty_id="T2", runner=runner)
    assert (outcome.raised, outcome.detail) == ("terminal", "T2")
    assert ("ghostty-focus", "T2") in runner.calls
    runner = FakeRunner(ghostty_terminals=listing)
    outcome = raise_session_host(host, cwd="/r", title=None, recorded_ghostty_id=None, runner=runner)
    assert outcome.raised == "app"
    assert not [call for call in runner.calls if call[0] == "ghostty-focus"]

    # --- scenario: tmux selects the pane, switching a lone client to its session
    runner = FakeRunner(
        tmux_panes="/dev/ttys009\tagents\t3\t1\n",
        tmux_clients="/dev/ttys002\tscratch\n",
    )
    host = SessionHost(pid=500, tty="/dev/ttys009", app_name=None, bundle_id=None, in_tmux=True)
    outcome = raise_session_host(host, cwd=None, title=None, recorded_ghostty_id=None, runner=runner)
    assert (outcome.raised, outcome.detail) == ("pane", "agents:3.1")
    tmux_calls = [call[1:] for call in runner.calls if call[0] == "tmux"]
    assert ("switch-client", "-c", "/dev/ttys002", "-t", "agents") in tmux_calls
    assert tmux_calls[-2:] == [("select-window", "-t", "agents:3"), ("select-pane", "-t", "agents:3.1")]

    # --- scenario: nothing to raise is said, not faked
    runner = FakeRunner(activate=False)
    host = SessionHost(pid=500, tty=None, app_name="kitty", bundle_id="net.kovidgoyal.kitty")
    assert raise_session_host(host, cwd=None, title=None, recorded_ghostty_id=None, runner=runner).raised == "none"
    host = SessionHost(pid=500, tty=None, app_name=None, bundle_id=None)
    assert raise_session_host(host, cwd=None, title=None, recorded_ghostty_id=None, runner=runner).raised == "none"


def _start(session_id: str = "s-1", cwd: str = "/Users/me/repo") -> str:
    return json.dumps({"hook_event_name": "SessionStart", "session_id": session_id, "cwd": cwd})


def test_session_start_records_the_ghostty_terminal__and_4_more(tmp_path: Path) -> None:
    path = tmp_path / "session-surfaces.json"

    def recorder(runner, *, clock=lambda: 1_000.0):
        return SurfaceRecorder(
            path=path, runner=runner, process_table=lambda: GHOSTTY_CODEX, wall_clock=clock, synchronous=True
        )

    # --- scenario: the focused terminal in the session's directory is recorded, and kept
    runner = FakeRunner(focused="T7\t/Users/me/repo")
    assert recorder(runner).note_session_start("codex", _start(), 500)
    assert recorder(FakeRunner()).recorded("codex", "s-1") == "T7"
    assert oct(path.stat().st_mode & 0o777) == "0o600"

    # --- scenario: never an Apple event macOS has not already allowed
    path.unlink()
    for permitted in (None, False):
        runner = FakeRunner(focused="T7\t/Users/me/repo", permitted=permitted)
        recorder(runner).note_session_start("codex", _start(), 500)
        assert ("ghostty-focused",) not in runner.calls
    assert not path.exists()

    # --- scenario: Ghostty not in front, or a terminal in another directory, records nothing
    for runner in (
        FakeRunner(focused="T7\t/Users/me/repo", frontmost="com.apple.Terminal"),
        FakeRunner(focused="T7\t/somewhere/else"),
    ):
        recorder(runner).note_session_start("codex", _start(), 500)
    assert not path.exists()

    # --- scenario: other events, no pid, or another host are not probed
    runner = FakeRunner(focused="T7\t/Users/me/repo")
    subject = recorder(runner)
    assert not subject.note_session_start("codex", json.dumps({"hook_event_name": "Stop", "session_id": "s"}), 500)
    subject.note_session_start("codex", _start(), None)
    SurfaceRecorder(
        path=path, runner=runner, process_table=lambda: _table(_entry(500, 1, "/bin/codex")), synchronous=True
    ).note_session_start("codex", _start(), 500)
    assert runner.calls == []

    # --- scenario: old records age out on load
    recorder(FakeRunner(focused="T7\t/Users/me/repo")).note_session_start("codex", _start(), 500)
    later = recorder(FakeRunner(), clock=lambda: 1_000.0 + surfaces.RECORDED_SURFACE_TTL_SECONDS + 1)
    assert later.recorded("codex", "s-1") is None


def test_process_probes_and_the_ghostty_focus_proof__and_4_more(monkeypatch) -> None:
    import os
    import signal
    import subprocess
    import time

    from jrbar import answer_local

    # --- scenario: a process's directory, read the way lsof reads it
    assert answer_local.process_cwd(os.getpid()) == os.getcwd()
    child = subprocess.Popen(["/bin/sleep", "30"], cwd="/private/tmp")
    try:
        assert answer_local.process_cwd(child.pid) == "/private/tmp"
        # --- scenario: a stopped (Ctrl-Z'd) process is seen as stopped
        assert answer_local.process_stopped(child.pid) is False
        os.kill(child.pid, signal.SIGSTOP)
        deadline = time.monotonic() + 5
        while answer_local.process_stopped(child.pid) is not True and time.monotonic() < deadline:
            time.sleep(0.02)
        assert answer_local.process_stopped(child.pid) is True
    finally:
        child.kill()
        child.wait()
    assert answer_local.process_cwd(None) is None and answer_local.process_stopped(-1) is None

    monkeypatch.setattr(answer_local, "process_cwd", lambda pid: "/Users/me/repo")

    # --- scenario: the focused terminal, alone in the session's directory, is proof
    runner = FakeRunner(focused="T1\t/Users/me/repo", ghostty_terminals="T1\t/Users/me/repo\tclaude\nT2\t/tmp\tzsh\n")
    assert answer_local.ghostty_focused_surface_proven(500, runner) is True

    # --- scenario: focus elsewhere is a definite no; a shared directory is unknown
    runner = FakeRunner(focused="T2\t/tmp", ghostty_terminals="T1\t/Users/me/repo\tx\nT2\t/tmp\ty\n")
    assert answer_local.ghostty_focused_surface_proven(500, runner) is False
    runner = FakeRunner(focused="T1\t/Users/me/repo", ghostty_terminals="T1\t/Users/me/repo\tx\nT3\t/Users/me/repo\ty\n")
    assert answer_local.ghostty_focused_surface_proven(500, runner) is None

    # --- scenario: no directory to compare, or Ghostty will not say, is unknown
    runner = FakeRunner(focused="")
    assert answer_local.ghostty_focused_surface_proven(500, runner) is None
    monkeypatch.setattr(answer_local, "process_cwd", lambda pid: None)
    assert answer_local.ghostty_focused_surface_proven(500, FakeRunner(focused="T1\t/x")) is None


def test_answer_raise_brings_the_exact_surface_forward(tmp_path: Path) -> None:
    runner = FakeRunner(ghostty_terminals="T1\t/Users/me/repo\tcodex\n")
    controller, status = _live()
    main_calls: list = []

    def on_main(function):
        main_calls.append(function)
        return function()

    outcome = surfaces.raise_for_answer(
        controller,
        status,
        on_main=on_main,
        runner=runner,
        recorder=SurfaceRecorder(path=tmp_path / "s.json", runner=FakeRunner(), synchronous=True),
        process_table=lambda: GHOSTTY_CODEX,
    )
    assert (outcome.raised, outcome.detail) == ("terminal", "T1")
    # The row's extras are main-thread state: read there, not on the socket thread.
    assert len(main_calls) == 1
    controller, status = _live(pid=None)
    assert surfaces.raise_for_answer(controller, status, runner=FakeRunner()) is None


class _Settings:
    def __init__(self, action=None):
        self.action = action

    def session_open_action(self, provider, origin=None):
        return self.action


def _live(pid=500, tty="/dev/ttys004", action=None):
    extras = SimpleNamespace(
        pid=pid,
        terminal={"app": "Ghostty", "bundle_id": "com.mitchellh.ghostty", "tty": tty},
        cwd="/Users/me/repo",
        name=None,
        origin={"kind": "codex_cli", "label": "Codex CLI", "bundle_id": None},
    )
    controller = SimpleNamespace(settings=_Settings(action), _core_extras_for=lambda status: extras)
    status = SimpleNamespace(
        agent_id="codex:session:s-1",
        provider="codex",
        session_id="s-1",
        origin="Codex CLI",
        cwd="/Users/me/repo",
    )
    return controller, status


def test_open_session_raises_a_live_session_instead_of_resuming_it__and_4_more(tmp_path: Path) -> None:
    recorder = SurfaceRecorder(path=tmp_path / "s.json", runner=FakeRunner(), synchronous=True)

    def open_(controller, status, args, runner):
        return open_live_session(
            controller, status, args, runner=runner, recorder=recorder, process_table=lambda: GHOSTTY_CODEX
        )

    # --- scenario: the one Ghostty terminal in the session's directory comes forward
    runner = FakeRunner(ghostty_terminals="T1\t/Users/me/repo\tcodex\nT2\t/tmp\tzsh\n")
    controller, status = _live()
    reply = open_(controller, status, {"session": status.agent_id}, runner)
    assert reply["raised"] == "terminal" and reply["detail"] == "T1"
    assert reply["activated"] == "Ghostty" and reply["session"] == "codex:session:s-1"
    assert ("ghostty-focus", "T1") in runner.calls

    # --- scenario: an ended session keeps --resume (the ladder)
    controller, status = _live(pid=None)
    assert open_(controller, status, {}, FakeRunner()) is None

    # --- scenario: an explicit app or VS Code choice keeps its own path
    controller, status = _live()
    assert open_(controller, status, {"action": "vscode"}, FakeRunner()) is None
    controller, status = _live(action="app")
    assert open_(controller, status, {}, FakeRunner()) is None
    controller, status = _live(action="terminal")
    assert open_(controller, status, {}, FakeRunner(ghostty_terminals="T1\t/Users/me/repo\tx\n"))["raised"] == "terminal"

    # --- scenario: remote rows are not this Mac's to open
    controller, status = _live()
    status.agent_id = "remote:studio:codex:session:s-1"
    assert open_(controller, status, {}, FakeRunner()) is None

    # --- scenario: live but nowhere to be found refuses instead of starting a second copy
    controller, status = _live()
    with pytest.raises(CommandError) as error:
        open_live_session(
            controller,
            status,
            {},
            runner=FakeRunner(activate=False),
            recorder=recorder,
            process_table=lambda: _table(_entry(500, 1, "/bin/codex")),
        )
    assert error.value.code == "not_found"
    assert "nothing new was started" in str(error.value)
