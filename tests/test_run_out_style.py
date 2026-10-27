import pytest

from jrbar.core_auth import setting_path_is_open
from jrbar.settings import AgentMonitorSettings, load_settings, save_settings, settings_from_mapping
from tests.test_core_runtime import headless  # noqa: F401


@pytest.mark.parametrize("value", [None, "", "bad", 1, [], {}])
def test_missing_or_invalid_style_defaults_to_time_left(value):
    assert AgentMonitorSettings().usage_run_out_style == "time_left"
    assert settings_from_mapping({}).usage_run_out_style == "time_left"
    assert settings_from_mapping({"usage_run_out_style": value}).usage_run_out_style == "time_left"


@pytest.mark.parametrize("style", ["time_left", "clock"])
def test_style_persists_through_unrelated_changes(tmp_path, style):
    target = tmp_path / "settings.json"
    configured = AgentMonitorSettings().with_usage_run_out_style(style)
    save_settings(configured, target)
    reloaded = load_settings(target).with_tips_enabled(False)
    save_settings(reloaded, target)
    assert load_settings(target).usage_run_out_style == style
    assert load_settings(target).to_dict()["usage_run_out_style"] == style


def test_style_is_an_open_display_preference(headless):  # noqa: F811
    assert setting_path_is_open("usage_run_out_style")
    headless.applicationDidFinishLaunching_(None)
    for style in ("clock", "time_left"):
        result = headless._core_dispatch("set_setting", {"path": "usage_run_out_style", "value": style})
        assert result["value"] == style
        assert headless.settings.usage_run_out_style == style
