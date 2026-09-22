"""W06: provider inspect/enable/consent over the shared control surface.

The socket commands and the CLI drive the same stores: settings writes
keep the document's optimistic concurrency (T25), consent grants import
nothing, and revoke removes JR-Bar-owned imported data only while it is
still the imported value (T26).
"""

from __future__ import annotations

import hashlib
import json
from pathlib import Path
from types import SimpleNamespace
from unittest.mock import MagicMock

import pytest

import jrbar.core_runtime as core_runtime
from jrbar import provider_management as pm
from jrbar.core_server import CommandError
from jrbar.provider_browser_consent import load_browser_consents
from jrbar.provider_browser_import import import_devin_browser_session
from jrbar.provider_usage_platform import (
    ProviderSourceState,
    ProviderUsageSnapshot,
)
from jrbar.provider_usage_runtime import ProviderUsageState
from jrbar.provider_usage_settings import (
    load_provider_usage_settings,
    save_provider_usage_settings,
)

NOW = 1_789_347_200.0


@pytest.fixture(autouse=True)
def fake_home(tmp_path: Path, monkeypatch: pytest.MonkeyPatch) -> Path:
    monkeypatch.setattr(Path, "home", lambda: tmp_path)
    return tmp_path


class DictCredentials:
    """In-memory stand-in for ProviderCredentialStore's read/write surface."""

    def __init__(self):
        self.values = {}

    def _read(self, provider_id, instance, account):
        value = self.values.get((provider_id, instance, account))
        return SimpleNamespace(
            available=value is not None,
            secret=value,
            reason=None if value is not None else "credential_not_found",
        )

    def get(self, provider_id, account):
        return self._read(provider_id, "default", account)

    def get_for_instance(self, key, account):
        provider_id, instance = key.value
        return self._read(provider_id, instance, account)

    def set(self, provider_id, account, secret):
        self.values[(provider_id, "default", account)] = secret

    def set_for_instance(self, key, account, secret):
        provider_id, instance = key.value
        self.values[(provider_id, instance, account)] = secret

    def delete(self, provider_id, account):
        return self.values.pop((provider_id, "default", account), None) is not None

    def delete_for_instance(self, key, account):
        provider_id, instance = key.value
        return self.values.pop((provider_id, instance, account), None) is not None


def _snapshot(provider_id="devin", state=ProviderSourceState.NEEDS_CONSENT):
    return ProviderUsageSnapshot(
        provider_id=provider_id,
        account_label=None,
        observed_at=NOW,
        state=state,
        reason_code="browser_consent_required",
        action_label="Enable Devin browser access",
        lanes=(),
        input_tokens=0,
        cached_input_tokens=0,
        output_tokens=0,
        model_count=0,
        estimated_cost_usd=None,
        cache_savings_usd=None,
        credits_remaining=None,
        incident=None,
    )


def test_provider_rows_inspect_without_secrets(fake_home):
    credentials = DictCredentials()
    credentials.set("devin", "token", "supersecret")
    state = ProviderUsageState((_snapshot(),), NOW, None, False)
    rows = pm.provider_rows(credentials=credentials, state=state)
    assert [row["id"] for row in rows] == [
        "codex", "claude", "cursor", "devin", "grok",
        "gemini", "antigravity", "opencode", "openai-api",
    ]
    devin = next(row for row in rows if row["id"] == "devin")
    assert devin["state"] == "needs_consent"
    assert devin["reason"] == "browser_consent_required"
    assert devin["action"] == "Enable Devin browser access"
    assert devin["credentials"] == [{"account": "token", "available": True}]
    # The row reports availability, never the secret.
    assert "supersecret" not in json.dumps(rows)

    # Options publish through a whitelist: display identifiers surface,
    # anything else -- including names the old substring filter missed --
    # stays inside the settings store.
    loaded = load_provider_usage_settings()
    settings = loaded.settings
    for key, value in (
        ("organization", "Cognition"),
        ("csrf_token", "csrf-secret"),
        ("api_password", "hunter2"),
        ("session_cookie", "cookie-value"),
    ):
        settings = settings.with_option("devin", key, value)
    save_provider_usage_settings(settings, loaded=loaded)
    rows = pm.provider_rows(credentials=credentials, state=state)
    devin = next(row for row in rows if row["id"] == "devin")
    assert devin["options"] == {"organization": "Cognition"}
    assert "csrf-secret" not in json.dumps(rows)
    assert "hunter2" not in json.dumps(rows)
    assert "cookie-value" not in json.dumps(rows)


