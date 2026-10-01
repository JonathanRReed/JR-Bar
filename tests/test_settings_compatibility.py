import json
import subprocess
import sys
from dataclasses import replace
from pathlib import Path

import pytest

from jrbar.settings import (
    CURRENT_SETTINGS_SCHEMA_VERSION,
    AgentMonitorSettings,
    SettingsConcurrentWriteError,
    SettingsWriteRefusedError,
    load_settings,
    load_settings_document,
    save_settings,
)

_DND_FIELDS = {
    "dnd_schedule_enabled": True,
    "dnd_schedule_start_minutes": 21 * 60 + 30,
    "dnd_schedule_end_minutes": 6 * 60 + 15,
    "dnd_schedule_mode": "dim",
    "dnd_dim_fraction": 0.25,
    "dnd_override_mode": "asks_only",
    "dnd_override_created_epoch": 1_800_000_000.0,
    "dnd_override_until_epoch": 1_800_003_600.0,
    "dnd_focus_mode": "pause",
}

_GLOBAL_ACTION_SHORTCUT = {
    "reveal_current_ask": {
        "key_code": 40,
        "key_label": "K",
        "modifiers": ["control", "shift"],
    }
}


def test_new_settings_leave_global_actions_unassigned__and_1_more(tmp_path: Path) -> None:
    # --- scenario: new_settings_leave_global_actions_unassigned
    settings = load_settings(tmp_path / "missing-settings.json")

    assert settings.global_action_shortcuts == {}

    # --- scenario: new_settings_leave_dnd_inactive_with_exact_defaults
    settings = load_settings(tmp_path / "missing-settings.json")

    assert settings.dnd_schedule_enabled is False
    assert settings.dnd_schedule_start_minutes == 1320
    assert settings.dnd_schedule_end_minutes == 420
    assert settings.dnd_schedule_mode == "dark"
    assert settings.dnd_dim_fraction == 0.15
    assert settings.dnd_override_mode is None
    assert settings.dnd_override_created_epoch is None
    assert settings.dnd_override_until_epoch is None
    assert settings.dnd_focus_mode == "pause"
    assert settings.dnd_persisted_refusals == ()
    assert settings.focus_sync_enabled is False



def test_dnd_scalars_round_trip_losslessly_and_preserve_unknown_fields(
    tmp_path: Path,
) -> None:
    target = tmp_path / "settings.json"
    target.write_text(
        json.dumps(
            {
                "settings_schema_version": CURRENT_SETTINGS_SCHEMA_VERSION,
                **_DND_FIELDS,
                "future_top_level": {"preserve": True},
            }
        ),
        encoding="utf-8",
    )

    loaded = load_settings_document(target)

    assert {
        key: getattr(loaded.settings, key)
        for key in _DND_FIELDS
    } == _DND_FIELDS
    assert loaded.settings.dnd_persisted_refusals == ()
    save_settings(loaded.settings, target, compatibility=loaded.compatibility)
    document = json.loads(target.read_text(encoding="utf-8"))
    assert {key: document[key] for key in _DND_FIELDS} == _DND_FIELDS
    assert document["future_top_level"] == {"preserve": True}


def test_malformed_dnd_scalar_is_individually_defaulted_and_reported(tmp_path: Path) -> None:
    for field, bad_value, expected in (
        ("dnd_schedule_enabled", 1, False),
        ("dnd_schedule_start_minutes", True, 1320),
        ("dnd_schedule_end_minutes", 1440, 420),
        ("dnd_schedule_mode", "future_mode", "dark"),
        ("dnd_dim_fraction", 0.0, 0.15),
        ("dnd_focus_mode", "resume", "pause"),
    ):
        target = tmp_path / "settings.json"
        document = {
            "settings_schema_version": CURRENT_SETTINGS_SCHEMA_VERSION,
            **_DND_FIELDS,
            "dnd_override_mode": None,
            "dnd_override_created_epoch": None,
            "dnd_override_until_epoch": None,
        }
        document[field] = bad_value
        target.write_text(json.dumps(document), encoding="utf-8")

        loaded = load_settings_document(target)

        assert getattr(loaded.settings, field) == expected
        assert tuple(item.field for item in loaded.settings.dnd_persisted_refusals) == (
            field,
        )
        for valid_field, valid_value in _DND_FIELDS.items():
            if valid_field not in {field, "dnd_override_mode", "dnd_override_created_epoch", "dnd_override_until_epoch"}:
                assert getattr(loaded.settings, valid_field) == valid_value


