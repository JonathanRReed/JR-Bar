"""Sealed settings: a hand edit of a protected setting changes nothing.

The seal is tested as plain functions and through the real settings file layer
with an installed seal, with a fixed synthetic key and a temporary folder. No
Keychain is touched: the daemon never reads one (the app hands it the key), so
there is nothing here to fake on that side.
"""

from __future__ import annotations

import json
import os
import re
import stat
from collections.abc import Iterator
from pathlib import Path
from typing import Any

import pytest

from jrbar import core_auth
from jrbar import settings as settings_module
from jrbar.core_auth import (
    HANDOFF_ENV,
    CoreAuthority,
    adopt_handoff,
    authority_from_process,
    requires_app,
    setting_path_is_open,
)
from jrbar.settings import AgentMonitorSettings, load_settings, save_settings
from jrbar.settings_seal import (
    SEAL_FIELD,
    SEALED_KEYS,
    UNSEALED_PRIVILEGED,
    SealState,
    SettingsSeal,
    seal_mac,
)

KEY = bytes(range(100, 132))
OTHER_KEY = bytes(range(1, 33))
DOC = Path(__file__).resolve().parents[1] / "docs" / "CORE-PROTOCOL.md"
LOGGED_VALUE = "https://example.test/hook-token-1234"


class _Logs:
    def __init__(self) -> None:
        self.lines: list[str] = []

    def __call__(self, line: str) -> None:
        self.lines.append(line)


@pytest.fixture(autouse=True)
def _no_installed_seal() -> Iterator[None]:
    yield
    settings_module.install_document_seal(None)


@pytest.fixture
def home(tmp_path: Path) -> Path:
    folder = tmp_path / "config"
    folder.mkdir(mode=0o700)
    return folder


def _make(home: Path, *, key: bytes | None = KEY, sealed_before: bool = True, logs: _Logs | None = None):
    seal = SettingsSeal(
        key,
        path=home / "settings.json",
        previously_sealed=sealed_before,
        log=logs or _Logs(),
        clock=lambda: 1_700_000_000.0,
    )
    settings_module.install_document_seal(seal)
    return seal


def _seal_defaults(home: Path, **changes: Any) -> SettingsSeal:
    """A first run: seal the defaults (plus ``changes``) the way the daemon does."""
    seal = _make(home, sealed_before=False)
    settings = AgentMonitorSettings()
    for name, value in changes.items():
        settings = _with(settings, name, value)
    seal.begin_adopt(settings.to_dict())
    save_settings(settings, home / "settings.json")
    return seal


def _with(settings: AgentMonitorSettings, name: str, value: Any) -> AgentMonitorSettings:
    from jrbar.core_runtime import settings_from_document

    document = settings.to_dict()
    document[name] = value
    return settings_from_document(document)


def _read(home: Path) -> dict[str, Any]:
    return json.loads((home / "settings.json").read_text(encoding="utf-8"))


def _write(home: Path, document: dict[str, Any]) -> None:
    (home / "settings.json").write_text(json.dumps(document), encoding="utf-8")


def _restart(home: Path, **kwargs: Any) -> tuple[SettingsSeal, _Logs]:
    """A new daemon process over the same file and the same key."""
    logs = _Logs()
    return _make(home, logs=logs, **kwargs), logs


def _tampered(value: object) -> object:
    if isinstance(value, bool):
        return not value
    if isinstance(value, (int, float)):
        return value + 7
    if isinstance(value, str):
        return value + LOGGED_VALUE
    if isinstance(value, list):
        return [*value, "tampered"]
    if isinstance(value, dict):
        return {**value, "tampered": True}
    return "tampered"


# --- the list ----------------------------------------------------------------------


def test_every_setting_is_sorted_into_open_sealed_or_reviewed_unsealed() -> None:
    document_keys = set(AgentMonitorSettings().to_dict())
    open_keys = set(core_auth.OPEN_SETTING_ROOTS)
    sealed = set(SEALED_KEYS)
    unsealed = set(UNSEALED_PRIVILEGED)

    assert document_keys - open_keys - sealed - unsealed == set(), (
        "a setting nobody decided about: seal it (settings_seal.SEALED_KEYS), or name why it "
        "grants nothing (UNSEALED_PRIVILEGED), or make it a display preference (core_auth)"
    )
    assert sealed - document_keys == set(), "a sealed key the settings no longer have"
    assert unsealed - document_keys == set(), "a reviewed-unsealed key the settings no longer have"
    assert sealed & open_keys == set()
    assert sealed & unsealed == set()
    assert unsealed & open_keys == set()


