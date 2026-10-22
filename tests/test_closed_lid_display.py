"""A closed laptop sleeps its panel without releasing the agents' hold."""

from types import SimpleNamespace

import pytest

from jrbar import lid_sleep
from tests.test_lid_sleep_on_release import _controller


def test_closed_lid_panel_sleeps_once_per_close_while_agents_continue(tmp_path):
    hold, slept = _controller(tmp_path, lid_closed=lambda: True, causes_sleep=lambda: True)
    hold.update("agents", agents_active=True)
    hold.changed_system_disable = True
    panels = []
    hold.external_display_reader = lambda: False
    hold.display_sleeper = lambda: panels.append(True)
    hold.sync_display_sleep(lid_closed=True)
    hold.sync_display_sleep(lid_closed=True)
    assert panels == [True]
    assert hold.active() and slept == []
    hold.sync_display_sleep(lid_closed=False)
    hold.sync_display_sleep(lid_closed=True)
    assert panels == [True, True]


@pytest.mark.parametrize("closed,external,disabled", [
    (False, False, True), (None, False, True), (True, True, True),
    (True, None, True), (True, False, False),
])
def test_display_sleep_requires_a_closed_lid_no_external_display_and_a_hold(tmp_path, closed, external, disabled):
    hold, _ = _controller(tmp_path, lid_closed=lambda: closed, causes_sleep=lambda: True)
    hold.update("agents", agents_active=True)
    hold.changed_system_disable = disabled
    hold.sleep_disabled_reader = lambda: False
    hold.external_display_reader = lambda: external
    hold.display_sleeper = lambda: pytest.fail("Display sleep was not justified")
    hold.sync_display_sleep(lid_closed=closed)


def test_closed_lid_caffeinate_does_not_assert_user_activity():
    assert not any("u" in part for part in lid_sleep.CAFFEINATE_CLOSED_LID_COMMAND if part.startswith("-"))


def test_display_sleep_command_is_test_suppressed_and_bounded(monkeypatch):
    calls = []
    def runner(command, **kwargs):
        calls.append((command, kwargs))
        return SimpleNamespace(returncode=0)

    with pytest.raises(lid_sleep.SystemSleepSuppressedError):
        lid_sleep.run_pmset_displaysleepnow(runner=runner)
    assert calls == []
    monkeypatch.setattr(lid_sleep, "system_sleep_suppressed", lambda: False)
    lid_sleep.run_pmset_displaysleepnow(runner=runner)
    assert calls[0][0] == ["/usr/bin/pmset", "displaysleepnow"]
    assert calls[0][1]["timeout"] <= 5


def test_display_sleep_failure_waits_before_retrying(tmp_path):
    hold, _ = _controller(tmp_path, lid_closed=lambda: True, causes_sleep=lambda: True)
    hold.update("agents", agents_active=True)
    hold.changed_system_disable = True
    hold.external_display_reader = lambda: False
    clock = [100.0]
    hold.wall_clock = lambda: clock[0]
    attempts = []

    def fail():
        attempts.append(True)
        raise OSError("synthetic refusal")

    hold.display_sleeper = fail
    hold.sync_display_sleep(lid_closed=True)
    hold.sync_display_sleep(lid_closed=True)
    assert len(attempts) == 1
    assert hold.last_error == "Closed-lid display sleep failed"
    clock[0] += 31
    hold.display_sleeper = lambda: attempts.append(True)
    hold.sync_display_sleep(lid_closed=True)
    assert len(attempts) == 2


def test_a_hold_inherited_after_restart_still_sleeps_the_closed_panel(tmp_path):
    hold, _ = _controller(tmp_path, lid_closed=lambda: True, causes_sleep=lambda: True)
    hold.update("agents", agents_active=True)
    hold.sleep_disabled_reader = lambda: True
    hold.external_display_reader = lambda: False
    panels = []
    hold.display_sleeper = lambda: panels.append(True)
    assert not hold.changed_system_disable
    hold.sync_display_sleep(lid_closed=True)
    assert panels == [True]
