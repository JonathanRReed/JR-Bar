import pytest

from jrbar import keep_awake
from jrbar.keep_awake import KeepAwakeController


class DeferredThread:
    def __init__(self, queue, target, args):
        self.queue = queue
        self.target = target
        self.args = args

    def start(self):
        if self.queue.fail_at == "start":
            raise RuntimeError("worker unavailable")

    def run(self):
        return self.target(*self.args)


class Threads:
    def __init__(self):
        self.items = []
        self.fail_at = None

    def create(self, *, target, args=(), **_kwargs):
        if self.fail_at == "construct":
            raise RuntimeError("worker unavailable")
        thread = DeferredThread(self, target, args)
        self.items.append(thread)
        return thread


@pytest.fixture
def threads(monkeypatch):
    queue = Threads()
    monkeypatch.setattr(keep_awake.threading, "Thread", queue.create)
    monkeypatch.setattr(keep_awake.firmware_hold, "held_reason", lambda _path: None)
    return queue


def controller(reader, *, asynchronous=True):
    def forbidden_process(*_args, **_kwargs):
        pytest.fail("This test must not start an assertion process")

    return KeepAwakeController(status_reader=reader, status_read_seconds=60,
                               status_read_async=asynchronous, process_factory=forbidden_process,
                               watch_current_process=False)


@pytest.mark.parametrize("stage", ["construct", "start"])
def test_worker_start_failure_settles_and_allows_immediate_retry(threads, tmp_path, stage):
    reads = []
    keep = controller(reads.append)
    target = tmp_path / "synthetic-device" / "LEDS.LED"
    status = target.parent / "keepalive"
    threads.fail_at = stage
    try:
        result = keep.poke_status_file(target, now=0)
    except RuntimeError:
        result = "escaped"
    assert result is None
    assert keep.last_status_error == "worker unavailable"
    assert status not in keep.status_read_in_flight_by_path
    assert status not in keep.last_status_read_monotonic_by_path
    threads.fail_at = None
    assert keep.poke_status_file(target, now=0) == status
    threads.items[-1].run()
    assert reads == [status]
    assert keep.last_status_error is None


def test_retired_queued_work_does_not_read_or_clear_replacement(threads, tmp_path):
    reads = []
    keep = controller(reads.append)
    target = tmp_path / "synthetic-device" / "LEDS.LED"
    status = target.parent / "keepalive"
    keep.poke_status_file(target, now=0)
    old = threads.items[-1]
    keep.set_enabled(False)
    keep.set_enabled(True)
    keep.poke_status_file(target, now=1)
    current = threads.items[-1]
    old.run()
    assert reads == []
    assert status in keep.status_read_in_flight_by_path
    current.run()
    assert reads == [status]
    assert status not in keep.status_read_in_flight_by_path


def test_busy_poll_does_not_consume_the_next_read_interval(threads, tmp_path):
    keep = controller(lambda _path: None)
    target = tmp_path / "synthetic-device" / "LEDS.LED"
    status = target.parent / "keepalive"
    keep.poke_status_file(target, now=0)
    assert keep.poke_status_file(target, now=61) is None
    assert keep.last_status_read_monotonic_by_path[status] == 0
    threads.items[-1].run()
    assert keep.poke_status_file(target, now=61.1) == status


def test_active_retired_read_blocks_same_path_until_it_finishes(threads, tmp_path):
    target = tmp_path / "synthetic-device" / "LEDS.LED"
    attempts = []

    def reader(_path):
        keep.set_enabled(False)
        keep.set_enabled(True)
        attempts.append(keep.poke_status_file(target, now=61))

    keep = controller(reader)
    keep.poke_status_file(target, now=0)
    threads.items[0].run()
    assert attempts == [None]
    assert len(threads.items) == 1
    assert keep.poke_status_file(target, now=61) == target.parent / "keepalive"


def test_old_active_failure_cannot_replace_current_generation_error(threads, tmp_path):
    target = tmp_path / "old-device" / "LEDS.LED"
    other = tmp_path / "current-device" / "LEDS.LED"

    def current_reader(_path):
        raise OSError("current failure")

    def old_reader(_path):
        keep.set_enabled(False)
        keep.set_enabled(True)
        keep.status_reader = current_reader
        keep.poke_status_file(other, now=1)
        threads.items[-1].run()
        raise OSError("retired failure")

    keep = controller(old_reader)
    keep.poke_status_file(target, now=0)
    threads.items[0].run()
    assert keep.last_status_error == "current failure"


def test_different_paths_keep_independent_admission_and_cadence(threads, tmp_path):
    reads = []
    keep = controller(reads.append)
    first = tmp_path / "first" / "LEDS.LED"
    second = tmp_path / "second" / "LEDS.LED"
    assert keep.poke_status_file(first, now=0) == first.parent / "keepalive"
    assert keep.poke_status_file(second, now=0) == second.parent / "keepalive"
    threads.items[0].run()
    assert second.parent / "keepalive" in keep.status_read_in_flight_by_path
    assert keep.poke_status_file(first, now=30) is None
    threads.items[1].run()
    assert reads == [first.parent / "keepalive", second.parent / "keepalive"]


