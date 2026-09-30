"""scripts/check_doc_links.py: every relative Markdown link resolves."""

from __future__ import annotations

import importlib.util
import os
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


def test_agent_worktrees_are_not_this_trees_docs(tmp_path: Path) -> None:
    """A checkout under ``.claude/worktrees`` is another commit of the repo:
    its stale links are not this tree's, and its files are not counted."""
    script = _script()
    (tmp_path / "README.md").write_text("[ok](README.md)\n")
    stale = tmp_path / ".claude" / "worktrees" / "lane" / "docs"
    stale.mkdir(parents=True)
    (stale / "old.md").write_text("[gone](missing.md)\n")
    assert script.broken_links(tmp_path) == []
    assert [path.name for path in script.markdown_files(tmp_path)] == ["README.md"]


def test_skipped_directories_are_never_listed(tmp_path: Path, monkeypatch) -> None:
    """Build trees are skipped without being walked: ``app/.build`` alone is
    gigabytes, and listing it took minutes before the skip was applied."""
    script = _script()
    (tmp_path / "docs").mkdir()
    (tmp_path / "docs" / "guide.md").write_text("# Guide\n")
    (tmp_path / "README.md").write_text("[guide](docs/guide.md)\n")
    skipped = sorted(script._SKIP_PARTS)
    for name in skipped:
        for base in (tmp_path, tmp_path / "app"):
            deep = base / name / "deep" / "deeper"
            deep.mkdir(parents=True)
            (deep / "stale.md").write_text("[gone](missing.md)\n")

    listed: list[Path] = []
    real_scandir = os.scandir

    def spy(path="."):
        listed.append(Path(os.fsdecode(path)))
        return real_scandir(path)

    with monkeypatch.context() as patch:
        patch.setattr(os, "scandir", spy)
        found = script.markdown_files(tmp_path)
        problems = script.broken_links(tmp_path)

    assert [path.relative_to(tmp_path).as_posix() for path in found] == ["README.md", "docs/guide.md"]
    assert problems == []
    assert tmp_path in listed and tmp_path / "app" in listed
    entered = [
        path.relative_to(tmp_path).as_posix()
        for path in listed
        if set(script._SKIP_PARTS) & set(path.relative_to(tmp_path).parts)
    ]
    assert entered == []
