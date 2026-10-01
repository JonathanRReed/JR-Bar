from __future__ import annotations

import json
from dataclasses import replace
from pathlib import Path

import pytest

from jrbar.settings import (
    AgentMonitorSettings,
    SettingsConcurrentWriteError,
    load_settings_document,
    save_settings,
)


def test_external_edit_after_load_is_never_silently_overwritten__and_2_more(tmp_path: Path,) -> None:
    # --- scenario: external_edit_after_load_is_never_silently_overwritten
    target = tmp_path / "settings.json"
    save_settings(AgentMonitorSettings(), target)
    loaded = load_settings_document(target)

    external = json.loads(target.read_text(encoding="utf-8"))
    external["external_owner"] = {"preserve": True}
    target.write_text(json.dumps(external), encoding="utf-8")

    with pytest.raises(SettingsConcurrentWriteError):
        save_settings(
            loaded.settings.with_tips_enabled(False),
            target,
            compatibility=loaded.compatibility,
        )

    assert json.loads(target.read_text(encoding="utf-8")) == external

    # --- scenario: successful_save_refreshes_the_expected_document_digest
    target = tmp_path / "settings.json"
    loaded = load_settings_document(target)
    updated = loaded.settings.with_tips_enabled(False)

    save_settings(updated, target, compatibility=loaded.compatibility)
    save_settings(updated, target)

    assert json.loads(target.read_text(encoding="utf-8"))["tips_enabled"] is False

    # --- scenario: concurrent_write_refuses_dnd_override_without_partial_durable_state
    target = tmp_path / "settings.json"
    save_settings(AgentMonitorSettings(), target)
    loaded = load_settings_document(target)
    candidate = replace(
        loaded.settings,
        dnd_override_mode="mute",
        dnd_override_created_epoch=1_800_000_000.0,
        dnd_override_until_epoch=1_800_003_600.0,
    )
    external = json.loads(target.read_text(encoding="utf-8"))
    external["external_owner"] = "keep"
    target.write_text(json.dumps(external), encoding="utf-8")

    with pytest.raises(SettingsConcurrentWriteError):
        save_settings(candidate, target, compatibility=loaded.compatibility)

    durable = json.loads(target.read_text(encoding="utf-8"))
    assert durable == external
    assert durable["dnd_override_mode"] is None
    assert durable["dnd_override_created_epoch"] is None
    assert durable["dnd_override_until_epoch"] is None



def _kept_copies(target: Path) -> list[Path]:
    return sorted(target.parent.glob(f"{target.name}.corrupt-*"))


# --- an incidental read is not a reload ---------------------------------------


def _loaded_then_edited_outside(target: Path):
    """Settings loaded the way the daemon loads them, then changed by hand."""
    save_settings(AgentMonitorSettings(), target)
    loaded = load_settings_document(target)
    external = json.loads(target.read_text(encoding="utf-8"))
    external["external_owner"] = {"edited": "by hand"}
    target.write_text(json.dumps(external), encoding="utf-8")
    return loaded, external


def test_an_incidental_untracked_load_does_not_rebaseline(tmp_path: Path) -> None:
    from jrbar.settings import load_settings

    target = tmp_path / "settings.json"
    loaded, external = _loaded_then_edited_outside(target)

    load_settings(target, track=False)

    with pytest.raises(SettingsConcurrentWriteError):
        save_settings(loaded.settings.with_tips_enabled(False), target)
    assert json.loads(target.read_text(encoding="utf-8")) == external
    # A deliberate, tracked reload is the one that re-baselines.
    reloaded = load_settings(target)
    save_settings(reloaded.with_tips_enabled(False), target)
    assert json.loads(target.read_text(encoding="utf-8"))["tips_enabled"] is False
    assert json.loads(target.read_text(encoding="utf-8"))["external_owner"] == {"edited": "by hand"}


def test_a_failed_incidental_read_does_not_forget_the_baseline(
    tmp_path: Path, monkeypatch: pytest.MonkeyPatch
) -> None:
    from jrbar import settings as settings_module

    target = tmp_path / "settings.json"
    loaded, external = _loaded_then_edited_outside(target)

    def refuse(_target):
        raise OSError("transient")

    monkeypatch.setattr(settings_module, "_read_document", refuse)
    settings_module.load_settings(target, track=False)
    monkeypatch.undo()

    assert target.absolute() in settings_module._COMPATIBILITY_BY_PATH
    with pytest.raises(SettingsConcurrentWriteError):
        save_settings(loaded.settings.with_tips_enabled(False), target)


