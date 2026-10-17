from __future__ import annotations

import pytest

from jrbar.claude_quota import windows_from_payload
from jrbar.provider_usage_parsers import (
    parse_antigravity_usage,
    parse_claude_usage,
    parse_codex_usage,
    parse_cursor_usage,
    parse_devin_usage,
    parse_gemini_usage,
    parse_grok_usage,
    parse_openai_api_usage,
)
from jrbar.provider_usage_platform import ProviderSourceState


def test_codex_preserves_spark_weekly_as_a_dynamic_lane__and_2_more() -> None:
    # --- scenario: codex_preserves_spark_weekly_as_a_dynamic_lane
    snapshot = parse_codex_usage(
        windows=[
            {
                "label": "primary",
                "used_percent": 30,
                "window_minutes": 300,
                "resets_at": 2000,
            },
            {
                "label": "secondary",
                "used_percent": 40,
                "window_minutes": 10080,
                "resets_at": 3000,
            },
            {
                "label": "Spark Weekly",
                "used_percent": 75,
                "window_minutes": 10080,
                "resets_at": 3000,
            },
        ],
        observed_at=1000,
        input_tokens=100,
        cached_input_tokens=25,
        output_tokens=50,
        model_count=2,
        estimated_cost_usd=1.5,
    )
    by_label = {lane.label: lane for lane in snapshot.lanes}
    assert by_label["5-hour"].remaining_percent == 70
    assert by_label["Weekly"].remaining_percent == 60
    assert by_label["Spark Weekly"].remaining_percent == 25
    assert by_label["Spark Weekly"].bindable is False
    assert snapshot.model_count == 2

    # --- scenario: claude_preserves_fable_and_model_scoped_windows
    snapshot = parse_claude_usage(
        windows=[
            {"label": "5-hour", "used_percent": 10, "resets_at": 2000},
            {"label": "weekly", "used_percent": 20, "resets_at": 3000},
            {"label": "Fable only", "used_percent": 80, "resets_at": 3000},
        ],
        observed_at=1000,
    )
    fable = next(lane for lane in snapshot.lanes if lane.model == "fable")
    assert fable.label == "Fable only"
    assert fable.remaining_percent == 20
    assert fable.bindable is False

    # --- scenario: cursor_usage_summary_maps_plan_auto_api_and_extra_spend
    snapshot = parse_cursor_usage(
        {
            "planUsage": {"usedPercent": 35},
            "autoComposerUsage": {"usedPercent": 20},
            "apiUsage": {"usedPercent": 5},
            "billingCycleEnd": "2026-09-01T00:00:00Z",
            "extraUsageCents": 1234,
            "account": {"email": "person@example.com"},
        },
        observed_at=1000,
    )
    assert [lane.label for lane in snapshot.lanes] == [
        "Included plan",
        "Auto + Composer",
        "API models",
    ]
    assert snapshot.lanes[0].remaining_percent == 65
    assert snapshot.estimated_cost_usd == 12.34
    assert snapshot.account_label == "person@example.com"



