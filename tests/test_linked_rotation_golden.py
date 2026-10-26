"""Exact output from the original fitter, including pulse cuts and byte limits."""
import json
from pathlib import Path

import pytest

from jrbar.linked_sync import rotate_program


@pytest.mark.parametrize("case", json.loads((Path(__file__).parent / "fixtures/linked-rotation-golden.json").read_text()))
def test_rotation_preserves_the_firmware_program(case):
    assert rotate_program(case["program"], case["phase_ms"], led_count=case["led_count"]) == case["rotated"]