def test_no_sealed_key_is_a_display_preference_so_an_unauthenticated_set_cannot_reach_it() -> None:
    for name in SEALED_KEYS:
        assert not setting_path_is_open(name)
        assert not setting_path_is_open(f"{name}.enabled")
        assert requires_app("set_setting", {"path": name, "value": True})
    assert requires_app("reset_settings", {"paths": list(SEALED_KEYS)})


def test_the_capabilities_the_gap_names_are_all_sealed() -> None:
    named = {
        "serve_answer_enabled",
        "serve_enabled",
        "escalation_webhook_url",
        "webhook_events",
        "cloud_ingest_enabled",
        "remote_peers",
        "usage_hooks",
        "usage_event_hook_path",
        "claude_plan_limits_enabled",
        "provider_status_feeds_enabled",
        "provider_update_checks_enabled",
        "cliproxy_hub",
        "provider_extra_homes",
        "closed_lid_awake_policy",
        "global_action_shortcuts",
    }
    assert named <= set(SEALED_KEYS)


def test_the_protocol_doc_names_exactly_the_sealed_keys() -> None:
    text = DOC.read_text(encoding="utf-8")
    section = text[text.index("### Protected settings") : text.index("## Daemon → app")]
    bullet = section[section.index("**The sealed keys**") : section.index("**The seal**")]
    named = set(re.findall(r"`([a-z_]+)`", bullet)) - {"jrbar", "OPEN_SETTING_ROOTS"}
    named = {name for name in named if name in set(AgentMonitorSettings().to_dict()) | set(SEALED_KEYS)}

    assert named == set(SEALED_KEYS)


def test_the_seal_commands_are_privileged_and_named_in_the_doc() -> None:
    for name in ("adopt_seal", "keep_protected_change"):
        assert core_auth.privilege_of(name) == core_auth.PRIVILEGED
        assert core_auth.COMMAND_PRIVILEGE[name] == core_auth.PRIVILEGED
        assert requires_app(name, {})
        assert f"`{name}`" in DOC.read_text(encoding="utf-8")
    assert CoreAuthority(bytes(32)).requires_app("adopt_seal", {})


# --- the MAC -----------------------------------------------------------------------


def test_the_mac_is_stable_whatever_the_key_order_or_spacing() -> None:
    names = ("serve_answer_enabled", "escalation_webhook_url")
    first = seal_mac(KEY, {"serve_answer_enabled": False, "escalation_webhook_url": "", "x": 1}, names)
    second = seal_mac(KEY, {"x": 2, "escalation_webhook_url": "", "serve_answer_enabled": False}, names)

    assert first == second and re.fullmatch(r"[0-9a-f]{64}", first)


def test_the_mac_covers_values_names_and_absence_and_depends_on_the_key() -> None:
    names = ("serve_answer_enabled", "escalation_webhook_url")
    document = {"serve_answer_enabled": False, "escalation_webhook_url": ""}
    base = seal_mac(KEY, document, names)

    assert seal_mac(KEY, {**document, "serve_answer_enabled": True}, names) != base
    assert seal_mac(KEY, {"serve_answer_enabled": False}, names) != base, "absent is not empty"
    assert seal_mac(KEY, document, names[:1]) != base, "the names covered are covered"
    assert seal_mac(OTHER_KEY, document, names) != base
    assert seal_mac(KEY, {**document, "serve_answer_enabled": 0}, names) != base, "0 is not False"
    with pytest.raises(ValueError):
        seal_mac(KEY, {"serve_answer_enabled": float("nan")}, names)


def test_the_key_must_be_32_bytes(home: Path) -> None:
    with pytest.raises(ValueError):
        SettingsSeal(b"short", path=home / "settings.json")


# --- sealing and checking a real file ----------------------------------------------


