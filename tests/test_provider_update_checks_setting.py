"""`provider_update_checks_enabled`: off by default, and only a real true turns it on.

The daemon's own switch for Settings > Agents' "Check for agent updates". Off, no request
leaves the Mac and no thread starts: the registry is asked only after the person turns it
on. The behaviour behind it is in test_provider_updates.py; this holds the key itself and
proves the daemon's own settings drive it. Every fetch here is injected; nothing reaches a
network (conftest refuses a connect off this Mac in any case).
"""

from __future__ import annotations

import pytest

from tests.test_core_runtime import headless  # noqa: F401  (the headless daemon fixture)


def test_the_default_settings_leave_update_checks_off() -> None:
    from jrbar.settings import AgentMonitorSettings

    assert AgentMonitorSettings().provider_update_checks_enabled is False
    assert AgentMonitorSettings().to_dict()["provider_update_checks_enabled"] is False
    on = AgentMonitorSettings().with_provider_update_checks_enabled(True)
    assert on.provider_update_checks_enabled is True
    assert on.to_dict()["provider_update_checks_enabled"] is True


def test_the_setting_round_trips_and_a_mistyped_value_is_off(tmp_path) -> None:
    from jrbar.core_runtime import settings_from_document
    from jrbar.settings import AgentMonitorSettings, load_settings, save_settings

    target = tmp_path / "settings.json"
    save_settings(AgentMonitorSettings().with_provider_update_checks_enabled(True), target)
    assert load_settings(target).provider_update_checks_enabled is True

    document = AgentMonitorSettings().to_dict()
    for mistyped in ("yes", 1, None, [True], "true"):
        loaded = settings_from_document(
            {**document, "provider_update_checks_enabled": mistyped}, scratch_dir=tmp_path
        )
        assert loaded.provider_update_checks_enabled is False
    # A settings file from before the key existed has the checks off too.
    document.pop("provider_update_checks_enabled")
    assert settings_from_document(document, scratch_dir=tmp_path).provider_update_checks_enabled is False


def test_the_daemon_asks_the_registry_only_after_set_setting_turns_the_switch_on(headless) -> None:  # noqa: F811
    from jrbar import core_runtime

    controller = headless
    controller.applicationDidFinishLaunching_(None)
    updates = core_runtime._provider_updates_of(controller)
    requests: list[str] = []
    started: list = []
    updates._fetch_latest = lambda package: requests.append(package)
    updates._start = lambda fn, name: started.append(fn)
    # Whatever is installed on the machine running this test is not the point: a CLI that
    # exists but cannot be run is found, so a request would show if one were made.
    updates._locate = lambda binary: f"/nonexistent/{binary}"

    # A fresh install: off. The daemon's tick, the Agents refresh and the document all do nothing.
    assert controller.settings.provider_update_checks_enabled is False
    updates.tick()
    assert controller._core_dispatch("provider_update_check", {}) == {"enabled": False, "started": False}
    assert started == [] and requests == []
    assert updates.document() == {}

    # The Settings switch goes through set_setting; the very next tick sees it.
    controller._core_dispatch("set_setting", {"path": "provider_update_checks_enabled", "value": True})
    assert controller.settings.provider_update_checks_enabled is True
    updates.tick()
    assert len(started) == 1
    started[0]()
    assert sorted(requests) == sorted(
        ["@anthropic-ai/claude-code", "@openai/codex", "@xai-official/grok", "@google/gemini-cli", "opencode-ai"]
    )

    # Turned off again, the next tick and the next Agents refresh ask nothing more.
    controller._core_dispatch("set_setting", {"path": "provider_update_checks_enabled", "value": False})
    before = list(requests)
    updates.tick()
    assert controller._core_dispatch("provider_update_check", {}) == {"enabled": False, "started": False}
    assert requests == before and len(started) == 1


@pytest.mark.parametrize("value", ["yes", 1, None, "true"])
def test_only_a_real_true_turns_the_coordinator_on(value) -> None:
    from types import SimpleNamespace

    from jrbar import core_runtime

    controller = SimpleNamespace(settings=SimpleNamespace(provider_update_checks_enabled=value))
    updates = core_runtime._provider_updates_of(controller)
    started: list = []
    updates._start = lambda fn, name: started.append(name)

    assert updates.check(forced=True) == {"enabled": False, "started": False}
    assert started == []


def test_the_apps_settings_key_is_a_key_the_daemon_serves() -> None:
    import re
    from pathlib import Path

    from jrbar.settings import AgentMonitorSettings

    catalogue = Path(__file__).parents[1] / "app" / "Sources" / "JRBarCore" / "SettingsDocument.swift"
    keys = set(
        re.findall(r'SettingsKey\(\.\w+, "([^"]+)", \.\w+\)', catalogue.read_text(encoding="utf-8"))
    )

    assert "provider_update_checks_enabled" in keys
    assert "provider_update_checks_enabled" in AgentMonitorSettings().to_dict()
