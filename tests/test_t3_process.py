"""Process detection never starts a shell or opens T3's database."""
from __future__ import annotations

from types import SimpleNamespace

import pytest

from jrbar import t3_process


@pytest.mark.parametrize("bundle, expected", [
    (b"/Applications/T3 Code.app/Contents/MacOS/T3 Code", True),
    (b"/Applications/T3 Code (Nightly).app/Contents/MacOS/T3 Code (Nightly)", True),
    (b"/synthetic/T3 Code", False),
])
def test_libproc_accepts_only_the_desktop_bundle(tmp_path, monkeypatch, bundle, expected):
    database = tmp_path / 'userdata/state.sqlite'
    database.parent.mkdir()
    database.touch()
    class Lib:
        def proc_listpids(self, kind, flags, buffer, size):
            if buffer is not None:
                buffer[0] = 42
            return 4

        def proc_name(self, pid, buffer, size):
            buffer.value = b"T3 Code"
            return len(buffer.value)

        def proc_pidpath(self, pid, buffer, size):
            buffer.value = bundle
            return len(bundle)

    monkeypatch.setattr(t3_process, "_libproc", lambda: Lib())
    monkeypatch.setattr(t3_process, "_cached", (0.0, False))
    assert t3_process.t3_code_running(base_dir=tmp_path) is expected
    monkeypatch.setattr(t3_process, "_libproc", lambda: pytest.fail("cached check loaded libproc"))
    assert t3_process.t3_code_running(base_dir=tmp_path) is expected


@pytest.mark.parametrize('name, uses_database, expected', [
    (b't3-code', True, True), (b'node', True, True), (b'bun', True, True),
    (b't3-code', False, False), (b'node', False, False), (b'other', True, False),
])
def test_headless_hosts_must_use_the_same_database(tmp_path, monkeypatch, name, uses_database, expected):
    database = tmp_path / 'userdata/state.sqlite'
    database.parent.mkdir()
    database.touch()
    class Lib:
        def proc_listpids(self, kind, flags, buffer, size):
            if buffer is not None:
                buffer[0] = 42
            return 4

        def proc_name(self, pid, buffer, size):
            buffer.value = name
            return len(name)

        def proc_pidpath(self, pid, buffer, size):
            buffer.value = b'/synthetic/bin/host'
            return len(buffer.value)

    monkeypatch.setattr(t3_process, '_libproc', lambda: Lib())
    monkeypatch.setattr(t3_process, '_uses_t3_database', lambda lib, pid, **kw: uses_database)
    monkeypatch.setattr(t3_process, '_cached', (0.0, False))
    assert t3_process.t3_code_running(base_dir=tmp_path) is expected


def test_native_descriptor_reader_matches_only_its_database(tmp_path):
    import os
    import sqlite3

    lib = t3_process._libproc()
    if lib is None:
        pytest.skip('requires libproc')
    (tmp_path / 'userdata').mkdir()
    with sqlite3.connect(tmp_path / 'userdata/statev2.sqlite') as connection:
        connection.execute('CREATE TABLE synthetic (id TEXT)')
        assert t3_process._uses_t3_database(lib, os.getpid(), base_dir=tmp_path)
        assert not t3_process._uses_t3_database(lib, os.getpid(), base_dir=tmp_path / 'other')


def test_missing_database_never_scans_processes_and_checks_disk_once_a_minute(tmp_path, monkeypatch):
    clock = [0.0]
    stats = []
    original = type(tmp_path).is_file
    monkeypatch.setattr(t3_process, 'time', SimpleNamespace(monotonic=lambda: clock[0]))
    monkeypatch.setattr(t3_process, '_cached', (0.0, False))
    monkeypatch.setattr(t3_process, '_libproc', lambda: pytest.fail('absent T3 scanned processes'))

    def is_file(path):
        stats.append(path)
        return original(path)

    monkeypatch.setattr(type(tmp_path), 'is_file', is_file)
    for tick in range(0, 60, 2):
        clock[0] = float(tick)
        assert not t3_process.t3_code_running(base_dir=tmp_path)
    assert len(stats) == 2
    database = tmp_path / 'userdata/statev2.sqlite'
    database.parent.mkdir()
    database.touch()
    monkeypatch.setattr(t3_process, '_libproc', lambda: None)
    clock[0] = 60.0
    assert not t3_process.t3_code_running(base_dir=tmp_path)
    assert len(stats) == 4


def test_stopped_headless_hosts_scan_at_most_twice_a_minute(tmp_path, monkeypatch):
    clock = [0.0]
    scans = []
    database = tmp_path / 'userdata/state.sqlite'
    database.parent.mkdir()
    database.touch()

    class Lib:
        def proc_listpids(self, kind, flags, buffer, size):
            if buffer is not None:
                buffer[0] = 42
            return 4

        def proc_name(self, pid, buffer, size):
            buffer.value = b'node'
            return len(buffer.value)

        def proc_pidpath(self, pid, buffer, size):
            buffer.value = b'/synthetic/bin/node'
            return len(buffer.value)

    monkeypatch.setattr(t3_process, 'time', SimpleNamespace(monotonic=lambda: clock[0]))
    monkeypatch.setattr(t3_process, '_cached', (0.0, False))
    monkeypatch.setattr(t3_process, '_libproc', lambda: Lib())
    monkeypatch.setattr(t3_process, '_uses_t3_database', lambda *a, **kw: (scans.append(clock[0]), False)[1])
    for tick in range(0, 60, 2):
        clock[0] = float(tick)
        assert not t3_process.t3_code_running(base_dir=tmp_path)
    assert scans == [0.0, 30.0]