def test_set_provider_enabled_persists_and_reports():
    credentials = DictCredentials()
    row = pm.set_provider_enabled("grok", False, credentials=credentials)
    assert row["enabled"] is False
    persisted = load_provider_usage_settings()
    assert persisted.settings.preference("grok").enabled is False
    with pytest.raises(pm.ProviderManagementError) as error:
        pm.set_provider_enabled("nonsense", True)
    assert error.value.code == "unknown_provider"
    with pytest.raises(pm.ProviderManagementError) as error:
        pm.set_provider_enabled(
            "grok", True, source_instance_id="work", credentials=credentials
        )
    assert error.value.code == "unknown_instance"


def test_rows_are_scoped_per_configured_instance():
    """Two accounts of one provider produce two rows; consents, imported
    provenance, and live state follow the instance, not the provider."""
    from jrbar.provider_instances import ProviderInstanceKey
    from jrbar.provider_usage_settings import ProviderInstanceProfile

    loaded = load_provider_usage_settings()
    settings = loaded.settings.with_profile(
        ProviderInstanceProfile(
            ProviderInstanceKey("devin", "work"), label="Devin · work"
        )
    )
    save_provider_usage_settings(settings, loaded=loaded)
    pm.grant_browser_consent(
        "devin", "chrome", "Default", source_instance_id="work"
    )
    credentials = DictCredentials()
    credentials.set("devin", "token", "default-secret")
    credentials.set_for_instance(
        ProviderInstanceKey("devin", "work"), "token", "work-secret"
    )
    import dataclasses

    work_snapshot = dataclasses.replace(
        _snapshot(),
        source_instance_id="work",
        state=ProviderSourceState.READY,
        reason_code=None,
        action_label=None,
    )
    state = ProviderUsageState((_snapshot(), work_snapshot), NOW, None, False)
    rows = pm.provider_rows(credentials=credentials, state=state)
    devin_rows = [row for row in rows if row["id"] == "devin"]
    assert [row["instance"] for row in devin_rows] == ["default", "work"]
    default_row, work_row = devin_rows
    assert default_row["state"] == "needs_consent"
    assert work_row["state"] == "ready"
    assert work_row["label"] == "Devin · work"
    assert [row["profile"] for row in work_row["consents"]] == ["Default"]
    assert default_row["consents"] == []
    assert work_row["credentials"][0]["available"] is True
    # The instance row carries its own credential, not the default's.
    pm.record_browser_import("devin", "work", "chrome", "Default", "work-secret")
    rows = pm.provider_rows(credentials=credentials, state=state)
    work_row = next(r for r in rows if r["id"] == "devin" and r["instance"] == "work")
    assert work_row["imported_credential"] is True
    result = pm.revoke_browser_consent(
        "devin", "chrome", "Default",
        source_instance_id="work", credentials=credentials,
    )
    assert result["imported_data"] == "removed"
    assert credentials.get("devin", "token").secret == "default-secret"


def test_set_provider_enabled_refuses_stale_write():
    """T25: a settings document edited between load and save is refused,
    never silently merged over."""
    loaded = load_provider_usage_settings()
    other = load_provider_usage_settings()
    save_provider_usage_settings(
        other.settings.with_enabled("cursor", False), loaded=other
    )
    with pytest.raises(pm.ProviderUsageSettingsWriteRefusedError):
        save_provider_usage_settings(
            loaded.settings.with_enabled("grok", False), loaded=loaded
        )


