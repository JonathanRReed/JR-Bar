from __future__ import annotations

import ast
import subprocess
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
SOURCE_ROOT = ROOT / "src" / "jrbar"


def _git_ls_files(*patterns: str) -> tuple[str, ...]:
    if not (ROOT / ".git").exists():
        return ()
    result = subprocess.run(
        ["git", "ls-files", *patterns],
        cwd=ROOT,
        check=True,
        capture_output=True,
        text=True,
    )
    return tuple(line for line in result.stdout.splitlines() if line)


def test_generated_work_directory_is_not_tracked__and_2_more() -> None:
    # --- scenario: generated_work_directory_is_not_tracked
    assert _git_ls_files("work") == ()

    # --- scenario: generated_installers_are_not_tracked
    assert _git_ls_files("*.pkg", "*.dmg") == ()

    # --- scenario: local_output_classes_are_ignored
    ignore = (ROOT / ".gitignore").read_text(encoding="utf-8")

    assert "work/" in ignore
    assert "*.pkg" in ignore
    assert "*.dmg" in ignore
    assert ".venv/" in ignore


def _is_overload(node: ast.FunctionDef | ast.AsyncFunctionDef | ast.ClassDef) -> bool:
    for decorator in node.decorator_list:
        name = decorator.attr if isinstance(decorator, ast.Attribute) else getattr(decorator, "id", None)
        if name == "overload":
            return True
    return False


def _duplicated_top_level_names(source: str) -> dict[str, tuple[int, ...]]:
    """Top-level def and class names bound more than once, with their lines.

    Only the module body itself is read, so a def chosen inside an ``if`` or
    ``try`` is not counted, and ``@overload`` stubs are allowed to repeat.
    """
    lines: dict[str, list[int]] = {}
    for node in ast.parse(source).body:
        if not isinstance(node, (ast.FunctionDef, ast.AsyncFunctionDef, ast.ClassDef)):
            continue
        if _is_overload(node):
            continue
        lines.setdefault(node.name, []).append(node.lineno)
    return {name: tuple(found) for name, found in lines.items() if len(found) > 1}


def test_top_level_name_finder_flags_a_redefinition_and_only_that() -> None:
    twice = "def _key(a):\n    return a\n\n\ndef use():\n    return _key(1)\n\n\ndef _key(a):\n    return a\n"
    assert _duplicated_top_level_names(twice) == {"_key": (1, 9)}

    class_and_def = "class Box:\n    pass\n\n\nasync def Box():\n    pass\n"
    assert _duplicated_top_level_names(class_and_def) == {"Box": (1, 5)}

    conditional = "try:\n    def load():\n        return 1\nexcept ImportError:\n    def load():\n        return 2\n"
    assert _duplicated_top_level_names(conditional) == {}

    methods = "class A:\n    def go(self):\n        return 1\n\n    def go(self, x):\n        return x\n"
    assert _duplicated_top_level_names(methods) == {}

    stubs = (
        "from typing import overload\n\n\n@overload\ndef pick(a: int) -> int: ...\n\n\n"
        "@overload\ndef pick(a: str) -> str: ...\n\n\ndef pick(a):\n    return a\n"
    )
    assert _duplicated_top_level_names(stubs) == {}


def test_no_module_defines_the_same_top_level_name_twice() -> None:
    # A second def silently rebinds the name at import, so the first one is
    # dead and the two can drift apart. ruff's F811 misses it whenever the
    # first def is used between the two.
    found: dict[str, dict[str, tuple[int, ...]]] = {}
    for path in sorted(SOURCE_ROOT.rglob("*.py")):
        repeated = _duplicated_top_level_names(path.read_text(encoding="utf-8"))
        if repeated:
            found[path.relative_to(ROOT).as_posix()] = repeated

    assert found == {}
