"""Scheduled reads use fake timers and provider fixtures only."""
import threading
from dataclasses import replace

import pytest

from jrbar.provider_reconnect import FailureGate
from jrbar.provider_usage_platform import ProviderSourceState
from jrbar.provider_usage_runtime import ProviderUsageService
from jrbar.provider_usage_settings import default_provider_usage_settings
from tests.test_provider_usage_runtime import snapshot


class Timer:
    def __init__(self, delay, callback):
        self.delay = delay
        self.callback = callback
        self.cancelled = False

    def start(self):
        pass

    def cancel(self):
        self.cancelled = True


def service_fixture(tmp_path):
    clock = [1000.0]
    timers = []
    calls = []
    settings = default_provider_usage_settings()

    def timer_factory(delay, callback):
        timer = Timer(delay, callback)
        timers.append(timer)
        return timer

    def collect(_preference, _home, now, _credentials):
        calls.append(now)
        reading = snapshot("codex", observed=now)
        return replace(reading, lanes=tuple(replace(lane, reset_at=1050.0) for lane in reading.lanes))

    service = ProviderUsageService(
        settings_loader=lambda: settings, credentials=object(), home=tmp_path,
        collectors={"codex": collect}, clock=lambda: clock[0], timer_factory=timer_factory,
    )
    return service, clock, timers, calls, settings


def test_due_timer_targets_reset_and_cancelled_timer_cannot_refresh(tmp_path):
    service, clock, timers, calls, settings = service_fixture(tmp_path)
    service.refresh_now(providers=("codex",))
    starts = []
    service._start_worker_locked = lambda **kwargs: starts.append(kwargs)
    service.request(callback=lambda _state: None)
    assert timers[-1].delay == 50.0
    assert service.snapshot().next_refresh_at == 1050.0
    old = timers[-1]
    service.note_menu_opened()
    assert old.cancelled
    clock[0] = 1050.0
    old.callback()
    assert not starts
    timers[-1].callback()
    assert starts[0]["providers"] == (("codex", "default"),)
    assert starts[0]["force"] is False
    service.note_settings_updated(settings)
    service.close()
    assert calls == [1000.0]


def test_known_reset_bypasses_transient_gate_once(tmp_path):
    service, clock, _timers, calls, _settings = service_fixture(tmp_path)
    service.refresh_now(providers=("codex",))
    service._state = replace(service._state, snapshots=tuple(
        replace(reading, state=ProviderSourceState.STALE, reason_code="network_unavailable")
        if reading.provider_id == "codex" else reading
        for reading in service._state.snapshots
    ))
    service._failure_gates[("codex", "default")] = FailureGate(retry_at=1400.0, strikes=1)
    clock[0] = 1050.0
    service.refresh_now(providers=("codex",))
    assert calls == [1000.0, 1050.0]
    service._failure_gates[("codex", "default")] = FailureGate(retry_at=1400.0, strikes=1)
    clock[0] = 1060.0
    service.refresh_now(providers=("codex",))
    assert calls == [1000.0, 1050.0]
    service.close()


def test_reset_does_not_bypass_terminal_gate(tmp_path, monkeypatch):
    service, clock, _timers, calls, _settings = service_fixture(tmp_path)
    service.refresh_now(providers=("codex",))
    monkeypatch.setattr("jrbar.provider_usage_runtime.credential_fingerprint", lambda *_args: None)
    service._failure_gates[("codex", "default")] = FailureGate(terminal=True)
    clock[0] = 1050.0
    service.refresh_now(providers=("codex",))
    assert calls == [1000.0]
    service.close()


