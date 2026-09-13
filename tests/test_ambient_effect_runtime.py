from dataclasses import replace
from types import SimpleNamespace

import pytest

from jrbar.ambient_effect_consumer import active_hardware_ambient_presentation
from jrbar.ambient_effect_dispatch import AmbientEffectFamily, AmbientEffectSurface
from jrbar.ambient_effect_runtime import (
    active_ambient_surface_output,
    install_ambient_effect_runtime,
    request_idle_screensaver_peek,
)
from jrbar.capacity_types import SourceKey
from jrbar.core_server import CommandError
from jrbar.dnd_policy import compose_dnd_contributions
from jrbar.effect_assignment_store import (
    EffectAssignmentCache,
    EffectAssignmentDocument,
    EffectAssignmentRecord,
)
from jrbar.effect_history import EffectOutcome
from jrbar.effect_studio import AssignmentScope
from jrbar.glance_light import GlanceLightState
from jrbar.operator_state import (
    AcknowledgementEligibility,
    CanonicalOperatorEvent,
    CanonicalRequestTruth,
    CanonicalWorkTruth,
    InterruptionClass,
    RequestPhase,
    SemanticEventKey,
    TransitionKind,
    classify_operator_event,
    empty_operator_state,
)
from jrbar.provider_facts import (
    EventToken,
    NextActor,
    ObservationAuthority,
    ProviderWatermark,
    RequestIdentifier,
    RequestKey,
    RequestKind,
    SourceFreshness,
    SourceHealth,
    WatermarkBasis,
    WorkIdentifier,
    WorkKey,
    WorkLifecycle,
)


class _Writer:
    def __init__(self) -> None:
        self.submissions: list[tuple[str, bool]] = []

    def submit(self, key, _operation, *, replace_pending=False):
        self.submissions.append((key, replace_pending))


class _Event:
    transition_kind = TransitionKind.REQUEST_OPENED

    def __repr__(self) -> str:
        return "content-free-event"


def _controller_type():
    class Controller:
        _effect_assignment_cache = EffectAssignmentCache()

        def __init__(self) -> None:
            self.settings = SimpleNamespace(active_scene="calm")
            self._accessibility_display_preferences = SimpleNamespace(
                reduce_motion=False
            )
            self._notification_action_bindings = {}
            self._persistence_writer = _Writer()
            self.virtual_status_device = object()
            self.observed_event_batches = []

        def current_dnd_projection(self):
            return compose_dnd_contributions(())

        def _deliver_semantic_notification(
            self,
            _event_key,
            _interruption_class,
            **_kwargs,
        ):
            self._notification_action_bindings["opaque-token"] = object()
            return True

        def _activate_notification_action(self, token):
            return token == "opaque-token"

        def observe_operator_history_events(self, events, state):
            self.observed_event_batches.append((events, state))

    return Controller


def _canonical_state(
    *,
    lifecycle: WorkLifecycle,
    request_open: bool = False,
    health: SourceHealth = SourceHealth.HEALTHY,
    epoch: float = 1_800_000_000.0,
):
    source = SourceKey("codex", "hooks", "local:01", "live_agent_events")
    work_key = WorkKey(source, WorkIdentifier("work:01"))
    request_key = RequestKey(work_key, RequestIdentifier("request:01"))
    watermark = ProviderWatermark(
        source,
        WatermarkBasis.PROVIDER_EVENT_ID,
        epoch,
        EventToken(f"event:{int(epoch)}"),
        None,
        1,
    )
    requests = ()
    request_keys = ()
    if request_open:
        semantic_key = SemanticEventKey(
            request_key,
            TransitionKind.REQUEST_OPENED,
            watermark,
        )
        requests = (
            CanonicalRequestTruth(
                request_key,
                RequestPhase.LIVE_UNACKNOWLEDGED,
                RequestKind.INPUT,
                NextActor.USER,
                watermark,
                SourceFreshness.FRESH,
                AcknowledgementEligibility.ELIGIBLE,
                semantic_key,
                epoch,
                0.0,
            ),
        )
        request_keys = (request_key,)
    work = CanonicalWorkTruth(
        work_key,
        lifecycle,
        watermark,
        ObservationAuthority.AUTHORITATIVE_PROVIDER,
        health,
        SourceFreshness.FRESH,
        NextActor.USER if request_open else NextActor.PROVIDER,
        "Codex work 01",
        None,
        request_keys,
        False,
    )
    state = replace(
        empty_operator_state(),
        generation=1,
        works=(work,),
        requests=requests,
    )
    return state, work_key, request_key, watermark


