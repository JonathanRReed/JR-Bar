"""The Colors window's preview repaint never paints a quiet worker as an ask.

``push_colors_preview_to_device`` handed ``sync_leds`` the snapshot's raw
statuses and no projection. The mode it also passed was already gated, but
the strip is drawn from the statuses when there is no projection, so a
waiting sub-agent was painted in the ask colour on every colour change made
with "Preview live on device" on. Every other repaint reads the last
refresh's projection or passes no statuses; so does this one.

Nothing here reaches hardware: ``sync_leds`` is recorded, or the hardware
write stage is replaced by a recorder, and no device path is ever opened.
"""

from __future__ import annotations

import unittest
from dataclasses import replace
from datetime import datetime, timezone
from pathlib import Path
from types import SimpleNamespace

from test_jrbar import isolate_controller

from jrbar.attention import LifecycleMode
from jrbar.collector import aggregate_status
from jrbar.models import AgentMode, AgentStatus
from jrbar.presentation_policy import GlanceSemantic


def _status(agent_id: str, mode: AgentMode, event: str = "PermissionRequest") -> AgentStatus:
    return AgentStatus(
        provider="claude",
        agent_id=agent_id,
        display_name=agent_id,
        mode=mode,
        updated_at=datetime.now(timezone.utc),
        event_name=event,
        session_id="s1",
    )


def _snapshot(*statuses: AgentStatus):
    return SimpleNamespace(
        statuses=tuple(statuses),
        stale_statuses=(),
        aggregate=aggregate_status(tuple(statuses), ()),
        collected_at=datetime.now(timezone.utc),
    )


_WORKER_ASKS = ("claude:agent:w1", AgentMode.WAITING_FOR_INPUT)
_MAIN_WORKS = ("claude:session:s1", AgentMode.WORKING, "PostToolUse")
_MAIN_ASKS = ("claude:session:s1", AgentMode.WAITING_FOR_INPUT)


class ColorsPreviewQuietWorkerTests(unittest.TestCase):
    def setUp(self) -> None:
        isolate_controller(self)

    def _publish(self, snapshot) -> None:
        """A refresh publishes the snapshot and its projection together."""
        self.controller.last_snapshot = snapshot
        self.controller.update_attention_projection(snapshot)
        self.controller.last_battery_snapshot = None

    def _preview_call(self, snapshot):
        """The ``(args, kwargs)`` a Colors preview repaint hands to sync_leds."""
        calls: list = []
        self._publish(snapshot)
        self.controller.sync_leds = lambda *args, **kwargs: calls.append((args, kwargs))
        self.controller.push_colors_preview_to_device()
        self.assertEqual(len(calls), 1)
        return calls[0]

    def test_a_waiting_worker_is_not_handed_to_the_repaint_as_a_status(self) -> None:
        for statuses in ((_WORKER_ASKS,), (_WORKER_ASKS, _MAIN_WORKS)):
            with self.subTest(statuses=len(statuses)):
                snapshot = _snapshot(*(_status(*row) for row in statuses))
                # The raw statuses are the leak: a waiting worker in them
                # reads as an ask to the strip's renderer.
                self.assertTrue(
                    any(status.is_subagent for status in snapshot.statuses)
                )

                args, kwargs = self._preview_call(snapshot)

                self.assertEqual(args[3], (), "no raw statuses reach the repaint")
                projection = kwargs["projection"]
                self.assertIs(projection, self.controller.current_attention_projection)
                self.assertEqual(projection.actionable_attention, ())
                self.assertIsNot(projection.lifecycle_mode, LifecycleMode.WAITING)
                self.assertNotEqual(args[0], AgentMode.WAITING_FOR_INPUT)

    def test_a_main_ask_still_shows_in_the_preview(self) -> None:
        args, kwargs = self._preview_call(_snapshot(_status(*_MAIN_ASKS)))

        self.assertEqual(args[0], AgentMode.WAITING_FOR_INPUT)
        self.assertEqual(args[3], ())
        self.assertIs(kwargs["projection"].lifecycle_mode, LifecycleMode.WAITING)
        self.assertEqual(len(kwargs["projection"].actionable_attention), 1)

    def test_a_worker_ask_shows_in_the_preview_when_the_setting_is_on(self) -> None:
        self.controller.settings = self.controller.settings.with_subagent_asks_alert(True)

        args, kwargs = self._preview_call(_snapshot(_status(*_WORKER_ASKS)))

        self.assertEqual(args[0], AgentMode.WAITING_FOR_INPUT)
        self.assertEqual(len(kwargs["projection"].actionable_attention), 1)

    def test_the_repaint_before_any_refresh_is_an_idle_strip(self) -> None:
        calls: list = []
        self.controller.last_snapshot = None
        self.controller.sync_leds = lambda *args, **kwargs: calls.append((args, kwargs))

        self.controller.push_colors_preview_to_device()

        ((args, kwargs),) = calls
        self.assertEqual(args[0], AgentMode.IDLE_READY)
        self.assertEqual(args[3], ())
        self.assertIsNone(kwargs["projection"])

    def test_what_reaches_the_hardware_write_stage_carries_no_worker_status(self) -> None:
        """Through the real ``sync_leds``: a connected strip is offered a
        request with no raw statuses and the gated projection."""
        from jrbar.status_bar_legacy import StatusBarDevice

        controller = self.controller
        device = StatusBarDevice(
            device_id="sidepulse:pro:serial:test",
            name="Test Pro",
            root=Path("/tmp/nonexistent-test-device"),
            target=Path("/tmp/nonexistent-test-device/LEDS.LED"),
            connected=True,
            display="agent",
        )
        submitted: list = []
        controller.status_bar_devices = lambda remember=False: [device]
        controller.sync_virtual_status_device = lambda *args, **kwargs: None
        controller._submit_hardware_write_requests = (
            lambda requests, _now: submitted.extend(requests)
        )
        controller._hardware_write_active = True
        controller.led_animation_until_monotonic = 0.0
        controller.calibration_test = None
        controller._core_held_preview_devices = lambda: frozenset()

        self._publish(_snapshot(_status(*_WORKER_ASKS), _status(*_MAIN_WORKS)))
        controller.push_colors_preview_to_device()

        self.assertEqual(len(submitted), 1)
        (request,) = submitted
        self.assertEqual(request.statuses, ())
        self.assertIsNot(request.mode, AgentMode.WAITING_FOR_INPUT)
        self.assertEqual(request.projection.actionable_attention, ())
        self.assertIs(request.resolved_glance.semantic, GlanceSemantic.ACTIVE)
        # Nothing was written: the request only ever named a fake path.
        self.assertFalse(Path("/tmp/nonexistent-test-device").exists())


if __name__ == "__main__":
    unittest.main()
