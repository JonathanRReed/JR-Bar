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
        new_tab: bool = True,
        launch: bool = True,
    ) -> None:
        self.new_tab = new_tab
        self.launch = launch
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
        if script == surfaces._GHOSTTY_NEW_TAB:
            self.calls.append(("ghostty-new-tab", *arguments))
            return (0, "tab") if self.new_tab else (1, "")
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

    def launch_in_terminal(self, bundle_id, command):
        self.calls.append(("launch", bundle_id, command))
        return self.launch

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

    # --- scenario: the surface recorded at SessionStart wins, while it is still in the session's directory
    assert choose_ghostty_terminal(terminals, recorded_id="T2", cwd="/Users/me/repo", title=None).id == "T2"
    assert choose_ghostty_terminal(terminals, recorded_id="T3", cwd="/Users/me/repo", title=None) is None

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

    # --- scenario: the host app and the focused terminal in the session's directory are recorded, and kept
    runner = FakeRunner(focused="T7\t/Users/me/repo")
    assert recorder(runner).note_session_start("codex", _start(), 500)
    reloaded = recorder(FakeRunner())
    assert reloaded.recorded("codex", "s-1") == "T7"
    assert reloaded.recorded_host("codex", "s-1") == "com.mitchellh.ghostty"
    assert oct(path.stat().st_mode & 0o777) == "0o600"

    # --- scenario: never an Apple event macOS has not already allowed -- the app still is
    for permitted in (None, False):
        runner = FakeRunner(focused="T7\t/Users/me/repo", permitted=permitted)
        subject = recorder(runner)
        subject.note_session_start("codex", _start("s-2"), 500)
        assert ("ghostty-focused",) not in runner.calls
        assert subject.recorded("codex", "s-2") is None
        assert subject.recorded_host("codex", "s-2") == "com.mitchellh.ghostty"

    # --- scenario: Ghostty not in front, or a terminal elsewhere, proves no surface; a restart replaces the old one
    for runner in (
        FakeRunner(focused="T7\t/Users/me/repo", frontmost="com.apple.Terminal"),
        FakeRunner(focused="T9\t/somewhere/else"),
    ):
        subject = recorder(runner)
        subject.note_session_start("codex", _start(), 500)
        assert subject.recorded("codex", "s-1") is None

    # --- scenario: other events, no pid, a Terminal.app host (no Apple event needed) and an app host
    runner = FakeRunner(focused="T7\t/Users/me/repo")
    subject = recorder(runner)
    assert not subject.note_session_start("codex", json.dumps({"hook_event_name": "Stop", "session_id": "s"}), 500)
    subject.note_session_start("codex", _start("s-3"), None)
    assert subject.recorded_host("codex", "s-3") is None
    terminal_host = _table(
        _entry(500, 400, "/bin/codex"), _entry(400, 1, "/System/Applications/Utilities/Terminal.app/Contents/MacOS/Terminal")
    )
    subject = SurfaceRecorder(path=path, runner=runner, process_table=lambda: terminal_host, synchronous=True)
    subject.note_session_start("codex", _start("s-4"), 500)
    assert subject.recorded_host("codex", "s-4") == "com.apple.Terminal"
    assert subject.recorded("codex", "s-4") is None
    app_host = _table(_entry(500, 400, "/bin/codex"), _entry(400, 1, "/Applications/Codex.app/Contents/MacOS/Codex"))
    subject = SurfaceRecorder(path=path, runner=runner, process_table=lambda: app_host, synchronous=True)
    subject.note_session_start("codex", _start("s-5"), 500)
    assert subject.recorded_host("codex", "s-5") is None
    assert runner.calls == []

    # --- scenario: old records age out on load
    recorder(FakeRunner(focused="T7\t/Users/me/repo")).note_session_start("codex", _start(), 500)
    later = recorder(FakeRunner(), clock=lambda: 1_000.0 + surfaces.RECORDED_SURFACE_TTL_SECONDS + 1)
    assert later.recorded("codex", "s-1") is None and later.recorded_host("codex", "s-1") is None


