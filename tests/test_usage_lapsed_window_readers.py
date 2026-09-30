"""The readers of saved quota readings judge a lapsed window by the clock too.

The LED, the ember and ``state.usage`` already skip a window whose reset has
passed. ``jrbar usage`` (reading the saved file when no monitor answers) and
the loopback status endpoint read the same saved readings, so a window that is
over must not be reported as the constrained one there either. It stays listed:
only the "how tight is it" answer changes. Every clock here is a fixed number.
"""

from __future__ import annotations

import io
import json
from pathlib import Path

import pytest

from jrbar import serve, usage_cli
from jrbar.provider_usage_platform import (
    ProviderSourceState,
    ProviderUsageSnapshot,
    UsageLane,
)
from jrbar.provider_usage_runtime import ProviderUsageState
from jrbar.provider_usage_store import (
    default_provider_usage_state_path,
    save_provider_usage_state,
)

NOW = 1_787_000_000.0


def _lane(lane_id: str, label: str, remaining: float | None, reset_at: float | None) -> UsageLane:
    return UsageLane(
        provider_id="claude",
        lane_id=lane_id,
        label=label,
        remaining_percent=remaining,
        reset_at=reset_at,
        scope="all",
        model=None,
        feature=None,
        bindable=True,
        source_id="official",
    )


def _save_claude(home: Path, lanes: tuple[UsageLane, ...]) -> None:
    snapshot = ProviderUsageSnapshot(
        provider_id="claude",
        account_label=None,
        observed_at=NOW - 60.0,
        state=ProviderSourceState.READY,
        reason_code=None,
        action_label=None,
        lanes=lanes,
        input_tokens=0,
        cached_input_tokens=0,
        output_tokens=0,
        model_count=0,
        estimated_cost_usd=None,
        cache_savings_usd=None,
        credits_remaining=None,
        incident=None,
    )
    save_provider_usage_state(
        ProviderUsageState((snapshot,), NOW - 60.0, NOW + 600.0, False),
        default_provider_usage_state_path(home),
    )


#: A 5-hour window whose reset passed an hour ago (nearly empty when last
#: read) beside a weekly window with real headroom.
def _lapsed_five_hour_and_open_week() -> tuple[UsageLane, ...]:
    return (
        _lane("five_hour", "5h", 5.0, NOW - 3_600.0),
        _lane("weekly", "7d", 60.0, NOW + 3 * 86_400.0),
    )


@pytest.fixture
def temporary_home(tmp_path: Path, monkeypatch: pytest.MonkeyPatch) -> Path:
    monkeypatch.setenv("HOME", str(tmp_path))
    return tmp_path


# --- jrbar usage, reading the saved file ------------------------------------


def test_usage_cli_store_reader_does_not_call_a_lapsed_window_constrained(
    temporary_home: Path,
) -> None:
    _save_claude(temporary_home, _lapsed_five_hour_and_open_week())

    document = usage_cli._from_store(now=NOW)

    [claude] = document["providers"]
    assert claude["constrained"]["id"] == "weekly"
    assert claude["constrained"]["candidates"] == 1
    # The lapsed window is still listed, unchanged.
    assert [(window["id"], window["used_pct"]) for window in claude["windows"]] == [
        ("five_hour", 95.0),
        ("weekly", 40.0),
    ]


def test_usage_cli_main_judges_the_saved_file_by_its_own_clock(
    temporary_home: Path,
) -> None:
    _save_claude(temporary_home, _lapsed_five_hour_and_open_week())
    out, err = io.StringIO(), io.StringIO()

    code = usage_cli.main(
        ["--json"],
        stdout=out,
        stderr=err,
        now=NOW,
        core_reader=lambda _path: None,
    )

    assert code == 0
    [claude] = json.loads(out.getvalue())["providers"]
    assert claude["constrained"]["id"] == "weekly"


def test_usage_cli_store_reader_keeps_a_live_low_window_constrained(
    temporary_home: Path,
) -> None:
    lanes = (
        _lane("five_hour", "5h", 5.0, NOW + 3_600.0),
        _lane("weekly", "7d", 60.0, NOW + 3 * 86_400.0),
    )
    _save_claude(temporary_home, lanes)

    [claude] = usage_cli._from_store(now=NOW)["providers"]

    assert claude["constrained"]["id"] == "five_hour"


