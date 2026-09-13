from __future__ import annotations

from dataclasses import FrozenInstanceError

import pytest

from jrbar.global_actions import (
    GlobalActionBindingState,
    GlobalActionID,
    ShortcutChord,
    ShortcutModifier,
    ShortcutValidationCode,
    ShortcutValidationError,
    format_shortcut,
    parse_global_action_shortcuts,
    project_global_action_status,
    serialize_global_action_shortcuts,
    validate_global_action_bindings,
    validate_shortcut,
)


def chord(
    key_code: int = 40,
    key_label: str = "K",
    *modifiers: ShortcutModifier,
) -> ShortcutChord:
    return ShortcutChord(
        key_code=key_code,
        key_label=key_label,
        modifiers=frozenset(modifiers or (ShortcutModifier.COMMAND,)),
    )


def test_action_and_modifier_identifiers_are_exact__and_2_more() -> None:
    # --- scenario: action_and_modifier_identifiers_are_exact
    assert tuple(action.value for action in GlobalActionID) == ("reveal_current_ask",)
    assert tuple(modifier.value for modifier in ShortcutModifier) == (
        "control",
        "option",
        "shift",
        "command",
    )

    # --- scenario: chord_refuses_out_of_range_or_non_integer_key_codes
    for key_code in [-1, 128, True, 1.5]:
        with pytest.raises(ValueError, match="key code"):
            chord(key_code=key_code)  # type: ignore[arg-type]

    # --- scenario: chord_refuses_empty_long_non_printable_or_non_string_labels
    for key_label in ["", "x" * 17, "line\nbreak", 42]:
        with pytest.raises(ValueError, match="key label"):
            chord(key_label=key_label)  # type: ignore[arg-type]



def test_chord_is_immutable_and_requires_exact_modifier_values__and_2_more() -> None:
    # --- scenario: chord_is_immutable_and_requires_exact_modifier_values
    value = chord()

    with pytest.raises(FrozenInstanceError):
        value.key_code = 1  # type: ignore[misc]
    with pytest.raises(ValueError, match="modifiers"):
        ShortcutChord(40, "K", frozenset({"command"}))  # type: ignore[arg-type]

    # --- scenario: shortcut_requires_a_modifier_and_command_or_control
    for modifiers, code in [
        (frozenset(), ShortcutValidationCode.NO_MODIFIERS),
        (
            frozenset({ShortcutModifier.OPTION, ShortcutModifier.SHIFT}),
            ShortcutValidationCode.OPTION_SHIFT_ONLY,
        ),
        (
            frozenset({ShortcutModifier.SHIFT}),
            ShortcutValidationCode.COMMAND_OR_CONTROL_REQUIRED,
        ),
        (
            frozenset({ShortcutModifier.OPTION}),
            ShortcutValidationCode.COMMAND_OR_CONTROL_REQUIRED,
        ),
    ]:
        with pytest.raises(ShortcutValidationError) as raised:
            validate_shortcut(ShortcutChord(40, "K", modifiers))

        assert raised.value.code is code

    # --- scenario: reserved_jr_bar_menu_equivalents_are_refused
    for key_code, key_label, modifiers in [
        (12, "Q", (ShortcutModifier.COMMAND,)),
        (13, "W", (ShortcutModifier.COMMAND,)),
        (43, ",", (ShortcutModifier.COMMAND,)),
        (7, "X", (ShortcutModifier.COMMAND,)),
        (8, "C", (ShortcutModifier.COMMAND,)),
        (9, "V", (ShortcutModifier.COMMAND,)),
        (0, "A", (ShortcutModifier.COMMAND,)),
        (6, "Z", (ShortcutModifier.COMMAND,)),
        (6, "Z", (ShortcutModifier.COMMAND, ShortcutModifier.SHIFT)),
    ]:
        with pytest.raises(ShortcutValidationError) as raised:
            validate_shortcut(chord(key_code, key_label, *modifiers))

        assert raised.value.code is ShortcutValidationCode.RESERVED_MENU_EQUIVALENT



