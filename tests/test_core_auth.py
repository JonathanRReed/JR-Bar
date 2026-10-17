"""The core socket takes privileged commands from the JR-Bar app alone.

The handshake and the privilege table are tested as plain functions, then
through a real in-process daemon socket with two connections: one that proves
the app's secret and one that does not. All data is synthetic.
"""

from __future__ import annotations

import hashlib
import hmac
import json
import os
import re
import shutil
import socket
import subprocess
import sys
import tempfile
import threading
from pathlib import Path
from typing import Any

import pytest

from jrbar import core_auth, core_runtime
from jrbar.core_auth import (
    COMMAND_PRIVILEGE,
    CoreAuthority,
    adopt_handoff_secret,
    auth_proof,
    authority_from_process,
    privilege_of,
    requires_app,
    setting_path_is_open,
)
from jrbar.core_server import CommandError, CommandRouter, CoreServer
from jrbar.settings import AgentMonitorSettings, DeviceDisplaySetting

SECRET = bytes(range(32))
DOC = Path(__file__).resolve().parents[1] / "docs" / "CORE-PROTOCOL.md"


# --- the handshake as plain functions -----------------------------------------


def test_the_proof_is_an_hmac_sha256_over_the_nonce_and_never_the_secret() -> None:
    nonce = "0123456789abcdef0123456789abcdef"
    expected = hmac.new(SECRET, b"jrbar-core-auth-v1\n" + nonce.encode(), hashlib.sha256).hexdigest()

    assert auth_proof(SECRET, nonce) == expected
    assert len(expected) == 64
    assert SECRET.hex() not in expected
    assert auth_proof(SECRET, nonce) != auth_proof(SECRET, "f" * 32)
    assert auth_proof(bytes(32), nonce) != expected


def test_the_authority_accepts_only_the_right_proof_for_the_nonce() -> None:
    authority = CoreAuthority(SECRET)
    challenge = authority.new_challenge()

    assert challenge is not None and challenge["scheme"] == "hmac-sha256"
    nonce = challenge["nonce"]
    assert re.fullmatch(r"[0-9a-f]{32}", nonce)
    assert authority.check_proof(nonce, auth_proof(SECRET, nonce))
    assert not authority.check_proof(nonce, auth_proof(SECRET, "0" * 32))
    assert not authority.check_proof(nonce, auth_proof(bytes(32), nonce))
    assert not authority.check_proof(nonce, "")
    assert not authority.check_proof(nonce, None)
    assert not authority.check_proof(nonce, 12345)
    # A proof with non-ASCII bytes is a mismatch, not an exception.
    assert not authority.check_proof(nonce, "é" * 64)
    assert authority.new_challenge()["nonce"] != nonce


def test_the_proof_compare_is_constant_time(monkeypatch: pytest.MonkeyPatch) -> None:
    calls: list[tuple[bytes, bytes]] = []
    real = hmac.compare_digest

    def spy(left: Any, right: Any) -> bool:
        calls.append((left, right))
        return real(left, right)

    monkeypatch.setattr(core_auth.hmac, "compare_digest", spy)
    authority = CoreAuthority(SECRET)
    assert authority.check_proof("a" * 32, "b" * 64) is False
    assert len(calls) == 1


def test_a_daemon_with_no_secret_offers_no_challenge_and_accepts_no_proof() -> None:
    authority = CoreAuthority.closed()

    assert authority.has_secret is False
    assert authority.new_challenge() is None
    assert authority.check_proof("a" * 32, auth_proof(SECRET, "a" * 32)) is False
    assert "JRBAR_DEV_ALLOW_UNAUTH" in authority.refusal_message()
    assert "JR-Bar" in CoreAuthority(SECRET).refusal_message()
    assert "Settings" in CoreAuthority(SECRET).refusal_message()


def test_bad_proofs_wait_longer_each_time_and_the_wait_is_capped() -> None:
    now = [100.0]
    authority = CoreAuthority(SECRET, clock=lambda: now[0])

    delays = [authority.record_failure() for _ in range(8)]

    assert delays[0] == pytest.approx(0.1)
    assert delays[1] == pytest.approx(0.2)
    assert delays == sorted(delays)
    assert max(delays) == authority.MAX_FAILURE_DELAY_SECONDS
    now[0] += 61.0
    assert authority.record_failure() == pytest.approx(0.1)