def test_malformed_dnd_override_is_ignored_as_one_typed_refusal(
    tmp_path: Path,
) -> None:
    target = tmp_path / "settings.json"
    target.write_text(
        json.dumps(
            {
                "settings_schema_version": CURRENT_SETTINGS_SCHEMA_VERSION,
                **_DND_FIELDS,
                "dnd_override_until_epoch": None,
                "future_top_level": "keep",
            }
        ),
        encoding="utf-8",
    )

    loaded = load_settings_document(target)

    assert loaded.settings.dnd_override_mode is None
    assert loaded.settings.dnd_override_created_epoch is None
    assert loaded.settings.dnd_override_until_epoch is None
    assert tuple(item.field for item in loaded.settings.dnd_persisted_refusals) == (
        "dnd_override",
    )
    assert loaded.settings.dnd_schedule_enabled is True
    assert loaded.settings.dnd_schedule_mode == "dim"


def test_dnd_save_rejects_invalid_programmatic_values(tmp_path: Path) -> None:
    target = tmp_path / "settings.json"
    loaded = load_settings_document(target)
    invalid = replace(loaded.settings, dnd_dim_fraction=float("nan"))

    with pytest.raises(ValueError, match="invalid DND settings"):
        save_settings(invalid, target, compatibility=loaded.compatibility)

    assert not target.exists()


def test_global_action_shortcuts_round_trip_without_losing_unknown_top_level_fields__and_2_more(tmp_path: Path,) -> None:
    # --- scenario: global_action_shortcuts_round_trip_without_losing_unknown_top_level_fields
    target = tmp_path / "settings.json"
    target.write_text(
        json.dumps(
            {
                "settings_schema_version": CURRENT_SETTINGS_SCHEMA_VERSION,
                "global_action_shortcuts": _GLOBAL_ACTION_SHORTCUT,
                "future_top_level": {"preserve": True},
            }
        ),
        encoding="utf-8",
    )

    loaded = load_settings_document(target)

    assert loaded.settings.global_action_shortcuts == _GLOBAL_ACTION_SHORTCUT
    save_settings(loaded.settings, target, compatibility=loaded.compatibility)
    document = json.loads(target.read_text(encoding="utf-8"))
    assert document["global_action_shortcuts"] == _GLOBAL_ACTION_SHORTCUT
    assert document["future_top_level"] == {"preserve": True}

    # --- scenario: global_action_shortcuts_are_owned_so_clear_does_not_resurrect_entries
    target = tmp_path / "settings.json"
    target.write_text(
        json.dumps(
            {
                "settings_schema_version": CURRENT_SETTINGS_SCHEMA_VERSION,
                "global_action_shortcuts": _GLOBAL_ACTION_SHORTCUT,
                "future_top_level": "keep",
            }
        ),
        encoding="utf-8",
    )
    loaded = load_settings_document(target)

    cleared = replace(loaded.settings, global_action_shortcuts={})
    save_settings(cleared, target, compatibility=loaded.compatibility)

    document = json.loads(target.read_text(encoding="utf-8"))
    assert document["global_action_shortcuts"] == {}
    assert document["future_top_level"] == "keep"

    # --- scenario: newer_settings_schema_is_read_only_and_never_overwritten
    target = tmp_path / "settings.json"
    original = {
        "settings_schema_version": 999,
        "future_feature": {"preserve": True},
        "tips_enabled": False,
        **_DND_FIELDS,
    }
    target.write_text(json.dumps(original), encoding="utf-8")

    loaded = load_settings_document(target)

    assert loaded.compatibility.read_only is True
    assert loaded.settings.tips_enabled is False
    assert loaded.settings.dnd_schedule_enabled is True
    assert loaded.settings.dnd_schedule_mode == "dim"
    assert loaded.settings.dnd_override_mode == "asks_only"
    with pytest.raises(SettingsWriteRefusedError):
        save_settings(loaded.settings, target, compatibility=loaded.compatibility)
    assert json.loads(target.read_text(encoding="utf-8")) == original



def test_legacy_convenience_loader_also_blocks_future_schema_writes__and_1_more(tmp_path: Path,) -> None:
    # --- scenario: legacy_convenience_loader_also_blocks_future_schema_writes
    target = tmp_path / "settings.json"
    original = {"settings_schema_version": 99, "future": "keep"}
    target.write_text(json.dumps(original), encoding="utf-8")

    settings = load_settings(target)

    with pytest.raises(SettingsWriteRefusedError):
        save_settings(settings.with_tips_enabled(False), target)
    assert json.loads(target.read_text(encoding="utf-8")) == original

    # --- scenario: schema_one_migrates_to_two_without_changing_user_values
    target = tmp_path / "settings.json"
    target.write_text(
        json.dumps(
            {
                "settings_schema_version": 1,
                "tips_enabled": False,
                "future_but_readable_extension": {"keep": True},
            }
        ),
        encoding="utf-8",
    )

    loaded = load_settings_document(target)
    assert loaded.compatibility.migrated is True
    assert loaded.settings.tips_enabled is False

    save_settings(loaded.settings, target, compatibility=loaded.compatibility)
    document = json.loads(target.read_text(encoding="utf-8"))
    assert document["settings_schema_version"] == CURRENT_SETTINGS_SCHEMA_VERSION
    assert document["tips_enabled"] is False
    assert document["future_but_readable_extension"] == {"keep": True}



