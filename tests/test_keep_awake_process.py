"""Keep Awake while a process runs: ``jrbar awake -- <command>`` and
``jrbar awake --pid N`` (the ``process`` lease).

The exit is heard from a kqueue ``NOTE_EXIT`` watch, never by asking: the
watch is real in the first tests (a short-lived child of this test, ended
by closing its stdin) and a recording fake everywhere else. No test takes
a power assertion: every hold runs on a fake ``caffeinate``."""

from __future__ import annotations

import subprocess
import sys
from pathlib import Path
from typing import ClassVar

import pytest

from jrbar import core_power, core_runtime
from jrbar.core_server import CommandError
from jrbar.keep_awake import (
    LEASE_END_EXITED,
    LEASE_FILE_NAME,
    LEASE_PROCESS,
    MAX_LEASE_SECONDS,
    POWER_LEASE_ENDED,
    AwakeLease,
    KeepAwakeController,
    LeaseRefusedError,
    PowerLog,
    lease_from_args,
)
from jrbar.models import AgentMode
from jrbar.process_watch import ProcessExitWatch, ProcessIdentity, process_label, read_identity
from tests.test_core_power import powered  # noqa: F401  (the powered daemon fixture)
from tests.test_core_runtime import headless  # noqa: F401
from tests.test_keep_awake_lease import NOW, _Clock, _controller, _Factory

WAIT = 10.0


def _child() -> subprocess.Popen:
    """A child that runs until its stdin closes -- no sleep, no timer."""
    return subprocess.Popen(
        [sys.executable, "-c", "import sys; sys.stdin.read()"],
        stdin=subprocess.PIPE,
        stdout=subprocess.DEVNULL,
        stderr=subprocess.DEVNULL,
    )


class _Watch:
    """A recording stand-in for ProcessExitWatch; ``exit()`` is the kernel's word."""

    made: ClassVar[list[_Watch]] = []

    def __init__(self, pid: int, on_exit) -> None:
        self.pid = pid
        self.on_exit = on_exit
        self.cancelled = False
        _Watch.made.append(self)

    def cancel(self) -> None:
        self.cancelled = True

    def exit(self) -> None:
        if not self.cancelled:
            self.on_exit()


def _identity(pid: int, started: int = 42, name: str = "swift"):
    return lambda asked: ProcessIdentity(asked, started, name) if asked == pid else None


@pytest.fixture(autouse=True)
def _fresh_watches():
    _Watch.made = []
    yield
    _Watch.made = []


# --- the watch ----------------------------------------------------------------


def test_the_kernel_says_when_the_process_exits() -> None:
    child = _child()
    heard: list[int] = []
    try:
        watch = ProcessExitWatch(child.pid, lambda: heard.append(child.pid))
        assert not watch.fired
        child.stdin.close()
        assert child.wait(timeout=WAIT) == 0
        assert watch.wait_fired(WAIT)
        assert heard == [child.pid]
    finally:
        if child.poll() is None:
            child.kill()
            child.wait(timeout=WAIT)


def test_a_process_already_gone_counts_as_exited() -> None:
    child = _child()
    child.stdin.close()
    child.wait(timeout=WAIT)
    heard: list[bool] = []
    watch = ProcessExitWatch(child.pid, lambda: heard.append(True))
    assert watch.wait_fired(WAIT)
    assert heard == [True]


def test_a_cancelled_watch_never_calls_back() -> None:
    child = _child()
    heard: list[bool] = []
    try:
        watch = ProcessExitWatch(child.pid, lambda: heard.append(True))
        watch.cancel()
        watch._thread.join(timeout=WAIT)
        assert not watch._thread.is_alive()
        child.stdin.close()
        child.wait(timeout=WAIT)
        assert heard == []
        assert not watch.fired
    finally:
        if child.poll() is None:
            child.kill()
            child.wait(timeout=WAIT)


def test_identity_reads_the_running_process_and_nothing_else() -> None:
    child = _child()
    try:
        identity = read_identity(child.pid)
        assert identity is not None
        assert identity.pid == child.pid
        assert identity.started > 0
        assert identity.name and "/" not in identity.name
        assert read_identity(child.pid) == identity
    finally:
        child.stdin.close()
        child.wait(timeout=WAIT)
    assert read_identity(child.pid) is None
    assert read_identity(1) is None
    assert read_identity(0) is None


