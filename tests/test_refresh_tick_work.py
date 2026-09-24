"""What the daemon's refresh tick does not do.

The headless daemon has no Why panel to show, yet every refresh_ asked for
one: the production controller deferred the call to the end of the tick
and then built the whole panel body (light context, local health, usage
text) only for the missing window to discard it.
"""

from __future__ import annotations

import ast
from pathlib import Path

LEGACY = Path(__file__).resolve().parents[1] / "src" / "jrbar" / "status_bar_legacy.py"


def _method(class_name: str, name: str) -> ast.FunctionDef:
    tree = ast.parse(LEGACY.read_text(encoding="utf-8"))
    owner = next(
        node for node in tree.body if isinstance(node, ast.ClassDef) and node.name == class_name
    )
    return next(
        node for node in owner.body if isinstance(node, ast.FunctionDef) and node.name == name
    )


def test_the_refresh_tick_never_rebuilds_the_why_panel() -> None:
    refresh = _method("StatusBarController", "refresh_")
    called = {
        node.func.attr
        for node in ast.walk(refresh)
        if isinstance(node, ast.Call) and isinstance(node.func, ast.Attribute)
    }

    assert "refresh_why_panel" not in called
    assert "why_panel_body" not in called
