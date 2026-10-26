"""The sealed settings inside the headless daemon.

The ``headless`` fixture comes from ``test_core_runtime`` and ``_Daemon`` from
``test_persistence_daemon`` (the daemon over a real settings file in a
temporary folder). The seal key is a fixed synthetic one handed straight to
``SettingsSeal``, as ``run_core`` does with the key off the stdin pipe; nothing
here touches a Keychain.
"""

from __future__ import annotations

import json
import threading
from pathlib import Path

import pytest
from test_core_runtime import REAL_THREAD
from test_persistence_daemon import _Daemon
from test_refresh_budget import _tick
from test_serve_answers import TOKEN, _call

from jrbar import daemon_controller as legacy
from jrbar import settings as settings_module
from jrbar.core_server import CommandError
from jrbar.serve import create_serve_server
from jrbar.serve_answers import ControllerAnswers
from jrbar.settings_seal import SEAL_FIELD, SealState, SettingsSeal

pytest_plugins = ("test_core_runtime",)

KEY = bytes(range(60, 92))
ANSWER = "/answer?session=claude:synthetic&decision=approve"


@pytest.fixture(autouse=True)
def _no_installed_seal():
    yield
    settings_module.install_document_seal(None)


class _SealedDaemon(_Daemon):
    def __init__(self, headless, monkeypatch, *, key: bytes | None = KEY, sealed_before: bool = False) -> None:
        super().__init__(headless, monkeypatch)
        self.key = key
        self.install(sealed_before=sealed_before)

    def install(self, *, sealed_before: bool) -> None:
        self.seal = SettingsSeal(
            self.key,
            path=self.path,
            previously_sealed=sealed_before,
            log=lambda line: legacy.log_status_bar(line),
            clock=lambda: 1_700_000_000.0,
        )
        settings_module.install_document_seal(self.seal)
        self.controller._core_seal = self.seal

    def adopt(self) -> dict:
        return self.controller._core_dispatch("adopt_seal", {})

    def restart(self) -> None:
        """The daemon starts again over the same file and the same key."""
        self.controller._core_flush_settings()
        self.install(sealed_before=True)
        self.controller.settings = settings_module.load_settings()
        self.controller._core_seal_signature = None

    def shown(self) -> dict:
        return self.settings_frames()[-1]["document"]["settings_seal"]

    def file(self) -> dict:
        return json.loads(self.path.read_text(encoding="utf-8"))

    def flush(self) -> None:
        assert self.controller._core_flush_settings() is True


@pytest.fixture
def sealed(headless, monkeypatch: pytest.MonkeyPatch) -> _SealedDaemon:
    daemon = _SealedDaemon(headless, monkeypatch)
    daemon.adopt()
    return daemon


# --- adopt_seal ------------------------------------------------------------------------


def test_a_new_key_is_not_sealed_until_the_app_adopts_and_then_it_is(headless, monkeypatch) -> None:
    daemon = _SealedDaemon(headless, monkeypatch)
    controller = daemon.controller
    controller._core_publish_settings()

    assert daemon.shown() == {"state": "not_sealed", "changed": None}
    assert SEAL_FIELD not in daemon.file()

    reply = controller._core_dispatch("adopt_seal", {})

    assert reply == {"state": "sealed"}
    assert daemon.shown() == {"state": "sealed", "changed": None}
    assert SEAL_FIELD in daemon.file()
    assert [line for line in daemon.lines if "sealed" in line] == ["core: protected settings sealed"]


def test_adopting_seals_the_values_the_daemon_holds_now(headless, monkeypatch) -> None:
    daemon = _SealedDaemon(headless, monkeypatch)
    controller = daemon.controller
    controller._core_dispatch("set_setting", {"path": "escalation_webhook_url", "value": "https://example.test/h"})
    daemon.flush()

    daemon.adopt()
    daemon.restart()

    assert controller.settings.escalation_webhook_url == "https://example.test/h"
    assert daemon.seal.state is SealState.SEALED and daemon.seal.notice() is None


def test_adopting_without_a_key_says_why(headless, monkeypatch) -> None:
    daemon = _SealedDaemon(headless, monkeypatch, key=None)

    with pytest.raises(CommandError) as refused:
        daemon.controller._core_dispatch("adopt_seal", {})

    assert refused.value.code == "seal_unavailable"
    assert "Keychain" in str(refused.value)


def test_a_daemon_with_no_seal_at_all_reports_unavailable(headless, monkeypatch) -> None:
    daemon = _Daemon(headless, monkeypatch)
    daemon.controller._core_seal = None

    daemon.controller._core_publish_settings()

    assert daemon.settings_frames()[-1]["document"]["settings_seal"] == {"state": "unavailable", "changed": None}
    with pytest.raises(CommandError) as refused:
        daemon.controller._core_dispatch("adopt_seal", {})
    assert refused.value.code == "seal_unavailable"


