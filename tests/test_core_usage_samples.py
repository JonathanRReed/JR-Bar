"""The usage sample buffer and the pace forecast (core_usage_samples.py)."""

from __future__ import annotations

import json
from pathlib import Path
from types import SimpleNamespace

import pytest

from jrbar import core_usage_samples as samples_module
from jrbar.core_usage_samples import UsageSample, UsageSampleBuffer, forecast_window, linear_rate

NOW = 1_788_982_892.0
HOUR = 3600.0


def climb(start_pct: float, rate_per_hour: float, *, minutes: int = 60, step: int = 5, end: float = NOW) -> list[UsageSample]:
    """Samples every ``step`` minutes over the last ``minutes``, rising linearly."""
    rows = []
    for offset in range(minutes, -1, -step):
        at = end - offset * 60.0
        rows.append(UsageSample(at=at, used_pct=start_pct + rate_per_hour * (minutes - offset) / 60.0))
    return rows


def test_a_steady_climb_that_beats_the_reset_is_ahead() -> None:
    # 20 %/h from 40 %: 60 % left runs out in three hours; the reset is five away.
    rows = climb(40.0, 20.0)
    rate, used = linear_rate(rows, now=NOW)
    assert rate == pytest.approx(20.0) and used == len(rows)
    forecast = forecast_window(rows, window_id="five-hour", used_pct=rows[-1].used_pct, resets_at=NOW + 5 * HOUR, now=NOW)
    assert forecast["pace"] == "ahead"
    assert forecast["exhausts_at"] == pytest.approx(NOW + 2 * HOUR, abs=1.0)
    assert forecast["window_id"] == "five-hour" and forecast["remaining_pct"] == 40.0
    assert forecast["rate_pct_per_hour"] == pytest.approx(20.0, abs=0.01) and forecast["samples"] == len(rows)


def test_a_reset_before_exhaustion_is_under_and_within_ten_percent_is_on() -> None:
    rows = climb(40.0, 20.0)
    # Two hours to exhaustion; the reset comes in one: under.
    assert forecast_window(rows, window_id="five-hour", used_pct=60.0, resets_at=NOW + HOUR, now=NOW)["pace"] == "under"
    # The reset lands 2h05m out, exhaustion at 2h: inside the 10 % band, on pace.
    on = forecast_window(rows, window_id="five-hour", used_pct=60.0, resets_at=NOW + 2 * HOUR + 300, now=NOW)
    assert on["pace"] == "on"
    # Exhaustion a touch after the reset still counts as on pace.
    assert forecast_window(rows, window_id="five-hour", used_pct=60.0, resets_at=NOW + 2 * HOUR - 300, now=NOW)["pace"] == "on"
    # Without a known reset a window heading for 100 % is ahead.
    assert forecast_window(rows, window_id="five-hour", used_pct=60.0, resets_at=None, now=NOW)["pace"] == "ahead"


def test_no_movement_is_under_with_no_exhaustion() -> None:
    flat = climb(37.0, 0.0)
    forecast = forecast_window(flat, window_id="weekly", used_pct=37.0, resets_at=NOW + 3 * 86400, now=NOW)
    assert forecast == {
        "window_id": "weekly", "remaining_pct": 63.0, "exhausts_at": None, "pace": "under",
        "rate_pct_per_hour": 0.0, "samples": len(flat),
    }
    # A trickle below the idle rate reads the same way.
    assert forecast_window(climb(37.0, 0.02), window_id="weekly", used_pct=37.0, resets_at=None, now=NOW)["pace"] == "under"


def test_exhausted_needs_no_history() -> None:
    forecast = forecast_window([], window_id="five-hour", used_pct=99.6, resets_at=NOW + HOUR, now=NOW)
    assert forecast["pace"] == "exhausted" and forecast["exhausts_at"] == NOW and forecast["remaining_pct"] == 0.4
    assert forecast_window([], window_id="five-hour", used_pct=100.0, resets_at=None, now=NOW)["pace"] == "exhausted"
    # A falling line into an exhausted window is still exhausted.
    assert forecast_window(climb(99.0, 1.0), window_id="five-hour", used_pct=99.9, resets_at=None, now=NOW)["pace"] == "exhausted"


def test_not_enough_history_means_no_forecast() -> None:
    assert forecast_window([], window_id="five-hour", used_pct=50.0, resets_at=None, now=NOW) is None
    assert forecast_window(climb(40.0, 20.0, minutes=20), window_id="five-hour", used_pct=46.0, resets_at=None, now=NOW) is None
    assert forecast_window(climb(40.0, 20.0), window_id="five-hour", used_pct=None, resets_at=None, now=NOW) is None
    # Old samples fall out of the 90-minute lookback.
    stale = climb(40.0, 20.0, end=NOW - 4 * HOUR)
    assert linear_rate(stale, now=NOW) is None


def test_a_reset_drop_restarts_the_fit() -> None:
    # Climbing to 90 %, the window resets to 2 %, then climbs slowly.
    before = climb(60.0, 30.0, end=NOW - 40 * 60)
    after = climb(2.0, 6.0, minutes=40, end=NOW)
    rate, used = linear_rate(before + after, now=NOW)
    assert rate == pytest.approx(6.0, abs=0.01) and used == len(after)


