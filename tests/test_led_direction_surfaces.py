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
from jrbar.dot_role import plan_dot_surface
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
    assert "roll-right" in plan_dot_surface(role="extend", strip_program=forward, strip_led_count=8).program

    # A forward Pro: the Dot extends what it wrote.
    _pro_reversed(controller, "forward")
    controller._core_linked_pro_program = (forward, None)
    expected = controller._core_dot_plan(SimpleNamespace(brightness=255)).program
    assert "roll-right" in expected

    # A reversed Pro wrote the mirror, which is what the Dot is handed; the
    # Dot still plays the light the way it runs on the desk.
    _pro_reversed(controller)
    controller._core_linked_pro_program = (
        oriented_program(forward, led_count=8, direction="reversed"),
        None,
    )
    plan = controller._core_dot_plan(SimpleNamespace(brightness=255))
    assert plan.program == expected
    assert "roll-left" not in plan.program


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
