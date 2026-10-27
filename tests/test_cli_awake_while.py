"""``jrbar awake -- <command>`` and ``jrbar awake --pid N`` over the fake
core socket. Nothing here runs a real command or a real ``caffeinate``: the
spawner is a recording fake, so no test holds the Mac awake."""

from __future__ import annotations

import tempfile
from pathlib import Path

import pytest

from jrbar import cli_control
from tests.test_cli_control import core, run  # noqa: F401  (the fake core fixture)


class _Child:
    def __init__(self, command, pid: int, returncode: int) -> None:
        self.command = list(command)
        self.pid = pid
        self.returncode = returncode
        self.waited = False
        self.killed = False

    def wait(self, timeout=None) -> int:
        self.waited = True
        return self.returncode

    def kill(self) -> None:
        self.killed = True


class _Spawner:
    def __init__(self, returncode: int = 0, fail: type[BaseException] | None = None) -> None:
        self.returncode = returncode
        self.fail = fail
        self.spawned: list[_Child] = []
        self.kwargs: list[dict] = []

    def __call__(self, command, **kwargs) -> _Child:
        if self.fail is not None and not self.spawned:
            raise self.fail(2, "No such file or directory")
        child = _Child(command, 4242 + len(self.spawned), self.returncode)
        self.spawned.append(child)
        self.kwargs.append(kwargs)
        return child


def _no_signals():
    return lambda: None


def _missing_socket() -> Path:
    return Path(tempfile.gettempdir()) / "jrc-missing-awake" / "core.sock"


def test_the_command_runs_held_and_its_exit_status_comes_back(core, capsys) -> None:  # noqa: F811
    spawn = _Spawner(returncode=3)
    status = cli_control.cmd_awake_while(
        ["swift", "test", "--filter", "TOKEN=secret"],
        lambda: cli_control.CoreConnection(core.path),
        spawn=spawn,
        ignore_interrupts=_no_signals,
    )
    assert status == 3
    assert spawn.spawned[0].command == ["swift", "test", "--filter", "TOKEN=secret"]
    assert spawn.spawned[0].waited
    sent = core.commands[-1]
    assert sent["name"] == "hold_awake"
    # The name only: never an argument, which may carry a secret.
    assert sent["args"] == {"pid": 4242, "label": "swift", "source": "cli"}
    assert "secret" not in str(sent)
    assert "while swift runs" in capsys.readouterr().err


def test_a_signal_ends_the_command_with_the_shell_s_status(core) -> None:  # noqa: F811
    spawn = _Spawner(returncode=-2)
    status = cli_control.cmd_awake_while(
        ["/usr/bin/make"], lambda: cli_control.CoreConnection(core.path), spawn=spawn, ignore_interrupts=_no_signals
    )
    assert status == 130
    assert core.commands[-1]["args"]["label"] == "make"


def test_without_the_monitor_caffeinate_holds_the_computer_only(capsys) -> None:
    spawn = _Spawner(returncode=0)
    status = cli_control.cmd_awake_while(
        ["swift", "build"],
        lambda: cli_control.CoreConnection(_missing_socket()),
        spawn=spawn,
        ignore_interrupts=_no_signals,
    )
    assert status == 0
    fallback = spawn.spawned[1].command
    assert fallback == ["/usr/bin/caffeinate", "-i", "-w", "4242"]
    assert "-d" not in fallback, "never a display assertion"
    assert "monitor is not running" in capsys.readouterr().err


def test_a_refused_hold_still_runs_the_command(core, capsys) -> None:  # noqa: F811
    core.replies["hold_awake"] = {"ok": False, "error": {"code": "refused", "message": "That process has already ended."}}
    spawn = _Spawner(returncode=0)
    status = cli_control.cmd_awake_while(
        ["true"], lambda: cli_control.CoreConnection(core.path), spawn=spawn, ignore_interrupts=_no_signals
    )
    assert status == 0
    assert len(spawn.spawned) == 1, "no caffeinate while the monitor answered"
    assert "without a hold" in capsys.readouterr().err


def test_a_missing_command_is_127(core) -> None:  # noqa: F811
    spawn = _Spawner(fail=FileNotFoundError)
    status = cli_control.cmd_awake_while(
        ["no-such-tool"], lambda: cli_control.CoreConnection(core.path), spawn=spawn, ignore_interrupts=_no_signals
    )
    assert status == 127
    assert core.commands == []


def test_the_router_splits_at_the_first_double_dash(core, monkeypatch) -> None:  # noqa: F811
    seen: list[list[str]] = []
    monkeypatch.setattr(cli_control, "cmd_awake_while", lambda command, _connect: seen.append(command) or 0)
    assert run(["awake", "--", "swift", "test", "--", "-v"], core) == 0
    assert seen == [["swift", "test", "--", "-v"]]


def test_the_router_refuses_mixed_shapes(core, capsys) -> None:  # noqa: F811
    assert run(["awake", "2h", "--", "swift"], core) == 2
    assert run(["awake", "--pid", "4242", "--", "swift"], core) == 2
    assert run(["awake", "--"], core) == 2
    assert "command" in capsys.readouterr().err


def test_pid_asks_the_monitor_and_returns(core, capsys) -> None:  # noqa: F811
    core.replies["hold_awake"] = {
        "ok": True,
        "result": {"lease": {"kind": "process", "pid": 4242, "label": "swift"}, "hold": {}},
    }
    assert run(["awake", "--pid", "4242"], core) == 0
    assert core.commands[-1]["args"] == {"pid": 4242, "source": "cli"}
    assert "while swift (pid 4242) runs" in capsys.readouterr().out


def test_pid_without_the_monitor_leaves_caffeinate_holding(capsys) -> None:
    spawn = _Spawner()
    status = cli_control.cmd_awake_pid(
        4242, lambda: cli_control.CoreConnection(_missing_socket()), spawn=spawn
    )
    assert status == 0
    assert spawn.spawned[0].command == ["/usr/bin/caffeinate", "-i", "-w", "4242"]
    assert spawn.kwargs[0]["start_new_session"] is True
    assert "caffeinate holds" in capsys.readouterr().out


@pytest.mark.parametrize("pid", ["0", "1"])
def test_pid_must_be_a_real_process(core, pid) -> None:  # noqa: F811
    assert run(["awake", "--pid", pid], core) == 2