def test_a_write_that_fails_seals_nothing(headless, monkeypatch) -> None:
    daemon = _SealedDaemon(headless, monkeypatch)
    monkeypatch.setattr(daemon.controller, "_core_flush_settings", lambda: False)

    with pytest.raises(CommandError) as refused:
        daemon.controller._core_dispatch("adopt_seal", {})

    assert refused.value.code == "refused"
    assert daemon.seal.state is SealState.NOT_SEALED


def test_the_settings_seal_is_a_fact_not_a_preference(sealed: _SealedDaemon) -> None:
    with pytest.raises(CommandError) as refused:
        sealed.controller._core_dispatch("set_setting", {"path": "settings_seal.state", "value": "sealed"})

    assert refused.value.code == "read_only"
    assert sealed.controller._core_dispatch("reset_settings", {"paths": ["settings_seal"]})["reset"] == []


# --- the authenticated path updates the seal --------------------------------------------


def test_a_sealed_setting_the_app_changes_is_sealed_in_the_same_write(sealed: _SealedDaemon) -> None:
    controller = sealed.controller
    controller._core_dispatch("set_setting", {"path": "serve_enabled", "value": True})
    controller._core_dispatch("set_setting", {"path": "serve_answer_enabled", "value": True})
    sealed.flush()

    assert sealed.file()["serve_answer_enabled"] is True
    sealed.restart()

    assert controller.settings.serve_answer_enabled is True
    assert sealed.seal.notice() is None
    assert sealed.shown()["changed"] is None


def test_a_display_change_leaves_the_seal_valid(sealed: _SealedDaemon) -> None:
    sealed.controller._core_dispatch("set_setting", {"path": "global_brightness_scale", "value": 0.5})
    sealed.flush()
    mac = sealed.file()[SEAL_FIELD]["mac"]
    sealed.restart()

    assert sealed.controller.settings.global_brightness_scale == 0.5
    assert sealed.seal.notice() is None
    assert sealed.file()[SEAL_FIELD]["mac"] == mac, "no protected value moved, so the seal did not"


# --- a hand edit ------------------------------------------------------------------------


def test_a_hand_edit_is_noticed_within_a_tick_written_over_and_shown(sealed: _SealedDaemon) -> None:
    controller = sealed.controller
    sealed.edit_outside(serve_answer_enabled=True, escalation_webhook_url="https://example.test/theirs")
    sealed.lines.clear()

    controller._core_seal_watch()
    sealed.flush()

    assert controller.settings.serve_answer_enabled is False
    assert controller.settings.escalation_webhook_url == ""
    assert sealed.file()["serve_answer_enabled"] is False, "the held values are written back"
    shown = sealed.shown()["changed"]
    assert shown == {"keys": ["escalation_webhook_url", "serve_answer_enabled"], "at": 1_700_000_000.0, "can_keep": True}
    assert sealed.lines == ["core: settings.json changed a protected setting outside JR-Bar; ignored"]
    rejected = sealed.path.with_name(sealed.path.name + ".rejected")
    assert json.loads(rejected.read_text(encoding="utf-8"))["serve_answer_enabled"] is True


def test_an_unchanged_file_costs_a_stat_not_a_read(sealed: _SealedDaemon, monkeypatch: pytest.MonkeyPatch) -> None:
    controller = sealed.controller
    controller._core_seal_watch()
    reads: list[Path] = []
    real = settings_module._read_document
    monkeypatch.setattr(settings_module, "_read_document", lambda target: reads.append(target) or real(target))

    for _ in range(3):
        controller._core_seal_watch()

    assert reads == []


def test_a_hand_edit_of_an_unprotected_setting_is_taken_as_it_always_was(sealed: _SealedDaemon) -> None:
    controller = sealed.controller
    controller._core_dispatch("set_setting", {"path": "alert_burst", "value": 5})
    sealed.flush()
    sealed.edit_outside(alert_burst=9)
    controller._core_seal_watch()
    controller._core_dispatch("set_setting", {"path": "alert_burst", "value": 6})
    assert controller._core_flush_settings() is False, "the save lost to the outside edit"
    _tick(controller)

    assert controller.settings.alert_burst == 9
    assert sealed.shown()["changed"] is None
    assert sealed.seal.notice() is None


def test_a_hand_edit_while_the_daemon_is_stopped_is_ignored_at_startup(sealed: _SealedDaemon) -> None:
    controller = sealed.controller
    controller._core_dispatch("set_setting", {"path": "escalation_webhook_url", "value": "https://example.test/mine"})
    sealed.flush()
    sealed.edit_outside(serve_answer_enabled=True)

    sealed.restart()

    assert controller.settings.serve_answer_enabled is False
    assert controller.settings.escalation_webhook_url == "https://example.test/mine", (
        "what the daemon sealed last stands in, not the defaults"
    )
    controller._core_seal_watch()
    assert sealed.shown()["changed"]["keys"] == ["serve_answer_enabled"]


