"""Persistence honesty in the daemon: what it does when the files under it change.

The ``headless`` fixture comes from ``test_core_runtime``; ``_refreshable`` and
``_tick`` are the refresh harness ``test_refresh_budget`` uses. The persistence
writer's thread never runs in this harness, so a queued save is driven inline
where a test needs it to land.
"""

from __future__ import annotations

import json
from pathlib import Path
from types import SimpleNamespace

import pytest
from test_core_runtime import _effect_pack_payload, _effects_daemon, _PackReads
from test_refresh_budget import _refreshable, _tick

from jrbar import core_runtime
from jrbar import settings as settings_module
from jrbar import status_bar_legacy as legacy
from jrbar.persistence_writer import PersistenceDisposition
from jrbar.settings import SettingsConcurrentWriteError, SettingsWriteRefusedError

pytest_plugins = ("test_core_runtime",)


# --- the pack list -------------------------------------------------------------


def test_a_stray_file_in_the_pack_folder_leaves_the_daemons_pack_list_cached(
    headless, monkeypatch: pytest.MonkeyPatch, tmp_path: Path
) -> None:
    """A Finder ``.DS_Store`` or a scratch file an interrupted write left
    behind used to make the whole store unavailable; the cached list, keyed
    on the store's fingerprint, still serves and still follows real changes."""
    from jrbar.effect_pack_store import EffectPackStore

    controller, root = _effects_daemon(headless, monkeypatch, tmp_path)
    store = EffectPackStore(root)
    assert store.install(_effect_pack_payload("calm-pack")).accepted
    (root / ".DS_Store").write_bytes(b"\x00")
    (root / "calm-pack.json.4242.1.0123456789abcdef0123456789abcdef.tmp").write_text("{")
    lines: list[str] = []
    controller._core_log = lines.append
    reads = _PackReads(monkeypatch)

    assert [pack.pack_id for pack in core_runtime._effect_packs(controller)] == ["calm-pack"]
    core_runtime._effect_packs(controller)
    core_runtime._effect_packs(controller)

    assert reads.count == 1, "the list is kept under the store's fingerprint"
    assert controller._core_effect_packs_cache is not None
    assert [line for line in lines if "unavailable" in line] == []
    assert store.install(_effect_pack_payload("second-pack", "Second Pack")).accepted
    assert {pack.pack_id for pack in core_runtime._effect_packs(controller)} == {
        "calm-pack",
        "second-pack",
    }
    assert reads.count == 2


# --- settings.json edited under the daemon --------------------------------------


class _Daemon:
    """The headless daemon over a real settings file it has loaded."""

    def __init__(self, headless, monkeypatch: pytest.MonkeyPatch) -> None:
        self.controller = _refreshable(headless)
        self.controller.schedule_event_refresh = lambda: None
        self.path = settings_module.settings_file_path()
        self.lines: list[str] = []
        monkeypatch.setattr(legacy, "log_status_bar", self.lines.append)
        self.saves = 0
        real_save = legacy.save_settings

        def counting_save(settings):
            self.saves += 1
            return real_save(settings)

        monkeypatch.setattr(legacy, "save_settings", counting_save)
        self.touched: list[list[str]] = []
        self.controller._core_after_settings_change = self.touched.append
        # The daemon starts by loading the file; this is that load.
        settings_module.save_settings(self.controller.settings)
        self.controller.settings = settings_module.load_settings()
        writer = self.controller._persistence_writer
        monkeypatch.setattr(writer, "snapshot", lambda: SimpleNamespace(pending_count=0, running=False))

        def inline_submit(_key, operation, **_kwargs):
            operation()
            return PersistenceDisposition.QUEUED

        self.inline_submit = inline_submit
        self.writer = writer
        self.monkeypatch = monkeypatch

    @property
    def replaced(self) -> Path:
        return self.path.with_name(self.path.name + ".replaced")

    def kept(self) -> list[Path]:
        """The ``.corrupt-<stamp>`` copies of the settings file."""
        return sorted(self.path.parent.glob(f"{self.path.name}.corrupt-*"))

    def toggle(self, value: int) -> None:
        """The person changes Alert burst in the app: it replies at once and queues the save."""
        self.controller._core_dispatch("set_setting", {"path": "alert_burst", "value": value})

    def edit_outside(self, **changes) -> dict:
        document = json.loads(self.path.read_text(encoding="utf-8"))
        document.update(changes)
        self.path.write_text(json.dumps(document), encoding="utf-8")
        return document

    def lines_about_the_file(self) -> list[str]:
        return [line for line in self.lines if "settings.json" in line]

    def settings_frames(self) -> list[dict]:
        return [doc for kind, doc in self.controller._core.published if kind == "settings"]


