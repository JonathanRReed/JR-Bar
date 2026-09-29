"""The ask-escalation defaults that README.md and the quick start quote.

Those pages say an unanswered ask brightens the light after 30 s, pulses the
menu-bar icon after 2 min and stops there unless Settings picks the Chime or
Take over tier, which adds the 5 min chime. If a default moves, the pages move
with it.
"""

from __future__ import annotations

from jrbar.settings import AgentMonitorSettings
from jrbar.signals import escalation_stage


def _stage(elapsed: float, tier: str) -> int:
    defaults = AgentMonitorSettings()
    return escalation_stage(
        elapsed,
        ramp_seconds=defaults.escalation_ramp_seconds,
        menu_bar_seconds=defaults.escalation_menu_bar_seconds,
        final_seconds=defaults.escalation_final_seconds,
        tier=tier,
    )


def test_the_default_tier_and_delays_are_the_ones_the_docs_quote() -> None:
    defaults = AgentMonitorSettings()

    assert defaults.escalation_tier == "menu_bar"
    assert defaults.escalation_ramp_seconds == 30.0
    assert defaults.escalation_menu_bar_seconds == 120.0
    assert defaults.escalation_final_seconds == 300.0


def test_an_unanswered_ask_stops_at_the_menu_bar_pulse_unless_the_tier_is_louder() -> None:
    default_tier = AgentMonitorSettings().escalation_tier

    assert [_stage(seconds, default_tier) for seconds in (10, 30, 119, 120, 299, 400)] == [0, 1, 1, 2, 2, 2]
    assert _stage(400, "light") == 1
    assert _stage(400, "chime") == 3
    assert _stage(400, "takeover") == 3
    # Stage 3 is the chime and the takeover, and only from the final delay on.
    assert _stage(299, "chime") == 2