def test_devin_maps_daily_and_weekly_windows__and_2_more() -> None:
    # --- scenario: devin_maps_daily_and_weekly_windows
    snapshot = parse_devin_usage(
        {
            "daily": {"used_percent": 25, "resets_at": 2000},
            "weekly": {"used_percent": 60, "resets_at": 3000},
            "organization": "org_example",
        },
        observed_at=1000,
    )
    assert [(lane.label, lane.remaining_percent) for lane in snapshot.lanes] == [
        ("Daily", 75),
        ("Weekly", 40),
    ]
    assert snapshot.account_label == "org_example"

    # --- scenario: grok_maps_cli_proxy_credit_usage_and_reset
    snapshot = parse_grok_usage(
        {
            "config": {
                "creditUsagePercent": 72,
                "currentPeriod": {"end": "2026-09-01T00:00:00Z"},
            },
            "email": "person@example.com",
        },
        observed_at=1000,
    )
    assert snapshot.lanes[0].label in {"Weekly", "Monthly", "Credits"}
    assert snapshot.lanes[0].remaining_percent == 28
    assert snapshot.account_label == "person@example.com"

    # --- scenario: antigravity_maps_four_summary_buckets
    snapshot = parse_antigravity_usage(
        {
            "response": {
                "groups": [
                    {
                        "displayName": "Gemini Models",
                        "buckets": [
                            {
                                "bucketId": "session-five-hour",
                                "displayName": "Session",
                                "remaining": {"remainingFraction": 0.4},
                                "resetTime": 2000,
                            },
                            {
                                "bucketId": "weekly",
                                "displayName": "Weekly",
                                "remaining": {"remainingFraction": 0.8},
                                "resetTime": 3000,
                            },
                        ],
                    },
                    {
                        "displayName": "Claude and GPT models",
                        "buckets": [
                            {
                                "bucketId": "session-five-hour",
                                "displayName": "Session",
                                "remaining": {"remainingFraction": 0.5},
                                "resetTime": 2000,
                            },
                            {
                                "bucketId": "weekly",
                                "displayName": "Weekly",
                                "remaining": {"remainingFraction": 0.7},
                                "resetTime": 3000,
                            },
                        ],
                    },
                ]
            }
        },
        observed_at=1000,
    )
    assert [lane.label for lane in snapshot.lanes] == [
        "Gemini Session",
        "Gemini Weekly",
        "Claude + GPT Session",
        "Claude + GPT Weekly",
    ]
    assert snapshot.lanes[0].remaining_percent == 40



def test_openai_usage_aggregates_tokens_models_requests_and_cost__and_2_more() -> None:
    # --- scenario: openai_usage_aggregates_tokens_models_requests_and_cost
    snapshot = parse_openai_api_usage(
        {
            "usage": {
                "data": [
                    {
                        "results": [
                            {
                                "input_tokens": 100,
                                "output_tokens": 50,
                                "num_model_requests": 2,
                                "model": "gpt-5.4",
                            },
                            {
                                "input_tokens": 25,
                                "output_tokens": 10,
                                "num_model_requests": 1,
                                "model": "gpt-5.3",
                            },
                        ]
                    }
                ]
            },
            "costs": {"data": [{"results": [{"amount": {"value": 2.75}}]}]},
        },
        observed_at=1000,
    )
    assert snapshot.input_tokens == 125
    assert snapshot.output_tokens == 60
    assert snapshot.model_count == 2
    assert snapshot.estimated_cost_usd == 2.75

    # --- scenario: claude_reads_the_utilization_key_claude_quota_actually_emits
    snapshot = parse_claude_usage(
        windows=[
            {"label": "5-hour", "utilization": 26.0, "resets_at": 2000,
             "window_minutes": 300},
            {"label": "weekly", "utilization": 11.5, "resets_at": 3000,
             "window_minutes": 10080},
        ],
        observed_at=1000,
    )
    by_label = {lane.label: lane for lane in snapshot.lanes}
    assert by_label["5-hour"].remaining_percent == 74.0
    assert by_label["Weekly"].remaining_percent == 88.5

    # --- scenario: codex_merged_account_weekly_primary_is_labeled_weekly
    snapshot = parse_codex_usage(
        windows=[
            {"label": "primary", "used_percent": 3.0,
             "window_minutes": 10080, "resets_at": 1787846584},
        ],
        observed_at=1000,
    )
    assert [lane.label for lane in snapshot.lanes] == ["Weekly"]
    assert snapshot.lanes[0].lane_id == "weekly"
    assert snapshot.lanes[0].remaining_percent == 97.0
    # And a true 5-hour primary still lands where it always did.
    classic = parse_codex_usage(
        windows=[
            {"label": "primary", "used_percent": 30.0,
             "window_minutes": 300, "resets_at": 2000},
            {"label": "secondary", "used_percent": 12.0,
             "window_minutes": 10080, "resets_at": 3000},
        ],
        observed_at=1000,
    )
    assert [lane.label for lane in classic.lanes] == ["5-hour", "Weekly"]



