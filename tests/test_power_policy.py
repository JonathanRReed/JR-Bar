from __future__ import annotations

import pytest

from jrbar.power_policy import (
    PowerHoldChoices,
    configure_caffeinate_display_assertion,
)


def test_display_assertion_compiles_to_one_canonical_flag_bundle__and_2_more() -> None:
    # --- scenario: display_assertion_compiles_to_one_canonical_flag_bundle
    for command, keep_display_awake, expected in [
        (
            ("/usr/bin/caffeinate", "-ims"),
            False,
            ("/usr/bin/caffeinate", "-ims"),
        ),
        (
            ("/usr/bin/caffeinate", "-ims"),
            True,
            ("/usr/bin/caffeinate", "-dims"),
        ),
        (
            ("/usr/bin/caffeinate", "-dimsu", "-t", "1800"),
            False,
            ("/usr/bin/caffeinate", "-imsu", "-t", "1800"),
        ),
        (
            ("/usr/bin/caffeinate", "-imsu", "-t", "1800"),
            True,
            ("/usr/bin/caffeinate", "-dimsu", "-t", "1800"),
        ),
        (
            ("/usr/bin/caffeinate", "-i", "-m", "-s", "-w", "42"),
            True,
            ("/usr/bin/caffeinate", "-dims", "-w", "42"),
        ),
        (
            ("/usr/bin/caffeinate", "-d", "-i", "-s", "--", "task"),
            False,
            ("/usr/bin/caffeinate", "-is", "--", "task"),
        ),
        (
            ("/usr/bin/caffeinate", "-d", "--", "-i", "-m"),
            False,
            ("/usr/bin/caffeinate", "--", "-i", "-m"),
        ),
        (
            ("/usr/bin/caffeinate", "-t", "30"),
            True,
            ("/usr/bin/caffeinate", "-d", "-t", "30"),
        ),
    ]:
        original = tuple(command)

        assert (
            configure_caffeinate_display_assertion(
                command,
                keep_display_awake=keep_display_awake,
            )
            == expected
        )
        assert command == original

    # --- scenario: display_assertion_rejects_invalid_inputs
    for command, keep_display_awake in [
        ((), False),
        (("",), False),
        (("/usr/bin/caffeinate", 7), False),
        (("/usr/bin/caffeinate",), 1),
    ]:
        with pytest.raises(ValueError, match="invalid caffeinate"):
            configure_caffeinate_display_assertion(  # type: ignore[arg-type]
                command,
                keep_display_awake=keep_display_awake,
            )

    # --- scenario: power_hold_choices_keep_the_four_decisions_independent
    choices = PowerHoldChoices(
        agent_keep_awake_enabled=False,
        keep_display_awake=True,
        keep_awake_on_battery=False,
        closed_lid_awake_policy="always",
    )

    assert choices.agent_keep_awake_enabled is False
    assert choices.keep_display_awake is True
    assert choices.keep_awake_on_battery is False
    assert choices.closed_lid_awake_policy == "always"



def test_default_agent_and_closed_lid_commands_allow_display_sleep__and_1_more() -> None:
    # --- scenario: default_agent_and_closed_lid_commands_allow_display_sleep
    from jrbar.keep_awake import CAFFEINATE_COMMAND
    from jrbar.lid_sleep import CAFFEINATE_CLOSED_LID_COMMAND

    assert configure_caffeinate_display_assertion(
        CAFFEINATE_COMMAND,
        keep_display_awake=False,
    ) == tuple(CAFFEINATE_COMMAND)
    assert configure_caffeinate_display_assertion(
        CAFFEINATE_CLOSED_LID_COMMAND,
        keep_display_awake=False,
    ) == tuple(CAFFEINATE_CLOSED_LID_COMMAND)

    # --- scenario: power_hold_choices_reject_ambiguous_values
    for kwargs in [
        {"agent_keep_awake_enabled": 1},
        {"keep_display_awake": None},
        {"keep_awake_on_battery": "yes"},
        {"closed_lid_awake_policy": ""},
    ]:
        values: dict[str, object] = {
            "agent_keep_awake_enabled": True,
            "keep_display_awake": False,
            "keep_awake_on_battery": True,
            "closed_lid_awake_policy": "never",
        }
        values.update(kwargs)

        with pytest.raises(ValueError, match="invalid power hold choices"):
            PowerHoldChoices(**values)  # type: ignore[arg-type]

