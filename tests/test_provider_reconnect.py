"""provider_reconnect: honest repair results, failure gates, transitions."""

from __future__ import annotations

import json

from jrbar.provider_reconnect import (
    TRANSIENT_BACKOFF_SECONDS,
    FailureGate,
    RepairOutcome,
    codex_activity_report,
    codex_app_server_probe,
    connection_loss_transitions,
    credential_fingerprint,
    grok_auth_status,
    newest_codex_rollout_age,
    note_failure,
    reconnect_provider,
    repair_claude_credential,
    repair_grok_credential,
    should_collect,
)


class FakeStore:
    def __init__(self, secrets=None):
        self.secrets = dict(secrets or {})
        self.deleted = []
        self.stored = []

    def get(self, provider_id, account):
        secret = self.secrets.get((provider_id, account))

        class Read:
            pass

        read = Read()
        read.available = secret is not None
        read.secret = secret
        return read

    def set(self, provider_id, account, secret):
        self.secrets[(provider_id, account)] = secret
        self.stored.append((provider_id, account))

    def delete(self, provider_id, account):
        self.deleted.append((provider_id, account))
        return self.secrets.pop((provider_id, account), None) is not None


def write_grok_auth(home, *, expires_at=None, email="jr@example.com"):
    grok_dir = home / ".grok"
    grok_dir.mkdir(parents=True, exist_ok=True)
    entry = {"key": "tok-" + "x" * 24, "email": email}
    if expires_at is not None:
        entry["expires_at"] = expires_at
    (grok_dir / "auth.json").write_text(
        json.dumps({"https://auth.x.ai::abc": entry}), encoding="utf-8"
    )


# --- grok ------------------------------------------------------------------


def test_grok_auth_status_live_expired_missing__and_2_more(tmp_path) -> None:
    # --- scenario: grok_auth_status_live_expired_missing
    assert grok_auth_status(tmp_path, 1000.0)[0] == "missing"
    write_grok_auth(tmp_path, expires_at=500.0)
    assert grok_auth_status(tmp_path, 1000.0)[0] == "expired"
    write_grok_auth(tmp_path, expires_at=2000.0)
    status, email = grok_auth_status(tmp_path, 1000.0)
    assert status == "ok"
    assert email == "jr@example.com"

    # --- scenario: repair_grok_clears_wedged_token_when_cli_is_signed_in
    write_grok_auth(tmp_path)
    store = FakeStore({("grok", "token"): "stale-stored-token-000000"})
    result = repair_grok_credential(store, home=tmp_path, now=1000.0)
    assert result.outcome is RepairOutcome.REPAIRED
    assert result.changed
    assert ("grok", "token") in store.deleted
    assert "signed in" in result.message

    # --- scenario: repair_grok_expired_names_grok_login
    write_grok_auth(tmp_path, expires_at=1.0)
    store = FakeStore()
    result = repair_grok_credential(store, home=tmp_path, now=1000.0)
    assert result.outcome is RepairOutcome.NEEDS_SIGN_IN
    assert "grok login" in result.message



# --- claude ----------------------------------------------------------------


def claude_payload(*, access="tok", expires_at=None, refresh="refresh-token"):
    oauth = {"accessToken": access, "refreshToken": refresh}
    if expires_at is not None:
        oauth["expiresAt"] = expires_at
    return json.dumps({"claudeAiOauth": oauth})


def test_repair_claude_names_refresh_token_only_shape_as_provider_owned__and_2_more() -> None:
    # --- scenario: repair_claude_names_refresh_token_only_shape_as_provider_owned
    store = FakeStore()
    result = repair_claude_credential(
        store,
        now=1000.0,
        keychain_payload_reader=lambda: claude_payload(access=""),
    )
    assert result.outcome is RepairOutcome.NEEDS_PROVIDER_REFRESH
    assert not store.stored
    assert "Claude Code owns" in result.message
    assert "sign in" not in result.message.lower()

    # --- scenario: repair_claude_rejects_an_empty_signed_out_shape
    store = FakeStore()
    result = repair_claude_credential(
        store,
        now=1000.0,
        keychain_payload_reader=lambda: claude_payload(access="", refresh=""),
    )
    assert result.outcome is RepairOutcome.NEEDS_SIGN_IN
    assert not store.stored
    assert "sign in" in result.message.lower()

    # --- scenario: repair_claude_stores_fresh_token_and_reports_change
    store = FakeStore({("claude", "oauth-token"): "old-token"})
    result = repair_claude_credential(
        store,
        now=1000.0,
        keychain_payload_reader=lambda: claude_payload(access="b" * 32),
    )
    assert result.outcome is RepairOutcome.REPAIRED
    assert result.changed
    assert store.secrets[("claude", "oauth-token")] == "b" * 32



