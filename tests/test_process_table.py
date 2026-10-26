from __future__ import annotations

import ctypes
import os
import sys

import pytest

from jrbar import process_table as pt


def test_process_table_keeps_paths_terminals_and_precise_start_times():
    class Library:
        def proc_listallpids(self, buffer, size):
            if buffer is not None:
                buffer[0], buffer[1] = 42, 43
            return 2

        def proc_pidinfo(self, pid, flavor, arg, pointer, size):
            if pid == 43:
                return 0  # process exited while enumerating
            info = ctypes.cast(pointer, ctypes.POINTER(pt.BsdInfo)).contents
            info.pid, info.ppid, info.start_sec, info.start_usec = pid, 1, 123, 456789
            info.ttydev = 9
            return size

        def proc_pidpath(self, pid, buffer, size):
            buffer.value = b"/Applications/Synthetic Agent/agent"
            return len(buffer.value)

    table = pt.read_process_table(library=Library(), terminals={9: "/dev/ttys009"}, launch_reader=lambda _: None)
    assert set(table) == {42}
    assert table[42].command == "/Applications/Synthetic Agent/agent"
    assert table[42].started_at_epoch == 123.456789
    assert table[42].tty == "/dev/ttys009"


@pytest.mark.skipif(sys.platform != "darwin", reason="Darwin libproc")
def test_native_table_identifies_this_process_without_starting_a_child(monkeypatch):
    import subprocess

    def forbidden(*args, **kwargs):
        raise AssertionError("process discovery forked a child")

    monkeypatch.setattr(subprocess, "Popen", forbidden)
    table = pt.read_process_table()
    entry = table[os.getpid()]
    assert entry.ppid == os.getppid()
    assert entry.started_at_epoch > 0
    assert entry.executable == os.path.realpath(sys.executable)
    assert entry.command == pt.launch_path(os.getpid())


def test_launch_path_reads_only_the_prefix_and_handles_permission_denial():
    import errno

    def read(mib, count, buffer, size, *_):
        assert list(mib) == [1, 49, 42]
        assert len(buffer) == 4100
        buffer.raw = b"\x01\0\0\0/opt/bin/claude\0".ljust(len(buffer), b"\0")
        ctypes.set_errno(errno.ENOMEM)
        return -1

    assert pt.launch_path(42, sysctl=read) == "/opt/bin/claude"

    def denied(*_):
        ctypes.set_errno(errno.EPERM)
        return -1

    assert pt.launch_path(42, sysctl=denied) is None


def test_native_table_omits_zombies_but_keeps_inaccessible_pid_as_unknown():
    import errno

    class Library:
        denied = False
        def proc_listallpids(self, buffer, size):
            if buffer is not None:
                buffer[0] = 42
            return 1
        def proc_pidinfo(self, pid, flavor, arg, pointer, size):
            if self.denied:
                ctypes.set_errno(errno.EPERM)
                return 0
            info = ctypes.cast(pointer, ctypes.POINTER(pt.BsdInfo)).contents
            info.pid, info.status = pid, 5
            return size
        def proc_pidpath(self, *_):
            raise AssertionError("zombie must not be read as live")

    lib = Library()
    assert pt.read_process_table(library=lib, terminals={}) == {}
    lib.denied = True
    denied = pt.read_process_table(library=lib, terminals={})[42]
    assert denied.command == "" and denied.started_at_epoch is None
