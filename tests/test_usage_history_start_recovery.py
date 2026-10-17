from __future__ import annotations

import threading
from collections.abc import Callable

import pytest

from jrbar.core_usage_history import UsageHistoryService


class _QueuedThread:
    def __init__(self, target: Callable, args: tuple, fail: bool) -> None:
        self.target = target
        self.args = args
        self.fail = fail

    def start(self) -> None:
        if self.fail:
            raise RuntimeError("synthetic startup refusal")

    def run(self) -> None:
        self.target(*self.args)


class _ThreadFactory:
    def __init__(self) -> None:
        self.fail_at: str | None = None
        self.events: list[threading.Event] = []
        self.workers: list[_QueuedThread] = []

    def __call__(self, *, target: Callable, args: tuple, **_kwargs) -> _QueuedThread:
        self.events.append(args[1])
        failure, self.fail_at = self.fail_at, None
        if failure == "factory":
            raise RuntimeError("synthetic construction refusal")
        worker = _QueuedThread(target, args, failure == "start")
        self.workers.append(worker)
        return worker


@pytest.mark.parametrize("failure", ["factory", "start"])
@pytest.mark.parametrize("path", ["cold", "warm", "cached"])
def test_usage_history_retries_after_worker_start_failure(failure: str, path: str) -> None:
    threads = _ThreadFactory()
    now = [1_800_000_000.0]
    scans: list[tuple[str, int]] = []
    notifications: list[tuple[str, dict]] = []

    def scan(provider: str, days: int) -> list[tuple]:
        scans.append((provider, days))
        return [(provider, "synthetic.session", "gpt-6.1", now[0], 100, 0, 0, 20, "synthetic.record")]

    service = UsageHistoryService(
        scan, lambda kind, **fields: notifications.append((kind, fields)),
        budget=0.0, clock=lambda: now[0], wall_clock=lambda: now[0],
        codex_default_model=lambda: None, thread_factory=threads,
    )
    previous = None
    if path == "cached":
        assert service.document("codex", "7d")["pending"] is True
        threads.workers[-1].run()
        previous = service.document("codex", "7d")
        assert previous["records"] == 1
        now[0] += 61.0
        notifications.clear()

    threads.fail_at = failure
    with pytest.raises(RuntimeError, match="synthetic"):
        if path == "warm":
            service.warm(("codex",), "7d")
        else:
            service.document("codex", "7d")

    assert not service.is_scanning()
    assert threads.events[-1].is_set()
    assert len(scans) == (1 if path == "cached" else 0)
    retry = service.document("codex", "7d")
    assert service.is_scanning()
    if previous is None:
        assert retry["pending"] is True and retry["scanned_at"] is None
    else:
        assert retry["pending"] is False and retry["stale"] is True
        assert retry["days"] == previous["days"]
        assert retry["scanned_at"] == previous["scanned_at"]
    threads.workers[-1].run()
    assert not service.is_scanning()
    final = service.document("codex", "7d")
    assert final["pending"] is False and final["stale"] is False
    assert final["records"] == 1 and final["scanned_at"] == now[0]
    assert len(scans) == (2 if path == "cached" else 1)
    assert len(notifications) == 1
    assert notifications[0][0] == "usage_history_ready"
    assert notifications[0][1]["range"] == "7d"