@pytest.fixture
def daemon(headless, monkeypatch: pytest.MonkeyPatch) -> _Daemon:
    return _Daemon(headless, monkeypatch)


def test_a_settings_save_that_lost_to_an_outside_edit_is_adopted_not_retried(daemon: _Daemon) -> None:
    controller = daemon.controller
    daemon.toggle(6)
    edited = daemon.edit_outside(alert_burst=9, external_owner="kept")
    saves_before = daemon.saves

    assert controller._core_flush_settings() is False
    assert controller._core_settings_dirty is False
    assert daemon.saves == saves_before + 1
    generation = controller._core_settings_generation
    # What the toggle itself reported is not what the adoption reports.
    daemon.touched.clear()
    for _ in range(3):
        _tick(controller)

    assert daemon.saves == saves_before + 1, "the lost save was not retried"
    assert controller.settings.alert_burst == 9
    assert controller._core_settings_generation > generation
    assert daemon.settings_frames()[-1]["document"]["alert_burst"] == 9
    assert json.loads(daemon.path.read_text(encoding="utf-8")) == edited, "the edit was not overwritten"
    backup = json.loads(daemon.replaced.read_text(encoding="utf-8"))
    assert backup["alert_burst"] == 6, "what memory held is kept"
    assert (daemon.replaced.stat().st_mode & 0o777) == 0o600
    assert len(daemon.lines_about_the_file()) == 1
    assert "settings.json.replaced" in daemon.lines_about_the_file()[0]
    assert len(daemon.touched) == 1 and "alert_burst" in daemon.touched[0], (
        "the adoption runs the side effects of the keys it changed, once"
    )
    # The adopted file is the new baseline: the next toggle saves, over the edit, not over nothing.
    daemon.toggle(4)
    assert controller._core_flush_settings() is True
    after = json.loads(daemon.path.read_text(encoding="utf-8"))
    assert after["alert_burst"] == 4 and after["external_owner"] == "kept"


def test_an_outside_edit_with_no_save_waiting_does_not_trigger_anything(daemon: _Daemon) -> None:
    daemon.edit_outside(alert_burst=9)

    for _ in range(3):
        _tick(daemon.controller)

    assert daemon.controller._core_settings_conflict is None
    assert daemon.controller.settings.alert_burst != 9
    assert daemon.lines_about_the_file() == []


def test_an_incidental_read_does_not_hide_the_outside_edit_from_the_daemon(daemon: _Daemon) -> None:
    """The daemon reads settings for one field on a timer (a statusline check,
    a price table). That must not make it look as if it had seen the edit."""
    controller = daemon.controller
    daemon.toggle(6)
    daemon.edit_outside(alert_burst=9)
    settings_module.load_settings(track=False)

    assert controller._core_flush_settings() is False

    _tick(controller)
    assert controller.settings.alert_burst == 9


def test_the_dnd_save_that_lost_to_an_outside_edit_asks_for_the_same_adoption(daemon: _Daemon) -> None:
    """Every save site in the daemon, not only the writer's, gets the recovery."""
    controller = daemon.controller
    daemon.edit_outside(alert_burst=9)

    with pytest.raises(SettingsConcurrentWriteError):
        controller.dnd_controller._settings_saver(controller.settings)

    assert controller._core_settings_conflict is not None
    _tick(controller)
    assert controller.settings.alert_burst == 9
    assert controller._core_settings_conflict is None


