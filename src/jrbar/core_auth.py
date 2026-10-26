"""Who may send the core socket a privileged command (docs/CORE-PROTOCOL.md,
"Who may send what").

``core.sock`` admits a peer by its uid, and every process running as you has
it: your shell, an agent's shell tool, whatever an agent installs. Releasing a
held permission request, switching on an answering route or installing a hook
cannot be open to all of them. So the socket trusts the JR-Bar app, not the
user:

* When the app starts the daemon it hands it 32 random bytes over the child's
  stdin pipe (never the environment, never an argument). The daemon keeps
  them in memory and points its stdin at ``/dev/null``.
* A connection proves it holds them with an HMAC over a nonce the daemon sent
  in ``hello``; the secret itself never crosses the socket.
* Every command is either open (any connection) or privileged (only an
  authenticated one). The table below is explicit and fails closed: a command
  that is not in it is privileged.

The daemon's own in-process answer path (``jrbar serve``) calls the
controller's dispatch directly and never passes through here.
"""

from __future__ import annotations

import hashlib
import hmac
import os
import re
import secrets
import select
import stat
import sys
import threading
import time
from collections.abc import Callable, Mapping
from dataclasses import dataclass
from typing import Any, Final, Literal

AUTH_COMMAND: Final = "auth"
AUTH_SCHEME: Final = "hmac-sha256"
AUTH_CONTEXT: Final = b"jrbar-core-auth-v1\n"
SECRET_BYTES: Final = 32
NONCE_HEX_CHARS: Final = 32
#: Set by the supervising app in the daemon's environment to say "your stdin is
#: the secret's pipe". It names a channel, not the secret.
HANDOFF_ENV: Final = "JRBAR_AUTH_STDIN"
#: Development only: a daemon with no app secret takes privileged commands from
#: any connection. Honoured by a source checkout, never by the frozen release.
DEV_ALLOW_ENV: Final = "JRBAR_DEV_ALLOW_UNAUTH"
HANDOFF_WAIT_SECONDS: Final = 2.0
#: What ``JRBAR_AUTH_STDIN`` says the pipe holds: the secret alone, the secret
#: and a seal key an earlier run sealed settings under, or the secret and a seal
#: key that has sealed nothing yet (docs/CORE-PROTOCOL.md, "Protected settings").
HANDOFF_SECRET_ONLY: Final = "1"
HANDOFF_WITH_SEAL_KEY: Final = "2"
HANDOFF_WITH_NEW_SEAL_KEY: Final = "3"
SEAL_KEY_BYTES: Final = 32

Privilege = Literal["open", "privileged"]
OPEN: Final = "open"
PRIVILEGED: Final = "privileged"

#: Any connection may send these: reads and the low-risk verbs `jrbar quiet`,
#: `snooze`, `confetti`, `awake` and a display `jrbar set` use.
_OPEN_COMMANDS: Final = (
    "ping",
    "list_commands",
    "replay_events",
    "doctor",
    "hooks_doctor",
    "list_history",
    "list_roster",
    "list_providers",
    "list_effects",
    "list_assignments",
    "list_lid_presets",
    "list_finish_looks",
    "list_scene_packs",
    "list_cues",
    "what_plays",
    "list_focuses",
    "list_light_log",
    "usage_history",
    "usage_graph",
    "usage_hooks_status",
    "session_energy",
    "session_timeline",
    "compare_sessions",
    "session_usage",
    "firmware_status",
    "quiet",
    "quiet_lease",
    "snooze",
    "confetti",
    "hold_awake",
    "release_awake",
    "refresh_usage",
    "set_brightness",
    # Open only for a display preference; see ``requires_app``.
    "set_setting",
    "scene_lease",
    "reset_settings",
)

