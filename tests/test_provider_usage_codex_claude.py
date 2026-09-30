from __future__ import annotations

import json
from pathlib import Path
from unittest.mock import patch

from jrbar.provider_usage_codex_claude import collect_claude, collect_codex
from jrbar.provider_usage_settings import default_provider_usage_settings


class FixtureCredentials:
    """Inert test-only credential source. Values are not real credentials."""

    def __init__(self, values=None):
        self.values = values or {}

    def get(self, provider, account):
        value = self.values.get((provider, account))
        return type(
            "Read",
            (),
            {
                "available": value is not None,
                "secret": value,
                "reason": None if value is not None else "credential_not_found",
            },
        )()


def preference(provider: str):
    return default_provider_usage_settings().preference(provider)


def write_claude_account(home: Path, email: str) -> None:
    (home / ".claude.json").write_text(
        json.dumps({"oauthAccount": {"emailAddress": email, "organizationType": "claude_max"}}),
        encoding="utf-8",
    )


def test_codex_combines_local_quota_tokens_models_and_cost(tmp_path: Path):
    result = collect_codex(
        preference("codex"),
        home=tmp_path,
        observed_at=1000,
        local_scanner=lambda _home, _observed: {
            "windows": [
                {
                    "label": "primary",
                    "used_percent": 40,
                    "window_minutes": 300,
                    "resets_at": 2000,
                },
                {
                    "label": "Spark Weekly",
                    "used_percent": 75,
                    "window_minutes": 10080,
                    "resets_at": 3000,
                },
            ],
            "input_tokens": 100,
            "cached_input_tokens": 25,
            "output_tokens": 50,
            "model_count": 2,
            "estimated_cost_usd": 1.5,
            "cache_savings_usd": 0.2,
            "account_label": "account-fixture",
        },
    )
    assert result.state.value == "ready"
    assert result.lanes[0].remaining_percent == 60
    assert result.lanes[1].label == "Spark Weekly"
    assert result.input_tokens == 100
    assert result.model_count == 2
    assert result.estimated_cost_usd == 1.5


def test_codex_live_rate_limit_replaces_a_newer_but_stale_local_percentage__and_1_more(tmp_path: Path,) -> None:
    # --- scenario: codex_live_rate_limit_replaces_a_newer_but_stale_local_percentage
    result = collect_codex(
        preference("codex"),
        home=tmp_path,
        observed_at=1000,
        live_probe=lambda: {
            "used_percent": 95.0,
            "resets_at": 3000.0,
            "window_minutes": 10080,
        },
        local_scanner=lambda _home, _observed: {
            "windows": [
                {
                    "label": "primary",
                    "used_percent": 89.0,
                    "window_minutes": 10080,
                    "resets_at": 3000.0,
                }
            ],
            "windows_observed_at": 999.0,
            "input_tokens": 100,
            "cached_input_tokens": 25,
            "output_tokens": 50,
            "model_count": 2,
        },
    )

    assert result.state.value == "ready"
    assert result.lanes[0].remaining_percent == 5.0
    assert result.lanes[0].source_id == "codex-app-server"
    assert result.input_tokens == 100
    assert result.cached_input_tokens == 25
    assert result.output_tokens == 50

    # --- scenario: codex_live_rate_limit_skips_the_default_cold_transcript_scan
    import jrbar.provider_usage_codex_claude as subject

    with (
        patch.object(subject, "_cached_codex_local_scan", return_value=None) as cached,
        patch.object(
            subject,
            "_default_provider_local_scan",
            side_effect=AssertionError("cold scan should not run on the live path"),
        ),
    ):
        result = collect_codex(
            preference("codex"),
            home=tmp_path,
            observed_at=1000,
            live_probe=lambda: {
                "used_percent": 95.0,
                "resets_at": 3000.0,
                "window_minutes": 10080,
            },
            local_scanner=subject._default_codex_local_scan,
        )

    cached.assert_called_once_with(tmp_path, 1000)
    assert result.state.value == "ready"
    assert result.lanes[0].remaining_percent == 5.0
    assert result.lanes[0].source_id == "codex-app-server"



def test_codex_without_rollout_evidence_is_actionable__and_1_more(tmp_path: Path) -> None:
    # --- scenario: codex_without_rollout_evidence_is_actionable
    result = collect_codex(
        preference("codex"),
        home=tmp_path,
        observed_at=1000,
        local_scanner=lambda _home, _observed: None,
    )
    assert result.state.value == "source_not_found"
    assert result.action_label == "Use Codex once or sign in"

    # --- scenario: claude_combines_oauth_windows_and_local_tokens
    write_claude_account(tmp_path, "fixture@example.invalid")
    result = collect_claude(
        preference("claude"),
        home=tmp_path,
        observed_at=1000,
        credentials=FixtureCredentials(
            {("claude", "oauth-token"): "fixture-claude-session"}
        ),
        quota_fetcher=lambda _token: [
            {"label": "5-hour", "used_percent": 15, "resets_at": 2000},
            {"label": "Fable only", "used_percent": 80, "resets_at": 3000},
        ],
        local_scanner=lambda _home, _observed: {
            "input_tokens": 200,
            "cached_input_tokens": 100,
            "output_tokens": 50,
            "model_count": 3,
            "estimated_cost_usd": 2.25,
            "cache_savings_usd": 0.75,
        },
    )
    assert result.state.value == "ready"
    assert next(lane for lane in result.lanes if lane.model == "fable").remaining_percent == 20
    assert result.cached_input_tokens == 100
    assert result.cache_savings_usd == 0.75
    assert result.account_discriminator is not None
    assert "fixture" not in result.account_discriminator


