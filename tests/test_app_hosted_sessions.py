"""Which app hosts a live session, and what a click does about it.

The process tables here are shaped like real ones: the Codex desktop app
ships inside ChatGPT.app (its main process is ``ChatGPT``, the thread runner
is ``codex app-server`` under it), T3 Code and Devin are Electron apps, cmux
is a terminal that logs the shell in. Nothing reads the real process table,
runs a script or activates an app.
"""

from __future__ import annotations

from types import SimpleNamespace

import pytest

from jrbar import answer_surfaces as surfaces
from jrbar.answer_surfaces import (
    APP_HOSTED_BUNDLE_IDS,
    RaiseOutcome,
    SessionHost,
    SurfaceRunner,
    host_from_ancestry,
    not_found_message,
    open_live_session,
    resume_ended_session,
)
from jrbar.core_server import CommandError

CHATGPT = "/Applications/ChatGPT.app/Contents/MacOS/ChatGPT"
CODEX_CLI = "/Applications/ChatGPT.app/Contents/Resources/codex-cli/CodexCLI.app/Contents/MacOS/codex"
RENDERER = (
    "/Applications/ChatGPT.app/Contents/Frameworks/Codex Framework.framework/Versions/154.0.8037.98/"
    "Helpers/Codex (Renderer).app/Contents/MacOS/Codex (Renderer)"
)


def _entry(pid: int, ppid: int, command: str, tty: str | None = None):
    return SimpleNamespace(pid=pid, ppid=ppid, command=command, started_at_epoch=1.0, tty=tty)


def _table(*rows):
    return {row.pid: row for row in rows}


class _Runner(SurfaceRunner):
    def __init__(self, *, activate: bool = True) -> None:
        self.activate_result = activate
        self.calls: list[tuple] = []

    def activate(self, bundle_id):
        self.calls.append(("activate", bundle_id))
        return self.activate_result

    def osascript(self, script, *arguments):
        raise AssertionError("an app-hosted raise runs no script")

    def tmux(self, *arguments):
        self.calls.append(("tmux", *arguments))
        return 0, ""


