from __future__ import annotations

from dataclasses import FrozenInstanceError

import pytest

from jrbar.accessibility_display import AccessibilityDisplayPreferences
from jrbar.ambient_effect_dispatch import (
    MAX_AMBIENT_OUTPUT_DURATION_MS,
    AmbientEffectFamily,
    AmbientEffectSurface,
    AmbientSemanticColors,
    compile_ambient_effect_dispatch,
)
from jrbar.animation import errors_only, read_program
from jrbar.announcer_stack import AnnouncerAlertIdentity
from jrbar.ask_heartbeat_sync import AskHeartbeatPresentation, plan_ask_heartbeat_sync
from jrbar.capacity_types import SourceKey
from jrbar.clear_agents import CompletionPresentationKey
from jrbar.completion_meniscus import (
    CompletionMeniscusGeometry,
    CompletionMeniscusSurface,
    SelectedUnseenCompletionEvidence,
    plan_completion_meniscus,
)
from jrbar.courtesy_signatures import CourtesySemantic, plan_courtesy_signature
from jrbar.dot_binary_heartbeat import DotSecondaryPolicy, plan_dot_binary_heartbeat
from jrbar.firefly_completion import FireflyCompletionEvidence, plan_firefly_completion
from jrbar.fleet_arrival_departure import (
    FleetArrivalDepartureAccessibility,
    FleetArrivalDepartureCue,
    FleetArrivalDepartureIdentity,
    FleetCueDisposition,
    FleetEndpointRole,
    FleetPresenceTransition,
)
from jrbar.fleet_bands import FleetBand, FleetPlan
from jrbar.glance_light import (
    GlanceKind,
    GlanceLightState,
    make_glance_notification,
    plan_glance_light,
)
from jrbar.handoff_baton import HandoffEndpoint, plan_handoff_baton
from jrbar.milestone_odometer import (
    MilestoneOdometerPreferences,
    MilestoneOdometerState,
    plan_milestone_odometer,
)
from jrbar.rainstick_idle import plan_rainstick_idle
from jrbar.recovery_grace_note import (
    RECOVERY_WIPE_DURATION_SECONDS,
    RecoveryGraceDisposition,
    RecoveryGraceIdentity,
    RecoveryGracePlan,
    RecoveryGracePresentation,
)
from jrbar.semantic_effect_router import (
    SemanticEffectCandidate,
    SemanticEventKind,
    route_semantic_effects,
)
from jrbar.turn_length_ember import plan_turn_length_ember

SOURCE = SourceKey("codex", "hooks", "local:test", "live_agent_events")


def _completion(index: int = 1) -> CompletionPresentationKey:
    return CompletionPresentationKey(SOURCE, f"agent:{index}", "Stop", float(index))


def _fleet_band(identity: str, start: int, end: int) -> FleetBand:
    return FleetBand(
        identity=identity,
        semantic="working",
        led_start=start,
        led_end=end,
        screen_start=float(start * 10),
        screen_end=float(end * 10),
    )


def _firefly():
    identity = "fleet:one"
    active = _fleet_band(identity, 0, 2)
    stable = _fleet_band(identity, 4, 8)
    decision = plan_firefly_completion(
        FireflyCompletionEvidence(_completion(), identity, active),
        FleetPlan(
            mode="segmented",
            bands=(stable,),
            member_slots=((identity, 4, 8),),
            led_count=8,
            screen_bar_width=80.0,
        ),
    )
    assert decision.plan is not None
    return decision.plan


def _meniscus(*, reduce_motion: bool = False):
    return plan_completion_meniscus(
        SelectedUnseenCompletionEvidence(_completion()),
        CompletionMeniscusGeometry(
            CompletionMeniscusSurface.SCREEN_BAR,
            0.0,
            0.0,
            80.0,
            12.0,
        ),
        AccessibilityDisplayPreferences(reduce_motion=reduce_motion),
    )


def _handoff():
    decision = plan_handoff_baton(
        HandoffEndpoint(
            "event:done",
            "agent:one",
            "segment:one",
            "First agent",
            10.0,
            project_identity="project:one",
        ),
        HandoffEndpoint(
            "event:start",
            "agent:two",
            "segment:two",
            "Second agent",
            11.0,
            project_identity="project:one",
        ),
    )
    assert decision.plan is not None
    return decision.plan