def test_an_injected_store_reader_still_works_without_a_clock() -> None:
    out, err = io.StringIO(), io.StringIO()

    code = usage_cli.main(
        [],
        stdout=out,
        stderr=err,
        now=NOW,
        core_reader=lambda _path: None,
        store_reader=lambda: {"refreshed_at": None, "providers": []},
    )

    assert code == 0
    assert out.getvalue().strip() == "No provider usage yet."


# --- the loopback status endpoint -------------------------------------------


def _raw_lane(lane_id: str, remaining: float | None, reset_at: float | None) -> dict:
    return {
        "provider_id": "claude",
        "lane_id": lane_id,
        "remaining_percent": remaining,
        "reset_at": reset_at,
    }


def test_quota_summary_skips_a_lapsed_window_for_remaining_and_next_reset() -> None:
    lanes = [
        _raw_lane("five_hour", 5.0, NOW - 3_600.0),
        _raw_lane("weekly", 60.0, NOW + 86_400.0),
    ]

    summary = serve._quota_summary(lanes, provider_id="claude", now=NOW)

    assert summary == {
        # Both windows are still counted: the lapsed one is listed, not judged.
        "window_count": 2,
        "remaining_percent": 60.0,
        "next_reset_at": NOW + 86_400.0,
    }


def test_quota_summary_says_nothing_is_constrained_when_every_window_lapsed() -> None:
    lanes = [
        _raw_lane("five_hour", 5.0, NOW - 3_600.0),
        _raw_lane("weekly", 60.0, NOW - 60.0),
    ]

    summary = serve._quota_summary(lanes, provider_id="claude", now=NOW)

    assert summary == {"window_count": 2, "remaining_percent": None, "next_reset_at": None}


def test_quota_summary_treats_a_reset_at_this_moment_as_lapsed() -> None:
    lanes = [_raw_lane("five_hour", 5.0, NOW), _raw_lane("weekly", 60.0, NOW + 1.0)]

    summary = serve._quota_summary(lanes, provider_id="claude", now=NOW)

    assert summary["remaining_percent"] == 60.0


def test_quota_summary_never_lapses_a_window_with_no_reset_time() -> None:
    lanes = [
        _raw_lane("credits", 10.0, None),
        _raw_lane("five_hour", 5.0, NOW - 3_600.0),
        _raw_lane("weekly", 60.0, NOW + 86_400.0),
    ]

    summary = serve._quota_summary(lanes, provider_id="claude", now=NOW)

    assert summary["remaining_percent"] == 10.0
    assert summary["next_reset_at"] == NOW + 86_400.0
    assert summary["window_count"] == 3


def test_quota_summary_reads_the_clock_when_no_moment_is_passed(
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    lanes = [
        _raw_lane("five_hour", 5.0, NOW - 3_600.0),
        _raw_lane("weekly", 60.0, NOW + 86_400.0),
    ]
    monkeypatch.setattr(serve, "_wall_clock", lambda: NOW)

    assert serve._quota_summary(lanes, provider_id="claude")["remaining_percent"] == 60.0

    monkeypatch.setattr(serve, "_wall_clock", lambda: NOW - 7_200.0)

    assert serve._quota_summary(lanes, provider_id="claude")["remaining_percent"] == 5.0


def test_the_status_document_leaves_a_lapsed_window_out_of_the_quota(
    temporary_home: Path, monkeypatch: pytest.MonkeyPatch
) -> None:
    # The endpoint reads the saved file raw, in the shape it accepts.
    path = default_provider_usage_state_path(temporary_home)
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(
        json.dumps(
            {
                "schema_version": 1,
                "refreshed_at": NOW - 60.0,
                "next_refresh_at": NOW + 600.0,
                "snapshots": [
                    {
                        "provider_id": "claude",
                        "observed_at": NOW - 60.0,
                        "state": "ready",
                        "lanes": [
                            _raw_lane("five_hour", 5.0, NOW - 3_600.0),
                            _raw_lane("weekly", 60.0, NOW + 3 * 86_400.0),
                        ],
                    }
                ],
            }
        ),
        encoding="utf-8",
    )
    monkeypatch.setattr(serve, "_wall_clock", lambda: NOW)

    document = serve.build_serve_document(temporary_home)

    [claude] = document["usage"]["providers"]
    assert claude["quota"] == {
        "window_count": 2,
        "remaining_percent": 60.0,
        "next_reset_at": NOW + 3 * 86_400.0,
    }