def test_devin_reads_the_flat_shape_the_endpoint_actually_returns__and_2_more() -> None:
    # --- scenario: devin_reads_the_flat_shape_the_endpoint_actually_returns
    """The live payload is flat -- {"daily_percentage": 80, ...} -- not a
    nested per-window object. Reading only the nested shape meant a
    correctly authenticated card showed zero lanes, so completing the
    API-key dance could not have paid off either."""
    snapshot = parse_devin_usage(
        {
            "daily_percentage": 80,
            "weekly_percentage": 40,
            "daily_reset_at": "2026-08-23T00:00:00-08:00",
            "weekly_reset_at": "2026-08-23T00:00:00-08:00",
            "organization": "org/acme",
        },
        observed_at=1000,
    )
    lanes = {lane.lane_id: lane for lane in snapshot.lanes}
    assert lanes["daily"].remaining_percent == 20.0
    assert lanes["weekly"].remaining_percent == 60.0
    assert lanes["daily"].reset_at is not None

    # --- scenario: devin_reads_a_fraction_as_a_share_not_a_percent
    snapshot = parse_devin_usage({"daily_percentage": 0.8}, observed_at=1000)
    assert abs(snapshot.lanes[0].remaining_percent - 20.0) < 1e-9

    # --- scenario: devin_still_reads_the_nested_shape
    snapshot = parse_devin_usage(
        {"daily": {"used_percent": 10, "resets_at": 2000}}, observed_at=1000
    )
    assert snapshot.lanes[0].remaining_percent == 90.0



# --- One window named twice must not discard the whole reading ---------------

#: The shape the usage endpoint answers: the named top-level windows and the
#: newer limits[] array, which repeats the same model's weekly cap.
_CLAUDE_PAYLOAD_NAMING_SONNET_TWICE = {
    "five_hour": {"utilization": 42.0, "resets_at": "2026-10-01T12:00:00Z"},
    "seven_day": {"utilization": 61.0, "resets_at": "2026-10-05T00:00:00Z"},
    "seven_day_sonnet": {"utilization": 12.0, "resets_at": "2026-10-05T00:00:00Z"},
    "limits": [
        {
            "kind": "weekly_scoped",
            "group": "weekly",
            "percent": 12.0,
            "resets_at": "2026-10-05T00:00:00Z",
            "scope": {"model": {"id": "claude-sonnet", "display_name": "Sonnet"}},
        },
    ],
}


def test_a_claude_window_named_twice_keeps_the_first_lane_and_the_reading() -> None:
    windows = windows_from_payload(_CLAUDE_PAYLOAD_NAMING_SONNET_TWICE)
    # The payload really does hand over the same window twice.
    assert [window["label"] for window in windows].count("Sonnet only") == 2

    snapshot = parse_claude_usage(windows=windows, observed_at=1000.0)

    assert snapshot.state is ProviderSourceState.READY
    assert [lane.lane_id for lane in snapshot.lanes] == [
        "five-hour",
        "weekly",
        "sonnet-only",
    ]
    assert snapshot.lanes[2].remaining_percent == 88.0


def test_two_different_claude_windows_under_one_name_are_both_kept_but_only_the_first_binds() -> None:
    windows = [
        {"label": "weekly", "utilization": 61.0, "resets_at": "2026-10-05T00:00:00Z"},
        {"label": "limit", "utilization": 3.0, "resets_at": "2026-10-05T00:00:00Z"},
        {"label": "limit", "utilization": 4.0, "resets_at": "2026-10-06T00:00:00Z"},
        {"label": "limit", "utilization": 3.0, "resets_at": "2026-10-05T00:00:00Z"},
    ]

    snapshot = parse_claude_usage(windows=windows, observed_at=1000.0)

    assert [lane.lane_id for lane in snapshot.lanes] == ["weekly", "limit", "limit-2"]
    first, second = snapshot.lanes[1], snapshot.lanes[2]
    assert (first.label, first.remaining_percent) == ("limit", 97.0)
    # The window that differs is shown, under a name that says it is another,
    # and it is never one the lights can follow.
    assert (second.label, second.remaining_percent) == ("limit (2)", 96.0)
    assert second.bindable is False


