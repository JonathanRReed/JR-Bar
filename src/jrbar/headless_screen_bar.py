"""The Screen Bar, as the daemon sees it.

The Swift app draws the Screen Bar. What the daemon owns is the program the
bar plays, which it computes and publishes on the ``lights`` frame. So this
module holds only what the status-bar controller needs from the surface on
every refresh: a place to push the Screen Bar settings, a record of the
last program asked for, and the scheduler inputs that say the surface is
never on screen, so no presentation timer is kept awake for it.

``HeadlessScreenBar`` owns no window, view, timer, sampler or AppKit object,
and nothing can turn it on. The three identity names below are here because
the controller and the core daemon address the Screen Bar by them.
"""

from __future__ import annotations

import time
from typing import Any

from .presentation_scheduler import PresentationSchedulerInputs

#: The Screen Bar's row in the device list.
VIRTUAL_DEVICE_ID = "virtual:status-bar"
VIRTUAL_DEVICE_NAME = "Screen Bar"
#: LEDs in every Screen Bar program, the same eight the strip has.
LED_COUNT = 8


def monotonic_ms() -> int:
    return int(time.monotonic() * 1000.0)


class HeadlessScreenBar:
    """A Screen Bar that is never drawn here and only remembers its program."""

    #: Nothing is ever on screen. ``peekTick_`` reads this to see whether
    #: there is a window to hit-test.
    window = None

    def __init__(self) -> None:
        self._live_program_call: tuple[str, dict[str, Any]] | None = None
        self._presentation_schedule_reconciler = None
        self._pointer_interaction_relevant = False
        self._terminating = False

    # --- the program ---------------------------------------------------

    def set_program(self, program: str, **kwargs: Any) -> None:
        """Remember the program the bar was last asked to play.

        ``core_runtime`` reads it back as the live call. Nothing is drawn.
        """
        self._live_program_call = (str(program), dict(kwargs))

    # --- lifecycle -----------------------------------------------------

    def hide(self) -> None:
        """There is nothing to hide. The timers are told again that the
        surface is off screen."""
        self._publish_presentation_schedule()

    def terminate(self) -> None:
        """Tell the presentation timers the app is going away, once."""
        if self._terminating:
            return
        self._terminating = True
        self._publish_presentation_schedule()

    # --- presentation timers -------------------------------------------

    def set_presentation_schedule_reconciler(self, reconciler) -> None:
        if reconciler is not None and not callable(reconciler):
            raise ValueError("presentation schedule reconciler must be callable")
        self._presentation_schedule_reconciler = reconciler
        self._publish_presentation_schedule()

    def presentation_scheduler_inputs(self) -> PresentationSchedulerInputs:
        """The bar is never enabled, visible or animating here, so the
        scheduler plans no frame, deadline, Alcove or pointer timer for it,
        whatever the pointer flag says. What changes is that the app is
        terminating."""
        return PresentationSchedulerInputs(
            screen_bar_enabled=False,
            visible=False,
            display_asleep=False,
            app_terminating=self._terminating,
            animation_active=False,
            next_visual_change_at=None,
            alcove_enabled=False,
            alcove_relevant=False,
            pointer_interaction_relevant=self._pointer_interaction_relevant,
        )

    def _publish_presentation_schedule(self) -> None:
        reconcile = self._presentation_schedule_reconciler
        if reconcile is not None:
            reconcile(self.presentation_scheduler_inputs())

    # The controller names these when a presentation timer fires. No timer
    # is planned while the bar is off screen, so they never run.

    def redraw_(self, _sender) -> None:
        return None

    def presentationStaticDeadline(self) -> None:
        return None

    def presentationAlcoveObservation(self) -> None:
        return None

    # --- settings the controller pushes on every refresh ---------------
    # The app reads the same settings from the daemon's documents. Nothing
    # here has a surface to apply them to. The controller has always
    # reconciled its presentation timers right after pushing the wrap,
    # follow-Alcove and pointer flags, so those three still do.

    def set_wraps_menu_bar(self, enabled: bool) -> None:
        self._publish_presentation_schedule()

    def set_follow_alcove(self, enabled: bool) -> None:
        self._publish_presentation_schedule()

    def set_pointer_interaction_relevant(self, relevant: bool) -> None:
        normalized = bool(relevant)
        if normalized == self._pointer_interaction_relevant:
            return
        self._pointer_interaction_relevant = normalized
        self._publish_presentation_schedule()

    def set_geometry_overrides(self, gap_width: float | None, wing_length: float | None) -> None:
        return None

    def set_bracket_style(self, style: str) -> None:
        return None

    def set_min_glow(self, fraction: float) -> None:
        return None

    def set_show_in_full_screen(self, enabled: bool) -> None:
        return None

    def set_standing_gauges(self, left_level: float, right_on: bool) -> None:
        return None

    def set_click_handler(self, handler) -> None:
        return None

    def set_announcer_stack(
        self,
        plan: object,
        intent_handler: object,
        *,
        answer_plan: object = None,
        answer_handler: object = None,
    ) -> None:
        return None

    def set_accessibility_display_preferences(
        self,
        preferences: object,
        *,
        generation: int,
    ) -> bool:
        """Nothing was applied, so it says so."""
        return False