def test_grant_binds_exact_scope_and_imports_nothing():
    consent = pm.grant_browser_consent("devin", "chrome", "Default")
    assert consent["fields"] == ["auth1_session", "organization"]
    assert consent["imported"] is False
    store = load_browser_consents().store
    assert store.allows(
        provider_id="devin", browser="chrome", profile="Default",
        domain="app.devin.ai", field="auth1_session",
    )
    with pytest.raises(pm.ProviderManagementError) as error:
        pm.grant_browser_consent("grok", "chrome", "Default")
    assert error.value.code == "unsupported"


def test_revoke_removes_only_the_imported_credential():
    """T26: consent revoked + imported token still ours → removed; a
    user-replaced token survives."""
    credentials = DictCredentials()
    credentials.set("devin", "token", "imported-secret")
    pm.record_browser_import(
        "devin", "default", "chrome", "Default", "imported-secret"
    )
    pm.grant_browser_consent("devin", "chrome", "Default")
    result = pm.revoke_browser_consent(
        "devin", "chrome", "Default", credentials=credentials
    )
    assert result["imported_data"] == "removed"
    assert credentials.get("devin", "token").available is False

    # A credential the user replaced after import is not ours to delete.
    credentials.set("devin", "token", "user-secret")
    pm.record_browser_import(
        "devin", "default", "chrome", "Default", "imported-secret"
    )
    pm.grant_browser_consent("devin", "chrome", "Default")
    result = pm.revoke_browser_consent(
        "devin", "chrome", "Default", credentials=credentials
    )
    assert result["imported_data"] == "replaced"
    assert credentials.get("devin", "token").secret == "user-secret"

    # A manual set after an import drops the provenance entirely.
    credentials.set("devin", "token", "imported-secret")
    pm.record_browser_import(
        "devin", "default", "chrome", "Default", "imported-secret"
    )
    pm.forget_browser_import("devin")
    pm.grant_browser_consent("devin", "chrome", "Default")
    result = pm.revoke_browser_consent(
        "devin", "chrome", "Default", credentials=credentials
    )
    assert result["imported_data"] == "none"
    assert credentials.get("devin", "token").secret == "imported-secret"


class Record:
    def __init__(self, seq, state, user_key, value):
        self.seq = seq
        self.state = state
        self.user_key = user_key
        self.value = value


class RawDb:
    def __init__(self, path, records):
        self.records = records

    def __enter__(self):
        return self

    def __exit__(self, *_args):
        return False

    def iterate_records_raw(self):
        return list(self.records)


class KeyState:
    Live = object()
    Deleted = object()


def test_import_records_digest_provenance(fake_home):
    profile_root = (
        fake_home
        / "Library"
        / "Application Support"
        / "Google"
        / "Chrome"
        / "Default"
    )
    leveldb = profile_root / "Local Storage" / "leveldb"
    leveldb.mkdir(parents=True)
    (leveldb / "000001.log").write_bytes(b"fixture")
    (leveldb / "CURRENT").write_text("MANIFEST-000001\n")
    pm.grant_browser_consent("devin", "chrome", "Default")
    store = load_browser_consents().store
    records = [
        Record(
            1,
            KeyState.Live,
            b"_https://app.devin.ai\x00\x01auth1_session",
            b"\x01" + json.dumps({"token": "imported-token-value"}).encode("latin-1"),
        ),
        Record(
            2,
            KeyState.Live,
            b"_https://app.devin.ai\x00\x01last-internal-org-for-external-org-v1-fixture",
            b"\x01org_fixture",
        ),
    ]
    credentials = DictCredentials()
    result = import_devin_browser_session(
        browser="chrome",
        profile="Default",
        profile_root=profile_root,
        consents=store,
        credentials=credentials,
        raw_db_factory=lambda path: RawDb(path, records),
        key_state_live=KeyState.Live,
        key_state_deleted=KeyState.Deleted,
    )
    assert result.state.value == "imported"
    ledger = pm._load_import_ledger()
    record = ledger["devin:default"]
    assert record["browser"] == "chrome" and record["profile"] == "Default"
    assert record["secret_sha256"] == hashlib.sha256(
        b"imported-token-value"
    ).hexdigest()
    assert "imported-token-value" not in json.dumps(record)