def test_process_probes_and_the_ghostty_focus_proof__and_4_more(monkeypatch) -> None:
    import os
    import signal
    import subprocess

    from jrbar import answer_local

    # --- scenario: a process's directory, read the way lsof reads it
    assert answer_local.process_cwd(os.getpid()) == os.getcwd()
    child = subprocess.Popen(["/bin/sleep", "30"], cwd="/private/tmp")
    try:
        assert answer_local.process_cwd(child.pid) == "/private/tmp"
        # --- scenario: a stopped (Ctrl-Z'd) process is seen as stopped
        assert answer_local.process_stopped(child.pid) is False
        os.kill(child.pid, signal.SIGSTOP)
        # Returns once the kernel has stopped it: no polling.
        assert os.WIFSTOPPED(os.waitpid(child.pid, os.WUNTRACED)[1])
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


def test_a_ghostty_terminal_with_no_directory_leaves_the_proof_unknown__and_1_more(monkeypatch) -> None:
    from jrbar import answer_local

    monkeypatch.setattr(answer_local, "process_cwd", lambda pid: "/Users/me/repo")

    # --- scenario: a terminal that names no directory could be the session's own
    runner = FakeRunner(focused="T1\t/Users/me/repo", ghostty_terminals="T1\t/Users/me/repo\tzsh\nT2\t\tclaude\n")
    assert answer_local.ghostty_focused_surface_proven(500, runner) is None

    # --- scenario: the one terminal in the directory must be the focused one
    runner = FakeRunner(focused="T1\t/Users/me/repo", ghostty_terminals="T3\t/Users/me/repo\tzsh\nT2\t/tmp\tx\n")
    assert answer_local.ghostty_focused_surface_proven(500, runner) is None


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


def _ended(tmp_path: Path, host: str | None, action=None):
    """An ended Codex CLI row whose SessionStart recorded ``host``."""
    recorder = SurfaceRecorder(path=tmp_path / "surfaces.json", runner=FakeRunner(permitted=None), synchronous=True)
    if host is not None:
        recorder._store("codex", "s-1", host_bundle=host, terminal_id=None, cwd="/Users/me/repo")
    controller = SimpleNamespace(settings=_Settings(action), _core_extras_for=lambda status: SimpleNamespace(pid=None))
    status = SimpleNamespace(
        agent_id="codex:session:s-1",
        provider="codex",
        session_id="s-1",
        origin="Codex CLI",
        cwd="/Users/me/repo",
    )
    return controller, status, recorder


def test_an_ended_session_resumes_in_the_terminal_it_ran_in__and_4_more(tmp_path: Path) -> None:
    from jrbar.answer_surfaces import open_session_surface, resume_in_own_terminal

    # --- scenario: Ghostty: a new tab in the session's directory, the resume typed into the shell
    controller, status, recorder = _ended(tmp_path, "com.mitchellh.ghostty")
    runner = FakeRunner()
    reply = open_session_surface(controller, status, {}, runner=runner, recorder=recorder)
    assert reply["raised"] == "new_tab" and reply["activated"] == "Ghostty"
    assert runner.calls == [("ghostty-new-tab", "/Users/me/repo", "codex resume s-1\n")]

    # --- scenario: a Ghostty that refuses the Apple event gets a new window through the reviewed plan
    runner = FakeRunner(new_tab=False)
    reply = resume_in_own_terminal(controller, status, {}, runner=runner, recorder=recorder)
    assert reply["raised"] == "new_window"
    assert runner.calls[-1] == ("launch", "com.mitchellh.ghostty", "cd /Users/me/repo && codex resume s-1")

    # --- scenario: Terminal.app: a new window there, not in whatever app is in front
    controller, status, recorder = _ended(tmp_path, "com.apple.Terminal")
    runner = FakeRunner()
    reply = resume_in_own_terminal(controller, status, {}, runner=runner, recorder=recorder)
    assert reply["activated"] == "Terminal" and reply["raised"] == "new_window"
    assert runner.calls == [("launch", "com.apple.Terminal", "cd /Users/me/repo && codex resume s-1")]

    # --- scenario: an explicit app or VS Code open, or no record of the terminal, keeps the ladder
    controller, status, recorder = _ended(tmp_path, "com.mitchellh.ghostty", action="app")
    assert resume_in_own_terminal(controller, status, {}, runner=FakeRunner(), recorder=recorder) is None
    controller, status, recorder = _ended(tmp_path, "com.mitchellh.ghostty")
    assert resume_in_own_terminal(controller, status, {"action": "vscode"}, runner=FakeRunner(), recorder=recorder) is None
    controller, status, recorder = _ended(tmp_path / "none", None)
    assert resume_in_own_terminal(controller, status, {}, runner=FakeRunner(), recorder=recorder) is None

    # --- scenario: a terminal with no reviewed plan keeps the ladder too
    controller, status, recorder = _ended(tmp_path, "com.apple.Terminal")
    assert resume_in_own_terminal(controller, status, {}, runner=FakeRunner(launch=False), recorder=recorder) is None


