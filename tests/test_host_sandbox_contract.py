from __future__ import annotations

import os
import subprocess
from pathlib import Path

import pytest

import jrbar._settings_legacy
import jrbar.integration_settings
import jrbar.settings
from jrbar import device_writer


def test_collection_time_environment_is_not_the_real_home__and_1_more() -> None:
    # --- scenario: collection_time_environment_is_not_the_real_home
    home = Path(os.environ["HOME"])
    assert home.name == "home"
    assert home.parent.name.startswith("jrbar-pytest-")
    assert os.environ["JRBAR_TESTING"] == "1"
    assert Path(os.environ["XDG_CONFIG_HOME"]).is_relative_to(home.parent)
    assert Path(os.environ["XDG_STATE_HOME"]).is_relative_to(home.parent)
    assert Path(os.environ["XDG_CACHE_HOME"]).is_relative_to(home.parent)

    # --- scenario: test_volume_root_is_not_real_volumes
    root = Path(os.environ["JRBAR_TEST_VOLUME_ROOT"])
    assert root != Path("/Volumes")
    assert root.name == "Volumes"
    assert root.is_dir()



# What the guards wrap, captured at collection time: nothing is armed yet, so
# these are the genuine functions.
_COLLECTED_RUN = subprocess.run
_COLLECTED_PATH_METHODS = {
    name: getattr(Path, name) for name in ("write_text", "write_bytes", "touch", "replace")
}
_COLLECTED_SETTINGS_PATH = jrbar.settings.default_settings_path

_LAUNCHCTL_MUTATIONS = ("bootstrap", "bootout", "kickstart", "enable", "disable", "remove", "submit")

# Guard canaries name paths that do not exist, so a guard that stopped working
# fails with FileNotFoundError and touches nothing. Never the real device
# volumes (AGENTS.md).
_CANARY_LAUNCHCTL = "/nonexistent-jrbar-canary/launchctl"
_CANARY_VOLUME = Path("/Volumes/jrbar-guard-canary")


def _guard_chain(function: object) -> tuple[list[str], object]:
    """The conftest guards stacked on `function`, outermost first, and what they wrap."""
    labels: list[str] = []
    while hasattr(function, "__jrbar_guard__"):
        labels.append(function.__jrbar_guard__)
        function = function.__wrapped__
    return labels, function


def test_conftest_guards_survive_monkeypatch_undo(monkeypatch, tmp_path) -> None:
    # A merged test resets between scenarios with monkeypatch.undo(). That must
    # revert the test's own patches and leave the sandbox guards standing.
    monkeypatch.undo()

    for operation in _LAUNCHCTL_MUTATIONS:
        with pytest.raises(AssertionError, match="live launchctl mutation"):
            subprocess.run([_CANARY_LAUNCHCTL, operation, "gui/0/jrbar.pytest-canary"])
    with pytest.raises(FileNotFoundError):
        subprocess.run([_CANARY_LAUNCHCTL, "print", "gui/0/jrbar.pytest-canary"])

    led_file = _CANARY_VOLUME / "LEDS.LED"
    with pytest.raises(AssertionError, match="mounted hardware path"):
        led_file.write_text("x")
    with pytest.raises(AssertionError, match="mounted hardware path"):
        led_file.write_bytes(b"x")
    with pytest.raises(AssertionError, match="mounted hardware path"):
        led_file.touch()
    with pytest.raises(AssertionError, match="mounted hardware path"):
        led_file.replace(tmp_path / "x")

    with pytest.raises(AssertionError, match="LED program write"):
        device_writer.write_led_program("off", device_path=_CANARY_VOLUME, dry_run=True)

    isolated_settings = tmp_path / "pytest-sidepulse-settings.json"
    assert jrbar.settings.default_settings_path() == isolated_settings
    assert jrbar._settings_legacy.default_settings_path() == isolated_settings
    integrations = jrbar.integration_settings.default_integration_settings_path()
    assert integrations.parent.name.startswith("jrbar-config")
    assert integrations.parent != tmp_path


def test_conftest_guards_are_armed_once_per_test() -> None:
    # Each guard sits on the genuine function exactly once. A guard that leaked
    # out of an earlier test would show up here as a repeated label or as a
    # tail that is not the function collected at import time.
    labels, tail = _guard_chain(subprocess.run)
    assert labels, "subprocess.run is not guarded"
    assert len(labels) == len(set(labels))
    assert tail is _COLLECTED_RUN

    for name, collected in _COLLECTED_PATH_METHODS.items():
        labels, tail = _guard_chain(getattr(Path, name))
        assert labels == ["volume"], name
        assert tail is collected, name

    assert jrbar.settings.default_settings_path is not _COLLECTED_SETTINGS_PATH
