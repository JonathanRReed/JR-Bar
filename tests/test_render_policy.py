from __future__ import annotations

from dataclasses import FrozenInstanceError

import pytest

from jrbar.accessibility_display import AccessibilityDisplayPreferences
from jrbar.render_policy import (
    BoundedRenderCache,
    GlowGeometryKey,
    GlowPaintKey,
    RenderEnvironment,
    choose_render_cadence,
    choose_render_schedule,
    runtime_render_environment,
)


def test_hidden_or_sleeping_surface_pauses__and_2_more() -> None:
    # --- scenario: hidden_or_sleeping_surface_pauses
    assert choose_render_cadence(RenderEnvironment(visible=False), True).fps == 0.0
    assert (
        choose_render_cadence(
            RenderEnvironment(visible=True, display_asleep=True), True
        ).fps
        == 0.0
    )

    # --- scenario: static_and_active_cadences_are_adaptive
    environment = RenderEnvironment(visible=True)

    static = choose_render_cadence(environment, False)
    active = choose_render_cadence(environment, True)

    assert 0.0 < static.fps <= 4.0
    assert active.fps >= 60.0
    assert active.fps > static.fps
    assert active.sample_fps == active.fps

    # --- scenario: render_schedule_reuses_the_cadence_policy_result
    environment = RenderEnvironment(visible=True, low_power=True, thermal="serious")

    schedule = choose_render_schedule(
        environment,
        animation_active=True,
        display_link_available=True,
    )

    assert schedule.cadence == choose_render_cadence(environment, animation_active=True)


def test_render_schedule_preserves_the_next_visual_change_deadline__and_2_more() -> None:
    # --- scenario: render_schedule_preserves_the_next_visual_change_deadline
    """Catches finite cue demotion losing the pulse deadline at driver selection."""
    schedule = choose_render_schedule(
        RenderEnvironment(visible=True),
        animation_active=True,
        display_link_available=True,
        next_visual_change_at=42.75,
    )

    assert schedule.next_visual_change_at == 42.75

    # --- scenario: low_power_and_thermal_pressure_reduce_cadence
    normal = choose_render_cadence(RenderEnvironment(visible=True), True)
    low_power = choose_render_cadence(
        RenderEnvironment(visible=True, low_power=True), True
    )
    serious = choose_render_cadence(
        RenderEnvironment(visible=True, thermal="serious"), True
    )
    constrained = choose_render_cadence(
        RenderEnvironment(visible=True, low_power=True, thermal="serious"), True
    )
    critical = choose_render_cadence(
        RenderEnvironment(visible=True, thermal="critical"), True
    )

    assert low_power.fps < normal.fps
    assert serious.fps < normal.fps
    assert constrained.fps <= 10.0
    assert critical.fps < serious.fps

    # --- scenario: accessibility_snapshot_and_generation_do_not_change_cadence
    baseline = RenderEnvironment(visible=True, low_power=True, thermal="serious")
    accessible = RenderEnvironment(
        visible=True,
        low_power=True,
        thermal="serious",
        preferences=AccessibilityDisplayPreferences(
            reduce_motion=True,
            reduce_transparency=True,
            increase_contrast=True,
            differentiate_without_color=True,
        ),
        accessibility_generation=41,
    )

    assert choose_render_cadence(accessible, False) == choose_render_cadence(
        baseline, False
    )
    assert choose_render_cadence(accessible, True) == choose_render_cadence(
        baseline, True
    )
    assert choose_render_schedule(
        accessible, True, display_link_available=True
    ) == choose_render_schedule(baseline, True, display_link_available=True)
    with pytest.raises(FrozenInstanceError):
        accessible.accessibility_generation = 42  # type: ignore[misc]