def test_a_sealed_save_loads_back_as_the_daemon_wrote_it(home: Path) -> None:
    _seal_defaults(home, serve_answer_enabled=True, escalation_webhook_url="https://example.test/h")

    seal, logs = _restart(home)
    loaded = load_settings(home / "settings.json")

    assert loaded.serve_answer_enabled is True
    assert loaded.escalation_webhook_url == "https://example.test/h"
    assert seal.notice() is None and logs.lines == []
    record = _read(home)[SEAL_FIELD]
    assert record["v"] == 1 and record["keys"] == sorted(SEALED_KEYS)
    assert re.fullmatch(r"[0-9a-f]{64}", record["mac"])


@pytest.mark.parametrize("name", SEALED_KEYS)
def test_a_hand_edit_of_each_sealed_key_is_ignored_and_noticed(home: Path, name: str) -> None:
    _seal_defaults(home)
    edited = _read(home)
    edited[name] = _tampered(edited[name])
    _write(home, edited)

    seal, logs = _restart(home)
    loaded = load_settings(home / "settings.json")

    assert loaded.to_dict()[name] == AgentMonitorSettings().to_dict()[name]
    notice = seal.notice()
    assert notice is not None and notice.keys == (name,) and notice.can_keep
    assert [line for line in logs.lines if "protected setting" in line] == [
        "core: settings.json changed a protected setting outside JR-Bar; ignored"
    ]
    assert seal.needs_rewrite()


def test_answering_switched_on_by_hand_never_reaches_the_daemon(home: Path) -> None:
    _seal_defaults(home)
    edited = _read(home)
    edited["serve_answer_enabled"] = True
    edited["serve_enabled"] = True
    edited["escalation_webhook_url"] = LOGGED_VALUE
    _write(home, edited)

    seal, logs = _restart(home)
    loaded = load_settings(home / "settings.json")

    assert loaded.serve_answer_enabled is False and loaded.serve_enabled is False
    assert loaded.escalation_webhook_url == ""
    assert sorted(seal.notice().keys) == ["escalation_webhook_url", "serve_answer_enabled", "serve_enabled"]
    assert all(LOGGED_VALUE not in line for line in logs.lines), "a value never goes to the log"


def test_the_ignored_edit_is_kept_as_evidence_and_written_over_on_the_next_save(home: Path) -> None:
    _seal_defaults(home)
    edited = _read(home)
    edited["serve_answer_enabled"] = True
    _write(home, edited)
    seal, _logs = _restart(home)
    settings = load_settings(home / "settings.json")

    evidence = home / "settings.json.rejected"
    assert json.loads(evidence.read_text(encoding="utf-8"))["serve_answer_enabled"] is True
    assert stat.S_IMODE(evidence.stat().st_mode) == 0o600
    assert _read(home)["serve_answer_enabled"] is True, "the file is not touched by a load"

    save_settings(settings, home / "settings.json")

    assert _read(home)["serve_answer_enabled"] is False
    assert not seal.needs_rewrite()
    again, again_logs = _restart(home)
    assert load_settings(home / "settings.json").serve_answer_enabled is False
    assert again.notice() is not None, "the notice survives the restart until a person answers it"
    assert again.notice().can_keep, "and so does what it would keep, from the evidence file"
    assert again_logs.lines == []


def test_other_settings_still_follow_a_hand_edit(home: Path) -> None:
    _seal_defaults(home)
    edited = _read(home)
    edited["tips_enabled"] = False
    edited["alert_burst"] = 9
    edited["calendar_alerts_enabled"] = True
    edited["a_field_this_build_does_not_know"] = {"kept": True}
    _write(home, edited)

    seal, logs = _restart(home)
    loaded = load_settings(home / "settings.json")

    assert loaded.tips_enabled is False and loaded.alert_burst == 9
    assert loaded.calendar_alerts_enabled is True
    assert seal.notice() is None and logs.lines == []
    save_settings(loaded, home / "settings.json")
    assert _read(home)["a_field_this_build_does_not_know"] == {"kept": True}
    again, _ = _restart(home)
    assert load_settings(home / "settings.json").tips_enabled is False and again.notice() is None


def test_a_missing_seal_on_a_mac_that_has_sealed_ignores_a_protected_value_it_never_sealed(home: Path) -> None:
    _seal_defaults(home)
    edited = _read(home)
    edited["serve_answer_enabled"] = True
    del edited[SEAL_FIELD]
    _write(home, edited)

    seal, _logs = _restart(home)
    loaded = load_settings(home / "settings.json")

    assert loaded.serve_answer_enabled is False
    assert seal.notice().keys == ("serve_answer_enabled",)


