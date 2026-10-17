"""Calendar glow deadlines survive delivery delay without extending the event."""

from dataclasses import replace
from datetime import datetime, timedelta, timezone
from types import SimpleNamespace

import pytest

from jrbar import status_bar
from tests.test_core_runtime import headless  # noqa: F401
from tests.test_jrbar import _PresentationTimerFactory


@pytest.mark.parametrize("delay", [0.0, 20.0, 30.0, 40.0])
@pytest.mark.parametrize("previous_glow", [0.0, 950.0])
def test_calendar_glow_ends_at_event_start_after_delayed_delivery(
    scheduled_calendar, monkeypatch, delay, previous_glow,
):
    state = scheduled_calendar
    clock = state.clock
    event_start = clock[0] + 30.0
    wall_now = datetime(2027, 1, 1, tzinfo=timezone.utc)
    controller = state.controller
    controller.calendar_glow_until = previous_glow
    monkeypatch.setattr(controller, "refresh_", lambda _sender: None)
    monkeypatch.setattr(status_bar, "datetime", SimpleNamespace(now=lambda _zone: wall_now))
    monkeypatch.setattr(
        status_bar.calendar_watch, "next_event_start",
        lambda _lead: ("Synthetic event", wall_now + timedelta(seconds=30.0)),
    )
    command = status_bar.RuntimeWorkCommand(
        status_bar.RuntimeWorkerDomain.OS_POLL,
        "calendar-observation",
        controller._os_poll_generation,
        clock[0] + 90.0,
        status_bar.CalendarObservationRequest(lead_minutes=5.0),
    )
    result = controller._execute_os_poll_command(command)
    assert result.available
    assert "Synthetic event" not in repr(result)

    clock[0] += delay
    assert clock[0] < command.deadline
    controller._apply_os_poll_result(command, result)

    expected = event_start if clock[0] < event_start else 0.0
    assert controller.calendar_glow_until == expected
    assert controller.calendar_event_title is None


@pytest.fixture
def scheduled_calendar(headless, monkeypatch, request):  # noqa: F811
    clock = [getattr(request, "param", 650.0)]
    controller = headless
    controller.settings = controller.settings.with_calendar_alerts_enabled(True)
    controller._runtime_started = True
    controller.leds_enabled = False
    controller._presentation_monotonic = lambda: clock[0]
    controller._runtime_worker_monotonic = lambda: clock[0]
    factory = _PresentationTimerFactory()
    controller._runtime_timer_registry = controller._build_presentation_timer_registry(
        timer_factory=factory, monotonic=lambda: clock[0],
    )
    controller._presentation_scheduler_state = status_bar.PresentationSchedulerState()
    controller._presentation_scheduler_inputs = None
    inputs = status_bar.PresentationSchedulerInputs(
        screen_bar_enabled=False, visible=False, display_asleep=False,
        app_terminating=False, animation_active=False,
        next_visual_change_at=None, pointer_interaction_relevant=False,
    )
    refreshes = []
    monkeypatch.setattr(controller, "refresh_", refreshes.append)
    controller.reconcile_presentation_timers(inputs)
    return SimpleNamespace(
        controller=controller, clock=clock, factory=factory, inputs=inputs, refreshes=refreshes,
    )


@pytest.mark.parametrize("delivery", ["timer", "queued_result"])
def test_calendar_event_start_arms_expiry_and_refreshes_without_another_poll(
    scheduled_calendar, monkeypatch, delivery,
):
    state = scheduled_calendar
    controller = state.controller
    wall_now = datetime(2027, 1, 1, tzinfo=timezone.utc)
    monkeypatch.setattr(status_bar, "datetime", SimpleNamespace(now=lambda _zone: wall_now))
    monkeypatch.setattr(
        status_bar.calendar_watch, "next_event_start",
        lambda _lead: ("Synthetic event", wall_now + timedelta(seconds=30.0)),
    )
    command = status_bar.RuntimeWorkCommand(
        status_bar.RuntimeWorkerDomain.OS_POLL, "calendar-observation",
        controller._os_poll_generation, state.clock[0] + 90.0,
        status_bar.CalendarObservationRequest(lead_minutes=5.0),
    )
    result = controller._execute_os_poll_command(command)
    controller._apply_os_poll_result(command, result)
    timers = [timer for timer in state.factory.live
              if timer.feature is status_bar.RuntimeFeature.TEST_SIGNAL_DEADLINE]

    assert len(timers) == 1
    assert timers[0].delay == 30.0
    assert timers[0].interval is None
    assert state.refreshes == [None]
    state.clock[0] += 30.0
    if delivery == "timer":
        controller.runtimeTimerFired_(timers[0])
    else:
        controller._apply_os_poll_result(command, result)

    assert controller.calendar_glow_until == 0.0
    assert state.refreshes == [None, None]
    assert not [timer for timer in state.factory.live
                if timer.feature is status_bar.RuntimeFeature.TEST_SIGNAL_DEADLINE]


@pytest.mark.parametrize("reason", ["setting", "display_asleep", "app_terminating"])
def test_calendar_glow_withdraws_with_its_lifecycle(scheduled_calendar, reason):
    state = scheduled_calendar
    controller = state.controller
    controller.calendar_glow_until = state.clock[0] + 30.0
    controller.reconcile_presentation_timers(state.inputs)
    inputs = state.inputs
    if reason == "setting":
        controller.settings = controller.settings.with_calendar_alerts_enabled(False)
    else:
        inputs = replace(inputs, **{reason: True})

    controller.reconcile_presentation_timers(inputs)

    assert controller.calendar_glow_until == 0.0
    assert not [timer for timer in state.factory.live
                if timer.feature is status_bar.RuntimeFeature.TEST_SIGNAL_DEADLINE]


@pytest.mark.parametrize("scheduled_calendar", [10_000.0, 1_000_000.0], indirect=True)
@pytest.mark.parametrize("seconds_ahead", [30.0, 3601.0])
def test_calendar_long_uptime_preserves_the_event_window(
    scheduled_calendar, monkeypatch, seconds_ahead,
):
    state = scheduled_calendar
    controller = state.controller
    read_at = state.clock[0]
    wall_now = datetime(2027, 1, 1, tzinfo=timezone.utc)
    monkeypatch.setattr(status_bar, "datetime", SimpleNamespace(now=lambda _zone: wall_now))
    monkeypatch.setattr(
        status_bar.calendar_watch, "next_event_start",
        lambda _lead: ("Synthetic event", wall_now + timedelta(seconds=seconds_ahead)),
    )
    command = status_bar.RuntimeWorkCommand(
        status_bar.RuntimeWorkerDomain.OS_POLL, "calendar-observation",
        controller._os_poll_generation, read_at + 90.0,
        status_bar.CalendarObservationRequest(lead_minutes=60.0),
    )

    result = controller._execute_os_poll_command(command)
    state.clock[0] += 20.0
    controller._apply_os_poll_result(command, result)

    if seconds_ahead <= 3600.0:
        assert result.available
        assert controller.calendar_glow_until == read_at + seconds_ahead
    else:
        assert not result.available
        assert controller.calendar_glow_until == 0.0
