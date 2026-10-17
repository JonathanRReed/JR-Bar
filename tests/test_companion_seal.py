"""The consent files beside settings.json are sealed (companion_seal.py).

Everything runs in a temporary folder with a fixed synthetic key; the loaders
and savers are the real ones, handed explicit paths. A consent written by hand
must grant nothing and be put back; the daemon's own writes must keep working.
"""

from __future__ import annotations

import json
from pathlib import Path

import pytest

from jrbar.companion_seal import (
    BROWSER_CONSENT,
    INTEGRATIONS,
    PROVIDER_USAGE,
    CompanionSeals,
    guard_companion,
    install_companion_seals,
    normalize_companion_seals,
)
from jrbar.integration_settings import (
    IntegrationSettings,
    load_integration_settings,
    save_integration_settings,
)
from jrbar.provider_browser_consent import (
    BrowserConsentStore,
    load_browser_consents,
    save_browser_consents,
)
from jrbar.provider_usage_settings import (
    load_provider_usage_settings,
    save_provider_usage_settings,
)
from jrbar.settings_seal import SealState, SettingsSeal

KEY = bytes(range(10, 42))
NOW = 1_700_000_000.0


class Rig:
    """A seal, a stand-in for the settings' ledger, and three consent files."""

    def __init__(self, tmp_path: Path, *, state_sealed: bool = True, key: bytes | None = KEY) -> None:
        self.dir = tmp_path / "config"
        self.dir.mkdir()
        self.paths = {
            PROVIDER_USAGE: self.dir / "provider-usage.json",
            BROWSER_CONSENT: self.dir / "browser-consent.json",
            INTEGRATIONS: self.dir / "integrations.json",
        }
        self.persisted: dict[str, str] = {}
        self.lines: list[str] = []
        self.seal = SettingsSeal(
            key,
            path=tmp_path / "settings.json",
            previously_sealed=state_sealed,
            log=self.lines.append,
            clock=lambda: NOW,
        )
        self.seals = CompanionSeals(
            self.seal, self.paths, lambda: self.persisted, log=self.lines.append, clock=lambda: NOW
        )
        install_companion_seals(self.seals)

    def settle(self) -> None:
        """What the run loop does each second: the settings take the ledger in."""
        self.persisted = self.seals.ledger()
        self.seals.settled(self.persisted)

    def read(self, name: str) -> dict:
        return json.loads(self.paths[name].read_text(encoding="utf-8"))

    def edit(self, name: str, change) -> None:
        document = self.read(name)
        change(document)
        self.paths[name].write_text(json.dumps(document), encoding="utf-8")

    def usage(self):
        return load_provider_usage_settings(self.paths[PROVIDER_USAGE])

    def grant_usage(self, provider: str = "codex") -> None:
        loaded = self.usage()
        updated = loaded.settings.with_usage_consent(provider, True, source="settings", at=NOW)
        save_provider_usage_settings(updated, self.paths[PROVIDER_USAGE], loaded=loaded)


@pytest.fixture(autouse=True)
def _no_installed_seals():
    yield
    install_companion_seals(None)


@pytest.fixture
def rig(tmp_path: Path) -> Rig:
    return Rig(tmp_path)


def _hand_grant_usage(document: dict, provider: str = "codex") -> None:
    for row in document["providers"]:
        if row["provider_id"] == provider:
            row["usage_consent_version"] = 1
            row["usage_consent_source"] = "settings"
            row["usage_consented_at"] = NOW


# --- provider-usage.json -------------------------------------------------------------


def test_a_usage_consent_written_by_hand_grants_nothing_and_is_put_back(rig: Rig) -> None:
    rig.grant_usage("claude")
    rig.settle()
    rig.edit(PROVIDER_USAGE, _hand_grant_usage)

    loaded = rig.usage()

    assert not loaded.settings.preference("codex").usage_consented
    assert loaded.settings.preference("claude").usage_consented
    assert not [
        row
        for row in rig.read(PROVIDER_USAGE)["providers"]
        if row["provider_id"] == "codex" and row["usage_consent_version"]
    ]
    rejected = rig.paths[PROVIDER_USAGE].with_name("provider-usage.json.rejected")
    assert json.loads(rejected.read_text(encoding="utf-8"))["providers"]
    notice = rig.seal.notice()
    assert notice is not None and notice.keys == ("provider_usage_consent",) and notice.can_keep
    assert any("changed outside JR-Bar; ignored" in line for line in rig.lines)


def test_the_file_stays_put_back_on_the_next_read(rig: Rig) -> None:
    rig.grant_usage("claude")
    rig.settle()
    rig.edit(PROVIDER_USAGE, _hand_grant_usage)
    rig.usage()
    before = rig.paths[PROVIDER_USAGE].read_text(encoding="utf-8")

    rig.usage()

    assert rig.paths[PROVIDER_USAGE].read_text(encoding="utf-8") == before
    assert len([line for line in rig.lines if "ignored" in line]) == 1


