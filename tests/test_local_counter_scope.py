"""Provider-wide local counters have one owner across quota accounts."""

from dataclasses import replace

import pytest
from test_provider_usage_codex_claude import FixtureCredentials

from jrbar.provider_usage_codex_claude import (
    collect_claude,
    collect_claude_local_only,
    collect_codex,
    collect_codex_local_only,
)
from jrbar.provider_usage_consent import ConsentGatedCollector
from jrbar.provider_usage_settings import USAGE_CONSENT_VERSION, default_provider_usage_settings


@pytest.mark.parametrize("provider", ["claude", "codex"])
@pytest.mark.parametrize("consented", [False, True])
def test_default_is_only_local_counter_owner(tmp_path, monkeypatch, provider, consented):
    from jrbar import claude_quota, provider_reconnect

    monkeypatch.setattr(claude_quota, "account_facts_from_claude_config", lambda *_a: (None, None))
    monkeypatch.setattr(provider_reconnect, "sync_claude_credential_in_background", lambda *_a, **_k: False)
    monkeypatch.setattr(claude_quota, "_claude_code_user_agent", lambda: "claude-code/fixture")
    local = {"input_tokens": 100, "cached_input_tokens": 20, "output_tokens": 30,
             "model_count": 2, "estimated_cost_usd": 1.5, "cache_savings_usd": 0.25,
             "windows": [{"label": "primary", "used_percent": 40,
                          "window_minutes": 300, "resets_at": 2000}]}
    def scanner(*_args):
        return local
    credentials = FixtureCredentials({("claude", "oauth-token"): "fixture-token"})
    if provider == "codex":
        def granted(pref, home, at, _creds):
            return collect_codex(
                    pref, home=home, observed_at=at, local_scanner=scanner, read_auth=False,
                    live_probe=lambda: {"windows": local["windows"]},
                )
        def local_only(pref, home, at):
            return collect_codex_local_only(
                    pref, home=home, observed_at=at, local_scanner=scanner,
                )
    else:
        def granted(pref, home, at, creds):
            return collect_claude(
                    pref, home=home, observed_at=at, credentials=creds, local_scanner=scanner,
                    quota_fetcher=lambda _token: local["windows"], statusline_reader=lambda _at: None,
                )
        def local_only(pref, home, at):
            return collect_claude_local_only(
                    pref, home=home, observed_at=at, local_scanner=scanner, statusline_reader=lambda _at: None,
                )
    gate = ConsentGatedCollector(provider, granted, local_only)
    snapshots = []
    for instance in ("default", "work", "personal"):
        pref = replace(default_provider_usage_settings().preference(provider),
                       source_instance_id=instance,
                       usage_consent_version=USAGE_CONSENT_VERSION if consented else 0)
        snapshots.append(gate(pref, tmp_path, 1000, credentials))
    default, *named = snapshots
    expected = (100, 20, 30) if consented else (0, 0, 0)
    assert (default.input_tokens, default.cached_input_tokens, default.output_tokens) == expected
    assert default.estimated_cost_usd == (1.5 if consented else None)
    for snapshot in named:
        assert (snapshot.input_tokens, snapshot.cached_input_tokens, snapshot.output_tokens) == (0, 0, 0)
        assert snapshot.model_count == 0
        assert snapshot.estimated_cost_usd is None and snapshot.cache_savings_usd is None
        if consented:
            assert snapshot.lanes and snapshot.lanes[0].remaining_percent == 60
    assert sum(s.input_tokens + s.cached_input_tokens + s.output_tokens for s in snapshots) == (150 if consented else 0)
    assert sum(s.estimated_cost_usd or 0 for s in snapshots) == (1.5 if consented else 0)
