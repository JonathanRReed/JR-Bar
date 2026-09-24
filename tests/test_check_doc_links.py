"""scripts/check_doc_links.py: every relative Markdown link resolves."""

from __future__ import annotations

import importlib.util
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]


def _script():
    spec = importlib.util.spec_from_file_location("check_doc_links", ROOT / "scripts" / "check_doc_links.py")
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


def test_the_repository_links_all_resolve() -> None:
    assert _script().broken_links(ROOT) == []


def test_missing_files_and_headings_are_caught(tmp_path: Path) -> None:
    script = _script()
    (tmp_path / "docs").mkdir()
    (tmp_path / "docs" / "guide.md").write_text("# Usage hooks\n\n## Run a rule\n\ntext\n")
    (tmp_path / "README.md").write_text(
        "[ok](docs/guide.md) [ok anchor](docs/guide.md#run-a-rule) [web](https://example.com)\n"
        "[gone](docs/missing.md) [bad anchor](docs/guide.md#nowhere) `[code](not/checked.md)`\n"
        "```\n[fenced](also/not/checked.md)\n```\n"
        "[ref]: docs/ref-missing.md\n"
    )
    problems = {(source.name, target, why) for source, target, why in script.broken_links(tmp_path)}
    assert problems == {
        ("README.md", "docs/missing.md", "no such file"),
        ("README.md", "docs/guide.md#nowhere", "no such heading"),
        ("README.md", "docs/ref-missing.md", "no such file"),
    }
    assert script.slug("Usage hooks v2: rules, env & JSON") == "usage-hooks-v2-rules-env--json"
