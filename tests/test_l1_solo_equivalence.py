"""Solo working providers keep native motion; other states keep reviewed bytes."""
import hashlib
import json
from datetime import datetime, timezone
from pathlib import Path

import pytest

from jrbar.colors import (
    BLEND_MODE_CHOICES,
    PROVIDER_ANIMATION_CHOICES,
    ColorSettings,
    program_for_snapshot,
    provider_motion_preview_program,
)
from jrbar.led_status import LedDisplayState, display_state_for_mode
from jrbar.models import AgentMode, AgentStatus

FIXTURE = Path(__file__).parent / "fixtures" / "l1_solo_59acbc0a.json"
NOW = datetime(2026, 10, 25, tzinfo=timezone.utc)


def solo_bytes(animation, mode, count, blend):
    settings = ColorSettings.defaults().with_agent_animation("codex", animation).with_blend_mode(blend)
    status = AgentStatus(provider="codex", agent_id="codex:synthetic", display_name="Synthetic",
        mode=AgentMode(mode), updated_at=NOW, event_name="synthetic")
    state, program = program_for_snapshot((status,), colors=settings, led_count=count)
    return hashlib.sha256((state.value + "\n" + program).encode()).hexdigest()


@pytest.mark.parametrize("blend", ("color_blend", "classic"))
@pytest.mark.parametrize("count", (2, 8))
@pytest.mark.parametrize("mode", tuple(mode.value for mode in AgentMode))
@pytest.mark.parametrize("animation", PROVIDER_ANIMATION_CHOICES)
def test_every_solo_animation_and_state_matches_reviewed_contract(animation, mode, count, blend):
    if display_state_for_mode(AgentMode(mode)) is LedDisplayState.WORKING:
        assert solo_bytes(animation, mode, count, blend) == solo_bytes(animation, mode, count, "round_robin")
        return
    baseline = json.loads(FIXTURE.read_text())
    assert baseline["revision"] == "59acbc0a"
    key = f"{animation}/{mode}/{count}/{blend}"
    assert solo_bytes(animation, mode, count, blend) == baseline["sha256"][key]


@pytest.mark.parametrize("animation", PROVIDER_ANIMATION_CHOICES)
@pytest.mark.parametrize("count", (2, 8))
@pytest.mark.parametrize("blend", BLEND_MODE_CHOICES)
def test_hover_preview_uses_the_live_solo_program(animation, count, blend):
    settings = ColorSettings.defaults().with_blend_mode(blend).with_agent_animation("codex", animation)
    status = AgentStatus(provider="codex", agent_id="codex:synthetic", display_name="Synthetic",
        mode=AgentMode.WORKING, updated_at=NOW, event_name="synthetic")
    preview = provider_motion_preview_program("codex", settings.agent_color("codex"), settings,
        led_count=count)
    assert program_for_snapshot((status,), colors=settings, led_count=count)[1] == preview


if __name__ == "__main__":
    rows = {f"{animation}/{mode.value}/{count}/{blend}": solo_bytes(animation, mode.value, count, blend)
        for animation in PROVIDER_ANIMATION_CHOICES for mode in AgentMode
        for count in (2, 8) for blend in ("color_blend", "classic")}
    baseline = json.loads(FIXTURE.read_text())
    for key, digest in rows.items():
        if key.split("/")[1] in {"waiting_for_input", "blocked_error"}:
            assert digest == baseline["sha256"][key], f"Unapproved attention change: {key}"
    FIXTURE.write_text(json.dumps({
        "revision": "59acbc0a",
        "calm_contract": "2026-10-26: a solo working provider keeps its motion; other Calm states and attention bytes are unchanged.",
        "sha256": rows,
    }, indent=2) + "\n")
