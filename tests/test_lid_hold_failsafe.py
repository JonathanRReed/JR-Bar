"""The closed-lid hold never turns `disablesleep` on without its fail-safe,
and never retires the fail-safe while `disablesleep` is still on."""

from __future__ import annotations

from pathlib import Path

from jrbar.lid_sleep import ClosedLidAwakeController
from jrbar.settings import CLOSED_LID_AWAKE_AGENTS, CLOSED_LID_AWAKE_NEVER


class FakeProcess:
    def __init__(self, argv):
        self.argv = argv
        self.terminated = False

    def poll(self):
        return 1 if self.terminated else None

    def terminate(self):
        self.terminated = True

    def kill(self):
        self.terminated = True

    def wait(self, timeout=None):
        return 0


def _controller(tmp_path: Path, *, setter, renewal_path: Path | None = None, factory=None):
    def default_factory(argv, **_kwargs):
        return FakeProcess(argv)

    return ClosedLidAwakeController(
        process_factory=factory or default_factory,
        sleep_disabled_reader=lambda: False,
        sleep_disabled_setter=setter,
        use_system_disable=True,
        renewal_path=renewal_path or tmp_path / "lid-hold-renewal",
    )


def test_no_disablesleep_without_a_heartbeat(tmp_path: Path) -> None:
    # The renewal file cannot be written: its parent is a regular file.
    blocker = tmp_path / "blocker"
    blocker.write_text("x")
    calls: list[bool] = []
    controller = _controller(
        tmp_path, setter=calls.append, renewal_path=blocker / "lid-hold-renewal"
    )

    controller.update(CLOSED_LID_AWAKE_AGENTS, agents_active=True)

    assert True not in calls
    assert controller.changed_system_disable is False
    assert controller.last_error and "renewal" in controller.last_error


def test_no_disablesleep_without_a_watchdog(tmp_path: Path) -> None:
    calls: list[bool] = []

    def factory(argv, **_kwargs):
        if argv[0] == "/bin/sh":
            raise OSError("no shell")
        return FakeProcess(argv)

    controller = _controller(tmp_path, setter=calls.append, factory=factory)
    controller.update(CLOSED_LID_AWAKE_AGENTS, agents_active=True)

    assert True not in calls
    assert controller.changed_system_disable is False
    assert controller.last_error and "watchdog" in controller.last_error


def test_disablesleep_is_taken_once_the_failsafe_recovers(tmp_path: Path) -> None:
    calls: list[bool] = []
    broken = {"on": True}

    def factory(argv, **_kwargs):
        if argv[0] == "/bin/sh" and broken["on"]:
            raise OSError("no shell")
        return FakeProcess(argv)

    controller = _controller(tmp_path, setter=calls.append, factory=factory)
    controller.update(CLOSED_LID_AWAKE_AGENTS, agents_active=True)
    assert calls == []

    broken["on"] = False
    controller.update(CLOSED_LID_AWAKE_AGENTS, agents_active=True)
    assert calls == [True]


def test_failed_release_keeps_the_failsafe_in_place(tmp_path: Path) -> None:
    calls: list[bool] = []
    fail = {"on": False}

    def setter(enabled: bool) -> None:
        if not enabled and fail["on"]:
            raise OSError("sudoers rule gone")
        calls.append(enabled)

    controller = _controller(tmp_path, setter=setter)
    controller.update(CLOSED_LID_AWAKE_AGENTS, agents_active=True)
    assert calls == [True]
    renewal = tmp_path / "lid-hold-renewal"
    assert renewal.exists()

    fail["on"] = True
    controller.update(CLOSED_LID_AWAKE_NEVER, agents_active=False)

    # disablesleep is still on, so the marker the watchdog polls stays.
    assert controller.changed_system_disable is True
    assert renewal.exists()
    assert controller.last_error and "disablesleep" in controller.last_error

    # A later release that works finishes the job.
    fail["on"] = False
    controller.release()
    assert calls == [True, False]
    assert not renewal.exists()


def test_the_renewal_file_is_touched_at_most_every_half_minute_while_asked_every_refresh(
    tmp_path: Path, monkeypatch
) -> None:
    import os

    from jrbar.lid_sleep import RENEWAL_TOUCH_SECONDS

    calls: list[bool] = []
    controller = _controller(tmp_path, setter=calls.append)
    clock = [1_000_000.0]
    controller.wall_clock = lambda: clock[0]
    renewal = controller.renewal_path
    touches: list[float] = []
    real_touch = Path.touch

    def counting_touch(self, *args, **kwargs):
        real_touch(self, *args, **kwargs)
        if self == renewal:
            touches.append(clock[0])
            os.utime(self, (clock[0], clock[0]))

    monkeypatch.setattr(Path, "touch", counting_touch)

    for _ in range(40):
        controller.update(CLOSED_LID_AWAKE_AGENTS, agents_active=True)
        clock[0] += 0.5
    assert touches == [1_000_000.0], "twenty seconds of asking is one touch"

    clock[0] = 1_000_000.0 + RENEWAL_TOUCH_SECONDS + 1
    controller.update(CLOSED_LID_AWAKE_AGENTS, agents_active=True)
    assert len(touches) == 2, "past the interval the heartbeat is renewed"

    renewal.unlink()
    controller.update(CLOSED_LID_AWAKE_AGENTS, agents_active=True)
    assert len(touches) == 3, "a vanished marker is put back at once"
    assert calls == [True]
