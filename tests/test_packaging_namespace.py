"""Repository helpers must leave the installed packaging distribution importable."""

from __future__ import annotations

import subprocess
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]


def test_repository_root_does_not_shadow_installed_packaging() -> None:
    probe = """
import importlib.metadata
from pathlib import Path
import packaging
from packaging.version import Version

distribution = importlib.metadata.distribution("packaging")
expected = Path(distribution.locate_file("packaging/__init__.py")).resolve()
actual = Path(packaging.__file__).resolve()
assert actual == expected, f"packaging root {actual} differs from installed root {expected}"
assert packaging.__version__ == distribution.version
assert Version("1.10") > Version("1.9")
"""
    result = subprocess.run(
        [sys.executable, "-c", probe],
        cwd=ROOT,
        capture_output=True,
        text=True,
        timeout=30,
        check=False,
    )
    assert result.returncode == 0, result.stdout + result.stderr
