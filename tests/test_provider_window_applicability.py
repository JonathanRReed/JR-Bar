"""Which windows an account HAS, and the three states a window can be in.

The owner's report: "I noticed that Codex had a five-hour limit. I'm on the
Pro plan, so I don't have that, but we need it so that if you are not on the
Pro plan, it is still there for the users that do."

Codex reports several limit FAMILIES side by side, and every family uses the
same ``primary``/``secondary`` key names. On this Pro account the account
family (``limitId: "codex"``) states ``secondary: null`` and a ``primary`` of
10,080 minutes -- a weekly ceiling and no 5-hour window at all -- while the
model-scoped ``codex_bengalfox`` family (GPT-5.3-Codex-Spark) has a
300-minute ``primary``. Reading that Spark window as the account's ceiling
put a red "5-hour · 100%" on a row for a window the plan does not have.

Every payload here was captured from the real CLI/endpoint; see
``tests/fixtures/provider_usage/README.md``.
"""

from __future__ import annotations

import json
from pathlib import Path

from jrbar import claude_quota, usage_stats
from jrbar.provider_reconnect import codex_app_server_probe
from jrbar.provider_usage_parsers import parse_claude_usage, parse_codex_usage
from jrbar.provider_usage_platform import ProviderSourceState, ProviderUsageSnapshot

FIXTURES = Path(__file__).parent / "fixtures" / "provider_usage"


def _fixture(name: str) -> dict:
    return json.loads((FIXTURES / name).read_text(encoding="utf-8"))


def _probe(payload: dict) -> dict:
    """Drive the real probe parser with a scripted app-server transcript."""
    lines = [
        json.dumps({"jsonrpc": "2.0", "id": 1, "result": {"userAgent": "codex/0.153.4 mac"}}),
        json.dumps({"jsonrpc": "2.0", "id": 2, "result": payload}),
        json.dumps({"jsonrpc": "2.0", "id": 3, "result": {"account": {"email": "a@b.c"}}}),
    ]
    result = codex_app_server_probe(runner=lambda: "\n".join(lines))
    assert result is not None
    return result


def _lanes(probe: dict) -> dict[str, object]:
    snapshot = parse_codex_usage(
        windows=probe["windows"],
        observed_at=1_789_073_144.0,
        account_plan=probe["plan"],
        source_id="codex-app-server",
    )
    return {lane.lane_id: lane for lane in snapshot.lanes}


# --------------------------------------------------------------------------
# A window the account does not have never becomes a lane.
# --------------------------------------------------------------------------


def test_a_pro_account_gets_a_weekly_lane_and_no_five_hour_lane() -> None:
    probe = _probe(_fixture("codex-app-server-rate-limits-pro.json"))

    assert probe["plan"] == "pro"
    lanes = _lanes(probe)

    assert "five-hour" not in lanes
    assert lanes["weekly"].remaining_percent == 0.0
    assert lanes["weekly"].reset_at == 1_789_440_279.0
    assert lanes["weekly"].bindable is True


def test_a_plan_that_has_a_five_hour_window_still_gets_one() -> None:
    """The half the owner asked to keep working for everyone else."""
    probe = _probe(_fixture("codex-app-server-rate-limits-plus.json"))

    assert probe["plan"] == "plus"
    lanes = _lanes(probe)

    assert lanes["five-hour"].remaining_percent == 70.0
    assert lanes["five-hour"].label == "5-hour"
    assert lanes["five-hour"].bindable is True
    assert lanes["weekly"].remaining_percent == 38.0


def test_an_explicit_null_secondary_emits_nothing_at_all() -> None:
    """`"secondary": null` is Codex STATING the plan has no second window."""
    windows = usage_stats.codex_windows_from_limits(
        {"limitId": "codex", "primary": {"usedPercent": 12, "windowDurationMins": 10080},
         "secondary": None}
    )

    assert [window["window_minutes"] for window in windows] == [10080]
    assert all(window["account_limit"] for window in windows)


# --------------------------------------------------------------------------
# A model-scoped sub-cap is never the account's ceiling.
# --------------------------------------------------------------------------


def test_the_spark_family_keeps_its_own_lanes_and_claims_no_account_lane() -> None:
    probe = _probe(_fixture("codex-app-server-rate-limits-pro.json"))
    lanes = _lanes(probe)

    assert lanes["spark-five-hour"].label == "Spark 5-hour"
    assert lanes["spark-five-hour"].model == "spark"
    assert lanes["spark-five-hour"].bindable is False
    assert lanes["spark-weekly"].remaining_percent == 15.0
    # The Spark 5-hour window and the account's missing one are not the
    # same row, and only one of them exists.
    assert "five-hour" not in lanes


