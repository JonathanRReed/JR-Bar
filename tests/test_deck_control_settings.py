import json

import pytest

from jrbar.deck_actions import DeckAction
from jrbar.deck_control_settings import DeckControlSettings, load_deck_controls, save_deck_controls


def test_missing_settings_are_disabled_and_saved_bindings_roundtrip_privately(tmp_path):
    path = tmp_path / "private" / "deck-controls.json"
    assert load_deck_controls(path) == DeckControlSettings()
    settings = DeckControlSettings(enabled=True, bindings=((3, DeckAction("open_usage")),))
    save_deck_controls(settings, path, expected=DeckControlSettings())
    assert load_deck_controls(path).action_for(3) == DeckAction("open_usage")
    assert path.stat().st_mode & 0o777 == 0o600


def test_disabled_settings_do_not_resolve_any_action__and_1_more() -> None:
    # --- scenario: disabled_settings_do_not_resolve_any_action
    settings = DeckControlSettings(bindings=((3, DeckAction("open_usage")),))
    assert settings.action_for(3) is None

    # --- scenario: invalid_or_duplicate_bindings_are_rejected
    for bindings in [
    ((True, DeckAction("open_usage")),), ((24, DeckAction("open_usage")),),
    ((3, DeckAction("open_usage")), (3, DeckAction("open_agent_browser"))),
    ((3, "open_usage"),),
]:
        with pytest.raises(ValueError):
            DeckControlSettings(enabled=True, bindings=bindings)



def test_save_refuses_changed_settings_instead_of_losing_another_edit__and_1_more(tmp_path) -> None:
    # --- scenario: save_refuses_changed_settings_instead_of_losing_another_edit
    path = tmp_path / "private" / "deck-controls.json"
    initial = DeckControlSettings()
    first = DeckControlSettings(enabled=True)
    save_deck_controls(first, path, expected=initial)
    with pytest.raises(ValueError, match="changed"):
        save_deck_controls(initial, path, expected=initial)
    assert load_deck_controls(path) == first

    # --- scenario: malformed_or_future_configuration_is_never_enabled_or_overwritten
    for document in [
    {"version": 2, "enabled": True, "bindings": []},
    {"version": 1, "enabled": "yes", "bindings": []},
    {"version": 1, "enabled": True, "bindings": [], "script": "unsafe"},
]:
        from jrbar.private_io import atomic_private_write

        path = tmp_path / "private" / "deck-controls.json"
        atomic_private_write(path, json.dumps(document))
        with pytest.raises(ValueError):
            load_deck_controls(path)
        with pytest.raises(ValueError):
            save_deck_controls(DeckControlSettings(), path, expected=DeckControlSettings())
        assert json.loads(path.read_text()) == document