def _recovery():
    from jrbar.provider_facts import EventToken, ProviderWatermark, WatermarkBasis

    watermark = ProviderWatermark(
        source_key=SOURCE,
        basis=WatermarkBasis.PROVIDER_EVENT_ID,
        occurred_at_epoch=10.0,
        event_token=EventToken("recovered:1"),
        sequence=None,
        tie_break_rank=1,
    )
    return RecoveryGracePlan(
        dedupe_identity=RecoveryGraceIdentity(watermark),
        disposition=RecoveryGraceDisposition.EMIT,
        presentation=RecoveryGracePresentation.RESTRAINED_WIPE,
        suppression_reason=None,
        repetitions=1,
        duration_seconds=RECOVERY_WIPE_DURATION_SECONDS,
        returns_to_normal=True,
        consumes_finite_cue=True,
        accessibility_text="Source recovered. A restrained recovery cue plays once.",
    )


def _ask(*, reduce_motion: bool = False):
    return plan_ask_heartbeat_sync(
        (
            AskHeartbeatPresentation(
                AnnouncerAlertIdentity("request:v1:one"),
                10.0,
            ),
        ),
        accessibility_preferences=AccessibilityDisplayPreferences(
            reduce_motion=reduce_motion
        ),
    )


def _milestone(*, reduce_motion: bool = False):
    return plan_milestone_odometer(
        MilestoneOdometerPreferences(enabled=True, milestone_steps=(1,)),
        MilestoneOdometerState(),
        (_completion(),),
        reduce_motion=reduce_motion,
    )


def _fleet_cue() -> FleetArrivalDepartureCue:
    identity = FleetArrivalDepartureIdentity(
        "machine:one",
        "episode:one",
        FleetPresenceTransition.ARRIVAL,
    )
    return FleetArrivalDepartureCue(
        identity=identity,
        endpoint_role=FleetEndpointRole.ARRIVAL_ENDPOINT,
        disposition=FleetCueDisposition.WINK,
        suppression_reason=None,
        duration_ms=650,
        passes=1,
        loops=0,
        returns_to_baseline=True,
        accessibility=FleetArrivalDepartureAccessibility(
            "Fleet presence",
            "Remote machine arrived",
            "A trusted remote machine joined the fleet.",
        ),
    )


def _glance():
    notification = make_glance_notification(
        notification_id="glance:one",
        kind=GlanceKind.UNANSWERED_ASK,
        created_at_epoch=10.0,
    )
    return plan_glance_light(GlanceLightState((notification,)), now_epoch=10.0)


@pytest.mark.parametrize(
    ("keyword", "plan", "family"),
    (
        (
            "semantic_selection",
            route_semantic_effects(
                (SemanticEffectCandidate("semantic:work", SemanticEventKind.WORK),)
            ),
            AmbientEffectFamily.SEMANTIC_SELECTION,
        ),
        ("glance_light", _glance(), AmbientEffectFamily.GLANCE_LIGHT),
        ("firefly_completion", _firefly(), AmbientEffectFamily.FIREFLY_COMPLETION),
        ("completion_meniscus", _meniscus(), AmbientEffectFamily.COMPLETION_MENISCUS),
        ("handoff_baton", _handoff(), AmbientEffectFamily.HANDOFF_BATON),
        ("recovery_grace", _recovery(), AmbientEffectFamily.RECOVERY_GRACE),
        ("ask_heartbeat", _ask(), AmbientEffectFamily.ASK_HEARTBEAT),
        (
            "turn_length_ember",
            plan_turn_length_ember(elapsed_seconds=300.0),
            AmbientEffectFamily.TURN_LENGTH_EMBER,
        ),
        (
            "rainstick_idle",
            plan_rainstick_idle(preference_enabled=True),
            AmbientEffectFamily.RAINSTICK_IDLE,
        ),
        (
            "dot_binary_heartbeat",
            plan_dot_binary_heartbeat(
                (SemanticEventKind.ASK,),
                secondary_policy=DotSecondaryPolicy.FLEET_SIZE,
                fleet_size=2,
            ),
            AmbientEffectFamily.DOT_BINARY_HEARTBEAT,
        ),
        ("milestone_odometer", _milestone(), AmbientEffectFamily.MILESTONE_ODOMETER),
        ("fleet_arrival_departure", _fleet_cue(), AmbientEffectFamily.FLEET_ARRIVAL_DEPARTURE),
        (
            "courtesy_signature",
            plan_courtesy_signature(CourtesySemantic.REMINDER),
            AmbientEffectFamily.COURTESY_SIGNATURE,
        ),
    ),
)
def test_every_renderer_neutral_family_compiles_to_a_named_accessible_effect(
    keyword: str,
    plan: object,
    family: AmbientEffectFamily,
) -> None:
    dispatch = compile_ambient_effect_dispatch(**{keyword: plan})

    assert dispatch.outputs
    assert all(output.family is family for output in dispatch.outputs)
    assert all(output.effect_identity for output in dispatch.outputs)
    assert all(output.accessibility_text for output in dispatch.outputs)
    assert all(output.static_fallback_program for output in dispatch.outputs)


