from __future__ import annotations

import importlib
import subprocess
import sys

import pytest


@pytest.mark.parametrize(
    "module",
    (
        "jrbar.hook_client",
        "jrbar.hook_entry",
        "sidepulse.hook_client",
        "sidepulse.hook_entry",
    ),
)
def test_hook_modules_fail_open_without_arguments(module: str) -> None:
    result = subprocess.run(
        [sys.executable, "-m", module],
        capture_output=True,
        text=True,
        timeout=10,
        check=False,
    )

    assert result.returncode == 0
    assert result.stdout == ""


def test_sidepulse_module_forwards_to_jrbar_cli() -> None:
    result = subprocess.run(
        [sys.executable, "-m", "sidepulse", "--help"],
        capture_output=True,
        text=True,
        timeout=20,
        check=False,
    )

    assert result.returncode == 0
    assert result.stdout.startswith("usage: jrbar"), result.stdout


@pytest.mark.parametrize("name", ("hook_client", "hook_entry", "ipc", "settings", "install"))
def test_sidepulse_alias_shares_module_objects_with_jrbar(name: str) -> None:
    importlib.import_module("sidepulse")
    aliased = importlib.import_module(f"sidepulse.{name}")
    real = importlib.import_module(f"jrbar.{name}")

    if name in {"hook_client", "hook_entry"}:
        # Real forwarder files exist for the python -m entry points.
        assert aliased.main is real.main
    else:
        assert aliased is real


def test_sidepulse_alias_does_not_invent_modules() -> None:
    importlib.import_module("sidepulse")
    with pytest.raises(ModuleNotFoundError):
        importlib.import_module("sidepulse.definitely_not_a_module")
