"""Repository-wide test sandbox and import setup.

The sandbox is established at collection time, before test modules import
SidePulse and cache default paths. Tests must never write the developer's real
settings, state, provider configuration, LaunchAgent domain, or mounted LEDs.
"""

from __future__ import annotations

import functools
import ipaddress
import os
import socket
import subprocess
import sys
import tempfile
from pathlib import Path

import pytest

_ROOT_PATH = Path(__file__).resolve().parent.parent
_ROOT = str(_ROOT_PATH)
if _ROOT not in sys.path:
    sys.path.insert(0, _ROOT)

# Module-level on purpose: fixtures run after test modules are imported, which
# is too late for modules that cache HOME/XDG-derived defaults.
_TEST_SANDBOX = Path(tempfile.mkdtemp(prefix="jrbar-pytest-"))
_TEST_HOME = _TEST_SANDBOX / "home"
_TEST_CONFIG = _TEST_SANDBOX / "config"
_TEST_STATE = _TEST_SANDBOX / "state"
_TEST_CACHE = _TEST_SANDBOX / "cache"
_TEST_VOLUMES = _TEST_SANDBOX / "Volumes"
for _path in (_TEST_HOME, _TEST_CONFIG, _TEST_STATE, _TEST_CACHE, _TEST_VOLUMES):
    _path.mkdir(parents=True, exist_ok=True, mode=0o700)

os.environ["HOME"] = str(_TEST_HOME)
os.environ["XDG_CONFIG_HOME"] = str(_TEST_CONFIG)
os.environ["XDG_STATE_HOME"] = str(_TEST_STATE)
os.environ["XDG_CACHE_HOME"] = str(_TEST_CACHE)
os.environ["JRBAR_TESTING"] = "1"
os.environ["JRBAR_TEST_VOLUME_ROOT"] = str(_TEST_VOLUMES)

# The suite must NEVER take the desktop away from a person using this
# machine. AppKit tests once exercised product code that called
# makeKeyAndOrderFront_ / activateIgnoringOtherApps_ -- for a four-minute
# run that meant focus being yanked from the owner's hands over and over
# ("makes this computer unusable", reported live 2026-08-26). The package
# has no such call now (tests/test_no_desktop_takeover.py keeps it so);
# this is the belt to that pair of braces:
#   1. PROHIBITED activation policy: macOS itself refuses to ever make
#      this process the active app, whatever the code under test asks.
#   2. Set at conftest import time -- before any test module can touch
#      AppKit -- exactly like the sandbox above, because a fixture
#      would be too late.
try:  # pragma: no cover - environment-dependent, no AppKit on CI
    from AppKit import NSApplication, NSApplicationActivationPolicyProhibited

    NSApplication.sharedApplication().setActivationPolicy_(
        NSApplicationActivationPolicyProhibited
    )
except Exception:
    pass

_LIVE_VOLUME_ROOT = Path("/Volumes")

# Every guard below patches through its own `pytest.MonkeyPatch`, never the
# test's shared `monkeypatch` fixture. A merged test that calls
# `monkeypatch.undo()` between scenarios reverts everything that fixture
# holds, fixture patches included; a guard on the shared fixture would go with
# it, and later scenarios would run with launchctl, /Volumes and the LED
# writer unguarded. A private patch is undone only when its own fixture ends.


def _mark_guard(original, label):
    """Tag a guard with what it wraps, so tests can see it armed exactly once."""

    def mark(guard):
        functools.update_wrapper(guard, original)
        guard.__jrbar_guard__ = label
        return guard

    return mark


@pytest.fixture(autouse=True)
def isolate_live_settings_file(tmp_path):
    """Keep all settings facades on one per-test path."""
    isolated = tmp_path / "pytest-sidepulse-settings.json"

    def _isolated_path(home=None):
        return isolated

    with pytest.MonkeyPatch.context() as mp:
        mp.setattr("jrbar._settings_legacy.default_settings_path", _isolated_path)
        mp.setattr("jrbar.settings.default_settings_path", _isolated_path)
        yield


@pytest.fixture(autouse=True)
def isolate_integration_settings_file(tmp_path_factory):
    """One per-test integrations.json (and its deck sidecar files).

    `default_integration_settings_path()` is read at call time from
    XDG_CONFIG_HOME, which the sandbox above shares across the whole run:
    a test that saves creator_micro settings without a path (the
    `deck_live` fixture) otherwise leaks its pad serial into every later
    `load_integration_settings()` (test_integration_settings'
    default-off tests failed only in the full run, 2026-09-10).
    """
    # A sibling of tmp_path, not inside it: tests assert on tmp_path's contents.
    isolated = tmp_path_factory.mktemp("jrbar-config") / "integrations.json"

    def _isolated_path():
        return isolated

    with pytest.MonkeyPatch.context() as mp:
        # The facade forwards attribute writes to the legacy module; modules
        # that bound the name at import time are patched where already loaded.
        mp.setattr("jrbar.integration_settings.default_integration_settings_path", _isolated_path)
        mp.setattr("jrbar._integration_settings_legacy.default_integration_settings_path", _isolated_path)
        for module_name in ("jrbar.deck_board_store", "jrbar.deck_control_settings", "jrbar.integration_cli"):
            module = sys.modules.get(module_name)
            if module is not None and hasattr(module, "default_integration_settings_path"):
                mp.setattr(module, "default_integration_settings_path", _isolated_path)
        yield