def test_a_missing_seal_over_the_values_last_sealed_changes_nothing_and_is_sealed_again(home: Path) -> None:
    _seal_defaults(home, serve_answer_enabled=True)
    edited = _read(home)
    del edited[SEAL_FIELD]
    _write(home, edited)

    seal, logs = _restart(home)
    loaded = load_settings(home / "settings.json")

    assert loaded.serve_answer_enabled is True, "it is the value the daemon sealed last"
    assert seal.notice() is None and logs.lines == []
    assert seal.needs_rewrite(), "the next save puts a seal back"
    save_settings(loaded, home / "settings.json")
    assert SEAL_FIELD in _read(home)


def test_with_no_snapshot_the_defaults_stand_in_at_startup(home: Path) -> None:
    _seal_defaults(home, serve_answer_enabled=True)
    (home / "settings.json.sealed").unlink()
    edited = _read(home)
    del edited[SEAL_FIELD]
    _write(home, edited)

    seal, _logs = _restart(home)

    assert load_settings(home / "settings.json").serve_answer_enabled is False
    assert seal.notice().keys == ("serve_answer_enabled",)


def test_a_snapshot_someone_edited_is_no_snapshot(home: Path) -> None:
    _seal_defaults(home)
    snapshot = json.loads((home / "settings.json.sealed").read_text(encoding="utf-8"))
    snapshot["values"]["serve_answer_enabled"] = True
    (home / "settings.json.sealed").write_text(json.dumps(snapshot), encoding="utf-8")
    edited = _read(home)
    edited["serve_answer_enabled"] = True
    del edited[SEAL_FIELD]
    _write(home, edited)

    seal, _logs = _restart(home)

    assert load_settings(home / "settings.json").serve_answer_enabled is False
    assert seal.notice() is not None


def test_the_snapshot_is_private_and_carries_a_mac(home: Path) -> None:
    _seal_defaults(home)
    path = home / "settings.json.sealed"

    assert stat.S_IMODE(path.stat().st_mode) == 0o600
    record = json.loads(path.read_text(encoding="utf-8"))
    assert record["mac"] == seal_mac(KEY, record["values"], tuple(record["keys"]))


def test_a_seal_made_with_another_key_is_no_seal(home: Path) -> None:
    _seal_defaults(home)
    forged = _read(home)
    forged["serve_answer_enabled"] = True
    forged[SEAL_FIELD]["mac"] = seal_mac(OTHER_KEY, forged, SEALED_KEYS)
    _write(home, forged)

    seal, _logs = _restart(home)

    assert load_settings(home / "settings.json").serve_answer_enabled is False
    assert seal.notice() is not None


def test_a_seal_with_fewer_names_does_not_vouch_for_the_rest(home: Path) -> None:
    _seal_defaults(home)
    edited = _read(home)
    edited["serve_answer_enabled"] = True
    edited[SEAL_FIELD]["keys"] = [name for name in SEALED_KEYS if name != "serve_answer_enabled"]
    edited[SEAL_FIELD]["mac"] = "0" * 64
    _write(home, edited)

    seal, _logs = _restart(home)

    assert load_settings(home / "settings.json").serve_answer_enabled is False
    assert seal.notice() is not None


def test_a_running_daemon_keeps_the_values_it_held_not_the_defaults(home: Path) -> None:
    seal = _seal_defaults(home, escalation_webhook_url="https://example.test/mine")
    assert load_settings(home / "settings.json").escalation_webhook_url == "https://example.test/mine"
    edited = _read(home)
    edited["escalation_webhook_url"] = "https://example.test/theirs"
    edited["serve_answer_enabled"] = True
    _write(home, edited)

    loaded = load_settings(home / "settings.json", track=False)

    assert loaded.escalation_webhook_url == "https://example.test/mine"
    assert loaded.serve_answer_enabled is False
    assert seal.notice().keys == ("escalation_webhook_url", "serve_answer_enabled")