def test_binding_validation_detects_duplicate_normalized_chords__and_2_more() -> None:
    # --- scenario: binding_validation_detects_duplicate_normalized_chords
    reveal = chord(40, "K", ShortcutModifier.CONTROL, ShortcutModifier.SHIFT)
    future_action = "future_action"
    duplicate_with_different_label = chord(
        40,
        "K2",
        ShortcutModifier.SHIFT,
        ShortcutModifier.CONTROL,
    )

    with pytest.raises(ShortcutValidationError) as raised:
        validate_global_action_bindings(
            {
                GlobalActionID.REVEAL_CURRENT_ASK: reveal,
                future_action: duplicate_with_different_label,
            }
        )

    assert raised.value.code is ShortcutValidationCode.DUPLICATE_BINDING
    assert raised.value.conflicting_action == GlobalActionID.REVEAL_CURRENT_ASK.value

    # --- scenario: modifier_symbol_formatting_is_deterministic
    value = chord(
        40,
        "K",
        ShortcutModifier.COMMAND,
        ShortcutModifier.SHIFT,
        ShortcutModifier.CONTROL,
        ShortcutModifier.OPTION,
    )

    assert format_shortcut(value) == "⌃⌥⇧⌘K"

    # --- scenario: known_binding_parses_and_serializes_only_known_fields
    raw = {
        "reveal_current_ask": {
            "key_code": 40,
            "key_label": "K",
            "modifiers": ["shift", "control"],
        }
    }

    parsed = parse_global_action_shortcuts(raw)

    assert parsed.refusals == ()
    assert parsed.binding_for(GlobalActionID.REVEAL_CURRENT_ASK) == chord(
        40,
        "K",
        ShortcutModifier.CONTROL,
        ShortcutModifier.SHIFT,
    )
    assert serialize_global_action_shortcuts(parsed.bindings) == {
        "reveal_current_ask": {
            "key_code": 40,
            "key_label": "K",
            "modifiers": ["control", "shift"],
        }
    }



def test_unknown_or_malformed_persisted_entry_is_refused_individually__and_2_more() -> None:
    # --- scenario: unknown_or_malformed_persisted_entry_is_refused_individually
    for raw, refused_key, code in [
        (
            {
                "unknown_action": {
                    "key_code": 40,
                    "key_label": "K",
                    "modifiers": ["command"],
                }
            },
            "unknown_action",
            ShortcutValidationCode.UNKNOWN_ACTION,
        ),
        (
            {
                "reveal_current_ask": {
                    "key_code": 40,
                    "key_label": "K",
                    "modifiers": ["command"],
                    "future_field": True,
                }
            },
            "reveal_current_ask",
            ShortcutValidationCode.MALFORMED,
        ),
        (
            {
                "reveal_current_ask": {
                    "key_code": 40,
                    "key_label": "K",
                    "modifiers": [{"not": "a modifier"}],
                }
            },
            "reveal_current_ask",
            ShortcutValidationCode.MALFORMED,
        ),
        (
            {
                "reveal_current_ask": {
                    "key_code": 40,
                    "key_label": "K",
                    "modifiers": ["hyper"],
                }
            },
            "reveal_current_ask",
            ShortcutValidationCode.MALFORMED,
        ),
        (
            {
                "reveal_current_ask": {
                    "key_code": 40,
                    "key_label": "K",
                    "modifiers": ["option", "shift"],
                }
            },
            "reveal_current_ask",
            ShortcutValidationCode.OPTION_SHIFT_ONLY,
        ),
    ]:
        parsed = parse_global_action_shortcuts(raw)

        assert parsed.bindings == ()
        assert parsed.refusals[0].action_key == refused_key
        assert parsed.refusals[0].code is code

    # --- scenario: one_bad_persisted_entry_does_not_discard_a_valid_known_binding
    parsed = parse_global_action_shortcuts(
        {
            "unknown_action": {"unexpected": True},
            "reveal_current_ask": {
                "key_code": 40,
                "key_label": "K",
                "modifiers": ["control"],
            },
        }
    )

    assert parsed.binding_for(GlobalActionID.REVEAL_CURRENT_ASK) == chord(
        40, "K", ShortcutModifier.CONTROL
    )
    assert tuple(refusal.action_key for refusal in parsed.refusals) == (
        "unknown_action",
    )

    # --- scenario: binding_state_projection_is_bounded_and_truthful
    for state, value_text in [
        (GlobalActionBindingState.UNASSIGNED, "Not set"),
        (GlobalActionBindingState.ACTIVE, "⌃K"),
        (GlobalActionBindingState.LOCAL_CONFLICT, "Already used by JR-Bar"),
        (GlobalActionBindingState.UNSUPPORTED, "Shortcut not supported"),
        (
            GlobalActionBindingState.REGISTRATION_REFUSED,
            "macOS refused shortcut",
        ),
        (GlobalActionBindingState.CLOSED, "Unavailable"),
    ]:
        projection = project_global_action_status(
            GlobalActionID.REVEAL_CURRENT_ASK,
            state,
            chord=chord(40, "K", ShortcutModifier.CONTROL)
            if state is GlobalActionBindingState.ACTIVE
            else None,
        )

        assert projection.state is state
        assert projection.value_text == value_text
        assert "current ask or Agent Browser" in projection.help_text
        assert len(projection.value_text) <= 64
        assert len(projection.help_text) <= 256



def test_active_projection_refuses_to_claim_success_without_a_chord() -> None:
    with pytest.raises(ValueError, match="active status requires"):
        project_global_action_status(
            GlobalActionID.REVEAL_CURRENT_ASK,
            GlobalActionBindingState.ACTIVE,
        )
