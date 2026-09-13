from __future__ import annotations

import pytest

from jrbar.dnd_policy import DisplayAdmission
from jrbar.signal_selection import (
    SIGNAL_CLAIM_PRECEDENCE,
    SignalClaimKey,
    select_active_led_display_kind,
)

EXPECTED_CLAIMS = (
    ("test", "signal_test", False, DisplayAdmission.ALL),
    ("escalation", "escalation", False, DisplayAdmission.ASKS),
    ("low_battery", "low_battery", False, DisplayAdmission.CRITICAL),
    ("failure", "failure", False, DisplayAdmission.CRITICAL),
    ("quota", "quota_alert", True, DisplayAdmission.ALL),
    ("reminders", "reminders", True, DisplayAdmission.ALL),
    ("completion", "completion", True, DisplayAdmission.ALL),
    ("reset_celebration", "reset_celebration", True, DisplayAdmission.ALL),
    ("connection", "connection_notice", True, DisplayAdmission.ALL),
    ("peek", "peek", True, DisplayAdmission.ALL),
    ("all_clear", "all_clear", True, DisplayAdmission.ALL),
    ("calendar", "calendar", True, DisplayAdmission.ALL),
    ("battery_selected_or_preview", "battery", False, DisplayAdmission.ALL),
    ("studio", "studio", False, DisplayAdmission.ALL),
    ("quota_runway", "quota_runway", False, DisplayAdmission.ALL),
    ("charging_idle", "battery", False, DisplayAdmission.ALL),
)


def _select(
    active: set[SignalClaimKey],
    *,
    signal_policy: str | None = None,
    display_admission: DisplayAdmission = DisplayAdmission.ALL,
    default_claim_admission: DisplayAdmission = DisplayAdmission.ALL,
) -> str | None:
    return select_active_led_display_kind(
        evaluate=lambda key: key in active,
        signal_policy=signal_policy,
        default_display_kind="agent",
        display_admission=display_admission,
        default_claim_admission=default_claim_admission,
    )


def test_signal_claim_precedence_pins_the_exact_current_order_and_metadata__and_2_more() -> None:
    # --- scenario: signal_claim_precedence_pins_the_exact_current_order_and_metadata
    assert tuple(
        (
            spec.key.value,
            spec.display_kind,
            spec.muted_by_asks_only,
            spec.claim_admission,
        )
        for spec in SIGNAL_CLAIM_PRECEDENCE
    ) == EXPECTED_CLAIMS

    # --- scenario: every_earlier_active_claim_wins_over_every_later_active_claim
    for earlier_index in range(len(SIGNAL_CLAIM_PRECEDENCE)):
        earlier = SIGNAL_CLAIM_PRECEDENCE[earlier_index]
        for later_index in range(earlier_index + 1, len(SIGNAL_CLAIM_PRECEDENCE)):
            later = SIGNAL_CLAIM_PRECEDENCE[later_index]
            assert _select({earlier.key, later.key}) == earlier.display_kind, (
                earlier,
                later,
            )

    # --- scenario: evaluation_stops_immediately_after_the_first_active_claim
    evaluated: list[SignalClaimKey] = []
    winning_key = SignalClaimKey.LOW_BATTERY

    def evaluate(key: SignalClaimKey) -> bool:
        evaluated.append(key)
        return key is winning_key

    assert (
        select_active_led_display_kind(
            evaluate=evaluate,
            signal_policy=None,
            default_display_kind="agent",
        )
        == "low_battery"
    )
    assert evaluated == [
        SignalClaimKey.TEST,
        SignalClaimKey.ESCALATION,
        SignalClaimKey.LOW_BATTERY,
    ]



