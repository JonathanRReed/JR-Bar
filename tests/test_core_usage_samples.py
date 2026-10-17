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


def test_a_steady_climb_that_beats_the_reset_is_ahead__and_2_more() -> None:
    # --- scenario: a_steady_climb_that_beats_the_reset_is_ahead
    rows = climb(40.0, 20.0)
    rate, used = linear_rate(rows, now=NOW)
    assert rate == pytest.approx(20.0) and used == len(rows)
    forecast = forecast_window(rows, window_id="five-hour", used_pct=rows[-1].used_pct, resets_at=NOW + 5 * HOUR, now=NOW)
    assert forecast["pace"] == "ahead"
    assert forecast["exhausts_at"] == pytest.approx(NOW + 2 * HOUR, abs=30.0)
    assert forecast["exhausts_at"] % 60 == 0, "to the minute: it moves once a minute, not every frame"
    assert forecast["window_id"] == "five-hour" and forecast["remaining_pct"] == 40.0
    assert forecast["rate_pct_per_hour"] == pytest.approx(20.0, abs=0.01) and forecast["samples"] == len(rows)

    # --- scenario: a_reset_before_exhaustion_is_under_and_within_ten_percent_is_on
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

    # --- scenario: no_movement_is_under_with_no_exhaustion
    flat = climb(37.0, 0.0)
    forecast = forecast_window(flat, window_id="weekly", used_pct=37.0, resets_at=NOW + 3 * 86400, now=NOW)
    assert forecast == {
        "window_id": "weekly", "remaining_pct": 63.0, "exhausts_at": None, "pace": "under",
        "rate_pct_per_hour": 0.0, "samples": len(flat), "reason": None,
    }
    # A trickle below the idle rate reads the same way.
    assert forecast_window(climb(37.0, 0.02), window_id="weekly", used_pct=37.0, resets_at=None, now=NOW)["pace"] == "under"



def test_exhausted_needs_no_history__and_2_more() -> None:
    # --- scenario: exhausted_needs_no_history
    forecast = forecast_window([], window_id="five-hour", used_pct=99.6, resets_at=NOW + HOUR, now=NOW)
    assert forecast["pace"] == "exhausted" and forecast["exhausts_at"] == pytest.approx(NOW, abs=30.0) and forecast["remaining_pct"] == 0.4
    assert forecast_window([], window_id="five-hour", used_pct=100.0, resets_at=None, now=NOW)["pace"] == "exhausted"
    # A falling line into an exhausted window is still exhausted.
    assert forecast_window(climb(99.0, 1.0), window_id="five-hour", used_pct=99.9, resets_at=None, now=NOW)["pace"] == "exhausted"

    # --- scenario: not_enough_history_is_guarded_never_fabricated (T28)
    # No samples at all: a guarded forecast naming the reason, not null
    # and never an invented exhaustion date.
    guarded = forecast_window([], window_id="five-hour", used_pct=50.0, resets_at=None, now=NOW)
    assert guarded["pace"] == "guarded" and guarded["reason"] == "insufficient_samples"
    assert guarded["exhausts_at"] is None and guarded["samples"] == 0
    # A 20-minute spread cannot carry a pace either.
    guarded = forecast_window(climb(40.0, 20.0, minutes=20), window_id="five-hour", used_pct=46.0, resets_at=None, now=NOW)
    assert guarded["pace"] == "guarded" and guarded["reason"] == "insufficient_span"
    assert guarded["samples"] == 5 and guarded["span_seconds"] == pytest.approx(1200.0)
    # No measurement at all is still a true null -- there is no window
    # to pace, only an absence.
    assert forecast_window(climb(40.0, 20.0), window_id="five-hour", used_pct=None, resets_at=None, now=NOW) is None
    # Readings that stopped flowing are stale, not a pace.
    stale_tail = climb(40.0, 20.0, minutes=45, end=NOW - 20 * 60)
    guarded = forecast_window(stale_tail, window_id="five-hour", used_pct=55.0, resets_at=None, now=NOW)
    assert guarded["pace"] == "guarded" and guarded["reason"] == "stale_samples"
    # Old samples entirely outside the lookback are just absent history.
    stale = climb(40.0, 20.0, end=NOW - 4 * HOUR)
    assert forecast_window(stale, window_id="five-hour", used_pct=60.0, resets_at=None, now=NOW)["reason"] == "insufficient_samples"
    assert linear_rate(stale, now=NOW) is None
    # A backwards clock leaves the buffer entirely future-dated: dropped,
    # and the forecast says the clock moved rather than fitting noise.
    future = climb(40.0, 20.0, end=NOW + 2 * HOUR)
    guarded = forecast_window(future, window_id="five-hour", used_pct=60.0, resets_at=None, now=NOW)
    assert guarded["pace"] == "guarded" and guarded["reason"] == "clock_regressed"
    # A partial regression keeps the usable history -- the tail that is
    # not future-dated still fits.
    mixed = climb(40.0, 20.0, end=NOW + 10 * 60)
    assert forecast_window(mixed, window_id="five-hour", used_pct=60.0, resets_at=None, now=NOW)["pace"] == "ahead"

    # --- scenario: a_reset_drop_restarts_the_fit
    before = climb(60.0, 30.0, end=NOW - 40 * 60)
    after = climb(2.0, 6.0, minutes=40, end=NOW)
    rate, used = linear_rate(before + after, now=NOW)
    assert rate == pytest.approx(6.0, abs=0.01) and used == len(after)
    # A lone post-reset reading is a boundary guard, not a fake shortage.
    one_after = [*before, UsageSample(at=NOW - 60, used_pct=3.0)]
    guarded = forecast_window(one_after, window_id="five-hour", used_pct=3.0, resets_at=NOW + 4 * HOUR, now=NOW)
    assert guarded["pace"] == "guarded" and guarded["reason"] == "reset_boundary"