def test_the_daemons_own_consent_save_is_sealed_and_kept(rig: Rig) -> None:
    rig.grant_usage("codex")
    rig.settle()

    assert rig.usage().settings.preference("codex").usage_consented
    assert rig.seal.notice() is None
    assert set(rig.seals.ledger()) == {PROVIDER_USAGE}


def test_taking_a_usage_consent_away_by_hand_is_accepted(rig: Rig) -> None:
    rig.grant_usage("codex")
    rig.settle()

    def withdraw(document: dict) -> None:
        for row in document["providers"]:
            row["usage_consent_version"] = 0

    rig.edit(PROVIDER_USAGE, withdraw)

    assert not rig.usage().settings.preference("codex").usage_consented
    assert rig.seal.notice() is None
    rig.settle()
    assert not rig.usage().settings.preference("codex").usage_consented


def test_other_usage_settings_do_not_need_the_seal(rig: Rig) -> None:
    rig.grant_usage("codex")
    rig.settle()

    def tune(document: dict) -> None:
        for row in document["providers"]:
            row["menu_visible"] = False
            row["threshold_remaining"] = 0.5

    rig.edit(PROVIDER_USAGE, tune)

    loaded = rig.usage()
    assert not loaded.settings.preference("codex").menu_visible
    assert loaded.settings.preference("codex").usage_consented
    assert rig.seal.notice() is None


def test_a_file_with_no_seal_yet_is_adopted_as_it_is(rig: Rig) -> None:
    # A Mac upgrading: the consent is already there and nothing sealed it.
    install_companion_seals(None)
    save_provider_usage_settings(
        rig.usage().settings.with_usage_consent("codex", True, source="settings", at=NOW),
        rig.paths[PROVIDER_USAGE],
    )
    install_companion_seals(rig.seals)
    assert rig.seals.ledger() == {}

    assert rig.usage().settings.preference("codex").usage_consented
    assert rig.seal.notice() is None
    assert PROVIDER_USAGE in rig.seals.ledger()


def test_a_lost_sealed_copy_puts_the_file_back_to_nothing_consented(rig: Rig) -> None:
    rig.grant_usage("claude")
    rig.settle()
    rig.paths[PROVIDER_USAGE].with_name("provider-usage.json.sealed").unlink()
    rig.edit(PROVIDER_USAGE, _hand_grant_usage)

    loaded = rig.usage()

    assert not loaded.settings.preference("codex").usage_consented
    assert not loaded.settings.preference("claude").usage_consented


def test_a_forged_sealed_copy_is_not_trusted(rig: Rig) -> None:
    rig.grant_usage("claude")
    rig.settle()
    forged = rig.paths[PROVIDER_USAGE].with_name("provider-usage.json.sealed")
    rig.edit(PROVIDER_USAGE, _hand_grant_usage)
    forged.write_text(rig.paths[PROVIDER_USAGE].read_text(encoding="utf-8"), encoding="utf-8")
    snapshot = {
        "v": 1,
        "name": PROVIDER_USAGE,
        "mac": "0" * 64,
        "projection": {"rows": {"codex\x1fdefault": [1, "settings", NOW]}},
    }
    forged.write_text(json.dumps(snapshot), encoding="utf-8")

    assert not rig.usage().settings.preference("codex").usage_consented


def test_keeping_an_ignored_usage_change_takes_it_and_seals_it(rig: Rig) -> None:
    rig.grant_usage("claude")
    rig.settle()
    rig.edit(PROVIDER_USAGE, _hand_grant_usage)
    assert not rig.usage().settings.preference("codex").usage_consented

    rig.seals.keep("provider_usage_consent")
    rig.settle()

    assert rig.usage().settings.preference("codex").usage_consented
    assert rig.usage().settings.preference("claude").usage_consented


# --- browser-consent.json ------------------------------------------------------------


def _browser_row() -> dict:
    return {
        "provider_id": "claude",
        "source_instance_id": "default",
        "browser": "chrome",
        "profile": "Default",
        "domains": ["example.test"],
        "fields": ["sessionKey"],
        "background_repair": False,
        "granted_at": NOW,
    }


def _allowed(path: Path) -> bool:
    return load_browser_consents(path).store.allows(
        provider_id="claude",
        browser="chrome",
        profile="Default",
        domain="example.test",
        field="sessionKey",
    )


def test_a_browser_consent_written_by_hand_reads_nothing_and_is_put_back(rig: Rig) -> None:
    path = rig.paths[BROWSER_CONSENT]
    save_browser_consents(BrowserConsentStore.empty(), path)
    rig.settle()
    rig.edit(BROWSER_CONSENT, lambda document: document.update(consents=[_browser_row()]))

    assert not _allowed(path)
    assert rig.read(BROWSER_CONSENT)["consents"] == []
    notice = rig.seal.notice()
    assert notice is not None and notice.keys == ("browser_consent",)


