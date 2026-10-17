"""Invalid readings fall back without touching a display or sensor."""

import json

import pytest

from jrbar.auto_dim import AutoDimSettings, LuxSmoother, _SmoothedAmbientLight, evaluate_auto_dim

BAD_READINGS = [
    True, False, "0.5", "broken", object(), float("nan"), float("inf"),
    pytest.param(10**1000, id="oversized"),
]


@pytest.mark.parametrize("reading", BAD_READINGS)
def test_invalid_ambient_reading_uses_display_fallback(reading: object) -> None:
    result = evaluate_auto_dim(
        AutoDimSettings(mode="ambient"),
        now_minutes=0,
        ambient_reader=lambda: reading,
        display_reader=lambda: 0.6,
    )
    assert (result.source, result.factor, result.available) == ("display", 0.6, False)
    json.dumps(result.to_dict(), allow_nan=False)


@pytest.mark.parametrize("reading", BAD_READINGS)
def test_invalid_display_reading_is_unavailable(reading: object) -> None:
    result = evaluate_auto_dim(
        AutoDimSettings(mode="display"),
        now_minutes=0,
        ambient_reader=lambda: None,
        display_reader=lambda: reading,
    )
    assert (result.factor, result.available, result.reading) == (1.0, False, None)


@pytest.mark.parametrize("raw", [*BAD_READINGS, -1.0])
def test_invalid_raw_readout_is_omitted(raw: object) -> None:
    def reader() -> float:
        return 80.0

    reader.last_raw = raw
    result = evaluate_auto_dim(
        AutoDimSettings(mode="ambient"),
        now_minutes=0,
        ambient_reader=reader,
        display_reader=lambda: None,
    )
    assert result.available and result.reading == 80.0
    assert "raw" not in result.to_dict()
    json.dumps(result.to_dict(), allow_nan=False)


@pytest.mark.parametrize("raw", [*BAD_READINGS, -1.0])
def test_failed_read_clears_smoothing_before_recovery(raw: object) -> None:
    values = iter([80.0, raw, 20.0])
    smoother = LuxSmoother(clock=lambda: 0.0)
    reader = _SmoothedAmbientLight(lambda: next(values), smoother)
    assert reader() == 80.0
    assert reader() is None
    assert smoother.value is None and reader.last_raw is None
    assert reader() == 20.0


def test_reader_exception_clears_smoothing_before_recovery() -> None:
    values = iter([80.0, RuntimeError("sensor disconnected"), 20.0])

    def read() -> float:
        value = next(values)
        if isinstance(value, Exception):
            raise value
        return value

    smoother = LuxSmoother(clock=lambda: 0.0)
    reader = _SmoothedAmbientLight(read, smoother)
    assert reader() == 80.0
    assert reader() is None
    assert reader() == 20.0


def test_oversized_setting_scalars_use_field_defaults() -> None:
    huge = 10**1000
    settings = AutoDimSettings.from_dict({
        "schedule": {"start_minutes": huge, "end_minutes": huge, "fraction": huge},
        "display": {"min_fraction": huge},
        "ambient": {"min_fraction": huge, "lux_floor": huge, "lux_ceiling": huge},
    })
    assert settings == AutoDimSettings()


def test_zero_sensor_readings_are_valid_darkness() -> None:
    result = evaluate_auto_dim(
        AutoDimSettings(mode="ambient"),
        now_minutes=0,
        ambient_reader=lambda: 0.0,
        display_reader=lambda: None,
    )
    assert result.available and result.reading == 0.0
    assert result.factor == AutoDimSettings().ambient_min_fraction