def test_failed_reset_read_recovers_on_one_short_scheduled_retry(tmp_path):
    service, clock, timers, calls, _settings = service_fixture(tmp_path)
    collect = service._collectors["codex"]

    def fail_boundary(preference, home, now, credentials):
        if now == 1050.0:
            calls.append(now)
            raise TimeoutError("fixture transport failure")
        return collect(preference, home, now, credentials)

    service._collectors["codex"] = fail_boundary
    delivered = threading.Event()
    try:
        service.refresh_now(providers=("codex",))
        service.request(callback=lambda _state: delivered.set())
        clock[0] = 1050.0
        service.refresh_now(providers=("codex",))
        assert calls == [1000.0, 1050.0]
        assert service._failure_gates[("codex", "default")].retry_at == 1350.0
        assert timers[-1].delay == 15.0
        clock[0] = 1065.0
        timers[-1].callback()
        assert delivered.wait(timeout=2.0)
        assert calls == [1000.0, 1050.0, 1065.0]
        assert service.snapshot().by_provider("codex").observed_at == 1065.0
        assert not service._reset_retries
    finally:
        service.close()


def test_failed_reset_recovery_is_bounded_and_does_not_retry_early(tmp_path):
    service, clock, timers, calls, _settings = service_fixture(tmp_path)
    service.refresh_now(providers=("codex",))

    def fail(_preference, _home, now, _credentials):
        calls.append(now)
        raise TimeoutError("fixture transport failure")

    service._collectors["codex"] = fail
    try:
        for moment in (1050.0, 1051.0, 1064.0, 1065.0, 1066.0, 1070.0):
            clock[0] = moment
            service.refresh_now(providers=("codex",))
        assert calls == [1000.0, 1050.0, 1065.0]
        assert not service._reset_retries
        assert service._failure_gates[("codex", "default")].strikes == 2
    finally:
        service.close()


@pytest.mark.parametrize("advances", [True, False])
def test_successful_old_window_gets_one_scheduled_recovery(tmp_path, advances):
    service, clock, timers, calls, _settings = service_fixture(tmp_path)
    collect = service._collectors["codex"]

    def lagging_window(preference, home, now, credentials):
        reading = collect(preference, home, now, credentials)
        if advances and now >= 1065.0:
            return replace(reading, lanes=tuple(
                replace(lane, reset_at=5000.0, remaining_percent=100.0)
                for lane in reading.lanes
            ))
        return reading

    service._collectors["codex"] = lagging_window
    delivered = threading.Event()
    try:
        service.refresh_now(providers=("codex",))
        service.request(callback=lambda _state: delivered.set())
        clock[0] = 1050.0
        service.refresh_now(providers=("codex",))
        assert timers[-1].delay == 15.0
        # A scoped read of another provider cannot spend or postpone recovery.
        clock[0] = 1055.0
        service.refresh_now(providers=("claude",))
        assert service.snapshot().next_refresh_at == 1065.0
        clock[0] = 1065.0
        timers[-1].callback()
        assert delivered.wait(timeout=2.0)
        assert calls == [1000.0, 1050.0, 1065.0]
        reading = service.snapshot().by_provider("codex")
        assert reading.observed_at == 1065.0
        assert reading.lanes[0].reset_at == (5000.0 if advances else 1050.0)
        assert not service._reset_retries
        assert service.snapshot().next_refresh_at > 1080.0
    finally:
        service.close()


@pytest.mark.parametrize("reset_at", [None, 5000.0])
def test_old_window_recovery_cancels_when_boundary_changes(tmp_path, reset_at):
    service, clock, timers, calls, _settings = service_fixture(tmp_path)
    try:
        service.refresh_now(providers=("codex",))
        service.request(callback=lambda _state: None)
        clock[0] = 1050.0
        service.refresh_now(providers=("codex",))
        assert timers[-1].delay == 15.0
        collect = service._collectors["codex"]

        def changed_boundary(preference, home, now, credentials):
            reading = collect(preference, home, now, credentials)
            return replace(reading, lanes=tuple(
                replace(lane, reset_at=reset_at) for lane in reading.lanes
            ))

        service._collectors["codex"] = changed_boundary
        clock[0] = 1055.0
        service.refresh_now(providers=("codex",))
        assert not service._reset_retries
        assert service.snapshot().next_refresh_at > 1065.0
        assert calls == [1000.0, 1050.0, 1055.0]
    finally:
        service.close()


