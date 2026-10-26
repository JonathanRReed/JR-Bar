"""Pinned phase cuts, including pulse cuts and firmware frame timing."""
import json
from pathlib import Path

import pytest

from jrbar.animation import read_program
from jrbar.led_wasm import RawSdLedWasmController
from jrbar.linked_sync import playback_loop_ms, rotate_program


@pytest.mark.parametrize("case", json.loads((Path(__file__).parent / "fixtures/linked-rotation-golden.json").read_text()))
def test_rotation_preserves_the_firmware_program(case):
    assert rotate_program(case["program"], case["phase_ms"], led_count=case["led_count"]) == case["rotated"]


@pytest.mark.parametrize("case", json.loads((Path(__file__).parent / "fixtures/linked-rotation-golden.json").read_text()))
def test_pinned_cut_matches_uninterrupted_firmware_playback(case):
    program = case["program"]
    count = case["led_count"]
    lap = playback_loop_ms(read_program(program, led_count=count)[0])
    when = lap + round(case["phase_ms"] % lap)
    engines = [RawSdLedWasmController(count) for _ in range(2)]
    for engine in engines:
        engine.reset(0)
        assert engine.parse(program, 0).ok
        engine.step_batch(0, 1, when)
    assert engines[1].parse(case["rotated"], when).ok
    reference, rotated = [engine.step_batch(when, 16, max(1, lap // 16)) for engine in engines]
    error = max(abs(a - b) for left, right in zip(reference, rotated)
                for lp, rp in zip(left, right) for a, b in zip(lp, rp))
    assert error <= 3