def test_explicit_priority_selects_one_output_per_surface() -> None:
    dispatch = compile_ambient_effect_dispatch(
        ask_heartbeat=_ask(),
        recovery_grace=_recovery(),
        rainstick_idle=plan_rainstick_idle(preference_enabled=True),
    )

    assert tuple(output.surface for output in dispatch.outputs) == (
        AmbientEffectSurface.SCREEN_BAR,
        AmbientEffectSurface.SIDEPULSE_PRO,
        AmbientEffectSurface.SIDEPULSE_DOT,
    )
    assert all(output.family is AmbientEffectFamily.ASK_HEARTBEAT for output in dispatch.outputs)
    assert len(dispatch.suppressed) == 4


def test_reduce_motion_plans_compile_static_output_without_losing_identity_or_text() -> None:
    moving = compile_ambient_effect_dispatch(completion_meniscus=_meniscus())
    static = compile_ambient_effect_dispatch(completion_meniscus=_meniscus(reduce_motion=True))

    moving_output = moving.for_surface(AmbientEffectSurface.SCREEN_BAR)
    static_output = static.for_surface(AmbientEffectSurface.SCREEN_BAR)
    assert moving_output is not None and static_output is not None
    assert moving_output.effect_identity == static_output.effect_identity
    assert static_output.animated is False
    assert "Reduce Motion" in static_output.accessibility_text
    assert static_output.program == static_output.static_fallback_program


def test_dot_binary_heartbeat_owns_dot_while_richer_surface_effects_remain_elsewhere() -> None:
    dispatch = compile_ambient_effect_dispatch(
        ask_heartbeat=_ask(),
        dot_binary_heartbeat=plan_dot_binary_heartbeat(
            (SemanticEventKind.ASK,),
            secondary_policy=DotSecondaryPolicy.UNSEEN_NOTIFICATIONS,
            unseen_notification_present=True,
        ),
    )

    dot = dispatch.for_surface(AmbientEffectSurface.SIDEPULSE_DOT)
    screen = dispatch.for_surface(AmbientEffectSurface.SCREEN_BAR)
    assert dot is not None and screen is not None
    assert dot.family is AmbientEffectFamily.DOT_BINARY_HEARTBEAT
    assert screen.family is AmbientEffectFamily.ASK_HEARTBEAT
    assert "0:" in dot.program and "1:" in dot.program


def test_every_program_is_parser_valid_bounded_and_capped_at_two_hertz() -> None:
    dispatch = compile_ambient_effect_dispatch(
        glance_light=_glance(),
        firefly_completion=_firefly(),
        ask_heartbeat=_ask(),
        dot_binary_heartbeat=plan_dot_binary_heartbeat(
            (SemanticEventKind.ASK,),
            secondary_policy=DotSecondaryPolicy.FLEET_SIZE,
            fleet_size=4,
        ),
    )

    for output in dispatch.outputs:
        led_count = 2 if output.surface is AmbientEffectSurface.SIDEPULSE_DOT else 8
        _animation, problems = read_program(output.program, led_count=led_count)
        assert errors_only(problems) == ()
        assert len(output.program.splitlines()) <= 20
        assert len(output.program.encode("utf-8")) <= 512
        assert 0.0 <= output.max_flash_hz <= 2.0
        assert 0 < output.duration_ms <= MAX_AMBIENT_OUTPUT_DURATION_MS
        assert output.expires_after_ms == output.duration_ms


def test_semantic_colors_are_typed_normalized_and_do_not_mutate_inputs() -> None:
    colors = AmbientSemanticColors(work="#123abc")
    selection = route_semantic_effects(
        (SemanticEffectCandidate("semantic:work", SemanticEventKind.WORK),)
    )

    dispatch = compile_ambient_effect_dispatch(
        semantic_selection=selection,
        semantic_colors=colors,
    )

    assert colors.work == "#123ABC"
    assert all("#123ABC" in output.program for output in dispatch.outputs)
    with pytest.raises(FrozenInstanceError):
        dispatch.outputs = ()  # type: ignore[misc]
    with pytest.raises(FrozenInstanceError):
        dispatch.outputs[0].program = "off"  # type: ignore[misc]