def test_an_edit_is_logged_once_however_often_the_file_is_read(home: Path) -> None:
    _seal_defaults(home)
    edited = _read(home)
    edited["serve_answer_enabled"] = True
    _write(home, edited)
    _seal, logs = _restart(home)

    for _ in range(5):
        load_settings(home / "settings.json", track=False)
    assert len(logs.lines) == 1

    edited["serve_enabled"] = True
    _write(home, edited)
    load_settings(home / "settings.json", track=False)
    assert len(logs.lines) == 2, "a different edit is news again"


def test_taking_an_outside_edit_ignores_a_protected_value_and_takes_the_rest(home: Path) -> None:
    _seal_defaults(home)
    current = load_settings(home / "settings.json")
    edited = _read(home)
    edited["serve_answer_enabled"] = True
    edited["tips_enabled"] = False
    _write(home, edited)

    adoption = settings_module.adopt_outside_edit(current, home / "settings.json")

    assert adoption.outcome is settings_module.OutsideEditOutcome.ADOPTED
    assert adoption.settings.serve_answer_enabled is False
    assert adoption.settings.tips_enabled is False


def test_an_edit_of_only_a_protected_value_is_an_outside_edit_that_changes_nothing(home: Path) -> None:
    _seal_defaults(home)
    current = load_settings(home / "settings.json")
    edited = _read(home)
    edited["serve_answer_enabled"] = True
    _write(home, edited)

    adoption = settings_module.adopt_outside_edit(current, home / "settings.json")

    assert adoption.outcome is settings_module.OutsideEditOutcome.UNCHANGED
    assert adoption.settings.serve_answer_enabled is False


def test_a_save_blesses_only_what_the_daemon_holds_not_what_the_file_gained(home: Path) -> None:
    _seal_defaults(home)
    settings = load_settings(home / "settings.json")
    edited = _read(home)
    edited["serve_answer_enabled"] = True
    edited["remote_peers"] = {"enabled": True, "smuggled": {"deep": 1}}
    _write(home, edited)
    settings_module.adopt_outside_edit(settings, home / "settings.json")

    save_settings(settings, home / "settings.json")

    written = _read(home)
    assert written["serve_answer_enabled"] is False
    assert "smuggled" not in json.dumps(written["remote_peers"])
    _seal, _ = _restart(home)
    assert load_settings(home / "settings.json").serve_answer_enabled is False


# --- the states without a seal -------------------------------------------------------


def test_with_no_key_the_daemon_behaves_as_it_always_did(home: Path) -> None:
    logs = _Logs()
    seal = _make(home, key=None, logs=logs)
    _write(home, {"settings_schema_version": 2, "serve_answer_enabled": True})

    loaded = load_settings(home / "settings.json")
    save_settings(loaded, home / "settings.json")

    assert seal.state is SealState.UNAVAILABLE
    assert loaded.serve_answer_enabled is True
    assert SEAL_FIELD not in _read(home)
    assert logs.lines == []
    assert seal.document() == {"state": "unavailable", "changed": None}


def test_a_new_key_seals_nothing_until_the_app_adopts(home: Path) -> None:
    logs = _Logs()
    seal = _make(home, sealed_before=False, logs=logs)
    _write(home, {"settings_schema_version": 2, "serve_answer_enabled": True, "webhook_events": []})

    first = load_settings(home / "settings.json")
    load_settings(home / "settings.json", track=False)
    save_settings(first, home / "settings.json")

    assert first.serve_answer_enabled is True, "an existing install keeps what it has until the app adopts it"
    assert seal.state is SealState.NOT_SEALED and SEAL_FIELD not in _read(home)
    assert logs.lines == ["core: settings not sealed yet; protected settings are taken from the file"]

    seal.begin_adopt(first.to_dict())
    save_settings(first, home / "settings.json")

    assert seal.state is SealState.SEALED
    again, _ = _restart(home)
    assert load_settings(home / "settings.json").serve_answer_enabled is True
    assert again.notice() is None


def test_adopting_replaces_a_foreign_edit_with_what_the_daemon_holds(home: Path) -> None:
    seal = _seal_defaults(home)
    edited = _read(home)
    edited["serve_answer_enabled"] = True
    _write(home, edited)
    held = load_settings(home / "settings.json")
    assert seal.notice() is not None

    seal.begin_adopt(held.to_dict())
    save_settings(held, home / "settings.json")

    assert seal.notice() is None and not seal.needs_rewrite()
    assert _read(home)["serve_answer_enabled"] is False


