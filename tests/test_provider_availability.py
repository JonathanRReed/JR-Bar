from dataclasses import replace
from types import SimpleNamespace

import pytest

from jrbar import core_runtime
from jrbar.core_projection import usage_document
from jrbar.core_server import ACTION_LANE_COMMANDS
from jrbar.provider_availability import GONE_READING_SECONDS, availability_document
from jrbar.provider_usage_platform import ProviderSourceState, UsageLane, failure_snapshot
from jrbar.provider_usage_runtime import ProviderUsageState
from jrbar.provider_usage_settings import load_provider_usage_settings


@pytest.fixture(autouse=True)
def isolated_provider_settings(tmp_path, monkeypatch):
    monkeypatch.setattr("jrbar.provider_usage_settings.default_provider_usage_settings_path",
                        lambda: tmp_path / "provider-usage.json")


def reading(*, measured=True, provider="antigravity", reason="quota_service_not_running"):
    value = failure_snapshot(provider, observed_at=2000, state=ProviderSourceState.UNAVAILABLE,
                             reason=reason, action="Open Antigravity")
    return replace(value, lanes=(UsageLane(provider, "weekly", "Weekly", 30, 3000, "account", None, None, True, "fixture"),) if measured else (),
                   read_at=1000 if measured else None)


def test_installed_idle_provider_names_cause_action_and_age():
    value = availability_document(reading(), now=8200, installed=True)
    assert value["availability"] == "source_idle"
    assert value["status_text"] == "Quota service is not running"
    assert value["last_good_age_seconds"] == 7200
    assert value["action"] == "Open Antigravity to refresh"
    assert value["action_kind"] == "open_app"
    assert value["panel_visible"]


def test_failed_installed_source_keeps_specific_cause_fix_and_age():
    value = reading(provider="claude", reason="claude_keychain_access_lost")
    value = replace(value, action_label="Allow Claude Keychain access")
    row = usage_document(ProviderUsageState((value,), 2000, 3000, False), now=8200,
                         detected_agents={"claude": True})["providers"][0]
    assert row["availability"] == "failing"
    assert row["status_text"] == "Keychain access lost after Claude renewed its sign-in"
    assert row["action"] == "Allow Claude Keychain access"
    assert row["read_at"] == 1000
    assert row["windows"][0]["used_pct"] is None
    assert row["windows"][0]["last_used_pct"] == 70


def test_absent_never_used_provider_is_only_in_settings_but_unknown_is_visible():
    assert not availability_document(reading(measured=False), now=8200, installed=False)["panel_visible"]
    assert availability_document(reading(measured=False), now=8200, installed=None)["panel_visible"]
    assert availability_document(replace(reading(measured=False), source_instance_id="work"),
                                  now=8200, installed=False)["panel_visible"]


def test_live_quota_answer_beats_an_absent_local_installation():
    snapshot = replace(reading(), state=ProviderSourceState.READY, reason_code=None, action_label=None)
    row = availability_document(snapshot, now=2000, installed=False)
    assert row["availability"] == "available"
    assert row["status_text"] is None
    assert row["panel_visible"]
    elapsed = availability_document(snapshot, now=3000, installed=False)
    assert elapsed["status_text"] == "Quota window reset since the last reading"
    assert elapsed["action"] == "Retry"


def test_removed_provider_keeps_reading_one_week_then_offers_hide_without_hiding_itself():
    snapshot = reading()
    recent = availability_document(snapshot, now=1000 + GONE_READING_SECONDS - 1, installed=False)
    assert recent["availability"] == "missing_recent"
    assert recent["panel_visible"]
    old = availability_document(snapshot, now=1000 + GONE_READING_SECONDS, installed=False)
    assert old["availability"] == "not_found"
    assert old["status_text"] == "Not found on this Mac"
    assert old["action_kind"] == "hide"
    assert old["panel_visible"]
    assert not availability_document(snapshot, now=1000 + GONE_READING_SECONDS,
                                      installed=False, hidden=True)["panel_visible"]


def test_provider_actions_run_on_action_worker_and_open_without_shell(tmp_path, monkeypatch):
    assert "provider_action" in ACTION_LANE_COMMANDS
    assert not core_runtime._MAIN_THREAD_COMMANDS["provider_action"].main_thread
    calls, refreshes = [], []
    monkeypatch.setattr(core_runtime.subprocess, "run", lambda args, **kw:
                        calls.append((args, kw)) or SimpleNamespace(returncode=0))
    controller = SimpleNamespace(provider_usage_state=ProviderUsageState((reading(),), 2000, 3000, False),
        _core_detected_agents=lambda: {"antigravity": True},
        _request_provider_usage=lambda **kw: refreshes.append(kw))
    result = core_runtime._cmd_provider_action(controller, {"provider": "antigravity"})
    assert result["message"] == "Opening Antigravity."
    assert calls[0][0] == ["/usr/bin/open", "-a", "Antigravity"]
    assert calls[0][1]["timeout"] == 5
    assert refreshes == [{"force": True, "providers": (("antigravity", "default"),)}]