def test_current_schema_round_trip_is_idempotent__and_1_more(tmp_path: Path) -> None:
    # --- scenario: current_schema_round_trip_is_idempotent
    target = tmp_path / "settings.json"
    first = load_settings(target)
    save_settings(first, target)
    before = target.read_text(encoding="utf-8")

    second = load_settings(target)
    save_settings(second, target)

    assert target.read_text(encoding="utf-8") == before

    # --- scenario: invalid_schema_version_preserves_corrupt_source
    target = tmp_path / "settings.json"
    target.write_text(
        json.dumps({"settings_schema_version": True, "sentinel": "keep"}),
        encoding="utf-8",
    )

    loaded = load_settings_document(target)

    assert loaded.settings.tips_enabled is True
    assert not target.exists()
    (corrupt,) = target.parent.glob("settings.json.corrupt-*")
    assert json.loads(corrupt.read_text(encoding="utf-8"))["sentinel"] == "keep"



@pytest.mark.parametrize(
    "text",
    (
        '{"screen_bar_gap_width": NaN, "sentinel": "keep"}',
        '{"sentinel": 1e999}',
        '{"sentinel": -Infinity}',
        '{"devices": [{"brightness": Infinity}], "sentinel": "keep"}',
    ),
)
def test_non_finite_number_quarantines_document(tmp_path: Path, text: str) -> None:
    target = tmp_path / "settings.json"
    target.write_text(text, encoding="utf-8")

    loaded = load_settings_document(target)

    assert loaded.settings == AgentMonitorSettings()
    assert loaded.compatibility.read_only is False
    assert not target.exists()
    (corrupt,) = target.parent.glob("settings.json.corrupt-*")
    assert corrupt.read_text(encoding="utf-8") == text

    save_settings(loaded.settings, target, compatibility=loaded.compatibility)

    assert target.exists()
    assert corrupt.read_text(encoding="utf-8") == text


def test_finite_exponent_numbers_still_load(tmp_path: Path) -> None:
    target = tmp_path / "settings.json"
    target.write_text(
        '{"settings_schema_version": 2, "sentinel": 1e5, "other": 2.5e-3}',
        encoding="utf-8",
    )

    loaded = load_settings_document(target)

    assert not list(target.parent.glob("settings.json.corrupt*"))
    save_settings(loaded.settings, target, compatibility=loaded.compatibility)
    document = json.loads(target.read_text(encoding="utf-8"))
    assert document["sentinel"] == 1e5
    assert document["other"] == 2.5e-3


@pytest.mark.parametrize("overwrite", ('{"x": NaN}', '{"x": '))
def test_tracked_save_refuses_when_document_becomes_unreadable(
    tmp_path: Path, overwrite: str
) -> None:
    target = tmp_path / "settings.json"
    save_settings(AgentMonitorSettings(), target)
    loaded = load_settings_document(target)
    target.write_text(overwrite, encoding="utf-8")

    with pytest.raises(SettingsConcurrentWriteError):
        save_settings(loaded.settings, target, compatibility=loaded.compatibility)

    assert target.read_text(encoding="utf-8") == overwrite


def test_untracked_save_refuses_unreadable_existing_file(tmp_path: Path) -> None:
    target = tmp_path / "settings.json"
    target.write_text('{"x": NaN}', encoding="utf-8")

    with pytest.raises(SettingsWriteRefusedError):
        save_settings(AgentMonitorSettings(), target)

    assert target.read_text(encoding="utf-8") == '{"x": NaN}'


def test_a_saved_bracket_style_survives_a_load_in_a_fresh_interpreter() -> None:
    # The Screen Bar draws the "bracket" style, and a settings file may carry
    # it. The choice belongs to the settings model itself: nothing installed
    # at boot widens it, so it is checked in an interpreter that imports only
    # the settings module.
    script = """
from jrbar.settings import AgentMonitorSettings, settings_from_mapping

for style in ("auto", "spatial", "identity", "bracket"):
    loaded = settings_from_mapping({"screen_bar_bracket_style": style})
    assert loaded.screen_bar_bracket_style == style, (style, loaded.screen_bar_bracket_style)
    chosen = AgentMonitorSettings().with_screen_bar_bracket_style(style)
    assert chosen.screen_bar_bracket_style == style
assert settings_from_mapping(
    {"screen_bar_bracket_style": "plaid"}
).screen_bar_bracket_style == "auto"
"""
    completed = subprocess.run(
        [sys.executable, "-c", script],
        capture_output=True,
        text=True,
        timeout=60,
        check=False,
    )

    assert completed.returncode == 0, completed.stderr