def test_new_session_starts_the_agent_in_the_owners_terminal__and_3_more(tmp_path: Path) -> None:
    from jrbar.answer_surfaces import start_session_in_terminal

    project = tmp_path / "my project"
    project.mkdir()
    recorder = SurfaceRecorder(path=tmp_path / "s.json", runner=FakeRunner(permitted=None), synchronous=True)
    recorder._store("claude", "old", host_bundle="com.mitchellh.ghostty", terminal_id=None, cwd="/x")

    # --- scenario: the terminal the last session ran in: a Ghostty tab there, the CLI typed in
    runner = FakeRunner()
    reply = start_session_in_terminal("Claude", str(project), runner=runner, recorder=recorder)
    assert (reply["raised"], reply["app"], reply["provider"]) == ("new_tab", "Ghostty", "claude")
    assert runner.calls == [("ghostty-new-tab", str(project), "claude\n")]

    # --- scenario: a named terminal wins, with the directory quoted for its shell
    runner = FakeRunner()
    reply = start_session_in_terminal(
        "codex", str(project), terminal="com.apple.Terminal", runner=runner, recorder=recorder
    )
    assert reply["raised"] == "new_window"
    assert runner.calls == [("launch", "com.apple.Terminal", f"cd '{project}' && codex")]

    # --- scenario: only known agents, only real absolute directories, only reviewed terminals
    for provider, cwd, terminal, code in (
        ("bash", str(project), None, "invalid_args"),
        ("claude", "relative/dir", None, "invalid_args"),
        ("claude", str(tmp_path / "missing"), None, "not_found"),
        ("claude", str(project), "com.example.term", "invalid_args"),
    ):
        with pytest.raises(CommandError) as error:
            start_session_in_terminal(provider, cwd, terminal=terminal, runner=FakeRunner(), recorder=recorder)
        assert error.value.code == code

    # --- scenario: a terminal that cannot be opened says so
    with pytest.raises(CommandError) as error:
        start_session_in_terminal(
            "claude",
            str(project),
            terminal="com.apple.Terminal",
            runner=FakeRunner(launch=False),
            recorder=recorder,
        )
    assert error.value.code == "unsupported"


# --- is the owner looking at it -------------------------------------------------

TERMINAL_CODEX = _table(
    _entry(500, 400, "/opt/homebrew/Caskroom/codex/0.155.1/bin/codex"),
    _entry(400, 300, "/bin/zsh"),
    _entry(300, 1, "/System/Applications/Utilities/Terminal.app/Contents/MacOS/Terminal"),
)
TMUX_CODEX = _table(
    _entry(500, 400, "/opt/homebrew/Caskroom/codex/0.155.1/bin/codex"),
    _entry(400, 350, "/bin/zsh"),
    _entry(350, 1, "/opt/homebrew/bin/tmux"),
)