def test_asks_only_skips_exactly_the_existing_courtesy_claims__and_2_more() -> None:
    # --- scenario: asks_only_skips_exactly_the_existing_courtesy_claims
    for spec in SIGNAL_CLAIM_PRECEDENCE:
        if spec.muted_by_asks_only:
            assert _select({spec.key}, signal_policy="asks_only") == "agent", spec

    # --- scenario: asks_only_preserves_critical_pinned_and_ambient_claims
    for spec in SIGNAL_CLAIM_PRECEDENCE:
        if not spec.muted_by_asks_only:
            assert (
                _select({spec.key}, signal_policy="asks_only") == spec.display_kind
            ), spec

    # --- scenario: asks_only_does_not_evaluate_muted_claims
    evaluated: list[SignalClaimKey] = []

    def evaluate(key: SignalClaimKey) -> bool:
        evaluated.append(key)
        if key is SignalClaimKey.QUOTA:
            raise AssertionError("muted claim was evaluated")
        return key is SignalClaimKey.BATTERY_SELECTED_OR_PREVIEW

    assert (
        select_active_led_display_kind(
            evaluate=evaluate,
            signal_policy="asks_only",
            default_display_kind="agent",
        )
        == "battery"
    )
    assert SignalClaimKey.QUOTA not in evaluated



def test_no_active_claim_returns_the_supplied_default__and_2_more() -> None:
    # --- scenario: no_active_claim_returns_the_supplied_default
    assert _select(set()) == "agent"

    # --- scenario: display_admission_filters_claim_capabilities_before_evaluation
    for display_admission, claim_key, expected in (
        (DisplayAdmission.ALL, SignalClaimKey.REMINDERS, "reminders"),
        (DisplayAdmission.CRITICAL, SignalClaimKey.REMINDERS, None),
        (DisplayAdmission.CRITICAL, SignalClaimKey.LOW_BATTERY, "low_battery"),
        (DisplayAdmission.CRITICAL, SignalClaimKey.FAILURE, "failure"),
        (DisplayAdmission.CRITICAL, SignalClaimKey.ESCALATION, "escalation"),
        (DisplayAdmission.ASKS, SignalClaimKey.FAILURE, None),
        (DisplayAdmission.ASKS, SignalClaimKey.ESCALATION, "escalation"),
        (DisplayAdmission.NONE, SignalClaimKey.ESCALATION, None),
    ):
        evaluated: list[SignalClaimKey] = []

        result = select_active_led_display_kind(
            evaluate=lambda key: evaluated.append(key) is None and key is claim_key,
            signal_policy=None,
            default_display_kind="agent",
            display_admission=display_admission,
            default_claim_admission=DisplayAdmission.ALL,
        )

        assert result == expected, (display_admission, claim_key)
        if expected is None:
            assert claim_key not in evaluated

    # --- scenario: standing_agent_truth_uses_its_current_semantic_capability
    for display_admission, standing_admission, expected in (
        (DisplayAdmission.ALL, DisplayAdmission.ALL, "agent"),
        (DisplayAdmission.CRITICAL, DisplayAdmission.ALL, None),
        (DisplayAdmission.CRITICAL, DisplayAdmission.CRITICAL, "agent"),
        (DisplayAdmission.CRITICAL, DisplayAdmission.ASKS, "agent"),
        (DisplayAdmission.ASKS, DisplayAdmission.CRITICAL, None),
        (DisplayAdmission.ASKS, DisplayAdmission.ASKS, "agent"),
        (DisplayAdmission.NONE, DisplayAdmission.ASKS, None),
    ):
        assert (
            _select(
                set(),
                display_admission=display_admission,
                default_claim_admission=standing_admission,
            )
            == expected
        ), (display_admission, standing_admission)



def test_evaluator_exception_is_not_swallowed() -> None:
    failure = RuntimeError("claim failed")

    def evaluate(_key: SignalClaimKey) -> bool:
        raise failure

    with pytest.raises(RuntimeError, match="claim failed") as raised:
        select_active_led_display_kind(
            evaluate=evaluate,
            signal_policy=None,
            default_display_kind="agent",
        )

    assert raised.value is failure
