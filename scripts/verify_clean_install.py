#!/usr/bin/env python3
"""Install the built wheel into an empty environment and test shipped surfaces."""

from __future__ import annotations

import os
import platform
import subprocess
import sys
import tempfile
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
DIST = ROOT / "dist"


def run(*arguments: object, cwd: Path | None = None) -> subprocess.CompletedProcess[str]:
    environment = {
        **os.environ,
        "PIP_DISABLE_PIP_VERSION_CHECK": "1",
        "PYTHONPATH": "",
    }
    return subprocess.run(
        [str(argument) for argument in arguments],
        cwd=cwd,
        check=True,
        capture_output=True,
        text=True,
        timeout=900,
        env=environment,
    )


def wheel_path() -> Path:
    wheels = sorted(DIST.glob("sidepulse-*.whl"))
    if len(wheels) != 1:
        raise RuntimeError(f"expected one SidePulse wheel in {DIST}, found {len(wheels)}")
    return wheels[0]


def main() -> int:
    wheel = wheel_path()
    with tempfile.TemporaryDirectory(prefix="sidepulse-clean-install-") as directory:
        root = Path(directory)
        environment = root / "venv"
        run(sys.executable, "-m", "venv", environment)
        python = environment / "bin" / "python"
        run(python, "-m", "pip", "install", wheel)

        probe = """
import importlib.metadata
import importlib.resources
import jrbar

assert importlib.metadata.version("sidepulse") == sidepulse.__version__
resources = importlib.resources.files("jrbar.resources")
assert (resources / "sdled.wasm").is_file()
assert (resources / "sd_eject_guard.c").is_file()
assert (resources / "integration_compatibility.json").is_file()
assert (resources / "provider_fixture_ownership.json").is_file()
for module in (
    "jrbar.cli",
    "jrbar.cli_entry",
    "jrbar.hook_dedupe",
    "jrbar.hook_entry",
    "jrbar.integration_cli",
    "jrbar.integration_compatibility",
    "jrbar.integration_settings",
    "jrbar.status_bar_launch",
    "jrbar.t3_compat",
    "sidepulse",
    "sidepulse.hook_client",
    "sidepulse.hook_entry",
):
    __import__(module)
"""
        run(python, "-c", probe, cwd=root)

        bin_dir = environment / "bin"
        for name in (
            "jrbar",
            "jrbar-integrations",
            # Transitional alias kept for one release after the rename.
            "sidepulse",
        ):
            path = bin_dir / name
            if not path.is_file() or not os.access(path, os.X_OK):
                raise RuntimeError(f"missing installed console script: {path}")

        run(bin_dir / "jrbar", "--help", cwd=root)
        run(bin_dir / "jrbar", "integrations", "status", "--json", cwd=root)
        run(bin_dir / "jrbar-integrations", "status", "--json", cwd=root)
        run(bin_dir / "jrbar", "agent-monitor", "--help", cwd=root)
        run(bin_dir / "sidepulse", "--help", cwd=root)
        run(python, "-m", "sidepulse.hook_client", cwd=root)
        run(python, "-m", "sidepulse.hook_entry", cwd=root)

        if platform.system() == "Darwin":
            run(python, "-c", "import jrbar.status_bar", cwd=root)

    print(f"Clean-install verification passed: {wheel.name}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