@pytest.mark.parametrize(("reason", "state"), [
    ("rate_limited", ProviderSourceState.RATE_LIMITED),
    ("usage_permission_missing", ProviderSourceState.ERROR),
    ("policy_denied", ProviderSourceState.ERROR),
    ("needs_sign_in", ProviderSourceState.NEEDS_SIGN_IN),
])
def test_failed_reset_read_does_not_shorten_provider_rest(tmp_path, reason, state):
    service, clock, _timers, calls, _settings = service_fixture(tmp_path)
    service.refresh_now(providers=("codex",))

    def unavailable(_preference, _home, now, _credentials):
        calls.append(now)
        return replace(snapshot("codex", state=state, observed=now),
                       reason_code=reason)

    service._collectors["codex"] = unavailable
    try:
        clock[0] = 1050.0
        service.refresh_now(providers=("codex",))
        assert not service._reset_retries
        clock[0] = 1065.0
        service.refresh_now(providers=("codex",))
        assert calls == [1000.0, 1050.0]
        assert service._failure_gates[("codex", "default")].retry_at >= 1350.0
    finally:
        service.close()


def test_close_cancels_due_read(tmp_path):
    service, clock, timers, calls, _settings = service_fixture(tmp_path)
    service.refresh_now(providers=("codex",))
    service.request(callback=lambda _state: None)
    service.close()
    assert timers[-1].cancelled
    clock[0] = 1050.0
    timers[-1].callback()
    assert calls == [1000.0]
    assert service.snapshot().by_provider("codex").state is ProviderSourceState.READY


def test_settings_edit_cancels_pending_read(tmp_path):
    service, clock, timers, calls, settings = service_fixture(tmp_path)
    service.refresh_now(providers=("codex",))
    service.request(callback=lambda _state: None)
    service.note_settings_updated(settings)
    assert timers[-1].cancelled
    clock[0] = 1050.0
    timers[-1].callback()
    assert calls == [1000.0]
    service.close()


@pytest.mark.parametrize("reason", ["rate_limited", "usage_permission_missing", "policy_denied"])
def test_reset_preserves_rate_limit_and_permission_rest(tmp_path, reason):
    service, clock, _timers, calls, _settings = service_fixture(tmp_path)
    service.refresh_now(providers=("codex",))
    service._state = replace(service._state, snapshots=tuple(
        replace(reading, state=ProviderSourceState.STALE, reason_code=reason)
        if reading.provider_id == "codex" else reading
        for reading in service._state.snapshots
    ))
    # The provider's 429 rest outlasts its advertised quota reset.
    service._failure_gates[("codex", "default")] = FailureGate(retry_at=1650.0, strikes=1)
    clock[0] = 1050.0
    service.refresh_now(providers=("codex",))
    assert calls == [1000.0]
    assert service._failure_gates[("codex", "default")].retry_at == 1650.0
    service.close()


def test_due_timer_collects_and_delivers_owner_callback_at_reset(tmp_path):
    service, clock, timers, calls, _settings = service_fixture(tmp_path)
    service.refresh_now(providers=("codex",))
    delivered = threading.Event()
    results = []

    def callback(state):
        results.append(state)
        delivered.set()

    service.request(callback=callback)
    clock[0] = 1050.0
    timers[-1].callback()
    assert delivered.wait(timeout=2.0)
    assert calls == [1000.0, 1050.0]
    assert len(results) == 1
    assert results[0].by_provider("codex").observed_at == 1050.0
    assert timers[-1].delay > 0.0
    service.close()


