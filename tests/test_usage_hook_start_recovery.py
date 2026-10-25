from __future__ import annotations

import ast
import threading
from pathlib import Path
from types import SimpleNamespace

import pytest

from jrbar import provider_usage_status_bar as production
from jrbar import usage_event_hooks as hooks
from jrbar.provider_feature_settings import ProviderPresentationSettings
from jrbar.provider_reset_events import ResetDeliveryState
from jrbar.provider_usage_runtime import ProviderUsageApply, ProviderUsageState
from tests.test_usage_event_hooks import lane, snapshot


class _QueuedThread:
    def __init__(self, *, target, **_kwargs):
        self.target = target

    def start(self):
        pass

    def run(self):
        self.target()


def _config(enabled=True):
    return hooks.load_usage_hook_config({"enabled": enabled, "rules": [{
        "id": "synthetic", "executable": "/synthetic/hook", "event": "*",
    }]})


def _refuse_worker(monkeypatch, failure):
    if failure == "factory":
        def create(**_kwargs):
            raise RuntimeError("synthetic worker construction refusal")
        monkeypatch.setattr(hooks.threading, "Thread", create)
    else:
        class Refused(_QueuedThread):
            def start(self):
                raise RuntimeError("synthetic worker startup refusal")
        monkeypatch.setattr(hooks.threading, "Thread", Refused)


@pytest.mark.parametrize("failure", ["factory", "start"])
@pytest.mark.parametrize("event_name", ["usage_updated", "quota_reset"])
def test_failed_worker_launch_is_reported_and_does_not_consume_cooldown(monkeypatch, failure, event_name):
    config = _config()
    event = hooks.sample_event(event_name, "codex", now=1000.0)
    limiter = hooks.UsageHookLimiter()
    results = hooks.UsageHookResults()
    logged = []
    _refuse_worker(monkeypatch, failure)
    assert hooks.dispatch_usage_hooks(config, (event,), limiter=limiter, results=results,
                                     environ={}, clock=lambda: 1000.0, log=logged.append) is None
    failure_result = results.get("synthetic")
    assert failure_result is not None and failure_result.outcome == "error"
    assert failure_result.event == event_name and failure_result.at == 1000.0
    assert logged
    monkeypatch.setattr(hooks.threading, "Thread", _QueuedThread)
    ran = []

    def execute(rule, event, **_kwargs):
        ran.append(event.name)
        return hooks.UsageHookResult(rule.id, event.name, event.provider_id, 1000.0, "ok", exit_code=0)

    monkeypatch.setattr(hooks, "run_rule", execute)
    retry = hooks.dispatch_usage_hooks(config, (event,), limiter=limiter, results=results,
                                       environ={}, clock=lambda: 1000.0, log=logged.append)
    assert retry is not None
    retry.run()
    assert ran == [event_name] and results.get("synthetic").outcome == "ok"
    if event_name == "usage_updated":
        assert hooks.dispatch_usage_hooks(config, (event,), limiter=limiter, environ={},
                                         clock=lambda: 1001.0, log=logged.append) is None


def test_failure_refund_preserves_the_prior_cooldown(monkeypatch):
    config = _config()
    event = hooks.sample_event("usage_updated", "codex", now=1000.0)
    limiter = hooks.UsageHookLimiter()
    assert limiter.admit(config.rules[0], event, 400.0)
    _refuse_worker(monkeypatch, "start")
    assert hooks.dispatch_usage_hooks(config, (event,), limiter=limiter, environ={},
                                     clock=lambda: 1000.0, log=lambda _line: None) is None
    assert not limiter.admit(config.rules[0], event, 999.0)
    assert limiter.admit(config.rules[0], event, 1000.0)


def test_failure_refund_cannot_erase_a_newer_same_timestamp_admission(monkeypatch):
    config = _config()
    event = hooks.sample_event("usage_updated", "codex", now=1000.0)
    limiter = hooks.UsageHookLimiter(interval=0.0)
    starts = []

    class Nested(_QueuedThread):
        def start(self):
            starts.append(self)
            if len(starts) == 1:
                nested = hooks.dispatch_usage_hooks(config, (event,), limiter=limiter, environ={},
                                                    clock=lambda: 1000.0, log=lambda _line: None)
                assert nested is not None
                raise RuntimeError("synthetic older worker refusal")

    monkeypatch.setattr(hooks.threading, "Thread", Nested)
    assert hooks.dispatch_usage_hooks(config, (event,), limiter=limiter, environ={},
                                     clock=lambda: 1000.0, log=lambda _line: None) is None
    assert len(starts) == 2
    limiter.interval = 600.0
    assert not limiter.admit(config.rules[0], event, 1000.0)