def test_hide_is_explicit_persisted_and_does_not_disable_tracking(tmp_path, monkeypatch):
    monkeypatch.setenv("XDG_CONFIG_HOME", str(tmp_path))
    monkeypatch.setattr(core_runtime.time, "time", lambda: 1000 + GONE_READING_SECONDS)
    controller = SimpleNamespace(provider_usage_state=ProviderUsageState((reading(),), 2000, 3000, False),
        _core_detected_agents=lambda: {"antigravity": False}, _request_provider_usage=lambda **_: None)
    before = load_provider_usage_settings().settings.preference("antigravity")
    core_runtime._cmd_provider_action(controller, {"provider": "antigravity", "action": "hide"})
    after = load_provider_usage_settings().settings.preference("antigravity")
    assert after.enabled == before.enabled
    assert after.usage_consented == before.usage_consented
    assert after.option("panel_hidden") == "true"


def test_elapsed_window_retry_uses_the_current_projected_action():
    snapshot = replace(reading(), state=ProviderSourceState.READY, reason_code=None, action_label=None)
    refreshes = []
    controller = SimpleNamespace(provider_usage_state=ProviderUsageState((snapshot,), 2000, 3000, False),
        _request_provider_usage=lambda **kw: refreshes.append(kw))
    result = core_runtime._cmd_provider_action(controller, {"provider": "antigravity"})
    assert result["message"] == "Antigravity usage refresh requested."
    assert len(refreshes) == 1


def test_claude_access_lost_button_rereads_instead_of_renewing_token(monkeypatch):
    from jrbar.provider_reconnect import ResignInResult

    snapshot = replace(reading(provider="claude", reason="claude_keychain_access_lost"),
                       action_label="Allow Claude Keychain access")
    calls = []
    monkeypatch.setattr("jrbar.provider_reconnect.reconnect_provider", lambda *args, **kw:
                        calls.append((args, kw)) or ResignInResult("claude", "Read sign-in again."))
    controller = SimpleNamespace(provider_usage_state=ProviderUsageState((snapshot,), 2000, 3000, False),
        _request_provider_usage=lambda **_: None)
    result = core_runtime._cmd_provider_action(controller, {"provider": "claude"})
    assert result["message"] == "Read sign-in again."
    assert calls == [(("claude", "default"), {"reason_code": "claude_keychain_access_lost"})]


def test_installed_missing_sources_keep_their_own_reason_and_action():
    for provider, reason, action in (
        ("gemini", "gemini_auth_missing", "Sign in to Gemini CLI"),
        ("grok", "grok_auth_missing", "Run grok login"),
    ):
        snapshot = replace(reading(provider=provider, reason=reason),
                           state=ProviderSourceState.SOURCE_NOT_FOUND, action_label=action)
        row = usage_document(ProviderUsageState((snapshot,), 2000, 3000, False), now=2001,
                             detected_agents={provider: True})["providers"][0]
        assert row["reason"] == reason
        assert row["action"] == action
        assert row["availability"] == "failing"
        assert row["action_kind"] is None
        assert "Quota service" not in row["status_text"]


def test_provider_action_hops_state_changes_to_main_but_opens_on_worker(monkeypatch):
    on_main_now = [False]
    refreshes = []

    def on_main(fn):
        assert not on_main_now[0]
        on_main_now[0] = True
        try:
            return fn()
        finally:
            on_main_now[0] = False

    def detect():
        assert on_main_now[0]
        return {"antigravity": True}

    def refresh(**kw):
        assert on_main_now[0]
        refreshes.append(kw)

    def open_app(*args, **kw):
        assert not on_main_now[0]
        return SimpleNamespace(returncode=0)

    monkeypatch.setattr(core_runtime.subprocess, "run", open_app)
    controller = SimpleNamespace(provider_usage_state=ProviderUsageState((reading(),), 2000, 3000, False),
        _core_on_main=on_main, _core_detected_agents=detect, _request_provider_usage=refresh)
    core_runtime._cmd_provider_action(controller, {"provider": "antigravity"})
    assert len(refreshes) == 1


def test_open_timeout_is_a_command_error(monkeypatch):
    import subprocess
    import pytest
    from jrbar.core_server import CommandError

    def timeout(*args, **kw):
        raise subprocess.TimeoutExpired("synthetic", 5)

    monkeypatch.setattr(core_runtime.subprocess, "run", timeout)
    controller = SimpleNamespace(provider_usage_state=ProviderUsageState((reading(),), 2000, 3000, False),
        _request_provider_usage=lambda **_: pytest.fail("refresh after failed open"))
    with pytest.raises(CommandError, match="Could not open"):
        core_runtime._cmd_provider_action(controller, {"provider": "antigravity"})


