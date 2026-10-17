"""The colour and animation model: swatches, names and motion.

The bug this suite exists for was reported as "we have a thing somewhere in
the menu that lets us choose brand colors for all of the providers we have
selected. I don't know where to find it or how to do it." What was actually
there: rows with no provider identity, swatch strips of anonymous coloured
squares, and a sentence of body text claiming the first four squares were the
Claude/OpenAI/Codex/Gemini brand colours -- which they were not, because the
strip being drawn was CURATED_PALETTE (system red/blue/green/purple).

So the interesting half is a MODEL: which swatches, what they are named, what
order they come in, which ones are brands, and how a provider's animation
replaces a state's rhythm. ``jrbar.colors`` is live code, so this file tests
it exhaustively without building a single view.
"""

from __future__ import annotations

from datetime import datetime, timezone

import pytest

from jrbar import colors as colors_module
from jrbar.colors import (
    BRAND_SEED_COLORS,
    MOTION_BEAT,
    MOTION_BLINK,
    MOTION_BREATHE,
    MOTION_CHASE,
    MOTION_STEADY,
    PROVIDER_ANIMATION_AUTO,
    PROVIDER_ANIMATION_CHOICES,
    PROVIDER_ANIMATION_LABELS,
    PROVIDER_PALETTES,
    ColorSettings,
    StudioPreviewSession,
    agent_motion,
    program_for_snapshot,
    studio_preview_program,
)
from jrbar.led_status import LedDisplayState
from jrbar.models import AgentMode, AgentStatus


def is_brand_color(hex_value):
    """Local guard over the live brand table (the src helper was deleted
    2026-08-26: tests were its only callers; the TABLE is load-bearing)."""
    from jrbar.colors import _BRAND_NAME_BY_HEX, normalize_hex

    return normalize_hex(hex_value, "#000000").upper() in _BRAND_NAME_BY_HEX


def _status(provider: str, mode: AgentMode, *, agent_id: str | None = None) -> AgentStatus:
    return AgentStatus(
        provider=provider,
        agent_id=agent_id or f"{provider}:1",
        display_name=provider.title(),
        mode=mode,
        updated_at=datetime(2026, 8, 14, tzinfo=timezone.utc),
        event_name="test",
    )


# --- Named brand groups ----------------------------------------------------





def test_brand_seeds_and_brand_palettes_cannot_drift_apart() -> None:
    # --- scenario: brand_seeds_and_brand_palettes_cannot_drift_apart
    """One source of truth: the "Claude" look and the "Claude" swatch are
    seeded from the same hex, so renaming or recolouring one moves both."""
    assert list(PROVIDER_PALETTES) == [name for name, _hex in BRAND_SEED_COLORS]
    for name, seed in BRAND_SEED_COLORS:
        assert PROVIDER_PALETTES[name] == colors_module.derive_palette(seed)










# --- Per-provider animation ------------------------------------------------


def test_provider_animation_defaults_to_automatic_and_round_trips__and_2_more() -> None:
    # --- scenario: provider_animation_defaults_to_automatic_and_round_trips
    colors = ColorSettings.defaults()
    assert colors.agent_animation("claude") == PROVIDER_ANIMATION_AUTO
    assert colors.provider_animation == {}

    chased = colors.with_agent_animation("claude", MOTION_CHASE)
    assert chased.agent_animation("claude") == MOTION_CHASE
    assert colors.agent_animation("claude") == PROVIDER_ANIMATION_AUTO  # frozen
    assert ColorSettings.from_dict(chased.to_dict()) == chased

    # --- scenario: automatic_removes_the_stored_choice_rather_than_storing_auto
    colors = ColorSettings.defaults().with_agent_animation("claude", MOTION_STEADY)
    back = colors.with_agent_animation("claude", PROVIDER_ANIMATION_AUTO)
    assert back.provider_animation == {}
    assert back == ColorSettings.from_dict(back.to_dict())

    # --- scenario: a_settings_file_from_before_this_feature_still_loads
    legacy = ColorSettings.defaults().to_dict()
    legacy.pop("provider_animation")
    assert ColorSettings.from_dict(legacy) == ColorSettings.defaults()