def test_the_secret_must_be_32_bytes() -> None:
    with pytest.raises(ValueError):
        CoreAuthority(b"short")


# --- the secret hand-off ------------------------------------------------------


def _pipe_with(data: bytes) -> int:
    read_end, write_end = os.pipe()
    os.write(write_end, data)
    os.close(write_end)
    return read_end


def test_the_hand_off_reads_32_bytes_from_a_pipe_once_and_clears_the_variable() -> None:
    env = {"JRBAR_AUTH_STDIN": "1"}
    descriptor = _pipe_with(SECRET)
    try:
        assert adopt_handoff_secret(env, fd=descriptor, wait_seconds=1.0) == SECRET
        # The descriptor now reads end-of-file: nothing is left for a child.
        assert os.read(descriptor, 64) == b""
    finally:
        os.close(descriptor)
    assert "JRBAR_AUTH_STDIN" not in env


def test_no_announcement_means_no_secret_and_stdin_is_left_alone() -> None:
    descriptor = _pipe_with(SECRET)
    try:
        assert adopt_handoff_secret({}, fd=descriptor, wait_seconds=0.1) is None
        assert os.read(descriptor, 64) == SECRET
    finally:
        os.close(descriptor)


@pytest.mark.parametrize("payload", [b"", b"too short", SECRET[:31]])
def test_a_short_or_missing_secret_is_no_secret(payload: bytes) -> None:
    lines: list[str] = []
    descriptor = _pipe_with(payload)
    try:
        secret = adopt_handoff_secret(
            {"JRBAR_AUTH_STDIN": "1"}, fd=descriptor, wait_seconds=0.2, log=lines.append
        )
    finally:
        os.close(descriptor)
    assert secret is None
    assert any("did not arrive" in line for line in lines)


def test_a_secret_is_not_taken_from_anything_but_a_pipe(tmp_path: Path) -> None:
    lines: list[str] = []
    path = tmp_path / "not-a-pipe"
    path.write_bytes(SECRET)
    descriptor = os.open(path, os.O_RDONLY)
    try:
        secret = adopt_handoff_secret(
            {"JRBAR_AUTH_STDIN": "1"}, fd=descriptor, wait_seconds=0.2, log=lines.append
        )
    finally:
        os.close(descriptor)
    assert secret is None
    assert any("not a pipe" in line for line in lines)


def test_the_development_bypass_is_ignored_by_the_frozen_release_and_by_a_held_secret() -> None:
    frozen_lines: list[str] = []
    frozen = authority_from_process(
        {"JRBAR_DEV_ALLOW_UNAUTH": "1"}, frozen=True, fd=-1, log=frozen_lines.append
    )
    assert frozen.dev_allow_unauth is False
    assert any("ignored by the release daemon" in line for line in frozen_lines)

    source = authority_from_process({"JRBAR_DEV_ALLOW_UNAUTH": "1"}, frozen=False, fd=-1)
    assert source.dev_allow_unauth is True
    assert source.requires_app("answer_ask", {}) is False

    plain = authority_from_process({}, frozen=False, fd=-1)
    assert plain.dev_allow_unauth is False
    assert plain.requires_app("answer_ask", {}) is True

    read_end = _pipe_with(SECRET)
    try:
        with_secret = authority_from_process(
            {"JRBAR_AUTH_STDIN": "1", "JRBAR_DEV_ALLOW_UNAUTH": "1"},
            frozen=False,
            fd=read_end,
            wait_seconds=1.0,
        )
    finally:
        os.close(read_end)
    assert with_secret.has_secret and with_secret.dev_allow_unauth is False


def test_the_bypass_variable_is_read_once_and_removed_from_the_environment() -> None:
    env = {"JRBAR_DEV_ALLOW_UNAUTH": "1"}
    authority_from_process(env, frozen=False, fd=-1)
    assert "JRBAR_DEV_ALLOW_UNAUTH" not in env


