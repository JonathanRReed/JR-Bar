"""The Screen Bar's width does not depend on which module imports first.

``virtual_device`` ships a default ``WINDOW_WIDTH`` and
``install_screen_bar_runtime`` overwrites it with the reviewed design's. If
the order the modules load in could leave the two apart, the Screen Bar would
draw at one width and be laid out at another. Each order runs in a fresh
interpreter, because the result is fixed by import time.
"""

from __future__ import annotations

import subprocess
import sys

import pytest

_IMPORT_ORDERS = {
    "virtual_device_first": "from jrbar import virtual_device, screen_bar_design",
    "design_first": "from jrbar import screen_bar_design, virtual_device",
}


@pytest.mark.parametrize("order", sorted(_IMPORT_ORDERS))
def test_the_screen_bar_width_is_stable_whichever_module_imports_first(order: str) -> None:
    script = f"""
{_IMPORT_ORDERS[order]}
from jrbar.screen_bar_runtime import install_screen_bar_runtime

install_screen_bar_runtime()
assert virtual_device.WINDOW_WIDTH == screen_bar_design.WINDOW_WIDTH, (
    virtual_device.WINDOW_WIDTH,
    screen_bar_design.WINDOW_WIDTH,
)
"""
    completed = subprocess.run(
        [sys.executable, "-c", script],
        capture_output=True,
        text=True,
        timeout=60,
        check=False,
    )

    assert completed.returncode == 0, completed.stderr
