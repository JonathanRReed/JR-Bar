"""A finished session lights the strip briefly, and never outranks live work.

The lights' own bound is COMPLETED_GLOW_SECONDS (20 s). The rows, the menu bar
and the unseen-done badge keep the longer COMPLETED_RECENT_SECONDS (120 s).
The glance light's unseen completion lives COMPLETED_UNSEEN_LIFETIME_SECONDS
(15 minutes) at most. 2026-08-20 fixed "the strip is just green all the time" by
settling the aggregate mode; the strip later moved to the attention projection
and the settle was not carried over, so a finished turn painted done for two
minutes again. Time is always passed in; nothing here sleeps.
"""

from __future__ import annotations

from datetime import datetime, timedelta, timezone
from types import SimpleNamespace
from unittest.mock import patch

from jrbar.attention import (
    AttentionProjection,
    LifecycleMode,
    project_attention,
    settle_completed_for_lights,
)
from jrbar.colors import ColorSettings, program_for_projection
from jrbar.led_status import LedDisplayState
from jrbar.models import AgentMode, AgentStatus
from jrbar.operator_state import COMPLETED_GLOW_SECONDS, COMPLETED_RECENT_SECONDS
from jrbar.settings import AgentMonitorSettings

POLICY_FLOOR_NOMINAL = 61
NOON = datetime(2026, 10, 7, 12, 0, 0, tzinfo=timezone.utc)


def _owner_like_colors() -> ColorSettings:
    return ColorSettings.from_dict(
        {
            "blend_mode": "color_blend",
            "agent_colors": {"claude": "#D97757", "codex": "#2B8FFF"},
            "mode_animation": {"ask": "blink", "idle": "pulse", "working": "roll"},
            "done_celebration_enabled": True,
            "done_celebration_style": "ripple",
        }
    )


def _status(
    provider: str,
    agent_id: str,
    mode: AgentMode,
    *,
    when: datetime = NOON,
) -> AgentStatus:
    return AgentStatus(
        provider=provider,
        agent_id=agent_id,
        display_name=agent_id,
        mode=mode,
        updated_at=when,
        event_name="Stop" if mode is AgentMode.COMPLETED else "PostToolUse",
        session_id=agent_id.rsplit(":", 1)[-1],
    )


def _projection(statuses, *, collected_at: datetime) -> AttentionProjection:
    snapshot = SimpleNamespace(statuses=tuple(statuses), collected_at=collected_at)
    return project_attention(snapshot, AgentMonitorSettings())


def test_the_lights_settle_a_completion_after_the_glow__and_the_bound_is_stated() -> None:
    """The bound: a finished session paints the strip for at most
    COMPLETED_GLOW_SECONDS (20 s) plus one refresh tick; the rows, the menu
    bar and the unseen-done badge keep COMPLETED_RECENT_SECONDS (120 s)."""
    assert COMPLETED_GLOW_SECONDS == 20.0
    assert COMPLETED_GLOW_SECONDS < COMPLETED_RECENT_SECONDS

    finished = _status("claude", "claude:session:done", AgentMode.COMPLETED, when=NOON)

    def lights_at(seconds: float) -> AttentionProjection:
        now = NOON + timedelta(seconds=seconds)
        return settle_completed_for_lights(_projection([finished], collected_at=now), now=now)

    just_after = lights_at(COMPLETED_GLOW_SECONDS - 1.0)
    assert just_after.lifecycle_mode is LifecycleMode.COMPLETED_RECENTLY
    settled = lights_at(COMPLETED_GLOW_SECONDS + 1.0)
    assert settled.lifecycle_mode is LifecycleMode.IDLE
    assert [row.lifecycle_mode for row in settled.visible_rows] == [LifecycleMode.IDLE]
    # Overnight is the same answer.
    assert lights_at(9 * 3600.0).lifecycle_mode is LifecycleMode.IDLE

    # The settled projection paints the idle whisper, not the done light.
    colors = _owner_like_colors()
    state_fresh, _ = program_for_projection(just_after, colors=colors, brightness=POLICY_FLOOR_NOMINAL)
    state_settled, _ = program_for_projection(settled, colors=colors, brightness=POLICY_FLOOR_NOMINAL)
    assert state_fresh is LedDisplayState.DONE
    assert state_settled is LedDisplayState.IDLE

    # The menu's own projection still remembers the completion.
    at_rest = NOON + timedelta(seconds=COMPLETED_GLOW_SECONDS + 1.0)
    remembered = _projection([finished], collected_at=at_rest)
    assert remembered.lifecycle_mode is LifecycleMode.COMPLETED_RECENTLY


def test_a_stale_done_never_outranks_a_live_working_session() -> None:
    old = _status("claude", "claude:session:old", AgentMode.COMPLETED, when=NOON)
    # Checked inside the glow (the finished session is still "done") and
    # eight hours on (it is long past it): the live pair wins either way.
    for moment in (
        NOON + timedelta(seconds=COMPLETED_GLOW_SECONDS - 5.0),
        NOON + timedelta(hours=8),
    ):
        live = [
            _status("codex", "codex:session:run", AgentMode.WORKING, when=moment),
            _status("claude", "claude:session:main", AgentMode.WORKING, when=moment),
        ]
        projection = settle_completed_for_lights(
            _projection([old, *live], collected_at=moment), now=moment
        )
        modes = {row.agent_id: row.lifecycle_mode for row in projection.visible_rows}
        assert modes["codex:session:run"] is LifecycleMode.ACTIVE
        assert modes["claude:session:main"] is LifecycleMode.ACTIVE
        assert projection.lifecycle_mode is LifecycleMode.ACTIVE
        state, _ = program_for_projection(
            projection, colors=_owner_like_colors(), brightness=POLICY_FLOOR_NOMINAL
        )
        assert state is LedDisplayState.WORKING


