"""The daemon's controller declares its attribute names on its class
(jrbar.controller_attributes), which ends PyObjC's lookup walk early. These
tests keep that honest: every ``getattr(self, "name", default)`` in the
controller's code names something declared, and no declaration changes
what any read answers."""

from __future__ import annotations

import ast
import json
import os
import subprocess
import sys
import tempfile
from functools import cache
from pathlib import Path

from jrbar import controller_attributes

pytest_plugins = ("test_core_runtime",)

ROOT = Path(__file__).resolve().parents[1]
SRC = ROOT / "src" / "jrbar"
CONTROLLER_CLASSES = frozenset(
    {
        "StatusBarController",
        "JRStatusBarController",
        "JRProviderUsageStatusBarController",
        "JRCoreHeadlessController",
    }
)
CONTROLLER_MODULES = (
    "status_bar_legacy.py",
    "_status_bar_production.py",
    "provider_usage_status_bar.py",
    "core_runtime.py",
)

_COMPOSED = """
import json

from jrbar import controller_attributes, core_runtime
from jrbar.application_composition import compose_status_bar_application

compose_status_bar_application()
cls = core_runtime.build_headless_controller_class()
controller = cls.alloc().init()
declared = controller_attributes.declared_names(cls)
print(json.dumps({
    "declared": {name: repr(cls.__dict__[name]) for name in sorted(declared)},
    "chain": sorted({name for klass in cls.__mro__[1:] for name in klass.__dict__}),
    "own": sorted(set(cls.__dict__) - declared),
}))
"""


@cache
def _composed_daemon_class() -> dict:
    """The daemon's own class (composed as ``run_core`` composes it), built
    in a child process so the composition does not leak into this one."""
    with tempfile.TemporaryDirectory() as tempdir:
        env = os.environ.copy()
        env["HOME"] = tempdir
        env["PYTHONPATH"] = str(ROOT / "src")
        env.pop("PYTEST_CURRENT_TEST", None)
        completed = subprocess.run(
            [sys.executable, "-c", _COMPOSED],
            cwd=ROOT,
            env=env,
            capture_output=True,
            text=True,
            timeout=60,
            check=False,
        )
    assert completed.returncode == 0, completed.stderr
    return json.loads(completed.stdout.strip().splitlines()[-1])


def _controller_self_getattrs(path: Path) -> dict[str, list[str]]:
    """``getattr(self, "name", default)`` inside the controller's classes,
    and inside core_runtime's module functions that take the controller as
    ``self`` (the command handlers)."""
    tree = ast.parse(path.read_text(encoding="utf-8"))
    found: dict[str, list[str]] = {}

    def visit(node: ast.AST, inside: bool) -> None:
        for child in ast.iter_child_nodes(node):
            here = inside
            if isinstance(child, ast.ClassDef):
                here = child.name in CONTROLLER_CLASSES
            elif (
                isinstance(child, (ast.FunctionDef, ast.AsyncFunctionDef))
                and isinstance(node, ast.Module)
                and path.name == "core_runtime.py"
            ):
                params = child.args.posonlyargs + child.args.args
                here = bool(params) and params[0].arg == "self"
            if (
                here
                and isinstance(child, ast.Call)
                and isinstance(child.func, ast.Name)
                and child.func.id == "getattr"
                and len(child.args) == 3
                and isinstance(child.args[0], ast.Name)
                and child.args[0].id == "self"
                and isinstance(child.args[1], ast.Constant)
                and isinstance(child.args[1].value, str)
            ):
                found.setdefault(child.args[1].value, []).append(f"{path.name}:{child.lineno}")
            visit(child, here)

    visit(tree, False)
    return found


def test_every_lazy_controller_read_names_a_declared_attribute() -> None:
    """A ``getattr(self, "x", default)`` on a name nothing declared costs
    about 228 us on this NSObject subclass. Declare the name in
    ``controller_attributes.DEFAULTS`` (with the call's default), or say in
    ``UNDECLARED`` why it must stay a miss."""
    composed = _composed_daemon_class()
    known = set(composed["declared"]) | set(composed["chain"]) | set(composed["own"])
    missing: dict[str, list[str]] = {}
    for module in CONTROLLER_MODULES:
        for name, sites in _controller_self_getattrs(SRC / module).items():
            if name in controller_attributes.UNDECLARED or name in known:
                continue
            missing.setdefault(name, []).extend(sites)
    assert missing == {}


def test_no_declaration_changes_what_a_read_answers() -> None:
    """Every getattr anywhere in jrbar that names a declared attribute uses
    the declared value as its default, and nothing asks hasattr about one:
    a controller that has not set the name yet answers as it always did."""
    declared = _composed_daemon_class()["declared"]
    assert "canonical_operator_state" in declared and "_core_settings_generation" in declared
    problems: list[str] = []
    for path in sorted(SRC.glob("*.py")):
        tree = ast.parse(path.read_text(encoding="utf-8"))
        for node in ast.walk(tree):
            if not (
                isinstance(node, ast.Call)
                and isinstance(node.func, ast.Name)
                and node.func.id in ("getattr", "hasattr")
                and len(node.args) >= 2
                and isinstance(node.args[1], ast.Constant)
                and node.args[1].value in declared
            ):
                continue
            name = node.args[1].value
            where = f"{path.name}:{node.lineno} {name}"
            if node.func.id == "hasattr":
                problems.append(f"{where}: hasattr on a declared name")
                continue
            if len(node.args) < 3:
                continue
            try:
                default = ast.literal_eval(node.args[2])
            except ValueError:
                problems.append(f"{where}: computed default")
                continue
            if repr(default) != declared[name]:
                problems.append(f"{where}: default {default!r}, declared {declared[name]}")
    assert problems == []


def test_declarations_are_immutable_and_an_instance_value_still_wins(headless) -> None:
    for name, default in controller_attributes.DEFAULTS.items():
        assert isinstance(default, (type(None), bool, int, float, str, tuple, frozenset)), name
        assert name not in controller_attributes.UNDECLARED, name
    cls = type(headless)
    declared = controller_attributes.declared_names(cls)
    assert "_core_presence" in declared
    for name in declared:
        assert not any(name in klass.__dict__ for klass in cls.__mro__[1:]), name
    headless._core_presence = "sensed"
    assert headless._core_presence == "sensed"
    assert cls.__dict__["_core_presence"] is None
    # A second controller's init reads its own settings generation from the
    # class default, exactly as it read the missing attribute's default.
    second = cls.alloc().init()
    assert second._core_settings_generation >= 1