#: Only the app's authenticated connection may send these.
_PRIVILEGED_COMMANDS: Final = (
    # Writes `FIRMWARE.BIN` to a device and pauses its lights: a person at the
    # app, never an agent or a stray process.
    "firmware_update",
    # Sends one request to the person's ntfy topic: only a click in the app.
    "ntfy_test",
    # Consent to a provider request leaving the Mac: only a person in the app.
    "set_provider_usage_consent",
    "set_provider_options",
    # Hides a pending ask from the person: only the person, in the app.
    "dismiss_ask",
    # Answers, approvals, typing into an agent, raising or starting sessions.
    "answer_ask",
    "deck_answer",
    "deck_press",
    "open_session",
    "new_session",
    "resume_session",
    "session_in_front",
    "clear_completed",
    "undo_clear",
    "dismiss_session",
    "mark_history_seen",
    # Secrets, tokens, hooks, accounts and provider consent.
    "serve_token",
    "install_hooks",
    "uninstall_hooks",
    "refresh_hooks",
    "claude_statusline_install",
    "claude_statusline_uninstall",
    "usage_hooks_test",
    "set_provider_enabled",
    "factory_session_profiles",
    "factory_session_import",
    "factory_session_disconnect",
    "set_provider_credential",
    "delete_provider_credential",
    "provider_consent",
    "provider_add_instance",
    "provider_action",
    "provider_sign_in",
    "provider_update",
    "provider_update_check",
    "t3code_integration",
    # Seals the settings that grant a capability, or applies a foreign edit of
    # them: only a person in the app.
    "adopt_seal",
    "keep_protected_change",
    # Power, presence and lifetime.
    "set_closed_lid_policy",
    "presence",
    "reset_receipt",
    "reset_status",
    "audit_export",
    "quit",
    # LED, calibration, effect, scene-pack and cue writers.
    "set_device_display",
    "apply_calibration",
    "preview_program",
    "preview_calibration",
    "end_calibration_preview",
    "apply_effect",
    "render_effect",
    "resolve_effect",
    "set_assignment",
    "clear_assignment",
    "play_lid_preset",
    "preview_provider_motion",
    "import_effect_pack",
    "remove_effect_pack",
    "export_effect_pack",
    "import_scene_pack",
    "preview_scene_pack",
    "preview_fleet",
    "set_cue",
    "burn_init",
    "calibration_profile",
    "auto_dim_learning",
    "check_palette",
    "linked_sync_check",
    "eject_guard",
    "protect_sidepulse",
    "release_sidepulse",
    # The Stream Deck / Creator Micro deck.
    "deck_pin",
    "deck_bank",
    "deck_scope",
    "deck_rail",
    "deck_clear_absent",
    "deck_plan_keymap",
    "deck_apply_keymap",
    "deck_restore_keymap",
    "deck_approve_device",
    "deck_disable",
    "deck_check_input",
    "deck_set_settings",
)

COMMAND_PRIVILEGE: Final[Mapping[str, Privilege]] = {
    **{name: OPEN for name in _OPEN_COMMANDS},
    **{name: PRIVILEGED for name in _PRIVILEGED_COMMANDS},
}

#: The top-level settings an unauthenticated ``set_setting`` /
#: ``reset_settings`` may change: how things look. Anything not named here,
#: including a setting added later, is privileged.
OPEN_SETTING_ROOTS: Final = frozenset(
    {
        "global_brightness_scale",
        "active_scene",
        "colors",
        "led_display",
        "idle_dim_enabled",
        "idle_dim_after_minutes",
        "idle_dim_fraction",
        "sleep_dim_enabled",
        "sleep_dim_fraction",
        "auto_dim",
        "screen_bar_gap_width",
        "screen_bar_wing_length",
        "screen_bar_notch_profile",
        "screen_bar_notch_corner",
        "screen_bar_notch_wings",
        "screen_bar_bracket_style",
        "screen_bar_min_glow",
        "screen_bar_phase_offset_ms",
        "screen_bar_gauges_enabled",
        "screen_bar_show_in_full_screen",
        "menu_bar_icon_style",
        "tips_enabled",
        "usage_graph_days",
        "usage_display_mode",
    }
)
#: ``devices.<n>.<field>`` is a display preference for these fields; ``id``,
#: ``name`` and ``path`` identify a device and are not.
OPEN_DEVICE_FIELDS: Final = frozenset(
    {
        "enabled",
        "led_display",
        "brightness",
        "auto_brightness_enabled",
        "red_gain",
        "green_gain",
        "blue_gain",
        "resting_glow",
        "blend_mode",
        "provider_pin",
        "signal_policy",
        "led_direction",
        "dot_travel_style",
    }
)