_CHILD_PROBE = r"""
import json, os, subprocess, sys
from jrbar.core_auth import authority_from_process
authority = authority_from_process()
grandchild = subprocess.run(
    [sys.executable, "-I", "-c",
     "import json, os, sys\n"
     "print(json.dumps({'env': dict(os.environ), 'argv': sys.argv, 'stdin': os.read(0, 64).hex()}))"],
    capture_output=True, text=True, timeout=30,
)
print(json.dumps({"has_secret": authority.has_secret, "env": dict(os.environ),
                  "argv": sys.argv, "grandchild": json.loads(grandchild.stdout)}))
"""


def test_the_secret_is_in_no_environment_argument_or_inherited_stdin_of_a_child() -> None:
    source = str(Path(__file__).resolve().parents[1] / "src")
    environment = {**os.environ, "PYTHONPATH": source, "JRBAR_AUTH_STDIN": "1"}
    environment.pop("JRBAR_DEV_ALLOW_UNAUTH", None)
    process = subprocess.Popen(
        [sys.executable, "-c", _CHILD_PROBE],
        stdin=subprocess.PIPE,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        env=environment,
    )
    output, errors = process.communicate(SECRET, timeout=60)
    assert process.returncode == 0, errors.decode()
    report = json.loads(output)

    assert report["has_secret"] is True
    for side in (report, report["grandchild"]):
        text = json.dumps(side["env"]) + json.dumps(side["argv"])
        assert SECRET.hex() not in text
        assert "JRBAR_AUTH_STDIN" not in side["env"]
    assert report["grandchild"]["stdin"] == ""


# --- the privilege table ------------------------------------------------------


def test_every_registered_command_has_a_row_in_the_privilege_table() -> None:
    registered = set(core_runtime.command_names())

    assert registered - set(COMMAND_PRIVILEGE) == set(), (
        "a command was registered without deciding who may send it: add it to "
        "core_auth._OPEN_COMMANDS or _PRIVILEGED_COMMANDS"
    )
    assert set(COMMAND_PRIVILEGE) - registered == set(), "the table names a command the daemon lacks"


def test_provider_source_options_require_the_authenticated_app() -> None:
    for name in ("set_provider_options", "set_provider_usage_consent"):
        assert COMMAND_PRIVILEGE.get(name) == "privileged"
        assert requires_app(name, {"provider": "kimi", "options": {"source": "api"}})


def test_a_command_the_table_does_not_know_is_privileged() -> None:
    assert privilege_of("a_command_added_next_year") == "privileged"
    assert privilege_of(None) == "privileged"
    assert privilege_of(17) == "privileged"
    assert requires_app("a_command_added_next_year", {}) is True


def test_everything_that_answers_or_grants_is_privileged() -> None:
    privileged = (
        "answer_ask", "deck_answer", "deck_press", "serve_token", "install_hooks",
        "uninstall_hooks", "refresh_hooks", "usage_hooks_test", "provider_consent",
        "set_provider_enabled", "provider_action", "provider_sign_in", "set_closed_lid_policy",
        "claude_statusline_install", "claude_statusline_uninstall", "new_session",
        "resume_session", "open_session", "quit", "presence", "deck_set_settings",
        "deck_apply_keymap", "provider_add_instance",
    )
    for name in privileged:
        assert privilege_of(name) == "privileged", name
        assert requires_app(name, {}) is True, name


def test_status_reads_and_the_low_risk_verbs_are_open() -> None:
    for name in ("ping", "list_history", "list_roster", "doctor", "replay_events", "quiet",
                 "snooze", "confetti", "hold_awake", "release_awake", "refresh_usage",
                 "set_brightness", "usage_graph", "hooks_doctor"):
        assert requires_app(name, {}) is False, name


@pytest.mark.parametrize(
    "path",
    [
        "serve_answer_enabled", "serve_enabled", "escalation_webhook_url", "webhook_events",
        "cloud_ingest_enabled", "remote_peers", "remote_peers.enabled", "usage_hooks",
        "usage_event_hook_path", "claude_plan_limits_enabled", "claude_plan_limits_consent_version",
        "claude_statusline_source", "closed_lid_awake_policy", "closed_lid_grace_minutes",
        "global_action_shortcuts", "provider_extra_homes", "cliproxy_hub", "calendar_alerts_enabled",
        "reminder_alerts_enabled", "provider_status_feeds_enabled", "provider_update_checks_enabled",
        "capacity_history_enabled", "transcript_monitoring.codex", "devices.0.path",
        "devices.0.name", "devices.0.id", "devices.x.brightness", "devices.0", "devices", "",
        "pricing_overrides", "a_setting_added_next_year",
    ],
)
def test_consent_egress_program_and_path_settings_are_privileged(path: str) -> None:
    assert setting_path_is_open(path) is False
    assert requires_app("set_setting", {"path": path, "value": True}) is True
    assert requires_app("reset_settings", {"paths": [path]}) is True


