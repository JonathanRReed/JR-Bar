"""No selector-shaped method may exist that nothing can ever invoke.

The class of bug this pins: a timer/selector migration moves the
invocation but leaves the method -- `animateColorsPreviewTick_` kept the
thumbnail-repaint half of the color preview while nothing invoked it
(every Settings thumb froze), and `pollDevices_` survived its own
migration test asserting the SELECTOR was gone. An orphaned callback is
invisible to ruff (it is "used" by being defined on the class) and to
the menu-action sweep (it is not in a menu). This test enumerates them
structurally.
"""

from __future__ import annotations

import ast
import re
from pathlib import Path

from test_controller_attributes import (
    CONTROLLER_CLASSES,
    CONTROLLER_MODULES,
    _composed_daemon_class,
)

# The deck layer is one more class in the composed controller's chain.
SELF_CALL_CLASSES = CONTROLLER_CLASSES | {"JRDeckStatusBarController"}

SRC = Path(__file__).resolve().parent.parent / "src" / "jrbar"

CONTROLLER_FILES = (
    "status_bar_legacy.py",
    "_status_bar_production.py",
    "provider_usage_status_bar.py",
)

# Cocoa invokes these itself (delegate/datasource/view overrides); they
# legitimately have zero in-repo references. Exact names only -- a new
# orphan must not be able to hide behind a prefix.
FRAMEWORK_CALLBACKS = frozenset(
    {
        # NSApplication invokes this delegate callback directly during
        # activation. It is intentionally framework-owned, not orphaned.
        "applicationDidBecomeActive_",
    }
)


def test_every_selector_shaped_callback_is_referenced__and_1_more() -> None:
    # --- scenario: every_selector_shaped_callback_is_referenced
    sources = {path.name: path.read_text() for path in SRC.glob("*.py")}
    blob = "\n".join(sources.values())

    defined: dict[str, str] = {}
    for name in CONTROLLER_FILES:
        text = sources[name]
        for match in re.finditer(r"^    def ([A-Za-z_]\w*?_)\(self", text, re.M):
            defined.setdefault(match.group(1), name)
        for match in re.finditer(r"^    def (_\w*_fired)\(self", text, re.M):
            defined.setdefault(match.group(1), name)

    orphans: list[str] = []
    for method, home in sorted(defined.items()):
        if method.startswith("__") or method in FRAMEWORK_CALLBACKS:
            continue
        selector = method[:-1] + ":" if method.endswith("_") else None
        references = blob.count(f".{method}(") + blob.count(f"self.{method}")
        # Declarative tables (PRESENTATION_TIMER_BINDINGS) reference
        # callbacks by quoted name; that is a reference too.
        references += blob.count(f'"{method}"') + blob.count(f"'{method}'")
        if selector is not None:
            references += blob.count(f'"{selector}"') + blob.count(f"'{selector}'")
        if references == 0:
            orphans.append(f"{home}: {method}")

    assert not orphans, (
        "selector-shaped methods nothing invokes (delete them, or add the "
        "Cocoa callback to FRAMEWORK_CALLBACKS with a reason):\n  "
        + "\n  ".join(orphans)
    )

    # --- scenario: every_timer_binding_names_a_real_callback
    """The declarative half of the same invariant: every entry in
    PRESENTATION_TIMER_BINDINGS must name a method the controller
    actually defines -- a renamed callback must fail HERE, not as a
    silent getattr surprise at launch."""
    text = (SRC / "status_bar_legacy.py").read_text()
    names = re.findall(r'\(RuntimeFeature\.\w+, "(\w+)"\)', text)
    # Floor only guards against the regex silently matching nothing; the
    # table lost its weather and timebox rows in the 0.8 rebuild.
    assert len(names) >= 15
    for name in names:
        assert re.search(rf"^    def {re.escape(name)}\(self", text, re.M), name


# Cocoa methods the controller inherits from NSObject. PyObjC resolves them
# lazily, so they never show up in a class's own namespace.
COCOA_CALLS = frozenset(
    {
        "performSelectorOnMainThread_withObject_waitUntilDone_",
        "performSelector_withObject_afterDelay_",
    }
)


def _self_calls_and_assignments(path: Path) -> tuple[dict[str, list[str]], set[str]]:
    """``self.name(...)`` calls, and every ``self.name = ...`` store, inside
    the controller's classes and the command functions in core_runtime that
    take the controller as ``self``."""
    tree = ast.parse(path.read_text(encoding="utf-8"))
    calls: dict[str, list[str]] = {}
    stores: set[str] = set()

    def visit(node: ast.AST, inside: bool) -> None:
        for child in ast.iter_child_nodes(node):
            here = inside
            if isinstance(child, ast.ClassDef):
                here = inside or child.name in SELF_CALL_CLASSES
            elif (
                isinstance(child, (ast.FunctionDef, ast.AsyncFunctionDef))
                and isinstance(node, ast.Module)
                and path.name == "core_runtime.py"
            ):
                params = child.args.posonlyargs + child.args.args
                here = bool(params) and params[0].arg == "self"
            if here:
                if (
                    isinstance(child, ast.Attribute)
                    and isinstance(child.ctx, ast.Store)
                    and isinstance(child.value, ast.Name)
                    and child.value.id == "self"
                ):
                    stores.add(child.attr)
                if (
                    isinstance(child, ast.Call)
                    and isinstance(child.func, ast.Attribute)
                    and isinstance(child.func.value, ast.Name)
                    and child.func.value.id == "self"
                ):
                    calls.setdefault(child.func.attr, []).append(
                        f"{path.name}:{child.lineno}"
                    )
            visit(child, here)

    visit(tree, False)
    return calls, stores


def test_every_self_call_names_a_method_the_controller_has() -> None:
    """The opposite failure to an orphan: a method deleted while a call to
    it stayed behind. Python reports that as an AttributeError on the path
    nothing exercised, and the controller's call sites are many and spread
    over four files. Every ``self.name(...)`` must name something the
    composed daemon class defines, a callable some method stores on
    ``self``, or a Cocoa method in COCOA_CALLS."""
    composed = _composed_daemon_class()
    known = set(composed["declared"]) | set(composed["chain"]) | set(composed["own"])
    stored: set[str] = set()
    calls: dict[str, list[str]] = {}
    for module in (*CONTROLLER_MODULES, "deck_status_bar.py"):
        found, stores = _self_calls_and_assignments(SRC / module)
        stored |= stores
        for name, sites in found.items():
            calls.setdefault(name, []).extend(sites)
    # The scan must have found the controller; an empty result would pass.
    assert len(calls) > 150
    undefined = {
        name: sites
        for name, sites in sorted(calls.items())
        if name not in known and name not in stored and name not in COCOA_CALLS
    }
    assert undefined == {}, (
        "self.name(...) calls to methods no controller class defines:\n  "
        + "\n  ".join(f"{name}: {', '.join(sites[:3])}" for name, sites in undefined.items())
    )