def test_repair_claude_same_token_is_already_healthy():
    token = "c" * 32
    store = FakeStore({("claude", "oauth-token"): token})
    result = repair_claude_credential(
        store,
        now=1000.0,
        keychain_payload_reader=lambda: claude_payload(access=token),
    )
    assert result.outcome is RepairOutcome.ALREADY_HEALTHY
    assert not result.changed


# --- codex -----------------------------------------------------------------


def make_rollout(home, day, name, mtime):
    directory = home / ".codex" / "sessions" / day
    directory.mkdir(parents=True, exist_ok=True)
    path = directory / name
    path.write_text("{}\n", encoding="utf-8")
    import os

    os.utime(path, (mtime, mtime))
    return path


def test_newest_codex_rollout_age(tmp_path):
    assert newest_codex_rollout_age(tmp_path, 1000.0) is None
    make_rollout(tmp_path, "2026/08/20", "rollout-old.jsonl", 100.0)
    make_rollout(tmp_path, "2026/08/26", "rollout-new.jsonl", 900.0)
    assert newest_codex_rollout_age(tmp_path, 1000.0) == 100.0


def test_codex_activity_report_shapes(tmp_path):
    assert "Install the Codex CLI" in codex_activity_report(tmp_path, 1000.0)
    (tmp_path / ".codex" / "sessions").mkdir(parents=True)
    assert "no completed sessions" in codex_activity_report(tmp_path, 1000.0)
    now = 1_000_000.0
    make_rollout(tmp_path, "2026/08/26", "rollout-fresh.jsonl", now - 120.0)
    assert "rescanning now" in codex_activity_report(tmp_path, now).lower()
    make_rollout(tmp_path, "2026/08/26", "rollout-fresh.jsonl", now - 72 * 3600.0)
    report = codex_activity_report(tmp_path, now)
    assert "3 d old" in report
    assert "completion" in report


def test_codex_app_server_probe_parses_replies():
    lines = [
        json.dumps(
            {"jsonrpc": "2.0", "id": 1, "result": {"userAgent": "codex/0.149.1 mac"}}
        ),
        json.dumps(
            {
                "jsonrpc": "2.0",
                "id": 2,
                "result": {
                    "rateLimits": {
                        "primary": {"used_percent": 4.0, "resets_at": 1788286790}
                    }
                },
            }
        ),
        json.dumps(
            {"jsonrpc": "2.0", "id": 3, "result": {"account": {"email": "a@b.c"}}}
        ),
    ]
    probe = codex_app_server_probe(runner=lambda: "\n".join(lines))
    assert probe == {
        "authenticated": True,
        "plan": None,
        "account_id": None,
        "windows": [
            {
                "label": "primary",
                "used_percent": 4.0,
                "window_minutes": None,
                "resets_at": 1788286790,
                "limit_id": None,
                "limit_name": None,
                "account_limit": True,
                "source_id": "codex-app-server",
            }
        ],
        "limit_ids": (),
        "used_percent": 4.0,
        "resets_at": 1788286790.0,
        "window_minutes": None,
        "version": "0.149.1",
    }
    assert codex_app_server_probe(runner=lambda: None) is None
    assert codex_app_server_probe(runner=lambda: "not json") is None


