"""One fact, one rung. What the Capacity card is and is not allowed to say.

The owner's dropdown read:

    Codex · 7d 100% left      resets in 6d 23h · updated 2m ago · partial · Local
    Claude · Claude, last 365 days: 2508 sessions

Three separate rung violations in two rows.

  * A CAPACITY row showed a TRANSCRIPT SESSION COUNT. Claude had no OAuth
    token, so no ceiling at all; the row fell through to the local aggregate,
    which is a different fact of a different kind from a different source, and
    printed it in the slot reserved for a plan limit.
  * The provider title was emitted twice, by two owners who did not know about
    each other -- the view, which owns the title, and the summary line, which
    named the provider again.
  * `partial` and `Local transcripts · N files` describe the transcript scan's
    coverage, not the quota source's. They appeared on the capacity row, and
    again on the row below it.

And on the Codex row, a fourth: `100% left` was not a reading. Codex writes
zero-used with the boundary a full window away when it has nothing to report,
and the boundary slides forward with the wall clock each time it writes one.
The status bar rendered that as a confident percentage -- the same class of
defect as the Spark allowance this codebase already documents.
"""

from __future__ import annotations

import time

from jrbar import usage_stats
from jrbar.capacity_types import ObservationState
from jrbar.provider_capacity import negotiate_provider_capacity_policies
from jrbar.providers import negotiated_provider_sources
from jrbar.usage_view import (
    LocalActivitySection,
    build_provider_usage_view,
)

_NOW = 1_800_000_000.0


def _model(**kwargs):
    defaults = {
        "provider_id": "claude",
        "provider_title": "Claude",
        "windows": (),
        "now": 500.0,
        "reset_now": _NOW,
        "last_success_at": 500.0,
    }
    defaults.update(kwargs)
    provider_id = defaults.pop("provider_id")
    provider_title = defaults.pop("provider_title")
    windows = defaults.pop("windows")
    return build_provider_usage_view(provider_id, provider_title, windows, **defaults)


# --------------------------------------------------------------------------
# A capacity row shows a capacity fact, or says it has none.
# --------------------------------------------------------------------------


def test_a_provider_with_no_ceiling_says_so_instead_of_borrowing_one__and_2_more() -> None:
    # --- scenario: a_provider_with_no_ceiling_says_so_instead_of_borrowing_one
    """The owner's Claude row, exactly: local activity, no quota window."""
    model = _model(
        local_activity=LocalActivitySection(
            summary_text="Last 365 days: 2508 sessions · estimated $1.00",
            detail_text="1 in · 2 cached · 3 out",
            partial=True,
            source_text="Local transcripts · 2707 files · partial",
        ),
    )
    # The capacity rung has no ceiling to show and borrows none from the
    # activity rung.
    assert model.windows == ()
    assert model.missing is False
    # The local aggregate is not lost -- it is on its own rung, where the
    # Settings pane reads it.
    assert "2508 sessions" in model.summary_text

    # --- scenario: the_transcript_scans_coverage_never_qualifies_a_plan_limit
    """`partial` and the file count belong to the scan, not to the ceiling."""
    model = _model(
        provider_id="codex",
        provider_title="Codex",
        windows=(
            {"label": "5-hour", "used_percent": 38.0, "window_minutes": 300},
        ),
        local_activity=LocalActivitySection(
            partial=True,
            source_text="Local transcripts · 2895 files · partial",
        ),
    )
    assert [(w.duration_text, w.percent_remaining) for w in model.windows] == [("5h", 62.0)]
    assert model.partial is True
    assert "2895 files" in model.source_text


def test_a_window_with_no_usable_percentage_carries_no_reading__and_2_more() -> None:
    # --- scenario: a_window_with_no_usable_percentage_carries_no_reading
    model = _model(
        provider_id="codex",
        provider_title="Codex",
        windows=(
            {
                "label": "5-hour",
                "used_percent": "unknown",
                "window_minutes": 300,
                "resets_at": _NOW + 120.0,
            },
        ),
    )
    window = model.windows[0]
    assert window.duration_text == "5h"
    assert window.usage_known is False
    assert window.percent_remaining is None
    assert window.percent_used is None

    # --- scenario: extra_windows_follow_the_same_rule
    model = _model(
        windows=(
            {"label": "5-hour", "used_percent": 10.0, "window_minutes": 300},
            {"label": "Weekly Opus", "used_percent": 88.0, "window_minutes": 10_080},
            {"label": "Weekly Sonnet", "utilization": None, "window_minutes": 10_080,
             "resets_at": _NOW + 600.0},
        ),
    )
    assert [(w.label, w.percent_remaining) for w in model.windows[1:]] == [
        ("Weekly Opus", 12.0),
        ("Weekly Sonnet", None),
    ]

    # --- scenario: the_summary_line_names_the_period_and_never_the_provider
    totals = usage_stats.UsageTotals()
    totals.sessions.add("s1")
    totals.input_tokens = 2_000_000

    line = usage_stats.usage_summary_line(
        totals,
        "sessions",
        period_label="Last 365 days",
    )

    assert line == "Last 365 days: 1 session"
    assert "Claude" not in line



# --------------------------------------------------------------------------
# Never a confident percentage for an unattested reading.
# --------------------------------------------------------------------------


def _codex_descriptor():
    return next(
        row.descriptor
        for row in negotiate_provider_capacity_policies(negotiated_provider_sources())
        if row.descriptor is not None
        and row.descriptor.source == usage_stats.CODEX_QUOTA_SOURCE
    )