def test_semantic_program_override_plays_the_assigned_effect() -> None:
    """An assignment's rendered program replaces the generic swell.

    The Effect Studio's promise is "this effect, with these parameters" --
    the daemon renders that program once per selection and hands it in
    here, uncompiled, so each surface binds its own LED count at write
    time.
    """
    from jrbar.semantic_effect_router import (
        DEFAULT_SEMANTIC_EFFECT_MAP,
        SemanticEffectAssignment,
        SemanticEffectMap,
    )

    assignments = tuple(
        SemanticEffectAssignment(
            row.semantic,
            "kitt" if row.semantic is SemanticEventKind.COMPLETION else row.effect_identifier,
        )
        for row in DEFAULT_SEMANTIC_EFFECT_MAP.assignments
    )
    selection = route_semantic_effects(
        (SemanticEffectCandidate("semantic:done", SemanticEventKind.COMPLETION),),
        effect_map=SemanticEffectMap(assignments=assignments),
    )
    assert selection.registry_effect_identifier == "kitt"

    custom = "#112233 100ms none\n#445566 100ms none\nrepeat 3"
    dispatch = compile_ambient_effect_dispatch(
        semantic_selection=selection, semantic_program=custom
    )
    assert dispatch.outputs
    for output in dispatch.outputs:
        assert "#112233" in output.program and "#445566" in output.program
        led_count = 2 if output.surface is AmbientEffectSurface.SIDEPULSE_DOT else 8
        _animation, problems = read_program(output.program, led_count=led_count)
        assert errors_only(problems) == ()

    # A bounded builtin keeps its safety variant; the override only ever
    # applies to the effect it was rendered for.
    ask = route_semantic_effects(
        (SemanticEffectCandidate("semantic:ask", SemanticEventKind.ASK),)
    )
    builtin = compile_ambient_effect_dispatch(
        semantic_selection=ask, semantic_program=custom
    )
    assert all("#112233" not in output.program for output in builtin.outputs)

    with pytest.raises(TypeError):
        compile_ambient_effect_dispatch(semantic_selection=selection, semantic_program=42)


def test_suppressed_or_empty_plans_emit_nothing() -> None:
    dispatch = compile_ambient_effect_dispatch(
        semantic_selection=route_semantic_effects(()),
        rainstick_idle=plan_rainstick_idle(),
        milestone_odometer=plan_milestone_odometer(
            MilestoneOdometerPreferences(),
            MilestoneOdometerState(),
            (),
        ),
    )

    assert dispatch.outputs == ()
    assert dispatch.suppressed == ()


def test_the_dot_heartbeat_paints_both_leds_on_every_line() -> None:
    """The live defect of 2026-09-10, in the surface that actually produced it.

    /Volumes/PulseDot/LEDS.LED was carrying

        0:#722CA1 1:#14732D 250ms none
        0:#000000 250ms none
        0:#722CA1 250ms none
        0:#000000 250ms none
        0:#000000 1500ms none
        repeat 8

    -- LED 2 named once and never again. The firmware's "unmentioned LEDs
    hold" rule then kept it lit at that green through every later line AND
    past the end of the bounded phrase, which is the "the first LED is still
    showing bluish-green" the owner reported. A program has to be a complete
    statement of the surface on every line it has.
    """
    from jrbar.animation import ColorList, IndexedPaint, PaintStep, WholeBar, read_program

    dispatch = compile_ambient_effect_dispatch(
        dot_binary_heartbeat=plan_dot_binary_heartbeat(
            (SemanticEventKind.ASK,),
            secondary_policy=DotSecondaryPolicy.UNSEEN_NOTIFICATIONS,
            unseen_notification_present=True,
        ),
    )
    dot = dispatch.for_surface(AmbientEffectSurface.SIDEPULSE_DOT)
    assert dot is not None and dot.animated
    animation, problems = read_program(dot.program, led_count=2)
    assert errors_only(problems) == ()
    lines = [step for step in animation.steps if type(step) is PaintStep]
    assert len(lines) >= 2
    for index, step in enumerate(lines):
        addressed: set[int] = set()
        for segment in step.segments:
            if type(segment) in (WholeBar, ColorList):
                addressed = {0, 1}
                break
            if type(segment) is IndexedPaint:
                addressed.update(int(led) for led, _color in segment.assignments)
        assert addressed == {0, 1}, f"line {index + 1} leaves an LED unaddressed"
