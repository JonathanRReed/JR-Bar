"""Every reason a provider reading can carry reads as a plain sentence, and a
row button says what a click does."""

from __future__ import annotations

import re
from dataclasses import replace
from pathlib import Path

import pytest

from jrbar.provider_availability import _CAUSES, ATTENTION, availability_document, status_sentence
from jrbar.core_projection import _snapshot_has_quota_source
from jrbar.provider_usage_platform import (
    ProviderSourceState,
    UsageLane,
    failure_snapshot,
    provider_descriptor,
    select_authoritative_snapshot,
)

SOURCE = Path(__file__).resolve().parents[1] / "src/jrbar"
#: Consent results and lifecycle words, not reading reasons.
NOT_READING_REASONS = {"provider_usage_consent.py"}
PATTERNS = (
    re.compile(r'\b\w*failure\w*\(\s*(?:ProviderSourceState\.[A-Z_]+|[\w.]+)\s*,\s*"([a-z][a-z0-9_]+)"'),
    re.compile(r'\breason(?:_code)?\s*=\s*"([a-z][a-z0-9_]+)"'),
    re.compile(r'ProviderHttpError\([^)]*?"([a-z][a-z0-9_]+)"'),
)
READING_MODULE = re.compile(r"^(provider_usage|cliproxy|claude_cli_usage|provider_auth|provider_browser|provider_sign_in)")


def emitted_reasons() -> set[str]:
    found: set[str] = set()
    for path in SOURCE.glob("*.py"):
        if not READING_MODULE.match(path.name) or path.name in NOT_READING_REASONS:
            continue
        text = path.read_text(encoding="utf-8")
        for pattern in PATTERNS:
            found.update(match.group(1) for match in pattern.finditer(text))
    return found - {"disabled", "fresh"}


def test_the_scan_finds_the_reasons_it_should():
    reasons = emitted_reasons()
    assert {"cli_session_unavailable", "invalid_json", "opencode_go_not_subscribed", "cliproxy_key_missing"} <= reasons


def test_every_emitted_reason_has_a_sentence():
    missing = sorted(emitted_reasons() - _CAUSES.keys())
    assert not missing, f"add plain sentences to provider_availability._CAUSES for {missing}"


@pytest.mark.parametrize("reason", sorted(_CAUSES))
def test_each_sentence_is_plain(reason):
    words = status_sentence(reason, "Kiro")
    assert words[0].isupper() and words.endswith("."), words
    assert "_" not in words and "{" not in words, words
    assert words.lower() != reason.replace("_", " ")


def test_an_unknown_reason_never_shows_its_code():
    assert status_sentence("brand_new_reason", "Kiro") == ATTENTION
    snapshot = failure_snapshot("codex", observed_at=10, state=ProviderSourceState.ERROR, reason="brand_new_reason",
                                action="Retry")
    row = availability_document(snapshot, now=10, installed=True)
    assert row["status_text"] == ATTENTION
    assert row["availability"] == "failing"


def kiro(state, reason, action):
    return failure_snapshot("kiro", observed_at=10, state=state, reason=reason, action=action)


def test_sign_in_and_consent_are_neutral_with_their_fix():
    signed_out = availability_document(kiro(ProviderSourceState.NEEDS_SIGN_IN, "cli_session_unavailable",
                                            "Run kiro-cli login"), now=10, installed=True)
    assert signed_out["availability"] == "available"
    assert signed_out["status_text"] == "Run kiro-cli login in Terminal, then Retry."
    assert signed_out["action"] == "Retry"
    consent = availability_document(kiro(ProviderSourceState.NEEDS_CONSENT, "usage_consent_required",
                                         "Allow Kiro usage"), now=10, installed=True)
    assert consent["availability"] == "available"
    assert consent["status_text"] == "Turn on Kiro usage in Settings > Providers."
    assert consent["action"] is None


