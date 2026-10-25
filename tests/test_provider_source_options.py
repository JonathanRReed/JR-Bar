"""Source option edits stay scoped to one consented provider preference."""
from dataclasses import replace
from pathlib import Path
from types import SimpleNamespace

import pytest

from jrbar import core_runtime
from jrbar import provider_management as pm
from jrbar.core_server import CommandError
from jrbar.provider_usage_settings import (
    default_provider_usage_settings_path,
    load_provider_usage_settings,
    save_provider_usage_settings,
)


class Credentials:
    def get(self, *_):
        return SimpleNamespace(available=False, secret=None, reason="credential_not_found")

    def get_for_instance(self, *_):
        return self.get()


@pytest.fixture
def home(tmp_path, monkeypatch):
    monkeypatch.setattr(Path, "home", lambda: tmp_path)
    for variable, path in (("HOME", tmp_path), ("XDG_CONFIG_HOME", tmp_path / ".config"),
                           ("XDG_STATE_HOME", tmp_path / ".local/state"),
                           ("XDG_DATA_HOME", tmp_path / ".local/share")):
        monkeypatch.setenv(variable, str(path))
    return tmp_path


def test_partial_patch_persists_preserves_options_and_never_grants_consent(home):
    loaded = load_provider_usage_settings()
    settings = loaded.settings.with_option("kimi", "unrelated", "keep")
    save_provider_usage_settings(settings, default_provider_usage_settings_path(), loaded=loaded)
    row = pm.set_provider_options("kimi", {"region": "international", "source": "web"},
                                  credentials=Credentials(), home=home)
    saved = load_provider_usage_settings().settings.preference("kimi")
    assert dict(saved.options) == {"region": "international", "source": "web", "unrelated": "keep"}
    assert not saved.usage_consented
    assert row["options"] == {"region": "international", "source": "web"}
    assert row["usage_consent"]["granted"] is False


def test_named_instance_isolation_and_empty_organization_clear(home):
    loaded = load_provider_usage_settings()
    named = replace(loaded.settings.preference("kilo"), source_instance_id="work")
    save_provider_usage_settings(loaded.settings.with_instance(named), default_provider_usage_settings_path(), loaded=loaded)
    pm.set_provider_options("kilo", {"organization_id": "synthetic-org:1"},
                            source_instance_id="work", credentials=Credentials(), home=home)
    saved = load_provider_usage_settings().settings
    assert dict(saved.preference("kilo", "work").options)["organization_id"] == "synthetic-org:1"
    assert saved.preference("kilo").options == ()
    row = pm.set_provider_options("kilo", {"organization_id": ""}, source_instance_id="work",
                                  credentials=Credentials(), home=home)
    assert "organization_id" not in row["options"]
    assert not load_provider_usage_settings().settings.preference("kilo", "work").usage_consented


@pytest.mark.parametrize("provider, options, instance, code", [
    ("absent", {}, "default", "unknown_provider"),
    ("kimi", {}, "absent", "unknown_instance"),
    ("claude", {"source": "auto"}, "default", "invalid_args"),
    ("kimi", {"region": "elsewhere"}, "default", "invalid_args"),
    ("kimi", {"source": "browser"}, "default", "invalid_args"),
    ("kimi", {"source": True}, "default", "invalid_args"),
    ("kimi", {"token": "synthetic"}, "default", "invalid_args"),
    ("kilo", {"organization_id": "bad\nheader"}, "default", "invalid_args"),
    ("kilo", {"organization_id": "x" * 129}, "default", "invalid_args"),
    ("kilo", {"organization_id": "é"}, "default", "invalid_args"),
    ("kilo", {"organization_id": None}, "default", "invalid_args"),
    ("kimi", [], "default", "invalid_args"),
])
def test_invalid_options_write_nothing(home, provider, options, instance, code):
    before = load_provider_usage_settings().settings
    with pytest.raises(pm.ProviderManagementError) as error:
        pm.set_provider_options(provider, options, source_instance_id=instance,
                                credentials=Credentials(), home=home)
    assert error.value.code == code
    assert load_provider_usage_settings().settings == before


def test_concurrent_write_is_refused_without_losing_other_edit(home, monkeypatch):
    real_save = pm.save_provider_usage_settings

    def concurrent(settings, path, *, loaded):
        real_save(loaded.settings.with_option("kimi", "unrelated", "concurrent"), path, loaded=loaded)
        real_save(settings, path, loaded=loaded)

    monkeypatch.setattr(pm, "save_provider_usage_settings", concurrent)
    with pytest.raises(pm.ProviderManagementError) as error:
        pm.set_provider_options("kimi", {"source": "api"}, credentials=Credentials(), home=home)
    assert error.value.code == "settings_changed"
    assert dict(load_provider_usage_settings().settings.preference("kimi").options) == {"unrelated": "concurrent"}


@pytest.mark.parametrize("instance", ["default", "work"])
def test_socket_refreshes_exact_instance_without_implicitly_granting_consent(home, instance):
    loaded = load_provider_usage_settings()
    named = replace(loaded.settings.preference("kimi"), source_instance_id="work")
    save_provider_usage_settings(loaded.settings.with_instance(named), default_provider_usage_settings_path(), loaded=loaded)
    calls = []
    controller = SimpleNamespace(_jrbar_provider_credential_store=Credentials(),
                                 _request_provider_usage=lambda **kw: calls.append(kw))
    reply = core_runtime._cmd_set_provider_options(controller,
        {"provider": "kimi", "instance": instance, "options": {"source": "cli"}})
    assert reply["provider"]["instance"] == instance
    assert reply["provider"]["usage_consent"]["granted"] is False
    assert calls == [{"force": True, "providers": (("kimi", instance),)}]


@pytest.mark.parametrize("args", [{}, {"provider": "kimi"},
    {"provider": "kimi", "options": {}, "instance": 4},
    {"provider": "kimi", "options": {}, "instance": ""}])
def test_socket_rejects_bad_arguments(home, args):
    with pytest.raises(CommandError) as error:
        core_runtime._cmd_set_provider_options(SimpleNamespace(), args)
    assert error.value.code == "invalid_args"


def test_edit_keeps_existing_consent_and_enabled_choice(home):
    loaded = load_provider_usage_settings()
    settings = loaded.settings.with_usage_consent("kimi", True, source="settings", at=1000)
    settings = settings.with_enabled("kimi", False)
    save_provider_usage_settings(settings, default_provider_usage_settings_path(), loaded=loaded)
    before = load_provider_usage_settings().settings.preference("kimi")
    pm.set_provider_options("kimi", {"region": "china"}, credentials=Credentials(), home=home)
    after = load_provider_usage_settings().settings.preference("kimi")
    assert after == before.with_option("region", "china")


def test_claude_cli_fallback_requires_its_own_persisted_opt_in(home):
    assert load_provider_usage_settings().settings.preference("claude").option("cli_fallback") is None
    row = pm.set_provider_options("claude", {"cli_fallback": "true"}, credentials=Credentials(), home=home)
    assert row["options"] == {"cli_fallback": "true"}
    assert not row["usage_consent"]["granted"]
    assert load_provider_usage_settings().settings.preference("claude").option("cli_fallback") == "true"
    pm.set_provider_options("claude", {"cli_fallback": "false"}, credentials=Credentials(), home=home)
    assert load_provider_usage_settings().settings.preference("claude").option("cli_fallback") == "false"