def _operator_event(subject, kind, watermark):
    key = SemanticEventKey(subject, kind, watermark)
    return CanonicalOperatorEvent(
        key,
        subject,
        kind,
        classify_operator_event(kind),
        watermark.occurred_at_epoch,
        SourceFreshness.FRESH,
    )


def test_runtime_projects_successful_delivery_and_acknowledgement_across_surfaces(
    monkeypatch,
) -> None:
    controller_type = _controller_type()
    receipt = install_ambient_effect_runtime(controller_type)
    assert install_ambient_effect_runtime(controller_type) is receipt
    controller = controller_type()
    monkeypatch.setattr("jrbar.ambient_effect_runtime.time.time", lambda: 100.0)

    assert controller._deliver_semantic_notification(
        _Event(),
        InterruptionClass.ACTION_REQUIRED,
        prefix="attention",
    )

    assert controller._semantic_effect_selection.winner.semantic.value == "ask"
    assert controller._glance_light_plan.notification_count == 1
    assert controller._glance_light_plan.selected_notification_id is not None
    assert len(controller._effect_history.events) == 4
    assert {event.outcome for event in controller._effect_history.events} == {
        EffectOutcome.SHOWN
    }
    assert len({event.surface for event in controller._effect_history.events}) == 4
    assert controller._why_effect_projection.priority == 90
    assert {key for key, _replace in controller._persistence_writer.submissions} == {
        "effect-history",
        "glance-light",
    }

    monkeypatch.setattr("jrbar.ambient_effect_runtime.time.time", lambda: 101.0)
    assert controller._activate_notification_action("opaque-token")

    assert controller._glance_light_plan.notification_count == 0
    assert any(
        event.outcome is EffectOutcome.ACKNOWLEDGED
        for event in controller._effect_history.events
    )
    assert isinstance(controller._glance_light_state, GlanceLightState)


def test_runtime_consumes_cached_provider_assignment_without_reading_disk(
    monkeypatch,
) -> None:
    controller_type = _controller_type()
    install_ambient_effect_runtime(controller_type)
    controller = controller_type()
    state, work_key, _request_key, watermark = _canonical_state(
        lifecycle=WorkLifecycle.COMPLETED,
    )
    event_key = SemanticEventKey(
        work_key,
        TransitionKind.COMPLETED,
        watermark,
    )
    controller.current_operator_state = state
    controller._effect_assignment_cache = EffectAssignmentCache(
        EffectAssignmentDocument(
            (
                EffectAssignmentRecord.create(
                    "pulse",
                    AssignmentScope.PROVIDER,
                    "codex",
                ),
            )
        )
    )
    monkeypatch.setattr(
        "jrbar.ambient_effect_runtime.load_effect_assignments",
        lambda *_args, **_kwargs: (_ for _ in ()).throw(
            AssertionError("runtime route must use the cache")
        ),
        raising=False,
    )

    assert controller._deliver_semantic_notification(
        event_key,
        InterruptionClass.IMPORTANT_OUTCOME,
        prefix="completion",
    )

    assert controller._semantic_effect_selection.registry_effect_identifier == "pulse"


