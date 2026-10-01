"""The Agent Browser's action payload refuses what it cannot carry.

The Swift app owns the browser window and sends the daemon one typed payload
per click.  The payload is the boundary: a stale or malformed one must fail
at construction, before anything acts on it.  The module that holds it draws
nothing and imports no AppKit.
"""

from __future__ import annotations

import ast
from pathlib import Path

import pytest

from jrbar import agent_browser_payloads
from jrbar.agent_browser_payloads import AgentBrowserActionPayload
from jrbar.capacity_types import SourceKey
from jrbar.navigation_policy import OperatorActionKind
from jrbar.provider_facts import WorkIdentifier, WorkKey

WORK_KEY = WorkKey(
    SourceKey("codex", "hooks", "local:test", "live_agent_events"),
    WorkIdentifier("payload"),
)


def test_a_snooze_may_name_each_preset_and_nothing_else_may() -> None:
    for preset in ("15-minutes", "1-hour", "tomorrow"):
        payload = AgentBrowserActionPayload(WORK_KEY, 3, OperatorActionKind.SNOOZE, preset)
        assert payload.snooze_preset == preset

    for kind, preset in (
        (OperatorActionKind.SNOOZE, "next-week"),
        (OperatorActionKind.OPEN, "1-hour"),
        (OperatorActionKind.PIN, "tomorrow"),
    ):
        with pytest.raises(ValueError, match="invalid agent browser action payload"):
            AgentBrowserActionPayload(WORK_KEY, 3, kind, preset)


def test_a_payload_needs_a_real_work_key_generation_and_kind() -> None:
    assert AgentBrowserActionPayload(WORK_KEY, 0, OperatorActionKind.OPEN).snooze_preset is None
    for generation in (-1, True, 2.0):
        with pytest.raises(ValueError, match="invalid agent browser action payload"):
            AgentBrowserActionPayload(WORK_KEY, generation, OperatorActionKind.OPEN)  # type: ignore[arg-type]
    with pytest.raises(ValueError, match="invalid agent browser action payload"):
        AgentBrowserActionPayload("not a key", 1, OperatorActionKind.OPEN)  # type: ignore[arg-type]
    with pytest.raises(ValueError, match="invalid agent browser action payload"):
        AgentBrowserActionPayload(WORK_KEY, 1, "open")  # type: ignore[arg-type]


def test_the_payload_module_draws_nothing_and_imports_no_appkit() -> None:
    tree = ast.parse(Path(agent_browser_payloads.__file__).read_text(encoding="utf-8"))
    imported = {
        (node.module or "").split(".")[0]
        for node in ast.walk(tree)
        if isinstance(node, ast.ImportFrom) and node.level == 0
    } | {
        alias.name.split(".")[0]
        for node in ast.walk(tree)
        if isinstance(node, ast.Import)
        for alias in node.names
    }
    assert imported.isdisjoint({"AppKit", "Foundation", "objc"})