def test_an_untracked_load_of_a_corrupt_file_still_sets_it_aside_but_keeps_the_baseline(
    tmp_path: Path,
) -> None:
    from jrbar import settings as settings_module

    target = tmp_path / "settings.json"
    save_settings(AgentMonitorSettings(), target)
    loaded = load_settings_document(target)
    target.write_text("{ not json", encoding="utf-8")

    result = settings_module.load_settings_document(target, track=False)

    assert result.settings == AgentMonitorSettings()
    assert not target.exists() and len(_kept_copies(target)) == 1
    assert target.absolute() in settings_module._COMPATIBILITY_BY_PATH
    assert loaded is not None


def _default_path_loaded_then_edited_outside():
    """The conftest default path is the daemon's tracked path."""
    from jrbar.settings import default_settings_path

    target = default_settings_path()
    loaded, external = _loaded_then_edited_outside(target)
    return target, loaded, external


def _read_statusline_source() -> object:
    from jrbar import claude_statusline_source as source

    source._settings_cache = None
    return source.source_enabled(now=1.0e9)


def _read_pricing_overrides() -> object:
    from jrbar.model_pricing import OVERRIDES

    OVERRIDES.pin(None)
    return OVERRIDES.rows()


def _read_extra_homes() -> object:
    from jrbar.provider_homes import configured_extra_homes

    return configured_extra_homes()


def _read_hub_settings() -> object:
    from jrbar.cliproxy_hub import HubSource

    return HubSource(key_reader=lambda: None)._settings()


def _read_default_sources() -> object:
    from jrbar._collector_legacy import default_sources

    return default_sources()


def _read_alcove_following() -> object:
    from jrbar.doctor import _alcove_following_enabled

    return _alcove_following_enabled()


@pytest.mark.parametrize(
    "reader",
    (
        _read_statusline_source,
        _read_pricing_overrides,
        _read_extra_homes,
        _read_hub_settings,
        _read_default_sources,
        _read_alcove_following,
    ),
    ids=lambda reader: reader.__name__.removeprefix("_read_"),
)
def test_the_daemons_incidental_readers_do_not_rebaseline(reader) -> None:
    target, loaded, external = _default_path_loaded_then_edited_outside()

    reader()

    with pytest.raises(SettingsConcurrentWriteError):
        save_settings(loaded.settings.with_tips_enabled(False))
    assert json.loads(target.read_text(encoding="utf-8")) == external


# --- adopting a valid outside edit ---------------------------------------------


def _mode(path: Path) -> int:
    return path.lstat().st_mode & 0o777


def _edit_outside(target: Path, **changes) -> dict:
    document = json.loads(target.read_text(encoding="utf-8"))
    document.update(changes)
    target.write_text(json.dumps(document), encoding="utf-8")
    return document


def test_a_valid_outside_edit_is_adopted_and_the_replaced_memory_is_kept(tmp_path: Path) -> None:
    from jrbar.settings import OutsideEditOutcome, adopt_outside_edit, load_settings

    target = tmp_path / "settings.json"
    save_settings(AgentMonitorSettings(), target)
    load_settings_document(target)
    memory = replace(AgentMonitorSettings(), alert_burst=6, tips_enabled=False)
    edited = _edit_outside(target, alert_burst=9, external_owner={"keep": True})

    adoption = adopt_outside_edit(memory, target)

    assert adoption.outcome is OutsideEditOutcome.ADOPTED
    assert adoption.settings.alert_burst == 9 and adoption.settings.tips_enabled is True
    assert json.loads(target.read_text(encoding="utf-8")) == edited, "the file is untouched"
    backup = target.with_name("settings.json.replaced")
    assert adoption.backup == backup and not adoption.backup_failed
    assert _mode(backup) == 0o600
    assert load_settings(backup, track=False) == memory, "the backup loads as the memory it kept"
    # The adopted file is the new baseline: the next save is allowed, and keeps what the edit added.
    save_settings(adoption.settings.with_tips_enabled(False), target)
    after = json.loads(target.read_text(encoding="utf-8"))
    assert after["alert_burst"] == 9 and after["tips_enabled"] is False
    assert after["external_owner"] == {"keep": True}