@pytest.mark.parametrize(
    ("raw", "label"),
    [
        ("swift", "swift"),
        ("/usr/bin/swift", "swift"),
        ("  npm ", "npm"),
        ("Google Chrome Helper", "Google Chrome Helper"),
        ("--token", None),
        ("TOKEN=abc", None),
        ("", None),
        ("a" * 33, None),
        ("tab\there", None),
        (7, None),
    ],
)
def test_a_label_is_a_short_name_never_an_argument(raw, label) -> None:
    assert process_label(raw) == label


# --- the lease ------------------------------------------------------------------


def test_hold_awake_with_a_pid_is_a_process_lease_bounded_to_a_day() -> None:
    lease = lease_from_args(
        {"pid": 4242, "label": "swift"},
        now=NOW,
        pending_ids=frozenset(),
        identify=_identity(4242, name="swift-frontend"),
    )
    assert lease.kind == LEASE_PROCESS
    assert (lease.pid, lease.process_started, lease.label) == (4242, 42, "swift")
    assert lease.until == NOW + MAX_LEASE_SECONDS
    assert lease.display is False
    assert lease.to_dict()["label"] == "swift"
    assert AwakeLease.from_dict(lease.to_dict()) == lease


def test_the_process_names_itself_when_the_caller_gives_no_usable_label() -> None:
    for given in (None, "API_KEY=secret", "--verbose"):
        args = {"pid": 4242} if given is None else {"pid": 4242, "label": given}
        lease = lease_from_args(args, now=NOW, pending_ids=frozenset(), identify=_identity(4242))
        assert lease.label == "swift"


def test_a_process_that_already_ended_is_refused() -> None:
    with pytest.raises(LeaseRefusedError, match="already ended"):
        lease_from_args({"pid": 4242}, now=NOW, pending_ids=frozenset(), identify=lambda _pid: None)


@pytest.mark.parametrize("pid", [0, 1, -3, True, "4242", 2**40])
def test_a_pid_must_be_a_process_id(pid) -> None:
    with pytest.raises(ValueError):
        lease_from_args({"pid": pid}, now=NOW, pending_ids=frozenset(), identify=_identity(4242))


def test_a_pid_is_one_shape_among_the_others() -> None:
    with pytest.raises(ValueError, match="exactly one"):
        lease_from_args({"pid": 4242, "seconds": 60}, now=NOW, pending_ids=frozenset(), identify=_identity(4242))


def test_only_a_process_lease_names_a_process() -> None:
    with pytest.raises(ValueError):
        AwakeLease("duration", NOW, NOW + 60, pid=4242, process_started=1, label="swift")
    with pytest.raises(ValueError):
        AwakeLease(LEASE_PROCESS, NOW, NOW + 60, pid=4242, process_started=1, label="TOKEN=abc")


def _process_controller(clock: _Clock, factory: _Factory | None = None) -> KeepAwakeController:
    controller = _controller(clock, factory, grace_seconds=0)
    controller.process_watch_factory = _Watch
    controller.process_identity = _identity(4242)
    controller.power_log = PowerLog(clock=clock)
    return controller


def _process_lease(**kwargs) -> AwakeLease:
    return AwakeLease(LEASE_PROCESS, NOW, NOW + MAX_LEASE_SECONDS, pid=4242, process_started=42, label="swift", **kwargs)


def test_the_hold_lasts_until_the_exit_is_heard_then_lets_go() -> None:
    clock = _Clock()
    factory = _Factory()
    controller = _process_controller(clock, factory)
    exits: list[bool] = []
    controller.on_process_exit = lambda: exits.append(True)
    controller.start_lease(_process_lease())

    assert controller.update(AgentMode.IDLE_READY)
    assert controller.hold_state() == "manual"
    assert factory.processes[-1].command[1] == "-ims", "the computer, not the display"
    assert controller.hold_document()["lease"]["label"] == "swift"
    assert [watch.pid for watch in _Watch.made] == [4242]

    # Hours later, still running: nothing asked, nothing changed.
    clock.now = NOW + 5 * 3600
    assert controller.update(AgentMode.IDLE_READY)

    _Watch.made[0].exit()
    assert exits == [True], "the daemon is told to resync"
    assert not controller.update(AgentMode.IDLE_READY)
    assert controller.lease is None
    assert factory.processes[-1].terminated
    ended = controller.power_log.last(POWER_LEASE_ENDED)
    assert ended is not None and ended.reason == LEASE_END_EXITED
    assert ended.worth_a_line


