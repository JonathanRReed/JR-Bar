"""The colour-vision check: the palette's dichromacy promise, measured on
the colours the person has now, with the nudge that keeps it."""

from __future__ import annotations

from types import SimpleNamespace

import pytest

from jrbar import colors as colors_module
from jrbar import core_runtime
from jrbar.colors import (
    DICHROMACY_VISIONS,
    IDENTITY_LUMINANCE_FLOOR,
    MIN_VISION_SEPARATION_DE,
    ColorSettings,
    check_palette,
    palette_colors,
    relative_luminance,
    vision_separation,
)
from jrbar.core_server import CommandError
from jrbar.providers import PROVIDER_SPECS
from jrbar.settings import AgentMonitorSettings
from tests.test_provider_colour_dichromacy import separation as reference_separation

PROVIDERS = tuple(spec.provider for spec in PROVIDER_SPECS)


@pytest.mark.parametrize("vision", DICHROMACY_VISIONS)
@pytest.mark.parametrize(
    ("left", "right"),
    [("#2B8FFF", "#00E5FF"), ("#D97757", "#FF9500"), ("#3BB056", "#00FF66"), ("#A00848", "#B23400")],
)
def test_the_runtime_metric_is_the_one_the_palette_was_searched_with(left: str, right: str, vision: str) -> None:
    assert vision_separation(left, right, vision) == pytest.approx(reference_separation(left, right, vision), abs=1e-6)


def test_the_shipped_palette_only_collapses_where_the_ratchet_says() -> None:
    shipped = palette_colors(ColorSettings.defaults(), PROVIDERS)
    pairs = check_palette(shipped, shipped=shipped)
    # The one recorded owner decision: Codex's brand blue is the Working
    # light for a protanope. Everything else the palette promised holds.
    assert [(pair["left"], pair["right"]) for pair in pairs] == [("agent:codex", "state:working")]
    assert pairs[0]["shipped"] is True and pairs[0]["vision"] == "protanopia"
    # No lightness step frees it without landing Codex on OpenCode or
    # Devin: it needs the hue decision the ratchet records, and the check
    # says so rather than offering a nudge that trades one collapse for
    # another.
    assert pairs[0]["suggestion"] is None


def test_an_edit_that_collapses_is_named_and_the_edit_is_what_moves() -> None:
    shipped = palette_colors(ColorSettings.defaults(), PROVIDERS)
    edited = dict(shipped, **{"agent:claude": "#FF9500"})  # onto Hermes' orange
    pairs = [pair for pair in check_palette(edited, shipped=shipped) if "agent:claude" in (pair["left"], pair["right"])]
    assert pairs, "claude on hermes' orange must read as one light"
    hermes = next(pair for pair in pairs if "agent:hermes" in (pair["left"], pair["right"]))
    assert hermes["shipped"] is False and hermes["separation"] < MIN_VISION_SEPARATION_DE
    nudge = hermes["suggestion"]
    assert nudge is not None and nudge["key"] == "agent:claude"
    # The nudge clears every other light, not just its pair, and stays lit.
    moved = dict(edited, **{"agent:claude": nudge["color"]})
    for key, value in moved.items():
        if key != "agent:claude":
            for vision in DICHROMACY_VISIONS:
                assert vision_separation(nudge["color"], value, vision) >= MIN_VISION_SEPARATION_DE
    assert relative_luminance(nudge["color"]) >= IDENTITY_LUMINANCE_FLOOR


def test_tritanopia_is_checked_only_when_asked() -> None:
    shipped = palette_colors(ColorSettings.defaults(), PROVIDERS)
    default = {(pair["left"], pair["right"]) for pair in check_palette(shipped, shipped=shipped)}
    with_tritan = check_palette(shipped, shipped=shipped, visions=(*DICHROMACY_VISIONS, "tritanopia"))
    assert {pair["vision"] for pair in with_tritan} >= {"tritanopia"}
    assert default < {(pair["left"], pair["right"]) for pair in with_tritan}


def test_the_daemon_checks_the_saved_palette_and_a_candidate_edit() -> None:
    daemon = SimpleNamespace(settings=AgentMonitorSettings())
    reply = core_runtime._cmd_check_palette(daemon, {})
    assert reply["min_separation"] == MIN_VISION_SEPARATION_DE
    assert reply["visions"] == list(DICHROMACY_VISIONS)
    assert reply["checked"] == len(PROVIDERS) + len(colors_module.MODE_COLOR_KEYS)
    assert [(pair["left"], pair["right"]) for pair in reply["pairs"]] == [("agent:codex", "state:working")]
    candidate = core_runtime._cmd_check_palette(daemon, {"colors": {"state:ask": "#B00020"}})
    assert any({"state:ask", "state:error"} <= {pair["left"], pair["right"]} for pair in candidate["pairs"])
    for bad in (
        {"colors": {"agent:nobody": "#FFFFFF"}},
        {"colors": {"state:ask": "red"}},
        {"colors": {"state:ask": "FF0000"}},
        {"colors": ["#FFFFFF"]},
        {"visions": ["x-ray"]},
        {"visions": []},
    ):
        with pytest.raises(CommandError):
            core_runtime._cmd_check_palette(daemon, bad)
    assert "check_palette" in core_runtime.command_names()