def test_hardware_consumption_resolves_device_assignments_without_mutating_global(
    monkeypatch,
) -> None:
    controller_type = _controller_type()
    install_ambient_effect_runtime(controller_type)
    controller = controller_type()
    state, work_key, _request_key, watermark = _canonical_state(
        lifecycle=WorkLifecycle.COMPLETED,
    )
    event_key = SemanticEventKey(
        work_key,
        TransitionKind.COMPLETED,
        watermark,
    )
    controller.current_operator_state = state
    controller._ambient_assignment_device_id = "device-a"
    controller._effect_assignment_cache = EffectAssignmentCache(
        EffectAssignmentDocument(
            (
                EffectAssignmentRecord.create(
                    "pulse",
                    AssignmentScope.DEVICE,
                    "device-a",
                ),
                EffectAssignmentRecord.create(
                    "rainbow",
                    AssignmentScope.DEVICE,
                    "device-b",
                ),
            )
        )
    )
    monkeypatch.setattr("jrbar.ambient_effect_runtime.time.time", lambda: 100.0)
    monkeypatch.setattr(
        "jrbar.ambient_effect_runtime.time.monotonic",
        lambda: 50.0,
    )

    assert controller._deliver_semantic_notification(
        event_key,
        InterruptionClass.IMPORTANT_OUTCOME,
        prefix="completion",
    )
    assert controller._semantic_effect_selection.registry_effect_identifier == (
        "notification"
    )
    controller._glance_light_plan = None
    controller.observe_operator_history_events((), state)
    global_dispatch = controller._ambient_effect_dispatch

    device_a = active_hardware_ambient_presentation(
        controller,
        device_id="device-a",
        led_count=8,
        reduce_motion=False,
        brightness=255,
    )
    device_b = active_hardware_ambient_presentation(
        controller,
        device_id="device-b",
        led_count=8,
        reduce_motion=False,
        brightness=255,
    )
    unassigned = active_hardware_ambient_presentation(
        controller,
        device_id="device-c",
        led_count=8,
        reduce_motion=False,
        brightness=255,
    )

    assert device_a is not None and device_a.output.effect_identity == "pulse"
    assert device_b is not None and device_b.output.effect_identity == "rainbow"
    assert unassigned is not None and unassigned.output.effect_identity == "notification"
    assert controller._ambient_effect_dispatch is global_dispatch
    assert (
        global_dispatch.for_surface(AmbientEffectSurface.SCREEN_BAR).effect_identity
        == "notification"
    )


def test_device_assignment_cannot_replace_higher_priority_urgent_output(
    monkeypatch,
) -> None:
    controller_type = _controller_type()
    install_ambient_effect_runtime(controller_type)
    controller = controller_type()
    state, _work_key, request_key, watermark = _canonical_state(
        lifecycle=WorkLifecycle.WAITING,
        request_open=True,
    )
    event_key = SemanticEventKey(
        request_key,
        TransitionKind.REQUEST_OPENED,
        watermark,
    )
    controller.current_operator_state = state
    controller._effect_assignment_cache = EffectAssignmentCache(
        EffectAssignmentDocument(
            (
                EffectAssignmentRecord.create(
                    "rainbow",
                    AssignmentScope.DEVICE,
                    "device-a",
                ),
            )
        )
    )
    monkeypatch.setattr("jrbar.ambient_effect_runtime.time.time", lambda: 100.0)
    monkeypatch.setattr(
        "jrbar.ambient_effect_runtime.time.monotonic",
        lambda: 50.0,
    )

    assert controller._deliver_semantic_notification(
        event_key,
        InterruptionClass.ACTION_REQUIRED,
        prefix="attention",
    )
    controller._glance_light_plan = None
    controller.observe_operator_history_events((), state)

    presentation = active_hardware_ambient_presentation(
        controller,
        device_id="device-a",
        led_count=8,
        reduce_motion=False,
        brightness=255,
    )

    assert presentation is not None
    assert presentation.output.effect_identity == "jrbar.ask-heartbeat-sync:v1"
    assert presentation.led_state.value == "ask"


def test_runtime_never_changes_a_refused_delivery() -> None:
    controller_type = _controller_type()

    def refused(self, _event_key, _interruption_class, **_kwargs):
        return False

    controller_type._deliver_semantic_notification = refused
    install_ambient_effect_runtime(controller_type)
    controller = controller_type()

    assert not controller._deliver_semantic_notification(
        _Event(),
        InterruptionClass.ACTION_REQUIRED,
        prefix="attention",
    )
    assert not hasattr(controller, "_glance_light_state")


def test_runtime_projects_canonical_events_through_the_shared_ambient_seam(
    monkeypatch,
) -> None:
    controller_type = _controller_type()
    install_ambient_effect_runtime(controller_type)
    controller = controller_type()
    state, work_key, request_key, watermark = _canonical_state(
        lifecycle=WorkLifecycle.ACTIVE,
        request_open=True,
    )
    events = (
        _operator_event(work_key, TransitionKind.BECAME_ACTIVE, watermark),
        _operator_event(request_key, TransitionKind.REQUEST_OPENED, watermark),
    )
    monkeypatch.setattr("jrbar.ambient_effect_runtime.time.time", lambda: 1_800_000_010.0)

    controller.observe_operator_history_events(events, state)

    assert controller.observed_event_batches == [(events, state)]
    assert controller._ask_heartbeat_plan.request_count == 1
    assert controller._turn_length_ember_plan.visible is True
    assert controller._turn_length_ember_plan.age_label == "Under 2 minutes"
    assert controller._ambient_fleet_plan.accepted is True
    assert controller._dot_binary_heartbeat_plan.selected_semantic.value == "ask"
    assert controller._rainstick_idle_plan.disposition.value == "suppress"
    assert callable(controller._plan_finite_ambient_effect)


