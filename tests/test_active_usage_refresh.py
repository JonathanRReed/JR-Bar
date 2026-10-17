"""Usage cadence follows fresh main-session work without bypassing provider rests."""

import ast
from dataclasses import replace
from pathlib import Path
from types import SimpleNamespace

import pytest

from jrbar import adaptive_refresh, provider_usage_runtime
from jrbar.models import AgentMode
from jrbar.provider_feature_settings import project_presentation_settings
from jrbar.provider_reconnect import FailureGate
from jrbar.provider_usage_parsers import parse_codex_usage
from jrbar.provider_usage_runtime import ProviderUsageApply, ProviderUsageService, ProviderUsageState
from jrbar.provider_usage_settings import default_provider_usage_settings


class Timer:
    def __init__(self, delay, callback):
        self.delay, self.callback = delay, callback
        self.cancelled = False

    def start(self):
        pass

    def cancel(self):
        self.cancelled = True


def fixture(tmp_path, monkeypatch, *, reset=5000):
    monkeypatch.setattr(provider_usage_runtime, "_machine_is_constrained", lambda: False)
    settings = default_provider_usage_settings()
    settings = replace(settings, providers=tuple(
        replace(preference, enabled=preference.provider_id == "codex") for preference in settings.providers
    ))
    clock, asked, timers = [1000.0], [], []

    def collector(_preference, _home, observed, _credentials):
        asked.append(observed)
        return parse_codex_usage(windows=[{"id": "five-hour", "label": "5h", "remaining_percent": 60,
                                           "resets_at": reset}], observed_at=observed)

    def timer_factory(delay, callback):
        timer = Timer(delay, callback)
        timers.append(timer)
        return timer

    service = ProviderUsageService(settings_loader=lambda: settings, collectors={"codex": collector},
                                   credentials=object(), home=tmp_path, clock=lambda: clock[0],
                                   timer_factory=timer_factory, incident_lookup=lambda *_a: None)
    service.refresh_now()
    return service, clock, asked, timers, settings


def test_active_main_work_replaces_the_idle_cadence_then_returns_to_idle(tmp_path, monkeypatch):
    service, clock, asked, _timers, _settings = fixture(tmp_path, monkeypatch)
    try:
        assert service.snapshot().next_refresh_at == 2800
        service.note_active_work(True)
        assert service.snapshot().next_refresh_at == 1120
        assert service.cadence_plan().reason is adaptive_refresh.AdaptiveRefreshReason.ACTIVE_WORK
        clock[0] = 1010
        service.note_active_work(True)
        assert service.snapshot().next_refresh_at == 1120
        service.note_active_work(False)
        assert service.snapshot().next_refresh_at == 1120, "ending work cannot postpone an accepted read"
        clock[0] = 1120
        service.refresh_now()
        assert service.snapshot().next_refresh_at == 2920
        assert asked == [1000, 1120]
    finally:
        service.close()


def test_active_work_cannot_postpone_a_known_reset(tmp_path, monkeypatch):
    service, clock, _asked, timers, _settings = fixture(tmp_path, monkeypatch, reset=1050)
    try:
        service.request(callback=lambda *_a: None)
        assert service.snapshot().next_refresh_at == 1050
        service.note_active_work(True)
        assert service.snapshot().next_refresh_at == 1050
        assert timers[-1].delay == 50
        clock[0] = 1020
        service.note_active_work(True)
        assert service.snapshot().next_refresh_at == 1050
    finally:
        service.close()


def test_active_cadence_does_not_retry_a_provider_during_429_rest(tmp_path, monkeypatch):
    service, clock, asked, _timers, _settings = fixture(tmp_path, monkeypatch)
    gate = FailureGate(strikes=2, retry_at=1500)
    service._failure_gates[("codex", "default")] = gate
    try:
        service.note_active_work(True)
        clock[0] = 1120
        service.refresh_now()
        assert asked == [1000]
        assert service._failure_gates[("codex", "default")] == gate
    finally:
        service.close()


