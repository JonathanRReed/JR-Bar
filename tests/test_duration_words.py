"""The daemon's duration words agree with the app's ``UsageTime.duration``
(app/Tests/JRBarCoreTests/WordingTests.swift reads the same table): a
whole hour or day drops its zeros, a partial hour keeps padded minutes."""

from __future__ import annotations

import math

import pytest

from jrbar.duration_words import duration

TABLE = [
    (30, "30s"),
    (90, "1m 30s"),
    (41 * 60, "41m"),
    (59 * 60, "59m"),
    (3600, "1h"),
    (3600 + 59, "1h"),
    (2 * 3600, "2h"),
    (23 * 3600, "23h"),
    (3600 + 5 * 60, "1h 05m"),
    (2 * 3600 + 30 * 60, "2h 30m"),
    (86400, "1d"),
    (3 * 86400, "3d"),
    (3 * 86400 + 4 * 3600, "3d 4h"),
    (3 * 86400 + 20 * 3600, "3d 20h"),
    (3 * 86400 + 30 * 60, "3d"),
]


@pytest.mark.parametrize(("seconds", "words"), TABLE)
def test_duration_matches_the_app(seconds: int, words: str) -> None:
    assert duration(seconds) == words


@pytest.mark.parametrize("value", [math.nan, math.inf, True, "1h", None])
def test_duration_refuses_what_is_not_a_length(value) -> None:
    assert duration(value) == "unknown"


def test_negative_is_zero() -> None:
    assert duration(-5) == "0s"
