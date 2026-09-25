"""A strip set to ``reversed`` turns round everything drawn for it, and
nothing that follows it turns round with it.

``devices.N.led_direction`` mirrors a strip's own agent light. Two paths
that are not the agent render used to miss that: Effect Studio's Play on
strip sent the program as drawn, so a previewed comet ran the opposite way
from the live one; and a linked Dot narrowed the Pro's mirrored program as
it stood, so flipping the Pro turned the Dot's light round too.
"""

from __future__ import annotations

from dataclasses import replace
from pathlib import Path
from types import SimpleNamespace

from jrbar._settings_legacy import DeviceDisplaySetting
from jrbar.device_clock import DeviceClocks
from jrbar.dot_role import plan_dot_surface
from jrbar.linked_runtime import LinkedEpoch, LinkedSync
from jrbar.motion_shapes import oriented_program, render_motion
from tests.test_core_runtime import headless  # noqa: F401  (the headless daemon fixture)

PRO = "sidepulse:pro:1"
DOT = "sidepulse:dot:1"


def _comet() -> str:
    return "\n".join(
        [*render_motion("comet", "#FF8040", "#030201", led_count=8, cycle_ms=2200), "repeat"]
    )


def _devices(controller):
    from jrbar.status_bar_legacy import StatusBarDevice

    pro = StatusBarDevice(PRO, "SidePulse", Path("/Volumes/SidePulse"), Path("/Volumes/SidePulse/LEDS.LED"), True, "agent")
    dot = StatusBarDevice(DOT, "SidePulse Dot", Path("/Volumes/PulseDot"), Path("/Volumes/PulseDot/LEDS.LED"), True, "agent")
    controller.status_bar_devices = lambda *, remember=True: [pro, dot]
    return pro, dot


def _pro_reversed(controller, direction: str = "reversed"):
    row = DeviceDisplaySetting(PRO, "SidePulse", "/Volumes/SidePulse", led_direction=direction)
    controller.settings = replace(controller.settings, devices=(row,))


def test_a_linked_dot_keeps_desk_order_when_the_pro_is_reversed(headless) -> None:  # noqa: F811
    controller = headless
    _devices(controller)
    controller.settings = controller.settings.with_devices_linked(True).with_dot_role("extend")
    controller._core_linked_pro_leds = 8
    forward = _comet()
    mirrored = oriented_program(forward, led_count=8, direction="reversed")
    # Narrowed as it stands, the mirror is a different light on the Dot:
    # the one it used to play, running the other way.
    assert (
        plan_dot_surface(role="extend", strip_program=mirrored, strip_led_count=8).program
        != plan_dot_surface(role="extend", strip_program=forward, strip_led_count=8).program
    )

    # A forward Pro: the Dot extends what it wrote.
    _pro_reversed(controller, "forward")
    controller._core_linked_pro_program = (forward, None)
    expected = controller._core_dot_plan(SimpleNamespace(brightness=255)).program

    # A reversed Pro wrote the mirror, which is what the Dot is handed; the
    # Dot still plays the light the way it runs on the desk. The strip's
    # recorded start names the strip (every strip write that feeds the Dot
    # records one first), since the plan runs where the device list is not
    # read.
    controller._core_linked = LinkedSync(DeviceClocks(None))
    controller._core_linked.note_epoch(LinkedEpoch(anchor=100.0, anchor_epoch=1.0, device_id=PRO))
    _pro_reversed(controller)
    controller._core_linked_pro_program = (mirrored, None)
    assert controller._core_dot_plan(SimpleNamespace(brightness=255)).program == expected


def test_a_continue_dot_joins_a_reversed_pro_at_the_end_it_sits_by(headless) -> None:  # noqa: F811
    """The Dot is handed the Pro's program in desk order, and Continue then
    reads it as a forward strip. With the sync's recorded start on a
    reversed Pro, the Dot plays exactly what it plays beside a forward one.
    Turning the strip's end round as well (Continue's own geometry for a
    program in the strip's numbers) sent the light out of the far end of
    the desk, so the Dot lit when the comet was nowhere near it."""
    controller = headless
    _devices(controller)
    controller.settings = controller.settings.with_devices_linked(True).with_dot_role("extend")
    assert controller.settings.dot_extend_style == "continue"
    controller._core_linked_pro_leds = 8
    controller._core_linked = LinkedSync(DeviceClocks(None))
    controller._core_linked.note_epoch(LinkedEpoch(anchor=100.0, anchor_epoch=1.0, device_id=PRO))
    forward = _comet()
    mirrored = oriented_program(forward, led_count=8, direction="reversed")

    _pro_reversed(controller, "forward")
    controller._core_linked_pro_program = (forward, None)
    beside_forward = controller._core_dot_plan(SimpleNamespace(brightness=255))
    assert beside_forward is not None and "style:continue" in beside_forward.reasons

    _pro_reversed(controller)
    controller._core_linked_pro_program = (mirrored, None)
    beside_reversed = controller._core_dot_plan(SimpleNamespace(brightness=255))
    assert beside_reversed is not None and "style:continue" in beside_reversed.reasons
    assert beside_reversed.program == beside_forward.program


def test_play_on_strip_turns_round_with_the_strip(headless) -> None:  # noqa: F811
    controller = headless
    controller.applicationDidFinishLaunching_(None)
    _devices(controller)
    written: dict[str, str] = {}

    def controller_for(device):
        def sync_program(program, _state):
            written[device.device_id] = program

        return SimpleNamespace(brightness=255, sync_program=sync_program)

    controller.agent_controller_for_device = controller_for
    program = _comet()

    controller._core_dispatch("preview_program", {"surface": "hardware", "program": program, "seconds": 1})
    assert written[PRO] == program

    _pro_reversed(controller)
    controller._core_previews.clear()
    controller._core_dispatch("preview_program", {"surface": "hardware", "program": program, "seconds": 1})
    assert written[PRO] == oriented_program(program, led_count=8, direction="reversed")
    assert "roll-left" in written[PRO]
    # The Screen Bar ignores the strip's direction: the preview it shows is
    # the program as drawn.
    assert controller._core_previews["hardware"].program == program