def _controller():
    return SimpleNamespace(
        _request_provider_usage=MagicMock(),
        provider_usage_state=None,
        _jrbar_provider_credential_store=DictCredentials(),
    )


def test_list_providers_command_rows():
    controller = _controller()
    controller.provider_usage_state = ProviderUsageState(
        (_snapshot(),), NOW, None, False
    )
    reply = core_runtime._cmd_list_providers(controller, {})
    ids = [row["id"] for row in reply["providers"]]
    assert "gemini" in ids and "devin" in ids
    devin = next(row for row in reply["providers"] if row["id"] == "devin")
    assert devin["state"] == "needs_consent"
    with pytest.raises(CommandError) as error:
        core_runtime._cmd_list_providers(controller, {"provider": ""})
    assert error.value.code == "invalid_args"


def test_provider_consent_command_grant_list_revoke():
    controller = _controller()
    granted = core_runtime._cmd_provider_consent(
        controller,
        {"action": "grant", "provider": "devin", "browser": "chrome", "profile": "Default"},
    )
    assert granted["consent"]["browser"] == "chrome"
    listed = core_runtime._cmd_provider_consent(controller, {"action": "list"})
    assert [row["profile"] for row in listed["consents"]] == ["Default"]
    revoked = core_runtime._cmd_provider_consent(
        controller,
        {"action": "revoke", "provider": "devin", "browser": "chrome", "profile": "Default"},
    )
    assert revoked["consent"]["was_granted"] is True
    listed = core_runtime._cmd_provider_consent(controller, {"action": "list"})
    assert listed["consents"] == []
    with pytest.raises(CommandError) as error:
        core_runtime._cmd_provider_consent(
            controller, {"action": "grant", "provider": "devin"}
        )
    assert error.value.code == "invalid_args"


def test_set_provider_enabled_command():
    controller = _controller()
    reply = core_runtime._cmd_set_provider_enabled(
        controller, {"provider": "cursor", "enabled": False}
    )
    assert reply["provider"]["enabled"] is False
    # A disable refreshes too: the row must stop showing the old quota
    # now, not at the next scheduled poll.
    controller._request_provider_usage.assert_called_once()
    reply = core_runtime._cmd_set_provider_enabled(
        controller, {"provider": "cursor", "enabled": True}
    )
    assert reply["provider"]["enabled"] is True
    assert controller._request_provider_usage.call_count == 2
    with pytest.raises(CommandError) as error:
        core_runtime._cmd_set_provider_enabled(controller, {"provider": "cursor"})
    assert error.value.code == "invalid_args"
    with pytest.raises(CommandError) as error:
        core_runtime._cmd_set_provider_enabled(
            controller, {"provider": "cursor", "enabled": "yes"}
        )
    assert error.value.code == "invalid_args"


def test_provider_action_command_rejects_unknown_and_unmatched():
    controller = _controller()
    with pytest.raises(CommandError) as error:
        core_runtime._cmd_provider_action(controller, {"provider": "nonsense"})
    assert error.value.code == "unknown_provider"
    # A provider with no staged action returns an explicit unsupported reply.
    with pytest.raises(CommandError) as error:
        core_runtime._cmd_provider_action(controller, {"provider": "claude"})
    assert error.value.code == "unsupported"


def test_provider_action_preserves_credential_ownership():
    """Gemini's credential is CLI-owned: the action must point the user
    at `gemini`, never claim JR-Bar can sign in or onboard for them."""
    controller = _controller()
    controller.provider_usage_state = ProviderUsageState(
        (
            ProviderUsageSnapshot(
                provider_id="gemini",
                account_label=None,
                observed_at=NOW,
                state=ProviderSourceState.NEEDS_SIGN_IN,
                reason_code="authentication_required",
                action_label="Run gemini once to sign in",
                lanes=(),
                input_tokens=0,
                cached_input_tokens=0,
                output_tokens=0,
                model_count=0,
                estimated_cost_usd=None,
                cache_savings_usd=None,
                credits_remaining=None,
                incident=None,
            ),
        ),
        NOW,
        None,
        False,
    )
    reply = core_runtime._cmd_provider_action(controller, {"provider": "gemini"})
    assert "gemini" in reply["message"].lower()
    assert reply["provider"] == "gemini"