class _FrontRunner(FakeRunner):
    """FakeRunner that also says which app is in front and which tty the
    frontmost Terminal.app / iTerm2 tab has."""

    def __init__(self, *, front=("com.mitchellh.ghostty", 200), focused_tty: str = "", **kwargs) -> None:
        super().__init__(**kwargs)
        self.front = front
        self.focused_tty = focused_tty

    def frontmost_application(self):
        return self.front

    def osascript(self, script, *arguments):
        from jrbar.answer_local import _FOCUSED_TTY_SCRIPTS

        if script in _FOCUSED_TTY_SCRIPTS.values():
            self.calls.append(("focused-tty",))
            return 0, self.focused_tty
        return super().osascript(script, *arguments)


def test_session_in_front_says_yes_only_on_proof__and_6_more(tmp_path: Path, monkeypatch) -> None:
    from jrbar import answer_local

    monkeypatch.setattr(answer_local, "process_cwd", lambda pid: "/Users/me/repo")
    no_record = SimpleNamespace(recorded=lambda provider, session_id: None)

    def ask(runner, *, table=GHOSTTY_CODEX, recorder=no_record, pid=500, agent_id=None):
        controller, status = _live(pid=pid)
        if agent_id is not None:
            status.agent_id = agent_id
        return surfaces.session_in_front(
            controller, status, runner=runner, recorder=recorder, process_table=lambda: table
        )

    one = "T1\t/Users/me/repo\tcodex\nT2\t/tmp\tzsh\n"

    # --- scenario: the only Ghostty terminal in the session's directory, focused, is in front
    assert ask(_FrontRunner(focused="T1\t/Users/me/repo", ghostty_terminals=one)) == {
        "session": "codex:session:s-1",
        "in_front": True,
        "evidence": "focused_surface_cwd",
        "app": "Ghostty",
    }

    # --- scenario: another Ghostty tab in front is a no -- the case the app alone cannot see
    reply = ask(_FrontRunner(focused="T2\t/tmp", ghostty_terminals=one))
    assert (reply["in_front"], reply["evidence"]) == (False, "other_surface")

    # --- scenario: two terminals in the directory: the surface the session started in decides
    both = "T1\t/Users/me/repo\tzsh\nT3\t/Users/me/repo\tcodex\n"
    started_in_t3 = SimpleNamespace(recorded=lambda provider, session_id: "T3")
    reply = ask(_FrontRunner(focused="T3\t/Users/me/repo", ghostty_terminals=both), recorder=started_in_t3)
    assert (reply["in_front"], reply["evidence"]) == (True, "recorded_surface")
    reply = ask(_FrontRunner(focused="T1\t/Users/me/repo", ghostty_terminals=both), recorder=started_in_t3)
    assert (reply["in_front"], reply["evidence"]) == (False, "other_surface")
    reply = ask(_FrontRunner(focused="T1\t/Users/me/repo", ghostty_terminals=both))
    assert (reply["in_front"], reply["evidence"]) == (None, "focused_surface_unproven")

    # --- scenario: Terminal.app answers by the focused tab's tty
    front = ("com.apple.Terminal", 300)
    reply = ask(_FrontRunner(front=front, focused_tty="/dev/ttys004"), table=TERMINAL_CODEX)
    assert (reply["in_front"], reply["evidence"], reply["app"]) == (True, "focused_tab_tty", "Terminal")
    reply = ask(_FrontRunner(front=front, focused_tty="/dev/ttys009"), table=TERMINAL_CODEX)
    assert (reply["in_front"], reply["evidence"]) == (False, "other_tab")
    reply = ask(_FrontRunner(front=front, focused_tty=""), table=TERMINAL_CODEX)
    assert (reply["in_front"], reply["evidence"]) == (None, "focused_tab_unproven")

    # --- scenario: another app in front is a no; a tmux pane or an unscriptable terminal cannot be told
    reply = ask(_FrontRunner(front=("com.apple.Safari", 999)))
    assert (reply["in_front"], reply["evidence"]) == (False, "other_app")
    reply = ask(_FrontRunner(), table=TMUX_CODEX)
    assert (reply["in_front"], reply["evidence"]) == (None, "tmux_unproven")
    reply = ask(_FrontRunner(front=("net.kovidgoyal.kitty", 200)))
    assert (reply["in_front"], reply["evidence"]) == (None, "tab_unproven")

    # --- scenario: with no Apple-events grant yet it is unknown, and nothing is sent to ask
    runner = _FrontRunner(permitted=None, focused="T1\t/Users/me/repo", ghostty_terminals=one)
    reply = ask(runner)
    assert (reply["in_front"], reply["evidence"]) == (None, "automation_not_granted")
    assert [call for call in runner.calls if call[0] != "permitted?"] == []

    # --- scenario: an ended session, a remote row or an unwalkable process table is unknown
    assert ask(_FrontRunner(), pid=None)["evidence"] == "not_running"
    assert ask(_FrontRunner(), agent_id="remote:studio:codex:session:s-1")["evidence"] == "remote"
    reply = ask(_FrontRunner(), table={})
    assert (reply["in_front"], reply["evidence"]) == (None, "ownership_unproven")