def test_a_new_lease_or_a_cancel_stops_the_old_watch() -> None:
    controller = _process_controller(_Clock())
    controller.start_lease(_process_lease())
    first = _Watch.made[0]
    controller.start_lease(AwakeLease("indefinite", NOW, None))
    assert first.cancelled
    first.exit()
    assert controller.update(AgentMode.IDLE_READY), "a cancelled watch's exit ends nothing"
    assert controller.lease is not None and controller.lease.kind == "indefinite"

    controller.start_lease(_process_lease())
    second = _Watch.made[1]
    assert controller.end_lease()
    assert second.cancelled


def test_a_restart_keeps_the_hold_only_for_the_same_process(tmp_path: Path) -> None:
    clock = _Clock()
    controller = _process_controller(clock)
    controller.attach_store(tmp_path)
    controller.start_lease(_process_lease())
    assert (tmp_path / LEASE_FILE_NAME).exists()

    # The same process, still running: the new daemon re-arms the watch.
    same = _process_controller(clock)
    same.attach_store(tmp_path)
    assert same.lease == _process_lease()
    assert [watch.pid for watch in _Watch.made] == [4242, 4242]

    # The pid now belongs to a process that started later: not ours.
    other = _process_controller(clock)
    other.process_identity = _identity(4242, started=99)
    other.attach_store(tmp_path)
    assert other.lease is None
    assert not (tmp_path / LEASE_FILE_NAME).exists()
    assert other.power_log.last(POWER_LEASE_ENDED).reason == LEASE_END_EXITED


def test_without_a_watch_the_identity_still_ends_the_hold() -> None:
    clock = _Clock()
    controller = _process_controller(clock)

    def refused(_pid, _on_exit):
        raise OSError("kqueue refused")

    controller.process_watch_factory = refused
    controller.start_lease(_process_lease())
    assert controller.update(AgentMode.IDLE_READY)
    controller.process_identity = lambda _pid: None
    assert not controller.update(AgentMode.IDLE_READY)
    assert controller.lease is None


def test_a_display_process_lease_holds_the_display_only_with_the_lid_open() -> None:
    factory = _Factory()
    controller = _process_controller(_Clock(), factory)
    controller.start_lease(_process_lease(display=True))
    assert controller.update(AgentMode.IDLE_READY)
    assert factory.processes[-1].command[1] == "-dims"
    controller.observe_environment(lid_closed=True, external_display=False)
    assert controller.update(AgentMode.IDLE_READY)
    assert factory.processes[-1].command[1] == "-ims"


# --- over the socket ---------------------------------------------------------------


def test_hold_awake_pid_over_the_socket_and_the_exit_resyncs(powered, monkeypatch) -> None:  # noqa: F811
    controller = powered
    controller.keep_awake.process_watch_factory = _Watch
    controller.keep_awake.process_identity = _identity(4242)
    published: list[bool] = []
    queued: list = []
    monkeypatch.setattr(controller, "_core_publish_state", lambda: published.append(True), raising=False)
    # The watch thread queues the resync for the main thread; run the queue by hand.
    monkeypatch.setattr(controller, "_core_on_main_later", queued.append, raising=False)

    reply = core_runtime._cmd_hold_awake(controller, {"pid": 4242, "label": "swift", "source": "cli"})
    assert reply["lease"]["kind"] == "process"
    assert reply["lease"]["label"] == "swift"
    assert reply["hold"]["state"] == "manual"
    assert controller.keep_awake.process_running()

    published.clear()
    _Watch.made[-1].exit()
    assert controller.keep_awake.lease is not None, "nothing changes off the main thread"
    assert len(queued) == 1
    queued.pop()()
    assert controller.keep_awake.lease is None
    assert published, "the state says the hold let go"
    assert core_power.release_awake(controller, {})["ended"] is False


def test_hold_awake_refuses_a_process_that_has_ended(powered) -> None:  # noqa: F811
    controller = powered
    controller.keep_awake.process_identity = lambda _pid: None
    with pytest.raises(CommandError) as raised:
        core_runtime._cmd_hold_awake(controller, {"pid": 4242})
    assert raised.value.code == "refused"
    assert "already ended" in str(raised.value)