def _is_live_volume_path(path: object) -> bool:
    candidate = Path(path)
    try:
        candidate = candidate.expanduser().resolve(strict=False)
        root = _LIVE_VOLUME_ROOT.resolve(strict=False)
    except OSError:
        candidate = candidate.absolute()
        root = _LIVE_VOLUME_ROOT
    return candidate == root or root in candidate.parents


@pytest.fixture(autouse=True)
def block_live_launchd_mutations():
    """Refuse real launchctl mutations even when a test forgot to stub them."""
    original_run = subprocess.run

    @_mark_guard(original_run, "launchctl")
    def guarded_run(arguments, *args, **kwargs):
        command = list(arguments) if not isinstance(arguments, (str, bytes)) else []
        if command and Path(str(command[0])).name == "launchctl":
            operation = str(command[1]) if len(command) > 1 else ""
            if operation in {
                "bootstrap",
                "bootout",
                "kickstart",
                "enable",
                "disable",
                "remove",
                "submit",
            }:
                raise AssertionError(
                    f"test attempted live launchctl mutation: {operation}"
                )
        return original_run(arguments, *args, **kwargs)

    with pytest.MonkeyPatch.context() as mp:
        mp.setattr(subprocess, "run", guarded_run)
        yield


def _reject_live_volume(path: object, operation: str) -> None:
    if _is_live_volume_path(path):
        raise AssertionError(
            f"test attempted {operation} on mounted hardware path: {path}"
        )


def _arm_led_writer_guard(mp: pytest.MonkeyPatch) -> None:
    """Refuse a device write to a mounted volume, whether or not AppKit imports."""
    from jrbar import device_writer

    original_write_led_program = device_writer.write_led_program

    @_mark_guard(original_write_led_program, "led-writer")
    def guarded_write_led_program(text, **kwargs):
        device_path = kwargs.get("device_path")
        if device_path is not None:
            file_name = kwargs.get("file_name", device_writer.DEFAULT_FILE_NAME)
            _reject_live_volume(
                device_writer.target_from_device_path(Path(device_path), file_name),
                "LED program write",
            )
        return original_write_led_program(text, **kwargs)

    mp.setattr(device_writer, "write_led_program", guarded_write_led_program)


def _arm_volume_guards(mp: pytest.MonkeyPatch) -> None:
    """Fail tests before any file or keepalive write reaches real hardware."""
    reject = _reject_live_volume

    original_write_text = Path.write_text
    original_write_bytes = Path.write_bytes
    original_touch = Path.touch
    original_replace = Path.replace

    @_mark_guard(original_write_text, "volume")
    def guarded_write_text(path, *args, **kwargs):
        reject(path, "write_text")
        return original_write_text(path, *args, **kwargs)

    @_mark_guard(original_write_bytes, "volume")
    def guarded_write_bytes(path, *args, **kwargs):
        reject(path, "write_bytes")
        return original_write_bytes(path, *args, **kwargs)

    @_mark_guard(original_touch, "volume")
    def guarded_touch(path, *args, **kwargs):
        reject(path, "touch")
        return original_touch(path, *args, **kwargs)

    @_mark_guard(original_replace, "volume")
    def guarded_replace(path, target, *args, **kwargs):
        reject(path, "replace source")
        reject(target, "replace target")
        return original_replace(path, target, *args, **kwargs)

    mp.setattr(Path, "write_text", guarded_write_text, raising=False)
    mp.setattr(Path, "write_bytes", guarded_write_bytes, raising=False)
    mp.setattr(Path, "touch", guarded_touch, raising=False)
    mp.setattr(Path, "replace", guarded_replace, raising=False)

    _arm_led_writer_guard(mp)

    from jrbar import keep_awake

    original_keepalive_touch = keep_awake.touch_keepalive_file
    original_poke_status_file = keep_awake.KeepAwakeController.poke_status_file

    def guarded_keepalive_touch(path):
        reject(path, "keepalive touch")
        return original_keepalive_touch(path)

    def guarded_poke_status_file(controller, target, *args, **kwargs):
        if target is not None:
            reject(keep_awake.keepalive_file_for_target(target), "keepalive poke")
        return original_poke_status_file(controller, target, *args, **kwargs)

    original_subprocess_run = keep_awake.subprocess.run

    @_mark_guard(original_subprocess_run, "volume-touch")
    def guarded_subprocess_run(arguments, *args, **kwargs):
        command = list(arguments) if not isinstance(arguments, (str, bytes)) else []
        if command and command[0] == "/usr/bin/touch":
            for target in command[1:]:
                reject(target, "subprocess touch")
        return original_subprocess_run(arguments, *args, **kwargs)

    mp.setattr(keep_awake, "touch_keepalive_file", guarded_keepalive_touch)
    mp.setattr(
        keep_awake.KeepAwakeController,
        "poke_status_file",
        guarded_poke_status_file,
    )
    mp.setattr(keep_awake.subprocess, "run", guarded_subprocess_run)

    try:
        from jrbar import status_bar
    except (ImportError, SystemExit):
        # No AppKit (make test-portable): the controller guard below has
        # nothing to wrap. The guards above are already armed.
        return

    original_keepalive_targets = status_bar.StatusBarController.status_keepalive_targets

    def guarded_keepalive_targets(controller):
        targets = original_keepalive_targets(controller)
        for target in targets:
            reject(target, "keepalive target selection")
        return targets

    mp.setattr(
        status_bar.StatusBarController,
        "status_keepalive_targets",
        guarded_keepalive_targets,
    )