@pytest.mark.parametrize("provider,state,reason,label", [
    ("kiro", ProviderSourceState.NEEDS_SIGN_IN, "cli_session_changed", "Run kiro-cli login"),
    ("kiro", ProviderSourceState.NEEDS_CONSENT, "usage_consent_required", "Allow Kiro usage"),
    ("kiro", ProviderSourceState.UNSUPPORTED, "cli_default_account_only", "Use the default Kiro CLI account"),
    ("kilo", ProviderSourceState.NEEDS_SIGN_IN, "authentication_required", "Run kilo auth login or add Kilo API key"),
    ("kimi", ProviderSourceState.NEEDS_SIGN_IN, "credential_changed", "Run kimi login"),
    ("kimi", ProviderSourceState.ERROR, "invalid_configuration", "Check Kimi Code source"),
    ("factory", ProviderSourceState.NEEDS_SIGN_IN, "web_session_changed", "Reconnect Factory browser session"),
])
def test_refresh_only_providers_never_promise_an_action_they_cannot_take(provider, state, reason, label):
    snapshot = failure_snapshot(provider, observed_at=10, state=state, reason=reason, action=label)
    row = availability_document(snapshot, now=10, installed=True)
    assert row["action"] in {None, "Retry"}
    if row["status_text"]:
        assert "_" not in row["status_text"]
    if provider == "kilo":
        assert row["status_text"] == "Run kilo auth login in Terminal or add a Kilo API key in Settings > Providers, then Retry."


def test_a_failing_source_with_a_sign_in_reason_and_a_last_reading_is_not_red():
    lane = UsageLane("codex", "weekly", "Weekly", 30, 3000, "account", None, None, True, "fixture")
    snapshot = replace(failure_snapshot("codex", observed_at=10, state=ProviderSourceState.UNAVAILABLE,
                                        reason="authentication_required", action="Reconnect Codex"),
                       lanes=(lane,), read_at=5)
    row = availability_document(snapshot, now=10, installed=True)
    assert row["availability"] == "available"
    assert row["status_text"] == "Codex needs you to sign in again."


#: A reason code turned into words by swapping underscores or capitalising,
#: the fallback that showed "Cli session unavailable".
CODE_AS_WORDS = re.compile(r'reason\w*\b[^\n#]*\.(?:replace\(\s*"_"|capitalize\(\)|title\(\))')


def test_no_daemon_text_humanises_a_reason_code():
    offenders = [f"{path.name}:{number}" for path in sorted(SOURCE.rglob("*.py"))
                 for number, line in enumerate(path.read_text(encoding="utf-8").splitlines(), 1)
                 if CODE_AS_WORDS.search(line)]
    assert not offenders, f"use provider_availability.status_sentence instead: {offenders}"


def test_the_humanise_scan_catches_the_old_fallback():
    assert CODE_AS_WORDS.search('status_text=_CAUSES.get(reason, (reason or state).replace("_", " ").capitalize())')
    assert not CODE_AS_WORDS.search('status_text=status_sentence(reason or state, label)')


@pytest.mark.parametrize(("provider", "state", "reason"), [
    ("opencode", ProviderSourceState.UNSUPPORTED, "opencode_go_not_subscribed"),
    ("opencode", ProviderSourceState.UNSUPPORTED, "opencode_no_quota_source"),
    ("kiro", ProviderSourceState.UNSUPPORTED, "no_separable_quota"),
    ("kiro", ProviderSourceState.UNSUPPORTED, "cli_default_account_only"),
    ("gemini", ProviderSourceState.UNAVAILABLE, "code_assist_tier_ineligible"),
    ("gemini", ProviderSourceState.SOURCE_NOT_FOUND, "quota_license_required"),
])
def test_no_quota_source_is_neutral_with_no_button(provider, state, reason):
    snapshot = failure_snapshot(provider, observed_at=10, state=state, reason=reason, action="Retry")
    row = availability_document(snapshot, now=10, installed=True)
    assert row["availability"] == "available"
    assert row["action"] is None
    assert row["status_text"] == status_sentence(reason, provider_descriptor(provider).label)


def test_a_last_good_reading_does_not_turn_no_quota_into_a_failure():
    lane = UsageLane(provider_id="opencode", lane_id="rolling", label="5h", remaining_percent=40,
                     reset_at=None, scope="account", model=None, feature=None, bindable=True, source_id="go")
    answer = failure_snapshot("opencode", observed_at=10, state=ProviderSourceState.UNSUPPORTED,
                              reason="opencode_go_not_subscribed", action=None)
    previous = replace(answer, observed_at=5, state=ProviderSourceState.READY, reason_code=None, lanes=(lane,))
    merged = select_authoritative_snapshot((answer,), last_known_good=previous)
    assert merged.state is ProviderSourceState.UNSUPPORTED
    assert merged.lanes == ()
    assert not _snapshot_has_quota_source(merged)
    # Should an older path still wrap the answer as stale, it stays neutral.
    wrapped = replace(answer, state=ProviderSourceState.STALE, lanes=(lane,), action_label="Retry")
    assert not _snapshot_has_quota_source(wrapped)
    row = availability_document(wrapped, now=10, installed=True)
    assert row["availability"] == "available"
    assert row["action"] is None