def test_the_daemons_own_browser_grant_is_sealed_and_a_widening_is_not(rig: Rig) -> None:
    path = rig.paths[BROWSER_CONSENT]
    store = BrowserConsentStore.empty().grant(
        provider_id="claude",
        browser="chrome",
        profile="Default",
        domains=("example.test",),
        fields=("sessionKey",),
        background_repair=False,
        granted_at=NOW,
    )
    save_browser_consents(store, path)
    rig.settle()
    assert _allowed(path)

    def widen(document: dict) -> None:
        document["consents"][0]["fields"] = ["sessionKey", "otherKey"]

    rig.edit(BROWSER_CONSENT, widen)

    assert _allowed(path)
    assert rig.read(BROWSER_CONSENT)["consents"][0]["fields"] == ["sessionKey"]
    assert rig.seal.notice() is not None


def test_dropping_a_browser_consent_by_hand_is_accepted(rig: Rig) -> None:
    path = rig.paths[BROWSER_CONSENT]
    save_browser_consents(
        BrowserConsentStore.empty().grant(
            provider_id="claude",
            browser="chrome",
            profile="Default",
            domains=("example.test",),
            fields=("sessionKey",),
            background_repair=False,
            granted_at=NOW,
        ),
        path,
    )
    rig.settle()
    rig.edit(BROWSER_CONSENT, lambda document: document.update(consents=[]))

    assert not _allowed(path)
    assert rig.seal.notice() is None


# --- integrations.json ---------------------------------------------------------------


def test_an_integration_switched_on_by_hand_stays_off_and_is_put_back(rig: Rig) -> None:
    path = rig.paths[INTEGRATIONS]
    save_integration_settings(IntegrationSettings(), path)
    rig.settle()

    def switch_on(document: dict) -> None:
        document["t3code_enabled"] = True
        document["t3code_base_dir"] = "/tmp/synthetic-t3"

    rig.edit(INTEGRATIONS, switch_on)

    settings = load_integration_settings(path).settings
    assert settings.t3code_enabled is False and settings.t3code_base_dir is None
    assert rig.read(INTEGRATIONS)["t3code_enabled"] is False
    notice = rig.seal.notice()
    assert notice is not None and notice.keys == ("integrations",)


def test_the_daemons_own_integration_change_is_sealed(rig: Rig) -> None:
    path = rig.paths[INTEGRATIONS]
    save_integration_settings(IntegrationSettings(), path)
    rig.settle()
    loaded = load_integration_settings(path)
    save_integration_settings(loaded.settings.with_enabled("t3code", True), path, loaded=loaded)
    rig.settle()

    assert load_integration_settings(path).settings.t3code_enabled is True
    assert rig.seal.notice() is None


# --- when nothing is sealed ----------------------------------------------------------


def test_with_no_seal_installed_the_files_read_and_write_as_ever(tmp_path: Path) -> None:
    path = tmp_path / "provider-usage.json"
    save_provider_usage_settings(
        load_provider_usage_settings(path).settings.with_usage_consent("codex", True, source="cli", at=NOW), path
    )
    assert load_provider_usage_settings(path).settings.preference("codex").usage_consented


@pytest.mark.parametrize("key,sealed", [(None, False), (KEY, False)])
def test_without_a_key_or_before_sealing_nothing_is_checked(tmp_path: Path, key, sealed) -> None:
    rig = Rig(tmp_path, state_sealed=sealed, key=key)
    assert rig.seal.state in {SealState.UNAVAILABLE, SealState.NOT_SEALED}
    rig.grant_usage("claude")
    rig.edit(PROVIDER_USAGE, _hand_grant_usage)

    assert rig.usage().settings.preference("codex").usage_consented
    assert rig.seal.notice() is None


def test_before_the_settings_are_read_nothing_is_checked(rig: Rig) -> None:
    seals = CompanionSeals(rig.seal, rig.paths, lambda: None)
    document = {"consents": [_browser_row()]}
    assert seals.guard(BROWSER_CONSENT, rig.paths[BROWSER_CONSENT], document) is document


def test_a_check_that_fails_closes_the_door(rig: Rig, monkeypatch: pytest.MonkeyPatch) -> None:
    rig.grant_usage("claude")
    rig.settle()

    def broken(*_args, **_kwargs):
        raise RuntimeError("synthetic")

    monkeypatch.setattr(rig.seals, "guard", broken)
    document = rig.read(PROVIDER_USAGE)

    guarded = guard_companion(PROVIDER_USAGE, rig.paths[PROVIDER_USAGE], document)

    assert all(row["usage_consent_version"] == 0 for row in guarded["providers"])


def test_the_ledger_only_keeps_names_and_digests() -> None:
    good = "a" * 64
    assert normalize_companion_seals({PROVIDER_USAGE: good, "other": good, INTEGRATIONS: "short"}) == {
        PROVIDER_USAGE: good
    }
    assert normalize_companion_seals(["x"]) == {}


def test_the_inspect_pass_notices_a_change_without_a_load(rig: Rig) -> None:
    rig.grant_usage("claude")
    rig.settle()
    rig.seals.inspect_all()
    assert rig.seal.notice() is None

    rig.edit(PROVIDER_USAGE, _hand_grant_usage)
    rig.seals.inspect_all()

    assert rig.seal.notice() is not None
    assert not [
        row
        for row in rig.read(PROVIDER_USAGE)["providers"]
        if row["provider_id"] == "codex" and row["usage_consent_version"]
    ]