@pytest.fixture(autouse=True)
def block_live_volume_writes():
    """Arm the volume guards on a private patch that outlives `monkeypatch.undo()`."""
    with pytest.MonkeyPatch.context() as mp:
        _arm_volume_guards(mp)
        yield


def _remote_host(family: int, address: object) -> str | None:
    """The host a connect would reach, or None when it stays on this machine.

    Only internet-family sockets can leave the Mac. Loopback and the
    unspecified address are this machine; any other name would need DNS.
    """
    if family not in (socket.AF_INET, socket.AF_INET6):
        return None
    if not isinstance(address, tuple) or not address:
        return None  # malformed: let the real connect raise its own error
    host = address[0]
    if isinstance(host, bytes):
        host = host.decode("ascii", "replace")
    if not isinstance(host, str):
        return None
    name = host.split("%", 1)[0]
    if name in ("", "localhost") or name.endswith(".localhost"):
        return None
    try:
        ip = ipaddress.ip_address(name)
    except ValueError:
        return host
    mapped = getattr(ip, "ipv4_mapped", None)
    if mapped is not None:
        ip = mapped
    return None if ip.is_loopback or ip.is_unspecified else host


@pytest.fixture(autouse=True)
def block_live_network_connects():
    """Refuse a connect to anything but loopback and unix sockets.

    A test that wants a remote answer injects a fake. The caller may swallow
    the AssertionError (a poller's fetch does), so the run stays quiet but
    nothing leaves the Mac.
    """
    original_connect = socket.socket.connect
    original_connect_ex = socket.socket.connect_ex

    def refuse_remote(sock, address):
        host = _remote_host(sock.family, address)
        if host is not None:
            raise AssertionError(f"test tried to reach the network: {host}")

    @_mark_guard(original_connect, "network")
    def guarded_connect(sock, address):
        refuse_remote(sock, address)
        return original_connect(sock, address)

    @_mark_guard(original_connect_ex, "network")
    def guarded_connect_ex(sock, address):
        refuse_remote(sock, address)
        return original_connect_ex(sock, address)

    with pytest.MonkeyPatch.context() as mp:
        mp.setattr(socket.socket, "connect", guarded_connect)
        mp.setattr(socket.socket, "connect_ex", guarded_connect_ex)
        yield


def _make_inert_status_feed_poller():
    from jrbar.status_feeds import StatusFeedPoller

    def refuse_fetch(*_args, **_kwargs):
        raise AssertionError("test fetched a provider status page")

    class InertStatusFeedPoller(StatusFeedPoller):
        """Records which providers were asked for; starts nothing, fetches nothing."""

        def __init__(self):
            super().__init__(fetch_json=refuse_fetch)
            self.started: list[tuple[str, ...]] = []

        def start(self, *, provider_ids=None):
            selected = tuple(self._feeds) if provider_ids is None else tuple(provider_ids)
            self.started.append(selected)

        def poll_once(self, *, provider_ids=None):
            return None

    return InertStatusFeedPoller()


@pytest.fixture(autouse=True)
def inert_status_feed_poller():
    """The provider status-page poller starts no thread and asks no vendor.

    The refresh loop starts `shared_status_feed_poller()` for every provider
    it refreshes, so any test that builds a `ProviderUsageService` without an
    `incident_lookup` would otherwise run daemon threads that GET the
    vendors' status pages. `StatusFeedPoller.__init__` binds its fetch
    function as a default at definition time, so patching the fetch does
    nothing; the shared accessor is looked up at call time and is the seam.
    A test that wants an incident patches it again with its own fake.
    """
    poller = _make_inert_status_feed_poller()
    with pytest.MonkeyPatch.context() as mp:
        mp.setattr("jrbar.status_feeds.shared_status_feed_poller", lambda: poller)
        yield poller
