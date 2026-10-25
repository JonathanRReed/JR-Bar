import json
import os
from pathlib import Path

import pytest

from jrbar.provider_auth_paths import gemini_auth_path, grok_auth_path, kilo_auth_path, kimi_code_home


@pytest.mark.parametrize("variable,resolve,suffix", [
    ("GROK_HOME", grok_auth_path, "auth.json"),
    ("GEMINI_CLI_HOME", gemini_auth_path, ".gemini/oauth_creds.json"),
    ("KIMI_CODE_HOME", kimi_code_home, "."),
    ("XDG_DATA_HOME", kilo_auth_path, "kilo/auth.json"),
])
def test_absolute_override_is_used_and_relative_override_is_refused(tmp_path, monkeypatch, variable, resolve, suffix):
    monkeypatch.delenv(variable, raising=False)
    default = resolve(tmp_path)
    monkeypatch.setenv(variable, str(tmp_path / "alternate"))
    assert resolve(tmp_path) == tmp_path / "alternate" / suffix
    monkeypatch.setenv(variable, "relative-location")
    assert resolve(tmp_path) == default


def test_kilo_collector_reads_xdg_auth_without_a_stored_key(tmp_path, monkeypatch):
    from types import SimpleNamespace

    from jrbar.provider_usage_kilo import collect_kilo
    from tests.test_provider_usage_kilo import batch

    monkeypatch.setenv("XDG_DATA_HOME", str(tmp_path / "alternate"))
    path = kilo_auth_path(tmp_path)
    path.parent.mkdir(parents=True)
    path.write_text(json.dumps({"kilo": {"access": "synthetic-alternate"}}))
    seen = []

    def request(_method, _url, **kw):
        seen.append(kw["headers"]["Authorization"])
        return batch()

    result = collect_kilo(SimpleNamespace(enabled=True, usage_consented=True, source_instance_id="default"),
                          observed_at=100, credentials=None, home=tmp_path, http_json=request)
    assert result.state.value == "ready"
    assert seen == ["Bearer synthetic-alternate"]


def test_moved_grok_auth_drives_reader_status_and_change_watch(tmp_path, monkeypatch):
    from jrbar.provider_reconnect import credential_fingerprint, grok_auth_status
    from jrbar.provider_usage_collectors import _read_grok_auth

    monkeypatch.setenv("GROK_HOME", str(tmp_path / "alternate"))
    path = grok_auth_path(tmp_path)
    path.parent.mkdir()
    path.write_text(json.dumps({"https://auth.x.ai::cli": {"key": "synthetic-access", "expires_at": 5000}}))
    assert _read_grok_auth(tmp_path, 1000).credential == ("synthetic-access", None)
    assert grok_auth_status(tmp_path, 1000) == ("ok", None)
    previous = credential_fingerprint(tmp_path, "grok")
    path.unlink()
    assert credential_fingerprint(tmp_path, "grok") != previous
    assert grok_auth_status(tmp_path, 1000) == ("missing", None)


def test_gemini_reader_and_kimi_reader_use_moved_roots(tmp_path, monkeypatch):
    from jrbar.provider_usage_collectors import _read_gemini_oauth
    from jrbar.provider_usage_kimi import _cli

    monkeypatch.setenv("GEMINI_CLI_HOME", str(tmp_path / "gemini-alternate"))
    gemini = gemini_auth_path(tmp_path)
    gemini.parent.mkdir(parents=True)
    gemini.write_text(json.dumps({"access_token": "synthetic-access", "email": "fixture@example.test"}))
    payload, email = _read_gemini_oauth(tmp_path)
    assert payload["access_token"] == "synthetic-access"
    assert email == "fixture@example.test"
    monkeypatch.setenv("KIMI_CODE_HOME", str(tmp_path / "kimi-alternate"))
    kimi = kimi_code_home(tmp_path)
    (kimi / "credentials").mkdir(parents=True)
    (kimi / "credentials/kimi-code.json").write_text(json.dumps({"access_token": "synthetic-access", "expires_at": 5000}))
    (kimi / "device_id").write_text("synthetic-device")
    token, headers = _cli(tmp_path, 1000)
    assert token == "synthetic-access"
    assert headers["X-Msh-Device-Id"] == "synthetic-device"


@pytest.mark.parametrize("app,provider,surface", [
    ("Cursor.app", "cursor", "ide"), ("OpenCode.app", "opencode", "desktop"),
    ("Gemini.app", "google", "gemini-desktop"),
    ("Antigravity.app", "google", "antigravity-desktop"),
])
def test_inventory_finds_user_applications(tmp_path, app, provider, surface):
    from jrbar.installed_agent_inventory import InventoryRoot, collect_installed_agent_inventory

    (tmp_path / "Applications" / app).mkdir(parents=True)
    result = collect_installed_agent_inventory(
        (InventoryRoot("home", tmp_path, frozenset({os.getuid()})),), path_dirs=())
    found = [row for row in result.reduction.observations
             if row.key.provider_id == provider and row.key.surface_id == surface]
    assert len(found) == 1
    assert found[0].presence.value == "installed"