def test_turn_length_ember_does_not_mask_multiple_active_works(monkeypatch) -> None:
    controller_type = _controller_type()
    install_ambient_effect_runtime(controller_type)
    controller = controller_type()
    state, work_key, _request_key, watermark = _canonical_state(
        lifecycle=WorkLifecycle.ACTIVE,
    )
    second_key = WorkKey(work_key.source_key, WorkIdentifier("work:02"))
    second_work = replace(state.works[0], key=second_key)
    state = replace(state, works=(*state.works, second_work))
    events = (_operator_event(work_key, TransitionKind.BECAME_ACTIVE, watermark),)
    monkeypatch.setattr(
        "jrbar.ambient_effect_runtime.time.time",
        lambda: 1_800_000_010.0,
    )

    controller.observe_operator_history_events(events, state)

    assert controller._ambient_turn_starts.keys() == {work_key}
    assert controller._turn_length_ember_plan is None
    assert controller._ambient_fleet_plan.accepted is True


def test_completion_event_projects_the_finite_completion_effect_family(
    monkeypatch,
) -> None:
    controller_type = _controller_type()
    install_ambient_effect_runtime(controller_type)
    controller = controller_type()
    state, work_key, _request_key, watermark = _canonical_state(
        lifecycle=WorkLifecycle.COMPLETED,
    )
    event = _operator_event(work_key, TransitionKind.COMPLETED, watermark)
    monkeypatch.setattr("jrbar.ambient_effect_runtime.time.time", lambda: 1_800_000_010.0)

    controller.observe_operator_history_events((event,), state)

    screen_output = controller._ambient_effect_dispatch.for_surface(
        AmbientEffectSurface.SCREEN_BAR
    )
    assert screen_output is not None
    assert screen_output.family is AmbientEffectFamily.FIREFLY_COMPLETION
    assert screen_output.semantic.value == "completion"
    assert controller._firefly_completion_decision is None
    assert controller._completion_meniscus_plans is None
    assert controller._milestone_odometer_plan is None
    assert controller._courtesy_signature_plan is None


def test_runtime_dispatch_expires_without_bypassing_the_surface_owner(
    monkeypatch,
) -> None:
    controller_type = _controller_type()
    install_ambient_effect_runtime(controller_type)
    controller = controller_type()
    state, work_key, _request_key, watermark = _canonical_state(
        lifecycle=WorkLifecycle.COMPLETED,
    )
    event = _operator_event(work_key, TransitionKind.COMPLETED, watermark)
    monkeypatch.setattr("jrbar.ambient_effect_runtime.time.time", lambda: 100.0)
    clock = [50.0]
    monkeypatch.setattr(
        "jrbar.ambient_effect_runtime.time.monotonic",
        lambda: clock[0],
    )

    controller.observe_operator_history_events((event,), state)

    active = active_ambient_surface_output(
        controller,
        AmbientEffectSurface.SCREEN_BAR,
        now_monotonic=50.001,
    )
    assert active is not None
    output, started_at = active
    assert started_at == 50.0

    clock[0] = 50.5
    controller.observe_operator_history_events((), state)
    retained = active_ambient_surface_output(
        controller,
        AmbientEffectSurface.SCREEN_BAR,
        now_monotonic=50.5,
    )
    assert retained is not None
    assert retained[0] == output
    assert retained[1] == 50.0

    assert active_ambient_surface_output(
        controller,
        AmbientEffectSurface.SCREEN_BAR,
        now_monotonic=50.0 + output.expires_after_ms / 1_000.0,
    ) is None


def _cue_settings(**overrides):
    base = {
        "active_scene": "calm",
        "active_scene_pack": None,
        "rainstick_idle_enabled": False,
        "rainstick_night_enabled": False,
        "milestone_odometer_enabled": False,
        "milestone_odometer_steps": (10, 25, 50, 100),
        "idle_screensaver_enabled": False,
        "idle_screensaver_effect": None,
        "idle_screensaver_after_minutes": 20,
    }
    base.update(overrides)
    return SimpleNamespace(**base)