def test_a_spark_rollout_alone_never_produces_an_account_five_hour_lane() -> None:
    """The exact evidence that produced the owner's phantom row.

    A rollout file carries one family per record. This one is Spark's, and
    its 300-minute `primary` used to be filed as the account's 5-hour lane.
    """
    windows = usage_stats.codex_windows_from_limits(
        _fixture("codex-rollout-rate-limits-spark.json")
    )

    assert [window["limit_id"] for window in windows] == [
        "codex_bengalfox",
        "codex_bengalfox",
    ]
    assert not any(window["account_limit"] for window in windows)

    snapshot = parse_codex_usage(windows=windows, observed_at=1_789_073_144.0)
    lane_ids = {lane.lane_id for lane in snapshot.lanes}

    assert lane_ids == {"spark-five-hour", "spark-weekly"}
    assert "five-hour" not in lane_ids
    assert "weekly" not in lane_ids


def test_the_capacity_plane_refuses_the_same_sub_cap() -> None:
    """The second plane that reads these windows must agree."""
    from jrbar.provider_capacity import negotiate_provider_capacity_policies
    from jrbar.providers import negotiated_provider_sources

    descriptor = next(
        row.descriptor
        for row in negotiate_provider_capacity_policies(negotiated_provider_sources())
        if row.descriptor is not None
        and row.descriptor.source == usage_stats.CODEX_QUOTA_SOURCE
    )
    evidence = usage_stats.codex_capacity_evidence_from_windows(
        descriptor,
        usage_stats.codex_windows_from_limits(
            _fixture("codex-rollout-rate-limits-spark.json")
        ),
        observed_at=1_789_073_144.0,
    )

    assert evidence.lanes == ()


# --------------------------------------------------------------------------
# Present-but-unknown is not exhausted.
# --------------------------------------------------------------------------


def test_a_window_with_no_stated_percentage_is_unknown_not_spent() -> None:
    windows = usage_stats.codex_windows_from_limits(
        {"limitId": "codex",
         "primary": {"windowDurationMins": 300, "resetsAt": 1_789_078_256},
         "secondary": {"usedPercent": 0.0, "windowDurationMins": 10080,
                       "resetsAt": 1_789_100_000}}
    )

    assert windows[0]["used_percent"] is None
    snapshot = parse_codex_usage(windows=windows, observed_at=1_789_073_144.0)
    lanes = {lane.lane_id: lane for lane in snapshot.lanes}

    # Unknown, and specifically NOT 0.0 remaining, which is the number a red
    # exhausted bar is drawn from.
    assert lanes["five-hour"].remaining_percent is None
    assert lanes["weekly"].remaining_percent == 100.0


def test_an_unknown_window_reaches_the_state_document_as_a_null_percentage(
) -> None:
    from jrbar import core_projection

    snapshot = parse_codex_usage(
        windows=[{"label": "primary", "window_minutes": 300, "limit_id": "codex"},
                 {"label": "secondary", "used_percent": 100.0,
                  "window_minutes": 10080, "limit_id": "codex"}],
        observed_at=1_789_073_144.0,
        account_plan="plus",
    )

    class _State:
        snapshots = (snapshot,)
        refreshed_at = 1_789_073_144.0
        next_refresh_at = None
        refreshing = False

    document = core_projection.usage_document(_State())
    windows = {window["id"]: window for window in document["providers"][0]["windows"]}

    # Three states reach the app as three different values: no key at all,
    # a null percentage, and a number.
    assert windows["five-hour"]["used_pct"] is None
    assert windows["weekly"]["used_pct"] == 100.0
    assert document["providers"][0]["account"]["plan"] == "plus"


def test_a_malformed_percentage_is_dropped_rather_than_read_as_unknown() -> None:
    """A NaN or a bool is not the provider saying "no reading"."""
    windows = usage_stats.codex_windows_from_limits(
        {"limitId": "codex",
         "primary": {"usedPercent": float("nan"), "windowDurationMins": 300},
         "secondary": {"usedPercent": 40, "windowDurationMins": 10080}}
    )

    assert [window["label"] for window in windows] == ["secondary"]


# --------------------------------------------------------------------------
# The live read owns the families it covered.
# --------------------------------------------------------------------------