def test_after_an_adoption_a_later_outside_edit_is_still_caught(tmp_path: Path) -> None:
    from jrbar.settings import adopt_outside_edit

    target = tmp_path / "settings.json"
    save_settings(AgentMonitorSettings(), target)
    load_settings_document(target)
    _edit_outside(target, alert_burst=9)
    adoption = adopt_outside_edit(AgentMonitorSettings(), target)

    later = _edit_outside(target, alert_burst=3)

    with pytest.raises(SettingsConcurrentWriteError):
        save_settings(adoption.settings, target)
    assert json.loads(target.read_text(encoding="utf-8")) == later


def test_an_outside_edit_that_changes_nothing_we_hold_is_not_a_replacement(tmp_path: Path) -> None:
    from jrbar.settings import OutsideEditOutcome, adopt_outside_edit

    target = tmp_path / "settings.json"
    save_settings(AgentMonitorSettings(), target)
    load_settings_document(target)
    _edit_outside(target, external_owner="only an unknown field")

    adoption = adopt_outside_edit(AgentMonitorSettings(), target)

    assert adoption.outcome is OutsideEditOutcome.UNCHANGED
    assert not target.with_name("settings.json.replaced").exists()
    save_settings(AgentMonitorSettings().with_tips_enabled(False), target)
    assert json.loads(target.read_text(encoding="utf-8"))["external_owner"] == "only an unknown field"


@pytest.mark.parametrize(
    "ruined",
    (
        "{ not json",
        "[1, 2]",
        '{"settings_schema_version": "two"}',
        '{"alert_burst": NaN}',
    ),
    ids=("garbage", "not an object", "bad schema version", "non-finite number"),
)
def test_an_invalid_outside_edit_is_never_adopted_and_memory_survives(
    tmp_path: Path, ruined: str
) -> None:
    from jrbar.settings import OutsideEditOutcome, adopt_outside_edit

    target = tmp_path / "settings.json"
    save_settings(AgentMonitorSettings(), target)
    load_settings_document(target)
    memory = replace(AgentMonitorSettings(), alert_burst=6)
    target.write_text(ruined, encoding="utf-8")

    first = adopt_outside_edit(memory, target)
    assert first.outcome is OutsideEditOutcome.UNSETTLED and target.exists()
    adoption = adopt_outside_edit(memory, target, unsettled=first.signature)

    assert adoption.outcome is OutsideEditOutcome.INVALID
    assert adoption.settings is memory
    assert not target.exists(), "set aside the way the loader sets one aside"
    (kept,) = _kept_copies(target)
    assert kept.read_text(encoding="utf-8") == ruined
    assert not target.with_name("settings.json.replaced").exists()
    # With the file gone, memory can be written out again.
    save_settings(memory, target)
    assert json.loads(target.read_text(encoding="utf-8"))["alert_burst"] == 6


def test_a_deleted_settings_file_keeps_memory_and_can_be_written_again(tmp_path: Path) -> None:
    from jrbar.settings import OutsideEditOutcome, adopt_outside_edit

    target = tmp_path / "settings.json"
    save_settings(AgentMonitorSettings(), target)
    load_settings_document(target)
    target.unlink()
    memory = replace(AgentMonitorSettings(), alert_burst=6)

    adoption = adopt_outside_edit(memory, target)

    assert adoption.outcome is OutsideEditOutcome.MISSING and adoption.settings is memory
    save_settings(memory, target)
    assert json.loads(target.read_text(encoding="utf-8"))["alert_burst"] == 6


def test_a_newer_schema_outside_edit_is_adopted_for_reading_and_still_refuses_saves(
    tmp_path: Path,
) -> None:
    from jrbar.settings import (
        OutsideEditOutcome,
        SettingsWriteRefusedError,
        adopt_outside_edit,
    )

    target = tmp_path / "settings.json"
    save_settings(AgentMonitorSettings(), target)
    load_settings_document(target)
    _edit_outside(target, settings_schema_version=99, alert_burst=9)

    adoption = adopt_outside_edit(AgentMonitorSettings(), target)

    assert adoption.outcome is OutsideEditOutcome.ADOPTED and adoption.settings.alert_burst == 9
    with pytest.raises(SettingsWriteRefusedError):
        save_settings(adoption.settings, target)


def test_a_read_that_may_pass_raises_and_changes_nothing(
    tmp_path: Path, monkeypatch: pytest.MonkeyPatch
) -> None:
    from jrbar import settings as settings_module

    target = tmp_path / "settings.json"
    loaded, external = _loaded_then_edited_outside(target)

    def transient(_target):
        raise OSError("temporarily unavailable")

    monkeypatch.setattr(settings_module, "_read_document", transient)
    with pytest.raises(OSError, match="temporarily"):
        settings_module.adopt_outside_edit(loaded.settings, target)
    monkeypatch.undo()

    with pytest.raises(SettingsConcurrentWriteError):
        save_settings(loaded.settings, target)


