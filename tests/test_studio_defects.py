"""Regression tests for the confirmed colour model defects.

Each test here failed against the tree it was written for. They are grouped by
the defect they pin: the animation sentence belonging to the row, the two Codex
colours, rows that named or offered the same thing twice, and state rows that
never rang the colour they wear. Every assertion reads ``jrbar.colors``
directly, so none of them needs a view.
"""

from __future__ import annotations

from jrbar import colors as colors_module
from jrbar.colors import (
    BRAND_SEED_COLORS,
    CURATED_PALETTE,
    PROVIDER_BRAND_COLORS,
    STATE_SEED_COLORS,
    default_agent_color,
)
from jrbar.providers import PROVIDER_SPECS

# --- Defect 4: the animation sentence belongs to the row --------------------


def is_brand_color(hex_value):
    """Local guard over the live brand table (the src helper was deleted
    2026-08-26: tests were its only callers; the TABLE is load-bearing)."""
    from jrbar.colors import _BRAND_NAME_BY_HEX, normalize_hex

    return normalize_hex(hex_value, "#000000").upper() in _BRAND_NAME_BY_HEX




# --- Defects 5 and 6: the two Codex colours ---------------------------------


def test_a_brand_hex_is_asserted_as_a_literal__and_1_more() -> None:
    # --- scenario: a_brand_hex_is_asserted_as_a_literal
    """The audit's finding: every brand test compared the model to the
    constant it is built from, so nothing could catch the constant being
    wrong -- and it was. Codex's brand colour is OpenAI's documented Azure,
    the same hex the provider table has always used."""
    brands = dict(BRAND_SEED_COLORS)
    assert brands["Codex"] == "#2B8FFF"
    assert brands["Claude"] == "#D97757"
    assert brands["OpenAI"] == "#10A37F"
    assert brands["Google"] == "#4796E3"

    # --- scenario: the_two_brand_tables_cannot_disagree
    """BRAND_SEED_COLORS said Codex was #FF3A00 while PROVIDER_BRAND_COLORS
    said codex was #2B8FFF, so the Codex row drew a "Default" chip AND a
    "Codex" chip, wearing different colours."""
    brands = {name.lower(): hex_value for name, hex_value in BRAND_SEED_COLORS}
    for provider, hex_value in PROVIDER_BRAND_COLORS.items():
        if provider in brands:
            assert brands[provider].upper() == hex_value.upper(), provider



def test_no_two_agents_ship_the_same_default_colour() -> None:
    # --- scenario: no_two_agents_ship_the_same_default_colour
    """grok and opencode both shipped systemGray #8E8E93 -- indistinguishable
    on the strip out of the box."""
    assigned = {
        spec.provider: default_agent_color(spec.provider).upper()
        for spec in PROVIDER_SPECS
    }
    duplicates = {
        hex_value
        for hex_value in assigned.values()
        if list(assigned.values()).count(hex_value) > 1
    }
    assert not duplicates, f"providers sharing a colour: {duplicates}"


def test_a_reassigned_default_lands_somewhere_actually_distinct__and_1_more() -> None:
    # --- scenario: a_reassigned_default_lands_somewhere_actually_distinct
    """Taking merely the next free index would have given opencode systemRed
    #FF3B30 -- ten degrees of hue from the ask signal #FF3A00. Distinct as a
    string, the same light on the strip."""
    reserved = [hex_value for _name, hex_value in STATE_SEED_COLORS]
    reserved += list(PROVIDER_BRAND_COLORS.values())
    for spec in PROVIDER_SPECS:
        colour = default_agent_color(spec.provider)
        if colour.upper() in {value.upper() for value in PROVIDER_BRAND_COLORS.values()}:
            continue  # its own brand colour; distinctness is not the goal there
        for other in reserved:
            assert colors_module._hue_gap(colour, other) > 20.0, (
                f"{spec.provider} {colour} sits {colors_module._hue_gap(colour, other):.1f} "
                f"degrees from {other}"
            )

    # --- scenario: defaults_still_come_from_the_curated_palette
    for spec in PROVIDER_SPECS:
        colour = default_agent_color(spec.provider)
        assert colour in CURATED_PALETTE or colour in PROVIDER_BRAND_COLORS.values()
    assert default_agent_color("some-future-provider") in CURATED_PALETTE
