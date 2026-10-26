from types import SimpleNamespace

import pytest

from jrbar import core_environment as environment
from jrbar.core_server import CommandError


def test_workspace_reports_preserve_sleep_edges_and_accessibility_policy():
    edges = []
    target = SimpleNamespace(
        dndWorkspaceDidWake_=lambda _: edges.append("wake"),
        dndWorkspaceWillSleep_=lambda _: edges.append("sleep"),
        _apply_accessibility_display_preferences=lambda value: edges.append(value),
    )
    flags = {key: False for key in environment.AccessibilityDisplayPreferences.__dataclass_fields__}
    flags["reduce_motion"] = True
    environment.report(target, {"event": "sleep", "accessibility": flags})
    environment.report(target, {"event": "wake"})
    assert edges[0].reduce_motion is True
    assert edges[1:] == ["sleep", "wake"]
    with pytest.raises(CommandError):
        environment.report(target, {"event": "wake", "accessibility": {"reduce_motion": "true"}})
    assert edges[1:] == ["sleep", "wake"]