def test_garbage_provider_animation_reads_as_automatic_and_is_not_persisted__and_2_more() -> None:
    # --- scenario: garbage_provider_animation_reads_as_automatic_and_is_not_persisted
    payload = ColorSettings.defaults().to_dict()
    payload["provider_animation"] = {
        "claude": "interpretive-dance",
        "codex": PROVIDER_ANIMATION_AUTO,
        "": MOTION_CHASE,
        "devin": MOTION_BLINK,
    }
    loaded = ColorSettings.from_dict(payload)
    assert loaded.provider_animation == {"devin": MOTION_BLINK}
    assert loaded.agent_animation("claude") == PROVIDER_ANIMATION_AUTO
    with pytest.raises(ValueError):
        loaded.with_agent_animation("claude", "interpretive-dance")

    # --- scenario: every_offered_animation_has_a_label_and_a_description
    for motion in PROVIDER_ANIMATION_CHOICES:
        assert PROVIDER_ANIMATION_LABELS[motion].strip()
        assert colors_module.PROVIDER_ANIMATION_DESCRIPTIONS[motion].strip()
    assert PROVIDER_ANIMATION_LABELS[PROVIDER_ANIMATION_AUTO] == "Automatic"
    # The vocabulary the owner asked for -- expanded 2026-08-21 with the
    # pattern-survey rhythms (heartbeat/scanner/comet/flicker), again
    # 2026-08-26 with the upstream-ecosystem shapes (KITT from PR #29,
    # tlip's gradient wave, the roll marquee, the two-tone duotone), and
    # again 2026-09-12 from upstream's own animation catalog (the
    # centre-bright idle gradient, the lid-open centre-out bloom, the
    # battery bar's pulsing frontier, and a specular glint), and again
    # 2026-09-24 when Jonathan asked for a handful of new animations (a
    # centre-out ripple and a swinging pendulum).
    # Still nothing invented BESIDE the list: every entry here was asked
    # for by name or ported from a sourced program.
    assert set(PROVIDER_ANIMATION_CHOICES) - {PROVIDER_ANIMATION_AUTO} == {
        MOTION_BREATHE,
        MOTION_CHASE,
        colors_module.MOTION_HEARTBEAT,
        colors_module.MOTION_SCANNER,
        colors_module.MOTION_KITT,
        colors_module.MOTION_COMET,
        colors_module.MOTION_FLICKER,
        colors_module.MOTION_STACK,
        colors_module.MOTION_TWINKLE,
        colors_module.MOTION_DRIFT,
        colors_module.MOTION_CONVERGE,
        colors_module.MOTION_AURORA,
        colors_module.MOTION_TIDE,
        colors_module.MOTION_GRADIENT,
        colors_module.MOTION_MARQUEE,
        colors_module.MOTION_DUOTONE,
        colors_module.MOTION_EMBER,
        colors_module.MOTION_BLOOM,
        colors_module.MOTION_FRONTIER,
        colors_module.MOTION_GLINT,
        colors_module.MOTION_RIPPLE,
        colors_module.MOTION_PENDULUM,
        MOTION_STEADY,
        MOTION_BLINK,
    }
    assert MOTION_BEAT not in PROVIDER_ANIMATION_CHOICES

    # --- scenario: seeded_ambient_motion_compiles_to_repeatable_bytes
    for motion in (
        colors_module.MOTION_FLICKER,
        colors_module.MOTION_TWINKLE,
        colors_module.MOTION_DRIFT,
        colors_module.MOTION_AURORA,
    ):
        settings = ColorSettings.defaults().with_agent_animation("claude", motion)

        first = colors_module._motion_turn_lines(
            "#4F8CFF",
            LedDisplayState.WORKING,
            settings,
            provider="claude",
            led_count=8,
            duration_ms=1600,
        )
        second = colors_module._motion_turn_lines(
            "#4F8CFF",
            LedDisplayState.WORKING,
            settings,
            provider="claude",
            led_count=8,
            duration_ms=1600,
        )

        assert first == second



