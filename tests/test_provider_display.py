from __future__ import annotations

import pytest

from jrbar.core_auth import requires_app, setting_path_is_open
from jrbar.provider_display import provider_display
from jrbar.settings import AgentMonitorSettings, load_settings, save_settings, settings_from_mapping


def test_defaults_do_not_authorize_collection():
    settings = AgentMonitorSettings()
    assert settings.provider_display is None
    assert settings.provider_status_feeds_enabled is False
    assert settings.provider_update_checks_enabled is False
    assert not setting_path_is_open("provider_display")
    assert requires_app("set_setting", {"path": "provider_display"})


def test_order_and_hidden_survive_save_and_unrelated_change(tmp_path):
    display = {"order": ["codex", "claude", "future-provider"], "hidden": ["claude"]}
    settings = settings_from_mapping({"provider_display": display})
    target = tmp_path / "settings.json"
    save_settings(settings, target)
    restored = load_settings(target).with_tips_enabled(False)
    save_settings(restored, target)
    assert load_settings(target).provider_display == display
    assert load_settings(target).provider_status_feeds_enabled is False


@pytest.mark.parametrize("invalid", [
    {}, {"order": [], "hidden": [], "extra": True},
    {"order": ["claude", "claude"], "hidden": []},
    {"order": "claude", "hidden": []}, {"order": ["Claude"], "hidden": []},
    {"order": ["x" * 65], "hidden": []}, {"order": [None], "hidden": []},
    {"order": [f"p{i}" for i in range(129)], "hidden": []},
])
def test_rejects_invalid_display(invalid):
    with pytest.raises(ValueError):
        provider_display(invalid)
    assert settings_from_mapping({"provider_display": invalid}).provider_display is None