def test_buffer_records_on_change_or_heartbeat_and_stays_bounded__and_2_more(tmp_path: Path) -> None:
    # --- scenario: buffer_records_on_change_or_heartbeat_and_stays_bounded
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

    # --- scenario: buffer_round_trips_through_the_state_file
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
    assert forecast["pace"] == "ahead" and forecast["exhausts_at"] == pytest.approx(NOW + HOUR, abs=30.0)
    # A window with no samples at all is guarded, not null.
    guarded = loaded.forecast("claude", None, used_pct=60.0, resets_at=None, now=NOW)
    assert guarded["pace"] == "guarded" and guarded["reason"] == "insufficient_samples"

    # Garbage and a missing file both give an empty buffer.
    path.write_text("{not json")
    assert UsageSampleBuffer.load(path).is_empty
    assert UsageSampleBuffer.load(tmp_path / "nowhere.json").is_empty
    assert UsageSampleBuffer.from_document({"schema": 1, "windows": {"bad": 1, "x|y": [[1, "z"], [2.0, 5.0], [1.0, 6.0]]}}).samples("x", "y") == [UsageSample(2.0, 5.0)]
    # No path: nothing to save.
    assert UsageSampleBuffer().save() is False

    # --- scenario: save_if_due_throttles_writes
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


def _snapshot(instance: str, remaining: float, state: str = "ready") -> SimpleNamespace:
    return SimpleNamespace(
        provider_id="claude",
        source_instance_id=instance,
        state=SimpleNamespace(value=state),
        lanes=(SimpleNamespace(lane_id="five-hour", remaining_percent=remaining),),
    )


@pytest.mark.parametrize("instance", ["default", "work"])
def test_known_account_switch_cannot_borrow_forecast_history(instance: str) -> None:
    buffer = UsageSampleBuffer()
    for row in climb(20.0, 6.0):
        old = _snapshot(instance, 100.0 - row.used_pct)
        old.account_discriminator = "opaque-account-A"
        assert buffer.record_state(SimpleNamespace(snapshots=(old,)), now=row.at) == 1
        buffer.record("claude", "five-hour", row.used_pct, at=row.at, instance=instance)
    current = _snapshot(instance, 74.0)
    current.account_discriminator = "opaque-account-B"
    buffer.record_state(SimpleNamespace(snapshots=(current,)), now=NOW)
    switched = buffer.forecast("claude", "five-hour", used_pct=26.0, resets_at=None,
                               now=NOW, instance=instance, account_discriminator="opaque-account-B")
    assert switched["pace"] == "guarded"
    assert switched["reason"] == "insufficient_samples" and switched["samples"] == 1
    stable = buffer.forecast("claude", "five-hour", used_pct=26.0, resets_at=None,
                             now=NOW, instance=instance, account_discriminator="opaque-account-A")
    assert stable["rate_pct_per_hour"] == pytest.approx(6.0)
    assert stable["samples"] == 13
    assert buffer.samples("claude", "five-hour", instance, account_discriminator="unseen") == []