@pytest.mark.parametrize("interval, later", [(0.0, 1000.0), (600.0, 1600.0)])
def test_overlapping_failed_launches_do_not_restore_each_others_cooldown(monkeypatch, interval, later):
    config = _config()
    event = hooks.sample_event("usage_updated", "codex", now=1000.0)
    limiter = hooks.UsageHookLimiter(interval=interval)
    real_thread = threading.Thread
    first_started = threading.Event()
    second_started = threading.Event()
    first_done = threading.Event()
    starts = []
    errors = []
    waits = []

    class Refused(_QueuedThread):
        def start(self):
            starts.append(self)
            if len(starts) == 1:
                first_started.set()
                waits.append(second_started.wait(5.0))
            else:
                second_started.set()
                waits.append(first_done.wait(5.0))
            raise RuntimeError("synthetic overlapping worker refusal")

    monkeypatch.setattr(hooks.threading, "Thread", Refused)

    def dispatch(first):
        try:
            assert hooks.dispatch_usage_hooks(config, (event,), limiter=limiter, environ={},
                                             clock=lambda: 1000.0 if first else later,
                                             log=lambda _line: None) is None
        except Exception as error:
            errors.append(error)
        finally:
            if first:
                first_done.set()

    older = real_thread(target=dispatch, args=(True,))
    newer = real_thread(target=dispatch, args=(False,))
    older.start()
    assert first_started.wait(5.0)
    newer.start()
    older.join(timeout=5.0)
    newer.join(timeout=5.0)
    assert not older.is_alive() and not newer.is_alive()
    assert not errors and len(starts) == 2
    assert waits == [True, True]
    limiter.interval = 600.0
    assert limiter.admit(config.rules[0], event, later)


def test_successful_start_keeps_cooldown_when_script_fails(monkeypatch):
    config = _config()
    event = hooks.sample_event("usage_updated", "codex", now=1000.0)
    limiter = hooks.UsageHookLimiter()
    results = hooks.UsageHookResults()
    monkeypatch.setattr(hooks.threading, "Thread", _QueuedThread)
    monkeypatch.setattr(hooks, "run_rule", lambda rule, event, **_kwargs: hooks.UsageHookResult(
        rule.id, event.name, event.provider_id, 1000.0, "exit", exit_code=1))
    worker = hooks.dispatch_usage_hooks(config, (event,), limiter=limiter, results=results,
                                        environ={}, clock=lambda: 1000.0, log=lambda _line: None)
    assert worker is not None
    worker.run()
    assert results.get("synthetic").outcome == "exit"
    assert not limiter.admit(config.rules[0], event, 1001.0)


def test_start_failure_with_broken_logger_still_refunds(monkeypatch):
    config = _config()
    event = hooks.sample_event("usage_updated", "codex", now=1000.0)
    limiter = hooks.UsageHookLimiter()
    _refuse_worker(monkeypatch, "start")

    def refused_log(_line):
        raise RuntimeError("synthetic logging refusal")

    assert hooks.dispatch_usage_hooks(config, (event,), limiter=limiter, environ={},
                                     clock=lambda: 1000.0, log=refused_log) is None
    assert limiter.admit(config.rules[0], event, 1000.0)


def test_pending_launch_blocks_duplicate_work(monkeypatch):
    config = _config()
    event = hooks.sample_event("usage_updated", "codex", now=1000.0)
    limiter = hooks.UsageHookLimiter()
    nested = []

    class Pending(_QueuedThread):
        def start(self):
            nested.append(hooks.dispatch_usage_hooks(config, (event,), limiter=limiter,
                          environ={}, clock=lambda: 1001.0, log=lambda _line: None))

    monkeypatch.setattr(hooks.threading, "Thread", Pending)
    assert hooks.dispatch_usage_hooks(config, (event,), limiter=limiter, environ={},
                                     clock=lambda: 1000.0, log=lambda _line: None) is not None
    assert nested == [None]