_LOGGABLE_NAME = re.compile(r"[a-z][a-z0-9_]{0,47}")

MESSAGE_WITH_SECRET: Final = (
    "That change has to be made in JR-Bar itself: open JR-Bar and use Settings."
)
MESSAGE_NO_SECRET: Final = (
    "This daemon was started without the JR-Bar app, so it takes no privileged "
    "commands: open JR-Bar and use Settings. (For development only, start the "
    f"daemon with {DEV_ALLOW_ENV}=1.)"
)


def privilege_of(name: object) -> Privilege:
    """The privilege a command name needs; a name not in the table is privileged."""
    if isinstance(name, str) and COMMAND_PRIVILEGE.get(name) == OPEN:
        return OPEN
    return PRIVILEGED


def setting_path_is_open(path: object) -> bool:
    """Whether ``path`` is a display preference an unauthenticated connection
    may write. Anything unclear is not."""
    if not isinstance(path, str) or not path:
        return False
    parts = [piece for piece in path.split(".") if piece]
    if not parts:
        return False
    root = parts[0]
    if root == "devices":
        return (
            len(parts) == 3
            and parts[1].isascii()
            and parts[1].isdigit()
            and parts[2] in OPEN_DEVICE_FIELDS
        )
    return root in OPEN_SETTING_ROOTS


def requires_app(name: object, args: Mapping[str, Any] | None) -> bool:
    """Whether this command, with these arguments, is for the app alone."""
    if privilege_of(name) == PRIVILEGED:
        return True
    arguments = args if isinstance(args, Mapping) else {}
    if name == "set_setting":
        return not setting_path_is_open(arguments.get("path"))
    if name == "reset_settings":
        paths = arguments.get("paths")
        if not isinstance(paths, list) or not paths:
            return True
        return not all(setting_path_is_open(path) for path in paths)
    return False


def auth_proof(secret: bytes, nonce: str) -> str:
    """The proof for ``nonce``: what the app (and a test client) sends."""
    return hmac.new(secret, AUTH_CONTEXT + nonce.encode("ascii"), hashlib.sha256).hexdigest()


def new_secret() -> bytes:
    return secrets.token_bytes(SECRET_BYTES)


def loggable_name(name: object) -> str:
    """A command name safe to put in a log line (the sender chose it)."""
    return name if isinstance(name, str) and _LOGGABLE_NAME.fullmatch(name) else "(unnamed)"