def test_a_backup_that_cannot_be_written_does_not_stop_the_adoption(tmp_path: Path) -> None:
    from jrbar.settings import OutsideEditOutcome, adopt_outside_edit

    target = tmp_path / "settings.json"
    save_settings(AgentMonitorSettings(), target)
    load_settings_document(target)
    target.with_name("settings.json.replaced").mkdir()
    _edit_outside(target, alert_burst=9)

    adoption = adopt_outside_edit(replace(AgentMonitorSettings(), alert_burst=6), target)

    assert adoption.outcome is OutsideEditOutcome.ADOPTED
    assert adoption.settings.alert_burst == 9
    assert adoption.backup is None and adoption.backup_failed


def test_a_lost_save_tells_the_registered_observer_once(tmp_path: Path) -> None:
    from jrbar import settings as settings_module

    target = tmp_path / "settings.json"
    loaded, _external = _loaded_then_edited_outside(target)
    heard: list[tuple[Path, Exception]] = []
    settings_module.set_write_conflict_observer(lambda path, error: heard.append((path, error)))
    try:
        with pytest.raises(SettingsConcurrentWriteError):
            save_settings(loaded.settings, target)
        assert len(heard) == 1 and heard[0][0] == target.absolute()
        assert isinstance(heard[0][1], SettingsConcurrentWriteError)

        def broken(_path, _error):
            raise RuntimeError("an observer must not break a save")

        settings_module.set_write_conflict_observer(broken)
        with pytest.raises(SettingsConcurrentWriteError):
            save_settings(loaded.settings, target)
        # A save that is not in conflict never tells anyone.
        settings_module.set_write_conflict_observer(lambda *_: heard.append("unexpected"))
        load_settings_document(target)
        save_settings(loaded.settings, target)
        assert "unexpected" not in heard
    finally:
        settings_module.set_write_conflict_observer(None)


# --- a typo'd edit is never destroyed, and an editor's half-written save is waited for ---


def _signature_reader(*signatures):
    """A stat reader that reports one signature per look, so a test needs no sleeps."""
    looks = iter(signatures)

    def read(_target: Path):
        return next(looks)

    return read


def test_two_invalid_edits_in_a_row_both_survive_as_timestamped_copies(tmp_path: Path) -> None:
    """The first ``.corrupt`` used to be kept and the next invalid file was
    unlinked, leaving no settings.json and one stale copy."""
    from jrbar.settings import adopt_outside_edit

    target = tmp_path / "settings.json"
    save_settings(AgentMonitorSettings(), target)
    load_settings_document(target)
    memory = AgentMonitorSettings()
    stat_same = lambda _target: (1, 1)  # noqa: E731 - the same look twice: settled

    for text in ('{"typo": ', "[1, 2"):
        target.write_text(text, encoding="utf-8")
        adoption = adopt_outside_edit(memory, target, unsettled=(1, 1), signature_of=stat_same)
        assert adoption.outcome.value == "invalid"
        assert not target.exists()
        # A save writes memory out again; the next outside edit starts over.
        save_settings(memory, target)
        load_settings_document(target)

    assert sorted(path.read_text(encoding="utf-8") for path in _kept_copies(target)) == [
        "[1, 2",
        '{"typo": ',
    ]
    assert all((path.lstat().st_mode & 0o777) == 0o600 for path in _kept_copies(target))


def test_the_loader_keeps_every_corrupt_file_not_just_the_first(tmp_path: Path) -> None:
    target = tmp_path / "settings.json"
    for text in ("{broken", "[]", "also broken"):
        target.write_text(text, encoding="utf-8")
        load_settings_document(target)
        assert not target.exists()

    assert sorted(path.read_text(encoding="utf-8") for path in _kept_copies(target)) == [
        "[]",
        "also broken",
        "{broken",
    ]
    for index in range(4):
        target.write_text(f"newer {index}", encoding="utf-8")
        load_settings_document(target)
    assert len(_kept_copies(target)) == 3, "only the newest three are kept"
    assert sorted(path.read_text(encoding="utf-8") for path in _kept_copies(target)) == [
        "newer 1",
        "newer 2",
        "newer 3",
    ]