def test_activity_transition_cannot_be_overwritten_by_an_in_flight_idle_plan(tmp_path, monkeypatch):
    service, _clock, _asked, _timers, _settings = fixture(tmp_path, monkeypatch)
    original = provider_usage_runtime.plan_adaptive_refresh_cadence
    changed = []

    def planning(*args, **kwargs):
        result = original(*args, **kwargs)
        if not changed and not kwargs.get("active_work", False):
            changed.append(True)
            service.note_active_work(True)
        return result

    monkeypatch.setattr(provider_usage_runtime, "plan_adaptive_refresh_cadence", planning)
    try:
        service.refresh_now()
        assert service.snapshot().next_refresh_at == 1120
        assert service.cadence_plan().reason is adaptive_refresh.AdaptiveRefreshReason.ACTIVE_WORK
    finally:
        service.close()


def controller_methods():
    path = Path(__file__).resolve().parents[1] / "src/jrbar/provider_usage_status_bar.py"
    wanted = {"refresh_", "_note_provider_usage_activity", "_request_provider_usage", "_provider_usage_ready"}
    functions = []
    for node in ast.walk(ast.parse(path.read_text())):
        if isinstance(node, ast.FunctionDef) and node.name in wanted:
            node.decorator_list = []
            functions.append(node)
    return compile(ast.Module(body=functions, type_ignores=[]), str(path), "exec")


def test_controller_feeds_current_activity_and_dispatches_fresh_usage_to_main(tmp_path, monkeypatch):
    service, _clock, _asked, _timers, settings = fixture(tmp_path, monkeypatch)
    order = []

    class Base:
        def refresh_(self, _sender):
            order.append("base")
            self.last_snapshot = SimpleNamespace(statuses=(SimpleNamespace(
                mode=AgentMode.WORKING, is_subagent=False, stale=False),))

    scope = {
        "_BaseStatusBarController": Base, "_legacy": SimpleNamespace(AgentMode=AgentMode),
        "time": SimpleNamespace(monotonic=lambda: 10), "ProviderUsageState": ProviderUsageState,
        "ProviderUsageApply": ProviderUsageApply, "project_presentation_settings": project_presentation_settings,
        "refresh_cached_merged_sync": lambda state: order.append("cache"),
    }
    exec(controller_methods(), scope)

    class Controller:
        last_snapshot = SimpleNamespace(statuses=())

        def _provider_usage_service(self):
            return service

        def _deliver_pending_reset_events(self):
            pass

        def performSelectorOnMainThread_withObject_waitUntilDone_(self, selector, payload, wait):
            order.append((selector, payload, wait))

    for name in ("refresh_", "_note_provider_usage_activity", "_request_provider_usage", "_provider_usage_ready"):
        setattr(Controller, name, scope[name])
    controller = Controller()
    try:
        controller.refresh_(None)
        assert controller._jrbar_provider_usage_state.next_refresh_at == 1120
        controller._provider_usage_ready(service.snapshot())
        assert order[-2] == "cache"
        selector, payload, wait = order[-1]
        assert selector == "applyProviderUsageState:" and wait is False
        assert payload.state.next_refresh_at == 1120 and payload.usage_settings == settings
    finally:
        service.close()


@pytest.mark.parametrize("subagent,stale", [(True, False), (False, True)])
def test_workers_and_stale_sessions_do_not_hold_the_fast_cadence(subagent, stale):
    seen = []
    scope = {"_legacy": SimpleNamespace(AgentMode=AgentMode), "ProviderUsageState": ProviderUsageState}
    exec(controller_methods(), scope)
    controller = SimpleNamespace(last_snapshot=SimpleNamespace(statuses=(SimpleNamespace(
        mode=AgentMode.WORKING, is_subagent=subagent, stale=stale),)))
    service = SimpleNamespace(note_active_work=seen.append, snapshot=lambda: None)
    scope["_note_provider_usage_activity"](controller, service)
    assert seen == [False]


def test_active_policy_retains_constrained_and_reset_confirmation_rules():
    plan = adaptive_refresh.plan_adaptive_refresh_cadence((), observed_at=1000, active_work=True, constrained=True)
    assert plan.interval_seconds == 1800
    confirming = adaptive_refresh.plan_adaptive_refresh_cadence((), observed_at=1000, active_work=True,
                                                               constrained=True, reset_confirm_until=1100)
    assert confirming.interval_seconds == 120