@pytest.mark.parametrize(
    "path",
    ["global_brightness_scale", "active_scene", "colors.mode_colors.idle", "led_display",
     "idle_dim_fraction", "screen_bar_min_glow", "devices.0.brightness", "devices.12.blend_mode"],
)
def test_display_preferences_stay_open_to_the_terminal(path: str) -> None:
    assert setting_path_is_open(path) is True
    assert requires_app("set_setting", {"path": path, "value": 0.5}) is False
    assert requires_app("reset_settings", {"paths": [path]}) is False


def test_a_reset_is_open_only_when_every_path_is_a_display_preference() -> None:
    assert requires_app("reset_settings", {"paths": ["active_scene", "serve_answer_enabled"]}) is True
    assert requires_app("reset_settings", {"paths": []}) is True
    assert requires_app("reset_settings", {}) is True
    assert requires_app("reset_settings", {"paths": "active_scene"}) is True
    assert requires_app("set_setting", {}) is True
    assert requires_app("set_setting", None) is True


def test_the_open_setting_names_are_real_and_none_is_a_consent_or_path_key() -> None:
    document = AgentMonitorSettings().to_dict()
    sensitive = re.compile(
        r"serve|token|webhook|hook|path|consent|cloud|remote|peer|url|home|shortcut|lid|"
        r"provider|credential|keychain|answer|ingest|egress|alert|calendar|reminder|cliproxy"
    )

    for key in core_auth.OPEN_SETTING_ROOTS:
        assert key in document, f"{key} is not a setting"
        assert sensitive.search(key) is None, f"{key} looks like a consent, egress or path setting"
    device = DeviceDisplaySetting(device_id="a", name="b", path="c").to_dict()
    for field in core_auth.OPEN_DEVICE_FIELDS:
        assert field in device, f"{field} is not a device field"
    assert not {"id", "name", "path"} & set(core_auth.OPEN_DEVICE_FIELDS)


def test_the_protocol_doc_names_every_open_command_in_its_privilege_section() -> None:
    text = DOC.read_text(encoding="utf-8")
    start = text.index("### Privilege")
    section = text[start : text.index("### What stays outside the socket")]
    open_part, _, privileged_part = section.partition("Privileged commands:")
    for name, kind in COMMAND_PRIVILEGE.items():
        if kind == "open":
            assert f"`{name}`" in open_part, f"{name} is open in the code but not in the doc"
        else:
            assert f"`{name}`" not in open_part, f"{name} is privileged but listed as open"
    for name in ("answer_ask", "serve_token", "install_hooks", "deck_press"):
        assert f"`{name}`" in privileged_part


# --- a real daemon socket, two connections -------------------------------------


@pytest.fixture
def sock_dir():
    path = Path(tempfile.mkdtemp(prefix="jrbar-", dir=tempfile.gettempdir()))
    try:
        yield path
    finally:
        shutil.rmtree(path, ignore_errors=True)