def test_a_live_read_outranks_a_stale_rollout_for_the_family_it_covered(
    tmp_path: Path,
) -> None:
    from jrbar.provider_usage_codex_claude import collect_codex
    from jrbar.provider_usage_settings import ProviderPreference

    live = _probe(_fixture("codex-app-server-rate-limits-pro.json"))
    stale_spark = usage_stats.codex_windows_from_limits(
        _fixture("codex-rollout-rate-limits-spark.json")
    )
    for window in stale_spark:
        window["used_percent"] = 5.0

    snapshot = collect_codex(
        ProviderPreference("codex", True, False),
        home=tmp_path,
        observed_at=1_789_073_144.0,
        live_probe=lambda: live,
        local_scanner=lambda _home, _observed: {
            "windows": stale_spark,
            "windows_observed_at": 1_789_000_000.0,
        },
    )
    lanes = {lane.lane_id: lane for lane in snapshot.lanes}

    assert snapshot.account_plan == "pro"
    assert "five-hour" not in lanes
    # The live Spark reading, not the rollout's 5.0.
    assert lanes["spark-five-hour"].remaining_percent == 0.0
    assert all(lane.source_id == "codex-app-server" for lane in snapshot.lanes)


# --------------------------------------------------------------------------
# Claude: the plan word, and its real 5-hour window, left alone.
# --------------------------------------------------------------------------


def test_claude_states_an_absent_window_as_null_and_gets_no_lane_for_it() -> None:
    payload = _fixture("claude-usage-max.json")
    windows = claude_quota.windows_from_payload(payload)
    snapshot = parse_claude_usage(
        windows=windows, observed_at=1_789_073_144.0, account_plan="Max 20x"
    )
    lanes = {lane.lane_id: lane for lane in snapshot.lanes}

    assert payload["seven_day_opus"] is None
    assert "weekly-opus" not in lanes
    assert "opus-only" not in lanes
    # Claude's real 5-hour window is untouched by the Codex rule.
    assert lanes["five-hour"].remaining_percent == 54.0
    assert lanes["weekly"].remaining_percent == 42.0
    assert snapshot.account_plan == "Max 20x"


def test_claude_plan_comes_from_claude_codes_own_config(tmp_path: Path) -> None:
    (tmp_path / ".claude.json").write_text(
        json.dumps(
            {
                "oauthAccount": {
                    "organizationType": "claude_max",
                    "organizationRateLimitTier": "default_claude_max_20x",
                    "userRateLimitTier": None,
                    "seatTier": None,
                }
            }
        ),
        encoding="utf-8",
    )

    assert claude_quota.plan_from_claude_config(tmp_path) == "Max 20x"
    assert claude_quota.plan_from_claude_config(tmp_path / "missing") is None


def test_codex_plan_falls_back_to_the_id_token_claim(tmp_path: Path) -> None:
    """No live probe and no rollout plan: auth.json still names the plan."""
    import base64

    from jrbar.credentials import read_codex_tokens

    claims = base64.urlsafe_b64encode(
        json.dumps(
            {"https://api.openai.com/auth": {"chatgpt_plan_type": "pro"}}
        ).encode()
    ).decode().rstrip("=")
    (tmp_path / ".codex").mkdir()
    (tmp_path / ".codex" / "auth.json").write_text(
        json.dumps(
            {
                "tokens": {
                    "access_token": "at",
                    "account_id": "acct",
                    "id_token": f"h.{claims}.s",
                }
            }
        ),
        encoding="utf-8",
    )

    tokens = read_codex_tokens(tmp_path / ".codex" / "auth.json")

    assert tokens is not None
    assert tokens.plan_type == "pro"


def test_the_plan_survives_a_save_and_load_round_trip(tmp_path: Path) -> None:
    from jrbar.provider_usage_runtime import ProviderUsageState
    from jrbar.provider_usage_store import (
        load_provider_usage_state,
        save_provider_usage_state,
    )

    snapshot = ProviderUsageSnapshot(
        provider_id="codex",
        account_label="acct",
        observed_at=1_789_073_144.0,
        state=ProviderSourceState.READY,
        reason_code=None,
        action_label=None,
        lanes=(),
        input_tokens=0,
        cached_input_tokens=0,
        output_tokens=0,
        model_count=0,
        estimated_cost_usd=None,
        cache_savings_usd=None,
        credits_remaining=None,
        incident=None,
        account_plan="pro",
    )
    path = tmp_path / "provider-usage.json"
    save_provider_usage_state(
        ProviderUsageState(
            refreshed_at=1_789_073_144.0,
            next_refresh_at=1_789_073_264.0,
            snapshots=(snapshot,),
            refreshing=False,
        ),
        path,
    )

    assert load_provider_usage_state(path).snapshots[0].account_plan == "pro"