def test_synchronous_failures_keep_cadence_and_recovery(threads, tmp_path):
    def failure(_path):
        raise OSError("read unavailable")

    keep = controller(failure, asynchronous=False)
    target = tmp_path / "synthetic-device" / "LEDS.LED"
    assert keep.poke_status_file(target, now=0) is None
    assert keep.last_status_error == "read unavailable"
    reads = []
    keep.status_reader = reads.append
    assert keep.poke_status_file(target, now=30) is None
    assert keep.poke_status_file(target, now=61) == target.parent / "keepalive"
    assert keep.last_status_error is None
    assert reads == [target.parent / "keepalive"]
    assert threads.items == []


def test_releasing_sleep_assertion_does_not_cancel_independent_keepalive(threads, tmp_path):
    reads = []
    keep = controller(reads.append)
    target = tmp_path / "synthetic-device" / "LEDS.LED"
    keep.poke_status_file(target, now=0)
    keep.release()
    threads.items[0].run()
    assert reads == [target.parent / "keepalive"]


@pytest.mark.parametrize("stage", ["construct", "start"])
def test_outer_device_worker_start_failure_allows_retry(threads, tmp_path, stage):
    from types import SimpleNamespace

    from test_capacity_expiry_publication import method

    logs = []
    scope = {"threading": keep_awake.threading, "time": SimpleNamespace(monotonic=lambda: 0),
             "log_status_bar": logs.append}
    poke = method("daemon_controller.py", "poke_led_devices", scope)
    target = tmp_path / "synthetic-device" / "LEDS.LED"
    host = SimpleNamespace(_keepalive_poke_in_flight=False, status_keepalive_targets=lambda: [target],
                           agent_led_controllers_by_device={}, _keepalive_fresh_read=lambda *_args: True,
                           keep_awake=SimpleNamespace(last_status_error=None), last_status_read_error=None)
    threads.fail_at = stage
    escaped = False
    try:
        poke(host)
    except RuntimeError:
        escaped = True
    assert not escaped
    assert not host._keepalive_poke_in_flight
    assert logs and "worker unavailable" in logs[-1]
    poke(host)
    assert len(logs) == 1
    threads.fail_at = None
    poke(host)
    assert host._keepalive_poke_in_flight
    threads.items[-1].run()
    assert not host._keepalive_poke_in_flight


def test_disabled_reader_does_not_probe_firmware_or_start_work(threads, monkeypatch, tmp_path):
    probes = []
    monkeypatch.setattr(keep_awake.firmware_hold, "held_reason", lambda path: probes.append(path))
    keep = controller(lambda _path: None)
    keep.set_enabled(False)
    assert keep.poke_status_file(tmp_path / "device" / "LEDS.LED", now=0) is None
    assert probes == []
    assert threads.items == []


def test_active_io_reservation_survives_disable_on_another_thread(monkeypatch, tmp_path):
    entered = keep_awake.threading.Event()
    allow_finish = keep_awake.threading.Event()
    real_thread = keep_awake.threading.Thread
    workers = []
    timeouts = []

    def thread_factory(**kwargs):
        thread = real_thread(**kwargs)
        workers.append(thread)
        return thread

    def reader(_path):
        entered.set()
        if not allow_finish.wait(timeout=5):
            timeouts.append(True)

    monkeypatch.setattr(keep_awake.threading, "Thread", thread_factory)
    monkeypatch.setattr(keep_awake.firmware_hold, "held_reason", lambda _path: None)
    keep = controller(reader)
    target = tmp_path / "device" / "LEDS.LED"
    try:
        keep.poke_status_file(target, now=0)
        assert entered.wait(timeout=5)
        keep.set_enabled(False)
        keep.set_enabled(True)
        assert keep.poke_status_file(target, now=61) is None
    finally:
        allow_finish.set()
        for thread in workers:
            thread.join(timeout=5)
    assert all(not thread.is_alive() for thread in workers)
    assert not timeouts
    assert len(workers) == 1
    assert target.parent / "keepalive" not in keep.status_read_in_flight_by_path


@pytest.mark.parametrize("stage", ["construct", "start"])
def test_worker_start_failure_restores_previous_actual_dispatch(threads, tmp_path, stage):
    reads = []
    keep = controller(reads.append)
    target = tmp_path / "device" / "LEDS.LED"
    keep.poke_status_file(target, now=0)
    threads.items[-1].run()
    threads.fail_at = stage
    assert keep.poke_status_file(target, now=61) is None
    assert keep.last_status_read_monotonic_by_path[target.parent / "keepalive"] == 0
    threads.fail_at = None
    assert keep.poke_status_file(target, now=61) == target.parent / "keepalive"
    threads.items[-1].run()
    assert reads == [target.parent / "keepalive", target.parent / "keepalive"]


def test_old_active_success_cannot_clear_current_generation_error(threads, tmp_path):
    target = tmp_path / "old-device" / "LEDS.LED"
    other = tmp_path / "current-device" / "LEDS.LED"

    def current_reader(_path):
        raise OSError("current failure")

    def old_reader(_path):
        keep.set_enabled(False)
        keep.set_enabled(True)
        keep.status_reader = current_reader
        keep.poke_status_file(other, now=1)
        threads.items[-1].run()

    keep = controller(old_reader)
    keep.poke_status_file(target, now=0)
    threads.items[0].run()
    assert keep.last_status_error == "current failure"