def test_a_conflict_on_another_file_is_not_the_daemons_to_adopt(daemon: _Daemon, tmp_path: Path) -> None:
    other = tmp_path / "elsewhere" / "settings.json"
    settings_module.save_settings(daemon.controller.settings, other)
    settings_module.load_settings_document(other)
    document = json.loads(other.read_text(encoding="utf-8"))
    document["alert_burst"] = 9
    other.write_text(json.dumps(document), encoding="utf-8")

    with pytest.raises(SettingsConcurrentWriteError):
        settings_module.save_settings(daemon.controller.settings, other)

    assert daemon.controller._core_settings_conflict is None


def test_an_invalid_outside_edit_is_set_aside_after_a_second_look_and_memory_is_saved_again(
    daemon: _Daemon,
) -> None:
    controller = daemon.controller
    daemon.toggle(6)
    daemon.path.write_text("{ not json", encoding="utf-8")
    assert controller._core_flush_settings() is False

    _tick(controller)

    # The first look moves nothing: an editor may still be saving.
    assert daemon.path.read_text(encoding="utf-8") == "{ not json" and daemon.kept() == []
    assert controller._core_settings_conflict is not None
    assert daemon.lines_about_the_file() == []

    _tick(controller)

    assert controller.settings.alert_burst == 6, "an invalid file is never adopted"
    (kept,) = daemon.kept()
    assert kept.read_text(encoding="utf-8") == "{ not json"
    assert not daemon.replaced.exists()
    assert controller._core_settings_conflict is None
    assert controller._core_settings_dirty is True
    assert len(daemon.lines_about_the_file()) == 1 and "set it aside" in daemon.lines_about_the_file()[0]
    daemon.monkeypatch.setattr(daemon.writer, "submit", daemon.inline_submit)
    _tick(controller)
    assert json.loads(daemon.path.read_text(encoding="utf-8"))["alert_burst"] == 6
    assert controller._core_settings_dirty is False


def test_an_editors_half_written_save_is_waited_for_not_moved_out_from_under_it(daemon: _Daemon) -> None:
    controller = daemon.controller
    daemon.toggle(6)
    daemon.path.write_text('{"alert_burst": 9, "tips_', encoding="utf-8")
    assert controller._core_flush_settings() is False

    _tick(controller)
    # The editor is still writing: the file changes between the looks.
    daemon.path.write_text('{"alert_burst": 9, "tips_enabled": fal', encoding="utf-8")
    _tick(controller)
    assert daemon.kept() == [] and daemon.path.exists()
    assert controller._core_settings_conflict is not None

    # The editor finishes. Its file is adopted whole; nothing was set aside.
    daemon.path.write_text(json.dumps({"alert_burst": 9, "tips_enabled": False}), encoding="utf-8")
    _tick(controller)

    assert controller.settings.alert_burst == 9 and controller.settings.tips_enabled is False
    assert daemon.kept() == []
    assert json.loads(daemon.replaced.read_text(encoding="utf-8"))["alert_burst"] == 6
    assert controller._core_settings_conflict is None and controller._core_settings_unsettled is None


def test_a_deleted_settings_file_is_written_again_from_memory(daemon: _Daemon) -> None:
    controller = daemon.controller
    daemon.toggle(6)
    daemon.path.unlink()
    assert controller._core_flush_settings() is False

    daemon.monkeypatch.setattr(daemon.writer, "submit", daemon.inline_submit)
    _tick(controller)

    assert json.loads(daemon.path.read_text(encoding="utf-8"))["alert_burst"] == 6
    assert controller.settings.alert_burst == 6
    assert "removed outside" in daemon.lines_about_the_file()[0]


