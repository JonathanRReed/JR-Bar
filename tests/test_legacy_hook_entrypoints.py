from __future__ import annotations

import subprocess
import sys


def test_hook_modules_fail_open_without_arguments() -> None:
    for module in ("jrbar.hook_client", "jrbar.hook_entry"):
        result = subprocess.run(
            [sys.executable, "-m", module],
            capture_output=True,
            text=True,
            timeout=10,
            check=False,
        )

        assert result.returncode == 0
        assert result.stdout == ""
