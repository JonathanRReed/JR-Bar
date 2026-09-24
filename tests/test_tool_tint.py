"""The tool tint: the working head shows what kind of tool the agent is using.

An idea from bizantl/sidepulse (luka, ``faace13``): six tool families, each a
colour of its own, on the HEAD of a chase, comet or glint only -- the tail
keeps the provider's colour, so identity survives. It is opt-in, asks and
failures never take it, and because the SidePulse is an emulated FAT volume
that must not be written in a storm, only a change of FAMILY can change the
light, and never more than once every three seconds.
"""

from __future__ import annotations

from datetime import datetime, timezone

import pytest

from jrbar import colors as colors_module
from jrbar import motion_shapes as shapes
from jrbar.accessibility_display import AccessibilityDisplayPreferences
from jrbar.colors import (
    TOOL_TINT_COLORS,
    ColorSettings,
    ToolTintGate,
    tool_family,
    with_tool_tint,
)
from jrbar.models import AgentMode, AgentStatus
from jrbar.presentation_policy import (
    GlanceInputs,
    compose_presentation_program,
    continuous_presentation_identity,
    resolve_glance,
)


@pytest.mark.parametrize(
    ("tool", "family"),
    (
        ("Bash", "shell"),
        ("exec_command", "shell"),
        ("Edit", "edit"),
        ("MultiEdit", "edit"),
        ("Write", "edit"),
        ("apply_patch", "edit"),
        ("Read", "read"),
        ("Grep", "read"),
        ("Glob", "read"),
        ("WebFetch", "web"),
        ("WebSearch", "web"),
        ("mcp__github__create_issue", "web"),
        ("mcp__claude-in-chrome__navigate", "web"),
        ("Task", "task"),
        ("TodoWrite", "plan"),
        ("ExitPlanMode", "plan"),
        ("update_plan", "plan"),
        ("SomethingNew", None),
        ("", None),
        (None, None),
    ),
)
def test_tools_map_to_their_family(tool, family) -> None:
    assert tool_family(tool) == family


def test_six_families_six_colours() -> None:
    assert set(TOOL_TINT_COLORS) == {"shell", "edit", "read", "web", "task", "plan"}
    assert len(set(TOOL_TINT_COLORS.values())) == 6


def test_the_gate_holds_a_family_for_three_seconds() -> None:
    gate = ToolTintGate()
    assert gate.family("Bash", 100.0) == "shell"
    # Another tool in the same family is the same light.
    assert gate.family("bash", 100.5) == "shell"
    # A new family inside the floor waits; the head keeps what it shows.
    assert gate.family("Edit", 101.0) == "shell"
    assert gate.family("Edit", 102.9) == "shell"
    # Past the floor it is taken.
    assert gate.family("Edit", 103.1) == "edit"
    # And the floor starts again from that change.
    assert gate.family("Read", 104.0) == "edit"
    assert gate.family("Read", 106.2) == "read"


def _status(tool: str | None, mode: AgentMode = AgentMode.TOOL_RUNNING) -> AgentStatus:
    return AgentStatus(
        provider="claude",
        agent_id="claude:1",
        display_name="Claude",
        mode=mode,
        updated_at=datetime(2026, 9, 24, tzinfo=timezone.utc),
        event_name="PreToolUse",
        tool_name=tool,
    )


def _compose(settings: ColorSettings, *, active: bool = True, attention: bool = False):
    preferences = AccessibilityDisplayPreferences()
    resolved = resolve_glance(
        GlanceInputs(
            actionable_episode_key="ask:1" if attention else None,
            fresh_failure=None,
            fresh_completion=None,
            active=active,
            unresolved_failure=False,
            capacity=None,
        ),
        presentation_time=100.0,
        relay_epoch=100.0,
        preferences=preferences,
    )
    return compose_presentation_program(
        resolved,
        presentation_time=100.0,
        led_count=8,
        color="#D97757",
        preferences=preferences,
        provider="claude",
        color_settings=settings,
    )


def _tinted(tool: str | None, *, now: float, gate: ToolTintGate, enabled: bool = True) -> ColorSettings:
    settings = ColorSettings.defaults().with_agent_animation("claude", "comet").with_tint_by_tool(enabled)
    return with_tool_tint(settings, (_status(tool),), "claude", now=now, gate=gate)


def test_the_head_takes_the_tint_and_the_tail_keeps_the_provider() -> None:
    gate = ToolTintGate()
    plain = _compose(_tinted("Edit", now=0.0, gate=ToolTintGate(), enabled=False))
    tinted = _compose(_tinted("Edit", now=0.0, gate=gate))
    profile_plain = plain.dsl.splitlines()[1].split()
    profile_tinted = tinted.dsl.splitlines()[1].split()
    ceiling = ColorSettings.defaults().fade_range(colors_module.MODE_WORKING)[1]
    assert profile_tinted[0] == shapes.shade(TOOL_TINT_COLORS["edit"], ceiling)
    assert profile_tinted[0] != profile_plain[0]
    assert profile_tinted[1:] == profile_plain[1:], "only the head changes"


def test_a_tool_change_within_a_family_writes_nothing() -> None:
    """The device dedupe compares identities: Read then Grep is one light."""
    gate = ToolTintGate()
    first = _compose(_tinted("Read", now=0.0, gate=gate))
    second = _compose(_tinted("Grep", now=10.0, gate=gate))
    assert continuous_presentation_identity(first) == continuous_presentation_identity(second)
    third = _compose(_tinted("Bash", now=20.0, gate=gate))
    assert continuous_presentation_identity(third) != continuous_presentation_identity(first)


def test_off_by_default_and_ignored_by_urgent_states() -> None:
    assert ColorSettings.defaults().tint_by_tool is False
    gate = ToolTintGate()
    untouched = ColorSettings.defaults().with_agent_animation("claude", "comet")
    assert with_tool_tint(untouched, (_status("Edit"),), "claude", now=0.0, gate=gate) is untouched
    # An ask reads the same whatever tool was running.
    asking_plain = _compose(_tinted("Edit", now=0.0, gate=ToolTintGate(), enabled=False), attention=True)
    asking_tinted = _compose(_tinted("Edit", now=0.0, gate=ToolTintGate()), attention=True)
    assert asking_plain.dsl == asking_tinted.dsl
    # A motion without a head (breathe) ignores it too.
    breathing = ColorSettings.defaults().with_agent_animation("claude", "breathe").with_tint_by_tool(True)
    assert _compose(with_tool_tint(breathing, (_status("Edit"),), "claude", now=0.0, gate=ToolTintGate())).dsl == _compose(breathing).dsl


def test_the_setting_round_trips() -> None:
    settings = ColorSettings.defaults().with_tint_by_tool(True)
    assert ColorSettings.from_dict(settings.to_dict()).tint_by_tool is True
    assert ColorSettings.from_dict({"tint_by_tool": "yes"}).tint_by_tool is False