def test_buffer_records_on_change_or_heartbeat_and_stays_bounded(tmp_path: Path) -> None:
    buffer = UsageSampleBuffer(tmp_path / "usage-samples.json")
    assert buffer.is_empty
    assert buffer.record("claude", "five-hour", 10.0, at=NOW) is True
    # Same reading a minute later: nothing new to say.
    assert buffer.record("claude", "five-hour", 10.0, at=NOW + 60) is False
    # A moved reading is kept; a reading from the past is not.
    assert buffer.record("claude", "five-hour", 11.0, at=NOW + 120) is True
    assert buffer.record("claude", "five-hour", 12.0, at=NOW + 60) is False
    # The heartbeat keeps a quiet window on the record.
    assert buffer.record("claude", "five-hour", 11.0, at=NOW + 120 + samples_module.HEARTBEAT_SECONDS) is True
    assert [sample.used_pct for sample in buffer.samples("claude", "five-hour")] == [10.0, 11.0, 11.0]
    assert buffer.samples("claude", "FIVE-HOUR") == buffer.samples("claude", "five-hour")
    for index in range(100):
        buffer.record("codex", "weekly", float(index % 100), at=NOW + index * 60)
    kept = buffer.samples("codex", "weekly")
    assert len(kept) == samples_module.SAMPLE_LIMIT and kept[-1].used_pct == 99.0
    # Out-of-range percentages are clamped.
    buffer.record("gemini", "daily", 140.0, at=NOW)
    assert buffer.samples("gemini", "daily")[0].used_pct == 100.0


def test_buffer_round_trips_through_the_state_file(tmp_path: Path) -> None:
    path = tmp_path / "state" / "usage-samples.json"
    buffer = UsageSampleBuffer(path)
    # 30 %/h in five-minute steps: 2.5-point moves, exact through the
    # file's two-decimal rounding.
    for sample in climb(40.0, 30.0):
        buffer.record("claude", "five-hour", sample.used_pct, at=sample.at)
    assert buffer.save() is True
    document = json.loads(path.read_text())
    assert document["schema"] == 1 and list(document["windows"]) == ["claude|five-hour"]
    assert document["windows"]["claude|five-hour"][0] == [NOW - 3600.0, 40.0]

    loaded = UsageSampleBuffer.load(path)
    assert loaded.samples("claude", "five-hour") == buffer.samples("claude", "five-hour")
    assert loaded.path == path
    forecast = loaded.forecast("claude", "five-hour", used_pct=70.0, resets_at=NOW + 5 * HOUR, now=NOW)
    assert forecast["pace"] == "ahead" and forecast["exhausts_at"] == pytest.approx(NOW + HOUR, abs=1.0)
    assert loaded.forecast("claude", None, used_pct=60.0, resets_at=None, now=NOW) is None

    # Garbage and a missing file both give an empty buffer.
    path.write_text("{not json")
    assert UsageSampleBuffer.load(path).is_empty
    assert UsageSampleBuffer.load(tmp_path / "nowhere.json").is_empty
    assert UsageSampleBuffer.from_document({"schema": 1, "windows": {"bad": 1, "x|y": [[1, "z"], [2.0, 5.0], [1.0, 6.0]]}}).samples("x", "y") == [UsageSample(2.0, 5.0)]
    # No path: nothing to save.
    assert UsageSampleBuffer().save() is False


def test_save_if_due_throttles_writes(tmp_path: Path) -> None:
    path = tmp_path / "usage-samples.json"
    buffer = UsageSampleBuffer(path)
    assert buffer.save_if_due(now=100.0) is False  # nothing recorded
    buffer.record("claude", "five-hour", 10.0, at=NOW)
    assert buffer.save_if_due(now=100.0) is True
    buffer.record("claude", "five-hour", 11.0, at=NOW + 60)
    assert buffer.save_if_due(now=100.0 + 10) is False
    assert buffer.save_if_due(now=100.0 + samples_module.SAVE_INTERVAL_SECONDS) is True
    assert buffer.save_if_due(now=100.0 + 2 * samples_module.SAVE_INTERVAL_SECONDS) is False


def test_record_state_reads_every_lane_of_a_provider_usage_state() -> None:
    state = SimpleNamespace(
        snapshots=(
            SimpleNamespace(
                provider_id="claude",
                lanes=(
                    SimpleNamespace(lane_id="five-hour", remaining_percent=58.0),
                    SimpleNamespace(lane_id="weekly", remaining_percent=None),
                    SimpleNamespace(lane_id=None, remaining_percent=1.0),
                ),
            ),
            SimpleNamespace(provider_id=None, lanes=(SimpleNamespace(lane_id="x", remaining_percent=1.0),)),
        )
    )
    buffer = UsageSampleBuffer()
    assert buffer.record_state(state, now=NOW) == 1
    assert buffer.samples("claude", "five-hour") == [UsageSample(NOW, 42.0)]
    assert buffer.record_state(None, now=NOW) == 0
