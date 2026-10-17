"""Mock startup preserves files and sockets it cannot prove are stale."""

from __future__ import annotations

import errno
import importlib.util
import socket
import sys
import tempfile
from pathlib import Path

import pytest

ROOT = Path(__file__).resolve().parents[1]


@pytest.fixture(scope="module")
def mock_module():
    spec = importlib.util.spec_from_file_location("mock_core_socket_safety", ROOT / "app/scripts/mock-core.py")
    module = importlib.util.module_from_spec(spec)
    sys.modules[spec.name] = module
    spec.loader.exec_module(module)
    return module


@pytest.fixture()
def socket_path():
    # Darwin limits Unix socket paths to 104 bytes.
    with tempfile.TemporaryDirectory(prefix="jrbar-mock-safety-") as directory:
        yield Path(directory) / "mock.sock"


@pytest.mark.parametrize("kind", ("file", "directory", "symlink", "broken-symlink"))
def test_non_socket_entries_are_preserved(mock_module, socket_path, kind):
    target = socket_path.parent / "target"
    target.write_text("keep this")
    if kind == "file":
        socket_path.write_text("keep this")
    elif kind == "directory":
        socket_path.mkdir()
    else:
        socket_path.symlink_to(target if kind == "symlink" else socket_path.parent / "missing")
    previous = socket_path.lstat()
    with pytest.raises(ValueError, match="not a socket"):
        mock_module.prepare_socket_path(socket_path)
    assert socket_path.lstat().st_ino == previous.st_ino
    assert target.read_text() == "keep this"


def test_only_a_stale_socket_is_removed(mock_module, socket_path):
    with socket.socket(socket.AF_UNIX, socket.SOCK_STREAM) as server:
        server.bind(str(socket_path))
        server.listen(1)
        with pytest.raises(ValueError, match="another daemon is listening"):
            mock_module.prepare_socket_path(socket_path)
        assert socket_path.exists()
    mock_module.prepare_socket_path(socket_path)
    assert not socket_path.exists()
    mock_module.prepare_socket_path(socket_path)


def test_another_users_socket_is_preserved(mock_module, socket_path, monkeypatch):
    with socket.socket(socket.AF_UNIX, socket.SOCK_STREAM) as server:
        server.bind(str(socket_path))
    previous = socket_path.lstat()
    monkeypatch.setattr(mock_module.os, "getuid", lambda: previous.st_uid + 1)
    with pytest.raises(ValueError, match="another user owns it"):
        mock_module.prepare_socket_path(socket_path)
    assert socket_path.lstat().st_ino == previous.st_ino


@pytest.mark.parametrize("error", (PermissionError(errno.EACCES, "denied"), TimeoutError("timed out")))
def test_probe_failures_preserve_the_socket(mock_module, socket_path, monkeypatch, error):
    with socket.socket(socket.AF_UNIX, socket.SOCK_STREAM) as server:
        server.bind(str(socket_path))
    previous = socket_path.lstat()
    timeouts = []

    class Probe:
        def __enter__(self):
            return self

        def __exit__(self, *_):
            pass

        def settimeout(self, timeout):
            timeouts.append(timeout)

        def connect(self, _):
            raise error

    monkeypatch.setattr(mock_module.socket, "socket", lambda *_: Probe())
    with pytest.raises(ValueError, match="cannot confirm a stale socket"):
        mock_module.prepare_socket_path(socket_path)
    assert socket_path.lstat().st_ino == previous.st_ino
    assert timeouts == [0.25]


def test_a_replacement_during_probe_is_preserved(mock_module, socket_path, monkeypatch):
    with socket.socket(socket.AF_UNIX, socket.SOCK_STREAM) as server:
        server.bind(str(socket_path))

    class Probe:
        def __enter__(self):
            return self

        def __exit__(self, *_):
            pass

        def settimeout(self, _):
            pass

        def connect(self, _):
            socket_path.rename(socket_path.parent / "old.sock")
            socket_path.write_text("replacement")
            raise ConnectionRefusedError(errno.ECONNREFUSED, "refused")

    monkeypatch.setattr(mock_module.socket, "socket", lambda *_: Probe())
    with pytest.raises(ValueError, match="socket path changed"):
        mock_module.prepare_socket_path(socket_path)
    assert socket_path.read_text() == "replacement"