def test_opted_in_cues_plan_presentations_while_defaults_stay_silent(
    monkeypatch,
) -> None:
    controller_type = _controller_type()
    install_ambient_effect_runtime(controller_type)
    monkeypatch.setattr(
        "jrbar.ambient_effect_runtime.time.time", lambda: 1_800_000_010.0
    )

    # Default flags: the planners still run, but the disabled preference
    # declines the idle cue and the odometer keeps no state.
    silent = controller_type()
    silent.settings = _cue_settings()
    silent.observe_operator_history_events((), empty_operator_state())
    assert silent._rainstick_idle_plan.disposition.value == "suppress"
    # An unadmitted context returns before any odometer state exists.
    assert not hasattr(silent, "_milestone_odometer_state")

    # Opted in: the same observation produces a live rainstick plan.
    enabled = controller_type()
    enabled.settings = _cue_settings(rainstick_idle_enabled=True)
    enabled.observe_operator_history_events((), empty_operator_state())
    rainstick = enabled._rainstick_idle_plan
    assert rainstick.disposition.value == "move"
    assert rainstick.animated is True


def test_milestone_odometer_counts_completions_and_fails_closed_on_bad_steps(
    monkeypatch,
) -> None:
    controller_type = _controller_type()
    install_ambient_effect_runtime(controller_type)
    state, work_key, _request_key, watermark = _canonical_state(
        lifecycle=WorkLifecycle.COMPLETED,
    )
    event = _operator_event(work_key, TransitionKind.COMPLETED, watermark)
    monkeypatch.setattr(
        "jrbar.ambient_effect_runtime.time.time", lambda: 1_800_000_010.0
    )

    enabled = controller_type()
    enabled.settings = _cue_settings(
        milestone_odometer_enabled=True,
        milestone_odometer_steps=(1,),
    )
    enabled.observe_operator_history_events((event,), state)
    assert enabled._milestone_odometer_state.completed_count == 1
    dispatch = enabled._ambient_effect_dispatch
    families = {output.family for output in dispatch.outputs} | {
        item.family for item in dispatch.suppressed
    }
    assert AmbientEffectFamily.MILESTONE_ODOMETER in families

    # A malformed persisted ladder disables the cue instead of crashing:
    # no odometer plan reaches the dispatch and nothing is counted.
    malformed = controller_type()
    malformed.settings = _cue_settings(
        milestone_odometer_enabled=True,
        milestone_odometer_steps="many",
    )
    malformed.observe_operator_history_events((event,), state)
    assert malformed._milestone_odometer_state.completed_count == 0

    # Disabled: the completion is not counted either.
    disabled = controller_type()
    disabled.settings = _cue_settings(milestone_odometer_steps=(1,))
    disabled.observe_operator_history_events((event,), state)
    assert disabled._milestone_odometer_state.completed_count == 0


def test_the_active_scene_pack_overrides_the_policy_the_runtime_resolves(
    monkeypatch,
) -> None:
    from jrbar.dnd_policy import DisplayAdmission
    from jrbar.scenes import SCENE_POLICIES, Scene

    class _PackStore:
        def __init__(self, root=None):
            pass

        def policy_overrides(self, pack_id):
            assert pack_id == "quiet-work"
            return {
                Scene.CALM: replace(
                    SCENE_POLICIES[Scene.CALM],
                    display_admission=DisplayAdmission.NONE,
                )
            }

    monkeypatch.setattr(
        "jrbar.scene_pack_store.ScenePackStore", _PackStore
    )
    controller_type = _controller_type()
    install_ambient_effect_runtime(controller_type)
    controller = controller_type()
    controller.settings = _cue_settings(
        active_scene_pack="quiet-work",
        rainstick_idle_enabled=True,
    )

    controller.observe_operator_history_events((), empty_operator_state())

    # The pack's tighter display admission reads as DND: even the opted-in
    # rainstick stays suppressed.
    plan = controller._rainstick_idle_plan
    assert plan.disposition.value == "suppress"
    assert {reason.value for reason in plan.suppression_reasons} == {"dnd"}


def _screensaver_output(dispatch):
    return next(
        (
            output
            for output in dispatch.outputs
            if output.family is AmbientEffectFamily.SEMANTIC_SELECTION
            and output.semantic is not None
            and output.semantic.value == "idle"
        ),
        None,
    )