def test_older_success_cannot_replace_newer_committed_cooldown(monkeypatch):
    config = _config()
    event = hooks.sample_event("usage_updated", "codex", now=1000.0)
    limiter = hooks.UsageHookLimiter(interval=600.0)
    starts = []

    class Nested(_QueuedThread):
        def start(self):
            starts.append(self)
            if len(starts) == 1:
                assert hooks.dispatch_usage_hooks(config, (event,), limiter=limiter, environ={},
                                                 clock=lambda: 1600.0, log=lambda _line: None) is not None

    monkeypatch.setattr(hooks.threading, "Thread", Nested)
    assert hooks.dispatch_usage_hooks(config, (event,), limiter=limiter, environ={},
                                     clock=lambda: 1000.0, log=lambda _line: None) is not None
    assert len(starts) == 2
    assert not limiter.admit(config.rules[0], event, 1600.0)
    assert limiter.admit(config.rules[0], event, 2200.0)


@pytest.mark.parametrize("enabled", [False, True])
def test_disabled_or_fully_throttled_hooks_do_not_construct_a_worker(monkeypatch, enabled):
    config = _config(enabled)
    event = hooks.sample_event("usage_updated", "codex", now=1000.0)
    limiter = hooks.UsageHookLimiter()
    if enabled:
        assert limiter.admit(config.rules[0], event, 1000.0)

    def forbidden(**_kwargs):
        pytest.fail("No hook work means no worker")

    monkeypatch.setattr(hooks.threading, "Thread", forbidden)
    assert hooks.dispatch_usage_hooks(config, (event,), limiter=limiter, environ={},
                                     clock=lambda: 1001.0, log=lambda _line: None) is None


@pytest.mark.parametrize("failure", ["factory", "start"])
def test_provider_apply_continues_after_hook_start_failure(monkeypatch, failure):
    source = Path(production.__file__)
    node = next(item for item in ast.walk(ast.parse(source.read_text()))
                if isinstance(item, ast.FunctionDef) and item.name == "applyProviderUsageState_")
    node.decorator_list = []
    order = []
    results = hooks.UsageHookResults()
    scope = dict(vars(production))
    scope.update({
        "record_state_observations": lambda *_args, **_kwargs: True,
        "reset_delivery_state": lambda _controller: ResetDeliveryState(),
        "note_reset_candidates": lambda *_args: None,
        "dispatch_usage_hooks": lambda config, events, **kwargs: hooks.dispatch_usage_hooks(
            config, events, limiter=hooks.UsageHookLimiter(), results=results, environ={},
            clock=lambda: 1000.0, log=lambda _line: None, **kwargs),
    })
    exec(compile(ast.Module(body=[node], type_ignores=[]), str(source), "exec"), scope)
    previous = ProviderUsageState((snapshot((lane(60.0),)),), 900.0, 1000.0, False)
    current = ProviderUsageState((snapshot((lane(50.0),)),), 1000.0, 1100.0, False)
    controller = SimpleNamespace(
        settings=SimpleNamespace(usage_hooks={"enabled": True, "rules": [{"id": "synthetic", "executable": "/synthetic/hook"}]}),
        _jrbar_provider_usage_edge_baseline=previous, _persistence_writer=None, _runtime_started=True,
        _deliver_pending_reset_events=lambda: order.append("delivery"),
        _alert_new_critical_pace=lambda *_args: order.append("pace"),
        _alert_connection_loss=lambda *_args: order.append("connection"),
        _report_reconnect_outcome=lambda *_args: order.append("reconnect"),
        schedule_event_refresh=lambda: order.append("refresh"),
        _provider_usage_log=lambda _line: None,
    )
    _refuse_worker(monkeypatch, failure)
    scope["applyProviderUsageState_"](controller, ProviderUsageApply(current, ProviderPresentationSettings(())))
    assert order == ["delivery", "pace", "connection", "reconnect", "refresh"]
    assert controller._jrbar_provider_usage_state is current
    assert results.get("synthetic").outcome == "error"
