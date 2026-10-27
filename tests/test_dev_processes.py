"""Dev process cleanup uses recorded identities, with no real signals."""

from __future__ import annotations

import ctypes
import importlib.util
import json
import signal
import subprocess
from pathlib import Path

import pytest


@pytest.fixture(scope="module")
def dev():
    source = Path(__file__).resolve().parents[1] / "app/scripts/dev-processes.py"
    spec = importlib.util.spec_from_file_location("dev_processes", source)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


class Clock:
    def __init__(self):
        self.now = 0.0

    def read(self):
        return self.now

    def pause(self, duration):
        self.now += duration


def record(**extra):
    return {"pid": 42, "identity": "darwin:100:200", **extra}


def test_record_round_trip_and_legacy_records_are_ignored(dev, tmp_path):
    path = tmp_path / "dev.pids"
    path.write_text("42\n43\n")
    assert dev.read_records(path) == []
    dev.write_records(path, [record()])
    assert dev.read_records(path) == [record()]
    assert path.stat().st_mode & 0o777 == 0o600
    path.write_text(json.dumps({"version": 1, "processes": [None, {"pid": True}, record()]}))
    assert dev.read_records(path) == [record()]


def test_darwin_identity_includes_microseconds_and_ignores_zombies(dev, monkeypatch):
    class Reader:
        status = 2

        def __call__(self, pid, flavor, offset, pointer, size):
            assert (pid, flavor, offset, size) == (42, 3, 0, 136)
            info = ctypes.cast(pointer, ctypes.POINTER(dev.BSDInfo)).contents
            info.ids[1] = self.status
            info.started_seconds = 100
            info.started_microseconds = 200
            return size

    reader = Reader()
    library = type("Library", (), {"proc_pidinfo": reader})()
    monkeypatch.setattr(dev.sys, "platform", "darwin")
    monkeypatch.setattr(dev.ctypes, "CDLL", lambda *_, **__: library)
    assert dev.process_identity(42) == "darwin:100:200"
    reader.status = 5
    assert dev.process_identity(42) is None
    assert dev.process_identity(0) is None


def test_reused_pid_is_never_signaled(dev):
    signals = []
    clock = Clock()
    dev.stop_records([record()], identity=lambda _: "darwin:100:201",
                     send_signal=lambda *args: signals.append(args),
                     clock=clock.read, pause=clock.pause)
    assert signals == []
    assert clock.now == 0


def test_identity_is_rechecked_before_escalation(dev):
    signals = []
    clock = Clock()
    live_identity = record()["identity"]

    def send(pid, sig):
        nonlocal live_identity
        signals.append((pid, sig))
        live_identity = "darwin:100:201"

    dev.stop_records([record()], identity=lambda _: live_identity, send_signal=send,
                     clock=clock.read, pause=clock.pause)
    assert signals == [(42, signal.SIGTERM)]


def test_unresponsive_owned_process_has_bounded_escalation(dev):
    signals = []
    clock = Clock()
    remaining = dev.stop_records([record()], identity=lambda _: record()["identity"],
                                 send_signal=lambda *args: signals.append(args),
                                 clock=clock.read, pause=clock.pause, timeout=0.3)
    assert signals == [(42, signal.SIGTERM), (42, signal.SIGKILL)]
    assert remaining == [record()]
    assert clock.now == pytest.approx(0.8)


def test_dead_mock_cannot_make_an_existing_socket_ready(dev, tmp_path):
    owners = []
    clock = Clock()
    assert not dev.await_socket(record(), tmp_path / "mock.sock", identity=lambda _: None,
                                owner=lambda *args: owners.append(args),
                                socket_state=lambda _: [1, 2, 3],
                                clock=clock.read, pause=clock.pause)
    assert owners == []
    assert clock.now == 0


def test_another_process_socket_never_becomes_ready(dev, tmp_path):
    clock = Clock()
    assert not dev.await_socket(record(), tmp_path / "mock.sock",
                                identity=lambda _: record()["identity"], owner=lambda *_: False,
                                socket_state=lambda _: [1, 2, 3],
                                clock=clock.read, pause=clock.pause, timeout=0.3)
    assert clock.now == pytest.approx(0.3)


@pytest.mark.parametrize("replacement", (True, False))
def test_readiness_rechecks_process_and_socket_after_ownership(dev, tmp_path, replacement):
    clock = Clock()
    current = record()["identity"]
    inode = [1, 2, 3]

    def owner(*_):
        nonlocal current, inode
        if replacement:
            inode = [1, inode[1] + 1, 3]
        else:
            current = None
        return True

    assert not dev.await_socket(record(), tmp_path / "mock.sock", identity=lambda _: current,
                                owner=owner, socket_state=lambda _: inode,
                                clock=clock.read, pause=clock.pause, timeout=0.3)