def test_a_codex_window_named_twice_keeps_one_lane() -> None:
    window = {
        "label": "primary",
        "used_percent": 30,
        "window_minutes": 300,
        "resets_at": 2000,
    }

    snapshot = parse_codex_usage(windows=[window, dict(window)], observed_at=1000)

    assert [lane.lane_id for lane in snapshot.lanes] == ["five-hour"]
    assert snapshot.lanes[0].bindable is True


def test_a_gemini_model_with_two_buckets_keeps_the_first_lane() -> None:
    payload = {
        "buckets": [
            {"modelId": "gemini-2.5-pro", "tokenType": "REQUESTS", "remainingFraction": 0.5,
             "resetTime": "2026-10-02T00:00:00Z"},
            {"modelId": "gemini-2.5-pro", "tokenType": "REQUESTS", "remainingFraction": 0.5,
             "resetTime": "2026-10-02T00:00:00Z"},
            {"modelId": "gemini-2.5-flash", "remainingFraction": 0.9,
             "resetTime": "2026-10-02T00:00:00Z"},
        ]
    }

    snapshot = parse_gemini_usage(payload, observed_at=1000.0)

    assert [lane.lane_id for lane in snapshot.lanes] == [
        "model-gemini-2-5-pro",
        "model-gemini-2-5-flash",
    ]
    assert snapshot.model_count == 2


def test_a_reset_in_epoch_milliseconds_reads_as_the_same_moment_in_seconds() -> None:
    # A provider that stamps its reset in milliseconds must not push the
    # boundary ~55,000 years out ("resets in 20,000,000 days").
    seconds = 1_760_000_000
    for value in (seconds, seconds * 1000, float(seconds * 1000)):
        snapshot = parse_cursor_usage(
            {"planUsage": {"usedPercent": 35}, "billingCycleEnd": value},
            observed_at=1000,
        )
        assert snapshot.lanes[0].reset_at == seconds


def _antigravity_summary(*buckets: dict) -> dict:
    return {"response": {"groups": [{"displayName": "Gemini Models", "buckets": list(buckets)}]}}


def test_an_antigravity_bucket_states_its_own_cadence() -> None:
    # A bucket whose name says nothing about its length ("Limit Remaining")
    # but whose `window` field says weekly is a weekly lane, never a 5-hour one.
    snapshot = parse_antigravity_usage(
        _antigravity_summary(
            {
                "bucketId": "gemini-allowance",
                "displayName": "Limit Remaining",
                "window": "weekly",
                "remainingFraction": 0.8,
                "resetTime": 3000,
            }
        ),
        observed_at=1000,
    )
    assert [(lane.label, lane.remaining_percent) for lane in snapshot.lanes] == [
        ("Gemini Weekly", 80)
    ]


def test_an_antigravity_bucket_cadence_beats_a_misleading_name() -> None:
    snapshot = parse_antigravity_usage(
        _antigravity_summary(
            {
                "bucketId": "gemini-5h",
                "displayName": "Weekly-style label",
                "window": "5h",
                "remainingFraction": 0.5,
                "resetTime": 2000,
            }
        ),
        observed_at=1000,
    )
    assert [lane.label for lane in snapshot.lanes] == ["Gemini 5-Hour"]


def test_a_weekly_only_antigravity_starter_account_gets_no_invented_five_hour_lane() -> None:
    snapshot = parse_antigravity_usage(
        {
            "response": {
                "groups": [
                    {
                        "displayName": "Gemini Models",
                        "buckets": [
                            {"bucketId": "g", "displayName": "Weekly Limit", "window": "weekly",
                             "remainingFraction": 1, "resetTime": 3000},
                        ],
                    },
                    {
                        "displayName": "Claude and GPT models",
                        "buckets": [
                            {"bucketId": "c", "displayName": "Weekly Limit", "window": "weekly",
                             "remainingFraction": 1, "resetTime": 3000},
                        ],
                    },
                ]
            }
        },
        observed_at=1000,
    )
    assert [lane.label for lane in snapshot.lanes] == ["Gemini Weekly", "Claude + GPT Weekly"]