def test_finished_workers_never_hold_the_strip_green_under_live_mains() -> None:
    moment = NOON + timedelta(seconds=COMPLETED_GLOW_SECONDS + 5.0)
    statuses = [
        _status("codex", "codex:session:run", AgentMode.WORKING, when=moment),
        _status("codex", "codex:agent:w1", AgentMode.COMPLETED, when=NOON),
        _status("codex", "codex:agent:w2", AgentMode.COMPLETED, when=NOON),
    ]
    projection = settle_completed_for_lights(
        _projection(statuses, collected_at=moment), now=moment
    )
    assert [row.agent_id for row in projection.visible_rows] == ["codex:session:run"]
    assert projection.lifecycle_mode is LifecycleMode.ACTIVE


def test_settling_leaves_waiting_and_failed_alone() -> None:
    waiting = _status("claude", "claude:session:ask", AgentMode.WAITING_FOR_INPUT, when=NOON)
    later = NOON + timedelta(seconds=COMPLETED_GLOW_SECONDS + 30.0)
    projection = _projection([waiting], collected_at=later)
    assert settle_completed_for_lights(projection, now=later) is projection


def test_the_settle_ignores_anything_that_is_not_a_projection() -> None:
    sentinel = SimpleNamespace(lifecycle_mode=None)
    assert settle_completed_for_lights(sentinel, now=NOON) is sentinel


def test_the_unseen_completion_glance_expires_and_goes_dark() -> None:
    """The other long-lived Done: glance's completed-unseen light. Fifteen
    minutes, then dark, and an acknowledged or seen one is dark at once."""
    from jrbar.glance_light import (
        COMPLETED_UNSEEN_LIFETIME_SECONDS,
        GlanceKind,
        GlanceLightState,
        acknowledge_glance_notification,
        make_glance_notification,
        plan_glance_light,
    )

    created = 1_800_000_000.0
    notification = make_glance_notification(
        notification_id="glance.completion.synthetic0001",
        kind=GlanceKind.COMPLETED_UNSEEN,
        created_at_epoch=created,
    )
    state = GlanceLightState((notification,))
    assert COMPLETED_UNSEEN_LIFETIME_SECONDS == 900.0
    lit = plan_glance_light(state, now_epoch=created + COMPLETED_UNSEEN_LIFETIME_SECONDS - 1.0)
    assert lit.notification_count == 1
    dark = plan_glance_light(state, now_epoch=created + COMPLETED_UNSEEN_LIFETIME_SECONDS + 1.0)
    assert dark.notification_count == 0
    acknowledged = acknowledge_glance_notification(
        state,
        notification_id=notification.notification_id,
        acknowledged_at_epoch=created + 5.0,
    )
    assert plan_glance_light(acknowledged, now_epoch=created + 6.0).notification_count == 0


# --- the controller's own lights clock -------------------------------------------------


def test_sync_leds_hands_the_hardware_a_settled_projection() -> None:
    import unittest

    from test_jrbar import isolate_controller

    class _Case(unittest.TestCase):
        def runTest(self) -> None:  # pragma: no cover - harness only
            pass

    case = _Case()
    isolate_controller(case)
    try:
        controller = case.controller
        finished = _status("claude", "claude:session:done", AgentMode.COMPLETED, when=NOON)
        projection = _projection(
            [finished], collected_at=NOON + timedelta(seconds=COMPLETED_GLOW_SECONDS - 1.0)
        )
        assert projection.lifecycle_mode is LifecycleMode.COMPLETED_RECENTLY
        seen: list[LifecycleMode] = []
        controller.leds_enabled = True
        controller._hardware_write_active = True
        clock = {"now": NOON + timedelta(seconds=COMPLETED_GLOW_SECONDS - 1.0)}
        with (
            patch.object(controller, "_lights_now", side_effect=lambda: clock["now"]),
            patch.object(controller, "status_bar_devices", return_value=[]),
            patch.object(
                controller,
                "sync_virtual_status_device",
                side_effect=lambda *a, projection=None, **k: seen.append(projection.lifecycle_mode),
            ),
        ):
            controller.sync_leds(
                AgentMode.COMPLETED,
                None,
                "agent",
                (finished,),
                projection=projection,
                resolved_glance=controller.resolve_presentation_glance(
                    projection, operator_events=(), capacity=None, presentation_time=1.0
                ),
            )
            clock["now"] = NOON + timedelta(seconds=COMPLETED_GLOW_SECONDS + 1.0)
            controller.sync_leds(
                AgentMode.COMPLETED,
                None,
                "agent",
                (finished,),
                projection=projection,
                resolved_glance=controller.resolve_presentation_glance(
                    projection, operator_events=(), capacity=None, presentation_time=2.0
                ),
            )
        assert seen == [LifecycleMode.COMPLETED_RECENTLY, LifecycleMode.IDLE]
    finally:
        case.doCleanups()