def test_a_failed_adopt_leaves_the_seal_as_it_was(home: Path) -> None:
    seal = _make(home, sealed_before=False)
    before = seal.begin_adopt(AgentMonitorSettings().to_dict())
    assert seal.state is SealState.SEALED

    seal.restore(before)

    assert seal.state is SealState.NOT_SEALED


def test_a_file_a_former_run_sealed_is_trusted_when_the_app_could_not_record_it(home: Path) -> None:
    _seal_defaults(home, serve_answer_enabled=True)

    seal = _make(home, sealed_before=False)
    loaded = load_settings(home / "settings.json")

    assert loaded.serve_answer_enabled is True
    assert seal.state is SealState.SEALED and seal.notice() is None


def test_a_seal_is_never_checked_against_another_file(home: Path, tmp_path: Path) -> None:
    _seal_defaults(home)
    other = tmp_path / "elsewhere.json"
    other.write_text(json.dumps({"settings_schema_version": 2, "serve_answer_enabled": True}), encoding="utf-8")

    assert load_settings(other).serve_answer_enabled is True


def test_a_seal_check_that_fails_closes_the_protected_keys(home: Path, monkeypatch: pytest.MonkeyPatch) -> None:
    seal = _seal_defaults(home)
    edited = _read(home)
    edited["serve_answer_enabled"] = True
    _write(home, edited)

    def broken(*_args: Any, **_kwargs: Any) -> Any:
        raise RuntimeError("synthetic")

    monkeypatch.setattr(seal, "view", broken)

    assert load_settings(home / "settings.json").serve_answer_enabled is False


# --- the key's hand-off ----------------------------------------------------------------


def _pipe(payload: bytes) -> int:
    read, write = os.pipe()
    os.write(write, payload)
    os.close(write)
    return read


def test_the_key_comes_over_the_same_pipe_as_the_secret_and_nowhere_else() -> None:
    secret = bytes(range(32))
    for announced, is_new in (("2", False), ("3", True)):
        env = {HANDOFF_ENV: announced}
        fd = _pipe(secret + KEY)
        try:
            handoff = adopt_handoff(env, fd=fd)
        finally:
            os.close(fd)
        assert handoff.secret == secret and handoff.seal_key == KEY
        assert handoff.seal_key_is_new is is_new
        assert HANDOFF_ENV not in env


def test_a_secret_alone_carries_no_key_and_a_short_pipe_carries_nothing() -> None:
    secret = bytes(range(32))
    fd = _pipe(secret)
    try:
        alone = adopt_handoff({HANDOFF_ENV: "1"}, fd=fd)
    finally:
        os.close(fd)
    assert alone.secret == secret and alone.seal_key is None

    fd = _pipe(secret)
    try:
        short = adopt_handoff({HANDOFF_ENV: "2"}, fd=fd, wait_seconds=0.05)
    finally:
        os.close(fd)
    assert short.secret is None and short.seal_key is None, "half a hand-off is none"


def test_the_authority_carries_the_key_and_whether_it_is_new() -> None:
    secret = bytes(range(32))
    fd = _pipe(secret + KEY)
    try:
        authority = authority_from_process({HANDOFF_ENV: "3"}, frozen=True, fd=fd)
    finally:
        os.close(fd)

    assert authority.has_secret and authority.seal_key == KEY and authority.seal_key_is_new
    assert CoreAuthority.closed().seal_key is None
    with pytest.raises(ValueError):
        CoreAuthority(secret, seal_key=b"short")


def test_the_key_is_not_in_the_environment_or_the_arguments_of_a_child() -> None:
    # The hand-off removes the variable and points stdin at /dev/null, as for the secret.
    env = {HANDOFF_ENV: "2"}
    fd = _pipe(bytes(range(32)) + KEY)
    stdin_before = os.dup(0)
    try:
        os.dup2(fd, 0)
        adopt_handoff(env)
        mode = os.fstat(0).st_mode
        remaining = os.read(0, 1)
    finally:
        os.dup2(stdin_before, 0)
        os.close(stdin_before)
        os.close(fd)

    assert env == {} and not stat.S_ISFIFO(mode) and remaining == b""
