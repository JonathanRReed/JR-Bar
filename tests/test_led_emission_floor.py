"""The strip must emit a state a person can read, not just carry a bright scalar.

2026-10-07, the owner: "the SidePulse has been green all night even though
there are agents working right now." The firmware drives each channel at
``colour byte * brightness / 255``. The ambient brightness floor (nominal 61,
drive 16) was written assuming full-scale colours; a working roll painted at
the Colors window's 50% ceiling peaks near byte 24, so it reached the die at
about 1.5 drive codes -- below the level where the green die's extra
efficiency stops deciding the hue. Done, Ask and Failed happened to be bright
enough, so working was the one state that read as nothing at all.

Everything here is synthetic: invented sessions, invented colours, a temporary
folder standing in for the device. Nothing sleeps.
"""

from __future__ import annotations

import re
from datetime import datetime, timezone
from pathlib import Path

import pytest

from jrbar.colors import ColorSettings
from jrbar.led_status import (
    STRIP_IDLE_EMISSION_DRIVE,
    STRIP_VISIBLE_EMISSION_DRIVE,
    AgentLedController,
    LedDisplayState,
    emission_floor_for_state,
    emitted_peak_drive,
    finite_cue_duration_ms,
    lift_emission_to_floor,
)
from jrbar.models import AgentMode, AgentStatus

# The ambient visibility floor, as the brightness policy emits it (nominal 61)
# and as the Pro's brightness curve turns it into the firmware's own number.
POLICY_FLOOR_NOMINAL = 61
POLICY_FLOOR_DRIVE = 16

NOON = datetime(2026, 10, 7, 12, 0, 0, tzinfo=timezone.utc)