class _Peer:
    """One client connection that reads frames with a bounded wait."""

    def __init__(self, path: Path) -> None:
        self.connection = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
        self.connection.settimeout(5.0)
        self.connection.connect(str(path))
        self.buffer = b""
        self.frames: list[dict[str, Any]] = []
        self.counter = 0

    def close(self) -> None:
        self.connection.close()

    def _next(self) -> dict[str, Any] | None:
        while b"\n" not in self.buffer:
            try:
                chunk = self.connection.recv(65536)
            except TimeoutError:
                return None
            if not chunk:
                return None
            self.buffer += chunk
        line, self.buffer = self.buffer.split(b"\n", 1)
        frame = json.loads(line)
        self.frames.append(frame)
        return frame

    def until(self, kind: str) -> dict[str, Any]:
        for frame in self.frames:
            if frame.get("t") == kind:
                return frame
        while True:
            frame = self._next()
            assert frame is not None, f"the daemon sent no {kind}"
            if frame.get("t") == kind:
                return frame

    def call(self, name: str, args: dict[str, Any] | None = None) -> dict[str, Any]:
        self.counter += 1
        identifier = f"t-{self.counter}"
        frame = {"t": "command", "v": 1, "id": identifier, "name": name, "args": args or {}}
        self.connection.sendall((json.dumps(frame) + "\n").encode())
        while True:
            reply = self._next()
            assert reply is not None, f"no reply to {name}"
            if reply.get("t") == "reply" and reply.get("id") == identifier:
                return reply

    def closed(self) -> bool:
        return self._next() is None

    def authenticate(self, secret: bytes) -> dict[str, Any]:
        nonce = self.until("hello")["auth"]["nonce"]
        return self.call("auth", {"proof": auth_proof(secret, nonce)})


class _Daemon:
    def __init__(self, sock_dir: Path, authority: CoreAuthority | None) -> None:
        self.calls: list[tuple[str, dict[str, Any]]] = []
        self.logs: list[str] = []
        self.waits: list[float] = []
        router = CommandRouter()

        def record(name: str):
            def handler(args: dict[str, Any]) -> dict[str, Any]:
                self.calls.append((name, dict(args)))
                if name == "serve_token":
                    return {"token": "synthetic-token-for-tests"}
                return {"ran": name}

            return handler

        for name in ("ping", "answer_ask", "set_setting", "reset_settings", "serve_token",
                     "install_hooks", "deck_press", "quiet", "confetti",
                     "adopt_seal", "keep_protected_change"):
            router.register(name, record(name))

        def boom(_args: dict[str, Any]) -> None:
            raise CommandError("not_found", "no such session")

        router.register("snooze", boom)
        self.server = CoreServer(
            dispatch=router,
            initial_documents=lambda: [
                {"t": "state", "generation": 1, "sessions": [], "asks": []},
                {"t": "settings", "generation": 1, "document": {"serve_answer_enabled": False}},
            ],
            socket_path=sock_dir / "core.sock",
            core_version="0.0.0-test",
            log=self.logs.append,
            authority=authority,
        )
        self.server.start()

    def peer(self) -> _Peer:
        return _Peer(self.server.socket_path)


@pytest.fixture
def daemon(sock_dir: Path):
    authority = CoreAuthority(SECRET, wait=lambda _seconds: None)
    instance = _Daemon(sock_dir, authority)
    instance.authority = authority  # type: ignore[attr-defined]
    try:
        yield instance
    finally:
        instance.server.stop()


def test_an_unauthenticated_connection_reads_status_but_cannot_answer_or_grant(daemon: _Daemon) -> None:
    stranger = daemon.peer()
    try:
        hello = stranger.until("hello")
        assert hello["auth"]["scheme"] == "hmac-sha256"
        assert stranger.until("state")["generation"] == 1
        assert stranger.until("settings")["document"]["serve_answer_enabled"] is False
        assert stranger.call("ping")["ok"] is True

        attempts = (
            ("answer_ask", {"session": "claude:synthetic", "decision": "approve"}),
            ("set_setting", {"path": "serve_answer_enabled", "value": True}),
            ("serve_token", {}),
            ("install_hooks", {"providers": ["claude"]}),
            ("deck_press", {"index": 0}),
        )
        for name, args in attempts:
            reply = stranger.call(name, args)
            assert reply["ok"] is False, name
            assert reply["error"]["code"] == "unauthenticated", name
            assert "open JR-Bar and use Settings" in reply["error"]["message"], name
        assert stranger.call("ping")["ok"] is True
    finally:
        stranger.close()

    names = [name for name, _args in daemon.calls]
    assert names == ["ping", "ping"], "a privileged command reached its handler"


