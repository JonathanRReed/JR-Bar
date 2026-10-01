"""The mock daemon speaks the provider sign-in and update contract the app was built against.

`app/scripts/mock-core.py` stands in for the daemon in the Swift suites and the dev loop, so
its `provider_sign_in`, `provider_update` and `provider_update_check` and its
`state.provider_updates` have to match docs/CORE-PROTOCOL.md. The pretend updater's timer is
replaced by one the test fires by hand, so nothing here waits.
"""

from __future__ import annotations

import importlib.util
import sys
from pathlib import Path

import pytest

MOCK_PATH = Path(__file__).resolve().parents[1] / "app" / "scripts" / "mock-core.py"


@pytest.fixture(scope="module")
def mock_module():
    spec = importlib.util.spec_from_file_location("mock_core_provider_commands", MOCK_PATH)
    module = importlib.util.module_from_spec(spec)
    sys.modules[spec.name] = module
    spec.loader.exec_module(module)
    return module


@pytest.fixture()
def world(mock_module):
    return mock_module.World(step_seconds=0.01, loop=False)


@pytest.fixture()
def timers(mock_module, monkeypatch):
    """The mock's pretend updater timer, fired by the test instead of the clock."""
    fired: list = []

    class Timer:
        def __init__(self, interval, function, args=()):
            self.function, self.args, self.daemon = function, args, False

        def start(self):
            fired.append(self)

        def run(self):
            self.function(*self.args)

    monkeypatch.setattr(mock_module.threading, "Timer", Timer)
    return fired


def call(world, name, args=None):
    return world.handle_command({"name": name, "args": args or {}, "id": "t-1"})


def test_fix_sign_in_answers_in_the_documented_shape(world) -> None:
    reply = call(world, "provider_sign_in", {"provider": "grok"})

    assert reply["ok"] is True
    assert reply["result"] == {
        "provider": "grok",
        "instance": "default",
        "outcome": "opened_terminal",
        "message": "Opened Ghostty on `grok login`: finish signing in there, JR-Bar notices on its own.",
        "command": "grok login",
        "sign_in_url": None,
    }
    assert call(world, "provider_sign_in", {"provider": "claude"})["result"]["outcome"] == "renewed"
    devin = call(world, "provider_sign_in", {"provider": "devin"})["result"]
    assert (devin["outcome"], devin["sign_in_url"]) == ("unavailable", "https://app.devin.ai")
    assert call(world, "provider_sign_in", {"provider": "nonsense"})["error"]["code"] == "unknown_provider"
    assert call(world, "provider_sign_in", {})["error"]["code"] == "invalid_args"


def test_an_update_returns_at_once_and_lands_in_the_state(world, timers) -> None:
    assert world.state()["provider_updates"] == {}

    reply = call(world, "provider_update", {"provider": "claude"})

    assert reply["result"] == {"provider": "claude", "started": True, "reason": None, "message": "Updating claude…"}
    assert world.state()["provider_updates"]["claude"]["phase"] == "running"
    again = call(world, "provider_update", {"provider": "claude"})["result"]
    assert (again["started"], again["reason"]) == (False, "busy")

    timers[0].run()

    record = world.state()["provider_updates"]["claude"]
    assert (record["phase"], record["from_version"], record["to_version"]) == ("updated", "2.1.285", "2.1.290")
    assert record["message"] == "Updated 2.1.285 to 2.1.290"
    assert record["finished_at"] is not None


def test_gemini_has_no_updater_and_an_unknown_provider_is_refused(world, timers) -> None:
    gemini = call(world, "provider_update", {"provider": "gemini"})["result"]

    assert (gemini["started"], gemini["reason"]) == (False, "no_updater")
    assert "brew upgrade gemini-cli" in gemini["message"]
    assert timers == [] and "gemini" not in world.state()["provider_updates"]
    assert call(world, "provider_update", {"provider": "nonsense"})["error"]["code"] == "unknown_provider"
    assert call(world, "provider_update", {})["error"]["code"] == "invalid_args"


def test_the_update_check_does_nothing_until_the_setting_is_on(world) -> None:
    assert world.document["provider_update_checks_enabled"] is False
    assert call(world, "provider_update_check")["result"] == {"enabled": False, "started": False}
    assert world.state()["provider_updates"] == {}

    world.document["provider_update_checks_enabled"] = True

    assert call(world, "provider_update_check")["result"] == {"enabled": True, "started": True}
    claude = world.state()["provider_updates"]["claude"]
    assert (claude["phase"], claude["latest_version"]) == ("idle", "2.1.290")
    # Turned off again, the state stops saying an update is available.
    world.document["provider_update_checks_enabled"] = False
    assert world.state()["provider_updates"] == {}
