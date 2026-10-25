import subprocess
from dataclasses import replace

import pytest

from jrbar.claude_cli_usage import parse_usage_screen
from jrbar.provider_usage_codex_claude import collect_claude
from jrbar.provider_usage_settings import default_provider_usage_settings
from tests.test_provider_usage_codex_claude import FixtureCredentials


def test_cli_screen_requires_labelled_usage_not_context_or_tool_share():
    windows = parse_usage_screen("Context 90% used\nCurrent session\n25% used\n"
                                 "Current week (all models)\n60% left\n")
    assert windows == [{"label": "5-hour", "utilization": 25}, {"label": "Weekly", "utilization": 40}]
    for text in ("Context 80% used", "Current session\nLoading usage", "Current session\n150% used"):
        with pytest.raises(ValueError, match="claude_cli_usage_unavailable"):
            parse_usage_screen(text)


@pytest.mark.parametrize("enabled,instance,calls", [(False, "default", 0), (True, "default", 1), (True, "work", 0)])
def test_cli_fallback_is_off_by_default_and_never_probes_named_accounts(tmp_path, monkeypatch, enabled, instance, calls):
    monkeypatch.setattr("jrbar.provider_reconnect.sync_claude_credential_in_background", lambda *_a, **_k: False)
    preference = default_provider_usage_settings().preference("claude")
    assert preference.option("cli_fallback") is None
    if enabled:
        preference = preference.with_option("cli_fallback", "true")
    preference = replace(preference, source_instance_id=instance)
    probes = []

    def probe(token):
        assert token == "synthetic-access"
        probes.append(True)
        return parse_usage_screen("Current session\n25% used")

    result = collect_claude(preference, home=tmp_path, observed_at=1000, credentials=FixtureCredentials({("claude", "oauth-token"): "synthetic-access"}),
                            quota_fetcher=lambda _: (_ for _ in ()).throw(ValueError("unauthorized")),
                            local_scanner=lambda *_: None, statusline_reader=lambda *_: None, cli_probe=probe)
    assert len(probes) == calls
    if calls:
        assert result.state.value == "ready"
        assert result.lanes[0].source_id == "claude-cli"
        assert result.lanes[0].remaining_percent == 75


def test_probe_uses_temporary_config_access_token_only_and_reaps_process(tmp_path, monkeypatch):
    from jrbar import claude_cli_usage

    executable = tmp_path / "synthetic-claude"
    executable.write_text("#!/bin/sh\nprintf 'Current session\\n25%% used\\nCurrent week (all models)\\n40%% used\\n'\n")
    executable.chmod(0o700)
    monkeypatch.setattr(claude_cli_usage, "resolve_cli", lambda _: str(executable))
    monkeypatch.setenv("ANTHROPIC_AUTH_TOKEN", "synthetic-unwanted-auth")
    monkeypatch.setenv("CLAUDE_CONFIG_DIR", str(tmp_path / "original-config"))
    original = subprocess.Popen
    processes, configs = [], []

    def start(args, **kwargs):
        assert args == [str(executable), "/usage"]
        environment = kwargs["env"]
        assert environment["CLAUDE_CODE_OAUTH_TOKEN"] == "synthetic-access"
        assert "ANTHROPIC_AUTH_TOKEN" not in environment
        assert environment["CLAUDE_CONFIG_DIR"] == kwargs["cwd"]
        assert environment["CLAUDE_CONFIG_DIR"] != str(tmp_path / "original-config")
        assert kwargs["start_new_session"]
        configs.append(kwargs["cwd"])
        process = original(args, **kwargs)
        processes.append(process)
        return process

    monkeypatch.setattr(claude_cli_usage.subprocess, "Popen", start)
    windows = claude_cli_usage.probe_usage("synthetic-access", timeout=2)
    assert [window["utilization"] for window in windows] == [25, 40]
    assert processes[0].poll() is not None
    from pathlib import Path

    assert not Path(configs[0]).exists()


def test_cli_option_does_not_bypass_usage_consent(tmp_path):
    from jrbar.provider_usage_consent import ConsentGatedCollector

    preference = default_provider_usage_settings().preference("claude").with_option("cli_fallback", "true")
    gated = ConsentGatedCollector("claude", lambda *_: pytest.fail("CLI or credential read without consent"))
    assert gated(preference, tmp_path, 1000, None).reason_code == "usage_not_turned_on"


def test_probe_stops_on_parsed_usage_and_reaps_before_removing_config(tmp_path, monkeypatch):
    from pathlib import Path
    from jrbar import claude_cli_usage as module

    executable = tmp_path / "synthetic-claude"
    executable.write_text("#!/bin/sh\nprintf 'Current session\\n25%% used\\n'\nread answer\n")
    executable.chmod(0o700)
    monkeypatch.setattr(module, "resolve_cli", lambda _: str(executable))
    original = module._kill_group
    spawn = module.subprocess.Popen
    configs, processes, killed = [], [], []

    def start(args, **kwargs):
        configs.append(Path(kwargs["cwd"]))
        process = spawn(args, **kwargs)
        processes.append(process)
        return process

    monkeypatch.setattr(module.subprocess, "Popen", start)

    def kill(process):
        assert configs[0].is_dir()
        killed.append(True)
        original(process)

    monkeypatch.setattr(module, "_kill_group", kill)
    # Parsing succeeds without waiting for the child to exit or its timeout.
    assert module.probe_usage("synthetic-access", timeout=2)[0]["utilization"] == 25
    assert killed == [True]
    assert processes[0].poll() is not None
    assert not configs[0].exists()
