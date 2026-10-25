import json
import os
import stat
import subprocess
import sys
from dataclasses import replace
from pathlib import Path

import pytest

from jrbar import claude_cli_usage as module
from jrbar.claude_cli_usage import parse_usage_screen
from jrbar.provider_usage_codex_claude import collect_claude
from jrbar.provider_usage_settings import default_provider_usage_settings, load_provider_usage_settings
from tests.test_provider_usage_codex_claude import FixtureCredentials


def test_cli_screen_requires_complete_labelled_usage():
    assert parse_usage_screen('Context 90% used\nCurrent session\n25% used\nCurrent week (all models)\n60% left') == [
        {'label': '5-hour', 'utilization': 25}, {'label': 'Weekly', 'utilization': 40}]
    for text in ('Context 80% used', 'Current session\n25% used',
                 'Current session\n150% used\nCurrent week (all models)\n40% used',
                 'Current session\n25% used\nCurrent week (all models)\nLoading usage'):
        with pytest.raises(ValueError, match='usage_unavailable'):
            parse_usage_screen(text)


@pytest.mark.parametrize('enabled,instance', [(False, 'default'), (True, 'default'), (True, 'work')])
@pytest.mark.parametrize('failure', ['network_unavailable', 'response_timed_out', 'invalid_provider_response'])
def test_reserved_cli_fallback_never_probes_or_changes_normal_state(tmp_path, monkeypatch, enabled, instance, failure):
    monkeypatch.setattr('jrbar.provider_reconnect.sync_claude_credential_in_background', lambda *_a, **_k: False)
    monkeypatch.setattr(module, 'probe_usage', lambda *_a, **_k: pytest.fail('unverified CLI probe'))
    preference = default_provider_usage_settings().preference('claude')
    assert preference.option('cli_fallback') is None
    if enabled:
        preference = preference.with_option('cli_fallback', 'true')
    preference = replace(preference, source_instance_id=instance)

    def fetch(_):
        if failure == 'invalid_provider_response':
            return None
        raise ValueError(failure)

    result = collect_claude(preference, home=tmp_path, observed_at=1000,
        credentials=FixtureCredentials({('claude', 'oauth-token'): 'synthetic-access'}), quota_fetcher=fetch,
        local_scanner=lambda *_: None, statusline_reader=lambda *_: None)
    assert result.reason_code == ('invalid_provider_response' if failure == 'invalid_provider_response' else 'network_unavailable')
    assert not result.lanes


@pytest.fixture
def fake_tui(tmp_path, monkeypatch):
    monkeypatch.setattr(module, '_model_turn_detected', False)
    executable = tmp_path / 'claude'
    executable.write_text(f'#!{sys.executable}\n' + (Path(__file__).parent / 'fixtures/claude_usage_tui.py').read_text())
    executable.chmod(0o700)
    monkeypatch.setattr(module, 'resolve_cli', lambda _: str(executable))
    monkeypatch.setenv('ANTHROPIC_AUTH_TOKEN', 'synthetic-unwanted')
    monkeypatch.setenv('CLAUDE_CONFIG_DIR', str(tmp_path / 'original-config'))
    monkeypatch.setenv('JRBAR_SECRET', 'synthetic-private')
    original = subprocess.Popen
    processes, configs = [], []
    log = tmp_path / 'input'
    mode = ['normal']

    def start(args, **kwargs):
        if '--version' in args:
            return original(args, **kwargs)
        env = kwargs['env']
        descriptor = int(env['CLAUDE_CODE_OAUTH_TOKEN_FILE_DESCRIPTOR'])
        assert stat.S_IMODE(os.fstat(descriptor).st_mode) == 0o600
        assert kwargs['pass_fds'] == (descriptor,)
        assert kwargs['start_new_session']
        assert 'synthetic-access' not in str(env) + str(args)
        assert not any(key.startswith(('ANTHROPIC', 'JRBAR')) for key in env)
        assert env['DISABLE_AUTOUPDATER'] == '1'
        assert json.loads(args[args.index('--settings') + 1]) == {
            'disableAllHooks': True, 'remoteControlAtStartup': False}
        configs.append(Path(env['CLAUDE_CONFIG_DIR']))
        kwargs['env'] = {**env, 'FAKE_CLAUDE_MODE': mode[0], 'FAKE_CLAUDE_INPUT': str(log)}
        process = original(args, **kwargs)
        processes.append(process)
        return process

    monkeypatch.setattr(module.subprocess, 'Popen', start)
    yield mode, log, processes, configs
    assert all(process.poll() is not None for process in processes)
    assert all(not config.exists() for config in configs)


def run_candidate(tmp_path, **kwargs):
    return module._probe_usage('synthetic-access', settings_path=tmp_path / 'provider-usage.json',
                               allowed_versions=frozenset({'2.1.309'}), **kwargs)