def test_claude_account_identity_survives_token_rotation_and_changes_on_switch(tmp_path: Path) -> None:
    write_claude_account(tmp_path, "first@example.invalid")

    def fetch(_token):
        return [{"label": "5-hour", "used_percent": 15, "resets_at": 2000}]
    first = collect_claude(
        preference("claude"), home=tmp_path, observed_at=1000,
        credentials=FixtureCredentials({("claude", "oauth-token"): "token-one"}),
        quota_fetcher=fetch, local_scanner=lambda *_args: None,
    )
    rotated = collect_claude(
        preference("claude"), home=tmp_path, observed_at=1001,
        credentials=FixtureCredentials({("claude", "oauth-token"): "token-two"}),
        quota_fetcher=fetch, local_scanner=lambda *_args: None,
    )
    assert first.account_discriminator == rotated.account_discriminator

    write_claude_account(tmp_path, "second@example.invalid")
    switched = collect_claude(
        preference("claude"), home=tmp_path, observed_at=1002,
        credentials=FixtureCredentials({("claude", "oauth-token"): "token-three"}),
        quota_fetcher=fetch, local_scanner=lambda *_args: None,
    )
    assert switched.account_discriminator != first.account_discriminator

    (tmp_path / ".claude.json").unlink()
    unknown = collect_claude(
        preference("claude"), home=tmp_path, observed_at=1003,
        credentials=FixtureCredentials({("claude", "oauth-token"): "token-four"}),
        quota_fetcher=fetch, local_scanner=lambda *_args: None,
    )
    assert unknown.state.value == "ready"
    assert unknown.account_discriminator is None


def test_claude_statusline_fallback_uses_only_the_default_cli_account_identity(tmp_path: Path) -> None:
    from dataclasses import replace

    from jrbar.claude_statusline_source import StatusLineReading, StatusLineWindow

    write_claude_account(tmp_path, "statusline@example.invalid")
    reading = StatusLineReading(
        "session-fixture",
        "claude-fixture",
        (("five_hour", StatusLineWindow(25.0, 2000.0)),),
        1000.0,
    )
    result = collect_claude(
        preference("claude"), home=tmp_path, observed_at=1000,
        credentials=FixtureCredentials(), quota_fetcher=lambda _token: [],
        local_scanner=lambda *_args: None, statusline_reader=lambda _now: reading,
    )
    assert result.state.value == "ready"
    assert result.account_discriminator is not None

    named = replace(preference("claude"), source_instance_id="manual")
    named_result = collect_claude(
        named, home=tmp_path, observed_at=1000,
        credentials=FixtureCredentials(), quota_fetcher=lambda _token: [],
        local_scanner=lambda *_args: None, statusline_reader=lambda _now: reading,
    )
    assert named_result.account_discriminator is None



def test_claude_default_quota_refresh_never_falls_back_to_a_cold_scan(
    tmp_path: Path,
):
    import jrbar.provider_usage_codex_claude as subject

    with (
        patch.object(subject, "_cached_claude_local_scan", return_value=None) as cached,
        patch.object(
            subject,
            "_default_provider_local_scan",
            side_effect=AssertionError("cold scan should not run on the quota path"),
        ),
    ):
        result = collect_claude(
            preference("claude"),
            home=tmp_path,
            observed_at=1000,
            credentials=FixtureCredentials(
                {("claude", "oauth-token"): "fixture-claude-session"}
            ),
            quota_fetcher=lambda _token: [
                {"label": "5-hour", "used_percent": 95, "resets_at": 2000}
            ],
            local_scanner=subject._default_claude_local_scan,
        )

    cached.assert_called_once_with(tmp_path, 1000)
    assert result.state.value == "ready"
    assert result.lanes[0].remaining_percent == 5


def test_claude_cached_local_scan_reuses_bounded_aggregate__and_1_more(
    tmp_path: Path, monkeypatch
) -> None:
    # --- scenario: claude_cached_local_scan_reuses_bounded_aggregate
    import jrbar.provider_usage_codex_claude as subject
    from jrbar import usage_stats
    from jrbar.state_paths import default_state_dir
    from tests.test_provider_usage_cached_scan import (
        DAY,
        OBSERVED,
        _claude_projects,
        _claude_transcript,
        _claude_usage_line,
    )

    # A real cache, written by the scan the graph runs. A model with no price
    # keeps the dollar figure honest: the tokens show and the cost does not.
    _claude_transcript(
        _claude_projects(tmp_path),
        "session.jsonl",
        [_claude_usage_line("m1", OBSERVED - 2 * DAY, model="no-such-model-x", cache_read=25)],
    )
    usage_stats.scan_usage(
        _claude_projects(tmp_path),
        default_state_dir(tmp_path) / "usage-scan-cache.json",
        since_epoch=OBSERVED - 30 * DAY,
    )
    subject._local_tokens_memo.clear()
    monkeypatch.delenv("CLAUDE_CONFIG_DIR", raising=False)

    result = subject._cached_claude_local_scan(tmp_path, OBSERVED, extra_homes=())

    assert result == {
        "input_tokens": 10,
        "cached_input_tokens": 25,
        "output_tokens": 5,
        "model_count": 1,
        "estimated_cost_usd": None,
        "cache_savings_usd": None,
    }

    # --- scenario: claude_without_explicit_usage_connection_is_actionable
    result = collect_claude(
        preference("claude"),
        home=tmp_path,
        observed_at=1000,
        credentials=FixtureCredentials(),
        quota_fetcher=lambda _token: [],
        local_scanner=lambda _home, _observed: None,
    )
    assert result.state.value == "needs_consent"
    assert result.action_label == "Connect Claude usage"