def test_codex_app_server_probe_keeps_transport_open_until_rate_limits_arrive(
    monkeypatch,
):
    import io
    import shutil
    import subprocess

    lines = [
        json.dumps(
            {"jsonrpc": "2.0", "id": 1, "result": {"userAgent": "codex/0.149.1 mac"}}
        ),
        json.dumps(
            {
                "jsonrpc": "2.0",
                "id": 3,
                "result": {"account": {"email": "fixture@example.invalid"}},
            }
        ),
        json.dumps(
            {
                "jsonrpc": "2.0",
                "id": 2,
                "result": {
                    "rateLimits": {
                        "primary": {
                            "usedPercent": 95.0,
                            "resetsAt": 1788286790,
                            "windowDurationMins": 10080,
                        }
                    }
                },
            }
        ),
    ]

    class RecordingInput(io.StringIO):
        def close(self):
            self.was_closed = True

    class FixtureProcess:
        def __init__(self):
            self.stdin = RecordingInput()
            self.stdout = io.StringIO("\n".join(lines) + "\n")
            self.terminated = False

        def terminate(self):
            self.terminated = True

        def wait(self, timeout=None):
            del timeout
            return 0

        def kill(self):
            self.terminated = True

    process = FixtureProcess()
    command: list[str] = []

    def popen(arguments, **_kwargs):
        command.extend(arguments)
        return process

    # The probe resolves `codex` before it spawns anything, and a machine
    # without one (GitHub's runner) returns None there. Resolve it to a
    # fixture path so the transport is what this test exercises.
    monkeypatch.setattr(
        shutil, "which", lambda _executable, *, path=None: "/fixture/bin/codex"
    )
    monkeypatch.setattr(subprocess, "Popen", popen)

    probe = codex_app_server_probe(timeout_seconds=1.0)

    assert command[0] == "/fixture/bin/codex"
    assert probe == {
        "authenticated": True,
        "plan": None,
        "account_id": None,
        "windows": [
            {
                "label": "primary",
                "used_percent": 95.0,
                "window_minutes": 10080,
                "resets_at": 1788286790,
                "limit_id": None,
                "limit_name": None,
                "account_limit": True,
                "source_id": "codex-app-server",
            }
        ],
        "limit_ids": (),
        "used_percent": 95.0,
        "resets_at": 1788286790.0,
        "window_minutes": 10080,
        "version": "0.149.1",
    }
    assert '"method": "account/rateLimits/read"' in process.stdin.getvalue()
    assert process.terminated is True


def test_codex_app_server_probe_finds_homebrew_under_launchd_path(monkeypatch):
    import io
    import shutil
    import subprocess

    searched: dict[str, str] = {}

    def find(executable, *, path):
        searched["executable"] = executable
        searched["path"] = path
        return "/opt/homebrew/bin/codex"

    lines = [
        json.dumps(
            {"jsonrpc": "2.0", "id": 1, "result": {"userAgent": "codex/1.0"}}
        ),
        json.dumps(
            {
                "jsonrpc": "2.0",
                "id": 2,
                "result": {"rateLimits": {"primary": {"usedPercent": 5.0}}},
            }
        ),
        json.dumps(
            {"jsonrpc": "2.0", "id": 3, "result": {"account": {"email": "x"}}}
        ),
    ]

    class FixtureProcess:
        def __init__(self):
            self.stdin = io.StringIO()
            self.stdout = io.StringIO("\n".join(lines) + "\n")

        def terminate(self):
            pass

        def wait(self, timeout=None):
            del timeout
            return 0

        def kill(self):
            pass

    command: list[str] = []

    def popen(arguments, **_kwargs):
        command.extend(arguments)
        return FixtureProcess()

    monkeypatch.setenv("PATH", "/usr/bin:/bin:/usr/sbin:/sbin")
    monkeypatch.setattr(shutil, "which", find)
    monkeypatch.setattr(subprocess, "Popen", popen)

    probe = codex_app_server_probe(timeout_seconds=1.0)

    assert probe is not None and probe["used_percent"] == 5.0
    assert searched["executable"] == "codex"
    assert "/opt/homebrew/bin" in searched["path"].split(":")
    assert command[0] == "/opt/homebrew/bin/codex"


# --- gates -----------------------------------------------------------------


def test_transient_gate_backs_off_and_forced_bypasses__and_1_more() -> None:
    # --- scenario: transient_gate_backs_off_and_forced_bypasses
    gate = FailureGate()
    gate = note_failure(gate, now=0.0, terminal=False, fingerprint=None)
    assert gate.retry_at == TRANSIENT_BACKOFF_SECONDS[0]
    assert not should_collect(gate, now=1.0, fingerprint=None, forced=False)
    assert should_collect(gate, now=1.0, fingerprint=None, forced=True)
    assert should_collect(
        gate, now=TRANSIENT_BACKOFF_SECONDS[0], fingerprint=None, forced=False
    )
    for _ in range(10):
        gate = note_failure(gate, now=0.0, terminal=False, fingerprint=None)
    assert gate.retry_at == TRANSIENT_BACKOFF_SECONDS[-1]

    # --- scenario: terminal_gate_lifts_on_credential_change
    fingerprint = (("x", 1, 2, 3),)
    gate = note_failure(
        FailureGate(), now=0.0, terminal=True, fingerprint=fingerprint
    )
    assert not should_collect(gate, now=10.0, fingerprint=fingerprint, forced=False)
    changed = (("x", 9, 9, 9),)
    assert should_collect(gate, now=10.0, fingerprint=changed, forced=False)
    # Terminal auth failures retry only after external evidence changes.
    assert not should_collect(
        gate,
        now=TRANSIENT_BACKOFF_SECONDS[-1] + 1.0,
        fingerprint=fingerprint,
        forced=False,
    )