def test_a_refusal_is_logged_with_the_command_and_peer_but_no_content(daemon: _Daemon) -> None:
    stranger = daemon.peer()
    try:
        stranger.until("hello")
        stranger.call("answer_ask", {"session": "claude:secret-looking-session", "reply_text": "hunter2"})
        stranger.call("answer_ask", {"session": "again"})
    finally:
        stranger.close()

    lines = [line for line in daemon.logs if "refused privileged command" in line]
    assert len(lines) == 1, "one line per command name per interval"
    assert "refused privileged command answer_ask from an unauthenticated connection" in lines[0]
    assert "client " in lines[0]
    joined = "\n".join(daemon.logs)
    assert "hunter2" not in joined and "secret-looking-session" not in joined
    assert daemon.server.stats["refused_privileged"] == 2


def test_a_command_name_chosen_by_the_sender_is_not_logged_raw(daemon: _Daemon) -> None:
    stranger = daemon.peer()
    try:
        stranger.until("hello")
        reply = stranger.call("evil\u2028name with spaces and a very long tail " + "x" * 400)
    finally:
        stranger.close()
    assert reply["error"]["code"] == "unauthenticated"
    assert any("refused privileged command (unnamed)" in line for line in daemon.logs)
    assert not any("evil" in line for line in daemon.logs)


def test_an_unauthenticated_display_preference_and_the_low_risk_verbs_still_work(daemon: _Daemon) -> None:
    stranger = daemon.peer()
    try:
        stranger.until("hello")
        assert stranger.call("set_setting", {"path": "global_brightness_scale", "value": 0.5})["ok"]
        assert stranger.call("quiet", {"mode": "dim", "seconds": 60})["ok"]
        assert stranger.call("confetti", {})["ok"]
        refused = stranger.call("reset_settings", {"paths": ["active_scene", "serve_answer_enabled"]})
        assert refused["error"]["code"] == "unauthenticated"
        # An open command's own refusal still comes through unchanged.
        assert stranger.call("snooze", {"session": "x"})["error"]["code"] == "not_found"
        assert stranger.call("not_a_command_anyone_registered")["error"]["code"] == "unauthenticated"
    finally:
        stranger.close()
    assert [name for name, _ in daemon.calls] == ["set_setting", "quiet", "confetti"]


def test_the_app_connection_proves_the_secret_and_then_sends_privileged_commands(daemon: _Daemon) -> None:
    app = daemon.peer()
    stranger = daemon.peer()
    try:
        reply = app.authenticate(SECRET)
        assert reply["ok"] is True and reply["result"] == {"authenticated": True}
        stranger.until("hello")

        answered = app.call("answer_ask", {"session": "claude:synthetic", "decision": "approve"})
        assert answered["ok"] is True and answered["result"] == {"ran": "answer_ask"}
        assert app.call("set_setting", {"path": "serve_answer_enabled", "value": True})["ok"]
        assert app.call("serve_token")["result"]["token"] == "synthetic-token-for-tests"
        assert app.call("install_hooks", {"providers": ["claude"]})["ok"]
        # Authenticated for the life of the connection, and only that one.
        assert stranger.call("answer_ask", {"session": "claude:synthetic"})["error"]["code"] == "unauthenticated"
    finally:
        app.close()
        stranger.close()
    assert [name for name, _ in daemon.calls] == [
        "answer_ask", "set_setting", "serve_token", "install_hooks",
    ]


def test_only_the_app_connection_can_seal_or_keep_a_protected_change(daemon: _Daemon) -> None:
    stranger = daemon.peer()
    app = daemon.peer()
    try:
        stranger.until("hello")
        for name in ("adopt_seal", "keep_protected_change"):
            reply = stranger.call(name)
            assert reply["ok"] is False and reply["error"]["code"] == "unauthenticated", name
        assert app.authenticate(SECRET)["ok"] is True
        assert app.call("adopt_seal")["result"] == {"ran": "adopt_seal"}
        assert app.call("keep_protected_change")["result"] == {"ran": "keep_protected_change"}
    finally:
        stranger.close()
        app.close()
    assert [name for name, _ in daemon.calls] == ["adopt_seal", "keep_protected_change"]