def test_an_unparsable_file_is_looked_at_twice_before_it_is_set_aside(tmp_path: Path) -> None:
    from jrbar.settings import OutsideEditOutcome, adopt_outside_edit

    target = tmp_path / "settings.json"
    save_settings(AgentMonitorSettings(), target)
    load_settings_document(target)
    memory = replace(AgentMonitorSettings(), alert_burst=6)
    target.write_text('{"alert_burst": 9, "tips_', encoding="utf-8")  # an editor mid-save

    first = adopt_outside_edit(memory, target, signature_of=_signature_reader((20, 111)))

    assert first.outcome is OutsideEditOutcome.UNSETTLED
    assert first.signature == (20, 111) and first.settings is memory
    assert target.exists() and _kept_copies(target) == [], "the first look moves nothing"

    # Still changing under us: wait again.
    again = adopt_outside_edit(
        memory, target, unsettled=first.signature, signature_of=_signature_reader((27, 222))
    )
    assert again.outcome is OutsideEditOutcome.UNSETTLED and again.signature == (27, 222)
    assert target.exists() and _kept_copies(target) == []

    # The editor finished and the file is whole: it is adopted, never set aside.
    target.write_text('{"alert_burst": 9}', encoding="utf-8")
    done = adopt_outside_edit(
        memory, target, unsettled=again.signature, signature_of=_signature_reader((18, 333))
    )
    assert done.outcome is OutsideEditOutcome.ADOPTED and done.settings.alert_burst == 9
    assert _kept_copies(target) == []


def test_an_unparsable_file_that_has_stopped_changing_is_set_aside(tmp_path: Path) -> None:
    from jrbar.settings import OutsideEditOutcome, adopt_outside_edit

    target = tmp_path / "settings.json"
    save_settings(AgentMonitorSettings(), target)
    load_settings_document(target)
    target.write_text("{ truly broken", encoding="utf-8")

    adoption = adopt_outside_edit(
        AgentMonitorSettings(),
        target,
        unsettled=(14, 5),
        signature_of=_signature_reader((14, 5)),
    )

    assert adoption.outcome is OutsideEditOutcome.INVALID
    (kept,) = _kept_copies(target)
    assert kept.read_text(encoding="utf-8") == "{ truly broken"


def test_a_file_that_vanishes_between_the_looks_is_a_missing_file(tmp_path: Path) -> None:
    from jrbar.settings import OutsideEditOutcome, adopt_outside_edit

    target = tmp_path / "settings.json"
    save_settings(AgentMonitorSettings(), target)
    load_settings_document(target)
    target.write_text("{", encoding="utf-8")

    adoption = adopt_outside_edit(
        AgentMonitorSettings(), target, signature_of=_signature_reader(None)
    )

    assert adoption.outcome is OutsideEditOutcome.MISSING


def test_after_an_invalid_file_is_set_aside_a_new_file_is_still_caught_by_the_guard(
    tmp_path: Path,
) -> None:
    """The baseline becomes "no file", not "forgotten": a valid file an editor
    then writes is an outside edit to adopt, not something a save overwrites."""
    from jrbar.settings import adopt_outside_edit

    target = tmp_path / "settings.json"
    save_settings(AgentMonitorSettings(), target)
    load_settings_document(target)
    memory = replace(AgentMonitorSettings(), alert_burst=6)
    target.write_text("{", encoding="utf-8")
    adopt_outside_edit(memory, target, unsettled=(1, 1), signature_of=lambda _t: (1, 1))
    target.write_text(json.dumps({"alert_burst": 9}), encoding="utf-8")

    with pytest.raises(SettingsConcurrentWriteError):
        save_settings(memory, target)
    assert json.loads(target.read_text(encoding="utf-8")) == {"alert_burst": 9}


def test_saving_over_a_file_that_cannot_be_read_is_a_retryable_refusal(tmp_path: Path) -> None:
    from jrbar import settings as settings_module
    from jrbar.settings import SettingsFileUnreadableError, SettingsWriteRefusedError

    target = tmp_path / "settings.json"
    target.write_text('{"half": ', encoding="utf-8")

    with pytest.raises(SettingsFileUnreadableError) as caught:
        save_settings(AgentMonitorSettings(), target)

    assert isinstance(caught.value, SettingsWriteRefusedError)
    assert target.read_text(encoding="utf-8") == '{"half": '
    assert not issubclass(settings_module.SettingsConcurrentWriteError, SettingsFileUnreadableError)