def test_a_read_that_fails_for_now_keeps_the_conflict_and_says_so_once(
    daemon: _Daemon, monkeypatch: pytest.MonkeyPatch
) -> None:
    controller = daemon.controller
    daemon.toggle(6)
    daemon.edit_outside(alert_burst=9)
    assert controller._core_flush_settings() is False

    def unavailable(_target):
        raise OSError("temporarily unavailable")

    with monkeypatch.context() as patched:
        patched.setattr(settings_module, "_read_document", unavailable)
        for _ in range(3):
            _tick(controller)
        assert controller._core_settings_conflict is not None
        assert len(daemon.lines_about_the_file()) == 1
    _tick(controller)

    assert controller.settings.alert_burst == 9
    assert controller._core_settings_conflict is None


def test_a_conflict_found_at_quit_still_keeps_what_memory_held(daemon: _Daemon) -> None:
    controller = daemon.controller
    controller.applicationDidFinishLaunching_(None)
    daemon.toggle(6)
    edited = daemon.edit_outside(alert_burst=9)
    assert controller._core_flush_settings() is False

    controller._core_quit_flush()

    assert json.loads(daemon.path.read_text(encoding="utf-8")) == edited
    assert json.loads(daemon.replaced.read_text(encoding="utf-8"))["alert_burst"] == 6


def test_a_file_deleted_before_quit_is_written_out_at_quit(daemon: _Daemon) -> None:
    controller = daemon.controller
    controller.applicationDidFinishLaunching_(None)
    daemon.toggle(6)
    daemon.path.unlink()
    assert controller._core_flush_settings() is False

    controller._core_quit_flush()

    assert json.loads(daemon.path.read_text(encoding="utf-8"))["alert_burst"] == 6
    assert controller._core_settings_dirty is False


def test_an_invalid_file_seen_twice_by_quit_is_set_aside_and_memory_is_written_out(daemon: _Daemon) -> None:
    controller = daemon.controller
    controller.applicationDidFinishLaunching_(None)
    daemon.toggle(6)
    daemon.path.write_text("{ not json", encoding="utf-8")
    assert controller._core_flush_settings() is False
    _tick(controller)  # the first look
    assert daemon.kept() == []

    controller._core_quit_flush()  # the second look finds it unchanged

    (kept,) = daemon.kept()
    assert kept.read_text(encoding="utf-8") == "{ not json"
    assert json.loads(daemon.path.read_text(encoding="utf-8"))["alert_burst"] == 6
    assert controller._core_settings_dirty is False


def test_a_file_that_is_unreadable_at_the_first_look_is_left_alone_at_quit(daemon: _Daemon) -> None:
    controller = daemon.controller
    controller.applicationDidFinishLaunching_(None)
    daemon.toggle(6)
    daemon.path.write_text('{"half": ', encoding="utf-8")
    assert controller._core_flush_settings() is False

    controller._core_quit_flush()

    assert daemon.path.read_text(encoding="utf-8") == '{"half": ' and daemon.kept() == []


def test_adopting_a_file_leaves_the_document_clean_so_nothing_is_written_after_it(daemon: _Daemon) -> None:
    """A save that failed through the DND path leaves the settings dirty; the
    adoption replaces memory with the file, so no write may follow it."""
    controller = daemon.controller
    daemon.toggle(6)
    assert controller._core_settings_dirty is True
    daemon.edit_outside(alert_burst=9)
    with pytest.raises(SettingsConcurrentWriteError):
        controller.dnd_controller._settings_saver(controller.settings)
    saves_before = daemon.saves
    daemon.monkeypatch.setattr(daemon.writer, "submit", daemon.inline_submit)

    _tick(controller)
    _tick(controller)

    assert controller.settings.alert_burst == 9
    assert controller._core_settings_dirty is False
    assert daemon.saves == saves_before, "the adopted document was not written back"


