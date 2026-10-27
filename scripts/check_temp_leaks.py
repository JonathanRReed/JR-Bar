#!/usr/bin/env python3
"""Run a command in a private TMPDIR and fail on leftover test files."""

from __future__ import annotations

import argparse
import os
import subprocess
import sys
import tempfile
from pathlib import Path


def leftover_entries(directory: Path, before: set[str]) -> list[str]:
    return sorted(path.name for path in directory.iterdir() if path.name not in before)


def run(command: list[str], *, environment_overrides: dict[str, str] | None = None) -> int:
    # A short parent also leaves room for macOS's 104-byte Unix socket paths.
    # This context owns only this new directory, including on a failed run.
    with tempfile.TemporaryDirectory(prefix="jrb-", dir="/tmp") as name:
        directory = Path(name)
        before = {path.name for path in directory.iterdir()}
        environment = dict(os.environ, TMPDIR=name + "/")
        if environment_overrides is not None:
            environment.update(environment_overrides)
            environment["JRBAR_TEST_TMPDIR"] = name + "/"
        environment.pop("JRBAR_INTERACTIVE_TESTS", None)
        result = subprocess.run(command, env=environment, check=False)
        remaining = leftover_entries(directory, before)
        print(f"Temporary entries left by this run: {len(remaining)}", flush=True)
        for entry in remaining:
            print(f"  {entry}", flush=True)
        return result.returncode or (1 if remaining else 0)


def run_swift() -> int:
    root = Path(__file__).resolve().parents[1]
    swift = subprocess.check_output(["xcrun", "--find", "swift"], text=True).strip()
    with tempfile.TemporaryDirectory(prefix="jrb-tools-", dir="/tmp") as tools:
        environment = dict(os.environ, TMPDIR=tools + "/")
        environment.pop("JRBAR_INTERACTIVE_TESTS", None)
        built = subprocess.run(
            [swift, "build", "--package-path", str(root / "app"), "--build-tests"],
            env=environment, check=False,
        )
        if built.returncode:
            return built.returncode
        library = str(Path(tools) / "temp-directory.dylib")
        subprocess.run(
            ["xcrun", "clang", "-dynamiclib", "-framework", "Foundation",
             str(root / "scripts/test_temp_directory.m"), "-o", library],
            check=True, env=environment,
        )
        return run(
            [swift, "test", "--package-path", str(root / "app"), "--skip-build", "--no-parallel"],
            # The mock daemon runs on this interpreter, not a system python3.
            environment_overrides={"TMPDIR": tools + "/", "DYLD_INSERT_LIBRARIES": library,
                                   "JRBAR_MOCK_PYTHON": os.environ.get("JRBAR_MOCK_PYTHON") or sys.executable},
        )


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--swift", action="store_true", help="Build and run the serial Swift suite.")
    parser.add_argument("command", nargs=argparse.REMAINDER)
    options = parser.parse_args()
    if options.swift:
        return run_swift()
    command = options.command
    if command[:1] == ["--"]:
        command = command[1:]
    if not command:
        parser.error("supply a command after --")
    return run(command)


if __name__ == "__main__":
    raise SystemExit(main())
