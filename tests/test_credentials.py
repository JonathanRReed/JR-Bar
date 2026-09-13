"""Credential reads are the one place this app can embarrass its user.

Two properties are non-negotiable: it never raises a Keychain dialog on a
background timer, and a secret never reaches a log, a repr, or a traceback.
"""

from __future__ import annotations

import json
import subprocess
from pathlib import Path

import pytest

from jrbar.credentials import (
    CLAUDE_CODE_KEYCHAIN,
    CodexTokens,
    CredentialOutcome,
    CredentialResult,
    KeychainConsentLedger,
    KeychainItem,
    read_codex_tokens,
    read_keychain_secret,
)


def _completed(returncode: int, stdout: str = "") -> subprocess.CompletedProcess:
    return subprocess.CompletedProcess(args=["security"], returncode=returncode, stdout=stdout, stderr="")


def test_background_reads_never_reach_the_keychain__and_2_more(tmp_path: Path) -> None:
    # --- scenario: background_reads_never_reach_the_keychain
    """The property that keeps this app off the 'why is it asking' list."""
    calls: list[KeychainItem] = []

    def runner(item):
        calls.append(item)
        return _completed(0, "secret-value")

    result = read_keychain_secret(
        CLAUDE_CODE_KEYCHAIN,
        allow_prompt=False,
        ledger=KeychainConsentLedger(tmp_path / "consent.json"),
        runner=runner,
    )

    assert result.outcome is CredentialOutcome.PROMPT_NOT_ALLOWED
    assert calls == [], "a background read reached the Keychain"
    assert result.secret is None

    # --- scenario: explicit_read_returns_the_secret
    result = read_keychain_secret(
        CLAUDE_CODE_KEYCHAIN,
        allow_prompt=True,
        ledger=KeychainConsentLedger(tmp_path / "consent.json"),
        runner=lambda item: _completed(0, "secret-value\n"),
    )
    assert result.ok
    assert result.secret == "secret-value"

    # --- scenario: a_denial_is_not_retried_on_the_next_tick
    """"Deny" is an answer. Asking again in 30 seconds is harassment."""
    ledger = KeychainConsentLedger(tmp_path / "consent.json")
    attempts = 0

    def runner(item):
        nonlocal attempts
        attempts += 1
        return _completed(128)  # user dismissed the dialog

    first = read_keychain_secret(
        CLAUDE_CODE_KEYCHAIN, allow_prompt=True, ledger=ledger, runner=runner, now=1_000.0
    )
    assert first.outcome is CredentialOutcome.DENIED
    assert first.retry_at is not None and first.retry_at > 1_000.0

    second = read_keychain_secret(
        CLAUDE_CODE_KEYCHAIN, allow_prompt=True, ledger=ledger, runner=runner, now=1_060.0
    )
    assert second.outcome is CredentialOutcome.COOLING_DOWN
    assert attempts == 1, "prompted again while cooling down"



def test_the_cooldown_survives_a_restart__and_2_more(tmp_path: Path) -> None:
    # --- scenario: the_cooldown_survives_a_restart
    """A fresh ledger object reads the same file -- relaunching is not consent."""
    path = tmp_path / "consent.json"
    KeychainConsentLedger(path).record_denial(CLAUDE_CODE_KEYCHAIN.service, 1_000.0)

    result = read_keychain_secret(
        CLAUDE_CODE_KEYCHAIN,
        allow_prompt=True,
        ledger=KeychainConsentLedger(path),
        runner=lambda item: pytest.fail("prompted after a restart"),
        now=1_500.0,
    )
    assert result.outcome is CredentialOutcome.COOLING_DOWN

    # --- scenario: repeated_denials_escalate_the_cooldown
    ledger = KeychainConsentLedger(tmp_path / "consent.json")
    first = ledger.record_denial("svc", 0.0)
    second = ledger.record_denial("svc", 0.0)
    assert second > first, "a second denial must back off harder"

    # --- scenario: success_clears_the_cooldown
    path = tmp_path / "consent.json"
    ledger = KeychainConsentLedger(path)
    ledger.record_denial(CLAUDE_CODE_KEYCHAIN.service, 1_000.0)

    read_keychain_secret(
        CLAUDE_CODE_KEYCHAIN,
        allow_prompt=True,
        ledger=ledger,
        runner=lambda item: _completed(0, "ok"),
        now=999_999.0,
    )
    assert ledger.retry_at(CLAUDE_CODE_KEYCHAIN.service, 1_000_000.0) is None



def test_a_secret_never_appears_in_a_repr() -> None:
    """reprs end up in tracebacks, logs and pytest output."""
    result = CredentialResult(CredentialOutcome.OK, secret="hunter2")
    assert "hunter2" not in repr(result)
    assert "redacted" in repr(result)

    tokens = CodexTokens(
        access_token="tok-secret",
        account_id="acct-1",
        refresh_token="refresh-secret",
        last_refresh=None,
    )
    rendered = repr(tokens)
    assert "tok-secret" not in rendered and "refresh-secret" not in rendered
    assert "acct-1" in rendered, "non-secret identity is useful in diagnostics"


