"""The slow-refresh log line names the stage behind a stall.

The daemon's refresh_ runs on the main thread that also executes socket
commands, and its timing line said only ``ingest=613`` or ``leds=2286``.
Ingest and leds now carry their parts, with the old totals kept so a log
read the old way still adds up.
"""

from __future__ import annotations

import re

from jrbar.status_bar_legacy import refresh_timing_line


def _fields(line: str) -> dict[str, int]:
    return {key: int(value) for key, value in re.findall(r"([a-z0-9_.]+)=(\d+)", line)}


def test_ingest_and_leds_name_their_stages__and_2_more() -> None:
    # --- scenario: ingest_and_leds_name_their_stages
    line = refresh_timing_line(
        start=100.000,
        dnd=100.001,
        transcript_fallback=100.601,
        liveness=100.611,
        ingest=100.613,
        snapshot=100.620,
        pipeline=100.700,
        leds=102.986,
        led_write_seconds=2.200,
        end=102.990,
    )
    fields = _fields(line)

    assert line.startswith("refresh timing: total=2990ms ")
    assert fields["ingest"] == 613
    assert fields["ingest.dnd"] == 1
    assert fields["ingest.transcript_fallback"] == 600
    assert fields["ingest.liveness"] == 10
    assert fields["ingest.t3"] == 2
    assert fields["snapshot"] == 7
    assert fields["pipeline"] == 80
    assert fields["leds"] == 2286
    assert fields["leds.device_write"] == 2200
    assert fields["leds.compute"] == 86
    assert fields["rest"] == 4

    # --- scenario: the_parts_never_exceed_their_stage
    # A write stamp from a stale tick (or a clock quirk) cannot claim more
    # than the leds stage it sits in.
    line = refresh_timing_line(
        start=0.0,
        dnd=0.0,
        transcript_fallback=0.0,
        liveness=0.0,
        ingest=0.0,
        snapshot=0.0,
        pipeline=1.0,
        leds=1.5,
        led_write_seconds=9.0,
        end=1.5,
    )
    fields = _fields(line)
    assert fields["leds"] == 500
    assert fields["leds.device_write"] == 500
    assert fields["leds.compute"] == 0

    # --- scenario: a_tick_with_no_device_write_reads_all_compute
    line = refresh_timing_line(
        start=0.0,
        dnd=0.0,
        transcript_fallback=0.0,
        liveness=0.0,
        ingest=0.0,
        snapshot=0.0,
        pipeline=0.0,
        leds=0.25,
        led_write_seconds=0.0,
        end=0.25,
    )
    fields = _fields(line)
    assert fields["leds.compute"] == 250
    assert fields["leds.device_write"] == 0
