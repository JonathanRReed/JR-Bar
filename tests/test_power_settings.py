from __future__ import annotations

import json
from dataclasses import replace
from pathlib import Path

from jrbar.settings import AgentMonitorSettings, load_settings, save_settings


def test_power_hold_defaults_keep_the_computer_awake_not_the_display__and_1_more() -> None:
    # --- scenario: power_hold_defaults_keep_the_computer_awake_not_the_display
    # A hold keeps the Mac running; the display may sleep (and, with the
    # lid shut, goes dark) unless the person turns the display hold on.
    settings = AgentMonitorSettings()

    assert settings.agent_keep_awake_enabled is True
    assert settings.keep_display_awake is False
    assert settings.keep_awake_on_battery is True
    assert settings.closed_lid_awake_policy == "never"

    # --- scenario: agent_and_display_choices_are_immutable_and_independent
    defaults = AgentMonitorSettings()
    no_agent_hold = replace(defaults, agent_keep_awake_enabled=False)
    display_hold = replace(no_agent_hold, keep_display_awake=True)

    assert defaults.agent_keep_awake_enabled is True
    assert defaults.keep_display_awake is False
    assert no_agent_hold.agent_keep_awake_enabled is False
    assert no_agent_hold.keep_display_awake is False
    assert display_hold.agent_keep_awake_enabled is False
    assert display_hold.keep_display_awake is True
    assert display_hold.keep_awake_on_battery is True
    assert display_hold.closed_lid_awake_policy == "never"



def test_agent_and_display_choices_round_trip_independently__and_2_more(tmp_path: Path) -> None:
    # --- scenario: agent_and_display_choices_round_trip_independently
    target = tmp_path / "settings.json"
    expected = replace(
        AgentMonitorSettings(),
        agent_keep_awake_enabled=False,
        keep_display_awake=True,
    )

    save_settings(expected, target)
    reloaded = load_settings(target)

    assert reloaded.agent_keep_awake_enabled is False
    assert reloaded.keep_display_awake is True
    document = json.loads(target.read_text())
    assert document["agent_keep_awake_enabled"] is False
    assert document["keep_display_awake"] is True

    # --- scenario: absent_power_choice_keys_use_safe_defaults
    target = tmp_path / "settings.json"
    save_settings(
        replace(
            AgentMonitorSettings(),
            agent_keep_awake_enabled=False,
            keep_display_awake=True,
        ),
        target,
    )
    document = json.loads(target.read_text())
    document.pop("agent_keep_awake_enabled")
    document.pop("keep_display_awake")
    target.write_text(json.dumps(document))

    reloaded = load_settings(target)

    assert reloaded.agent_keep_awake_enabled is True
    assert reloaded.keep_display_awake is False

    # --- scenario: ambiguous_power_choice_values_use_safe_defaults
    target = tmp_path / "settings.json"
    save_settings(AgentMonitorSettings(), target)
    document = json.loads(target.read_text())
    document["agent_keep_awake_enabled"] = 1
    document["keep_display_awake"] = "true"
    target.write_text(json.dumps(document))

    reloaded = load_settings(target)

    assert reloaded.agent_keep_awake_enabled is True
    assert reloaded.keep_display_awake is False  # the default, not the garbage



def test_unrelated_save_retains_power_choices_and_readable_extension(
    tmp_path: Path,
) -> None:
    target = tmp_path / "settings.json"
    save_settings(
        replace(
            AgentMonitorSettings(),
            agent_keep_awake_enabled=False,
            keep_display_awake=True,
        ),
        target,
    )
    document = json.loads(target.read_text())
    document["future_power_extension"] = {"preserve": True}
    target.write_text(json.dumps(document))

    reloaded = load_settings(target).with_tips_enabled(False)
    save_settings(reloaded, target)
    final = json.loads(target.read_text())

    assert final["agent_keep_awake_enabled"] is False
    assert final["keep_display_awake"] is True
    assert final["future_power_extension"] == {"preserve": True}


def test_display_hold_is_turned_off_once_for_a_file_from_before_the_new_default(
    tmp_path: Path,
) -> None:
    # A 0.10.0 file holds the old default, on, and no stamp: it reads as
    # off, and the next save stamps it.
    target = tmp_path / "settings.json"
    save_settings(AgentMonitorSettings(), target)
    document = json.loads(target.read_text())
    document.pop("keep_display_awake_default_version")
    document["keep_display_awake"] = True
    target.write_text(json.dumps(document))

    migrated = load_settings(target)
    assert migrated.keep_display_awake is False
    save_settings(migrated, target)
    saved = json.loads(target.read_text())
    assert saved["keep_display_awake"] is False
    assert saved["keep_display_awake_default_version"] == 1


def test_the_display_migration_never_runs_again(tmp_path: Path) -> None:
    # After the stamp, turning the display hold on is the person's choice
    # and survives every later load and save.
    target = tmp_path / "settings.json"
    document = json.loads(json.dumps(AgentMonitorSettings().to_dict()))
    document.pop("keep_display_awake_default_version")
    document["keep_display_awake"] = True
    target.write_text(json.dumps(document))

    first = load_settings(target)
    assert first.keep_display_awake is False
    chosen = replace(first, keep_display_awake=True)
    save_settings(chosen, target)
    for _ in range(3):
        again = load_settings(target)
        assert again.keep_display_awake is True
        save_settings(again, target)
    assert json.loads(target.read_text())["keep_display_awake_default_version"] == 1


def test_a_newer_stamp_is_honoured_as_already_migrated(tmp_path: Path) -> None:
    target = tmp_path / "settings.json"
    document = json.loads(json.dumps(AgentMonitorSettings().to_dict()))
    document["keep_display_awake_default_version"] = 7
    document["keep_display_awake"] = True
    target.write_text(json.dumps(document))
    assert load_settings(target).keep_display_awake is True


def test_a_malformed_stamp_reads_as_unmigrated(tmp_path: Path) -> None:
    target = tmp_path / "settings.json"
    document = json.loads(json.dumps(AgentMonitorSettings().to_dict()))
    document["keep_display_awake_default_version"] = "1"
    document["keep_display_awake"] = True
    target.write_text(json.dumps(document))
    assert load_settings(target).keep_display_awake is False