def test_hide_write_refusal_is_reported_on_main(monkeypatch):
    import pytest
    from jrbar.core_server import CommandError
    from jrbar.provider_usage_settings import ProviderUsageSettingsWriteRefusedError

    main = [False]

    def on_main(fn):
        main[0] = True
        try:
            return fn()
        finally:
            main[0] = False

    def refuse(*args, **kw):
        assert main[0]
        raise ProviderUsageSettingsWriteRefusedError("settings changed")

    monkeypatch.setattr("jrbar.provider_usage_settings.save_provider_usage_settings", refuse)
    monkeypatch.setattr(core_runtime.time, "time", lambda: 1000 + GONE_READING_SECONDS)
    controller = SimpleNamespace(provider_usage_state=ProviderUsageState((reading(),), 2000, 3000, False),
        _core_on_main=on_main, _core_detected_agents=lambda: {"antigravity": False})
    with pytest.raises(CommandError, match="settings changed"):
        core_runtime._cmd_provider_action(controller, {"provider": "antigravity", "action": "hide"})


def test_reconnect_reads_on_worker_and_publishes_on_main(monkeypatch):
    from jrbar.provider_reconnect import ResignInResult
    from jrbar.provider_browser_access import perform_provider_usage_action

    main = [False]
    refreshes = []

    class Controller(SimpleNamespace):
        def __setattr__(self, name, value):
            if name == "_jrbar_reconnect_watch":
                assert main[0]
            super().__setattr__(name, value)

    def on_main(fn):
        main[0] = True
        try:
            return fn()
        finally:
            main[0] = False

    def read(*args, **kw):
        assert not main[0]
        return ResignInResult("claude", "Read again.")

    def refresh(**kw):
        assert main[0]
        refreshes.append(kw)

    monkeypatch.setattr("jrbar.provider_reconnect.reconnect_provider", read)
    snapshot = replace(reading(provider="claude"), action_label="Reconnect Claude")
    controller = Controller(provider_usage_state=ProviderUsageState((snapshot,), 2000, 3000, False),
        _core_on_main=on_main, _request_provider_usage=refresh)
    core_runtime._cmd_provider_action(controller, {"provider": "claude", "action": "resign_in"})
    monkeypatch.setattr("jrbar.provider_browser_access.handle_provider_usage_action",
                        lambda *a, **kw: read().message)
    assert perform_provider_usage_action(controller, "claude") == "Read again."
    assert len(refreshes) == 2


def test_explicit_open_cannot_become_hide_when_inventory_changes(tmp_path, monkeypatch):
    import pytest
    from jrbar.core_server import CommandError

    monkeypatch.setattr(core_runtime.time, "time", lambda: 1000 + GONE_READING_SECONDS)
    controller = SimpleNamespace(provider_usage_state=ProviderUsageState((reading(),), 2000, 3000, False),
        _core_detected_agents=lambda: {"antigravity": False})
    with pytest.raises(CommandError, match="no longer available"):
        core_runtime._cmd_provider_action(controller, {"provider": "antigravity", "action": "open_app"})
    with pytest.raises(CommandError, match="explicit hide"):
        core_runtime._cmd_provider_action(controller, {"provider": "antigravity"})
    assert load_provider_usage_settings().settings.preference("antigravity").option("panel_hidden") != "true"


def test_hide_can_be_undone_without_changing_collection(tmp_path, monkeypatch):
    monkeypatch.setenv("XDG_CONFIG_HOME", str(tmp_path))
    monkeypatch.setattr(core_runtime.time, "time", lambda: 1000 + GONE_READING_SECONDS)
    controller = SimpleNamespace(provider_usage_state=ProviderUsageState((reading(),), 2000, 3000, False),
        _core_detected_agents=lambda: {"antigravity": False}, _request_provider_usage=lambda **_: None)
    core_runtime._cmd_provider_action(controller, {"provider": "antigravity", "action": "hide"})
    core_runtime._cmd_set_provider_options(controller, {
        "provider": "antigravity", "options": {"panel_hidden": "false"}})
    preference = load_provider_usage_settings().settings.preference("antigravity")
    assert preference.option("panel_hidden") == "false"
    assert availability_document(reading(), now=700000, installed=False,
                                 hidden=preference.option("panel_hidden") == "true")["panel_visible"]


def test_agy_only_idle_source_never_offers_open_app():
    snapshot = replace(reading(), action_label="Run agy in a terminal")
    row = availability_document(snapshot, now=2001, installed=True)
    assert row["availability"] == "source_idle"
    assert row["action"] == "Run agy in a terminal"
    assert row["action_kind"] is None