# (label, the agent's command, [(ancestor command, ...)] nearest first, app name, bundle id)
HOSTS = [
    pytest.param(
        "codex app-server in ChatGPT.app",
        CODEX_CLI,
        [CHATGPT],
        "Codex",
        "com.openai.codex",
        id="codex-desktop-app-server",
    ),
    pytest.param(
        "codex exec-server in ChatGPT.app",
        CODEX_CLI,
        [CHATGPT],
        "Codex",
        "com.openai.codex",
        id="codex-desktop-exec-server",
    ),
    pytest.param(
        "a tool the app-server runs",
        "/Applications/ChatGPT.app/Contents/Resources/cua_node/bin/node",
        [CODEX_CLI, CHATGPT],
        "Codex",
        "com.openai.codex",
        id="codex-desktop-tool-child",
    ),
    pytest.param(
        "a Codex renderer helper",
        "/bin/zsh",
        [RENDERER],
        "Codex",
        "com.openai.codex",
        id="codex-desktop-renderer",
    ),
    pytest.param(
        "Codex.app (older name)",
        "/bin/codex",
        ["/Applications/Codex.app/Contents/MacOS/Codex"],
        "Codex",
        "com.openai.codex",
        id="codex-app-old-name",
    ),
    pytest.param(
        "Claude desktop",
        "/Users/me/Library/Application Support/Claude/claude-code/2.1.280/claude.app/Contents/MacOS/claude",
        ["/Applications/Claude.app/Contents/Helpers/disclaimer", "/Applications/Claude.app/Contents/MacOS/Claude"],
        "Claude",
        "com.anthropic.claudefordesktop",
        id="claude-desktop",
    ),
    pytest.param(
        "T3 Code",
        "claude",
        ["/Applications/T3 Code (Nightly).app/Contents/MacOS/T3 Code (Nightly)"],
        "T3 Code",
        "com.t3tools.t3code",
        id="t3-code",
    ),
    pytest.param(
        "Cursor",
        "/Users/me/.local/bin/claude",
        [
            "/bin/zsh",
            "/Applications/Cursor.app/Contents/Frameworks/Cursor Helper (Plugin).app/Contents/MacOS/Cursor Helper (Plugin)",
        ],
        "Cursor",
        "com.todesktop.230313mzl4w4u92",
        id="cursor",
    ),
    pytest.param(
        "VS Code",
        "/Users/me/.local/bin/claude",
        [
            "/bin/zsh",
            "/Applications/Visual Studio Code.app/Contents/Frameworks/Code Helper (Plugin).app/Contents/MacOS/Code Helper (Plugin)",
        ],
        "Visual Studio Code",
        "com.microsoft.VSCode",
        id="vscode",
    ),
    pytest.param(
        "Windsurf",
        "/Users/me/.local/bin/claude",
        [
            "/bin/zsh",
            "/Applications/Windsurf.app/Contents/Frameworks/Windsurf Helper (Plugin).app/Contents/MacOS/Windsurf Helper (Plugin)",
        ],
        "Windsurf",
        "com.exafunction.windsurf",
        id="windsurf",
    ),
    pytest.param(
        "Codex extension inside Devin",
        "/Users/me/.devin/extensions/openai.chatgpt-26.908.40401-darwin-arm64/bin/macos-aarch64/codex",
        ["/Applications/Devin.app/Contents/Frameworks/Devin Helper (Plugin).app/Contents/MacOS/Devin Helper (Plugin)"],
        "Devin",
        "com.exafunction.windsurf",
        id="devin",
    ),
    pytest.param(
        "cmux",
        "/Users/me/.local/bin/claude",
        ["-/bin/zsh", "/usr/bin/login", "/Applications/cmux.app/Contents/MacOS/cmux"],
        "cmux",
        "com.cmuxterm.app",
        id="cmux",
    ),
    pytest.param(
        "Warp",
        "/Users/me/.local/bin/claude",
        ["/bin/zsh", "/Applications/Warp.app/Contents/MacOS/stable"],
        "Warp",
        "dev.warp.Warp-Stable",
        id="warp",
    ),
    pytest.param(
        "kitty",
        "/Users/me/.local/bin/claude",
        ["/bin/zsh", "/Applications/kitty.app/Contents/MacOS/kitty"],
        "kitty",
        "net.kovidgoyal.kitty",
        id="kitty",
    ),
    pytest.param(
        "WezTerm",
        "/Users/me/.local/bin/claude",
        ["/bin/zsh", "/Applications/WezTerm.app/Contents/MacOS/wezterm-gui"],
        "WezTerm",
        "com.github.wez.wezterm",
        id="wezterm",
    ),
    pytest.param(
        "Antigravity",
        "/Users/me/.local/bin/agy",
        ["/bin/zsh", "/Applications/Antigravity.app/Contents/Frameworks/Antigravity Helper (Plugin).app/Contents/MacOS/Antigravity Helper (Plugin)"],
        "Antigravity",
        "com.google.antigravity",
        id="antigravity",
    ),
    pytest.param(
        "Ghostty",
        "/opt/homebrew/bin/codex",
        ["/bin/zsh", "/usr/bin/login", "/Applications/Ghostty.app/Contents/MacOS/ghostty"],
        "Ghostty",
        "com.mitchellh.ghostty",
        id="ghostty",
    ),
    pytest.param(
        "iTerm2",
        "/opt/homebrew/bin/codex",
        ["/bin/zsh", "/usr/bin/login", "/Applications/iTerm.app/Contents/MacOS/iTerm2"],
        "iTerm",
        "com.googlecode.iterm2",
        id="iterm",
    ),
    pytest.param(
        "Terminal",
        "/opt/homebrew/bin/codex",
        ["/bin/zsh", "/usr/bin/login", "/System/Applications/Utilities/Terminal.app/Contents/MacOS/Terminal"],
        "Terminal",
        "com.apple.Terminal",
        id="terminal",
    ),
]