def test_reported_antigravity_argon_pool_keeps_independent_limits_and_resets():
    # Synthetic fields follow Antigravity 2.23.1's embedded quota_summary.proto.
    groups = [
        {"displayName": "Gemini Models", "buckets": [
            {"bucketId": "gemini-week", "window": "weekly", "remainingFraction": 0.8, "resetTime": 3000},
        ]},
        {"displayName": "Gemini 4 Argon", "buckets": [
            {"bucketId": "argon-week", "window": "weekly", "remainingFraction": 0.3, "resetTime": 4000},
            {"bucketId": "argon-short", "window": "5h", "remainingFraction": 0.6, "resetTime": 2000},
        ]},
    ]
    reading = parse_antigravity_usage({"response": {"groups": groups}}, observed_at=1000)
    assert [(lane.lane_id, lane.remaining_percent, lane.reset_at) for lane in reading.lanes] == [
        ("gemini-weekly", 80, 3000),
        ("gemini-argon-weekly", 30, 4000),
        ("gemini-argon-five-hour", 60, 2000),
    ]
    assert reading.lanes[1].scope == "gemini-argon"
    assert reading.lanes[1].model == "gemini-4-argon"
    assert reading.lanes[1].label == "Gemini 4 Argon Weekly"


def test_reported_argon_only_group_is_not_dropped():
    reading = parse_antigravity_usage({"response": {"groups": [
        {"displayName": "Argon", "buckets": [
            {"bucketId": "weekly", "window": "weekly", "remainingFraction": 0.4},
        ]},
    ]}}, observed_at=1000)
    assert [(lane.lane_id, lane.remaining_percent) for lane in reading.lanes] == [
        ("gemini-argon-weekly", 40),
    ]


@pytest.mark.parametrize("group,bucket_id,bucket_name", [
    ("Gemini Models", "gemini-4-argon-high-weekly", "Weekly limit"),
    ("Gemini Models", "separate-weekly", "Argon weekly limit"),
])
def test_argon_bucket_identity_can_report_a_separate_pool(group, bucket_id, bucket_name):
    reading = parse_antigravity_usage({"groups": [{"displayName": group, "buckets": [{
        "bucketId": bucket_id, "displayName": bucket_name, "window": "weekly", "remainingFraction": 0.2,
    }]}]}, observed_at=1000)
    assert [(lane.lane_id, lane.remaining_percent) for lane in reading.lanes] == [
        ("gemini-argon-weekly", 20),
    ]


def test_unknown_quota_names_do_not_create_argon_and_duplicate_pools_fail_closed():
    bucket = {"bucketId": "weekly", "window": "weekly", "remainingFraction": 0.4}
    unknown = {"displayName": "Argonaut models", "buckets": [bucket]}
    assert parse_antigravity_usage({"groups": [unknown]}, observed_at=1000).lanes == ()
    argon = {"displayName": "Argon", "buckets": [bucket]}
    with pytest.raises(ValueError, match="duplicate usage lane"):
        parse_antigravity_usage({"groups": [argon, argon]}, observed_at=1000)


@pytest.mark.parametrize("bucket", [
    {"bucketId": "argon-allowance", "displayName": "Limit Remaining"},
    {"bucketId": "argon-allowance", "displayName": "Limit Remaining", "window": "daily"},
])
def test_argon_without_a_reported_cadence_does_not_invent_a_five_hour_lane(bucket):
    reading = parse_antigravity_usage({"groups": [
        {"displayName": "Gemini Models", "buckets": [
            {"bucketId": "weekly", "window": "weekly", "remainingFraction": 0.8},
        ]},
        {"displayName": "Gemini 4 Argon", "buckets": [dict(bucket, remainingFraction=0.3)]},
    ]}, observed_at=1000)
    assert [lane.lane_id for lane in reading.lanes] == ["gemini-weekly"]


@pytest.mark.parametrize("label", ["5h", "5-Hour Limit", "Five Hour Limit Remaining"])
def test_argon_five_hour_name_can_state_its_cadence(label):
    reading = parse_antigravity_usage({"groups": [{"displayName": "Gemini 4 Argon", "buckets": [
        {"bucketId": "argon-allowance", "displayName": label, "remainingFraction": 0.3},
    ]}]}, observed_at=1000)
    assert [lane.lane_id for lane in reading.lanes] == ["gemini-argon-five-hour"]
