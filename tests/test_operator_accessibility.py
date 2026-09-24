from __future__ import annotations

from dataclasses import FrozenInstanceError, replace

import pytest

from jrbar.capacity_types import SourceKey
from jrbar.operator_accessibility import (
    MAX_ACCESSIBILITY_HELP_LENGTH,
    MAX_ACCESSIBILITY_LABEL_LENGTH,
    MAX_ACCESSIBILITY_VALUE_LENGTH,
    AccessibilityText,
    FocusSnapshot,
    normalize_semantic_text_scale,
    status_item_accessibility,
)
from jrbar.operator_state import (
    AcknowledgementEligibility,
    CanonicalRequestTruth,
    CanonicalWorkTruth,
    RequestPhase,
    SemanticEventKey,
    TransitionKind,
    empty_operator_state,
)
from jrbar.presentation_policy import (
    FiniteCue,
    FiniteCueState,
    GlanceOverrideReason,
    GlanceSemantic,
    ResolvedGlance,
    SemanticGlyph,
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

_GLYPH_BY_SEMANTIC = {
    GlanceSemantic.ATTENTION: SemanticGlyph.FULL_ANCHOR,
    GlanceSemantic.FRESH_FAILURE: SemanticGlyph.LEFT_ANCHOR,
    GlanceSemantic.FRESH_COMPLETION: SemanticGlyph.RIGHT_ANCHOR,
    GlanceSemantic.ACTIVE: SemanticGlyph.CENTER_PAIR,
    GlanceSemantic.UNRESOLVED_FAILURE: SemanticGlyph.LEFT_ANCHOR,
    GlanceSemantic.CAPACITY: SemanticGlyph.CAPACITY_FILL,
    GlanceSemantic.REST: SemanticGlyph.REST,
}


def _source(*, provider: str = "codex", instance: str = "local.01") -> SourceKey:
    return SourceKey(provider, "local", instance, "sessions")


def _watermark(source: SourceKey, *, rank: int = 1) -> ProviderWatermark:
    return ProviderWatermark(
        source_key=source,
        basis=WatermarkBasis.OCCURRED_AT_TIE_BREAK,
        occurred_at_epoch=1_800_000_000.0 + rank,
        event_token=EventToken(f"event:{rank}"),
        sequence=None,
        tie_break_rank=rank,
    )


def _operator_state(
    *,
    lifecycle: WorkLifecycle = WorkLifecycle.IDLE,
    freshness: SourceFreshness = SourceFreshness.FRESH,
    request_phase: RequestPhase | None = None,
    safe_label: str = "Codex work:01",
    timing_uncertain: bool = False,
):
    source = _source()
    work_key = WorkKey(source, WorkIdentifier("work:01"))
    watermark = _watermark(source)
    requests = ()
    request_keys = ()
    if request_phase is not None:
        request_key = RequestKey(work_key, RequestIdentifier("request:01"))
        eligibility = {
            RequestPhase.LIVE_UNACKNOWLEDGED: AcknowledgementEligibility.ELIGIBLE,
            RequestPhase.LIVE_ACKNOWLEDGED: AcknowledgementEligibility.ALREADY_ACKNOWLEDGED,
            RequestPhase.STALE_HOLD: AcknowledgementEligibility.STALE_HOLD,
            RequestPhase.RESOLVED: AcknowledgementEligibility.RESOLVED,
            RequestPhase.UNKNOWN_EXPIRED: AcknowledgementEligibility.RESOLVED,
        }[request_phase]
        semantic_key = SemanticEventKey(
            request_key,
            TransitionKind.REQUEST_OPENED,
            watermark,
        )
        requests = (
            CanonicalRequestTruth(
                key=request_key,
                phase=request_phase,
                request_kind=RequestKind.INPUT,
                next_actor=NextActor.USER,
                watermark=watermark,
                source_freshness=freshness,
                acknowledgement_eligibility=eligibility,
                semantic_event_key=semantic_key,
                opened_at_epoch=1_800_000_000.0,
                eligible_elapsed_seconds=5.0,
            ),
        )
        request_keys = (request_key,)
    work = CanonicalWorkTruth(
        key=work_key,
        lifecycle=lifecycle,
        watermark=watermark,
        observation_authority=ObservationAuthority.AUTHORITATIVE_PROVIDER,
        source_health=(SourceHealth.HEALTHY if freshness is SourceFreshness.FRESH else SourceHealth.UNAVAILABLE),
        source_freshness=freshness,
        next_actor=(NextActor.USER if request_phase is not None else NextActor.PROVIDER),
        safe_label=safe_label,
        parent_key=None,
        request_keys=request_keys,
        timing_uncertain=timing_uncertain,
    )
    state = replace(
        empty_operator_state(),
        generation=1,
        works=(work,),
        requests=requests,
    )
    return state, work, (requests[0] if requests else None)


def _glance(
    semantic: GlanceSemantic,
    *,
    override: GlanceOverrideReason = GlanceOverrideReason.NONE,
    cue: FiniteCue | None = None,
) -> ResolvedGlance:
    return ResolvedGlance(
        semantic=semantic,
        glyph=_GLYPH_BY_SEMANTIC[semantic],
        cue=cue,
        override_reason=override,
        relay_epoch=10.0,
        next_visual_change_at=None,
    )


def _all_text(text: AccessibilityText) -> str:
    return " ".join((text.label, text.value, text.help))


def test_accessibility_records_are_frozen_and_reject_blank_or_unbounded_text__and_2_more() -> None:
    # --- scenario: accessibility_records_are_frozen_and_reject_blank_or_unbounded_text
    text = AccessibilityText("JR-Bar", "No agents need attention", "Open JR-Bar status")
    focus = FocusSnapshot("agent-browser", "search", None, (3, 2), "agents")

    with pytest.raises(FrozenInstanceError):
        text.value = ""  # type: ignore[misc]
    with pytest.raises(FrozenInstanceError):
        focus.control_key = None  # type: ignore[misc]
    with pytest.raises(ValueError):
        AccessibilityText("", "value", "help")
    with pytest.raises(ValueError):
        AccessibilityText("x" * (MAX_ACCESSIBILITY_LABEL_LENGTH + 1), "value", "help")

    # --- scenario: semantic_text_scale_accepts_only_the_five_exact_percentage_choices
    for choice, expected in ((100, 1.0), (125, 1.25), (150, 1.5), (175, 1.75), (200, 2.0)):
        assert normalize_semantic_text_scale(choice) == expected

    # --- scenario: invalid_semantic_text_scale_normalizes_to_one_hundred_percent
    for invalid in (None, True, False, 0, 99, 201, 125.0, 1.25, "125", float("nan"), object()):
        assert normalize_semantic_text_scale(invalid) == 1.0


def test_status_item_has_stable_role_text_and_nonblank_value_for_every_glance__and_2_more() -> None:
    # --- scenario: status_item_has_stable_role_text_and_nonblank_value_for_every_glance
    for semantic, expected_phrase in (
        (GlanceSemantic.ATTENTION, "Needs your attention"),
        (GlanceSemantic.FRESH_FAILURE, "New failure"),
        (GlanceSemantic.FRESH_COMPLETION, "Agent completed"),
        (GlanceSemantic.ACTIVE, "Agents active"),
        (GlanceSemantic.UNRESOLVED_FAILURE, "Failure needs review"),
        (GlanceSemantic.CAPACITY, "Capacity status available"),
        (GlanceSemantic.REST, "No agents need attention"),
    ):
        state, _, _ = _operator_state()

        result = status_item_accessibility(state, _glance(semantic))

        assert result.label == "JR-Bar"
        assert result.help == "Open JR-Bar status"
        assert expected_phrase in result.value
        assert result.value.strip()
        assert len(result.value) <= MAX_ACCESSIBILITY_VALUE_LENGTH

    # --- scenario: status_item_preserves_stale_acknowledged_quiet_and_finite_cue_truth
    state, _, _ = _operator_state(
        lifecycle=WorkLifecycle.WAITING,
        freshness=SourceFreshness.STALE,
        request_phase=RequestPhase.LIVE_ACKNOWLEDGED,
    )
    active = FiniteCue("attention:1", GlanceSemantic.ATTENTION, 1, 1.0)
    pending = FiniteCue("completion:1", GlanceSemantic.FRESH_COMPLETION, 1, 1.0)
    finite = FiniteCueState(active, pending, 11.0, True)

    result = status_item_accessibility(
        state,
        _glance(
            GlanceSemantic.ATTENTION,
            override=GlanceOverrideReason.SHARED_SPACE_PRIVACY,
            cue=active,
        ),
        finite_cues=finite,
    )

    assert result.label == "JR-Bar"
    assert result.help == "Open JR-Bar status"
    assert "Acknowledged locally" in result.value
    assert "Source stale" in result.value
    assert "Quiet presentation" in result.value
    assert "Brief status cue" in result.value
    assert "Additional updates waiting" in result.value
    assert result.value.strip()


def test_focus_snapshot_rejects_invalid_text_selection() -> None:
    # --- scenario: focus_snapshot_rejects_invalid_text_selection
    for invalid_selection in ((-1, 0), (0, -1), (True, 0), (0, 1.5), (0,), [0, 0]):
        with pytest.raises(ValueError):
            FocusSnapshot(
                "agent-browser",
                "search",
                None,
                invalid_selection,  # type: ignore[arg-type]
                "agents",
            )


def test_all_public_helpers_return_nonempty_bounded_privacy_safe_text() -> None:
    texts = (
        status_item_accessibility(empty_operator_state(), _glance(GlanceSemantic.REST)),
    )

    for semantic_text in texts:
        assert semantic_text.label.strip()
        assert semantic_text.value.strip()
        assert semantic_text.help.strip()
        assert len(semantic_text.label) <= MAX_ACCESSIBILITY_LABEL_LENGTH
        assert len(semantic_text.value) <= MAX_ACCESSIBILITY_VALUE_LENGTH
        assert len(semantic_text.help) <= MAX_ACCESSIBILITY_HELP_LENGTH
        rendered = _all_text(semantic_text).casefold()
        for forbidden in (
            "nightingale",
            "/users/",
            "sk-live-secret",
            "prompt:delete-files",
        ):
            assert forbidden not in rendered
