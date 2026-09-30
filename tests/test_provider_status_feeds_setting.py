"""`provider_status_feeds_enabled`: off by default, and only a real true turns it on.

The daemon's own settings key for Settings > Usage > Provider status pages. The
behaviour it gates is in test_status_feeds_optin.py.
"""

from __future__ import annotations


def test_the_default_settings_leave_the_feeds_off() -> None:
    from jrbar.settings import AgentMonitorSettings

    assert AgentMonitorSettings().provider_status_feeds_enabled is False
    assert AgentMonitorSettings().to_dict()["provider_status_feeds_enabled"] is False
    on = AgentMonitorSettings().with_provider_status_feeds_enabled(True)
    assert on.provider_status_feeds_enabled is True
    assert on.to_dict()["provider_status_feeds_enabled"] is True


def test_the_setting_round_trips_and_a_mistyped_value_is_off(tmp_path) -> None:
    from jrbar.core_runtime import settings_from_document
    from jrbar.settings import AgentMonitorSettings, load_settings, save_settings

    target = tmp_path / "settings.json"
    save_settings(AgentMonitorSettings().with_provider_status_feeds_enabled(True), target)
    assert load_settings(target).provider_status_feeds_enabled is True

    document = AgentMonitorSettings().to_dict()
    for mistyped in ("yes", 1, None, [True]):
        loaded = settings_from_document(
            {**document, "provider_status_feeds_enabled": mistyped}, scratch_dir=tmp_path
        )
        assert loaded.provider_status_feeds_enabled is False
    # A settings file from before the key existed has the feeds off too.
    document.pop("provider_status_feeds_enabled")
    assert settings_from_document(document, scratch_dir=tmp_path).provider_status_feeds_enabled is False