def test_a_providers_animation_replaces_the_states_rhythm__and_2_more() -> None:
    # --- scenario: a_providers_animation_replaces_the_states_rhythm
    colors = ColorSettings.defaults().with_agent_animation("claude", MOTION_STEADY)
    assert agent_motion(LedDisplayState.WORKING, cycle_ms=1600) == MOTION_CHASE
    assert (
        agent_motion(
            LedDisplayState.WORKING, cycle_ms=1600, provider="claude", settings=colors
        )
        == MOTION_STEADY
    )
    # A provider left on Automatic is untouched.
    assert (
        agent_motion(
            LedDisplayState.WORKING, cycle_ms=1600, provider="codex", settings=colors
        )
        == MOTION_CHASE
    )

    # --- scenario: urgency_keeps_its_beat_whatever_the_provider_was_set_to
    """A per-provider animation is for telling two busy agents apart. It is
    not a switch for turning "a human is needed" into something calmer."""
    colors = ColorSettings.defaults().with_agent_animation("claude", MOTION_STEADY)
    for state in (LedDisplayState.ASK, LedDisplayState.FAILED):
        assert agent_motion(
            state, cycle_ms=1600, provider="claude", settings=colors
        ) == agent_motion(state, cycle_ms=1600)

    # --- scenario: a_chosen_animation_still_obeys_nothing_above_two_hertz
    colors = ColorSettings.defaults().with_agent_animation("claude", MOTION_BLINK)
    fast = colors_module.MIN_FLASH_CYCLE_MS - 1
    assert (
        agent_motion(LedDisplayState.WORKING, cycle_ms=fast, provider="claude", settings=colors)
        == MOTION_STEADY
    )
    assert (
        agent_motion(
            LedDisplayState.WORKING,
            cycle_ms=colors_module.MIN_FLASH_CYCLE_MS,
            provider="claude",
            settings=colors,
        )
        == MOTION_BLINK
    )



def _round_robin(colors: ColorSettings) -> str:
    statuses = (
        _status("claude", AgentMode.WORKING),
        _status("codex", AgentMode.WORKING),
    )
    _state, program = program_for_snapshot(
        statuses, led_count=8, colors=colors.with_blend_mode(colors_module.BLEND_MODE_ROUND_ROBIN)
    )
    return program


def test_one_provider_on_steady_changes_only_its_own_leds__and_1_more() -> None:
    # --- scenario: one_provider_on_steady_changes_only_its_own_leds
    """Two agents working at once: put Claude on Steady and its LEDs hold
    while Codex's keep chasing. Without the per-provider wiring both keep
    pulsing and the two programs are byte-identical."""
    base = ColorSettings.defaults()
    changed = base.with_agent_animation("claude", MOTION_STEADY)

    before = _round_robin(base)
    after = _round_robin(changed)
    assert before != after

    # Claude sorts after Codex in PROVIDER_SPECS order, so it owns the odd
    # LEDs; those lose their pulse while the even ones keep theirs.
    motion_line = after.splitlines()[1]
    segments = motion_line.split("; ")
    assert "pulse" not in segments[1]
    assert "pulse" in segments[0]

    # --- scenario: a_lone_agent_also_gets_its_providers_animation
    base = ColorSettings.defaults()
    changed = base.with_agent_animation("claude", MOTION_STEADY)
    statuses = (_status("claude", AgentMode.WORKING),)

    _state, before = program_for_snapshot(statuses, led_count=8, colors=base)
    _state, after = program_for_snapshot(statuses, led_count=8, colors=changed)
    assert before != after
    assert "pulse" not in after



def _segments(program: str, line: int) -> list[str]:
    return program.splitlines()[line].split("; ")