class CoreAuthority:
    """The daemon's side of the handshake and the privilege decision."""

    FAILURE_WINDOW_SECONDS: Final = 60.0
    MAX_FAILURE_DELAY_SECONDS: Final = 2.0
    FIRST_FAILURE_DELAY_SECONDS: Final = 0.1

    def __init__(
        self,
        secret: bytes | None = None,
        *,
        dev_allow_unauth: bool = False,
        nonce_source: Callable[[], str] | None = None,
        clock: Callable[[], float] = time.monotonic,
        wait: Callable[[float], None] | None = None,
        seal_key: bytes | None = None,
        seal_key_is_new: bool = False,
    ) -> None:
        if secret is not None and (not isinstance(secret, bytes) or len(secret) != SECRET_BYTES):
            raise ValueError("the app secret is 32 bytes")
        if seal_key is not None and (not isinstance(seal_key, bytes) or len(seal_key) != SEAL_KEY_BYTES):
            raise ValueError("the seal key is 32 bytes")
        self._secret = secret
        #: The key the app sealed the protected settings with, if it gave one.
        self.seal_key = seal_key
        #: True when nothing has been sealed under ``seal_key`` yet.
        self.seal_key_is_new = bool(seal_key_is_new)
        self.dev_allow_unauth = bool(dev_allow_unauth)
        self._nonce_source = nonce_source or (lambda: secrets.token_hex(NONCE_HEX_CHARS // 2))
        self._clock = clock
        self._wait = wait or _wait_seconds
        self._lock = threading.Lock()
        self._failures: list[float] = []

    @classmethod
    def closed(cls) -> CoreAuthority:
        """No secret, no development bypass: every privileged command refused."""
        return cls()

    @property
    def has_secret(self) -> bool:
        return self._secret is not None

    def new_challenge(self) -> dict[str, str] | None:
        """The ``hello.auth`` member for one connection; ``None`` with no secret."""
        if self._secret is None:
            return None
        return {"scheme": AUTH_SCHEME, "nonce": self._nonce_source()}

    def check_proof(self, nonce: str, proof: object) -> bool:
        if self._secret is None or not isinstance(proof, str) or not isinstance(nonce, str):
            return False
        expected = auth_proof(self._secret, nonce)
        return hmac.compare_digest(expected.encode("ascii"), proof.encode("utf-8", "replace"))

    def requires_app(self, name: object, args: Mapping[str, Any] | None) -> bool:
        """Whether an unauthenticated connection must be refused this command."""
        if self.dev_allow_unauth:
            return False
        return requires_app(name, args)

    def refusal_message(self) -> str:
        return MESSAGE_WITH_SECRET if self.has_secret else MESSAGE_NO_SECRET

    def record_failure(self) -> float:
        """Count a failed proof; the seconds to wait before answering it.

        The delay doubles with each failure in the last minute and is capped,
        so guessing is slow and a burst of bad proofs never locks the app out.
        """
        now = self._clock()
        with self._lock:
            self._failures = [at for at in self._failures if now - at < self.FAILURE_WINDOW_SECONDS]
            self._failures.append(now)
            count = len(self._failures)
        return min(self.MAX_FAILURE_DELAY_SECONDS, self.FIRST_FAILURE_DELAY_SECONDS * (2 ** (count - 1)))

    def wait(self, seconds: float) -> None:
        if seconds > 0:
            self._wait(seconds)


def _wait_seconds(seconds: float) -> None:
    threading.Event().wait(seconds)


def _read_exact(fd: int, count: int, wait_seconds: float) -> bytes | None:
    deadline = time.monotonic() + wait_seconds
    chunks: list[bytes] = []
    remaining = count
    while remaining > 0:
        left = deadline - time.monotonic()
        if left <= 0:
            return None
        try:
            ready, _w, _x = select.select([fd], [], [], left)
        except (OSError, ValueError):
            return None
        if not ready:
            return None
        try:
            chunk = os.read(fd, remaining)
        except OSError:
            return None
        if not chunk:
            return None
        chunks.append(chunk)
        remaining -= len(chunk)
    return b"".join(chunks)


@dataclass(frozen=True, slots=True)
class Handoff:
    """What the app put on the daemon's stdin pipe."""

    secret: bytes | None = None
    seal_key: bytes | None = None
    #: The seal key is one the app only just made (nothing sealed under it).
    seal_key_is_new: bool = False


def adopt_handoff(
    environ: Any = None,
    *,
    fd: int = 0,
    wait_seconds: float = HANDOFF_WAIT_SECONDS,
    log: Callable[[str], None] | None = None,
) -> Handoff:
    """Take the app's secret (and seal key) from the pipe on ``fd``, once.

    Only when the environment says the app handed one over (``HANDOFF_ENV``),
    and only from a pipe. Whatever happens, ``fd`` is then pointed at
    ``/dev/null`` so no child of this process inherits the pipe, and the
    variable is removed from the environment.
    """
    env = os.environ if environ is None else environ
    say = log or (lambda _line: None)
    announced = env.pop(HANDOFF_ENV, None)
    if announced not in (HANDOFF_SECRET_ONLY, HANDOFF_WITH_SEAL_KEY, HANDOFF_WITH_NEW_SEAL_KEY):
        return Handoff()
    with_key = announced != HANDOFF_SECRET_ONLY
    payload: bytes | None = None
    try:
        if not stat.S_ISFIFO(os.fstat(fd).st_mode):
            say("core: the app secret was announced but stdin is not a pipe; ignoring it")
        else:
            payload = _read_exact(fd, SECRET_BYTES + (SEAL_KEY_BYTES if with_key else 0), wait_seconds)
            if payload is None:
                say("core: the app secret did not arrive; privileged commands will be refused")
    except OSError:
        say("core: could not read the app secret; privileged commands will be refused")
    finally:
        try:
            null = os.open(os.devnull, os.O_RDONLY)
            try:
                os.dup2(null, fd)
            finally:
                os.close(null)
        except OSError:
            pass
    if payload is None:
        return Handoff()
    return Handoff(
        secret=payload[:SECRET_BYTES],
        seal_key=payload[SECRET_BYTES:] if with_key else None,
        seal_key_is_new=announced == HANDOFF_WITH_NEW_SEAL_KEY,
    )


def adopt_handoff_secret(
    environ: Any = None,
    *,
    fd: int = 0,
    wait_seconds: float = HANDOFF_WAIT_SECONDS,
    log: Callable[[str], None] | None = None,
) -> bytes | None:
    """The secret alone; see ``adopt_handoff``."""
    return adopt_handoff(environ, fd=fd, wait_seconds=wait_seconds, log=log).secret


def authority_from_process(
    environ: Any = None,
    *,
    frozen: bool | None = None,
    fd: int = 0,
    log: Callable[[str], None] | None = None,
    wait_seconds: float = HANDOFF_WAIT_SECONDS,
) -> CoreAuthority:
    """The authority this daemon process runs with, decided once at startup.

    A secret from the supervising app wins. Without one, the daemon is closed
    to privileged commands unless a source checkout asked for the development
    bypass; the frozen release ignores the bypass.
    """
    env = os.environ if environ is None else environ
    is_frozen = bool(getattr(sys, "frozen", False)) if frozen is None else frozen
    say = log or (lambda _line: None)
    handoff = adopt_handoff(env, fd=fd, wait_seconds=wait_seconds, log=say)
    secret = handoff.secret
    requested = env.pop(DEV_ALLOW_ENV, None) == "1"
    dev = requested and not is_frozen and secret is None
    if requested and is_frozen:
        say(f"core: {DEV_ALLOW_ENV} is ignored by the release daemon")
    if dev:
        say(
            f"core: {DEV_ALLOW_ENV}=1: privileged commands are accepted from any local "
            "process (development only)"
        )
    return CoreAuthority(
        secret,
        dev_allow_unauth=dev,
        seal_key=handoff.seal_key,
        seal_key_is_new=handoff.seal_key_is_new,
    )


__all__ = [
    "AUTH_COMMAND",
    "AUTH_CONTEXT",
    "AUTH_SCHEME",
    "COMMAND_PRIVILEGE",
    "DEV_ALLOW_ENV",
    "HANDOFF_ENV",
    "OPEN",
    "OPEN_DEVICE_FIELDS",
    "OPEN_SETTING_ROOTS",
    "PRIVILEGED",
    "SEAL_KEY_BYTES",
    "SECRET_BYTES",
    "CoreAuthority",
    "Handoff",
    "adopt_handoff",
    "adopt_handoff_secret",
    "auth_proof",
    "authority_from_process",
    "loggable_name",
    "new_secret",
    "privilege_of",
    "requires_app",
    "setting_path_is_open",
]