def test_idle_screensaver_waits_for_the_delay_then_plays_the_chosen_effect(
    monkeypatch,
) -> None:
    controller_type = _controller_type()
    install_ambient_effect_runtime(controller_type)
    monkeypatch.setattr(
        "jrbar.ambient_effect_runtime.time.time", lambda: 1_800_000_010.0
    )
    clock = [10_000.0]
    monkeypatch.setattr(
        "jrbar.ambient_effect_runtime.time.monotonic",
        lambda: clock[0],
    )

    controller = controller_type()
    controller.settings = _cue_settings(
        idle_screensaver_enabled=True,
        idle_screensaver_effect="rainbow",
        idle_screensaver_after_minutes=20,
    )

    # One minute gone of twenty: armed but waiting, nothing on the strip.
    controller.idle_since_monotonic = clock[0] - 60.0
    controller.observe_operator_history_events((), empty_operator_state())
    assert _screensaver_output(controller._ambient_effect_dispatch) is None
    fact = controller._idle_screensaver_fact["screensaver"]
    assert fact["state"] == "waiting"
    assert fact["after_seconds"] == 1200

    # Past the delay: the chosen library effect owns the ambient surfaces.
    controller.idle_since_monotonic = clock[0] - 1_300.0
    controller.observe_operator_history_events((), empty_operator_state())
    output = _screensaver_output(controller._ambient_effect_dispatch)
    assert output is not None
    assert output.effect_identity == "rainbow"
    assert controller._ambient_effect_dispatch.for_surface(
        AmbientEffectSurface.SCREEN_BAR
    ).effect_identity == "rainbow"
    fact = controller._idle_screensaver_fact["screensaver"]
    assert fact["state"] == "playing"
    assert fact["idle_seconds"] >= 1_300.0

    # The next batch re-stages the same output instead of restarting it.
    clock[0] += 2.0
    controller.observe_operator_history_events((), empty_operator_state())
    retained = controller._ambient_effect_dispatch.for_surface(
        AmbientEffectSurface.SCREEN_BAR
    )
    assert retained is not None and retained.effect_identity == "rainbow"
    assert controller._idle_screensaver_fact["screensaver"]["state"] == "playing"


def test_idle_screensaver_yields_the_moment_a_real_signal_exists(
    monkeypatch,
) -> None:
    controller_type = _controller_type()
    install_ambient_effect_runtime(controller_type)
    monkeypatch.setattr(
        "jrbar.ambient_effect_runtime.time.time", lambda: 1_800_000_010.0
    )
    clock = [10_000.0]
    monkeypatch.setattr(
        "jrbar.ambient_effect_runtime.time.monotonic",
        lambda: clock[0],
    )

    controller = controller_type()
    controller.settings = _cue_settings(
        idle_screensaver_enabled=True,
        idle_screensaver_effect="rainbow",
        idle_screensaver_after_minutes=20,
    )
    controller.idle_since_monotonic = clock[0] - 1_300.0
    controller.observe_operator_history_events((), empty_operator_state())
    assert _screensaver_output(controller._ambient_effect_dispatch) is not None

    # A working session appears: the screensaver retires inside the same
    # batch instead of lingering on its unexpired output.
    state, work_key, _request_key, watermark = _canonical_state(
        lifecycle=WorkLifecycle.ACTIVE,
    )
    event = _operator_event(work_key, TransitionKind.BECAME_ACTIVE, watermark)
    controller.observe_operator_history_events((event,), state)
    assert _screensaver_output(controller._ambient_effect_dispatch) is None
    # Held off by a live signal reads "off", not "waiting".
    assert controller._idle_screensaver_fact["screensaver"]["state"] == "off"

    # And an ask that arrived by delivery keeps its staged selection: the
    # screensaver never clobbers a pending winner.
    controller.observe_operator_history_events((), empty_operator_state())
    assert _screensaver_output(controller._ambient_effect_dispatch) is not None
    ask_state, _work_key, request_key, ask_watermark = _canonical_state(
        lifecycle=WorkLifecycle.WAITING,
        request_open=True,
    )
    event_key = SemanticEventKey(
        request_key,
        TransitionKind.REQUEST_OPENED,
        ask_watermark,
    )
    assert controller._deliver_semantic_notification(
        event_key,
        InterruptionClass.ACTION_REQUIRED,
        prefix="attention",
    )
    controller.observe_operator_history_events((), ask_state)
    screen = controller._ambient_effect_dispatch.for_surface(
        AmbientEffectSurface.SCREEN_BAR
    )
    assert screen is not None
    assert screen.semantic.value == "ask"
    assert _screensaver_output(controller._ambient_effect_dispatch) is None