def test_credential_fingerprint_tracks_the_source_file(tmp_path):
    assert credential_fingerprint(tmp_path, "grok") is None
    write_grok_auth(tmp_path)
    first = credential_fingerprint(tmp_path, "grok")
    assert first is not None
    write_grok_auth(tmp_path, email="other@example.com")
    assert credential_fingerprint(tmp_path, "grok") != first


# --- transitions -----------------------------------------------------------


class Snap:
    def __init__(self, provider_id, state_value):
        class State:
            pass

        self.provider_id = provider_id
        self.state = State()
        self.state.value = state_value


def test_connection_loss_transitions_edge_only():
    before = (Snap("grok", "ready"), Snap("claude", "stale"), Snap("codex", "error"))
    after = (
        Snap("grok", "needs_sign_in"),
        Snap("claude", "rate_limited"),
        Snap("codex", "error"),
    )
    events = connection_loss_transitions(before, after)
    assert events == (
        ("grok:needs_sign_in", "grok", "needs_sign_in"),
        ("claude:rate_limited", "claude", "rate_limited"),
    )
    # Deduped by key; a still-broken provider announces nothing new.
    assert (
        connection_loss_transitions(
            before, after, seen_keys=frozenset(k for k, _p, _s in events)
        )
        == ()
    )


def test_repair_grok_defers_to_a_server_rejection(tmp_path):
    """The server is the authority on a token, not the file's own
    expiry stamp. Clicked live three times (2026-08-26): the file held
    a valid-looking session, the server 401'd it, and every click said
    "signed in — refreshing now" while nothing could change."""
    write_grok_auth(tmp_path)
    store = FakeStore()
    result = repair_grok_credential(
        store, home=tmp_path, now=1000.0, server_rejected=True
    )
    assert result.outcome is RepairOutcome.NEEDS_SIGN_IN
    assert "grok login" in result.message
    assert "rejecting" in result.message
    # Without the rejection context the healthy message stands.
    healthy = repair_grok_credential(store, home=tmp_path, now=1000.0)
    assert healthy.outcome in (
        RepairOutcome.REPAIRED,
        RepairOutcome.ALREADY_HEALTHY,
    )


def test_the_claude_gate_can_lift_when_the_keychain_item_changes__and_1_more() -> None:
    # --- scenario: the_claude_gate_can_lift_when_the_keychain_item_changes
    """The gate fingerprinted ~/.claude/.credentials.json, which does not
    exist on a Keychain-only machine -- so None == None forever and a
    fresh `claude login` was invisible to it."""
    from jrbar import provider_reconnect

    provider_reconnect._KEYCHAIN_FINGERPRINT_CACHE.clear()
    before = provider_reconnect.keychain_fingerprint("svc", now=0.0)
    provider_reconnect._KEYCHAIN_FINGERPRINT_CACHE["svc"] = (
        0.0,
        (("keychain", "svc", "STAMP-A", "CREATED"),),
    )
    cached = provider_reconnect.keychain_fingerprint("svc", now=30.0)
    assert cached == (("keychain", "svc", "STAMP-A", "CREATED"),), (
        "probes are throttled to 60s"
    )
    provider_reconnect._KEYCHAIN_FINGERPRINT_CACHE["svc"] = (
        0.0,
        (("keychain", "svc", "STAMP-B", "CREATED"),),
    )
    assert provider_reconnect.keychain_fingerprint("svc", now=30.0) != cached
    assert isinstance(before, tuple)

    # --- scenario: a_stored_expiry_drives_read_only_sync
    from jrbar.provider_reconnect import claude_token_is_stale

    class Store:
        def __init__(self, value):
            self.value = value

        def get(self, provider_id, account):
            class Read:
                available = self.value is not None
                secret = self.value

            return Read()

    assert claude_token_is_stale(Store(None), now=1000.0), "unknown = stale"
    assert claude_token_is_stale(Store("1200"), now=1000.0), "inside the margin"
    assert not claude_token_is_stale(Store("9000"), now=1000.0)


