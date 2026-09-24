"""Contracts for the single compatibility facade around the AppKit runtime."""

from __future__ import annotations

import ast
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
FACADE = ROOT / "src" / "jrbar" / "status_bar.py"
PRODUCTION_FACADE = ROOT / "src" / "jrbar" / "_status_bar_production.py"


def _tree(path: Path) -> ast.Module:
    return ast.parse(path.read_text(encoding="utf-8"), filename=str(path))


def test_the_facade_starts_nothing_when_run__and_2_more() -> None:
    # --- scenario: the_facade_starts_nothing_when_run
    # `python -m jrbar.status_bar` ran the retired PyObjC menu bar; the
    # Swift app is the UI, so the facade has no entry point of its own.
    guards = [
        node
        for node in _tree(FACADE).body
        if isinstance(node, ast.If)
        and isinstance(node.test, ast.Compare)
        and isinstance(node.test.left, ast.Name)
        and node.test.left.id == "__name__"
    ]
    assert guards == [], "the retired menu bar must not start from python -m"

    # --- scenario: only_production_module_defines_a_controller_subclass
    production_tree = _tree(PRODUCTION_FACADE)
    production_controller = next(
        node
        for node in ast.walk(production_tree)
        if isinstance(node, ast.ClassDef) and node.name == "JRStatusBarController"
    )
    method_names = {
        node.name
        for node in production_controller.body
        if isinstance(node, (ast.FunctionDef, ast.AsyncFunctionDef))
    }
    assert {
        "projected_rows_for_device",
        "projection_for_device",
    } <= method_names

    public_classes = {
        node.name
        for node in ast.walk(_tree(FACADE))
        if isinstance(node, ast.ClassDef)
    }
    assert "JRFinalStatusBarController" not in public_classes
    assert "JRStatusBarController" not in public_classes
    assert "StatusBarController = JRStatusBarController" in FACADE.read_text(
        encoding="utf-8"
    )

    forbidden_assignments = [
        node
        for tree in (production_tree, _tree(FACADE))
        for node in ast.walk(tree)
        if isinstance(node, (ast.Assign, ast.AnnAssign, ast.AugAssign))
        and any(
            isinstance(candidate, ast.Attribute)
            and candidate.attr in {
                "projected_rows_for_device",
                "projection_for_device",
            }
            for candidate in ast.walk(node)
        )
    ]
    assert forbidden_assignments == [], "do not mutate Cocoa methods after class creation"

    # --- scenario: facade_forwards_assignment_and_deletion
    class_definition = next(
        node
        for node in _tree(FACADE).body
        if isinstance(node, ast.ClassDef) and node.name == "_StatusBarFacade"
    )
    method_names = {
        node.name
        for node in class_definition.body
        if isinstance(node, (ast.FunctionDef, ast.AsyncFunctionDef))
    }

    assert {"__getattr__", "__setattr__", "__delattr__", "__dir__"} <= method_names



def test_source_introspection_points_at_the_retained_runtime() -> None:
    source = FACADE.read_text(encoding="utf-8")

    assert "_facade_module.__file__ = _legacy.__file__" in source
