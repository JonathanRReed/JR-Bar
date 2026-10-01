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
    PROVIDER_ANIMATION_CHOICES,
    PROVIDER_ANIMATION_DESCRIPTIONS,
    PROVIDER_BRAND_COLORS,
    STATE_SEED_COLORS,
    SWATCH_GROUP_CUSTOM,
    SWATCH_GROUP_DEFAULT,
    ColorSettings,
    default_agent_color,
    mode_color_row,
    mode_color_rows,
    provider_color_row,
    provider_color_rows,
    swatch_name,
)
from jrbar.led_status import ASK_AMBER, DONE_GREEN, IDLE_DIM, WORKING_CYAN
from jrbar.providers import PROVIDER_SPECS

# --- Defect 4: the animation sentence belongs to the row --------------------


def is_brand_color(hex_value):
    """Local guard over the live brand table (the src helper was deleted
    2026-08-26: tests were its only callers; the TABLE is load-bearing)."""
    from jrbar.colors import _BRAND_NAME_BY_HEX, normalize_hex

    return normalize_hex(hex_value, "#000000").upper() in _BRAND_NAME_BY_HEX


def test_the_model_carries_the_animation_sentence_not_just_its_key() -> None:
    """The description the view shows is a property of the row, so a view
    that renders the row cannot disagree with the popup beside it."""
    colors = ColorSettings.defaults()
    for motion in PROVIDER_ANIMATION_CHOICES:
        row = provider_color_row("codex", colors.with_agent_animation("codex", motion))
        assert row.animation == motion
        assert row.animation_description == PROVIDER_ANIMATION_DESCRIPTIONS[motion]
        assert row.animation_description.strip()


# --- Defects 5 and 6: the two Codex colours ---------------------------------


def test_a_brand_hex_is_asserted_as_a_literal__and_2_more() -> None:
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

    # --- scenario: no_state_signal_colour_is_claimed_as_a_brand
    """#FF3A00 is this app's ask/blocked colour. It was globally named
    "Codex" and reported as a brand, so the State Colors card's Ask row was
    named after a provider and clicking the chip captioned "Codex" painted
    Codex the alert red."""
    for name, hex_value in STATE_SEED_COLORS:
        assert not is_brand_color(hex_value), hex_value
        assert swatch_name(hex_value) == name, hex_value
    assert swatch_name(ASK_AMBER) == "Ask"
    assert swatch_name(WORKING_CYAN) == "Working"
    assert swatch_name(DONE_GREEN) == "Done"
    assert swatch_name(IDLE_DIM) == "Idle"


def test_no_row_names_the_same_thing_twice__and_2_more() -> None:
    # --- scenario: no_row_names_the_same_thing_twice
    """``brand_swatches_for_provider``'s own docstring promises "never a
    second swatch confusingly wearing the provider's own name next to a
    different hex". For Codex it produced exactly that."""
    for row in provider_color_rows(ColorSettings.defaults()) + mode_color_rows(
        ColorSettings.defaults()
    ):
        offered = [
            swatch
            for group in row.groups
            for swatch in group.swatches
            if not swatch.opens_picker
        ]
        names = [swatch.name for swatch in offered]
        hexes = [swatch.hex.upper() for swatch in offered]
        assert len(names) == len(set(names)), f"{row.key}: duplicate names {names}"
        assert len(hexes) == len(set(hexes)), f"{row.key}: duplicate hexes {hexes}"

    # --- scenario: a_provider_whose_colour_is_a_brand_does_not_also_get_a_default_chip
    row = provider_color_row("codex", ColorSettings.defaults())
    assert [swatch.name for swatch in row.group("brand").swatches] == [
        name for name, _hex in BRAND_SEED_COLORS
    ]
    assert row.current_name == "Codex"
    # Devin's navy really is in neither named set, so it keeps its Default.
    devin = provider_color_row("devin", ColorSettings.defaults())
    assert devin.group("brand").swatches[0].name == "Default"
    assert devin.current_name == "Default"

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


def test_a_reassigned_default_lands_somewhere_actually_distinct__and_2_more() -> None:
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

    # --- scenario: every_state_row_rings_the_colour_it_is_wearing
    """On a fresh install every State Colors row had ZERO chips ringed: it
    drew CURATED_PALETTE[:6] and not one of the four shipped state colours
    is in that strip."""
    for row in mode_color_rows(ColorSettings.defaults()):
        selected = [
            swatch
            for group in row.groups
            for swatch in group.swatches
            if swatch.selected and not swatch.opens_picker
        ]
        assert len(selected) == 1, f"{row.key}: {len(selected)} chips ringed"
        assert selected[0].group == SWATCH_GROUP_DEFAULT
        assert row.current_name == selected[0].name


def test_a_hand_picked_state_colour_becomes_a_named_ringed_custom_chip__and_1_more() -> None:
    # --- scenario: a_hand_picked_state_colour_becomes_a_named_ringed_custom_chip
    """The picker chip was hardcoded ``name="Pick…"`` with ``selected`` never
    set, so unlike a provider row it could never become "Custom"."""
    colors = ColorSettings.defaults().with_mode_color("done", "#123456")
    row = mode_color_row("done", colors)
    picker = row.picker_swatch
    assert picker.name == "Custom"
    assert picker.selected is True
    assert picker.hex == "#123456"
    assert row.current_name == "Custom"

    # And back on a named colour it is the neutral opener again.
    named = mode_color_row("done", ColorSettings.defaults().with_mode_color("done", CURATED_PALETTE[1]))
    assert named.picker_swatch.name == "Pick…"
    assert named.picker_swatch.selected is False
    assert named.current_name == "Blue"

    # --- scenario: every_state_swatch_has_a_name_and_a_labelled_group
    for row in mode_color_rows(ColorSettings.defaults()):
        assert row.label.strip()
        assert [group.key for group in row.groups] == [
            SWATCH_GROUP_DEFAULT,
            "palette",
            SWATCH_GROUP_CUSTOM,
        ]
        for group in row.groups:
            assert group.label.strip() and group.hint.strip()
            for swatch in group.swatches:
                assert swatch.name.strip()
