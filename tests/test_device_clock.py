"""The devices' own clocks: fresh STATUS reads, a robust rate, persistence.

A linked Dot stays on the strip's beat only if its program is written for
the clock it really has -- the first Dot's ticks run about 2.7% slow -- so
the rate has to be measured, per device, from reads that actually reach the
device, without ever letting a stalled read stall the daemon."""

from __future__ import annotations

import random
import threading
import time
from pathlib import Path

from jrbar.device_clock import (
    DeviceClockEstimator,
    DeviceClocks,
    DeviceStatus,
    load_rates,
    parse_status,
    read_fresh_file,
    read_fresh_status,
    save_rates,
)
from jrbar.linked_sync import MAX_CLOCK_RATE, MIN_CLOCK_RATE, WARM_START_DOT_RATE

# STATUS.TXT as the two devices wrote it on 2026-09-24 (read-only probes),
# serial numbers redacted. The Pro pads the file with spaces.
PRO_STATUS = (
    "release_version 1.0.2\n"
    "serial SPP-000000\n"
    "firmware_version 27251.50806\n"
    "uptime_ms 61747904\n"
    "clk_hz 24763000\n"
    "temp_c 39.3\n"
    "state idle\n"
    "fsmeta_saves_lifetime 27381\n" + " " * 120
)
DOT_STATUS = (
    "reads 1886\n"
    "ticks 60153710\n"
    "writes 3795\n"
    "leds_writes 976\n"
    "leds_applies 976\n"
    "cache_slots 18\n"
    "init_flash 0\n"
    "serial SPD-000000\n"
    "app_version 1.0.4\n"
)


def test_both_status_formats_parse__and_2_more() -> None:
    # --- scenario: the_pro_reports_uptime_ms
    pro = DeviceStatus(10.0, parse_status(PRO_STATUS))
    assert pro.uptime_ms == 61747904.0
    assert pro.ticks is None
    assert pro.clock_ms == 61747904.0
    assert pro.serial == "SPP-000000"

    # --- scenario: the_dot_reports_ticks_and_no_uptime
    dot = DeviceStatus(10.0, parse_status(DOT_STATUS))
    assert dot.uptime_ms is None
    assert dot.clock_ms == dot.ticks == 60153710.0
    assert dot.leds_applies == 976

    # --- scenario: garbage_is_no_number
    junk = DeviceStatus(1.0, parse_status("ticks lots\nuptime_ms nan\n\n  \nnoise"))
    assert junk.ticks is None and junk.uptime_ms is None and junk.clock_ms is None


def _feed(estimator: DeviceClockEstimator, *, rate: float, seconds: float, every: float,
          jitter_ms: float = 0.0, start: float = 1000.0, clock0: float = 5_000_000.0,
          seed: int = 7) -> tuple[float, float]:
    generator = random.Random(seed)
    host = start
    clock = clock0
    while host < start + seconds:
        noisy = clock + generator.uniform(-jitter_ms, jitter_ms)
        estimator.add(host, noisy)
        host += every
        clock += every * 1000.0 * rate
    return host, clock


def test_the_estimator_finds_a_slow_dot_through_jitter__and_3_more() -> None:
    # --- scenario: a_2_66_percent_slow_clock_read_every_20_s_with_jitter
    """Sparse reads (every 20 s) with 12 ms of read jitter still land the
    rate within 0.1% after ten minutes: the Theil-Sen median ignores the
    noise that a least-squares fit would chase."""
    estimator = DeviceClockEstimator(warm_rate=1.0)
    _feed(estimator, rate=0.9734, seconds=600, every=20, jitter_ms=12)
    assert estimator.estimate.source == "measured"
    assert abs(estimator.estimate.rate - 0.9734) < 0.001

    # --- scenario: a_burst_of_reads_that_slows_the_dot_barely_moves_it
    """Four reads a second slowed the live Dot to 3.8%; a short burst of
    that inside ten sparse minutes must not drag the rate there."""
    estimator = DeviceClockEstimator(warm_rate=1.0)
    host, clock = _feed(estimator, rate=0.9734, seconds=300, every=20, jitter_ms=5)
    burst_host, burst_clock = host, clock
    for _ in range(40):
        estimator.add(burst_host, burst_clock)
        burst_host += 0.25
        burst_clock += 250.0 * 0.9624
    _feed(estimator, rate=0.9734, seconds=280, every=20, jitter_ms=5,
          start=burst_host, clock0=burst_clock)
    assert abs(estimator.estimate.rate - 0.9734) < 0.002

    # --- scenario: a_rate_step_is_followed_within_the_window
    estimator = DeviceClockEstimator(warm_rate=1.0)
    host, clock = _feed(estimator, rate=0.9734, seconds=600, every=20, jitter_ms=5)
    _feed(estimator, rate=0.9650, seconds=620, every=20, jitter_ms=5, start=host, clock0=clock)
    assert abs(estimator.estimate.rate - 0.9650) < 0.001

    # --- scenario: bounds_refuse_an_impossible_fit_and_a_reboot_clears_the_window
    estimator = DeviceClockEstimator(warm_rate=WARM_START_DOT_RATE)
    _feed(estimator, rate=1.5, seconds=200, every=20)
    assert estimator.estimate.rate == WARM_START_DOT_RATE
    assert estimator.estimate.source == "warm"
    assert MIN_CLOCK_RATE <= DeviceClockEstimator(warm_rate=0.1).estimate.rate <= MAX_CLOCK_RATE
    estimator = DeviceClockEstimator()
    _feed(estimator, rate=0.9734, seconds=200, every=20)
    estimator.add(2000.0, 10.0)  # the clock went backwards: a reboot
    assert list(estimator.samples) == [(2000.0, 10.0)]