def test_session_in_front_is_a_socket_thread_command__and_1_more() -> None:
    from jrbar.core_runtime import _MAIN_THREAD_COMMANDS, _cmd_session_in_front

    # --- scenario: registered off the main thread, its Apple events never stall a refresh
    assert _MAIN_THREAD_COMMANDS["session_in_front"].main_thread is False

    # --- scenario: the row is found by its id; a remote row answers without a probe
    remote = SimpleNamespace(agent_id="remote:studio:codex:session:s-1", provider="codex", session_id="s-1")
    controller = SimpleNamespace(last_snapshot=SimpleNamespace(statuses=[remote], stale_statuses=[]))
    reply = _cmd_session_in_front(controller, {"session": remote.agent_id})
    assert reply == {"session": remote.agent_id, "in_front": None, "evidence": "remote", "app": None}
    with pytest.raises(CommandError) as error:
        _cmd_session_in_front(controller, {"session": "claude:session:nobody"})
    assert error.value.code == "not_found"


def test_history_resumes_a_session_the_list_no_longer_shows__and_5_more(tmp_path: Path) -> None:
    from jrbar.answer_surfaces import resume_ended_session

    repo = tmp_path / "repo"
    repo.mkdir()
    ended = SimpleNamespace(cwd=str(repo), pid=500, ended_at_epoch=1.0)
    recorder = SurfaceRecorder(path=tmp_path / "surfaces.json", runner=FakeRunner(permitted=None), synchronous=True)
    recorder._store("codex", "s-1", host_bundle="com.mitchellh.ghostty", terminal_id="T1", cwd=str(repo))

    def resume(agent_id="codex:session:s-1", record=ended, runner=None, **kwargs):
        return resume_ended_session(
            agent_id,
            runner=runner or FakeRunner(),
            recorder=kwargs.pop("recorder", recorder),
            load_record=lambda provider, session_id: record,
            process_table=lambda: GHOSTTY_CODEX,
            **kwargs,
        )

    # --- scenario: an ended session resumes in a new tab of the terminal it ran in
    runner = FakeRunner()
    reply = resume(runner=runner)
    assert (reply["raised"], reply["app"], reply["detail"], reply["cwd"]) == ("new_tab", "Ghostty", "resumed", str(repo))
    assert runner.calls == [("ghostty-new-tab", str(repo), "codex resume s-1\n")]

    # --- scenario: the terminal named wins; with no record, the owner's latest terminal
    runner = FakeRunner()
    assert resume(runner=runner, terminal="com.apple.Terminal")["app"] == "Terminal"
    assert runner.calls == [("launch", "com.apple.Terminal", f"cd {repo} && codex resume s-1")]
    fresh = SurfaceRecorder(path=tmp_path / "other.json", runner=FakeRunner(permitted=None), synchronous=True)
    fresh._store("claude", "x-9", host_bundle="com.googlecode.iterm2", terminal_id=None, cwd=str(repo))
    runner = FakeRunner()
    assert resume(runner=runner, recorder=fresh)["app"] == "iTerm"

    # --- scenario: cleared from the list but still running: its own window is raised, nothing started
    alive = SimpleNamespace(cwd=str(repo), pid=500, ended_at_epoch=None)
    runner = FakeRunner(ghostty_terminals=f"T1\t{repo}\tcodex\n")
    reply = resume(record=alive, runner=runner, record_is_live=lambda record: True)
    assert (reply["raised"], reply["detail"]) == ("terminal", "T1")
    assert not any(call[0] in ("ghostty-new-tab", "launch") for call in runner.calls)
    with pytest.raises(CommandError) as error:
        resume_ended_session(
            "codex:session:s-1",
            runner=FakeRunner(activate=False),
            recorder=recorder,
            load_record=lambda provider, session_id: alive,
            record_is_live=lambda record: True,
            process_table=lambda: _table(_entry(500, 1, "/bin/codex")),
        )
    assert error.value.code == "not_found" and "nothing new was started" in str(error.value)

    # --- scenario: a registry record that was left open but whose process is gone resumes
    runner = FakeRunner()
    assert resume(record=alive, runner=runner, record_is_live=lambda record: False)["detail"] == "resumed"

    # --- scenario: no record, a directory that is gone, or not a resumable session refuses
    with pytest.raises(CommandError) as error:
        resume(record=None)
    assert error.value.code == "not_found"
    with pytest.raises(CommandError) as error:
        resume(record=SimpleNamespace(cwd=str(tmp_path / "gone"), pid=500, ended_at_epoch=1.0))
    assert error.value.code == "not_found"
    for agent_id, code in (
        ("remote:studio:codex:session:s-1", "unsupported"),
        ("codex:agent:worker-1", "unsupported"),
        ("pi:session:s-1", "unsupported"),
        ("", "invalid_args"),
    ):
        with pytest.raises(CommandError) as error:
            resume(agent_id)
        assert error.value.code == code, agent_id

    # --- scenario: only the terminals JR-Bar can open are accepted by name
    with pytest.raises(CommandError) as error:
        resume(terminal="net.kovidgoyal.kitty")
    assert error.value.code == "invalid_args"


