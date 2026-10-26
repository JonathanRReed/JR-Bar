import os
import select

import pytest

from jrbar.settings_watch import SettingsWatcher


def test_safety_poll_recovers_without_statting_on_every_housekeeping_tick(tmp_path):
    watcher = SettingsWatcher([tmp_path / "settings.json"], clock=lambda: 0, start=False)
    assert watcher.changed(now=0)
    for now in range(1, 30):
        assert not watcher.changed(now=now)
    assert watcher.changed(now=30)
    watcher._dirty.set()
    assert watcher.changed(now=31)
    assert not watcher.changed(now=32)
    watcher.close()


@pytest.mark.skipif(not hasattr(select, "kqueue"), reason="Darwin kqueue")
def test_atomic_replacement_and_directory_replacement_wake_the_watch(tmp_path):
    path = tmp_path / "settings.json"
    path.write_text("{}")
    watcher = SettingsWatcher([path])
    try:
        assert watcher._ready.wait(3)
        watcher.changed(now=0)
        replacement = tmp_path / "replacement"
        replacement.write_text('{"enabled":false}')
        os.replace(replacement, path)
        assert watcher._dirty.wait(3)
        assert watcher.changed(now=1)
        assert path.read_text() == '{"enabled":false}'
    finally:
        watcher.close()
        watcher._thread.join(timeout=3)
        assert not watcher._thread.is_alive()
