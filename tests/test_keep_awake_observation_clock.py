"""Keep Awake treats invalid or future battery timestamps as unknown."""
from types import SimpleNamespace

import pytest

from jrbar.keep_awake import BATTERY_READING_MAX_AGE_SECONDS, fresh_battery_snapshot


@pytest.mark.parametrize("observed,now", [(1005.0, 1000.0), (float("nan"), 1000.0),
                                         (float("inf"), 1000.0), (1000.0, float("nan")), (True, 1.5)])
def test_invalid_or_future_observation_is_not_a_current_battery_reading(observed, now):
    snapshot = object()
    observation = SimpleNamespace(snapshot=snapshot, observed_at=observed)
    assert fresh_battery_snapshot(observation, now=now) is None


def test_real_reading_at_the_age_boundary_is_still_used():
    snapshot = object()
    observation = SimpleNamespace(snapshot=snapshot, observed_at=1000.0)
    assert fresh_battery_snapshot(observation, now=1000 + BATTERY_READING_MAX_AGE_SECONDS) is snapshot
    assert fresh_battery_snapshot(observation, now=1001 + BATTERY_READING_MAX_AGE_SECONDS) is None