def test_resume_session_opens_a_listed_row_and_resumes_a_gone_one__and_1_more(monkeypatch) -> None:
    from jrbar import answer_surfaces as surfaces_module
    from jrbar import core_runtime

    listed = SimpleNamespace(agent_id="codex:session:s-1", provider="codex", session_id="s-1")
    controller = SimpleNamespace(last_snapshot=SimpleNamespace(statuses=[listed], stale_statuses=[]))
    opened: list = []
    resumed: list = []
    monkeypatch.setattr(core_runtime, "_cmd_open_session", lambda self, args: opened.append(args) or {"via": "open"})
    monkeypatch.setattr(
        surfaces_module,
        "resume_ended_session",
        lambda session, terminal=None: resumed.append((session, terminal)) or {"via": "registry"},
    )

    # --- scenario: a row the list still shows opens exactly as open_session would
    assert core_runtime._cmd_resume_session(controller, {"session": "codex:session:s-1"}) == {"via": "open"}
    assert opened == [{"session": "codex:session:s-1"}] and resumed == []

    # --- scenario: one it no longer shows is resumed from the registry, in the terminal named
    reply = core_runtime._cmd_resume_session(
        controller, {"session": "claude:session:gone", "terminal": "com.apple.Terminal"}
    )
    assert reply == {"via": "registry"}
    assert resumed == [("claude:session:gone", "com.apple.Terminal")]
    assert core_runtime._MAIN_THREAD_COMMANDS["resume_session"].main_thread is False