@pytest.mark.parametrize('mode', ['normal', 'slow'])
def test_candidate_sends_only_command_dispatch_and_exit(tmp_path, fake_tui, mode):
    fake_tui[0][0] = mode
    evidence = module.ProbeEvidence()
    assert run_candidate(tmp_path, timeout=4, evidence=evidence) == [
        {'label': '5-hour', 'utilization': 25}, {'label': 'Weekly', 'utilization': 40}]
    assert fake_tui[1].read_bytes() in (b'/usage\r\x1b', b'/usage\r\x1b/exit')
    # The final write may be killed before the child reads it. Audit actual writes separately.
    assert evidence.sent_hex == ['2f7573616765', '0d', '1b', '2f65786974']
    assert evidence.audit == {'files': 0, 'records': 0, 'assistant_entries': 0, 'model_entries': 0, 'usage_entries': 0}


@pytest.mark.parametrize('mode', ['onboarding', 'trust', 'login', 'api_key', 'choice', 'crash'])
def test_candidate_never_answers_a_screen_or_crash(tmp_path, fake_tui, mode):
    fake_tui[0][0] = mode
    evidence = module.ProbeEvidence()
    reason = 'usage_unavailable' if mode == 'crash' else 'interaction_required'
    with pytest.raises(ValueError, match=reason):
        run_candidate(tmp_path, timeout=1.5, evidence=evidence)
    assert evidence.sent_hex == []
    assert not fake_tui[1].exists()


@pytest.mark.parametrize('mode,sent', [('partial', ['2f7573616765', '0d']),
                                      ('wrong_menu', ['2f7573616765']), ('unselected_menu', ['2f7573616765'])])
def test_candidate_refuses_incomplete_or_unselected_screen(tmp_path, fake_tui, mode, sent):
    fake_tui[0][0] = mode
    evidence = module.ProbeEvidence()
    with pytest.raises(ValueError, match='usage_unavailable'):
        run_candidate(tmp_path, timeout=1.7, evidence=evidence)
    assert evidence.sent_hex == sent


def test_model_entry_disables_fallback_persistently(tmp_path, fake_tui):
    fake_tui[0][0] = 'assistant'
    with pytest.raises(ValueError, match='model_turn_detected'):
        run_candidate(tmp_path, timeout=3)
    preference = load_provider_usage_settings(tmp_path / 'provider-usage.json').settings.preference('claude')
    assert preference.option('cli_fallback') == 'false'
    assert preference.option('cli_fallback_disabled') == 'true'
    with pytest.raises(ValueError, match='permanently_disabled'):
        run_candidate(tmp_path)


def test_unverified_production_transport_cannot_launch(tmp_path, monkeypatch):
    monkeypatch.setattr(module.subprocess, 'Popen', lambda *a, **kw: pytest.fail('unsafe CLI launch'))
    with pytest.raises(ValueError, match='command_transport_unverified'):
        module.probe_usage('synthetic-access', settings_path=tmp_path / 'settings.json')


def test_unknown_version_never_opens_pty(tmp_path, monkeypatch):
    monkeypatch.setattr(module, 'resolve_cli', lambda _: '/synthetic/claude')
    monkeypatch.setattr(module, 'installed_version', lambda *a, **kw: '2.1.310')
    monkeypatch.setattr(module.pty, 'openpty', lambda: pytest.fail('unknown version opened PTY'))
    with pytest.raises(ValueError, match='version_unverified'):
        run_candidate(tmp_path)


def test_cli_option_does_not_bypass_usage_consent(tmp_path):
    from jrbar.provider_usage_consent import ConsentGatedCollector

    preference = default_provider_usage_settings().preference('claude').with_option('cli_fallback', 'true')
    gated = ConsentGatedCollector('claude', lambda *_: pytest.fail('CLI or credential read without consent'))
    assert gated(preference, tmp_path, 1000, None).reason_code == 'usage_not_turned_on'


def test_terminal_erases_old_sections_and_preserves_selected_command():
    screen = module._Screen()
    screen.feed(b'Current session\r\n25% used\r\nCurrent week (all models)\r\n40% used')
    screen.feed(b'\x1b[2J\x1b[H/usage Show session cost and plan usage')
    assert 'Current session' not in screen.text()
    assert not screen.usage_selected()
    screen.feed(b'\x1b[H\x1b[7m/usage\x1b[0m Show session cost and plan usage')
    assert screen.usage_selected()


def test_evidence_redacts_identity_and_secrets():
    evidence = module.ProbeEvidence()
    evidence.capture('synthetic@example.invalid\nSynthetic organization\nsk-synthetic-token\nCurrent session\n25% used')
    assert evidence.screens == ['[redacted]\n[redacted]\n[redacted]\nCurrent session\n25% used']


def test_foreground_rgb_does_not_mark_menu_selected():
    screen = module._Screen()
    screen.feed(b'\x1b[38;2;40;100;107m/usage Show session cost and plan usage')
    assert not screen.usage_selected()