def test_geometry_key_is_color_free_but_invalidates_geometry_inputs__and_2_more() -> None:
    # --- scenario: geometry_key_is_color_free_but_invalidates_geometry_inputs
    cache: BoundedRenderCache[object] = BoundedRenderCache(max_entries=3)
    builds = 0

    def build() -> object:
        nonlocal builds
        builds += 1
        return object()

    base = GlowGeometryKey.from_output(
        screen_identity="built-in:1",
        scale=2.0,
        dimensions=(220.0, 37.0),
        led_count=8,
        width=220.0,
        silhouette=((0.0, 0.0), (220.0, 0.0), (220.0, 37.0), (0.0, 0.0)),
    )
    first = cache.get_or_build(base, build)
    second = cache.get_or_build(base, build)
    resized = cache.get_or_build(
        GlowGeometryKey.from_output(
            screen_identity="built-in:1",
            scale=2.0,
            dimensions=(221.0, 37.0),
            led_count=8,
            width=221.0,
            silhouette=((0.0, 0.0), (221.0, 0.0), (221.0, 37.0), (0.0, 0.0)),
        ),
        build,
    )

    assert first is second
    assert resized is not first
    assert builds == 2
    assert cache.metrics.hits == 1
    assert cache.metrics.misses == 2

    # --- scenario: geometry_keys_ignore_color_and_brightness_but_cover_geometry_identity
    first = GlowGeometryKey.from_output(
        screen_identity="built-in:1",
        scale=2.0,
        dimensions=(220.0, 37.0),
        led_count=8,
        width=220.0,
        silhouette="rounded",
        brightness=255,
        colors=((0.2, 0.4, 0.8, 1.0),),
    )
    second = GlowGeometryKey.from_output(
        screen_identity="built-in:1",
        scale=2.0,
        dimensions=(220.0, 37.0),
        led_count=8,
        width=220.0,
        silhouette="rounded",
        brightness=32,
        colors=((1.0, 0.0, 0.0, 1.0),),
    )

    assert first == second
    variants = [
        {"screen_identity": "external:2"},
        {"scale": 1.0},
        {"dimensions": (221.0, 37.0)},
        {"led_count": 12},
        {"width": 218.0},
        {"silhouette": "contoured"},
    ]
    for change in variants:
        values = {
            "screen_identity": "built-in:1",
            "scale": 2.0,
            "dimensions": (220.0, 37.0),
            "led_count": 8,
            "width": 220.0,
            "silhouette": "rounded",
        }
        values.update(change)
        assert GlowGeometryKey.from_output(**values) != first

    # --- scenario: paint_key_changes_for_every_paint_input
    geometry = GlowGeometryKey.from_output(
        screen_identity="built-in:1",
        scale=2.0,
        dimensions=(220.0, 37.0),
        led_count=8,
        width=220.0,
        silhouette="rounded",
    )
    base = GlowPaintKey.from_output(
        geometry=geometry,
        colors=((0.2, 0.4, 0.8, 1.0),),
        brightness=255,
        contrast=False,
        transparency=True,
        differentiate_without_color=False,
    )
    changes = [
        {"colors": ((0.9, 0.4, 0.8, 1.0),)},
        {"brightness": 128},
        {"contrast": True},
        {"transparency": False},
        {"differentiate_without_color": True},
    ]
    for change in changes:
        values = {
            "geometry": geometry,
            "colors": ((0.2, 0.4, 0.8, 1.0),),
            "brightness": 255,
            "contrast": False,
            "transparency": True,
            "differentiate_without_color": False,
        }
        values.update(change)
        assert GlowPaintKey.from_output(**values) != base


def test_runtime_environment_reads_public_power_state_with_fallbacks() -> None:
    class ProcessInfo:
        @staticmethod
        def isLowPowerModeEnabled() -> bool:
            return True

        @staticmethod
        def thermalState() -> int:
            return 2

    environment = runtime_render_environment(
        visible=True,
        display_asleep=False,
        process_info=ProcessInfo(),
    )
    fallback = runtime_render_environment(
        visible=True,
        process_info=object(),
    )

    assert environment.low_power is True
    assert environment.thermal == "serious"
    assert fallback.low_power is False
    assert fallback.thermal == "nominal"
