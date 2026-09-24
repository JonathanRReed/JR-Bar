"""Probe-only helpers for provider_usage_status_bar import-time contracts."""

from __future__ import annotations

import os
import sys

# A test's `python -c` probe subprocess, which inherits PYTEST_CURRENT_TEST.
# A pytest-xdist worker is also a `python -c` process under a test, but it
# has pytest itself loaded; that is what tells the two apart.
PROBE_IMPORT_MODE = (
    os.environ.get("PYTEST_CURRENT_TEST") is not None
    and sys.argv[:1] == ["-c"]
    and "_pytest" not in sys.modules
)


class ProbeLegacyShim:
    class objc:
        @staticmethod
        def IBAction(function):
            return function


__all__ = [
    "PROBE_IMPORT_MODE",
    "ProbeLegacyShim",
]