def test_owned_socket_becomes_ready_and_is_recorded(dev, tmp_path):
    entry = record()
    clock = Clock()
    path = tmp_path / "mock.sock"
    assert dev.await_socket(entry, path, identity=lambda _: entry["identity"],
                            owner=lambda *_: True, socket_state=lambda _: [1, 2, 3],
                            clock=clock.read, pause=clock.pause)
    assert entry["socket"] == {"path": str(path), "identity": [1, 2, 3]}


@pytest.mark.parametrize("actual,expected,removed", (
    ([1, 2, 3], [1, 2, 3], True),
    ([1, 4, 3], [1, 2, 3], False),
    (None, None, False),
))
def test_cleanup_preserves_replacements_and_unknown_socket_identity(dev, tmp_path, actual, expected, removed):
    path = tmp_path / "socket-placeholder"
    path.write_text("temporary fixture")
    clock = Clock()
    dev.stop_records([record(socket={"path": str(path), "identity": expected})],
                     identity=lambda _: None, send_signal=lambda *_: pytest.fail("no owner"),
                     socket_state=lambda _: actual, clock=clock.read, pause=clock.pause)
    assert path.exists() is not removed


def test_socket_owner_requires_exact_pid_and_path(dev, tmp_path, monkeypatch):
    path = tmp_path / "mock.sock"
    calls = []

    def run(command, **kwargs):
        calls.append((command, kwargs))
        return subprocess.CompletedProcess(command, 0, f"p42\nn{path}\n", "")

    monkeypatch.setattr(dev.subprocess, "run", run)
    assert dev.owns_socket(42, path)
    assert not dev.owns_socket(42, tmp_path / "other.sock")
    assert calls[0][0] == ["/usr/sbin/lsof", "-a", "-p", "42", "-U", "-Fn"]
    assert calls[0][1]["timeout"] == 0.5


@pytest.fixture()
def fake_dev_script(tmp_path):
    root = Path(__file__).resolve().parents[1]
    scripts = tmp_path / "app/scripts"
    scripts.mkdir(parents=True)
    script = scripts / "run-dev.sh"
    script.write_text((root / "app/scripts/run-dev.sh").read_text())
    fake_bin = tmp_path / "bin"
    fake_bin.mkdir()
    fake_python = fake_bin / "python3"
    fake_python.write_text(
        '#!/bin/sh\n'
        'printf "%s\\n" "$*" >> "$DEV_CALLS"\n'
        'case "$1" in\n'
        '  */mock-core.py) exit 1 ;;\n'
        '  */dev-processes.py) [ "$2" != wait ] ;;\n'
        '  *) exit 99 ;;\n'
        'esac\n'
    )
    fake_python.chmod(0o700)
    calls = tmp_path / "calls"
    return script, fake_bin, calls


@pytest.mark.parametrize("kind", ("file", "broken-symlink"))
def test_script_refuses_existing_paths_before_launch_or_build(fake_dev_script, tmp_path, kind):
    script, fake_bin, calls = fake_dev_script
    socket_path = tmp_path / "mock.sock"
    if kind == "file":
        socket_path.write_text("preserve")
    else:
        socket_path.symlink_to(tmp_path / "missing")
    result = subprocess.run(
        ["/bin/zsh", str(script)], capture_output=True, text=True, timeout=5,
        env={"PATH": f"{fake_bin}:/usr/bin:/bin", "HOME": str(tmp_path),
             "JRBAR_CORE_SOCKET": str(socket_path), "DEV_CALLS": str(calls)},
    )
    assert result.returncode == 1
    assert "occupied socket path" in result.stderr
    assert len(calls.read_text().splitlines()) == 1
    assert socket_path.is_symlink() if kind == "broken-symlink" else socket_path.read_text() == "preserve"


def test_failed_readiness_runs_cleanup_without_starting_app(fake_dev_script, tmp_path):
    script, fake_bin, calls = fake_dev_script
    bundle = tmp_path / "app/build/JR-Bar-dev.app"
    bundle.mkdir(parents=True)
    result = subprocess.run(
        ["/bin/zsh", str(script)], capture_output=True, text=True, timeout=5,
        env={"PATH": f"{fake_bin}:/usr/bin:/bin", "HOME": str(tmp_path),
             "JRBAR_CORE_SOCKET": str(tmp_path / "mock.sock"), "DEV_CALLS": str(calls)},
    )
    assert result.returncode == 1
    commands = calls.read_text().splitlines()
    assert sum("dev-processes.py stop " in command for command in commands) == 2
    assert any("dev-processes.py wait " in command for command in commands)
    # The background mock may not log before the readiness failure returns.
    process_commands = [command for command in commands if "dev-processes.py " in command]
    assert len(process_commands) == 4
    assert sum("dev-processes.py add " in command for command in process_commands) == 1