def test_provider_action_resign_in_reconnects_and_forces_refresh():
    """`action="resign_in"` is the Usage Center's per-provider "Re-sign
    in": it runs the provider's own re-pull even when no staged action
    label is on the card, arms the outcome watch, and forces a scoped
    refresh — never the plain path's `unsupported`."""
    controller = _controller()
    reply = core_runtime._cmd_provider_action(
        controller, {"provider": "gemini", "action": "resign_in"}
    )
    assert "gemini" in reply["message"].lower()
    assert reply["sign_in_url"] is None
    controller._request_provider_usage.assert_called_once_with(
        force=True, providers=("gemini",)
    )
    assert controller._jrbar_reconnect_watch[0] == "gemini"

    # A named instance scopes the forced refresh to it.
    controller = _controller()
    core_runtime._cmd_provider_action(
        controller,
        {"provider": "gemini", "instance": "work", "action": "resign_in"},
    )
    controller._request_provider_usage.assert_called_once_with(
        force=True, providers=(("gemini", "work"),)
    )

    with pytest.raises(CommandError) as error:
        core_runtime._cmd_provider_action(
            _controller(), {"provider": "claude", "action": "nonsense"}
        )
    assert error.value.code == "invalid_args"
    with pytest.raises(CommandError) as error:
        core_runtime._cmd_provider_action(
            _controller(), {"provider": "nonsense", "action": "resign_in"}
        )
    assert error.value.code == "unknown_provider"


def test_add_provider_instance_persists_and_reports():
    credentials = DictCredentials()
    row = pm.add_provider_instance(
        "devin", "work", label="Devin · work", credentials=credentials
    )
    assert row["id"] == "devin" and row["instance"] == "work"
    assert row["label"] == "Devin · work"
    assert row["enabled"] is True
    assert row["supports_instances"] is True
    persisted = load_provider_usage_settings()
    assert persisted.settings.profile("devin", "work").label == "Devin · work"
    rows = pm.provider_rows(credentials=credentials, only="devin")
    assert [r["instance"] for r in rows] == ["default", "work"]
    work_row = next(r for r in rows if r["instance"] == "work")
    assert work_row["supports_instances"] is True


def test_add_provider_instance_refusals():
    # This-Mac's-own-sign-in providers can't read a second account.
    with pytest.raises(pm.ProviderManagementError) as error:
        pm.add_provider_instance("codex", "work")
    assert error.value.code == "unsupported"
    with pytest.raises(pm.ProviderManagementError) as error:
        pm.add_provider_instance("nonsense", "work")
    assert error.value.code == "unknown_provider"
    # "default" already exists for every provider.
    with pytest.raises(pm.ProviderManagementError) as error:
        pm.add_provider_instance("devin", "default")
    assert error.value.code == "invalid_args"
    # Reserved characters can't survive the instance id.
    with pytest.raises(pm.ProviderManagementError) as error:
        pm.add_provider_instance("devin", "a/b")
    assert error.value.code == "invalid_args"


def test_provider_add_instance_command():
    controller = _controller()
    reply = core_runtime._cmd_provider_add_instance(
        controller, {"provider": "devin", "instance": "work", "label": "Devin · work"}
    )
    assert reply["provider"]["instance"] == "work"
    controller._request_provider_usage.assert_called_once_with(
        force=True, providers=("devin",)
    )
    with pytest.raises(CommandError) as error:
        core_runtime._cmd_provider_add_instance(controller, {"provider": ""})
    assert error.value.code == "invalid_args"
    with pytest.raises(CommandError) as error:
        core_runtime._cmd_provider_add_instance(
            controller, {"provider": "devin"}
        )
    assert error.value.code == "invalid_args"
    with pytest.raises(CommandError) as error:
        core_runtime._cmd_provider_add_instance(
            controller, {"provider": "codex", "instance": "work"}
        )
    assert error.value.code == "unsupported"
