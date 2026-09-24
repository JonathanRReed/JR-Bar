"""Settings > Agents' T3 Code switch: presence, the opt-in write, the
reader's last look, and the daemon command that wraps them."""

from __future__ import annotations

import json
from pathlib import Path
from types import SimpleNamespace

import pytest

from jrbar import core_runtime, integration_settings
from jrbar.core_server import CommandError
from jrbar.integration_settings import load_integration_settings
from jrbar.t3code_toggle import T3CodeToggleRefused, t3code_integration, t3code_observation


@pytest.fixture
def t3_home(tmp_path, monkeypatch) -> Path:
    home = tmp_path / "t3"
    monkeypatch.setenv("T3_HOME", str(home))
    return home


def default_integration_settings_path() -> Path:
    # Looked up at call time: the autouse fixture isolates it per test.
    return integration_settings.default_integration_settings_path()


def _make_database(home: Path) -> Path:
    database = home / "userdata" / "state.sqlite"
    database.parent.mkdir(parents=True)
    database.write_bytes(b"")
    return database


def test_the_row_reads_presence_and_starts_off(t3_home) -> None:
    document, settings = t3code_integration()
    assert document["present"] is False
    assert document["enabled"] is False
    assert document["read_only"] is False
    assert document["database"] == str(t3_home.absolute() / "userdata" / "state.sqlite")
    assert settings.t3code_enabled is not True
    # Reading the row writes nothing.
    assert not default_integration_settings_path().exists()

    _make_database(t3_home)
    document, _ = t3code_integration()
    assert document["present"] is True


def test_enable_and_disable_write_the_opt_in_once(t3_home) -> None:
    _make_database(t3_home)
    document, settings = t3code_integration(True)
    assert document["enabled"] is True and settings.t3code_enabled is True
    assert load_integration_settings().settings.t3code_enabled is True
    written = default_integration_settings_path().stat().st_mtime_ns

    # Asking for what is already so leaves the file alone.
    t3code_integration(True)
    assert default_integration_settings_path().stat().st_mtime_ns == written

    document, _ = t3code_integration(False)
    assert document["enabled"] is False
    assert load_integration_settings().settings.t3code_enabled is False

    with pytest.raises(TypeError):
        t3code_integration("yes")  # type: ignore[arg-type]


def test_a_newer_builds_settings_file_refuses_the_write(t3_home) -> None:
    path = default_integration_settings_path()
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(json.dumps({"settings_schema_version": 999}), encoding="utf-8")
    before = path.read_bytes()
    document, _ = t3code_integration()
    assert document["read_only"] is True
    with pytest.raises(T3CodeToggleRefused):
        t3code_integration(True)
    assert path.read_bytes() == before


def test_the_observation_counts_what_the_reader_saw() -> None:
    assert t3code_observation(None) is None
    snapshot = SimpleNamespace(compatible=True, threads=(1, 2, 3), active_count=2, needs_user_count=1, reason=None)
    service = SimpleNamespace(observation=lambda: SimpleNamespace(snapshot=snapshot, reason=None, in_flight=False))
    assert t3code_observation(service) == {
        "available": True, "threads": 3, "active": 2, "needs_user": 1, "reason": None, "in_flight": False,
    }
    refused = SimpleNamespace(compatible=False, threads=(), reason="schema_mismatch")
    stale = SimpleNamespace(observation=lambda: SimpleNamespace(snapshot=refused, reason=None, in_flight=True))
    assert t3code_observation(stale) == {
        "available": False, "threads": 0, "active": 0, "needs_user": 0,
        "reason": "schema_mismatch", "in_flight": True,
    }


def test_the_command_validates_writes_and_reconciles_at_once(t3_home, monkeypatch) -> None:
    assert "t3code_integration" in core_runtime.command_names()
    handler = core_runtime._MAIN_THREAD_COMMANDS["t3code_integration"].handler
    reconciled = []

    from jrbar import t3_compat

    def reconcile(target, settings):
        reconciled.append(settings.t3code_enabled)
        target._t3_snapshot_service = SimpleNamespace(
            observation=lambda: SimpleNamespace(snapshot=None, reason=None, in_flight=True)
        )

    monkeypatch.setattr(t3_compat, "update_t3_snapshot_runtime", reconcile)
    controller = SimpleNamespace(_core_log=lambda message: None)

    with pytest.raises(CommandError) as invalid:
        handler(controller, {"enabled": "yes"})
    assert invalid.value.code == "invalid_args"

    status = handler(controller, {})
    assert status["enabled"] is False and status["observation"] is None
    assert reconciled == [], "a status read reconciles nothing"

    _make_database(t3_home)
    reply = handler(controller, {"enabled": True})
    assert reply["present"] is True and reply["enabled"] is True
    assert reconciled == [True]
    assert reply["observation"] == {
        "available": False, "threads": 0, "active": 0, "needs_user": 0, "reason": None, "in_flight": True,
    }

    # A newer build's file reads as off and refuses the switch, untouched.
    path = default_integration_settings_path()
    path.write_text(json.dumps({"settings_schema_version": 999}), encoding="utf-8")
    with pytest.raises(CommandError) as refused:
        handler(controller, {"enabled": True})
    assert refused.value.code == "refused"
    assert reconciled == [True]