def _chain(agent: str, ancestors: list[str]):
    """A table with the agent at pid 100 and its ancestors above it."""
    rows = []
    pid = 100
    command = agent
    for ancestor in ancestors:
        rows.append(_entry(pid, pid + 1, command))
        pid += 1
        command = ancestor
    rows.append(_entry(pid, 1, command))
    return _table(*rows)


@pytest.mark.parametrize(("label", "agent", "ancestors", "name", "bundle"), HOSTS)
def test_every_known_host_app_is_found_above_the_agent(label, agent, ancestors, name, bundle) -> None:
    assert host_from_ancestry(100, _chain(agent, ancestors)) == (name, bundle, False), label


def test_a_codex_desktop_thread_is_app_hosted_not_terminal_hosted() -> None:
    table = _table(
        _entry(687, 1, CHATGPT),
        _entry(1421, 687, CODEX_CLI + " -c features.code_mode_host=true app-server --analytics-default-enabled"),
    )
    _app, bundle, in_tmux = host_from_ancestry(1421, table)
    assert bundle == "com.openai.codex" and bundle in APP_HOSTED_BUNDLE_IDS and not in_tmux


def _live(pid: int, origin_bundle: str | None = None):
    extras = SimpleNamespace(
        pid=pid,
        terminal=None,
        cwd="/Users/me/repo",
        name=None,
        origin={"kind": "x", "label": "x", "bundle_id": origin_bundle} if origin_bundle else None,
    )
    controller = SimpleNamespace(
        settings=SimpleNamespace(session_open_action=lambda provider, origin: None),
        _core_extras_for=lambda status: extras,
    )
    status = SimpleNamespace(
        agent_id="codex:session:s-1",
        provider="codex",
        session_id="s-1",
        origin="Codex UI",
        cwd="/Users/me/repo",
    )
    return controller, status


def _recorder(tmp_path):
    return surfaces.SurfaceRecorder(path=tmp_path / "s.json", runner=_Runner(), synchronous=True)


def test_a_click_on_a_codex_desktop_thread_goes_to_the_apps_own_link(tmp_path) -> None:
    table = _table(
        _entry(687, 1, CHATGPT),
        _entry(1421, 687, CODEX_CLI),
    )
    controller, status = _live(1421)
    runner = _Runner()
    # None is "the controller's ladder": the codex:// thread link, not a terminal raise and not a refusal.
    assert (
        open_live_session(
            controller, status, {}, runner=runner, recorder=_recorder(tmp_path), process_table=lambda: table
        )
        is None
    )
    assert runner.calls == []


def test_a_host_the_walk_cannot_name_falls_back_to_the_hooks_origin(tmp_path) -> None:
    # An unknown wrapper stands between the agent and launchd.
    table = _table(_entry(100, 99, "/usr/local/bin/codex"), _entry(99, 1, "/opt/mystery/launcher"))

    # --- scenario: the origin says the provider's own app: the app's link is the click
    controller, status = _live(100, origin_bundle="com.openai.codex")
    assert (
        open_live_session(
            controller,
            status,
            {},
            runner=_Runner(),
            recorder=_recorder(tmp_path),
            process_table=lambda: table,
        )
        is None
    )

    # --- scenario: the origin says an editor: that app comes forward
    controller, status = _live(100, origin_bundle="com.microsoft.VSCode")
    runner = _Runner()
    reply = open_live_session(
        controller, status, {}, runner=runner, recorder=_recorder(tmp_path), process_table=lambda: table
    )
    assert (reply["raised"], reply["bundle_id"], reply["app"]) == ("app", "com.microsoft.VSCode", "Visual Studio Code")
    assert runner.calls == [("activate", "com.microsoft.VSCode")]