# --- reconnect_provider: the Usage Center's "Re-sign in" --------------------
#
# The button is always on the card, so the answer is always honest: a real
# re-pull where JR-Bar can reach the sign-in, the provider's own remedy
# where only its CLI/app can mint one.


def test_reconnect_grok_clears_the_wedge_and_reports(tmp_path):
    write_grok_auth(tmp_path)
    store = FakeStore({("grok", "token"): "stale-stored-token-000000"})
    result = reconnect_provider(
        "grok", credential_store=store, home=tmp_path, now=1000.0
    )
    assert result.changed
    assert ("grok", "token") in store.deleted
    assert "signed in" in result.message
    assert result.sign_in_url is None


def test_reconnect_grok_names_grok_login_when_the_cli_is_out(tmp_path):
    write_grok_auth(tmp_path, expires_at=1.0)
    result = reconnect_provider(
        "grok", credential_store=FakeStore(), home=tmp_path, now=1000.0
    )
    assert not result.changed
    assert "grok login" in result.message


def test_reconnect_grok_defers_to_the_server_rejection(tmp_path):
    # reason_code="authentication_required" is the collector's last 401:
    # the file looks live, the server says otherwise, so the answer must
    # be `grok login`, not "signed in — refreshing now".
    write_grok_auth(tmp_path)
    result = reconnect_provider(
        "grok",
        reason_code="authentication_required",
        credential_store=FakeStore(),
        home=tmp_path,
        now=1000.0,
    )
    assert "grok login" in result.message
    assert "rejecting" in result.message


def test_reconnect_claude_stores_the_fresh_keychain_token():
    store = FakeStore()
    result = reconnect_provider(
        "claude",
        credential_store=store,
        now=1000.0,
        keychain_payload_reader=lambda: claude_payload(access="d" * 32),
    )
    assert result.changed
    assert store.secrets[("claude", "oauth-token")] == "d" * 32


def test_reconnect_claude_provider_owned_shape_is_not_a_sign_in_ask():
    # A refresh-token-only payload means Claude Code itself owns the
    # renewal; the honest message says so instead of asking the user to
    # sign in somewhere.
    result = reconnect_provider(
        "claude",
        credential_store=FakeStore(),
        now=1000.0,
        keychain_payload_reader=lambda: claude_payload(access=""),
    )
    assert not result.changed
    assert "Claude Code owns" in result.message


def test_reconnect_codex_reports_the_evidence_it_found(tmp_path):
    result = reconnect_provider(
        "codex", credential_store=FakeStore(), home=tmp_path, now=1000.0
    )
    assert "Codex" in result.message
    assert not result.changed
    assert result.sign_in_url is None


def test_reconnect_devin_reimports_the_consented_session():
    result = reconnect_provider(
        "devin",
        credential_store=FakeStore(),
        session_importer=lambda provider: "Signed in as your Firefox "
        "session — no API key needed. Refreshing usage now.",
    )
    assert result.changed
    assert "Signed in" in result.message


def test_reconnect_devin_without_a_session_points_at_the_page():
    result = reconnect_provider(
        "devin",
        credential_store=FakeStore(),
        session_importer=lambda provider: None,
    )
    assert not result.changed
    assert result.sign_in_url == "https://app.devin.ai"
    assert "app.devin.ai" in result.message


def test_reconnect_openai_takes_the_clipboard_key_on_click():
    store = FakeStore()
    result = reconnect_provider(
        "openai-api",
        credential_store=store,
        clipboard_reader=lambda: "sk-admin-" + "x" * 24,
    )
    assert result.changed
    assert store.secrets[("openai-api", "admin-key")].startswith("sk-admin-")
    # Prose on the clipboard is not a credential: the honest ask names
    # the Admin-keys page.
    again = reconnect_provider(
        "openai-api",
        credential_store=FakeStore(),
        clipboard_reader=lambda: "not a key, just text",
    )
    assert not again.changed
    assert "Admin" in again.message


def test_reconnect_cli_owned_providers_name_the_owner():
    gemini = reconnect_provider("gemini", credential_store=FakeStore())
    assert "gemini" in gemini.message.lower()
    assert "cli" in gemini.message.lower()
    assert gemini.sign_in_url is None
    cursor = reconnect_provider("cursor", credential_store=FakeStore())
    assert "Cursor" in cursor.message
    assert cursor.sign_in_url == "https://cursor.com/settings"
    opencode = reconnect_provider("opencode", credential_store=FakeStore())
    assert "opencode auth login" in opencode.message