def test_codex_tokens_read_from_disk__and_2_more(tmp_path: Path) -> None:
    # --- scenario: codex_tokens_read_from_disk
    path = tmp_path / "auth.json"
    path.write_text(
        json.dumps(
            {
                "auth_mode": "oauth",
                "last_refresh": "2026-08-13T00:00:00Z",
                "tokens": {
                    "access_token": "at",
                    "account_id": "acct",
                    "refresh_token": "rt",
                },
            }
        )
    )
    tokens = read_codex_tokens(path)
    assert tokens is not None
    assert tokens.access_token == "at"
    assert tokens.account_id == "acct"

    # --- scenario: malformed_codex_auth_is_absence_not_a_crash
    for payload in [
        "{}",
        '{"tokens": {}}',
        '{"tokens": {"access_token": ""}}',
        '{"tokens": []}',
        "not json at all",
    ]:
        path = tmp_path / "auth.json"
        path.write_text(payload)
        assert read_codex_tokens(path) is None

    # --- scenario: missing_codex_auth_is_absence
    assert read_codex_tokens(tmp_path / "nope.json") is None



# --- Standing consent: background reads only after a granted foreground one


def _ok_runner(item):
    import subprocess

    return subprocess.CompletedProcess([], 0, stdout="secret-payload\n", stderr="")


def test_background_read_is_refused_without_a_standing_grant__and_2_more(tmp_path) -> None:
    # --- scenario: background_read_is_refused_without_a_standing_grant
    ledger = KeychainConsentLedger(tmp_path / "consent.json")

    def runner(item):
        raise AssertionError("no grant on record: security must not run")

    result = read_keychain_secret(
        CLAUDE_CODE_KEYCHAIN,
        allow_prompt=False,
        ledger=ledger,
        runner=runner,
    )
    assert result.outcome is CredentialOutcome.PROMPT_NOT_ALLOWED

    # --- scenario: a_granted_foreground_read_authorizes_background_reads
    ledger = KeychainConsentLedger(tmp_path / "consent.json")
    first = read_keychain_secret(
        CLAUDE_CODE_KEYCHAIN,
        allow_prompt=True,
        ledger=ledger,
        runner=_ok_runner,
    )
    assert first.ok
    assert ledger.standing_grant(CLAUDE_CODE_KEYCHAIN.service)

    background = read_keychain_secret(
        CLAUDE_CODE_KEYCHAIN,
        allow_prompt=False,
        ledger=ledger,
        runner=_ok_runner,
    )
    assert background.ok
    assert background.secret == "secret-payload"

    # --- scenario: a_denial_revokes_the_standing_grant
    import subprocess

    ledger = KeychainConsentLedger(tmp_path / "consent.json")
    ledger.record_success(CLAUDE_CODE_KEYCHAIN.service, 1_000.0)

    def cancels(item):
        return subprocess.CompletedProcess([], 128, stdout="", stderr="")

    denied = read_keychain_secret(
        CLAUDE_CODE_KEYCHAIN,
        allow_prompt=True,
        ledger=ledger,
        runner=cancels,
        now=2_000.0,
    )
    assert denied.outcome is CredentialOutcome.DENIED
    assert not ledger.standing_grant(CLAUDE_CODE_KEYCHAIN.service), (
        "a revoked grant falls back to foreground-only"
    )



def test_a_background_read_cannot_park_a_worker_thread_for_half_a_minute(tmp_path):
    """A dialog the user must answer legitimately takes seconds. A
    BACKGROUND read must not wait on one at all -- 30s of a stalled
    worker was the hazard (2026-08-27 mining)."""
    import inspect

    from jrbar import credentials as module

    seen = {}

    def runner(item, *, timeout):
        seen["timeout"] = timeout
        import subprocess

        return subprocess.CompletedProcess([], 1, stdout="", stderr="")

    ledger = KeychainConsentLedger(tmp_path / "consent.json")
    ledger.record_success(CLAUDE_CODE_KEYCHAIN.service, 1_000.0)
    original = module._run_security
    module._run_security = runner
    try:
        read_keychain_secret(
            CLAUDE_CODE_KEYCHAIN, allow_prompt=False, ledger=ledger
        )
        background = seen["timeout"]
        read_keychain_secret(CLAUDE_CODE_KEYCHAIN, allow_prompt=True)
        foreground = seen["timeout"]
    finally:
        module._run_security = original

    assert background <= 5.0, "no dialog is expected, so do not wait for one"
    assert foreground >= background, "a real prompt gets room to be answered"
    source = inspect.getsource(module)
    assert "_SECURITY_BACKGROUND_TIMEOUT_SECONDS" in source
