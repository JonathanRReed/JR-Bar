"""The app's copied closed-lid install command writes the daemon's rule.

The Swift side (``SetupModel.lidHelperScript``) writes the sudoers drop-in
from a fixed ``/bin/sh`` script so no program in the app bundle runs as
root. This pins the rule text and the file name it writes to the Python
installer's, so the two cannot drift apart.
"""

from __future__ import annotations

from pathlib import Path

from jrbar.lid_sleep import SLEEP_HELPER_SUDOERS_PATH, sleep_helper_sudoers_rule

SETUP_MODEL = Path(__file__).resolve().parents[1] / "app/Sources/JRBarApp/Setup/SetupModel.swift"


def test_the_app_command_writes_the_rule_the_installer_writes() -> None:
    source = SETUP_MODEL.read_text(encoding="utf-8")
    rule = sleep_helper_sudoers_rule("USER").replace("USER", "%s").replace("\n", "\\n")
    assert rule in source
    assert f"/{SLEEP_HELPER_SUDOERS_PATH.name}" in source
    assert str(SLEEP_HELPER_SUDOERS_PATH.parent) in source