def test_reset_crossed_during_another_scoped_refresh_is_still_due(tmp_path):
    service, clock, timers, calls, _settings = service_fixture(tmp_path)
    service.refresh_now(providers=("codex",))
    starts = []
    service._start_worker_locked = lambda **kwargs: starts.append(kwargs)
    service.request(callback=lambda _state: None)
    clock[0] = 1051.0
    service.refresh_now(providers=("claude",))
    assert timers[-1].delay == 0.0
    timers[-1].callback()
    assert starts[-1]["providers"] == (("codex", "default"),)
    assert starts[-1]["force"] is False
    assert calls == [1000.0]
    service.close()


def test_unrelated_scoped_reads_do_not_postpone_reset_confirmation(tmp_path):
    service, clock, timers, _, _settings = service_fixture(tmp_path)
    service._collectors["codex"] = lambda _preference, _home, now, _credentials: snapshot("codex", observed=now)
    try:
        service.refresh_now(providers=("codex",))
        service.note_reset_candidates(1180.0)
        assert service.snapshot().next_refresh_at == 1120.0
        service.request(callback=lambda _state: None)
        for moment in (1110.0, 1115.0, 1118.0):
            clock[0] = moment
            service.refresh_now(providers=("claude",))
            assert service.snapshot().next_refresh_at == 1120.0
            assert timers[-1].delay == 1120.0 - moment
        for moment in (1125.0, 1190.0):
            clock[0] = moment
            service.refresh_now(providers=("claude",))
            assert timers[-1].delay == 0.0
        # A full read pays the pending confirmation read and can advance.
        service.refresh_now()
        assert service.snapshot().next_refresh_at > clock[0]
        assert timers[-1].delay > 0.0
    finally:
        service.close()


@pytest.mark.parametrize("scope", [("codex",), (("codex", "default"),)])
def test_reading_the_quota_scope_can_advance_confirmation_schedule(tmp_path, scope):
    service, clock, _, _, _settings = service_fixture(tmp_path)
    service._collectors["codex"] = lambda _preference, _home, now, _credentials: snapshot("codex", observed=now)
    try:
        service.refresh_now(providers=("codex",))
        service.note_reset_candidates(1180.0)
        assert service.snapshot().next_refresh_at == 1120.0
        clock[0] = 1110.0
        service.refresh_now(providers=scope)
        assert service.snapshot().next_refresh_at > 1120.0
    finally:
        service.close()


@pytest.mark.parametrize("reason,terminal", [
    ("rate_limited", False), ("usage_permission_missing", False),
    ("policy_denied", False), ("network_unavailable", True),
])
def test_crossed_reset_does_not_create_a_zero_delay_rest_loop(tmp_path, reason, terminal):
    service, clock, timers, _calls, _settings = service_fixture(tmp_path)
    service.refresh_now(providers=("codex",))
    service.request(callback=lambda _state: None)
    service._state = replace(service._state, snapshots=tuple(
        replace(reading, state=ProviderSourceState.STALE, reason_code=reason)
        if reading.provider_id == "codex" else reading
        for reading in service._state.snapshots
    ))
    service._failure_gates[("codex", "default")] = FailureGate(
        retry_at=1650.0, strikes=1, terminal=terminal)
    clock[0] = 1051.0
    service.refresh_now(providers=("claude",))
    assert timers[-1].delay > 0.0
    service.close()


def test_crossed_reset_is_rearmed_after_a_busy_worker_retires(tmp_path):
    class Busy:
        def is_alive(self):
            return True

    service, clock, timers, _calls, _settings = service_fixture(tmp_path)
    service.refresh_now(providers=("codex",))
    starts = []
    service._start_worker_locked = lambda **kwargs: starts.append(kwargs)
    service.request(callback=lambda _state: None)
    clock[0] = 1051.0
    service.refresh_now(providers=("claude",))
    service._workers.add(Busy())
    timers[-1].callback()
    assert starts == []
    service._workers.clear()
    with service._lock:
        service._schedule_due_locked()
    assert timers[-1].delay == 0.0
    timers[-1].callback()
    assert starts[-1]["providers"] == (("codex", "default"),)
    assert starts[-1]["force"] is False
    service.close()