def test_spatial_split_blocks_follow_the_providers_animation__and_2_more() -> None:
    # --- scenario: spatial_split_blocks_follow_the_providers_animation
    base = ColorSettings.defaults().with_blend_mode(colors_module.BLEND_MODE_SPATIAL)
    changed = base.with_agent_animation("claude", MOTION_STEADY)
    statuses = (
        _status("claude", AgentMode.WORKING),
        _status("codex", AgentMode.WORKING),
    )
    _state, before = program_for_snapshot(statuses, led_count=8, colors=base)
    _state, after = program_for_snapshot(statuses, led_count=8, colors=changed)
    assert before != after

    # Blocks are laid out in PROVIDER_SPECS order, so codex owns 0-3 and
    # claude 4-7. Only claude's block loses its pulse.
    motion = _segments(after, 1)
    assert all("pulse" in segment for segment in motion[:4])
    assert not any("pulse" in segment for segment in motion[4:])

    # And its RESET line has to agree it is not pulsing: a reset that still
    # dims to the fade floor while the motion line holds solid parks the
    # whole block at its floor colour.
    def reset_color(program: str, index: int) -> str:
        return _segments(program, 0)[index].split(":")[1].split()[0]

    for index in range(4, 8):
        assert colors_module.relative_luminance(
            reset_color(after, index)
        ) > colors_module.relative_luminance(reset_color(before, index))

    # --- scenario: relay_stays_byte_stable_when_every_provider_holds_still
    """Relay skips its baton rotation when nothing is actually moving -- the
    property that keeps it from rewriting the device for motion that does not
    exist. A provider parked on Steady counts as still."""
    colors = (
        ColorSettings.defaults()
        .with_blend_mode(colors_module.BLEND_MODE_RELAY)
        .with_agent_animation("claude", MOTION_STEADY)
        .with_agent_animation("codex", MOTION_STEADY)
    )
    statuses = (
        _status("claude", AgentMode.WORKING),
        _status("codex", AgentMode.WORKING),
    )
    programs = {
        program_for_snapshot(
            statuses, led_count=8, colors=colors, relay_elapsed_seconds=elapsed
        )[1]
        for elapsed in (0.0, 0.4, 0.9, 1.7)
    }
    assert len(programs) == 1

    # --- scenario: hovering_never_changes_what_is_saved
    committed = ColorSettings.defaults()
    session = StudioPreviewSession(committed)
    assert not session.previewing

    candidate = session.preview_agent_color("claude", "#10A37F")
    assert session.previewing
    assert session.effective is candidate
    assert candidate.agent_color("claude") == "#10A37F"
    assert session.committed is committed
    assert session.committed.agent_color("claude") == "#D97757"

    assert session.revert() is committed
    assert not session.previewing
    assert session.effective is committed



def test_committing_keeps_whatever_is_being_previewed__and_2_more() -> None:
    # --- scenario: committing_keeps_whatever_is_being_previewed
    session = StudioPreviewSession(ColorSettings.defaults())
    session.preview_agent_animation("claude", MOTION_CHASE)
    kept = session.commit()
    assert kept.agent_animation("claude") == MOTION_CHASE
    assert not session.previewing
    assert session.effective is kept

    # --- scenario: rebasing_drops_an_in_flight_hover
    """A palette button or Reset changes the ground under an open hover. The
    candidate is stale the moment that happens and must not repaint over it."""
    session = StudioPreviewSession(ColorSettings.defaults())
    session.preview_agent_color("claude", "#10A37F")
    fresh = ColorSettings.defaults().with_agent_color("claude", "#FF3A00")
    assert session.rebase(fresh) is fresh
    assert not session.previewing
    assert session.effective is fresh

    # --- scenario: a_preview_program_reflects_the_candidate_not_the_saved_settings
    committed = ColorSettings.defaults()
    candidate = committed.with_agent_color("claude", "#10A37F")
    statuses = (_status("claude", AgentMode.WORKING),)

    before = studio_preview_program(committed, statuses=statuses)
    after = studio_preview_program(candidate, statuses=statuses)
    assert before != after
    assert after == program_for_snapshot(
        statuses, led_count=8, colors=candidate, brightness=1.0
    )[1]
    assert committed.agent_color("claude") == "#D97757"



def test_a_preview_with_nothing_running_still_shows_something() -> None:
    # --- scenario: a_preview_with_nothing_running_still_shows_something
    program = studio_preview_program(ColorSettings.defaults(), statuses=())
    assert program.strip()