def test_a_file_that_cannot_be_read_yet_is_retried_next_refresh_and_at_quit(
    daemon: _Daemon, monkeypatch: pytest.MonkeyPatch
) -> None:
    from jrbar.settings import SettingsFileUnreadableError

    controller = daemon.controller
    attempts: list[int] = []
    unreadable = [True]

    def half_written(settings):
        attempts.append(settings.alert_burst)
        if unreadable[0]:
            raise SettingsFileUnreadableError("settings file is unreadable; load it before saving")

    monkeypatch.setattr(legacy, "save_settings", half_written)
    daemon.toggle(6)
    assert controller._core_flush_settings() is False
    assert controller._core_settings_dirty is True, "the change is kept, not dropped"
    unreadable_lines = [line for line in daemon.lines if "unreadable" in line]
    assert len(unreadable_lines) == 1 and "retrying" in unreadable_lines[0]
    assert controller._core_flush_settings() is False
    assert len([line for line in daemon.lines if "unreadable" in line]) == 1, "said once"

    # The next refresh retries it once nothing is queued.
    monkeypatch.setattr(daemon.writer, "submit", daemon.inline_submit)
    unreadable[0] = False
    controller._core_settings_conflict = None  # the file is whole again
    _tick(controller)
    assert attempts[-1] == 6 and controller._core_settings_dirty is False

    # And at quit: the change that could not be saved is tried once more.
    controller.applicationDidFinishLaunching_(None)
    unreadable[0] = True
    daemon.toggle(7)
    assert controller._core_settings_dirty is True
    unreadable[0] = False
    controller._core_settings_conflict = None  # the file is whole again
    controller._core_quit_flush()
    assert attempts[-1] == 7 and controller._core_settings_dirty is False


def test_a_refused_settings_save_is_not_retried_every_refresh(
    daemon: _Daemon, monkeypatch: pytest.MonkeyPatch
) -> None:
    controller = daemon.controller
    attempts: list[int] = []
    outcome: list[Exception | None] = [SettingsWriteRefusedError("settings were written by a newer JR-Bar version")]

    def refusing(settings):
        attempts.append(settings.alert_burst)
        if outcome[0] is not None:
            raise outcome[0]

    monkeypatch.setattr(legacy, "save_settings", refusing)
    daemon.toggle(6)
    assert controller._core_flush_settings() is False
    monkeypatch.setattr(daemon.writer, "submit", daemon.inline_submit)
    for _ in range(5):
        _tick(controller)

    assert attempts == [6], "a refusal that can never succeed is not retried"
    assert controller._core_settings_dirty is False
    assert controller.settings.alert_burst == 6, "the in-memory value stays live"
    refusal_lines = [line for line in daemon.lines if "will not be retried" in line]
    assert len(refusal_lines) == 1

    # The same refusal is not said twice; a save that works resets that.
    # (The writer runs inline from here, so each toggle saves at once.)
    daemon.toggle(7)
    assert attempts == [6, 7]
    assert len([line for line in daemon.lines if "will not be retried" in line]) == 1
    outcome[0] = None
    daemon.toggle(8)
    assert attempts == [6, 7, 8] and controller._core_settings_refusal is None
    outcome[0] = SettingsWriteRefusedError("settings were written by a newer JR-Bar version")
    daemon.toggle(9)
    assert len([line for line in daemon.lines if "will not be retried" in line]) == 2


def test_an_io_error_is_still_retried_by_the_next_refresh(
    daemon: _Daemon, monkeypatch: pytest.MonkeyPatch
) -> None:
    controller = daemon.controller
    attempts: list[int] = []
    failing = [True]

    def flaky(settings):
        attempts.append(settings.alert_burst)
        if failing[0]:
            raise OSError("disk full")

    monkeypatch.setattr(legacy, "save_settings", flaky)
    daemon.toggle(6)
    assert controller._core_flush_settings() is False
    assert controller._core_settings_dirty is True
    failing[0] = False
    monkeypatch.setattr(daemon.writer, "submit", daemon.inline_submit)
    _tick(controller)
    assert attempts == [6, 6] and controller._core_settings_dirty is False