def test_each_connection_is_offered_its_own_nonce_and_a_proof_is_not_portable(daemon: _Daemon) -> None:
    first = daemon.peer()
    second = daemon.peer()
    try:
        nonce_one = first.until("hello")["auth"]["nonce"]
        nonce_two = second.until("hello")["auth"]["nonce"]
        assert nonce_one != nonce_two
        # The first connection's proof, replayed on the second, is refused.
        reply = second.call("auth", {"proof": auth_proof(SECRET, nonce_one)})
        assert reply["error"]["code"] == "auth_failed"
        assert second.closed()
    finally:
        first.close()
        second.close()


def test_a_wrong_proof_is_refused_delayed_and_closes_the_connection(daemon: _Daemon) -> None:
    waits: list[float] = []
    daemon.authority.wait = lambda seconds: waits.append(seconds)  # type: ignore[attr-defined,method-assign]
    attacker = daemon.peer()
    try:
        attacker.until("hello")
        reply = attacker.call("auth", {"proof": "0" * 64})
        assert reply["ok"] is False and reply["error"]["code"] == "auth_failed"
        assert attacker.closed(), "one attempt, then the connection is closed"
    finally:
        attacker.close()
    assert waits and waits[0] > 0
    assert daemon.server.stats["auth_failed"] == 1
    assert any("refused an authentication attempt" in line for line in daemon.logs)
    # The secret was never in the log.
    assert not any(SECRET.hex() in line for line in daemon.logs)
    # A failed attempt does not lock the app out: it connects and proves itself.
    app = daemon.peer()
    try:
        assert app.authenticate(SECRET)["ok"] is True
    finally:
        app.close()


def test_a_missing_or_malformed_proof_fails_the_same_way(daemon: _Daemon) -> None:
    for args in ({}, {"proof": 5}, {"proof": ["a"]}, {"proof": "short"}):
        peer = daemon.peer()
        try:
            peer.until("hello")
            assert peer.call("auth", args)["error"]["code"] == "auth_failed"
            assert peer.closed()
        finally:
            peer.close()


def test_a_second_auth_on_an_authenticated_connection_is_a_no_op(daemon: _Daemon) -> None:
    app = daemon.peer()
    try:
        assert app.authenticate(SECRET)["ok"] is True
        again = app.call("auth", {"proof": "garbage"})
        assert again["ok"] is True and again["result"] == {"authenticated": True}
        assert app.call("answer_ask", {"session": "claude:synthetic"})["ok"] is True
    finally:
        app.close()


def test_a_spent_nonce_is_replayed_not_accepted(daemon: _Daemon) -> None:
    from jrbar.core_server import _Client

    left, right = socket.socketpair()
    try:
        client = _Client(left, 1)
        client.offer_nonce("a" * 32)
        assert client.take_nonce() == "a" * 32
        assert client.take_nonce() is None
        daemon.server._handle_auth(client, "r-1", {"proof": auth_proof(SECRET, "a" * 32)})
        right.settimeout(2.0)
        reply = json.loads(right.recv(65536).split(b"\n")[0])
    finally:
        left.close()
        right.close()
    assert reply["error"]["code"] == "auth_replayed"
    assert client.authenticated is False


def test_a_daemon_with_no_secret_refuses_privileged_commands_and_says_how_to_develop(sock_dir: Path) -> None:
    daemon = _Daemon(sock_dir, CoreAuthority.closed())
    peer = daemon.peer()
    try:
        hello = peer.until("hello")
        assert "auth" not in hello
        assert peer.call("ping")["ok"] is True
        refused = peer.call("answer_ask", {"session": "claude:synthetic"})
        assert refused["error"]["code"] == "unauthenticated"
        assert "JRBAR_DEV_ALLOW_UNAUTH=1" in refused["error"]["message"]
        assert peer.call("auth", {"proof": "0" * 64})["error"]["code"] == "auth_unavailable"
    finally:
        peer.close()
        daemon.server.stop()
    assert daemon.calls == [("ping", {})]


def test_the_development_bypass_lets_a_source_daemon_take_privileged_commands(sock_dir: Path) -> None:
    daemon = _Daemon(sock_dir, CoreAuthority(None, dev_allow_unauth=True))
    peer = daemon.peer()
    try:
        peer.until("hello")
        assert peer.call("answer_ask", {"session": "claude:synthetic"})["ok"] is True
    finally:
        peer.close()
        daemon.server.stop()


