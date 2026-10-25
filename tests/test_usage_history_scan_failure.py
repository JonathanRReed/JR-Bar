from __future__ import annotations

import threading
from types import SimpleNamespace

import pytest

from jrbar.core_runtime import _cmd_usage_history
from jrbar.core_server import CommandError
from jrbar.core_usage_history import ScanPass, UsageHistoryService
from tests.test_core_usage_history import _Threads


@pytest.mark.parametrize("cached", [False, True])
@pytest.mark.parametrize("command", [False, True])
def test_failed_history_scan_is_unavailable_and_retries_without_losing_cache(cached: bool, command: bool) -> None:
    threads = _Threads()
    now = [1800000000.0]
    fail = [False]
    release = threading.Event()
    release.set()
    tokens = [100]
    calls = []

    def scan(provider: str, days: int) -> list[tuple]:
        calls.append((provider, days))
        assert release.wait(5.0)
        if fail[0]:
            raise OSError("synthetic private scan detail")
        return [(provider, "synthetic.session", "gpt-6.1", now[0], tokens[0], 0, 0, 20, "synthetic.record")]

    service = UsageHistoryService(scan, budget=2.0, clock=lambda: now[0], wall_clock=lambda: now[0],
                                 codex_default_model=lambda: None, thread_factory=threads)
    controller = SimpleNamespace(settings=SimpleNamespace(token_history_enabled=True), _core_lock=threading.RLock(), _core_documents={},
                                 _core_usage_history_service=service)
    previous = None
    if cached:
        previous = service.document("codex", "7d")
        assert previous["pending"] is False and previous["records"] == 1
        now[0] += 61.0
    fail[0] = True
    try:
        if command:
            release.clear()
            pending = _cmd_usage_history(controller, {"provider": "codex", "range": "7d"})
            assert pending["stale"] if cached else pending["pending"]
            release.set()
            threads.settle()
            with pytest.raises(CommandError) as error:
                _cmd_usage_history(controller, {"provider": "codex", "range": "7d", "observe": True})
            assert error.value.code == "unavailable"
            assert "synthetic private scan detail" not in str(error.value)
        else:
            with pytest.raises(RuntimeError, match="Local history scan failed"):
                service.document("codex", "7d")
        assert not service.is_scanning()
        fail[0] = False
        tokens[0] = 200
        release.clear()
        retry = service.document("codex", "7d", budget=0.0)
        assert service.is_scanning()
        if previous is None:
            assert retry["pending"] is True
        else:
            assert retry["stale"] is True
            assert retry["days"] == previous["days"]
            assert retry["scanned_at"] == previous["scanned_at"]
        release.set()
        threads.settle()
        recovered = service.document("codex", "7d")
        assert recovered["stale"] is False and recovered["pending"] is False
        assert sum(day["tokens_in"] for day in recovered["days"]) == 200
        assert recovered["scanned_at"] == now[0]
        assert len(calls) == (3 if cached else 2)
    finally:
        release.set()
        service.close()
        threads.settle()



def test_failed_continuation_cannot_reuse_a_fresh_partial_snapshot() -> None:
    threads = _Threads()
    first_ready = threading.Event()
    continuation = threading.Event()
    retry = threading.Event()
    calls = []
    stamp = 1800000000.0
    records = [("codex", "synthetic.session", "gpt-6.1", stamp, 100, 0, 0, 20, "synthetic.record")]

    def scan(_provider: str, _days: int):
        calls.append(len(calls) + 1)
        if len(calls) == 1:
            return ScanPass(records, 1)
        if len(calls) == 2:
            first_ready.set()
            assert continuation.wait(5.0)
            raise OSError("synthetic continuation refusal")
        if len(calls) == 3:
            raise OSError("synthetic retry refusal")
        assert retry.wait(5.0)
        return records

    service = UsageHistoryService(scan, budget=2.0, fresh=60.0, clock=lambda: stamp,
                                 wall_clock=lambda: stamp, codex_default_model=lambda: None,
                                 thread_factory=threads, pass_pause=0.0)
    try:
        partial = service.document("codex", "7d")
        assert first_ready.wait(5.0)
        assert partial["reading_files"] == 1 and partial["records"] == 1
        continuation.set()
        threads.settle()
        assert not service.is_scanning()
        with pytest.raises(RuntimeError, match="Local history scan failed"):
            service.document("codex", "7d")
        assert calls == [1, 2, 3]
        active_retry = service.document("codex", "7d", budget=0.0)
        assert active_retry["stale"] is True and active_retry["partial"] is True
        assert active_retry["days"] == partial["days"]
        assert active_retry["scanned_at"] == partial["scanned_at"]
        retry.set()
        threads.settle()
        complete = service.document("codex", "7d")
        assert complete["reading_files"] == 0 and complete["partial"] is False
        assert complete["stale"] is False
    finally:
        continuation.set()
        retry.set()
        service.close()
        threads.settle()
