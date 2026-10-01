from __future__ import annotations

import math

import pytest

from jrbar.exact_boundary_schedule import ExactBoundarySchedule


def test_early_and_stale_callbacks_are_rejected() -> None:
    schedule = ExactBoundarySchedule()
    first = schedule.replace(101.25)
    second = schedule.replace(102.5)

    assert schedule.callback_due(first, now_epoch=103.0) is False
    assert schedule.callback_due(second, now_epoch=102.49) is False
    assert schedule.callback_due(second, now_epoch=102.5) is True
    assert schedule.callback_due(second, now_epoch=104.0) is False


def test_the_exact_deadline_is_kept_without_rounding() -> None:
    schedule = ExactBoundarySchedule()
    token = schedule.replace(1_800_000_012.345678)

    assert token.deadline_epoch == 1_800_000_012.345678
    assert schedule.deadline_epoch == 1_800_000_012.345678


def test_clearing_fences_the_token_that_was_waiting() -> None:
    schedule = ExactBoundarySchedule()
    token = schedule.replace(50.0)

    schedule.clear()

    assert schedule.deadline_epoch is None
    assert schedule.callback_due(token, now_epoch=60.0) is False


def test_a_deadline_that_is_not_a_finite_time_is_refused() -> None:
    schedule = ExactBoundarySchedule()
    for bad in (math.nan, math.inf, -1.0, True, "soon"):
        with pytest.raises(ValueError, match="invalid boundary deadline"):
            schedule.replace(bad)  # type: ignore[arg-type]
    assert schedule.deadline_epoch is None

    token = schedule.replace(10.0)
    assert schedule.callback_due(token, now_epoch=math.nan) is False
    assert schedule.callback_due(token, now_epoch=10.0) is True