def _codex_lanes(payload, *, observed_at=_NOW):
    evidence = usage_stats.codex_capacity_evidence_from_windows(
        _codex_descriptor(),
        usage_stats.codex_windows_from_limits(payload),
        observed_at=observed_at,
    )
    return evidence.lanes


def test_a_window_that_only_says_it_just_opened_reports_no_balance__and_2_more() -> None:
    # --- scenario: a_window_that_only_says_it_just_opened_reports_no_balance
    """The owner's Codex row: used 0.0, boundary exactly one window ahead.

    Every rate-limit record in the live rollout file carried
    `resets_at ~= observed_at + 604800` and `used_percent == 0.0`, while that
    same session consumed 376,434 input tokens. The boundary slid forward with
    the wall clock between records; a real ceiling's does not move.
    """
    lanes = _codex_lanes(
        {
            "primary": {
                "used_percent": 0.0,
                "window_minutes": 10_080,
                "resets_at": _NOW + 604_797.0,
            }
        }
    )

    assert len(lanes) == 1
    assert lanes[0].percent is None
    assert lanes[0].state is ObservationState.NULL

    # --- scenario: a_stationary_boundary_with_nothing_spent_is_still_a_real_reading
    """The suppression must not swallow a genuine untouched allowance."""
    lanes = _codex_lanes(
        {
            "primary": {
                "used_percent": 0.0,
                "window_minutes": 10_080,
                # Two days into a seven-day window: the boundary is fixed and
                # the allowance really is untouched.
                "resets_at": _NOW + 5 * 86_400.0,
            }
        }
    )

    assert lanes[0].percent == 0.0
    assert lanes[0].state is ObservationState.OBSERVED

    # --- scenario: a_nonzero_reading_at_a_fresh_boundary_is_never_suppressed
    lanes = _codex_lanes(
        {
            "primary": {
                "used_percent": 3.0,
                "window_minutes": 300,
                "resets_at": _NOW + 18_000.0,
            }
        }
    )

    assert lanes[0].percent == 3.0
    assert lanes[0].state is ObservationState.OBSERVED



def test_the_model_carries_no_percentage_for_the_suppressed_window__and_2_more() -> None:
    # --- scenario: the_model_carries_no_percentage_for_the_suppressed_window
    """End to end: the placeholder reaches the dropdown as "no reading"."""
    model = _model(
        provider_id="codex",
        provider_title="Codex",
        windows=(
            {
                "label": "primary",
                "used_percent": None,
                "window_minutes": 10_080,
                "resets_at": _NOW + 604_797.0,
            },
        ),
    )
    window = model.windows[0]
    assert window.duration_text == "7d"
    assert window.percent_remaining is None
    assert window.percent_used is None

    # --- scenario: a_weekly_window_under_the_primary_key_binds_to_the_weekly_lane
    """`primary` carrying 10,080 minutes is the WEEKLY ceiling, renamed.

    The card printed "7d" from `window_minutes` while the authority layer had
    the same row filed as `five-hour` from the label. OpenAI removed the 5-hour
    window entirely for about two and a half weeks in 2026, which is exactly
    when a payload like this appears.
    """
    lanes = _codex_lanes(
        {
            "primary": {
                "used_percent": 42.0,
                "window_minutes": 10_080,
                "resets_at": _NOW + 200_000.0,
            }
        }
    )

    assert tuple(lane.key.window for lane in lanes) == ("weekly",)

    # --- scenario: the_ordinary_pair_still_binds_the_way_it_always_did
    lanes = _codex_lanes(
        {
            "primary": {"used_percent": 25.0, "window_minutes": 300},
            "secondary": {"used_percent": 70.0, "window_minutes": 10_080},
        }
    )

    assert tuple(lane.key.window for lane in lanes) == ("five-hour", "weekly")



def test_a_declared_label_carrying_an_undeclared_window_is_dropped__and_2_more() -> None:
    # --- scenario: a_declared_label_carrying_an_undeclared_window_is_dropped
    """Force-fitting an unknown length is how the 7d/5h mismatch happened."""
    lanes = _codex_lanes(
        {"primary": {"used_percent": 25.0, "window_minutes": 1_440}}
    )

    assert lanes == ()

    # --- scenario: an_undeclared_label_is_still_dropped_whatever_its_length
    """The Spark rule, unchanged: length decides WHICH lane, never WHETHER."""
    lanes = _codex_lanes(
        {
            "additional_rate_limits": [
                {
                    "name": "GPT-5.3-Codex-Spark",
                    "used_percent": 97.0,
                    "window_minutes": 300,
                }
            ]
        }
    )

    assert lanes == ()

    # --- scenario: a_window_with_no_stated_length_falls_back_to_its_label
    lanes = _codex_lanes({"secondary": {"used_percent": 12.0}})

    assert tuple(lane.key.window for lane in lanes) == ("weekly",)



def test_time_moves_but_the_suppression_rule_does_not_depend_on_the_clock() -> None:
    """Guard against a rule that only holds at one instant."""
    for offset in (0.0, 1.0, 3_600.0, 86_400.0):
        observed = time.time() + offset
        lanes = _codex_lanes(
            {
                "primary": {
                    "used_percent": 0.0,
                    "window_minutes": 10_080,
                    "resets_at": observed + 604_800.0,
                }
            },
            observed_at=observed,
        )
        assert lanes[0].percent is None
