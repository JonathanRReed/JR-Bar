import subprocess
import sys
import threading
from pathlib import Path
from types import SimpleNamespace

import pytest

from jrbar.core_runtime import _cmd_usage_history
from jrbar.core_server import CommandError
from jrbar.core_usage_history import FAILURE_MESSAGE, UsageHistoryScanError, UsageHistoryService


class SteppedThreads:
    def __init__(self):
        self.pending = []

    def __call__(self, *, target, args, **_kwargs):
        return SimpleNamespace(start=lambda: self.pending.append(lambda: target(*args)))

    def step(self):
        self.pending.pop(0)()


def fixture_service():
    threads = SteppedThreads()
    events = []
    calls = []
    fail = [False]
    stamp = [1800000000.0]

    def scan(provider, days):
        calls.append((provider, days))
        if fail[0]:
            raise OSError("synthetic private detail")
        return [(provider, "synthetic.session", "gpt-6.1", stamp[0], 100, 0, 0, 20, "synthetic.record")]

    service = UsageHistoryService(scan, lambda kind, **fields: events.append((kind, fields)),
                                  clock=lambda: stamp[0], wall_clock=lambda: stamp[0],
                                  codex_default_model=lambda: None, thread_factory=threads)
    owner = SimpleNamespace(settings=SimpleNamespace(token_history_enabled=True), _core_lock=threading.RLock(), _core_documents={}, _core_usage_history_service=service)
    return service, owner, threads, events, calls, fail, stamp


def test_observation_never_starts_work_and_current_success_outlives_old_failure_event():
    service, owner, threads, events, calls, fail, stamp = fixture_service()
    assert service.observe("codex", "7d") is None
    assert threads.pending == []
    assert service.observe("synthetic-unscanned", "7d")["pending"] is False
    with pytest.raises(ValueError):
        service.observe("codex", "2d")
    pending = _cmd_usage_history(owner, {"provider": "codex", "range": "7d"})
    assert pending["pending"] is True
    assert service.observe("codex", "7d")["pending"] is True
    assert len(threads.pending) == 1
    fail[0] = True
    threads.step()
    assert events == [("usage_history_failed", {"provider": "codex", "range": "7d", "code": "unavailable",
                                               "message": FAILURE_MESSAGE, "notify": False})]
    for _ in range(2):
        with pytest.raises(UsageHistoryScanError):
            service.observe("codex", "7d")
    assert calls == [("codex", 7)] and threads.pending == []
    fail[0] = False
    assert _cmd_usage_history(owner, {"provider": "codex", "range": "7d"})["pending"] is True
    threads.step()
    for _ in range(2):
        recovered = _cmd_usage_history(owner, {"provider": "codex", "range": "7d", "observe": True})
        assert recovered["records"] == 1 and recovered["stale"] is False
    assert len(calls) == 2 and threads.pending == []
    stamp[0] += 61
    stale = _cmd_usage_history(owner, {"provider": "codex", "range": "7d"})
    assert stale["stale"] is True and stale["partial"] is False
    assert service.observe("codex", "7d")["days"] == recovered["days"]
    fail[0] = True
    threads.step()
    with pytest.raises(CommandError) as error:
        _cmd_usage_history(owner, {"provider": "codex", "range": "7d", "observe": True})
    assert error.value.code == "unavailable" and str(error.value) == FAILURE_MESSAGE
    assert len(calls) == 3 and threads.pending == []


@pytest.mark.parametrize("value", [None, 0, 1, "true", [], {}])
def test_observe_argument_is_strict_boolean(value):
    _, owner, threads, _, calls, _, _ = fixture_service()
    with pytest.raises(CommandError) as error:
        _cmd_usage_history(owner, {"provider": "codex", "observe": value})
    assert error.value.code == "invalid_args"
    assert threads.pending == [] and calls == []


def test_unknown_observation_is_unavailable_and_invalid_range_is_rejected():
    _, owner, threads, _, _, _, _ = fixture_service()
    with pytest.raises(CommandError) as error:
        _cmd_usage_history(owner, {"provider": "codex", "range": "7d", "observe": True})
    assert error.value.code == "unavailable"
    assert str(error.value) == "No local history reading is available yet. Try Refresh."
    with pytest.raises(CommandError) as error:
        _cmd_usage_history(owner, {"provider": "codex", "range": "2d", "observe": True})
    assert error.value.code == "invalid_range"
    assert threads.pending == []


def test_observation_after_thread_start_refusal_does_not_invent_an_active_scan():
    def refuse(**_kwargs):
        raise RuntimeError("synthetic thread refusal")

    service = UsageHistoryService(lambda *_: [], thread_factory=refuse, codex_default_model=lambda: None)
    with pytest.raises(RuntimeError, match="synthetic thread refusal"):
        service.document("codex", "7d", budget=0)
    assert service.observe("codex", "7d") is None
    assert not service.is_scanning()


@pytest.mark.parametrize("symlink", [False, True])
def test_native_fixture_refuses_other_sockets_without_touching_them(tmp_path, symlink):
    directory = tmp_path / "jrbar-history-guard"
    directory.mkdir()
    protected = tmp_path / "core.sock"
    protected.write_text("synthetic socket sentinel")
    if symlink:
        target = directory / "s"
        target.symlink_to(protected)
    else:
        target = directory / "core.sock"
        target.write_text("synthetic socket sentinel")
    fixture = Path(__file__).resolve().parents[1] / "app/scripts/usage-history-rpc-fixture.py"
    result = subprocess.run([sys.executable, str(fixture), "--socket", str(target)],
                            capture_output=True, text=True, timeout=5, check=False)
    assert result.returncode == 2
    assert "private temporary socket named s" in result.stderr
    assert protected.read_text() == "synthetic socket sentinel"
    assert target.read_text() == "synthetic socket sentinel"
