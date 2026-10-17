"""The consent files' seals inside the headless daemon: the ledger rides in the
sealed settings, adopt_seal seals the files, and Keep the change takes one.

Harness from ``test_settings_seal_daemon``; the key is a fixed synthetic one.
"""

from __future__ import annotations

import json
from pathlib import Path

import pytest
from test_settings_seal_daemon import _SealedDaemon

from jrbar import settings as settings_module
from jrbar.companion_seal import PROVIDER_USAGE, CompanionSeals, install_companion_seals
from jrbar.provider_usage_settings import load_provider_usage_settings, save_provider_usage_settings

pytest_plugins = ("test_core_runtime",)

NOW = 1_700_000_000.0


@pytest.fixture(autouse=True)
def _no_installed_seals():
    yield
    install_companion_seals(None)
    settings_module.install_document_seal(None)


def _wire(daemon: _SealedDaemon, tmp_path: Path) -> tuple[CompanionSeals, Path]:
    path = tmp_path / "provider-usage.json"
    seals = CompanionSeals(
        daemon.seal,
        {PROVIDER_USAGE: path},
        lambda: daemon.controller.settings.companion_seals,
        log=daemon.lines.append,
        clock=lambda: NOW,
    )
    install_companion_seals(seals)
    daemon.controller._core_companions = seals
    return seals, path


def _consent(path: Path, provider: str) -> None:
    loaded = load_provider_usage_settings(path)
    save_provider_usage_settings(
        loaded.settings.with_usage_consent(provider, True, source="settings", at=NOW), path, loaded=loaded
    )


def _hand_grant(path: Path, provider: str) -> None:
    document = json.loads(path.read_text(encoding="utf-8"))
    for row in document["providers"]:
        if row["provider_id"] == provider:
            row.update(usage_consent_version=1, usage_consent_source="settings", usage_consented_at=NOW)
    path.write_text(json.dumps(document), encoding="utf-8")


def _consented(path: Path, provider: str) -> bool:
    return load_provider_usage_settings(path).settings.preference(provider).usage_consented


def test_adopting_seals_the_consent_files_into_the_sealed_settings(headless, monkeypatch, tmp_path) -> None:
    daemon = _SealedDaemon(headless, monkeypatch)
    _seals, path = _wire(daemon, tmp_path)
    _consent(path, "claude")

    daemon.adopt()
    ledger = daemon.controller.settings.companion_seals

    assert set(ledger) == {PROVIDER_USAGE}
    assert daemon.file()["companion_seals"] == ledger

    # After a restart the sealed ledger is what judges the file.
    daemon.restart()
    _wire(daemon, tmp_path)
    _hand_grant(path, "codex")
    assert _consented(path, "claude") and not _consented(path, "codex")
    assert daemon.seal.notice() is not None


def test_the_once_a_second_look_puts_a_hand_grant_back_and_says_so(headless, monkeypatch, tmp_path) -> None:
    daemon = _SealedDaemon(headless, monkeypatch)
    seals, path = _wire(daemon, tmp_path)
    _consent(path, "claude")
    daemon.adopt()
    seals.inspect_all()

    _hand_grant(path, "codex")
    seals.inspect_all()
    daemon.controller._core_publish_settings()

    shown = daemon.shown()
    assert shown["changed"]["keys"] == ["provider_usage_consent"] and shown["changed"]["can_keep"] is True
    assert not _consented(path, "codex")


def test_keeping_the_change_takes_it_and_clears_the_banner(headless, monkeypatch, tmp_path) -> None:
    daemon = _SealedDaemon(headless, monkeypatch)
    seals, path = _wire(daemon, tmp_path)
    _consent(path, "claude")
    daemon.adopt()
    _hand_grant(path, "codex")
    seals.inspect_all()
    assert not _consented(path, "codex")

    reply = daemon.controller._core_dispatch("keep_protected_change", {})

    assert reply["kept"] == ["provider_usage_consent"]
    assert _consented(path, "codex") and _consented(path, "claude")
    assert daemon.seal.notice() is None
    assert daemon.controller.settings.companion_seals == seals.ledger()
    daemon.restart()
    _wire(daemon, tmp_path)
    assert _consented(path, "codex")


def test_resetting_protection_seals_the_files_as_they_are(headless, monkeypatch, tmp_path) -> None:
    daemon = _SealedDaemon(headless, monkeypatch)
    seals, path = _wire(daemon, tmp_path)
    _consent(path, "claude")
    daemon.adopt()
    _hand_grant(path, "codex")
    seals.inspect_all()
    assert daemon.seal.notice() is not None

    daemon.adopt()

    assert daemon.seal.notice() is None
    assert _consented(path, "claude") and not _consented(path, "codex")