def test_account_scoped_history_round_trips_without_private_key_material(tmp_path: Path) -> None:
    path = tmp_path / "samples.json"
    buffer = UsageSampleBuffer(path)
    private_identity = "synthetic-private-account@example.invalid"
    for instance, used in ((None, 10.0), ("work", 20.0)):
        buffer.record("grok", "daily", used, at=NOW, instance=instance,
                      account_discriminator=private_identity)
    buffer.record("grok", "daily", 30.0, at=NOW)
    assert buffer.save(now=0.0)
    text = path.read_text()
    assert private_identity not in text
    loaded = UsageSampleBuffer.load(path)
    assert loaded.samples("grok", "daily", "default", account_discriminator=private_identity) == [UsageSample(NOW, 10.0)]
    assert loaded.samples("grok", "daily", "work", account_discriminator=private_identity) == [UsageSample(NOW, 20.0)]
    assert loaded.samples("grok", "daily") == [UsageSample(NOW, 30.0)]
    assert "grok|daily" in loaded.to_document()["windows"]


def test_account_scoped_windows_preserve_sample_and_window_bounds() -> None:
    buffer = UsageSampleBuffer()
    for index in range(samples_module.MAX_WINDOWS + 1):
        buffer.record("claude", "weekly", 1.0, at=NOW + index,
                      account_discriminator=f"account-{index}")
    assert len(buffer.to_document()["windows"]) == samples_module.MAX_WINDOWS
    assert buffer.samples("claude", "weekly", account_discriminator="account-0") == []
    newest = f"account-{samples_module.MAX_WINDOWS}"
    for index in range(samples_module.SAMPLE_LIMIT + 1):
        buffer.record("claude", "weekly", float(index), at=NOW + 1000 + index,
                      account_discriminator=newest)
    assert len(buffer.samples("claude", "weekly", account_discriminator=newest)) == samples_module.SAMPLE_LIMIT


def test_two_instances_of_one_provider_keep_their_own_samples() -> None:
    # Account "work" burns 6 points an hour while "default" sits idle. Their
    # alternating readings must not read as a reset of one shared window.
    buffer = UsageSampleBuffer()
    for step in range(0, 61, 5):
        at = NOW - (60 - step) * 60.0
        work = 80.0 - 6.0 * step / 60.0
        state = SimpleNamespace(snapshots=(_snapshot("work", work), _snapshot("default", 90.0)))
        buffer.record_state(state, now=at)
    work_forecast = buffer.forecast("claude", "five-hour", used_pct=26.0, resets_at=None, now=NOW, instance="work")
    default_forecast = buffer.forecast("claude", "five-hour", used_pct=10.0, resets_at=None, now=NOW, instance="default")
    assert work_forecast["rate_pct_per_hour"] == pytest.approx(6.0, abs=0.1)
    assert default_forecast["pace"] == "under"
    assert default_forecast["rate_pct_per_hour"] == 0.0
    # The default instance keeps the key older builds saved.
    assert "claude|five-hour" in buffer.to_document()["windows"]
    assert "claude:work|five-hour" in buffer.to_document()["windows"]


def test_a_stale_reading_is_not_sampled_as_a_fresh_one() -> None:
    buffer = UsageSampleBuffer()
    assert buffer.record_state(SimpleNamespace(snapshots=(_snapshot("default", 50.0, "stale"),)), now=NOW) == 0
    assert buffer.samples("claude", "five-hour") == []
    assert buffer.record_state(SimpleNamespace(snapshots=(_snapshot("default", 50.0, "ready"),)), now=NOW) == 1


def test_a_samples_file_of_the_wrong_shape_loads_as_far_as_it_makes_sense(tmp_path: Path) -> None:
    path = tmp_path / "usage-samples.json"
    for text in (
        '{"schema":1,"windows":{"claude|five-hour":[{"x":1}]}}',
        '{"schema":1,"windows":{"claude|five-hour":[[NaN,5],[Infinity,6],[1,NaN]]}}',
        "[" * 60_000,
        '{"schema":1,"windows":[]}',
    ):
        path.write_text(text)
        assert UsageSampleBuffer.load(path).is_empty, text[:40]
    path.write_text('{"schema":1,"windows":{"claude|five-hour":[{"x":1},[100.0,5],[NaN,7]]}}')
    assert UsageSampleBuffer.load(path).samples("claude", "five-hour") == [UsageSample(100.0, 5.0)]


def test_windows_nobody_records_any_more_do_not_pile_up() -> None:
    buffer = UsageSampleBuffer()
    for index in range(samples_module.MAX_WINDOWS + 40):
        buffer.record("claude", "five-hour", 10.0, at=NOW + index, instance=f"hub-{index}")
    document = buffer.to_document()["windows"]
    assert len(document) == samples_module.MAX_WINDOWS
    newest = f"claude:hub-{samples_module.MAX_WINDOWS + 39}|five-hour"
    assert newest in document, "the newest window is the one kept"
    assert "claude:hub-0|five-hour" not in document
