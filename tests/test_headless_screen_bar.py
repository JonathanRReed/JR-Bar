"""The daemon's Screen Bar draws nothing and only keeps what the controller needs.

The Swift app draws the Screen Bar. The status-bar controller still pushes
settings at it on every refresh, asks it for the scheduler inputs, and tears
it down at exit, so this pins what that object promises: it remembers the
last program, it is never on screen, nothing can turn it on, and the
presentation timers are told about it the way they always were.
"""

from __future__ import annotations

import importlib.util

import pytest

from jrbar.headless_screen_bar import (
    LED_COUNT,
    VIRTUAL_DEVICE_ID,
    VIRTUAL_DEVICE_NAME,
    HeadlessScreenBar,
)
from jrbar.presentation_scheduler import (
    PresentationSchedulerInputs,
    plan_presentation_schedule,
)


def _watched() -> tuple[HeadlessScreenBar, list[PresentationSchedulerInputs]]:
    bar = HeadlessScreenBar()
    seen: list[PresentationSchedulerInputs] = []
    bar.set_presentation_schedule_reconciler(seen.append)
    seen.clear()
    return bar, seen


def test_the_bar_remembers_the_last_program_it_was_asked_for_and_draws_nothing() -> None:
    bar = HeadlessScreenBar()
    assert bar._live_program_call is None

    assert bar.set_program("#FF0000 500ms\nrepeat", started_at=12.5, motion="continuous") is None

    assert bar._live_program_call == (
        "#FF0000 500ms\nrepeat",
        {"started_at": 12.5, "motion": "continuous"},
    )
    assert bar.window is None

    bar.set_program("off")
    assert bar._live_program_call == ("off", {})


def test_the_remembered_program_is_a_copy_of_what_the_caller_passed() -> None:
    bar = HeadlessScreenBar()
    kwargs = {"started_at": 1.0}
    bar.set_program("prog", **kwargs)
    kwargs["started_at"] = 2.0
    assert bar._live_program_call == ("prog", {"started_at": 1.0})


def test_the_scheduler_inputs_say_the_bar_is_off_screen_and_plan_no_timer() -> None:
    bar = HeadlessScreenBar()
    inputs = bar.presentation_scheduler_inputs()

    assert inputs.screen_bar_enabled is False
    assert inputs.visible is False
    assert inputs.display_asleep is False
    assert inputs.app_terminating is False
    assert inputs.animation_active is False
    assert inputs.next_visual_change_at is None
    assert inputs.alcove_enabled is False
    assert inputs.alcove_relevant is False

    plan = plan_presentation_schedule(inputs, now=100.0)
    assert plan.intents == ()
    assert plan.reconcile_immediately is False


def test_nothing_the_controller_pushes_turns_the_bar_on() -> None:
    bar = HeadlessScreenBar()
    bar.set_wraps_menu_bar(True)
    bar.set_geometry_overrides(12.0, 40.0)
    bar.set_bracket_style("bracket")
    bar.set_min_glow(0.4)
    bar.set_follow_alcove(True)
    bar.set_show_in_full_screen(True)
    bar.set_standing_gauges(0.8, True)
    bar.set_click_handler(lambda: None)
    bar.set_pointer_interaction_relevant(True)
    bar.set_announcer_stack(object(), object(), answer_plan=object(), answer_handler=object())
    assert bar.set_accessibility_display_preferences(object(), generation=3) is False
    bar.redraw_(None)
    bar.presentationStaticDeadline()
    bar.presentationAlcoveObservation()

    inputs = bar.presentation_scheduler_inputs()
    assert inputs.screen_bar_enabled is False
    assert inputs.visible is False
    assert inputs.animation_active is False
    assert bar.window is None
    assert not hasattr(bar, "set_enabled")
    assert not hasattr(bar, "show")


def test_hide_tells_the_timers_the_surface_is_off_screen_every_time() -> None:
    bar, seen = _watched()

    bar.hide()
    bar.hide()

    assert len(seen) == 2
    assert all(item.screen_bar_enabled is False and item.visible is False for item in seen)


def test_terminate_tells_the_timers_once_and_is_idempotent() -> None:
    bar, seen = _watched()

    bar.terminate()
    bar.terminate()

    assert len(seen) == 1
    assert seen[0].app_terminating is True
    assert bar.presentation_scheduler_inputs().app_terminating is True
    # A hide after teardown still reports the app as terminating.
    bar.hide()
    assert seen[-1].app_terminating is True


def test_setting_the_reconciler_publishes_the_inputs_at_once_and_validates_it() -> None:
    bar = HeadlessScreenBar()
    seen: list[PresentationSchedulerInputs] = []

    bar.set_presentation_schedule_reconciler(seen.append)

    assert seen == [bar.presentation_scheduler_inputs()]
    with pytest.raises(ValueError, match="must be callable"):
        bar.set_presentation_schedule_reconciler("not callable")  # type: ignore[arg-type]
    bar.set_presentation_schedule_reconciler(None)
    bar.hide()
    assert len(seen) == 1


def test_the_flags_the_controller_reconciles_after_pushing_still_publish() -> None:
    bar, seen = _watched()

    bar.set_wraps_menu_bar(True)
    bar.set_follow_alcove(True)
    assert len(seen) == 2

    bar.set_pointer_interaction_relevant(False)
    assert len(seen) == 2
    bar.set_pointer_interaction_relevant(True)
    assert len(seen) == 3
    assert seen[-1].pointer_interaction_relevant is True
    bar.set_pointer_interaction_relevant(True)
    assert len(seen) == 3
    # The pointer flag alone never wakes a timer for a bar that is off screen.
    assert plan_presentation_schedule(seen[-1], now=50.0).intents == ()


def test_the_screen_bar_identity_the_controller_and_daemon_share() -> None:
    from jrbar import status_bar_legacy

    assert VIRTUAL_DEVICE_ID == "virtual:status-bar"
    assert VIRTUAL_DEVICE_NAME == "Screen Bar"
    assert LED_COUNT == 8
    assert status_bar_legacy.VIRTUAL_DEVICE_ID == VIRTUAL_DEVICE_ID
    assert status_bar_legacy.LED_COUNT == LED_COUNT


def test_the_python_bars_drawing_modules_are_not_packaged() -> None:
    """The daemon boots the headless bar, so nothing imports these, and a
    module that comes back would be drawing code nothing runs."""
    for retired in (
        "virtual_device",
        "announcer_stack_view",
        "announcer_presenter",
        "native_gradient",
        "notch_silhouette",
        "alcove_window_probe",
        "screen_bar_runtime",
        "screen_bar_design",
        "screen_bar_profile",
    ):
        assert importlib.util.find_spec(f"jrbar.{retired}") is None, retired