@pytest.mark.parametrize("location", [".openclaw", ".config/openclaw"])
def test_inventory_accepts_both_openclaw_config_locations(tmp_path, location):
    from jrbar.installed_agent_inventory import InventoryRoot, collect_installed_agent_inventory

    (tmp_path / location).mkdir(parents=True)
    result = collect_installed_agent_inventory(
        (InventoryRoot("home", tmp_path, frozenset({os.getuid()})),), path_dirs=())
    found = next(row for row in result.reduction.observations if row.key.provider_id == "openclaw")
    assert found.presence.value == "configured"


def test_user_antigravity_path_still_requires_signed_running_code(tmp_path, monkeypatch):
    from jrbar import antigravity_process_identity as identity

    path = tmp_path / "Applications/Antigravity.app/Contents/Resources/bin/language_server"
    path.parent.mkdir(parents=True)
    path.write_bytes(b"synthetic executable")
    monkeypatch.setattr(Path, "home", lambda: tmp_path)
    monkeypatch.setattr(identity, "_process_facts", lambda _: (str(path), os.getuid(), 100, 0))
    monkeypatch.setattr(identity, "_running_process_is_trusted", lambda _: False)
    assert identity._canonical_language_server(str(path))
    assert identity.verified_antigravity_process_identity(1234) is None
    monkeypatch.setattr(identity, "_running_process_is_trusted", lambda _: True)
    assert identity.verified_antigravity_process_identity(1234) == (1234, str(path), os.getuid(), 100, 0)
    assert not identity._canonical_language_server(str(tmp_path / "language_server"))


def test_cli_mode_of_verified_antigravity_server_can_supply_same_quota_rpc(tmp_path):
    from jrbar import provider_usage_collectors as collectors
    from jrbar.provider_usage_settings import default_provider_usage_settings

    collectors._cached_antigravity_connection.clear()
    identity = (1234, "/Applications/Antigravity.app/Contents/Resources/bin/language_server", os.getuid(), 100, 0)
    def run(args, timeout):
        if args[0] == "ps":
            return f"1234 {identity[1]} --agy_acp_server --localharness_external --csrf_token synthetic-csrf\n"
        return "server 1234 user 1u IPv4 0 0t0 TCP 127.0.0.1:44556 (LISTEN)\n"

    requests = []
    def request(_method, url, **kwargs):
        requests.append(url)
        return {"groups": [{"displayName": "Gemini", "buckets": [
            {"displayName": "Weekly", "bucketId": "weekly", "remaining": {"remainingFraction": 0.9}}]}]}

    try:
        snapshot = collectors.collect_antigravity(default_provider_usage_settings().preference("antigravity"),
            observed_at=1000, home=tmp_path, command_runner=run, http_json=request,
            process_identity_resolver=lambda pid: identity if pid == 1234 else None)
        assert snapshot.state.value == "ready"
        assert snapshot.lanes[0].remaining_percent == 90
        assert requests == ["http://127.0.0.1:44556/exa.language_server_pb.LanguageServerService/RetrieveUserQuotaSummary"]
    finally:
        collectors._cached_antigravity_connection.clear()


@pytest.mark.parametrize("variable,resolve,relative", [
    ("GROK_HOME", grok_auth_path, ".grok/auth.json"),
    ("GEMINI_CLI_HOME", gemini_auth_path, ".gemini/oauth_creds.json"),
    ("KIMI_CODE_HOME", kimi_code_home, ".kimi-code/credentials/kimi-code.json"),
    ("XDG_DATA_HOME", kilo_auth_path, ".local/share/kilo/auth.json"),
])
def test_missing_override_also_checks_conventional_auth(tmp_path, monkeypatch, variable, resolve, relative):
    monkeypatch.setenv(variable, str(tmp_path / "unused"))
    conventional = tmp_path / relative
    conventional.parent.mkdir(parents=True)
    conventional.write_text("{}")
    selected = resolve(tmp_path)
    if variable == "KIMI_CODE_HOME":
        selected /= "credentials/kimi-code.json"
    assert selected == conventional


def test_existing_override_is_not_replaced_by_another_accounts_default(tmp_path, monkeypatch):
    monkeypatch.setenv("GROK_HOME", str(tmp_path / "alternate"))
    override = tmp_path / "alternate/auth.json"
    default = tmp_path / ".grok/auth.json"
    for path in (override, default):
        path.parent.mkdir(parents=True)
        path.write_text("{}")
    assert grok_auth_path(tmp_path) == override
