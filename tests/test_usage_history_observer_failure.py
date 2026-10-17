from __future__ import annotations

import threading

import pytest

from jrbar.core_usage_history import READY_EVENT, ScanPass, UsageHistoryScanError, UsageHistoryService
from tests.test_core_usage_history import _Threads


class CapturedThreads(_Threads):
    def __init__(self):
        super().__init__()
        self.failures = []

    def __call__(self, *, target, args, **kwargs):
        def run():
            try:
                target(*args)
            except Exception as error:
                self.failures.append(type(error).__name__)

        return super().__call__(target=run, args=(), **kwargs)


@pytest.mark.parametrize("fault", ["none", "log", "publish", "both", "publish-always"])
def test_observer_failure_cannot_strand_the_following_scan_pass(fault):
    threads = CapturedThreads()
    release = threading.Event()
    calls = []
    events = []
    logs = []
    publish_calls = []
    stamp = 1_800_000_000.0

    def scan(provider, _days):
        calls.append(provider)
        assert release.wait(5)
        records = [(provider, "synthetic.session", "gpt-6.1", stamp,
                    100, 0, 0, 20, f"synthetic.record.{index}") for index in range(len(calls))]
        return ScanPass(records, reading_files=1 if len(calls) == 1 else 0)

    def publish(kind, **fields):
        publish_calls.append(kind)
        if fault == "publish-always" or (len(publish_calls) == 1 and fault in {"publish", "both"}):
            raise OSError("synthetic event observer refusal")
        events.append((kind, fields))

    def log(message):
        logs.append(message)
        if len(logs) == 1 and fault in {"log", "both"}:
            raise OSError("synthetic log observer refusal")

    service = UsageHistoryService(scan, publish, log=log, thread_factory=threads,
                                  clock=lambda: stamp, wall_clock=lambda: stamp,
                                  codex_default_model=lambda: None, pass_pause=0)
    try:
        pending = service.document("codex", "7d", budget=0)
        assert pending["pending"] is True
        release.set()
        threads.settle()
        assert all(not thread.is_alive() for thread in threads.threads)
        assert not service.is_scanning(), "A dead observer left a following pass permanently in flight"
        assert threads.failures == []
        assert calls == ["codex", "codex"]
        complete = service.observe("codex", "7d")
        assert complete["records"] == 2
        assert complete["reading_files"] == 0
        assert complete["partial"] is False and complete["stale"] is False
        if fault == "publish-always":
            assert events == [] and publish_calls == [READY_EVENT, READY_EVENT]
        elif fault in {"publish", "both"}:
            assert events[0][0] == READY_EVENT
            assert events[0][1]["reading_files"] == 0
        else:
            assert events[0][0] == READY_EVENT
            assert events[0][1]["reading_files"] == 1
    finally:
        release.set()
        service.close()
        threads.settle()


def test_failed_terminal_publication_keeps_failure_observable_and_explicit_retry_works():
    threads = CapturedThreads()
    release = threading.Event()
    failing = [True]

    def scan(provider, _days):
        assert release.wait(5)
        if failing[0]:
            raise OSError("synthetic scan refusal")
        return [(provider, "synthetic.session", "gpt-6.1", 1_800_000_000.0,
                 100, 0, 0, 20, "synthetic.record")]

    def publish(*_args, **_fields):
        raise OSError("synthetic publication refusal")

    service = UsageHistoryService(scan, publish, thread_factory=threads, codex_default_model=lambda: None,
                                  clock=lambda: 1_800_000_000.0, wall_clock=lambda: 1_800_000_000.0)
    try:
        assert service.document("codex", "7d", budget=0)["pending"] is True
        release.set()
        threads.settle()
        assert not service.is_scanning() and threads.failures == []
        with pytest.raises(UsageHistoryScanError):
            service.observe("codex", "7d")
        failing[0] = False
        release.clear()
        assert service.document("codex", "7d", budget=0)["pending"] is True
        release.set()
        threads.settle()
        assert not service.is_scanning() and threads.failures == []
        assert service.observe("codex", "7d")["records"] == 1
    finally:
        release.set()
        service.close()
        threads.settle()


def test_close_from_a_failed_partial_publication_retires_the_reserved_following_pass():
    threads = CapturedThreads()
    release = threading.Event()
    calls = []

    def scan(_provider, _days):
        calls.append(1)
        assert release.wait(5)
        return ScanPass([], reading_files=1)

    def publish(*_args, **_fields):
        service.close()
        raise OSError("synthetic publication refusal")

    service = UsageHistoryService(scan, publish, thread_factory=threads,
                                  codex_default_model=lambda: None, pass_pause=0)
    try:
        assert service.document("codex", "7d", budget=0)["pending"] is True
        release.set()
        threads.settle()
        assert not service.is_scanning() and threads.failures == []
        assert calls == [1]
        assert service.observe("codex", "7d")["reading_files"] == 1
    finally:
        release.set()
        service.close()
        threads.settle()
