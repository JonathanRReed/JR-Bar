"""The daemon's own words never send a person to a Settings page that no
longer exists. Comments and docstrings may keep history; strings a person
reads may not."""

from __future__ import annotations

import ast
import importlib.util
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]


def _retired():
    spec = importlib.util.spec_from_file_location("check_doc_links", ROOT / "scripts" / "check_doc_links.py")
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module.RETIRED_PAGES


def _docstrings(tree: ast.AST) -> set[int]:
    found = set()
    for node in ast.walk(tree):
        if isinstance(node, (ast.Module, ast.ClassDef, ast.FunctionDef, ast.AsyncFunctionDef)) and node.body:
            first = node.body[0]
            if isinstance(first, ast.Expr) and isinstance(first.value, ast.Constant):
                found.add(id(first.value))
    return found


def retired_strings(root: Path) -> list[str]:
    pattern = _retired()
    hits = []
    for path in sorted(root.rglob("*.py")):
        tree = ast.parse(path.read_text(encoding="utf-8"))
        skip = _docstrings(tree)
        for node in ast.walk(tree):
            if isinstance(node, ast.Constant) and isinstance(node.value, str) and id(node) not in skip:
                hits.extend(f"{path.name}:{node.lineno}: {match.group()}" for match in pattern.finditer(node.value))
    return hits


def test_daemon_strings_name_current_pages():
    assert retired_strings(ROOT / "src/jrbar") == []


def test_the_scan_sees_strings_but_not_docstrings(tmp_path: Path):
    (tmp_path / "words.py").write_text(
        '"""Settings > Agents & Usage, in a docstring."""\n'
        '# Settings > Devices & Lighting, in a comment\n'
        'MESSAGE = "Turn it on in Settings > Agents & Usage first"\n')
    assert retired_strings(tmp_path) == ["words.py:3: Agents & Usage"]


def test_the_app_and_doc_guards_share_one_list():
    from scripts.check_design_tokens import PATTERNS

    assert PATTERNS["retired-page"].pattern == _retired().pattern