def test_keeping_the_change_goes_through_the_command_and_seals_it(sealed: _SealedDaemon) -> None:
    controller = sealed.controller
    sealed.edit_outside(escalation_webhook_url="https://example.test/theirs")
    controller._core_seal_watch()
    sealed.flush()
    assert controller.settings.escalation_webhook_url == ""

    reply = controller._core_dispatch("keep_protected_change", {})

    assert reply == {"state": "sealed", "kept": ["escalation_webhook_url"]}
    assert controller.settings.escalation_webhook_url == "https://example.test/theirs"
    assert sealed.shown()["changed"] is None
    sealed.restart()
    assert controller.settings.escalation_webhook_url == "https://example.test/theirs"
    assert sealed.seal.notice() is None


def test_there_is_nothing_to_keep_when_nothing_was_ignored(sealed: _SealedDaemon) -> None:
    with pytest.raises(CommandError) as refused:
        sealed.controller._core_dispatch("keep_protected_change", {})

    assert refused.value.code == "nothing_to_keep"


def test_a_kept_value_goes_through_the_loaders_rules(sealed: _SealedDaemon) -> None:
    controller = sealed.controller
    sealed.edit_outside(closed_lid_grace_minutes=99999)
    controller._core_seal_watch()
    sealed.flush()

    controller._core_dispatch("keep_protected_change", {})

    assert controller.settings.closed_lid_grace_minutes == settings_module.normalize_closed_lid_grace_minutes(99999)
    assert controller.settings.closed_lid_grace_minutes != 99999
    assert sealed.seal.state is SealState.SEALED


def test_reset_protection_drops_a_foreign_edit_for_good(sealed: _SealedDaemon) -> None:
    controller = sealed.controller
    sealed.edit_outside(serve_answer_enabled=True)
    controller._core_seal_watch()
    sealed.flush()
    assert sealed.shown()["changed"] is not None

    reply = controller._core_dispatch("adopt_seal", {})

    assert reply == {"state": "sealed"}
    assert sealed.shown()["changed"] is None
    assert controller.settings.serve_answer_enabled is False
    with pytest.raises(CommandError):
        controller._core_dispatch("keep_protected_change", {})
    assert [line for line in sealed.lines if "sealed again" in line] == ["core: protected settings sealed again (reset)"]


# --- no key: today's behaviour, said honestly ---------------------------------------------


def test_with_no_key_a_hand_edit_is_taken_as_it_always_was_and_the_app_is_told(headless, monkeypatch) -> None:
    daemon = _SealedDaemon(headless, monkeypatch, key=None)
    controller = daemon.controller
    daemon.edit_outside(serve_answer_enabled=True)
    controller._core_seal_watch()
    controller._core_settings_conflict = "edited"
    _tick(controller)

    assert controller.settings.serve_answer_enabled is True
    assert daemon.shown() == {"state": "unavailable", "changed": None}
    assert SEAL_FIELD not in daemon.file()


# --- the whole point: a hand edit cannot turn answering on ---------------------------------


def _serve(controller):
    server = create_serve_server(port=0, status_access_token=TOKEN, answers=ControllerAnswers(controller))
    thread = REAL_THREAD(target=lambda: server.serve_forever(poll_interval=0.05), daemon=True)
    thread.start()
    return server, f"http://127.0.0.1:{server.server_address[1]}"


def test_switching_answering_on_by_hand_does_not_open_the_answer_route(
    sealed: _SealedDaemon, monkeypatch: pytest.MonkeyPatch
) -> None:
    controller = sealed.controller
    # The headless fixture swaps ``threading.Thread`` for an inert stand-in;
    # the serve server's request deadline needs the real one.
    monkeypatch.setattr(threading, "Thread", REAL_THREAD)
    server, base = _serve(controller)
    try:
        status, body = _call(base + ANSWER)
        assert status == 403 and body["error"]["code"] == "answering_off"

        # A process running as you: turn the switch on in the file, read the
        # token, and make the daemon read the file again (a restart).
        sealed.edit_outside(serve_enabled=True, serve_answer_enabled=True)
        sealed.restart()

        status, body = _call(base + ANSWER)
        assert status == 403 and body["error"]["code"] == "answering_off"
        status, _ = _call(base + "/asks.json", method="GET")
        assert status == 403

        # The person turns it on in the app (the authenticated command).
        controller._core_dispatch("set_setting", {"path": "serve_answer_enabled", "value": True})
        sealed.flush()

        status, body = _call(base + ANSWER)
        assert body is None or body.get("error", {}).get("code") != "answering_off"
        assert status != 403
        sealed.restart()
        assert controller.settings.serve_answer_enabled is True, "and it survives a restart, sealed"
    finally:
        server.shutdown()
        server.server_close()