def test_t3_code_and_devin_sessions_bring_their_app_forward(tmp_path) -> None:
    for agent, ancestors, bundle in (
        ("claude", ["/Applications/T3 Code (Nightly).app/Contents/MacOS/T3 Code (Nightly)"], "com.t3tools.t3code"),
        (
            "/Users/me/.devin/extensions/openai.chatgpt-26.908.40401-darwin-arm64/bin/macos-aarch64/codex",
            [
                "/Applications/Devin.app/Contents/Frameworks/Devin Helper (Plugin).app"
                "/Contents/MacOS/Devin Helper (Plugin)"
            ],
            "com.exafunction.windsurf",
        ),
    ):
        controller, status = _live(100)
        runner = _Runner()
        reply = open_live_session(
            controller,
            status,
            {},
            runner=runner,
            recorder=_recorder(tmp_path),
            process_table=lambda agent=agent, ancestors=ancestors: _chain(agent, ancestors),
        )
        assert (reply["raised"], reply["bundle_id"]) == ("app", bundle)
        assert runner.calls == [("activate", bundle)]


def test_a_session_nothing_hosts_says_what_it_looked_through(tmp_path) -> None:
    table = _table(
        _entry(100, 99, "/usr/local/bin/codex"),
        _entry(99, 98, "/bin/sh"),
        _entry(98, 1, "/opt/mystery/launcher"),
    )
    controller, status = _live(100)
    with pytest.raises(CommandError) as error:
        open_live_session(
            controller, status, {}, runner=_Runner(), recorder=_recorder(tmp_path), process_table=lambda: table
        )
    assert error.value.code == "not_found"
    message = str(error.value)
    assert "found no terminal or app that hosts it" in message
    assert "It looked through: sh > launcher." in message
    assert message.endswith("Nothing new was started.")
    # Names only: never a path or an argument.
    assert "/opt" not in message


def test_a_host_that_does_not_come_forward_is_named(tmp_path) -> None:
    table = _chain("claude", ["/Applications/T3 Code (Nightly).app/Contents/MacOS/T3 Code (Nightly)"])
    controller, status = _live(100)
    with pytest.raises(CommandError) as error:
        open_live_session(
            controller,
            status,
            {},
            runner=_Runner(activate=False),
            recorder=_recorder(tmp_path),
            process_table=lambda: table,
        )
    message = str(error.value)
    assert "T3 Code (com.t3tools.t3code)" in message and "did not come forward" in message
    assert message.endswith("Nothing new was started.")


def test_the_not_found_sentence_covers_tmux_and_an_unreadable_table() -> None:
    tmux = not_found_message(
        SessionHost(pid=5, tty="/dev/ttys004", app_name=None, bundle_id=None, in_tmux=True),
        RaiseOutcome("none", "tmux", None, "no tmux pane has that tty"),
    )
    assert "running in tmux" in tmux and "/dev/ttys004" in tmux
    unreadable = not_found_message(SessionHost(pid=5, tty=None, app_name=None, bundle_id=None), RaiseOutcome("none"), {})
    assert "could not read the session's process" in unreadable
    alone = not_found_message(
        SessionHost(pid=5, tty=None, app_name=None, bundle_id=None),
        RaiseOutcome("none"),
        _table(_entry(5, 1, "/bin/codex")),
    )
    assert "no parent but launchd" in alone


def test_history_resume_of_a_live_codex_desktop_thread_brings_the_app_forward(tmp_path) -> None:
    repo = tmp_path / "repo"
    repo.mkdir()
    table = _table(_entry(687, 1, CHATGPT), _entry(1421, 687, CODEX_CLI))
    runner = _Runner()
    reply = resume_ended_session(
        "codex:session:s-1",
        runner=runner,
        recorder=_recorder(tmp_path),
        load_record=lambda provider, session_id: SimpleNamespace(cwd=str(repo), pid=1421, ended_at_epoch=None),
        record_is_live=lambda record: True,
        process_table=lambda: table,
    )
    assert (reply["raised"], reply["bundle_id"]) == ("app", "com.openai.codex")
    assert ("activate", "com.openai.codex") in runner.calls