def _owner_like_colors() -> ColorSettings:
    """A palette shaped like the one that reproduced it: blended identity
    colours, a roll for working, and every fade held to the 50% ceiling."""
    return ColorSettings.from_dict(
        {
            "blend_mode": "color_blend",
            "agent_colors": {"claude": "#D97757", "codex": "#2B8FFF"},
            "mode_animation": {"ask": "blink", "idle": "pulse", "working": "roll"},
            "fade_floor": {"ask": 0.01, "idle": 0.01, "working": 0.01},
            "fade_ceiling": {"ask": 0.5, "idle": 0.5, "working": 0.5},
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


def _written(tmp_path: Path, statuses, *, brightness: int = POLICY_FLOOR_NOMINAL,
             colors: ColorSettings | None = None) -> str:
    """What lands in LEDS.LED for these statuses, through the real controller."""
    device = tmp_path / "SidePulsePro"
    device.mkdir(exist_ok=True)
    controller = AgentLedController(device_path=device, brightness=brightness)
    write = controller.sync_snapshot(tuple(statuses), colors or _owner_like_colors())
    assert write.error is None
    return (device / "LEDS.LED").read_text()


def _emitted_here(program: str) -> float:
    """The same arithmetic as the firmware, written out so the reproduction
    does not depend on the helper under test."""
    level = 255
    for match in re.finditer(r"(?im)^brightness[ \t]+(\d+)[ \t]*$", program):
        level = int(match.group(1))
    peak = 0
    for match in re.finditer(r"#([0-9A-Fa-f]{6})", program):
        digits = match.group(1)
        peak = max(peak, *(int(digits[i : i + 2], 16) for i in (0, 2, 4)))
    return peak * level / 255.0


# --- the reproduction ----------------------------------------------------------------


def test_two_working_sessions_at_the_floor_reach_the_die__and_idle_does_not_glow_green(
    tmp_path: Path,
) -> None:
    # --- scenario: two_working_sessions_reach_the_die
    working = _written(
        tmp_path,
        [
            _status("claude", "claude:session:a", AgentMode.WORKING),
            _status("codex", "codex:session:b", AgentMode.WORKING),
        ],
    )
    assert "brightness" in working
    assert _emitted_here(working) >= STRIP_VISIBLE_EMISSION_DRIVE, working

    # --- scenario: finished_workers_do_not_dim_a_live_main_session
    with_workers = _written(
        tmp_path,
        [
            _status("claude", "claude:session:a", AgentMode.WORKING),
            _status("codex", "codex:session:b", AgentMode.WORKING),
            _status("codex", "codex:agent:w1", AgentMode.COMPLETED),
            _status("codex", "codex:agent:w2", AgentMode.COMPLETED),
        ],
    )
    assert _emitted_here(with_workers) >= STRIP_VISIBLE_EMISSION_DRIVE
    assert finite_cue_duration_ms(with_workers) is None, "working keeps moving"

    # --- scenario: idle_is_a_whisper_that_still_holds_a_hue
    idle = _written(tmp_path, [_status("claude", "claude:session:a", AgentMode.IDLE_READY)])
    assert _emitted_here(idle) >= STRIP_IDLE_EMISSION_DRIVE, idle
    assert _emitted_here(idle) < STRIP_VISIBLE_EMISSION_DRIVE, "idle stays quieter than any signal"


@pytest.mark.parametrize(
    "mode",
    [
        AgentMode.WORKING,
        AgentMode.TOOL_RUNNING,
        AgentMode.WAITING_FOR_INPUT,
        AgentMode.COMPLETED,
        AgentMode.BLOCKED_ERROR,
    ],
)
@pytest.mark.parametrize("provider", ["claude", "codex"])
def test_every_signal_state_is_readable_at_the_dimmest_the_policy_allows(
    tmp_path: Path, mode: AgentMode, provider: str
) -> None:
    program = _written(tmp_path, [_status(provider, f"{provider}:session:a", mode)])
    assert _emitted_here(program) >= STRIP_VISIBLE_EMISSION_DRIVE, (mode, program)


def test_working_and_done_stay_different_lights_when_dimmed(tmp_path: Path) -> None:
    """At the floor the two used to differ only by nine drive codes of
    brightness; the dim one was indistinguishable from idle. Held to the same
    floor they differ by what they are: working moves forever, done is a
    finite cue that settles."""
    # Calm holds both states; this checks the animated mix's emission floor.
    animated = _owner_like_colors().with_blend_mode("round_robin")
    working = _written(tmp_path, [_status("codex", "codex:session:a", AgentMode.WORKING)], colors=animated)
    done = _written(tmp_path, [_status("codex", "codex:session:a", AgentMode.COMPLETED)], colors=animated)
    assert _emitted_here(working) >= STRIP_VISIBLE_EMISSION_DRIVE
    assert _emitted_here(done) >= STRIP_VISIBLE_EMISSION_DRIVE
    assert finite_cue_duration_ms(working) is None
    assert finite_cue_duration_ms(done) is not None
    assert working != done


@pytest.mark.parametrize("nominal", [12, 30, 61, 90, 140, 255])
def test_the_floor_holds_across_the_brightness_policy_range(
    tmp_path: Path, nominal: int
) -> None:
    program = _written(
        tmp_path,
        [_status("claude", "claude:session:a", AgentMode.WORKING)],
        brightness=nominal,
    )
    assert _emitted_here(program) >= STRIP_VISIBLE_EMISSION_DRIVE or "brightness" not in program


def test_explicit_zero_still_switches_the_strip_off(tmp_path: Path) -> None:
    """Idle auto-off, Do Not Disturb dark and a zeroed master dial all ask
    for brightness 0. The floor never argues with an explicit off."""
    program = _written(
        tmp_path,
        [_status("claude", "claude:session:a", AgentMode.WORKING)],
        brightness=0,
    )
    assert re.search(r"(?m)^brightness 0$", program)
    assert emitted_peak_drive(program) == 0.0


# --- the helpers ---------------------------------------------------------------------


def test_lift_changes_only_the_scalar_and_keeps_every_colour_ratio() -> None:
    program = "brightness 16\n#0D0E18 #08090E 250ms cosine\nroll-right 2s linear\nrepeat"
    lifted = lift_emission_to_floor(program, 12)
    assert re.findall(r"#[0-9A-F]{6}", lifted) == re.findall(r"#[0-9A-F]{6}", program)
    assert lifted.splitlines()[1:] == program.splitlines()[1:]
    assert emitted_peak_drive(lifted) >= 12
    # The smallest scalar that does the job: one step lower would fall short.
    level = int(lifted.splitlines()[0].split()[1])
    assert 0x18 * (level - 1) / 255.0 < 12


def test_lift_leaves_alone_what_it_must() -> None:
    assert lift_emission_to_floor("brightness 0\n#102030", 12) == "brightness 0\n#102030"
    assert lift_emission_to_floor("#102030 1s\nrepeat", 12) == "#102030 1s\nrepeat"
    assert lift_emission_to_floor("brightness 20\noff", 12) == "brightness 20\noff"
    bright = "brightness 200\n#FF0000 1s"
    assert lift_emission_to_floor(bright, 12) == bright
    once = lift_emission_to_floor("brightness 5\n#303030 1s", 12)
    assert lift_emission_to_floor(once, 12) == once


def test_lift_never_exceeds_full_scale_and_obeys_the_last_brightness_line() -> None:
    assert lift_emission_to_floor("brightness 3\n#020202 1s", 12).startswith("brightness 255")
    twice = "brightness 200\n#101010 1s\nbrightness 4\n#101010 1s"
    lifted = lift_emission_to_floor(twice, 12)
    assert lifted.splitlines()[0] == "brightness 200"
    assert int(lifted.splitlines()[2].split()[1]) > 4


def test_only_the_states_a_person_reads_have_a_floor() -> None:
    for state in (
        LedDisplayState.WORKING,
        LedDisplayState.ASK,
        LedDisplayState.DONE,
        LedDisplayState.FAILED,
    ):
        assert emission_floor_for_state(state) == STRIP_VISIBLE_EMISSION_DRIVE
    assert emission_floor_for_state(LedDisplayState.IDLE) == STRIP_IDLE_EMISSION_DRIVE
    assert emission_floor_for_state(None) is None
    assert STRIP_IDLE_EMISSION_DRIVE < STRIP_VISIBLE_EMISSION_DRIVE


def test_a_linked_dot_keeps_the_ratio_the_person_chose(tmp_path: Path) -> None:
    device = tmp_path / "SidePulseDot"
    device.mkdir()
    controller = AgentLedController(device_path=device)
    program = "brightness 5\n#C07030 1s\nrepeat"
    controller.sync_program(program, LedDisplayState.WORKING, hold_visible=False)
    assert (device / "LEDS.LED").read_text().startswith("brightness 4")
    other = tmp_path / "SidePulsePro"
    other.mkdir()
    strip = AgentLedController(device_path=other)
    strip.sync_program(program, LedDisplayState.WORKING)
    assert _emitted_here((other / "LEDS.LED").read_text()) >= STRIP_VISIBLE_EMISSION_DRIVE


def test_the_strip_bytes_do_not_flap_between_refreshes(tmp_path: Path) -> None:
    """The lift is a pure function of the program, so the deduper still sees
    one identity and a refresh does not rewrite the device."""
    device = tmp_path / "SidePulsePro"
    device.mkdir()
    controller = AgentLedController(device_path=device, brightness=POLICY_FLOOR_NOMINAL)
    statuses = (
        _status("claude", "claude:session:a", AgentMode.WORKING),
        _status("codex", "codex:session:b", AgentMode.WORKING),
    )
    first = controller.sync_snapshot(statuses, _owner_like_colors())
    second = controller.sync_snapshot(statuses, _owner_like_colors())
    assert first.changed
    assert not second.changed