def test_idle_screensaver_fails_closed_on_unknown_or_missing_effect(
    monkeypatch,
) -> None:
    controller_type = _controller_type()
    install_ambient_effect_runtime(controller_type)
    monkeypatch.setattr(
        "jrbar.ambient_effect_runtime.time.time", lambda: 1_800_000_010.0
    )
    clock = [10_000.0]
    monkeypatch.setattr(
        "jrbar.ambient_effect_runtime.time.monotonic",
        lambda: clock[0],
    )

    # Enabled but nothing picked: "off", never waiting, never playing.
    controller = controller_type()
    controller.settings = _cue_settings(
        idle_screensaver_enabled=True,
        idle_screensaver_effect=None,
    )
    controller.idle_since_monotonic = clock[0] - 9_999.0
    controller.observe_operator_history_events((), empty_operator_state())
    assert _screensaver_output(controller._ambient_effect_dispatch) is None
    assert controller._idle_screensaver_fact["screensaver"]["state"] == "off"

    # An id the registry does not know fails the same closed way.
    unknown = controller_type()
    unknown.settings = _cue_settings(
        idle_screensaver_enabled=True,
        idle_screensaver_effect="not-a-real-effect",
    )
    unknown.idle_since_monotonic = clock[0] - 9_999.0
    unknown.observe_operator_history_events((), empty_operator_state())
    assert _screensaver_output(unknown._ambient_effect_dispatch) is None
    assert unknown._idle_screensaver_fact["screensaver"]["state"] == "off"


def test_idle_screensaver_respects_night_consent_and_dnd_admission(
    monkeypatch,
) -> None:
    from jrbar.dnd_policy import DisplayAdmission
    from jrbar.scenes import SCENE_POLICIES, Scene

    class _PackStore:
        def __init__(self, root=None):
            pass

        def policy_overrides(self, pack_id):
            assert pack_id == "quiet-work"
            return {
                Scene.CALM: replace(
                    SCENE_POLICIES[Scene.CALM],
                    display_admission=DisplayAdmission.NONE,
                )
            }

    monkeypatch.setattr(
        "jrbar.scene_pack_store.ScenePackStore", _PackStore
    )
    controller_type = _controller_type()
    install_ambient_effect_runtime(controller_type)
    monkeypatch.setattr(
        "jrbar.ambient_effect_runtime.time.time", lambda: 1_800_000_010.0
    )
    clock = [10_000.0]
    monkeypatch.setattr(
        "jrbar.ambient_effect_runtime.time.monotonic",
        lambda: clock[0],
    )

    # Night scene without the shared night consent: armed but held off.
    night = controller_type()
    night.settings = _cue_settings(
        active_scene="night",
        idle_screensaver_enabled=True,
        idle_screensaver_effect="rainbow",
    )
    night.idle_since_monotonic = clock[0] - 9_999.0
    night.observe_operator_history_events((), empty_operator_state())
    assert _screensaver_output(night._ambient_effect_dispatch) is None
    assert night._idle_screensaver_fact["screensaver"]["state"] == "off"

    # Consented, the same night scene plays.
    consented = controller_type()
    consented.settings = _cue_settings(
        active_scene="night",
        rainstick_night_enabled=True,
        idle_screensaver_enabled=True,
        idle_screensaver_effect="rainbow",
    )
    consented.idle_since_monotonic = clock[0] - 9_999.0
    consented.observe_operator_history_events((), empty_operator_state())
    assert _screensaver_output(consented._ambient_effect_dispatch) is not None

    # A pack that tightens admission to NONE holds the screensaver off too.
    packed = controller_type()
    packed.settings = _cue_settings(
        active_scene_pack="quiet-work",
        idle_screensaver_enabled=True,
        idle_screensaver_effect="rainbow",
    )
    packed.idle_since_monotonic = clock[0] - 9_999.0
    packed.observe_operator_history_events((), empty_operator_state())
    assert _screensaver_output(packed._ambient_effect_dispatch) is None
    assert packed._idle_screensaver_fact["screensaver"]["state"] == "off"