def test_the_socket_is_owner_only(daemon: _Daemon) -> None:
    path = daemon.server.socket_path
    assert path.stat().st_mode & 0o777 == 0o600
    assert path.parent.stat().st_mode & 0o777 == 0o700


def test_the_peer_pid_is_recorded_for_log_lines(daemon: _Daemon) -> None:
    peer = daemon.peer()
    try:
        peer.until("hello")
        peer.call("answer_ask", {})
    finally:
        peer.close()
    assert any(f"pid {os.getpid()}" in line for line in daemon.logs if "refused privileged" in line)


def test_slow_lane_commands_obey_the_same_gate(sock_dir: Path) -> None:
    authority = CoreAuthority(SECRET, wait=lambda _s: None)
    ran: list[str] = []
    router = CommandRouter()
    router.register("doctor", lambda args: ran.append("doctor") or {"ok": 1})
    router.register("provider_sign_in", lambda args: ran.append("provider_sign_in") or {})
    server = CoreServer(
        dispatch=router,
        initial_documents=lambda: [],
        socket_path=sock_dir / "core.sock",
        authority=authority,
    )
    server.start()
    peer = _Peer(server.socket_path)
    done = threading.Event()
    try:
        peer.until("hello")
        assert peer.call("provider_sign_in", {"provider": "claude"})["error"]["code"] == "unauthenticated"
        assert peer.call("doctor")["ok"] is True
        done.set()
    finally:
        peer.close()
        server.stop()
    assert done.is_set()
    assert ran == ["doctor"]


# --- the paths that must keep working, and the ones that must not ---------------


def test_the_daemons_own_serve_answer_path_dispatches_in_process_not_over_the_socket(daemon: _Daemon) -> None:
    from types import SimpleNamespace

    from jrbar.serve_answers import ControllerAnswers

    dispatched: list[tuple[str, dict[str, Any]]] = []

    def dispatch(name: str, args: dict[str, Any]) -> dict[str, Any]:
        dispatched.append((name, args))
        return {"answered": True, "session": args.get("session"), "decision": args.get("decision")}

    controller = SimpleNamespace(
        settings=SimpleNamespace(serve_answer_enabled=True),
        _core_dispatch=dispatch,
        _core_documents={"state": {"asks": [], "sessions": []}},
        _core_lock=threading.Lock(),
    )

    result = ControllerAnswers(controller).answer({"session": "claude:synthetic", "decision": "approve"})

    assert result["answered"] is True
    assert dispatched == [
        ("answer_ask", {"session": "claude:synthetic", "decision": "approve", "only_if_frontmost": True})
    ]
    # The same command over the socket, from a process that is not the app, is refused.
    stranger = daemon.peer()
    try:
        stranger.until("hello")
        assert stranger.call("answer_ask", {"session": "claude:synthetic"})["error"]["code"] == "unauthenticated"
    finally:
        stranger.close()


def test_a_standalone_serve_reads_status_over_the_socket_but_its_answers_are_refused(daemon: _Daemon) -> None:
    from jrbar.serve_answers import CoreSocketAnswers, ServeAnswerRefused

    answers = CoreSocketAnswers(daemon.server.socket_path)

    assert answers.enabled() is False
    assert answers.asks() == []
    with pytest.raises(ServeAnswerRefused) as refused:
        answers.answer({"session": "claude:synthetic", "decision": "approve"})
    assert refused.value.code == "unauthenticated"
    assert refused.value.http_status == 403
    assert "answer_ask" not in [name for name, _ in daemon.calls]


def test_the_cli_prints_a_plain_sentence_when_the_app_has_to_make_the_change(
    daemon: _Daemon, capsys: pytest.CaptureFixture[str]
) -> None:
    from jrbar import cli_control

    status = cli_control.main(
        ["set", "serve_answer_enabled", "true"], socket_path=daemon.server.socket_path
    )

    captured = capsys.readouterr()
    assert status == 1
    assert "open JR-Bar and use Settings" in captured.err
    assert "set_setting:" not in captured.err
    assert daemon.calls == []
    # A display preference from the same terminal is still taken.
    assert cli_control.main(["set", "global_brightness_scale", "0.5"], socket_path=daemon.server.socket_path) == 0
    assert [name for name, _ in daemon.calls] == ["set_setting"]
