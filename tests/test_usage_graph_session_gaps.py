"""Sessions graph: days before a hook ledger starts are unknown, not zero.

The hook ledgers are compacted to their newest events, so a hook-only
provider (one with no transcript reader) can be counted only from where its
ledger now begins. Earlier days are drawn as gap days (a negative slot the
client breaks the line at), never as a run of zero sessions. Fixed dates and
synthetic providers throughout.
"""

from __future__ import annotations

from datetime import datetime, timedelta

from jrbar import usage_stats

NOW = datetime(2026, 9, 10, 12, 0, 0)


def _day(offset: int) -> str:
    """The ISO day ``offset`` days before NOW."""
    return (NOW - timedelta(days=offset)).date().isoformat()


def _sessions_model(**overrides):
    arguments = {
        "records": [],
        "days": 7,
        "metric": "sessions",
        "provider_ids": ("devin",),
        "now": NOW,
        "extra_sessions": {"devin": {_day(1): 2}},
    }
    arguments.update(overrides)
    return usage_stats.usage_graph_model(**arguments)


def test_days_before_the_first_ledger_day_are_gaps_and_the_rest_are_real() -> None:
    model = _sessions_model(ledger_first_day={"devin": _day(3)})

    assert [series["provider_id"] for series in model["series"]] == ["devin"]
    # Days 6, 5 and 4 before NOW precede the ledger; day 3 onward is counted.
    assert model["series"][0]["values"] == (-1.0, -1.0, -1.0, 0, 0, 2, 0)
    assert model["scale_max"] >= 2


def test_a_provider_the_ledger_does_not_cover_stays_zero_filled() -> None:
    model = _sessions_model(
        provider_ids=("devin", "cursor"),
        extra_sessions={"devin": {_day(1): 2}, "cursor": {_day(1): 1}},
        ledger_first_day={"devin": _day(3)},
    )

    by_provider = {series["provider_id"]: series["values"] for series in model["series"]}
    assert by_provider["devin"][:3] == (-1.0, -1.0, -1.0)
    assert by_provider["cursor"] == (0, 0, 0, 0, 0, 1, 0)


def test_a_first_day_at_or_before_the_window_start_makes_no_gaps() -> None:
    at_start = _sessions_model(ledger_first_day={"devin": _day(6)})
    before = _sessions_model(ledger_first_day={"devin": _day(40)})

    for model in (at_start, before):
        assert all(value >= 0 for value in model["series"][0]["values"])
        assert model["series"][0]["values"] == (0, 0, 0, 0, 0, 2, 0)


def test_only_zero_days_become_gaps_a_counted_day_is_kept() -> None:
    model = _sessions_model(
        extra_sessions={"devin": {_day(5): 1, _day(1): 2}},
        ledger_first_day={"devin": _day(3)},
    )

    # Another source counted a session on a day the ledger cannot see: it
    # stays; only the empty days around it are unknown.
    assert model["series"][0]["values"] == (-1.0, 1, -1.0, 0, 0, 2, 0)


def test_the_first_day_only_shapes_the_sessions_metric() -> None:
    epoch = (NOW - timedelta(days=1)).timestamp()
    records = [("devin", "s1", "model", epoch, 10, 0, 0, 5, "d1")]

    model = usage_stats.usage_graph_model(
        records,
        days=7,
        metric="tokens",
        provider_ids=("devin",),
        now=NOW,
        ledger_first_day={"devin": _day(3)},
    )

    assert model["series"][0]["values"] == (0, 0, 0, 0, 0, 15, 0)


def test_a_provider_with_only_gap_days_and_no_sessions_draws_no_series() -> None:
    model = _sessions_model(
        extra_sessions={}, ledger_first_day={"devin": _day(3)}
    )

    assert model["series"] == ()
    assert model["scale_max"] == usage_stats.nice_usage_scale(0.0)


def test_existing_callers_that_pass_no_first_day_are_unchanged() -> None:
    model = _sessions_model()

    assert model["series"][0]["values"] == (0, 0, 0, 0, 0, 2, 0)