def test_idle_screensaver_peek_plays_now_then_retires(monkeypatch) -> None:
    controller_type = _controller_type()
    install_ambient_effect_runtime(controller_type)
    monkeypatch.setattr(
        "jrbar.ambient_effect_runtime.time.time", lambda: 1_800_000_010.0
    )
    clock = [10_000.0]
    monkeypatch.setattr(
        "jrbar.ambient_effect_runtime.time.monotonic",
        lambda: clock[0],
    )

    # Toggle off and nowhere near the delay: a peek still stages the
    # picked effect -- it is the owner pressing "Play it now".
    controller = controller_type()
    controller.settings = _cue_settings(
        idle_screensaver_enabled=False,
        idle_screensaver_effect="rainbow",
    )
    controller.idle_since_monotonic = clock[0]

    reply = request_idle_screensaver_peek(controller)
    assert reply["effect_id"] == "rainbow"
    assert 2.0 <= reply["seconds"] <= 15.0
    assert controller._idle_screensaver_peek_until == clock[0] + reply["seconds"]

    controller.observe_operator_history_events((), empty_operator_state())
    output = _screensaver_output(controller._ambient_effect_dispatch)
    assert output is not None
    assert output.effect_identity == "rainbow"
    assert controller._idle_screensaver_fact["screensaver"]["state"] == "peeking"

    # The first batch past the window retires it through the ordinary
    # merge, and the fact returns to "off" (still armed? no -- disabled).
    clock[0] += reply["seconds"] + 0.1
    controller.observe_operator_history_events((), empty_operator_state())
    assert _screensaver_output(controller._ambient_effect_dispatch) is None
    assert controller._idle_screensaver_fact["screensaver"]["state"] == "off"
    assert controller._idle_screensaver_peek_until is None


def test_idle_screensaver_peek_still_yields_to_a_live_semantic(
    monkeypatch,
) -> None:
    controller_type = _controller_type()
    install_ambient_effect_runtime(controller_type)
    monkeypatch.setattr(
        "jrbar.ambient_effect_runtime.time.time", lambda: 1_800_000_010.0
    )
    clock = [10_000.0]
    monkeypatch.setattr(
        "jrbar.ambient_effect_runtime.time.monotonic",
        lambda: clock[0],
    )

    controller = controller_type()
    controller.settings = _cue_settings(
        idle_screensaver_enabled=True,
        idle_screensaver_effect="rainbow",
    )
    request_idle_screensaver_peek(controller, seconds=5)

    # A working session is live: the admission gates apply to a peek too,
    # so nothing stages and the fact stays honest about it.
    state, work_key, _request_key, watermark = _canonical_state(
        lifecycle=WorkLifecycle.ACTIVE,
    )
    event = _operator_event(work_key, TransitionKind.BECAME_ACTIVE, watermark)
    controller.observe_operator_history_events((event,), state)
    assert _screensaver_output(controller._ambient_effect_dispatch) is None
    assert controller._idle_screensaver_fact["screensaver"]["state"] == "off"

    # Once the signal clears, a batch inside the window still stages it.
    clock[0] += 1.0
    controller.observe_operator_history_events((), empty_operator_state())
    assert _screensaver_output(controller._ambient_effect_dispatch) is not None
    assert controller._idle_screensaver_fact["screensaver"]["state"] == "peeking"


def test_idle_screensaver_peek_refuses_without_a_known_effect(
    monkeypatch,
) -> None:
    controller_type = _controller_type()
    install_ambient_effect_runtime(controller_type)
    monkeypatch.setattr(
        "jrbar.ambient_effect_runtime.time.monotonic", lambda: 10_000.0
    )

    # Nothing picked at all: the card should never have offered it, but
    # the command still answers an honest refusal.
    controller = controller_type()
    controller.settings = _cue_settings(idle_screensaver_effect=None)
    with pytest.raises(CommandError) as refused:
        request_idle_screensaver_peek(controller)
    assert refused.value.code == "invalid_args"
    assert not hasattr(controller, "_idle_screensaver_peek_until")

    # An id the registry does not know fails closed the same way the
    # idle path does.
    unknown = controller_type()
    unknown.settings = _cue_settings(idle_screensaver_effect="not-a-real-effect")
    with pytest.raises(CommandError) as missing:
        request_idle_screensaver_peek(unknown)
    assert missing.value.code == "not_found"
    assert not hasattr(unknown, "_idle_screensaver_peek_until")

    # A hand-forged seconds is invalid; a real one clamps into 2…15.
    bad = controller_type()
    bad.settings = _cue_settings(idle_screensaver_effect="rainbow")
    with pytest.raises(CommandError):
        request_idle_screensaver_peek(bad, seconds="a while")
    assert request_idle_screensaver_peek(bad, seconds=600)["seconds"] == 15.0
    assert request_idle_screensaver_peek(bad, seconds=0.1)["seconds"] == 2.0