def test_a_frozen_clock_is_a_cached_read_not_a_sample() -> None:
    """If the cache trick stops working the clock never moves; three such
    reads mark the estimate ``frozen`` so the loop re-anchors blind."""
    estimator = DeviceClockEstimator(warm_rate=0.97)
    estimator.add(100.0, 5000.0)
    for step in range(1, 4):
        estimator.add(100.0 + step * 20, 5000.0)
    assert estimator.estimate.source == "frozen"
    assert len(estimator.samples) == 1


def test_rates_persist_per_device_and_warm_start__and_1_more(tmp_path: Path) -> None:
    # --- scenario: measured_rates_round_trip_and_a_dot_warm_starts
    path = tmp_path / "device-clocks.json"
    clocks = DeviceClocks(path)
    assert clocks.rate("dot-a", dot=True) == WARM_START_DOT_RATE
    assert clocks.rate("pro-a", dot=False) == 1.0
    host = 50.0
    clock = 1_000_000.0
    for _ in range(12):
        clocks.add("dot-a", dot=True, host_at=host, clock_ms=clock)
        host += 20.0
        clock += 20_000.0 * 0.9701
    save_rates(path, {"dot-a": clocks.estimator("dot-a", dot=True).estimate})
    assert abs(load_rates(path)["dot-a"] - 0.9701) < 1e-4
    again = DeviceClocks(path)
    assert abs(again.rate("dot-a", dot=True) - 0.9701) < 1e-4
    assert again.rate("dot-b", dot=True) == WARM_START_DOT_RATE

    # --- scenario: a_mangled_file_is_an_empty_one
    path.write_text('{"dot-a": {"rate": "fast"}, "dot-b": {"rate": 7.0}, "x": 1}', encoding="utf-8")
    assert load_rates(path) == {}
    path.write_text("not json", encoding="utf-8")
    assert load_rates(path) == {}


def test_fresh_reads_are_bounded__and_2_more(tmp_path: Path) -> None:
    # --- scenario: a_real_file_reads_through
    (tmp_path / "STATUS.TXT").write_text(DOT_STATUS, encoding="utf-8")
    status = read_fresh_status(tmp_path)
    assert status is not None and status.ticks == 60153710.0
    (tmp_path / "LEDS.LED").write_text("#FF0000\n", encoding="utf-8")
    assert read_fresh_file(tmp_path / "LEDS.LED") == "#FF0000\n"

    # --- scenario: a_stalled_read_times_out_without_blocking
    """A stalled device answers ``None`` within the timeout, and while the
    stuck read is still in flight the next one answers ``None`` at once
    instead of stacking another thread on it."""
    release = threading.Event()
    entered = threading.Event()

    def stuck(path: Path):
        entered.set()
        release.wait(5.0)
        return DOT_STATUS.encode(), 1.0

    stalled_root = tmp_path / "stalled"
    started = time.monotonic()
    assert read_fresh_status(stalled_root, timeout=0.05, reader=stuck) is None
    assert time.monotonic() - started < 1.0
    assert entered.wait(1.0)
    assert read_fresh_status(stalled_root, timeout=0.05, reader=stuck) is None
    release.set()

    # --- scenario: a_live_volume_is_never_read_under_test
    assert read_fresh_status(Path("/Volumes/PulseDot"), timeout=0.5) is None
